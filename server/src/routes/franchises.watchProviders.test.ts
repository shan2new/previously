import Fastify, { type FastifyReply, type FastifyRequest } from 'fastify'
import { beforeEach, describe, expect, it, vi } from 'vitest'

const mocks = vi.hoisted(() => ({
  getWatchAvailability: vi.fn(),
  getFranchise: vi.fn(),
  getSummaries: vi.fn(),
  enqueueFranchiseNewsRefresh: vi.fn(),
  searchFranchises: vi.fn(),
  refreshTvUpcomingFact: vi.fn(),
  enqueueFranchiseEnrichment: vi.fn(),
  refreshAnimeVideoFallback: vi.fn(),
  enqueueAnimeVideoFallback: vi.fn(),
  getAvailabilityPreviews: vi.fn(),
  getWatchAvailabilityBatch: vi.fn(),
  resolveUserPreferences: vi.fn(),
  listAnnouncementObservations: vi.fn(),
  ensureTvFranchise: vi.fn(),
  groupFromSeed: vi.fn(),
  findLocalFranchise: vi.fn(),
}))

/** The caller's stored audience (services/audience.ts reads it for real, from this fake table). */
const viewer = vi.hoisted(() => ({ audience: null as string | null, reads: 0 }))

vi.mock('../db/index.js', () => ({
  db: {
    select: () => ({
      from: () => ({
        where: () => ({
          limit: async () => {
            viewer.reads += 1
            return viewer.audience ? [{ audience: viewer.audience, updatedAt: new Date(0) }] : []
          },
        }),
      }),
    }),
  },
  sql: {},
}))
vi.mock('../services/watchAvailability.js', () => ({
  getWatchAvailability: mocks.getWatchAvailability,
  getAvailabilityPreviews: mocks.getAvailabilityPreviews,
  getWatchAvailabilityBatch: mocks.getWatchAvailabilityBatch,
}))
vi.mock('../services/franchiseView.js', () => ({
  getFranchise: mocks.getFranchise,
  getSummaries: mocks.getSummaries,
  getTrendingFranchises: vi.fn(async () => []),
}))
vi.mock('../news/service.js', () => ({
  enqueueFranchiseNewsRefresh: mocks.enqueueFranchiseNewsRefresh,
  listAnnouncementObservations: mocks.listAnnouncementObservations,
}))
vi.mock('../tmdb/service.js', () => ({
  refreshTvUpcomingFact: mocks.refreshTvUpcomingFact,
  ensureTvFranchise: mocks.ensureTvFranchise,
}))
vi.mock('../grouping/service.js', () => ({ groupFromSeed: mocks.groupFromSeed }))
vi.mock('../services/recommendations.js', () => ({ findLocalFranchise: mocks.findLocalFranchise }))
// This file tests route wiring; the real visibility query is covered by the owned SQL suite.
vi.mock('../services/consumerContent.js', async (original) => ({
  ...await original<typeof import('../services/consumerContent.js')>(),
  consumerFranchiseIds: async (ids: string[]) => new Set(ids),
}))
vi.mock('../services/preferences.js', () => ({
  resolveUserPreferences: mocks.resolveUserPreferences,
  applyProviderPreferences: (value: unknown) => value,
}))
vi.mock('../services/search.js', () => ({
  searchFranchises: mocks.searchFranchises,
}))
vi.mock('../services/catalogEnrichment.js', () => ({
  enqueueFranchiseEnrichment: mocks.enqueueFranchiseEnrichment,
}))
vi.mock('../services/animeVideoFallback.js', () => ({
  refreshAnimeVideoFallback: mocks.refreshAnimeVideoFallback,
  enqueueAnimeVideoFallback: mocks.enqueueAnimeVideoFallback,
}))

const { franchiseRoutes } = await import('./franchises.js')
const ID = '11111111-1111-4111-8111-111111111111'

async function appWithUser() {
  const app = Fastify()
  app.decorate('authenticate', async (req: FastifyRequest, _reply: FastifyReply) => {
    req.user = { id: ID, clerkId: 'user_test' }
  })
  await app.register(franchiseRoutes)
  await app.ready()
  return app
}

