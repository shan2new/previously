import type { FastifyPluginAsync } from 'fastify'
import { z } from 'zod'
import { enqueueFranchiseNewsRefresh, listAnnouncementObservations } from '../news/service.js'
import { getFranchise, getSummaries } from '../services/franchiseView.js'
import { withReleaseWindow } from '../services/releaseWindow.js'
import { searchFranchises, type SearchProfile } from '../services/search.js'
import {
  getAvailabilityPreviews,
  getWatchAvailability,
  getWatchAvailabilityBatch,
} from '../services/watchAvailability.js'
import { enqueueFranchiseEnrichment } from '../services/catalogEnrichment.js'
import { enqueueAnimeVideoFallback, refreshAnimeVideoFallback } from '../services/animeVideoFallback.js'
import { ensureTvFranchise, refreshTvUpcomingFact } from '../tmdb/service.js'
import type { FranchiseSummary } from '../types/api.js'
import { withTimeout } from '../util/abort.js'
import { suggestionSource } from '../services/audience.js'
import { applyProviderPreferences, resolveUserPreferences } from '../services/preferences.js'
import { findLocalFranchise } from '../services/recommendations.js'
import { groupFromSeed } from '../grouping/service.js'
import { getStarterFranchises, STARTER_MAX } from '../services/starter.js'

const countrySchema = z.string().regex(/^[a-z]{2}$/i).transform((value) => value.toUpperCase())
const filterFields = {
  // Absent = the viewer's audience decides (services/audience.ts); an explicit catalogue wins.
  source: z.enum(['anilist', 'tmdb']).optional(),
  year: z.coerce.number().int().min(1880).max(2200).optional(),
  status: z.enum(['FINISHED', 'RELEASING', 'NOT_YET_RELEASED', 'CANCELLED', 'HIATUS']).optional(),
  theme: z.string().trim().min(1).max(80).optional(),
  providerId: z.coerce.number().int().positive().optional(),
  country: countrySchema.optional(),
}
const trendingQuery = z.object({ limit: z.coerce.number().min(1).max(100).default(30), ...filterFields })
const starterQuery = z.object({
  limit: z.coerce.number().int().min(1).max(STARTER_MAX).default(60),
  source: z.enum(['anilist', 'tmdb']).optional(),
})
// `exact=1` opts out of the LLM spell-correction: the caller wants the literal query searched.
const searchQuery = z.object({
  q: z.string().default(''),
  limit: z.coerce.number().min(1).max(100).default(30),
  exact: z.string().optional(),
  ...filterFields,
})
const watchProviderQuery = z.object({
  country: countrySchema.optional(),
})
const detailQuery = z.object({
  country: countrySchema.optional(),
})

const normalizedTitle = (value: string): string =>
  value.normalize('NFKC').toLocaleLowerCase('en-US').replace(/[^\p{L}\p{N}]+/gu, ' ').trim()

async function attachAvailabilityPreviews(
  rows: FranchiseSummary[],
  country: string | null,
  providerIds: number[],
  requiredProviderId?: number,
): Promise<FranchiseSummary[]> {
  if (!country || rows.length === 0) return rows
  const values = requiredProviderId == null
    ? await getAvailabilityPreviews(rows.map((item) => item.id), country)
    : await getWatchAvailabilityBatch(rows.map((item) => item.id), country)
  for (const item of rows) {
    const value = values.get(item.id)
    if (value) item.availability = applyProviderPreferences(value, providerIds)
  }
  return requiredProviderId == null
    ? rows
    : rows.filter((item) => item.availability?.providers.some((provider) => provider.id === requiredProviderId))
}

