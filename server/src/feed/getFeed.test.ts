import { beforeEach, describe, expect, it, vi } from 'vitest'
import type { FeedTime, Franchise, FranchisePart, FranchiseSummary, FranchiseVideo, RecommendationReason } from '../types/api.js'
import type { ComposedPost, ComposeInput } from './compose.js'

// `getFeed` per request (docs/api-contract.md, "Today feed"): anchors → hides → the composed posts
// minus owned, muted and hidden ones → order → cap → the viewer's social state → author rows. The
// composer is stubbed (feed/compose.test.ts covers it), and so are the recommender's loader and
// ranker (services/recommendations.test.ts); `orderPosts`, `rankForYou` (feed/forYou.test.ts) and
// `toFeedFranchise` are real.

const mocks = vi.hoisted(() => ({
  subRows: [] as { franchiseId: string }[],
  /** franchise_member rows a post id resolves through (`franchiseIdForPost`). */
  memberRows: [] as { franchiseId: string }[],
  composePosts: vi.fn(),
  getFeedFranchises: vi.fn(),
  getSummaries: vi.fn(),
  trendingFranchiseIds: vi.fn(),
  readVisitAnchors: vi.fn(),
  loadResearchHistory: vi.fn(),
  loadHides: vi.fn(),
  loadPostSocial: vi.fn(),
  firstActivityAt: vi.fn(),
  loadRankInput: vi.fn(),
  rankRecommendations: vi.fn(),
  resolveAudience: vi.fn(),
}))

vi.mock('../db/index.js', () => {
  const chain = {
    from: () => chain,
    where: () => chain,
    orderBy: () => Promise.resolve(mocks.subRows),
    limit: () => Promise.resolve(mocks.memberRows),
  }
  return { db: { select: () => chain }, sql: {} }
})
vi.mock('../env.js', () => ({ env: { SOCIAL_COMMENTS_ENABLED: true } }))
vi.mock('../services/franchiseView.js', () => ({
  getFeedFranchises: mocks.getFeedFranchises,
  getSummaries: mocks.getSummaries,
  trendingFranchiseIds: mocks.trendingFranchiseIds,
}))
// Only the loader: anything else of the recommender's (its materialisation queue above all) is
// undefined here, so a feed that reached for it would throw.
vi.mock('../services/recommendations.js', () => ({ loadRankInput: mocks.loadRankInput }))
vi.mock('../services/recommendationRank.js', async (importOriginal) => ({
  ...(await importOriginal<typeof import('../services/recommendationRank.js')>()),
  rankRecommendations: mocks.rankRecommendations,
}))
// The viewer's stored audience; `sourceFor` and `inAudience` are the real rule.
vi.mock('../services/audience.js', async (importOriginal) => ({
  ...(await importOriginal<typeof import('../services/audience.js')>()),
  resolveAudience: mocks.resolveAudience,
}))
vi.mock('../services/visits.js', async (importOriginal) => ({
  ...(await importOriginal<typeof import('../services/visits.js')>()),
  readVisitAnchors: mocks.readVisitAnchors,
}))
vi.mock('./history.js', () => ({ loadResearchHistory: mocks.loadResearchHistory }))
vi.mock('./viewerState.js', async (importOriginal) => ({
  ...(await importOriginal<typeof import('./viewerState.js')>()),
  loadHides: mocks.loadHides,
  loadPostSocial: mocks.loadPostSocial,
  firstActivityAt: mocks.firstActivityAt,
}))
vi.mock('./compose.js', async (importOriginal) => ({
  ...(await importOriginal<typeof import('./compose.js')>()),
  composePosts: mocks.composePosts,
}))

import { FEED_LIMITS, getFeed, getPostDetail } from './service.js'

const D = 86_400_000
const H = 3_600_000
const USER = 'user-1'
const [OWNED, MUTED, F3, F4, PICK, TV1, TV2, TV_PICK] = [
  '11111111-1111-4111-8111-111111111111',
  '22222222-2222-4222-8222-222222222222',
  '33333333-3333-4333-8333-333333333333',
  '44444444-4444-4444-8444-444444444444',
  '55555555-5555-4555-8555-555555555555',
  '66666666-6666-4666-8666-666666666666',
  '77777777-7777-4777-8777-777777777777',
  '88888888-8888-4888-8888-888888888888',
]
/** The TV shows (`source: 'tmdb'`); every other fixture show is anime. */
const TV: ReadonlySet<string> = new Set([TV1, TV2, TV_PICK])
const sourceOf = (id: string) => (TV.has(id) ? 'tmdb' : 'anilist')

