import type { FastifyPluginAsync } from 'fastify'
import { z } from 'zod'
import { env } from '../env.js'
import { getLibrary } from '../services/franchiseView.js'
import { listNotifications, markNotificationsRead } from '../services/notifications.js'
import {
  franchiseExists,
  FranchiseProgressError,
  markOpened,
  setFranchiseProgress,
  setProgress,
  setSubscriptionStatus,
  subscribe,
  unsubscribe,
} from '../services/library.js'
import { readVisitAnchors } from '../services/visits.js'
import { recordErasure } from '../services/erasure.js'
import { deletionResponse, enqueueDeletion, finishDeletion, lockIdentity, recordAppleRevocation } from '../services/deletionLedger.js'
import { prepareAppleDeletion } from '../services/appleDeletion.js'
import { db } from '../db/index.js'
import type {
  AccountDeletedResponse,
  NotificationsPage,
  RecommendationsResponse,
  WatchSessionsResponse,
} from '../types/api.js'
import { decodeCursor } from '../util/cursor.js'
import { MAX_MEDIA_ID } from '../social/subjects.js'
import { enqueueAnimeVideoFallback } from '../services/animeVideoFallback.js'
import { enqueueRecommendationRefresh } from '../services/catalogEnrichment.js'
import {
  applyProviderPreferences,
  getUserPreferences,
  resolveUserPreferences,
  updateUserPreferences,
} from '../services/preferences.js'
import { getAvailabilityPreviews } from '../services/watchAvailability.js'
import {
  clearRecommendationFeedback,
  getRecommendations,
  recordRecommendationFeedback,
} from '../services/recommendations.js'
import { deleteWatchSession, listWatchSessions, putWatchSession } from '../services/watchSessions.js'
import { ClientMutationError, clientMutationContext } from '../services/clientMutations.js'
import { eraseOwnedAccount } from '../services/accountErasurePlan.js'
export { accountErasurePlan, accountOwnedTableNames, type ErasureParent, type ErasureStep } from '../services/accountErasurePlan.js'

// Board 09's status vocabulary. `subscriptions.status` is a text() column, so the two added
// values need no migration.
const statusEnum = z.enum(['watching', 'completed', 'planned', 'paused', 'dropped'])
/** A recommendation's stable key: `anilist:<series root id>` or `tmdb:<show id>`. */
const recommendationKey = z.string().regex(/^(anilist|tmdb):[1-9][0-9]{0,9}$/)

/** A client ms epoch: 0 ("date unknown") through the year 2100. */
const msEpoch = z.number().int().min(0).max(4_102_444_800_000)
const episodeCount = z.number().int().min(0).max(100_000)
/** PUT /me/watch-sessions/:id. Optional fields default to null, so an older client can omit them. */
const watchSessionBody = z
  .object({
    franchiseId: z.string().uuid(),
    scopeMediaId: z.number().int().min(1).max(MAX_MEDIA_ID).nullish(),
    ordinal: z.number().int().min(1).max(999),
    startedAt: msEpoch.nullish(),
    completedAt: msEpoch.nullish(),
    cancelledAt: msEpoch.nullish(),
    cancelledAtEpisode: episodeCount.nullish(),
    episodes: episodeCount,
    restoreProgress: z
      .record(z.string().regex(/^[1-9][0-9]{0,9}$/), episodeCount)
      .refine((m) => Object.keys(m).length <= 200, 'too many parts')
      .nullish(),
    restoreStatus: statusEnum.nullish(),
  })
  .strict()
  .transform((b) => ({
    franchiseId: b.franchiseId,
    scopeMediaId: b.scopeMediaId ?? null,
    ordinal: b.ordinal,
    startedAt: b.startedAt ?? null,
    completedAt: b.completedAt ?? null,
    cancelledAt: b.cancelledAt ?? null,
    cancelledAtEpisode: b.cancelledAtEpisode ?? null,
    episodes: b.episodes,
    restoreProgress: b.restoreProgress ?? null,
    restoreStatus: b.restoreStatus ?? null,
  }))
const sessionIdParams = z.object({ id: z.string().uuid() })
const countrySchema = z.string().regex(/^[a-z]{2}$/i).transform((value) => value.toUpperCase())
const countryQuery = z.object({ country: countrySchema.optional() })
/** `media.id` and `progress.episodes_watched` are int4: a value past it would be a 500 from Postgres, not a 400. */
const INT4_MAX = 2_147_483_647