beforeEach(() => {
  viewer.audience = null
  viewer.reads = 0
  mocks.getWatchAvailability.mockReset()
  mocks.getFranchise.mockReset()
  mocks.getSummaries.mockReset().mockResolvedValue([])
  mocks.enqueueFranchiseNewsRefresh.mockReset()
  mocks.searchFranchises.mockReset().mockResolvedValue({ franchises: [] })
  mocks.refreshTvUpcomingFact.mockReset().mockResolvedValue(null)
  mocks.enqueueFranchiseEnrichment.mockReset()
  mocks.refreshAnimeVideoFallback.mockReset().mockResolvedValue({
    checked: false,
    matched: false,
    updated: false,
    videos: 0,
  })
  mocks.enqueueAnimeVideoFallback.mockReset()
  mocks.getAvailabilityPreviews.mockReset().mockResolvedValue(new Map())
  mocks.getWatchAvailabilityBatch.mockReset().mockResolvedValue(new Map())
  mocks.resolveUserPreferences.mockReset().mockImplementation(async (_userId: string, country?: string) => ({
    country: country ?? null, language: 'en', providerIds: [], updatedAt: null,
  }))
  mocks.listAnnouncementObservations.mockReset().mockResolvedValue([])
  mocks.ensureTvFranchise.mockReset()
  mocks.groupFromSeed.mockReset()
  mocks.findLocalFranchise.mockReset().mockResolvedValue(null)
  mocks.getWatchAvailability.mockResolvedValue({
    country: 'IN',
    status: 'not_available',
    providers: [],
    link: null,
    attribution: 'JustWatch',
  })
})