// For you is cached per process for 10 minutes: every test composes at its own hour.
let clock = Date.UTC(2026, 8, 25, 12)
const nextNow = () => (clock += H)

/** A measured, TMDB-grade poster: what makes a post without a video worth a For you slot. */
const SHARP_POSTER = { url: 'https://img.example/p.jpg', source: 'tmdb', width: 2000, height: 3000, language: null, score: null } as const

function franchise(id: string, genres: string[] = [], overrides: Partial<Franchise> = {}): Franchise {
  return {
    id,
    source: sourceOf(id),
    genres,
    title: `Show ${id.slice(0, 1)}`,
    cover: '',
    banner: '',
    images: { portrait: null, landscape: null },
    artwork: { portraits: [SHARP_POSTER], landscapes: [], logos: [] },
    year: 2026,
    isReleasing: false,
    upcoming: null,
    subscription: null,
    featuredVideo: null,
    parts: [],
    videos: [],
    ...overrides,
  } as unknown as Franchise
}

/** An official trailer published at `publishedAt` (ms). */
function trailer(id: string, publishedAt: number): FranchiseVideo {
  return {
    id,
    site: 'YouTube',
    kind: 'trailer',
    title: 'Official Trailer',
    url: `https://www.youtube.com/watch?v=${id}`,
    thumbnail: null,
    official: true,
    language: 'en',
    country: null,
    publishedAt: new Date(publishedAt).toISOString(),
    scope: { type: 'franchise' },
  }
}

/** Season 2 (media 21) on air: episode 7 aired two days ago, episode 8 airs in five. */
function airingPart(now: number): FranchisePart {
  return {
    mediaId: 21,
    kind: 'season',
    sequence: 1,
    watchOrder: 1,
    relationship: null,
    optional: false,
    label: 'Season 2',
    title: 'Show 3 Season 2',
    cover: '',
    banner: '',
    images: { portrait: null, landscape: null },
    artwork: { portraits: [], landscapes: [], logos: [] },
    format: 'TV',
    status: 'RELEASING',
    isReleasing: true,
    totalEpisodes: 12,
    airedEpisodes: 7,
    nextEpisodeNumber: 8,
    nextAiringAt: now + 5 * D,
    airings: [{ episode: 7, at: now - 2 * D }, { episode: 8, at: now + 5 * D }],
    videos: [],
  } as unknown as FranchisePart
}

function post(id: string, franchiseId: string, at: number, discoveredAt = 0): ComposedPost {
  const time: FeedTime = { at, dateOnly: false, basis: 'observed' }
  return {
    id,
    kind: 'announced',
    origin: 'research',
    franchiseId,
    installment: 'Season 2',
    isMovie: false,
    part: null,
    episode: null,
    time,
    discoveredAt,
    premiere: null,
    window: null,
    note: null,
    video: null,
    sources: [],
    isOfficial: false,
    thread: [],
  }
}

function loaded(ids: string[], status: Record<string, string> = {}, genres: Record<string, string[]> = {}) {
  return {
    franchises: ids.map((id) => franchise(id, genres[id])),
    memberAddedAt: new Map(),
    externalIdById: new Map(),
    statusById: new Map(Object.entries(status)),
  }
}

/** The recommender's loader and ranker for one viewer: their library and the picks out of it. */
function recommender(
  seeds: { genres: string[] }[],
  picks: { franchiseId: string | null; reason: RecommendationReason }[],
) {
  mocks.loadRankInput.mockResolvedValue({
    input: {
      now: 0,
      seeds: seeds.map((seed) => ({ source: 'anilist', status: 'completed', watchedEpisodes: 12, airedEpisodes: 12, ...seed })),
      edges: [],
      targets: [],
      feedback: [],
    },
    series: new Map(),
  })
  mocks.rankRecommendations.mockReturnValue({ items: picks })
}

beforeEach(() => {
  mocks.subRows = [{ franchiseId: OWNED }, { franchiseId: MUTED }]
  mocks.memberRows = []
  mocks.composePosts.mockReset()
  mocks.getFeedFranchises.mockReset().mockImplementation(async (ids: string[]) => loaded(ids, { [OWNED]: 'watching' }))
  mocks.getSummaries.mockReset().mockImplementation(async (ids: string[]) => ids.map((id) => ({ id, source: sourceOf(id) }) as FranchiseSummary))
  // Not chosen: both catalogues, the feed as it was before the audience existed.
  mocks.resolveAudience.mockReset().mockResolvedValue('both')
  mocks.trendingFranchiseIds.mockReset().mockResolvedValue([OWNED, MUTED, F3, F4])
  mocks.loadResearchHistory.mockReset().mockResolvedValue({ observations: new Map(), announcements: new Map() })
  mocks.loadHides.mockReset().mockResolvedValue({ posts: new Set(['news:hidden']), shows: new Set([MUTED]) })
  mocks.loadPostSocial.mockReset().mockImplementation(async (_user: string, ids: string[]) =>
    new Map(ids.map((id) => [id, { viewer: { liked: id === 'news:f4', saved: false, reminded: false }, counts: { likes: 2, comments: 1 } }])))
  // A library the recommender has nothing to say about: For you is the trending feed in time order.
  mocks.loadRankInput.mockReset()
  mocks.rankRecommendations.mockReset()
  recommender([], [])
})