export const franchiseRoutes: FastifyPluginAsync = async (app) => {
  // All franchise routes require a valid user (so detail can include subscription/progress).
  app.addHook('preHandler', app.authenticate)

  app.get('/franchises/trending', async (req, reply) => {
    const query = trendingQuery.parse(req.query)
    const preferences = await resolveUserPreferences(req.user!.id, query.country)
    const country = preferences.country
    if (query.providerId != null && !country) {
      return reply.code(400).send({ error: 'country is required when filtering by provider' })
    }
    const source = await suggestionSource(req.user!.id, query.source)
    const response = await searchFranchises('', query.limit, {
      filters: {
        source: source ?? undefined,
        year: query.year,
        status: query.status,
        theme: query.theme,
        providerId: query.providerId,
        country: country ?? undefined,
      },
    })
    response.franchises = await attachAvailabilityPreviews(
      response.franchises,
      country,
      preferences.providerIds,
      query.providerId,
    )
    return { franchises: response.franchises }
  })

  // First run's picker: the catalogue's best-known shows (services/starter.ts), so a new viewer
  // finds theirs. Like every suggestion route, no `source` = the viewer's audience.
  app.get('/franchises/starter', async (req, reply) => {
    const query = starterQuery.safeParse(req.query)
    if (!query.success) return reply.code(400).send({ error: 'invalid request' })
    const source = await suggestionSource(req.user!.id, query.data.source)
    return { franchises: await getStarterFranchises(source, query.data.limit) }
  })

  app.get('/search', async (req, reply) => {
    const query = searchQuery.parse(req.query)
    const { q, limit, exact } = query
    const preferences = await resolveUserPreferences(req.user!.id, query.country)
    const country = preferences.country
    if (query.providerId != null && !country) {
      return reply.code(400).send({ error: 'country is required when filtering by provider' })
    }
    // Trending (an empty `q`) and a typed query alike: with no explicit `source`, the viewer's
    // audience is the catalogue searched.
    const source = await suggestionSource(req.user!.id, query.source)
    const controller = new AbortController()
    const abort = () => controller.abort()
    const abortIfUnsent = () => {
      if (!reply.raw.writableEnded) controller.abort()
    }
    req.raw.once('aborted', abort)
    reply.raw.once('close', abortIfUnsent)

    let profile: SearchProfile | undefined
    try {
      const response = await searchFranchises(q, limit, {
        exact: exact === '1',
        signal: controller.signal,
        onProfile: (value) => {
          profile = value
        },
        filters: {
          source: source ?? undefined,
          year: query.year,
          status: query.status,
          theme: query.theme,
          providerId: query.providerId,
          country: country ?? undefined,
        },
      })
      // Search is a product surface, not merely a path to Detail. An exact result must begin
      // enriching its catalogue fallback here; the request still returns immediately.
      const intendedTitle = normalizedTitle(response.correctedQuery ?? q)
      const exactFranchise = intendedTitle
        ? response.franchises.find((item) => normalizedTitle(item.title) === intendedTitle)
        : undefined
      if (exactFranchise?.source === 'tmdb' && (!exactFranchise.upcoming || !exactFranchise.featuredVideo)) {
        try {
          const immediate = await refreshTvUpcomingFact(exactFranchise.id, { maxRetries: 0, timeoutMs: 1_050 })
          // refreshTvUpcomingFact also persists the show-level video from the same TMDB response.
          // Rebuild this one summary so a first exact Search can return that trailer immediately.
          const [refreshed] = await getSummaries([exactFranchise.id])
          if (refreshed) Object.assign(exactFranchise, refreshed)
          exactFranchise.upcoming = withReleaseWindow(immediate)
        } catch (error) {
          // Provider news is enrichment: a short TMDB failure must not turn a useful search result
          // into an error. The background researcher below can still fill it later.
          req.log.warn(
            { event: 'search.upcoming_refresh_failed', franchiseId: exactFranchise.id, error },
            'exact-search upcoming refresh failed',
          )
        }
      } else if (exactFranchise?.source === 'anilist' && !exactFranchise.featuredVideo) {
        try {
          const result = await refreshAnimeVideoFallback(exactFranchise.id, {
            request: {
              signal: withTimeout(controller.signal, 3_200),
              maxRetries: 0,
              timeoutMs: 1_050,
            },
          })
          if (result.updated) {
            const [refreshed] = await getSummaries([exactFranchise.id])
            if (refreshed) Object.assign(exactFranchise, refreshed)
          }
        } catch (error) {
          // A failed metadata fallback must not hide the AniList search result. The queued pass
          // below gets a longer budget and the daily subscriber sweep repairs it independently.
          req.log.warn(
            { event: 'search.anime_video_fallback_failed', franchiseId: exactFranchise.id, error },
            'exact-search anime video fallback failed',
          )
        }
      }
      if (exactFranchise) {
        enqueueFranchiseNewsRefresh(exactFranchise.id, exactFranchise.upcoming)
        enqueueFranchiseEnrichment(exactFranchise.id)
        enqueueAnimeVideoFallback(exactFranchise.id)
      }
      response.franchises = await attachAvailabilityPreviews(
        response.franchises,
        country,
        preferences.providerIds,
        query.providerId,
      )
      if (exactFranchise && country && query.providerId == null) {
        try {
          const availability = await getWatchAvailability(exactFranchise.id, country)
          if (availability) exactFranchise.availability = applyProviderPreferences(availability, preferences.providerIds)
        } catch (error) {
          req.log.warn(
            { event: 'search.availability_refresh_failed', franchiseId: exactFranchise.id, country, error },
            'exact-search availability refresh failed',
          )
        }
      }
      req.log.info({ event: 'search.profile', search: profile, sources: response.sources }, 'search profile')
      return response
    } finally {
      req.raw.removeListener('aborted', abort)
      reply.raw.removeListener('close', abortIfUnsent)
    }
  })

  app.post('/franchises/watch-providers/batch', async (req, reply) => {
    const body = z.object({
      franchiseIds: z.array(z.string().uuid()).min(1).max(100).transform((ids) => [...new Set(ids)]),
      country: countrySchema.optional(),
    }).strict().safeParse(req.body)
    if (!body.success) return reply.code(400).send({ error: 'invalid request' })
    const preferences = await resolveUserPreferences(req.user!.id, body.data.country)
    const country = preferences.country
    if (!country) return reply.code(400).send({ error: 'country is required until a preference is saved' })
    const values = await getWatchAvailabilityBatch(body.data.franchiseIds, country)
    return {
      country,
      availability: body.data.franchiseIds.flatMap((franchiseId) => {
        const value = values.get(franchiseId)
        return value ? [{ franchiseId, ...applyProviderPreferences(value, preferences.providerIds) }] : []
      }),
    }
  })

  app.post('/franchises/resolve', async (req, reply) => {
    const body = z.object({
      source: z.enum(['anilist', 'tmdb']),
      externalId: z.number().int().positive(),
    }).strict().safeParse(req.body)
    if (!body.success) return reply.code(400).send({ error: 'invalid request' })
    try {
      // The database first: a title that already has a show page opens it without the provider
      // round trips (`groupFromSeed` always re-walks AniList, 3–15 s, even for a grouped title).
      const local = await findLocalFranchise(body.data.source, body.data.externalId)
      const franchiseId = local ?? (body.data.source === 'anilist'
        ? (await groupFromSeed(body.data.externalId)).franchiseId
        : (await ensureTvFranchise(body.data.externalId))?.franchiseId)
      if (!franchiseId) return reply.code(422).send({ error: 'title could not be materialized' })
      const [summary] = await getSummaries([franchiseId])
      if (!summary) return reply.code(422).send({ error: 'title could not be materialized' })
      return summary
    } catch (error) {
      req.log.warn({ event: 'franchise.resolve_failed', request: body.data, error }, 'franchise resolve failed')
      return reply.code(422).send({ error: 'title could not be materialized' })
    }
  })

  app.get('/franchises/:id/watch-providers', async (req, reply) => {
    const params = z.object({ id: z.string().uuid() }).safeParse(req.params)
    const query = watchProviderQuery.safeParse(req.query)
    if (!params.success || !query.success) return reply.code(400).send({ error: 'invalid request' })
    const { id } = params.data
    const preferences = await resolveUserPreferences(req.user!.id, query.data.country)
    const country = preferences.country
    if (!country) return reply.code(400).send({ error: 'country is required until a preference is saved' })
    const availability = await getWatchAvailability(id, country)
    if (!availability) return reply.code(404).send({ error: 'franchise not found' })
    return applyProviderPreferences(availability, preferences.providerIds)
  })

  app.get('/franchises/:id/announcements', async (req, reply) => {
    const params = z.object({ id: z.string().uuid() }).safeParse(req.params)
    const query = z.object({ limit: z.coerce.number().int().min(1).max(100).default(20) }).safeParse(req.query)
    if (!params.success || !query.success) return reply.code(400).send({ error: 'invalid request' })
    const [existing] = await getSummaries([params.data.id])
    if (!existing) return reply.code(404).send({ error: 'franchise not found' })
    return { observations: await listAnnouncementObservations(params.data.id, query.data.limit) }
  })

  app.get('/franchises/:id', async (req, reply) => {
    const params = z.object({ id: z.string().uuid() }).safeParse(req.params)
    const query = detailQuery.safeParse(req.query)
    if (!params.success || !query.success) return reply.code(400).send({ error: 'invalid request' })
    const { id } = params.data
    const preferences = await resolveUserPreferences(req.user!.id, query.data.country)
    const country = preferences.country
    let f = await getFranchise(id, req.user!.id, country ?? undefined)
    if (!f) return reply.code(404).send({ error: 'franchise not found' })
    if (f.source === 'anilist' && !f.featuredVideo) {
      try {
        const result = await refreshAnimeVideoFallback(id, {
          request: { signal: withTimeout(undefined, 3_200), maxRetries: 0, timeoutMs: 1_050 },
        })
        if (result.updated) f = await getFranchise(id, req.user!.id, country ?? undefined) ?? f
      } catch (error) {
        req.log.warn(
          { event: 'detail.anime_video_fallback_failed', franchiseId: id, error },
          'anime detail video fallback failed',
        )
      }
    }
    enqueueFranchiseNewsRefresh(id, f.upcoming)
    enqueueFranchiseEnrichment(id)
    enqueueAnimeVideoFallback(id)
    if (country) {
      try {
        const availability = await getWatchAvailability(id, country)
        f.availability = availability ? applyProviderPreferences(availability, preferences.providerIds) : undefined
      } catch (error) {
        req.log.warn({ event: 'detail.availability_refresh_failed', franchiseId: id, country, error }, 'detail availability refresh failed')
      }
    }
    return f
  })
}