describe('GET /search', () => {
  it('ships announcement data on the search result and starts exact-title enrichment there', async () => {
    const upcoming = {
      status: 'upcoming_dated',
      next: 'Season 6',
      release: '2026-12-24',
      note: null,
      source: 'https://www.themoviedb.org/tv/82596',
      checked: '2026-09-02T12:00:00.000Z',
      releaseWindow: { date: '2026-12-24', precision: 'day', sortKey: 20261224 },
    }
    mocks.searchFranchises.mockResolvedValueOnce({
      franchises: [{ id: ID, title: 'Emily in Paris', upcoming }],
      sources: { anilist: 'ok', tmdb: 'ok' },
    })
    const app = await appWithUser()
    const res = await app.inject({ method: 'GET', url: '/search?q=Emily%20in%20Paris' })

    expect(res.statusCode, res.body).toBe(200)
    expect(res.json().franchises[0].upcoming).toEqual(upcoming)
    expect(mocks.enqueueFranchiseNewsRefresh).toHaveBeenCalledWith(ID, upcoming)
    expect(mocks.enqueueFranchiseEnrichment).toHaveBeenCalledWith(ID)
    await app.close()
  })

  it('does not launch research for every fuzzy result while the user is still typing', async () => {
    mocks.searchFranchises.mockResolvedValueOnce({
      franchises: [{ id: ID, title: 'Emily in Paris', upcoming: null }],
    })
    const app = await appWithUser()
    await app.inject({ method: 'GET', url: '/search?q=Emily' })

    expect(mocks.enqueueFranchiseNewsRefresh).not.toHaveBeenCalled()
    await app.close()
  })

  it('passes validated catalogue filters and normalized region into Search 2.0', async () => {
    mocks.searchFranchises.mockResolvedValueOnce({ franchises: [{ id: ID, title: 'Dark Matter' }] })
    const app = await appWithUser()
    const res = await app.inject({
      method: 'GET',
      url: '/search?q=dark&source=tmdb&year=2024&status=FINISHED&theme=Drama&country=in',
    })

    expect(res.statusCode, res.body).toBe(200)
    expect(mocks.searchFranchises).toHaveBeenCalledWith('dark', 30, expect.objectContaining({
      filters: {
        source: 'tmdb', year: 2024, status: 'FINISHED', theme: 'Drama',
        providerId: undefined, country: 'IN',
      },
    }))
    expect(mocks.getAvailabilityPreviews).toHaveBeenCalledWith([ID], 'IN')
    await app.close()
  })

  it('fills a missing exact TMDB announcement before returning the search response', async () => {
    mocks.searchFranchises.mockResolvedValueOnce({
      franchises: [{ id: ID, source: 'tmdb', title: 'Selling Sunset', upcoming: null }],
    })
    mocks.refreshTvUpcomingFact.mockResolvedValueOnce({
      status: 'announced_no_date',
      next: 'Season 10',
      release: 'TBA',
      note: 'TMDB currently lists the series as returning.',
      source: 'https://www.themoviedb.org/tv/87826',
      checked: '2026-09-02T12:00:00.000Z',
    })
    mocks.getSummaries.mockResolvedValueOnce([{ id: ID, source: 'tmdb', title: 'Selling Sunset' }])
    const app = await appWithUser()
    const res = await app.inject({ method: 'GET', url: '/search?q=Selling%20Sunset' })

    expect(res.statusCode, res.body).toBe(200)
    expect(mocks.refreshTvUpcomingFact).toHaveBeenCalledWith(ID, { maxRetries: 0, timeoutMs: 1_050 })
    expect(res.json().franchises[0].upcoming).toMatchObject({
      status: 'announced_no_date',
      next: 'Season 10',
      releaseWindow: { precision: 'unknown', sortKey: null },
    })
    expect(mocks.enqueueFranchiseNewsRefresh).toHaveBeenCalledWith(
      ID,
      expect.objectContaining({ next: 'Season 10' }),
    )
    await app.close()
  })

  it('returns a newly fetched TMDB trailer on the same exact-search response', async () => {
    mocks.searchFranchises.mockResolvedValueOnce({
      franchises: [{ id: ID, source: 'tmdb', title: 'Emily in Paris', upcoming: { next: 'Season 6' }, featuredVideo: null }],
    })
    mocks.refreshTvUpcomingFact.mockResolvedValueOnce({
      status: 'announced_no_date',
      next: 'Season 6',
      release: 'TBA',
      note: null,
      source: 'https://www.themoviedb.org/tv/82596',
      checked: '2026-09-02T12:00:00.000Z',
    })
    mocks.getSummaries.mockResolvedValueOnce([{
      id: ID,
      source: 'tmdb',
      title: 'Emily in Paris',
      featuredVideo: { id: 'ldfEtPf3CfQ', kind: 'announcement', site: 'youtube' },
    }])
    const app = await appWithUser()
    const res = await app.inject({ method: 'GET', url: '/search?q=Emily%20in%20Paris' })

    expect(res.statusCode, res.body).toBe(200)
    expect(mocks.getSummaries).toHaveBeenCalledWith([ID])
    expect(res.json().franchises[0].featuredVideo).toMatchObject({
      id: 'ldfEtPf3CfQ',
      kind: 'announcement',
    })
    await app.close()
  })

  it('returns a conservatively matched anime trailer on the same exact-search response', async () => {
    mocks.searchFranchises.mockResolvedValueOnce({
      franchises: [{ id: ID, source: 'anilist', title: 'Bleach', featuredVideo: null }],
    })
    mocks.refreshAnimeVideoFallback.mockResolvedValueOnce({
      checked: true,
      matched: true,
      updated: true,
      videos: 2,
    })
    mocks.getSummaries.mockResolvedValueOnce([{
      id: ID,
      source: 'anilist',
      title: 'Bleach',
      featuredVideo: { id: 'Px1xodGZAT0', kind: 'trailer', site: 'youtube' },
    }])
    const app = await appWithUser()
    const res = await app.inject({ method: 'GET', url: '/search?q=Bleach' })

    expect(res.statusCode, res.body).toBe(200)
    expect(mocks.refreshAnimeVideoFallback).toHaveBeenCalledWith(ID, {
      request: expect.objectContaining({ maxRetries: 0, timeoutMs: 1_050 }),
    })
    expect(mocks.getSummaries).toHaveBeenCalledWith([ID])
    expect(res.json().franchises[0].featuredVideo).toMatchObject({
      id: 'Px1xodGZAT0',
      kind: 'trailer',
    })
    expect(mocks.enqueueAnimeVideoFallback).toHaveBeenCalledWith(ID)
    await app.close()
  })
  it('does not restore an exact result hidden by its synchronous metadata refresh', async () => {
    mocks.searchFranchises.mockResolvedValueOnce({ franchises: [{ id: ID, source: 'anilist', title: 'Show', featuredVideo: null }] })
    mocks.refreshAnimeVideoFallback.mockResolvedValueOnce({ updated: true })
    mocks.getSummaries.mockResolvedValueOnce([])
    const app = await appWithUser()
    const result = await app.inject('/search?q=Show')
    expect(result.statusCode).toBe(200)
    expect(result.json().franchises).toEqual([])
    expect(mocks.enqueueFranchiseNewsRefresh).not.toHaveBeenCalled()
    await app.close()
  })
})