describe('getFeed: For you', () => {
  it('drops owned, muted and hidden posts, orders by time alone with nothing fresh, and attaches social state', async () => {
    const now = nextNow()
    const prev = now - D
    mocks.readVisitAnchors.mockResolvedValue({ prevOpenedAt: prev, lastOpenedAt: now - H })
    mocks.composePosts.mockReturnValue([
      post('news:owned', OWNED, now - H, now - H),
      post('news:muted', MUTED, now - H, now - H),
      // Learned since the previous visit, but For you has no fresh block: it sorts by its time.
      post('news:f3', F3, now - 3 * D, now - H),
      post('news:hidden', F3, now - 2 * H, now - H),
      post('news:f4', F4, now - D, 0),
    ])

    const res = await getFeed(USER, 'foryou', now)

    expect(res.tab).toBe('foryou')
    expect(res.prevOpenedAt).toBe(prev)
    expect(res.posts.map((p) => [p.id, p.fresh, p.context])).toEqual([['news:f4', false, null], ['news:f3', false, null]])
    expect(mocks.loadPostSocial).toHaveBeenCalledWith(USER, ['news:f4', 'news:f3'])
    expect(res.posts[0]).toMatchObject({ viewer: { liked: true }, counts: { likes: 2, comments: 1 } })
    expect(res.posts[0]).not.toHaveProperty('thread')
    // Author rows for exactly the referenced shows, none of them in the viewer's library.
    expect(res.franchises.map((f) => [f.id, f.status])).toEqual([[F4, null], [F3, null]])
    expect(res.trending.map((s) => s.id)).toEqual([F3, F4])
    // The composition is the viewer-independent one: trending shows, no user id.
    expect(mocks.getFeedFranchises).toHaveBeenCalledWith([OWNED, MUTED, F3, F4], null)
  })

  it('caps at 20 posts, newest first', async () => {
    const now = nextNow()
    mocks.readVisitAnchors.mockResolvedValue({ prevOpenedAt: 0, lastOpenedAt: 0 })
    mocks.composePosts.mockReturnValue(
      Array.from({ length: 60 }, (_, i) => post(`news:n${String(i).padStart(2, '0')}`, F3, now - i * H)),
    )

    const res = await getFeed(USER, 'foryou', now)

    expect(FEED_LIMITS.forYou).toBe(20)
    expect(res.posts).toHaveLength(20)
    expect(res.posts[0]?.id).toBe('news:n00')
    expect(res.posts.at(-1)?.id).toBe('news:n19')
  })

  it('never serves more than 20 when the feed is personal, one show each', async () => {
    const now = nextNow()
    mocks.readVisitAnchors.mockResolvedValue({ prevOpenedAt: 0, lastOpenedAt: 0 })
    recommender([{ genres: ['Action'] }], [])
    const shows = Array.from({ length: 30 }, (_, i) => `aaaaaaaa-aaaa-4aaa-8aaa-${String(i).padStart(12, '0')}`)
    mocks.trendingFranchiseIds.mockResolvedValue(shows)
    mocks.getFeedFranchises.mockImplementation(async (ids: string[]) => loaded(ids, {}, Object.fromEntries(ids.map((id) => [id, ['Action']]))))
    // Two posts a show: sixty candidates, every one a full match.
    mocks.composePosts.mockReturnValue(
      shows.flatMap((id, i) => [post(`news:a${String(i).padStart(2, '0')}`, id, now - i * H), post(`news:b${String(i).padStart(2, '0')}`, id, now - i * H - 60_000)]),
    )

    const res = await getFeed(USER, 'foryou', now)

    expect(res.posts).toHaveLength(20)
    expect(new Set(res.posts.map((p) => p.franchiseId)).size).toBe(20)
    expect(res.posts.every((p) => p.id.startsWith('news:a'))).toBe(true)
    expect(res.franchises).toHaveLength(20)
  })

  it('gives a recommended show its trailer whatever its age, and keeps what the ranker read off the wire', async () => {
    const now = nextNow()
    mocks.readVisitAnchors.mockResolvedValue({ prevOpenedAt: 0, lastOpenedAt: 0 })
    const reason: RecommendationReason = { kind: 'watching', seeds: [{ franchiseId: OWNED, title: 'Show 1' }], count: 1 }
    recommender([{ genres: ['Action'] }], [{ franchiseId: PICK, reason }, { franchiseId: F3, reason }])
    // Three years old: far past the feed's 200-day trailer horizon and the 240-day age limit.
    const old = now - 1100 * D
    // PICK is outside the trending snapshot; F3 is a pick the snapshot carries, with no post there.
    mocks.getFeedFranchises.mockImplementation(async (ids: string[]) => ({
      ...loaded(ids),
      franchises: ids.map((id) => franchise(id, ['Action'], id === PICK ? { videos: [trailer('pick0000001', old)] } : id === F3 ? { videos: [trailer('three000001', old)] } : {})),
    }))
    mocks.composePosts.mockImplementation((input: ComposeInput) =>
      input.franchises.some((f) => f.id === PICK) ? [] : [post('news:f4', F4, now - 2 * D)])

    const res = await getFeed(USER, 'foryou', now)

    // The first pick's trailer leads (0.5 + 0.3); this week's news about a show in the viewer's
    // genres (0.3 + 0.485) sits between it and the last pick's trailer (0.35 + 0.3): trailers mix
    // with the news, they do not fill the list.
    expect(res.posts.map((p) => [p.id, p.kind, p.context?.kind])).toEqual([
      [`trailer:${PICK}:youtube:pick0000001`, 'trailer', 'recommended'],
      ['news:f4', 'announced', 'taste'],
      [`trailer:${F3}:youtube:three000001`, 'trailer', 'recommended'],
    ])
    // Honestly dated, and exactly the wire shape: the ranker's flags never leave the server.
    expect(res.posts[0]).toMatchObject({ time: { at: now - 1100 * D, basis: 'published' }, video: { id: 'pick0000001' }, fresh: false })
    for (const p of res.posts) {
      expect(p).not.toHaveProperty('evergreen')
      expect(p).not.toHaveProperty('sharp')
      expect(p).not.toHaveProperty('thread')
    }
    expect(res.franchises.map((f) => [f.id, f.status])).toEqual([[PICK, null], [F4, null], [F3, null]])
  })

  it('leaves a post with no video and no sharp picture out once 20 better ones fit', async () => {
    const now = nextNow()
    mocks.readVisitAnchors.mockResolvedValue({ prevOpenedAt: 0, lastOpenedAt: 0 })
    recommender([{ genres: ['Action'] }], [])
    const shows = Array.from({ length: 21 }, (_, i) => `bbbbbbbb-bbbb-4bbb-8bbb-${String(i).padStart(12, '0')}`)
    const blurred = shows[0]!
    mocks.trendingFranchiseIds.mockResolvedValue(shows)
    // The first show has only AniList's cover (unmeasured); it also has the newest post.
    const cover = { url: 'https://img.example/c.jpg', source: 'anilist', width: null, height: null, language: null, score: null } as const
    mocks.getFeedFranchises.mockImplementation(async (ids: string[]) => ({
      ...loaded(ids),
      franchises: ids.map((id) => franchise(id, ['Action'], id === blurred ? { artwork: { portraits: [cover], landscapes: [], logos: [] } } : {})),
    }))
    mocks.composePosts.mockReturnValue(shows.map((id, i) => post(`news:s${String(i).padStart(2, '0')}`, id, now - i * H)))

    const res = await getFeed(USER, 'foryou', now)

    expect(res.posts).toHaveLength(20)
    expect(res.posts.map((p) => p.id)).not.toContain('news:s00')
    expect(res.posts[0]?.id).toBe('news:s01')
  })

  it('leads with a recommended show\'s post and says why each post is there', async () => {
    const now = nextNow()
    mocks.readVisitAnchors.mockResolvedValue({ prevOpenedAt: now - D, lastOpenedAt: now - H })
    const reason: RecommendationReason = { kind: 'finished', seeds: [{ franchiseId: OWNED, title: 'Show 1' }], count: 1 }
    // The viewer's library is all Action. The recommender picks a show outside the trending
    // snapshot, one with no show page yet (never composed), and one the viewer has muted.
    recommender([{ genres: ['Action'] }], [
      { franchiseId: PICK, reason },
      { franchiseId: null, reason },
      { franchiseId: MUTED, reason },
    ])
    mocks.getFeedFranchises.mockImplementation(async (ids: string[]) => loaded(ids, {}, { [F3]: ['Action'], [F4]: ['Horror'] }))
    mocks.composePosts.mockImplementation((input: ComposeInput) =>
      input.franchises.some((f) => f.id === PICK)
        ? [post('news:pick', PICK, now - 20 * D)]
        : [
            post('news:muted', MUTED, now - H),
            post('news:f4', F4, now - H),
            post('news:f3', F3, now - 2 * D),
          ])

    const res = await getFeed(USER, 'foryou', now)

    // The pick leads although it is the oldest news; then the show that matches the library; the
    // newest post, about a show the library does not touch, comes last.
    expect(res.posts.map((p) => [p.id, p.fresh, p.context])).toEqual([
      ['news:pick', false, { kind: 'recommended', reason }],
      ['news:f3', false, { kind: 'taste', genres: ['Action'] }],
      ['news:f4', false, null],
    ])
    expect(res.franchises.map((f) => [f.id, f.status])).toEqual([[PICK, null], [F3, null], [F4, null]])
    expect(res.trending.map((s) => s.id)).toEqual([F3, F4])
    // Read through the loader and the pure ranker, for this viewer, at the request's instant; the
    // muted pick is in the snapshot already, so only the one outside it is composed.
    expect(mocks.loadRankInput).toHaveBeenCalledWith(USER, now)
    expect(mocks.rankRecommendations).toHaveBeenCalledWith(expect.anything(), { userId: USER, limit: 40, rotation: false, source: null })
    expect(mocks.getFeedFranchises).toHaveBeenCalledWith([PICK], null)
    expect(mocks.loadResearchHistory).toHaveBeenCalledWith([PICK])

    // Within the 10 minutes the viewer's part is served from memory, like the snapshot.
    await getFeed(USER, 'foryou', now + 60_000)
    expect(mocks.loadRankInput).toHaveBeenCalledTimes(1)
    expect(mocks.getFeedFranchises).toHaveBeenCalledTimes(2)
  })

  it('serves the trending feed in time order when the recommender fails', async () => {
    const now = nextNow()
    mocks.readVisitAnchors.mockResolvedValue({ prevOpenedAt: 0, lastOpenedAt: 0 })
    mocks.loadRankInput.mockRejectedValue(new Error('recommendation_edges is gone'))
    const warn = vi.spyOn(console, 'warn').mockImplementation(() => {})
    mocks.composePosts.mockReturnValue([post('news:f3', F3, now - 3 * D), post('news:f4', F4, now - D)])

    const res = await getFeed(USER, 'foryou', now)

    expect(res.posts.map((p) => [p.id, p.context])).toEqual([['news:f4', null], ['news:f3', null]])
    expect(res.trending.map((s) => s.id)).toEqual([F3, F4])
    expect(warn).toHaveBeenCalledOnce()
    warn.mockRestore()
  })
})

