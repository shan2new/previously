import { beforeEach, describe, expect, it, vi } from 'vitest'

// `getRecommendations` resolves the viewer's audience ITSELF (services/audience.ts) and hands it to
// the ranker as a catalogue, so the route, the nightly materialiser and any future caller inherit
// the rule. The ranking under one catalogue is recommendations.test.ts; this is the wiring.

const h = vi.hoisted(() => ({
  audienceSource: vi.fn(),
  rankRecommendations: vi.fn(),
}))

/** An empty library: every query of the loader answers no rows. */
function emptyQuery(): Record<string, unknown> {
  const query: Record<string, unknown> = {}
  for (const method of ['from', 'innerJoin', 'leftJoin', 'where', 'orderBy', 'limit']) query[method] = () => query
  query.then = (resolve: (rows: unknown[]) => unknown) => resolve([])
  return query
}

vi.mock('../db/index.js', () => ({ db: { select: () => emptyQuery() }, sql: {} }))
vi.mock('../env.js', () => ({ env: {} }))
vi.mock('../grouping/service.js', () => ({ groupFromSeed: vi.fn() }))
vi.mock('../tmdb/client.js', () => ({ tmdbEnabled: () => false }))
vi.mock('../tmdb/service.js', () => ({ ensureTvFranchise: vi.fn() }))
vi.mock('./animeVideoFallback.js', () => ({ enqueueAnimeVideoFallback: vi.fn() }))
vi.mock('./franchiseView.js', () => ({ deriveAiredEpisodes: () => 0, getSummaries: async () => [] }))
vi.mock('./recommendationRoots.js', () => ({
  applyFranchiseSeries: vi.fn(),
  franchisesOfMedia: async () => new Map(),
  loadFranchiseSeries: async () => new Map(),
}))
vi.mock('./audience.js', () => ({ audienceSource: h.audienceSource }))
vi.mock('./recommendationRank.js', () => ({ rankRecommendations: h.rankRecommendations }))

const { getRecommendations } = await import('./recommendations.js')

const USER = '11111111-1111-4111-8111-111111111111'
const NOW = Date.UTC(2026, 9, 4, 12)

beforeEach(() => {
  h.audienceSource.mockReset().mockResolvedValue(null)
  h.rankRecommendations.mockReset().mockReturnValue({ items: [] })
})

describe('getRecommendations: the audience', () => {
  it.each([
    ['anime', 'anilist'],
    ['tv', 'tmdb'],
    ['both (or not chosen)', null],
  ] as const)('ranks a %s viewer over %s', async (_audience, source) => {
    h.audienceSource.mockResolvedValue(source)

    expect(await getRecommendations(USER, 12, { now: NOW })).toEqual({ items: [], generatedAt: NOW })

    // The viewer, not the ranking's clock: a job ranking "as of tomorrow" reads today's preference.
    expect(h.audienceSource).toHaveBeenCalledWith(USER)
    expect(h.rankRecommendations).toHaveBeenCalledWith(expect.objectContaining({ now: NOW }), { userId: USER, limit: 12, source })
  })

  it('lets a caller name the catalogue, without reading the preference', async () => {
    h.audienceSource.mockResolvedValue('anilist')

    await getRecommendations(USER, 30, { now: NOW, source: 'tmdb' })
    await getRecommendations(USER, 30, { now: NOW, source: null })

    expect(h.audienceSource).not.toHaveBeenCalled()
    expect(h.rankRecommendations.mock.calls.map((call) => call[1])).toEqual([
      { userId: USER, limit: 30, source: 'tmdb' },
      { userId: USER, limit: 30, source: null },
    ])
  })
})