// Any id the column can hold is LOOKED UP (absent → 404, which the client treats as final); only a
// value no int4 can hold is a bad body.
const progressBody = z
  .object({
    mediaId: z.number().int().min(-MAX_MEDIA_ID - 1).max(MAX_MEDIA_ID),
    episodes: z.number().int().min(0).max(INT4_MAX),
  })
  .strict()

const notificationsQuery = z
  .object({
    limit: z.coerce.number().int().min(1).max(200).default(50),
    cursor: z.string().max(400).optional(),
  })
  .strict()

const notificationsReadBody = z.object({ ids: z.array(z.string().uuid()).max(500).optional() }).strict()

const progressCommand = z.union([
  z.object({
    mode: z.enum(['caught_up', 'completed', 'reset']),
    status: statusEnum.optional(),
  }).strict(),
  z.object({
    parts: z.array(z.object({
      mediaId: z.number().int(),
      episodes: z.number().int().min(0),
    }).strict()).max(200),
    status: statusEnum.optional(),
  }).strict(),
])

export const meRoutes: FastifyPluginAsync = async (app) => {
  app.addHook('preHandler', app.authenticate)
  app.setErrorHandler((error, _req, reply) => {
    if (error instanceof ClientMutationError) return reply.code(error.statusCode).send({ error: error.message })
    throw error
  })

  app.get('/me/library', async (req, reply) => {
    const query = countryQuery.safeParse(req.query)
    if (!query.success) return reply.code(400).send({ error: 'invalid request' })
    const userId = req.user!.id
    // The PREVIOUS visit (what `POST /me/opened` shifted away), never the stamp this session just
    // wrote: `newParts` and the client's "new" both compare against it (services/visits.ts).
    const { prevOpenedAt } = await readVisitAnchors(userId)
    const franchises = await getLibrary(userId, prevOpenedAt)
    const preferences = await resolveUserPreferences(userId, query.data.country)
    const country = preferences.country
    if (country) {
      const availability = await getAvailabilityPreviews(franchises.map((item) => item.id), country)
      for (const item of franchises) {
        const value = availability.get(item.id)
        if (value) item.availability = applyProviderPreferences(value, preferences.providerIds)
      }
    }
    return { franchises, prevOpenedAt }
  })

  app.get('/me/preferences', async (req) => getUserPreferences(req.user!.id))

  app.put('/me/preferences', async (req, reply) => {
    const body = z.object({
      country: countrySchema.nullable().optional(),
      language: z.string().trim().min(2).max(35).optional(),
      providerIds: z.array(z.number().int().positive()).max(50)
        .transform((ids) => [...new Set(ids)]).optional(),
      // Which catalogue the server suggests titles from (services/audience.ts). Omitted = unchanged.
      audience: z.enum(['anime', 'tv', 'both']).optional(),
    }).strict().parse(req.body)
    const result = await updateUserPreferences(req.user!.id, body)
    // The audience has its own table, which a not-yet-applied migration creates: the other fields
    // ARE saved, and the client is told this one was not rather than shown a choice that never took.
    if (!result.ok) return reply.code(503).send({ error: result.error })
    return result.preferences
  })

  // "Recommended for you" — second-degree picks out of the user's own library, deterministic for
  // (user, UTC day). See services/recommendationRank.ts and docs/api-contract.md.
  app.get('/me/recommendations', async (req, reply) => {
    const query = z.object({ limit: z.coerce.number().int().min(1).max(30).default(12) }).safeParse(req.query)
    if (!query.success) return reply.code(400).send({ error: 'invalid request' })
    const body: RecommendationsResponse = await getRecommendations(req.user!.id, query.data.limit)
    return body
  })

  app.post('/me/recommendations/feedback', async (req, reply) => {
    const body = z.object({
      key: recommendationKey,
      kind: z.enum(['dismissed', 'seen']),
    }).strict().safeParse(req.body)
    if (!body.success) return reply.code(400).send({ error: 'invalid request' })
    await recordRecommendationFeedback(req.user!.id, body.data.key, body.data.kind)
    return reply.code(204).send()
  })

  // Undo of either verdict.
  app.delete('/me/recommendations/feedback', async (req, reply) => {
    const body = z.object({ key: recommendationKey }).strict().safeParse(req.body)
    if (!body.success) return reply.code(400).send({ error: 'invalid request' })
    await clearRecommendationFeedback(req.user!.id, body.data.key)
    return reply.code(204).send()
  })

  // Watch sessions — the first watch and every rewatch — kept so the history survives a new phone.
  app.get('/me/watch-sessions', async (req) => {
    const body: WatchSessionsResponse = { sessions: await listWatchSessions(req.user!.id) }
    return body
  })

  // The whole session, client-generated id. Idempotent; a deleted id stays deleted (410).
  app.put('/me/watch-sessions/:id', async (req, reply) => {
    const params = sessionIdParams.safeParse(req.params)
    const body = watchSessionBody.safeParse(req.body)
    if (!params.success || !body.success) return reply.code(400).send({ error: 'invalid request' })
    const context = clientMutationContext(req)
    const result = await putWatchSession(req.user!.id, params.data.id, body.data, context)
    if (context.stamp && (result === 'saved' || result === 'superseded')) {
      reply.header('X-Previously-Applied', result === 'saved' ? 'true' : 'false')
    }
    switch (result) {
      case 'saved':
      case 'superseded':
        return reply.code(204).send()
      case 'deleted':
        return reply.code(410).send({ error: 'session deleted' })
      case 'franchise_not_found':
        return reply.code(404).send({ error: 'franchise not found' })
      case 'not_found':
        return reply.code(404).send({ error: 'session not found' })
    }
  })

  app.delete('/me/watch-sessions/:id', async (req, reply) => {
    const params = sessionIdParams.safeParse(req.params)
    if (!params.success) return reply.code(400).send({ error: 'invalid request' })
    const context = clientMutationContext(req)
    const applied = await deleteWatchSession(req.user!.id, params.data.id, context)
    if (context.stamp) reply.header('X-Previously-Applied', applied ? 'true' : 'false')
    return reply.code(204).send()
  })

  app.post('/me/subscriptions', async (req, reply) => {
    const body = z.object({ franchiseId: z.string().uuid(), status: statusEnum.optional() }).parse(req.body)
    if (!(await franchiseExists(body.franchiseId))) return reply.code(404).send({ error: 'franchise not found' })
    const context = clientMutationContext(req)
    const applied = await subscribe(req.user!.id, body.franchiseId, body.status, context)
    if (applied) enqueueAnimeVideoFallback(body.franchiseId)
    // A newly followed show votes at once, not after the next weekly enrichment.
    if (applied) enqueueRecommendationRefresh(body.franchiseId)
    return { ok: true, ...(context.stamp ? { applied } : {}) }
  })

  app.patch('/me/subscriptions/:franchiseId', async (req) => {
    const { franchiseId } = z.object({ franchiseId: z.string().uuid() }).parse(req.params)
    const { status } = z.object({ status: statusEnum }).parse(req.body)
    const context = clientMutationContext(req)
    const applied = await setSubscriptionStatus(req.user!.id, franchiseId, status, context)
    return { ok: true, ...(context.stamp ? { applied } : {}) }
  })

  app.delete('/me/subscriptions/:franchiseId', async (req) => {
    const { franchiseId } = z.object({ franchiseId: z.string().uuid() }).parse(req.params)
    const context = clientMutationContext(req)
    const applied = await unsubscribe(req.user!.id, franchiseId, context)
    return { ok: true, ...(context.stamp ? { applied } : {}) }
  })

  // The count is clamped (services/aired.ts): a RELEASING part to what has aired by now, a
  // NOT_YET_RELEASED one to 0. An unknown media id writes nothing and is FINAL — the client drops
  // the pending write instead of retrying it forever.
  app.put('/me/progress', async (req, reply) => {
    const body = progressBody.safeParse(req.body)
    if (!body.success) return reply.code(400).send({ error: 'invalid request' })
    const context = clientMutationContext(req)
    const result = await setProgress(req.user!.id, body.data.mediaId, body.data.episodes, context)
    if (!result.ok) return reply.code(404).send({ error: 'media not found' })
    return { ok: true, ...(context.stamp ? { applied: result.applied } : {}) }
  })

  app.put('/me/franchises/:franchiseId/progress', async (req, reply) => {
    const params = z.object({ franchiseId: z.string().uuid() }).safeParse(req.params)
    const body = progressCommand.safeParse(req.body)
    if (!params.success || !body.success) return reply.code(400).send({ error: 'invalid request' })
    try {
      return await setFranchiseProgress(req.user!.id, params.data.franchiseId, body.data, clientMutationContext(req))
    } catch (error) {
      if (error instanceof FranchiseProgressError) {
        return reply.code(error.reason === 'not_found' ? 404 : 400).send({ error: error.message })
      }
      throw error
    }
  })

  app.post('/me/opened', async (req) => {
    const prevOpenedAt = await markOpened(req.user!.id)
    return { prevOpenedAt }
  })

  app.get('/me/notifications', async (req, reply) => {
    const query = notificationsQuery.safeParse(req.query)
    if (!query.success) return reply.code(400).send({ error: 'invalid request' })
    // `?cursor=` with nothing after it is the first page; anything else must be a cursor we wrote.
    const raw = query.data.cursor
    const cursor = raw ? decodeCursor(raw) : null
    if (raw && !cursor) return reply.code(400).send({ error: 'invalid request' })
    const page: NotificationsPage = await listNotifications(req.user!.id, {
      limit: query.data.limit,
      cursor,
      // With comments switched off the social kinds (reply, like_comment) are not listed at all.
      includeSocial: env.SOCIAL_COMMENTS_ENABLED,
    })
    return page
  })

  app.post('/me/notifications/read', async (req, reply) => {
    // ids omitted → mark everything unread as read.
    const body = notificationsReadBody.safeParse(req.body ?? {})
    if (!body.success) return reply.code(400).send({ error: 'invalid request' })
    const marked = await markNotificationsRead(req.user!.id, body.data.ids)
    return { marked }
  })

  // In-app account deletion — App Store guideline 5.1.1(v). The client confirms; this is the
  // point of no return, so it must actually erase, not deactivate.
  //
  // Every user-owned row is deleted EXPLICITLY (`accountErasurePlan`, below) rather than left to
  // the `onDelete: 'cascade'` declared on each foreign key. The cascade is real and is asserted by
  // `me.account.test.ts`, but a database restored from a dump, or a table added later without one,
  // would turn "delete my account" into "orphan my rows" — and a deletion route that silently leaves
  // a user's progress, comments or likes behind is the failure the guideline exists to prevent. The
  // whole erasure runs in one transaction: a half-deleted account is worse than either outcome.
  //
  // A suspended account can still call this (auth/clerk.ts): deletion must stay reachable. The ban
  // row itself (`moderation_bans`, keyed on the Clerk id) is the one disclosed retention, so
  // deleting and signing back in does not lift a ban.
  //
  // Only once the transaction has COMMITTED (services/erasure.ts): the Clerk id is held for 15
  // minutes (`authenticate` answers `401 account deleted`, so the app's in-flight writes cannot
  // re-create the account on a still-valid JWT), and the Clerk identity is deleted — or, for a
  // suspended one, banned in Clerk. A Clerk failure does not undo the erasure: it is logged
  // (`account.clerk_delete_failed`) for `npm run moderation -- clerk-delete <clerkId>`.
  app.delete('/me', async (req, reply) => {
    // Fresh Apple proof belongs only to this authenticated deletion request. Never persist it.
    const request = z.object({ apple: z.object({ identityToken: z.string().max(16_384).optional(),
      authorizationCode: z.string().max(8_192).optional() }).strict().optional() }).strict().safeParse(req.body ?? {})
    if (!request.success) {
      return reply.code(400).send({ error: 'unexpected body' })
    }
    const userId = req.user!.id
    const clerkId = req.user!.clerkId
    const apple = await prepareAppleDeletion(clerkId, request.data.apple)
    await db.transaction(async (tx) => {
      await lockIdentity(tx, clerkId)
      await enqueueDeletion(tx, clerkId, apple.initial)
      await eraseOwnedAccount(tx, userId)
    })
    recordErasure(clerkId)
    const appleRevocation = await apple.finish()
    if (appleRevocation !== apple.initial) {
      try { await recordAppleRevocation(clerkId, appleRevocation) }
      catch { req.log.warn({ event: 'account.apple_outcome_persistence_failed' }) }
    }
    const ledger = await finishDeletion(clerkId, req.log)
    const body: AccountDeletedResponse = deletionResponse(ledger ?? { completedAt: null })
    return reply.code(body.deleted ? 200 : 202).send(body)
  })
  // authenticate answers this before any user upsert; reconciliation never creates an account.
  app.get('/me/deletion', async () => ({ deleted: false, status: 'active' }))
}