describe('getFeed: For you and the audience', () => {
  const reason: RecommendationReason = { kind: 'finished', seeds: [{ franchiseId: OWNED, title: 'Show 1' }], count: 1 }
  /** One post per franchise the composer is handed, so every loaded show would reach the feed. */
  const postEveryShow = (now: number) =>
    mocks.composePosts.mockImplementation((input: ComposeInput) => input.franchises.map((f) => post(`news:${f.id.slice(0, 2)}`, f.id, now - H)))
  /**
   * A pool and a recommender that LEAK: the trending ranking answers anime and TV whatever
   * catalogue it is asked for, and the ranker returns picks of both. What the response holds is
   * then decided by the feed's own enforcement alone.
   */
  const leaky = (now: number) => {
    mocks.readVisitAnchors.mockResolvedValue({ prevOpenedAt: 0, lastOpenedAt: 0 })
    mocks.subRows = []
    mocks.loadHides.mockResolvedValue({ posts: new Set(), shows: new Set() })
    mocks.trendingFranchiseIds.mockResolvedValue([F3, TV1, F4, TV2])
    recommender([{ genres: ['Action'] }], [
      { franchiseId: PICK, reason, source: 'anilist' },
      { franchiseId: TV_PICK, reason, source: 'tmdb' },
    ] as never)
    mocks.getFeedFranchises.mockImplementation(async (ids: string[]) => loaded(ids, {}, Object.fromEntries(ids.map((id) => [id, ['Action']]))))
    postEveryShow(now)
  }
  const shown = (res: Awaited<ReturnType<typeof getFeed>>) => ({
    posts: res.posts.map((p) => p.franchiseId).sort(),
    authors: res.franchises.map((f) => [f.id, f.source]).sort(),
    trending: res.trending.map((t) => t.id),
  })

  it('an anime viewer gets no TV show: not in the posts, the author rows or the Trending module', async () => {
    const now = nextNow()
    leaky(now)
    mocks.resolveAudience.mockResolvedValue('anime')

    const res = await getFeed(USER, 'foryou', now)

    expect(shown(res)).toEqual({
      posts: [F3, F4, PICK],
      authors: [[F3, 'anilist'], [F4, 'anilist'], [PICK, 'anilist']],
      trending: [F3, F4],
    })
    // Asked of the anime catalogue from the start: its own trending ranking, the ranker scoped to
    // it, and the TV pick never even loaded.
    expect(mocks.resolveAudience).toHaveBeenCalledWith(USER)
    expect(mocks.trendingFranchiseIds).toHaveBeenCalledWith(FEED_LIMITS.forYouCandidates, 'anilist')
    expect(mocks.rankRecommendations).toHaveBeenCalledWith(expect.anything(), expect.objectContaining({ source: 'anilist' }))
    expect(mocks.getFeedFranchises.mock.calls.map((call) => call[0])).toEqual([[F3, TV1, F4, TV2], [PICK]])
  })

  it('a TV viewer gets no anime: the reverse', async () => {
    const now = nextNow()
    leaky(now)
    mocks.resolveAudience.mockResolvedValue('tv')

    const res = await getFeed(USER, 'foryou', now)

    expect(shown(res)).toEqual({
      posts: [TV1, TV2, TV_PICK],
      authors: [[TV1, 'tmdb'], [TV2, 'tmdb'], [TV_PICK, 'tmdb']],
      trending: [TV1, TV2],
    })
    expect(mocks.trendingFranchiseIds).toHaveBeenCalledWith(FEED_LIMITS.forYouCandidates, 'tmdb')
    expect(mocks.rankRecommendations).toHaveBeenCalledWith(expect.anything(), expect.objectContaining({ source: 'tmdb' }))
    expect(mocks.getFeedFranchises.mock.calls.map((call) => call[0])).toEqual([[F3, TV1, F4, TV2], [TV_PICK]])
  })

  it('both — and a viewer who has not chosen — get every catalogue, from the one mixed ranking', async () => {
    const now = nextNow()
    leaky(now)

    const res = await getFeed(USER, 'foryou', now)

    expect(shown(res).posts).toEqual([F3, F4, PICK, TV1, TV2, TV_PICK])
    expect(shown(res).trending).toEqual([F3, TV1, F4, TV2])
    expect(mocks.trendingFranchiseIds).toHaveBeenCalledWith(FEED_LIMITS.forYouCandidates, null)
    expect(mocks.rankRecommendations).toHaveBeenCalledWith(expect.anything(), expect.objectContaining({ source: null }))
  })

  it('a change of audience shows on the very next request, not when the ten-minute caches run out', async () => {
    const now = nextNow()
    leaky(now)

    mocks.resolveAudience.mockResolvedValue('anime')
    expect(shown(await getFeed(USER, 'foryou', now)).posts).toEqual([F3, F4, PICK])
    // Served again from memory while nothing changes.
    expect(shown(await getFeed(USER, 'foryou', now + 1_000)).posts).toEqual([F3, F4, PICK])
    expect(mocks.loadRankInput).toHaveBeenCalledTimes(1)

    // The viewer switches to TV: seconds later, the feed is TV.
    mocks.resolveAudience.mockResolvedValue('tv')
    const tv = await getFeed(USER, 'foryou', now + 2_000)
    expect(shown(tv)).toMatchObject({ posts: [TV1, TV2, TV_PICK], trending: [TV1, TV2] })
    expect(mocks.loadRankInput).toHaveBeenCalledTimes(2)

    // And back, and to both: each is the next response.
    mocks.resolveAudience.mockResolvedValue('anime')
    expect(shown(await getFeed(USER, 'foryou', now + 3_000)).posts).toEqual([F3, F4, PICK])
    mocks.resolveAudience.mockResolvedValue('both')
    expect(shown(await getFeed(USER, 'foryou', now + 4_000)).posts).toEqual([F3, F4, PICK, TV1, TV2, TV_PICK])
  })

  it('never filters Following: the library is the viewer\'s own, and the audience is not even read', async () => {
    const now = nextNow()
    mocks.readVisitAnchors.mockResolvedValue({ prevOpenedAt: 0, lastOpenedAt: 0 })
    mocks.resolveAudience.mockResolvedValue('anime')
    mocks.subRows = [{ franchiseId: F3 }, { franchiseId: TV1 }]
    mocks.loadHides.mockResolvedValue({ posts: new Set(), shows: new Set() })
    postEveryShow(now)

    const res = await getFeed(USER, 'following', now)

    expect(res.posts.map((p) => p.franchiseId).sort()).toEqual([F3, TV1])
    expect(res.franchises.map((f) => f.source).sort()).toEqual(['anilist', 'tmdb'])
    expect(mocks.resolveAudience).not.toHaveBeenCalled()
  })
})