describe('the audience is the default catalogue of trending and search', () => {
  /** The `source` filter the route handed to Search for one request. */
  const searched = async (url: string) => {
    mocks.searchFranchises.mockClear()
    const app = await appWithUser()
    const res = await app.inject({ method: 'GET', url })
    await app.close()
    expect(res.statusCode, url).toBe(200)
    return mocks.searchFranchises.mock.calls[0]![2].filters.source
  }

  it('searches the viewer\'s own catalogue when the request names none: trending, an empty q and a typed query', async () => {
    for (const [audience, source] of [['anime', 'anilist'], ['tv', 'tmdb'], ['both', undefined], [null, undefined]] as const) {
      viewer.audience = audience
      expect(await searched('/franchises/trending'), `trending ${audience}`).toBe(source)
      expect(await searched('/search'), `search, no q ${audience}`).toBe(source)
      expect(await searched('/search?q=frieren'), `search q ${audience}`).toBe(source)
    }
  })

  it('lets an explicit source win over the audience, without reading the preference', async () => {
    viewer.audience = 'anime'
    expect(await searched('/franchises/trending?source=tmdb')).toBe('tmdb')
    expect(await searched('/search?source=tmdb')).toBe('tmdb')
    expect(await searched('/search?q=severance&source=tmdb')).toBe('tmdb')
    viewer.audience = 'tv'
    expect(await searched('/search?q=frieren&source=anilist')).toBe('anilist')
    expect(viewer.reads).toBe(0)
  })

  it('leaves the routes that name a title alone: detail and resolve never read the audience', async () => {
    viewer.audience = 'anime'
    mocks.getFranchise.mockResolvedValue({ id: ID, source: 'tmdb', title: 'Severance', upcoming: null, featuredVideo: { id: 'v' } })
    mocks.findLocalFranchise.mockResolvedValue(ID)
    mocks.getSummaries.mockResolvedValue([{ id: ID, source: 'tmdb', title: 'Severance' }])
    const app = await appWithUser()
    // An anime viewer opens a TV show's page, and resolves a TV title, as anyone can.
    expect((await app.inject({ method: 'GET', url: `/franchises/${ID}` })).json().source).toBe('tmdb')
    const resolved = await app.inject({ method: 'POST', url: '/franchises/resolve', payload: { source: 'tmdb', externalId: 95396 } })
    expect(resolved.json().source).toBe('tmdb')
    expect(viewer.reads).toBe(0)
    await app.close()
  })
})

describe('GET /franchises/:id', () => {
  it('does not fall back to an older visible detail after refresh hides the title', async () => {
    mocks.getFranchise.mockResolvedValueOnce({ id: ID, source: 'anilist', title: 'Show', featuredVideo: null }).mockResolvedValueOnce(null)
    mocks.refreshAnimeVideoFallback.mockResolvedValueOnce({ updated: true })
    const app = await appWithUser()
    const result = await app.inject(`/franchises/${ID}`)
    expect(result.statusCode).toBe(404)
    expect(result.json()).toEqual({ error: 'franchise not found' })
    expect(mocks.enqueueFranchiseNewsRefresh).not.toHaveBeenCalled()
    await app.close()
  })
  it('returns immediately and schedules stale-while-revalidate news research', async () => {
    const franchise = { id: ID, title: 'Selling Sunset', upcoming: null }
    mocks.getFranchise.mockResolvedValueOnce(franchise)
    const app = await appWithUser()
    const res = await app.inject({ method: 'GET', url: `/franchises/${ID}?country=in` })

    expect(res.statusCode, res.body).toBe(200)
    expect(res.json()).toEqual(franchise)
    expect(mocks.getFranchise).toHaveBeenCalledWith(ID, ID, 'IN')
    expect(mocks.enqueueFranchiseNewsRefresh).toHaveBeenCalledWith(ID, null)
    expect(mocks.enqueueFranchiseEnrichment).toHaveBeenCalledWith(ID)
    await app.close()
  })

  it('rejects a malformed optional rating country', async () => {
    const app = await appWithUser()
    const res = await app.inject({ method: 'GET', url: `/franchises/${ID}?country=India` })

    expect(res.statusCode, res.body).toBe(400)
    expect(mocks.getFranchise).not.toHaveBeenCalled()
    await app.close()
  })

  it('fills a missing anime trailer before returning Detail', async () => {
    const before = { id: ID, source: 'anilist', title: 'Bleach', upcoming: null, featuredVideo: null }
    const after = {
      ...before,
      featuredVideo: { id: 'Px1xodGZAT0', site: 'youtube', kind: 'trailer' },
    }
    mocks.getFranchise.mockResolvedValueOnce(before).mockResolvedValueOnce(after)
    mocks.refreshAnimeVideoFallback.mockResolvedValueOnce({
      checked: true,
      matched: true,
      updated: true,
      videos: 2,
    })
    const app = await appWithUser()
    const res = await app.inject({ method: 'GET', url: `/franchises/${ID}` })

    expect(res.statusCode, res.body).toBe(200)
    expect(res.json().featuredVideo.id).toBe('Px1xodGZAT0')
    expect(mocks.getFranchise).toHaveBeenCalledTimes(2)
    expect(mocks.enqueueAnimeVideoFallback).toHaveBeenCalledWith(ID)
    await app.close()
  })
})