describe('getFeed: Following', () => {
  it('composes the library minus muted shows, puts the fresh block first, and drops hidden posts', async () => {
    const now = nextNow()
    const prev = now - D
    mocks.readVisitAnchors.mockResolvedValue({ prevOpenedAt: prev, lastOpenedAt: now - H })
    mocks.composePosts.mockReturnValue([
      post('news:old-fresh', OWNED, now - 5 * D, now - H),
      post('news:newer', OWNED, now - 2 * H, prev - H),
      post('news:hidden', OWNED, now - H, now - H),
    ])

    const res = await getFeed(USER, 'following', now)

    expect(mocks.getFeedFranchises).toHaveBeenCalledWith([OWNED], USER)
    expect(mocks.loadResearchHistory).toHaveBeenCalledWith([OWNED])
    // No option: the composer is not asked for episode posts.
    expect(mocks.composePosts).toHaveBeenCalledWith(expect.objectContaining({ episodes: false }))
    expect(res.posts.map((p) => [p.id, p.fresh, p.context])).toEqual([['news:old-fresh', true, null], ['news:newer', false, null]])
    expect(res.franchises.map((f) => [f.id, f.status])).toEqual([[OWNED, 'watching']])
    expect(res.trending).toEqual([])
    // Following is the library itself: the recommender is never asked.
    expect(mocks.loadRankInput).not.toHaveBeenCalled()
  })

  it('sends "Episode N is out" posts only to a request that asked for them', async () => {
    const now = nextNow()
    // The real composer: the gate is the composer's, so it is exercised end to end.
    const real = await vi.importActual<typeof import('./compose.js')>('./compose.js')
    mocks.composePosts.mockImplementation(real.composePosts)
    mocks.readVisitAnchors.mockResolvedValue({ prevOpenedAt: now - 3 * D, lastOpenedAt: now - H })
    // A show the viewer is watching: episode 7 aired two days ago, and a trailer came out last week.
    mocks.getFeedFranchises.mockImplementation(async (ids: string[]) => ({
      ...loaded(ids, { [OWNED]: 'watching' }),
      franchises: ids.map((id) =>
        franchise(id, [], { subscription: { status: 'watching', addedAt: 0 }, parts: [airingPart(now)], videos: [trailer('recent00001', now - 7 * D)] })),
    }))
    const trailerId = `trailer:${OWNED}:youtube:recent00001`

    // Every client that predates the kind sends no parameter: the response is what it always was.
    const before = await getFeed(USER, 'following', now)
    expect(before.posts.map((p) => [p.id, p.kind])).toEqual([[trailerId, 'trailer']])
    expect((await getFeed(USER, 'following', now, null, { episodes: false })).posts).toEqual(before.posts)

    // Asked for: the same posts, plus the episode — new since the visit, so it leads.
    const asked = await getFeed(USER, 'following', now, null, { episodes: true })
    expect(asked.posts.map((p) => [p.id, p.kind, p.episode, p.fresh])).toEqual([
      ['ep:21:7', 'episode', 7, true],
      [trailerId, 'trailer', null, false],
    ])
    expect(asked.posts[0]).toMatchObject({
      origin: 'catalogue',
      installment: 'Season 2',
      time: { at: now - 2 * D, dateOnly: false, basis: 'aired' },
      context: null,
      video: null,
      sources: [],
    })
    expect(asked.posts.slice(1)).toEqual(before.posts)

    // For you never carries one, whatever is asked.
    mocks.trendingFranchiseIds.mockResolvedValue([F3])
    const forYou = await getFeed(USER, 'foryou', now, null, { episodes: true })
    expect(forYou.posts.map((p) => p.kind)).toEqual(['trailer'])
  })

  it('counts an episode post\'s likes and comments under the episode\'s own subject, and hides it like any post', async () => {
    const now = nextNow()
    const prev = now - D
    mocks.readVisitAnchors.mockResolvedValue({ prevOpenedAt: prev, lastOpenedAt: now - H })
    const episode: ComposedPost = {
      ...post('ep:21:7', OWNED, now - 2 * H, now - 2 * H),
      kind: 'episode',
      origin: 'catalogue',
      installment: 'Season 2',
      episode: 7,
      time: { at: now - 2 * H, dateOnly: false, basis: 'aired' },
    }
    mocks.composePosts.mockReturnValue([
      post('news:newer', OWNED, now - H, prev - H),
      episode,
      { ...episode, id: 'ep:hidden:1' },
    ])
    mocks.loadHides.mockResolvedValue({ posts: new Set(['ep:hidden:1']), shows: new Set([MUTED]) })

    const res = await getFeed(USER, 'following', now, null, { episodes: true })

    expect(mocks.composePosts).toHaveBeenCalledWith(expect.objectContaining({ episodes: true }))
    // It aired since the previous visit: fresh, so ahead of newer news the viewer already had.
    expect(res.posts.map((p) => [p.id, p.kind, p.episode, p.fresh])).toEqual([
      ['ep:21:7', 'episode', 7, true],
      ['news:newer', 'announced', null, false],
    ])
    expect(mocks.loadPostSocial).toHaveBeenCalledWith(USER, ['ep:21:7', 'news:newer'])
    expect(res.posts[0]).toMatchObject({ counts: { likes: 2, comments: 1 } })
  })
})

describe('getPostDetail: an episode post', () => {
  const part = airingPart

  beforeEach(() => {
    mocks.memberRows = [{ franchiseId: F3 }]
    mocks.firstActivityAt.mockReset().mockResolvedValue(new Map())
  })

  it('resolves an ep: id through its part and composes the post — no opt-in needed — live while Following carries it', async () => {
    const now = nextNow()
    mocks.readVisitAnchors.mockResolvedValue({ prevOpenedAt: now - D, lastOpenedAt: now - H })
    mocks.getFeedFranchises.mockImplementation(async (ids: string[]) => ({
      ...loaded(ids, { [F3]: 'watching' }),
      franchises: ids.map((id) => franchise(id, [], { subscription: { status: 'watching', addedAt: 0 }, parts: [part(now)] })),
    }))

    const res = await getPostDetail(USER, 'ep:21:7', now)

    expect(mocks.getFeedFranchises).toHaveBeenCalledWith([F3], USER)
    expect(res).toMatchObject({
      live: true,
      post: { id: 'ep:21:7', kind: 'episode', episode: 7, installment: 'Season 2', context: null, fresh: false, time: { at: now - 2 * D, basis: 'aired' } },
      franchise: { id: F3, status: 'watching' },
      storyline: [],
      threadSources: [],
    })
    // An episode that has not aired is not a post, whoever asks.
    expect(await getPostDetail(USER, 'ep:21:8', now)).toBeNull()
  })

  it('keeps an older episode reachable while someone holds a row on it, and is gone otherwise', async () => {
    const now = nextNow()
    mocks.readVisitAnchors.mockResolvedValue({ prevOpenedAt: 0, lastOpenedAt: 0 })
    mocks.getFeedFranchises.mockImplementation(async (ids: string[]) => ({
      ...loaded(ids),
      franchises: ids.map((id) => franchise(id, [], { parts: [part(now)] })),
    }))

    expect(await getPostDetail(USER, 'ep:21:3', now)).toBeNull()
    expect(mocks.firstActivityAt).toHaveBeenCalledWith(['ep:21:3'])

    mocks.firstActivityAt.mockResolvedValue(new Map([['ep:21:3', now - 30 * D]]))
    expect(await getPostDetail(USER, 'ep:21:3', now)).toMatchObject({
      live: false,
      post: { id: 'ep:21:3', kind: 'episode', episode: 3, time: { at: now - 30 * D, basis: 'observed' }, fresh: false },
    })
    // No part of any franchise: nothing to resolve.
    mocks.memberRows = []
    expect(await getPostDetail(USER, 'ep:999:1', now)).toBeNull()
  })
})

describe('getPostDetail: a delisted trailer', () => {
  const id = `trailer:${F3}:youtube:gone0000001`

  it('stays reachable, bare and not live, while someone holds a row on it', async () => {
    const now = nextNow()
    mocks.readVisitAnchors.mockResolvedValue({ prevOpenedAt: now - D, lastOpenedAt: now - H })
    mocks.firstActivityAt.mockReset().mockResolvedValue(new Map([[id, now - 3 * D]]))

    const res = await getPostDetail(USER, id, now)

    expect(mocks.firstActivityAt).toHaveBeenCalledWith([id])
    expect(res).toMatchObject({
      live: false,
      post: { id, kind: 'trailer', video: null, installment: '', sources: [], fresh: false, context: null, time: { at: now - 3 * D } },
      franchise: { id: F3, status: null },
      storyline: [],
    })
  })

  it('is gone once nobody holds a row on it', async () => {
    const now = nextNow()
    mocks.readVisitAnchors.mockResolvedValue({ prevOpenedAt: 0, lastOpenedAt: 0 })
    mocks.firstActivityAt.mockReset().mockResolvedValue(new Map())

    expect(await getPostDetail(USER, id, now)).toBeNull()
  })
})