describe('GET /franchises/:id/watch-providers', () => {
  it('normalizes the requested country before lookup', async () => {
    const app = await appWithUser()
    const res = await app.inject({ method: 'GET', url: `/franchises/${ID}/watch-providers?country=in` })

    expect(res.statusCode, res.body).toBe(200)
    expect(mocks.getWatchAvailability).toHaveBeenCalledWith(ID, 'IN')
    expect(res.json().country).toBe('IN')
    await app.close()
  })

  it('rejects a missing or non-ISO-alpha-2 country without touching the provider', async () => {
    const app = await appWithUser()
    const missing = await app.inject({ method: 'GET', url: `/franchises/${ID}/watch-providers` })
    const malformed = await app.inject({ method: 'GET', url: `/franchises/${ID}/watch-providers?country=India` })

    expect(missing.statusCode, missing.body).toBe(400)
    expect(malformed.statusCode, malformed.body).toBe(400)
    expect(mocks.getWatchAvailability).not.toHaveBeenCalled()
    await app.close()
  })

  it('returns 404 when the franchise does not exist', async () => {
    mocks.getWatchAvailability.mockResolvedValueOnce(null)
    const app = await appWithUser()
    const res = await app.inject({ method: 'GET', url: `/franchises/${ID}/watch-providers?country=IN` })

    expect(res.statusCode, res.body).toBe(404)
    expect(res.json()).toEqual({ error: 'franchise not found' })
    await app.close()
  })

  it('uses the saved country when the request omits an override', async () => {
    mocks.resolveUserPreferences.mockResolvedValueOnce({
      country: 'IN', language: 'en', providerIds: [], updatedAt: null,
    })
    const app = await appWithUser()
    const res = await app.inject({ method: 'GET', url: `/franchises/${ID}/watch-providers` })

    expect(res.statusCode, res.body).toBe(200)
    expect(mocks.getWatchAvailability).toHaveBeenCalledWith(ID, 'IN')
    await app.close()
  })
})

describe('POST /franchises/resolve', () => {
  const summary = { id: ID, title: 'Hunter x Hunter (2011)' }

  it('opens a title that already has a show page without asking a provider', async () => {
    mocks.findLocalFranchise.mockResolvedValueOnce(ID)
    mocks.getSummaries.mockResolvedValueOnce([summary])
    const app = await appWithUser()
    const res = await app.inject({ method: 'POST', url: '/franchises/resolve', payload: { source: 'anilist', externalId: 11061 } })

    expect(res.statusCode, res.body).toBe(200)
    expect(res.json()).toEqual(summary)
    expect(mocks.findLocalFranchise).toHaveBeenCalledWith('anilist', 11061)
    expect(mocks.groupFromSeed).not.toHaveBeenCalled()
    expect(mocks.ensureTvFranchise).not.toHaveBeenCalled()
    await app.close()
  })

  it('materialises a title the catalogue has never grouped, per source', async () => {
    mocks.groupFromSeed.mockResolvedValueOnce({ franchiseId: ID, created: true, attached: 0 })
    mocks.ensureTvFranchise.mockResolvedValueOnce({ franchiseId: ID, created: true, attached: 0 })
    mocks.getSummaries.mockResolvedValue([summary])
    const app = await appWithUser()
    const anime = await app.inject({ method: 'POST', url: '/franchises/resolve', payload: { source: 'anilist', externalId: 20832 } })
    const tv = await app.inject({ method: 'POST', url: '/franchises/resolve', payload: { source: 'tmdb', externalId: 63210 } })

    expect(anime.statusCode, anime.body).toBe(200)
    expect(tv.statusCode, tv.body).toBe(200)
    expect(mocks.groupFromSeed).toHaveBeenCalledWith(20832, { fetcher: expect.any(Function) })
    expect(mocks.ensureTvFranchise).toHaveBeenCalledWith(63210, { consumerOnly: true })
    await app.close()
  })

  it('answers 422 when source policy refuses the title', async () => {
    mocks.ensureTvFranchise.mockResolvedValueOnce(null)
    const app = await appWithUser()
    const res = await app.inject({ method: 'POST', url: '/franchises/resolve', payload: { source: 'tmdb', externalId: 106480 } })

    expect(res.statusCode, res.body).toBe(422)
    await app.close()
  })
})
