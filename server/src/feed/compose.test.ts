import { afterEach, describe, expect, it, vi } from 'vitest'
import type { Franchise, FranchisePart, FranchiseVideo } from '../types/api.js'

// Never a real term in a test (social/blocklist.ts): the filter reads this fake list here.
vi.mock('../social/blocklist.js', () => ({ BLOCKED_TERMS: [{ term: 'zzbadword', match: 'word' }], NAME_ONLY_TERMS: [] }))

import {
  composePostById,
  composePosts,
  discoveryTrailer,
  orderPosts,
  tidyNote,
  toFeedFranchise,
  toPartRef,
  type ComposeAnnouncement,
  type ComposeEvidence,
  type ComposeInput,
  type ComposeObservation,
  type ComposedPost,
} from './compose.js'

// The Today feed composer, rule by rule (spec §2.4). Every fixture is built from `NOW`; nothing
// reads the clock.

const D = 86_400_000
const NOW = Date.UTC(2026, 8, 25, 12)
const FID = '11111111-1111-4111-8111-111111111111'
const FID2 = '22222222-2222-4222-8222-222222222222'
const A1 = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
const A2 = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
const ADDED = Date.UTC(2026, 7, 1)

const day = (y: number, m: number, d: number) => Date.UTC(y, m - 1, d, 12)
const iso = (ms: number) => new Date(ms).toISOString()

function part(overrides: Partial<FranchisePart> = {}): FranchisePart {
  return {
    mediaId: 100,
    kind: 'season',
    sequence: 1,
    watchOrder: 1,
    relationship: null,
    optional: false,
    label: 'Season 1',
    title: 'Show',
    cover: 'https://img.example/cover.jpg',
    banner: '',
    images: { portrait: 'https://img.example/cover.jpg', landscape: null },
    artwork: { portraits: [], landscapes: [], logos: [] },
    format: 'TV',
    status: 'FINISHED',
    isReleasing: false,
    totalEpisodes: 12,
    airedEpisodes: 12,
    nextEpisodeNumber: null,
    nextAiringAt: null,
    release: { precision: 'unknown', at: null, date: null },
    lastAiredAt: null,
    synopsis: '',
    genres: [],
    progress: 0,
    year: 2024,
    studios: [],
    nextAiringCount: 0,
    episodes: [],
    airings: [],
    videos: [],
    ...overrides,
  }
}

/** A NOT_YET_RELEASED season 2, premiering in a month unless told otherwise. */
function nyr(overrides: Partial<FranchisePart> = {}): FranchisePart {
  return part({
    mediaId: 200,
    sequence: 2,
    watchOrder: 2,
    label: 'Season 2',
    title: 'Show Season 2',
    status: 'NOT_YET_RELEASED',
    totalEpisodes: 0,
    airedEpisodes: 0,
    nextAiringAt: NOW + 30 * D,
    ...overrides,
  })
}

function franchise(overrides: Partial<Franchise> = {}): Franchise {
  return {
    id: FID,
    source: 'anilist',
    title: 'Show',
    cover: 'https://img.example/f.jpg',
    banner: '',
    images: { portrait: 'https://img.example/f.jpg', landscape: null },
    artwork: { portraits: [], landscapes: [], logos: [] },
    synopsis: '',
    genres: [],
    isReleasing: false,
    partCounts: { season: 1 },
    parts: [part()],
    subscription: null,
    upcoming: null,
    year: 2024,
    studios: [],
    themes: [],
    featuredVideo: null,
    videos: [],
    audience: { isAdult: null, contentRating: null, availableRatings: [] },
    people: { creators: [], directors: [], cast: [] },
    related: [],
    continueWatching: null,
    metadata: {
      completeness: { artwork: false, episodes: false, people: false, ratings: false, related: false, videos: false },
      sources: [],
    },
    ...overrides,
  }
}

function evidence(overrides: Partial<ComposeEvidence> = {}): ComposeEvidence {
  return {
    url: 'https://news.example/show-season-2-announced-for-2027',
    publisher: 'News Example',
    publishedAt: null,
    tier: 'trade',
    primary: false,
    ...overrides,
  }
}

let obsSeq = 0
function observation(overrides: Partial<ComposeObservation> = {}): ComposeObservation {
  obsSeq += 1
  return {
    id: `00000000-0000-4000-8000-${String(obsSeq).padStart(12, '0')}`,
    announcementId: A1,
    status: 'announced',
    next: 'Season 2',
    release: 'January 2027',
    note: null,
    observedAt: NOW - D,
    evidence: [],
    ...overrides,
  }
}

function announcement(overrides: Partial<ComposeAnnouncement> = {}): ComposeAnnouncement {
  return { id: A1, dedupeKey: 'season 2', status: 'announced', next: 'Season 2', firstSeenAt: NOW - 10 * D, ...overrides }
}

function video(overrides: Partial<FranchiseVideo> = {}): FranchiseVideo {
  return {
    id: 'vid00000001',
    site: 'YouTube',
    kind: 'trailer',
    title: 'Official Trailer',
    url: 'https://www.youtube.com/watch?v=vid00000001',
    thumbnail: 'https://i.ytimg.com/vi/vid00000001/hqdefault.jpg',
    official: true,
    language: 'en',
    country: null,
    publishedAt: iso(NOW - 30 * D),
    scope: { type: 'franchise' },
    ...overrides,
  }
}

function input(opts: {
  franchises?: Franchise[]
  observations?: Record<string, ComposeObservation[]>
  announcements?: Record<string, ComposeAnnouncement[]>
  memberAddedAt?: Record<number, number>
  externalIds?: Record<string, number | null>
  episodes?: boolean
  nowMs?: number
} = {}): ComposeInput {
  return {
    franchises: opts.franchises ?? [franchise()],
    observations: new Map(Object.entries(opts.observations ?? {})),
    announcements: new Map(Object.entries(opts.announcements ?? {})),
    memberAddedAt: new Map(
      Object.entries(opts.memberAddedAt ?? { 100: ADDED, 200: ADDED, 300: ADDED }).map(([k, v]) => [Number(k), v]),
    ),
    externalIds: new Map(Object.entries(opts.externalIds ?? {})),
    episodes: opts.episodes,
    nowMs: opts.nowMs ?? NOW,
  }
}

/** The franchise's one news post (research or catalogue origin), if any. */
function newsOf(posts: ComposedPost[]): ComposedPost | undefined {
  return posts.find((p) => p.origin !== 'video')
}

afterEach(() => {
  vi.restoreAllMocks()
})

describe('kind map', () => {
  const cases: [string, string, string | null][] = [
    ['upcoming_dated', '2026-11-20', 'dated'],
    ['announced', 'January 2027', 'window'],
    ['announced_no_date', 'TBA', 'announced'],
    ['rumored', 'Late 2027', 'rumour'],
    ['airing', '', null],
    ['recently_aired', '', null],
    ['concluded', '', null],
  ]
  for (const [status, release, kind] of cases) {
    it(`${status} → ${kind ?? 'no post'}`, () => {
      const posts = composePosts(input({
        observations: { [FID]: [observation({ status, release, announcementId: kind ? A1 : null })] },
      }))
      expect(newsOf(posts)?.kind ?? null).toBe(kind)
    })
  }

  it('makes no post from an observation with an empty `next`', () => {
    const posts = composePosts(input({ observations: { [FID]: [observation({ next: '   ' })] } }))
    expect(posts).toEqual([])
  })

  it('makes no research post without an announcement id', () => {
    const posts = composePosts(input({ observations: { [FID]: [observation({ announcementId: null })] } }))
    expect(posts).toEqual([])
  })
})

describe('ids and threads', () => {
  it('keys a research post on its announcement: news:<announcementId>', () => {
    const [post] = composePosts(input({ observations: { [FID]: [observation()] } }))
    expect(post?.id).toBe(`news:${A1}`)
    expect(post?.origin).toBe('research')
    expect(post?.installment).toBe('Season 2')
  })

  it('keeps rewordings of one installment on one post and one thread', () => {
    const posts = composePosts(input({
      observations: {
        [FID]: [
          observation({ next: 'Season 2: The Return', observedAt: NOW - D }),
          observation({ next: 'Season 2', observedAt: NOW - 5 * D }),
        ],
      },
    }))
    expect(posts).toHaveLength(1)
    expect(posts[0]?.thread).toHaveLength(2)
    expect(posts[0]?.installment).toBe('Season 2: The Return')
  })

  it("excludes another announcement's observations and their evidence (D5)", () => {
    const [post] = composePosts(input({
      observations: {
        [FID]: [
          observation({ evidence: [evidence({ publisher: 'Ours', url: 'https://ours.example/a' })] }),
          observation({
            announcementId: A2,
            next: 'The Movie',
            observedAt: NOW - 50 * D,
            evidence: [evidence({ publisher: 'Theirs', url: 'https://theirs.example/b' })],
          }),
          observation({ announcementId: null, status: 'airing', next: '', observedAt: NOW - 60 * D }),
        ],
      },
    }))
    expect(post?.thread.map((o) => o.announcementId)).toEqual([A1])
    expect(post?.sources.map((s) => s.publisher)).toEqual(['Ours'])
  })
})

describe('dating', () => {
  it('uses the newest primary report within 400 days of the newest report', () => {
    const [post] = composePosts(input({
      observations: {
        [FID]: [observation({
          evidence: [
            evidence({ url: 'https://a.example/1', publisher: 'A', publishedAt: '2026-09-01' }),
            evidence({ url: 'https://b.example/2', publisher: 'B', publishedAt: '2026-06-01', primary: true, tier: 'official' }),
            evidence({ url: 'https://c.example/3', publisher: 'C', publishedAt: '2026-04-01', primary: true }),
          ],
        })],
      },
    }))
    expect(post?.time).toEqual({ at: day(2026, 6, 1), dateOnly: true, basis: 'primary' })
  })

  it('ignores a stale primary and dates from the first report of the 120-day cluster', () => {
    const [post] = composePosts(input({
      observations: {
        [FID]: [observation({
          evidence: [
            evidence({ url: 'https://a.example/1', publisher: 'A', publishedAt: '2025-01-01', primary: true }),
            evidence({ url: 'https://b.example/2', publisher: 'B', publishedAt: '2026-09-01' }),
            evidence({ url: 'https://c.example/3', publisher: 'C', publishedAt: '2026-08-01T09:00:00Z' }),
            evidence({ url: 'https://d.example/4', publisher: 'D', publishedAt: '2026-03-01' }),
          ],
        })],
      },
    }))
    expect(post?.time).toEqual({ at: Date.UTC(2026, 7, 1, 9), dateOnly: false, basis: 'first_report' })
  })

  it('falls back to when research first saw the state', () => {
    const [post] = composePosts(input({
      observations: {
        [FID]: [
          observation({ observedAt: NOW - D }),
          observation({ observedAt: NOW - 3 * D }),
        ],
      },
    }))
    expect(post?.time).toEqual({ at: NOW - 3 * D, dateOnly: false, basis: 'observed' })
    expect(post?.discoveredAt).toBe(NOW - 3 * D)
  })

  it('ignores catalogue-tier and future-dated evidence', () => {
    const [post] = composePosts(input({
      observations: {
        [FID]: [observation({
          evidence: [
            evidence({ url: 'https://anilist.co/anime/200', publisher: 'AniList', tier: 'catalogue', publishedAt: '2026-01-01', primary: true }),
            evidence({ url: 'https://future.example/1', publisher: 'Future', publishedAt: iso(NOW + 3 * D), primary: true }),
            evidence({ url: 'https://b.example/2', publisher: 'B', publishedAt: '2026-09-10' }),
          ],
        })],
      },
    }))
    expect(post?.time).toEqual({ at: day(2026, 9, 10), dateOnly: true, basis: 'first_report' })
  })

  it('re-dates from the new state only when the status or release changes', () => {
    const [post] = composePosts(input({
      observations: {
        [FID]: [
          observation({
            release: 'January 2027',
            observedAt: NOW - D,
            evidence: [evidence({ url: 'https://b.example/new', publisher: 'B', publishedAt: '2026-09-20' })],
          }),
          observation({
            release: 'TBA',
            observedAt: NOW - 100 * D,
            evidence: [evidence({ url: 'https://a.example/old', publisher: 'A', publishedAt: '2026-06-01', primary: true })],
          }),
        ],
      },
    }))
    expect(post?.time).toEqual({ at: day(2026, 9, 20), dateOnly: true, basis: 'first_report' })
    expect(post?.discoveredAt).toBe(NOW - D)
    // The old state's report is still a source of the thread.
    expect(post?.sources.map((s) => s.publisher).sort()).toEqual(['A', 'B'])
  })

  it('reads the FULL history: the oldest same-state observation can be the 25th of 30', () => {
    const history = Array.from({ length: 30 }, (_, i) =>
      observation({
        observedAt: NOW - (i + 1) * D,
        status: i < 25 ? 'announced' : 'rumored',
        release: i < 25 ? 'January 2027' : 'TBA',
      }),
    )
    const [post] = composePosts(input({ observations: { [FID]: history } }))
    expect(post?.time).toEqual({ at: NOW - 25 * D, dateOnly: false, basis: 'observed' })
    expect(post?.discoveredAt).toBe(NOW - 25 * D)
    expect(post?.thread).toHaveLength(30)
  })
})

describe('premiere', () => {
  it("takes an AniList part's slot as an exact instant", () => {
    const slot = NOW + 40 * D
    const [post] = composePosts(input({
      franchises: [franchise({ parts: [part(), nyr({ nextAiringAt: slot })] })],
      observations: { [FID]: [observation({ status: 'upcoming_dated', release: 'Winter 2027' })] },
    }))
    expect(post).toMatchObject({ kind: 'dated', premiere: { at: slot, precision: 'exact' }, window: null })
    expect(post?.part?.mediaId).toBe(200)
  })

  it("takes a TMDB part's slot as date-only", () => {
    const slot = NOW + 40 * D
    const [post] = composePosts(input({
      franchises: [franchise({ source: 'tmdb', parts: [part(), nyr({ nextAiringAt: slot })] })],
      observations: { [FID]: [observation({ status: 'upcoming_dated', release: 'Winter 2027' })] },
    }))
    expect(post?.premiere).toEqual({ at: slot, precision: 'date_only' })
  })

  it('uses the first airing when the part has no next slot', () => {
    const at = NOW + 12 * D
    const [post] = composePosts(input({
      franchises: [franchise({ parts: [part(), nyr({ nextAiringAt: null, airings: [{ episode: 1, at }] })] })],
      observations: { [FID]: [observation({ status: 'upcoming_dated', release: 'October 2026' })] },
    }))
    expect(post?.premiere).toEqual({ at, precision: 'exact' })
  })

  it('reads a day-precise release as date-only at 12:00 UTC when no part matched', () => {
    const [iso8601] = composePosts(input({
      observations: { [FID]: [observation({ status: 'upcoming_dated', release: '2026-11-20', next: 'The Movie' })] },
    }))
    expect(iso8601).toMatchObject({ kind: 'dated', premiere: { at: day(2026, 11, 20), precision: 'date_only' }, part: null })
    // A deviation from the spike's ISO-only parse: the canonical window parser reads prose dates.
    const [prose] = composePosts(input({
      observations: { [FID]: [observation({ status: 'upcoming_dated', release: 'November 20, 2026', next: 'The Movie' })] },
    }))
    expect(prose?.premiere).toEqual({ at: day(2026, 11, 20), precision: 'date_only' })
  })

  it('files a dated post with no premiere as a window, resolved by the window parser', () => {
    const [post] = composePosts(input({
      observations: { [FID]: [observation({ status: 'upcoming_dated', release: 'November 2026', next: 'The Movie' })] },
    }))
    expect(post).toMatchObject({
      kind: 'window',
      premiere: null,
      window: { release: 'November 2026', releaseWindow: { date: '2026-11', precision: 'month', sortKey: 20261101 } },
    })
  })

  it('flags a movie and names it without the marker', () => {
    const [post] = composePosts(input({
      observations: { [FID]: [observation({ next: 'Infinity Castle - Part 2 (movie)' })] },
    }))
    expect(post).toMatchObject({ installment: 'Infinity Castle - Part 2', isMovie: true })
  })
})

describe('catalogue resolution (D4)', () => {
  it('keeps a confirmed rumour on its thread, with the catalogue kind and premiere', () => {
    const slot = NOW + 20 * D
    const [dated] = composePosts(input({
      franchises: [franchise({ parts: [part(), nyr({ nextAiringAt: slot })] })],
      observations: { [FID]: [observation({ status: 'rumored', release: 'Late 2026' })] },
    }))
    expect(dated).toMatchObject({ id: `news:${A1}`, origin: 'research', kind: 'dated', premiere: { at: slot, precision: 'exact' } })

    const [announced] = composePosts(input({
      franchises: [franchise({ parts: [part(), nyr({ nextAiringAt: null })] })],
      observations: { [FID]: [observation({ status: 'rumored', release: 'Late 2026' })] },
    }))
    expect(announced).toMatchObject({ id: `news:${A1}`, origin: 'research', kind: 'announced', premiere: null })
  })

  it('gives a rumour about another installment no post; the confirmed part posts instead', () => {
    const posts = composePosts(input({
      franchises: [franchise({ parts: [part(), nyr()] })],
      observations: { [FID]: [observation({ status: 'rumored', next: 'Season 3', release: 'TBA' })] },
    }))
    expect(posts.map((p) => p.id)).toEqual(['catalog:200'])
  })

  it('posts the catalogue part after a concluded or recently aired state', () => {
    for (const status of ['concluded', 'recently_aired']) {
      const posts = composePosts(input({
        franchises: [franchise({ parts: [part(), nyr()] })],
        observations: { [FID]: [observation({ status, announcementId: null, next: 'Season 1', release: '' })] },
      }))
      expect(posts.map((p) => p.id)).toEqual(['catalog:200'])
    }
  })

  it('keeps a stored `airing` over the catalogue: no post', () => {
    const posts = composePosts(input({
      franchises: [franchise({ parts: [part(), nyr()] })],
      observations: { [FID]: [observation({ status: 'airing', announcementId: null, next: 'Season 1', release: '' })] },
    }))
    expect(posts).toEqual([])
  })

  it('posts a catalogue-only part when research knows nothing', () => {
    const slot = NOW + 30 * D
    const [post] = composePosts(input({ franchises: [franchise({ parts: [part(), nyr({ nextAiringAt: slot })] })] }))
    expect(post).toMatchObject({
      id: 'catalog:200',
      kind: 'dated',
      origin: 'catalogue',
      installment: 'Season 2',
      isMovie: false,
      time: { at: ADDED, dateOnly: false, basis: 'catalogue' },
      // Attached with the show's first grouping (every member at ADDED): never "new".
      discoveredAt: 0,
      premiere: { at: slot, precision: 'exact' },
      window: null,
      note: null,
      isOfficial: false,
      thread: [],
    })
    expect(post?.sources).toEqual([{
      publisher: 'AniList',
      tier: 'catalogue',
      url: 'https://anilist.co/anime/200',
      publishedAt: null,
      dateOnly: false,
      primary: false,
    }])
  })

  it('is new only when the part was attached after the show was grouped', () => {
    const grouped = NOW - 200 * D
    const parts = [part(), nyr()]
    // The daily attach pass found Season 2 weeks after the show was grouped: that is news of an attach.
    const [later] = composePosts(input({ franchises: [franchise({ parts })], memberAddedAt: { 100: grouped, 200: NOW - 2 * D } }))
    expect(later).toMatchObject({ id: 'catalog:200', time: { at: NOW - 2 * D, basis: 'catalogue' }, discoveredAt: NOW - 2 * D })
    expect(orderPosts([later!], NOW - 3 * D)[0]?.fresh).toBe(true)

    // A re-grouping re-stamped every member (or the show was materialised with Season 2 already
    // listed): the attach instant says nothing about the announcement, so the post is never fresh.
    for (const stamps of [{ 100: NOW - D, 200: NOW - D }, { 100: NOW - D, 200: NOW - D + 30 * 60_000 }]) {
      const [founding] = composePosts(input({ franchises: [franchise({ parts })], memberAddedAt: stamps }))
      expect(founding).toMatchObject({ id: 'catalog:200', discoveredAt: 0 })
      expect(orderPosts([founding!], NOW - 3 * D)[0]?.fresh).toBe(false)
    }
  })

  it('links a TMDB catalogue post to the show page when the show id is known', () => {
    const [post] = composePosts(input({
      franchises: [franchise({ source: 'tmdb', parts: [part(), nyr({ nextAiringAt: null })] })],
      externalIds: { [FID]: 82596 },
    }))
    expect(post).toMatchObject({ kind: 'announced', premiere: null })
    expect(post?.sources[0]).toMatchObject({ publisher: 'TMDB', url: 'https://www.themoviedb.org/tv/82596' })
    const [unknown] = composePosts(input({ franchises: [franchise({ source: 'tmdb', parts: [part(), nyr()] })] }))
    expect(unknown?.sources[0]?.url).toBeNull()
  })

  it('reuses news:<id> when an announcement already names the part', () => {
    const [post] = composePosts(input({
      franchises: [franchise({ parts: [part(), nyr()] })],
      announcements: { [FID]: [announcement({ id: A2, dedupeKey: 'season 2' })] },
    }))
    expect(post).toMatchObject({ id: `news:${A2}`, origin: 'catalogue' })
  })

  it('keys the catalogue post by the part matcher adoption uses, not the announcement table\'s subset rule', () => {
    // "season 2" ⊂ "season 2 part 2" made the old alias hand this part the finished season's thread,
    // while adoption (matchPart) never moved a row to it.
    const s2 = part({ mediaId: 150, sequence: 2, watchOrder: 2, label: 'Season 2', title: 'Show Season 2' })
    const s2p2 = nyr({ mediaId: 200, sequence: 3, watchOrder: 3, label: 'Season 2 Part 2', title: 'Show Season 2 Part 2' })
    const [post] = composePosts(input({
      franchises: [franchise({ parts: [part(), s2, s2p2] })],
      announcements: { [FID]: [announcement({ id: A2, next: 'Season 2', dedupeKey: 'season 2' })] },
      memberAddedAt: { 100: ADDED, 150: ADDED, 200: ADDED },
    }))
    expect(post).toMatchObject({ id: 'catalog:200', origin: 'catalogue' })
  })

  it('makes no catalogue post without a stable attach time', () => {
    const posts = composePosts(input({ franchises: [franchise({ parts: [part(), nyr()] })], memberAddedAt: {} }))
    expect(posts).toEqual([])
  })

  it('ignores a NOT_YET_RELEASED part whose premiere has already passed (stale catalogue)', () => {
    const posts = composePosts(input({ franchises: [franchise({ parts: [part(), nyr({ nextAiringAt: NOW - D })] })] }))
    expect(posts).toEqual([])
  })
})

describe('sources and hygiene', () => {
  it('drops non-https evidence before dating: a javascript: primary cannot date the post', () => {
    const [post] = composePosts(input({
      observations: {
        [FID]: [observation({
          evidence: [
            evidence({ url: 'javascript:alert(1)', publisher: 'Evil', publishedAt: '2026-01-01', primary: true, tier: 'official' }),
            evidence({ url: 'http://plain.example/x', publisher: 'Plain', publishedAt: '2026-02-01', primary: true }),
            evidence({ url: 'https://b.example/2', publisher: 'B', publishedAt: '2026-09-01' }),
          ],
        })],
      },
    }))
    expect(post?.time).toEqual({ at: day(2026, 9, 1), dateOnly: true, basis: 'first_report' })
    expect(post?.sources.map((s) => s.publisher)).toEqual(['B'])
    expect(post?.thread[0]?.evidence.map((e) => e.url)).toEqual(['https://b.example/2'])
  })

  it('is official only when the lead source is official-tier', () => {
    const [official] = composePosts(input({
      observations: {
        [FID]: [observation({
          evidence: [
            evidence({ url: 'https://t.example/1', publisher: 'Trade', tier: 'trade' }),
            evidence({ url: 'https://about.netflix.com/en/news/show-season-2', publisher: 'Studio', tier: 'official' }),
          ],
        })],
      },
    }))
    expect(official?.sources[0]?.publisher).toBe('Studio')
    expect(official?.isOfficial).toBe(true)

    const [primaryTrade] = composePosts(input({
      observations: {
        [FID]: [observation({
          evidence: [
            evidence({ url: 'https://t.example/1', publisher: 'Trade', tier: 'trade', primary: true }),
            evidence({ url: 'https://about.netflix.com/en/news/show-season-2', publisher: 'Studio', tier: 'official' }),
          ],
        })],
      },
    }))
    expect(primaryTrade?.isOfficial).toBe(false)
  })

  it("does not take the agent's word for `official`: only a reviewed official host keeps the check", () => {
    const [post] = composePosts(input({
      observations: {
        [FID]: [observation({
          evidence: [evidence({ url: 'https://netflix-news.example/show-season-2', publisher: 'Netflix', tier: 'official', primary: true })],
        })],
      },
    }))
    expect(post?.sources[0]).toMatchObject({ publisher: 'Netflix', tier: 'reputable' })
    expect(post?.isOfficial).toBe(false)
    expect(post?.thread[0]?.evidence[0]?.tier).toBe('reputable')
  })

  it('prints no agent text that carries a link or a blocked term', () => {
    const [noted] = composePosts(input({
      observations: { [FID]: [observation({ note: 'Join us at discord.gg/x for the reveal.' })] },
    }))
    expect(noted?.note).toBeNull()
    const [blocked] = composePosts(input({ observations: { [FID]: [observation({ note: 'A zzbadword note.' })] } }))
    expect(blocked?.note).toBeNull()

    // A publisher name carrying a link reads as the page's own host.
    const [sourced] = composePosts(input({
      observations: {
        [FID]: [observation({ evidence: [evidence({ url: 'https://news.example/a', publisher: 'Visit spam.example/now' })] })],
      },
    }))
    expect(sourced?.sources[0]?.publisher).toBe('news.example')

    // A window whose release is not printable is an announcement without a date.
    const [release] = composePosts(input({
      observations: { [FID]: [observation({ status: 'announced', release: 'see https://x.example' })] },
    }))
    expect(release).toMatchObject({ kind: 'announced', window: null })
  })

  it('makes no post from an installment that carries a link, unless a part names it', () => {
    const linked = observation({ next: 'Season 2 discord.gg/abc' })
    expect(composePosts(input({ observations: { [FID]: [linked] } }))).toEqual([])
    // The matcher still finds the announced part, and its catalogue label is printed instead.
    const [post] = composePosts(input({
      franchises: [franchise({ parts: [part(), nyr()] })],
      observations: { [FID]: [linked] },
    }))
    expect(post).toMatchObject({ id: `news:${A1}`, installment: 'Season 2', part: { mediaId: 200 } })
    expect(composePosts(input({ observations: { [FID]: [observation({ next: 'Season 2 zzbadword' })] } }))).toEqual([])
  })

  it('normalises and caps an installment name', () => {
    const [post] = composePosts(input({
      observations: { [FID]: [observation({ next: `  Season\u00072\n  ${'Very Long Subtitle '.repeat(6)}` })] },
    }))
    expect(post?.installment.startsWith('Season2 Very Long Subtitle')).toBe(true)
    expect([...post!.installment].length).toBeLessThanOrEqual(60)
    expect(post?.installment.endsWith('…')).toBe(true)
  })

  it('leaves a trade-only window post without the check', () => {
    const [post] = composePosts(input({
      observations: { [FID]: [observation({ evidence: [evidence({ tier: 'trade' })] })] },
    }))
    expect(post).toMatchObject({ kind: 'window', isOfficial: false })
  })

  it('tidies the note', () => {
    const [post] = composePosts(input({
      observations: { [FID]: [observation({ note: '  Announced   at\tthe event.\u0007 ' })] },
    }))
    expect(post?.note).toBe('Announced at the event.')
    expect(tidyNote('   ')).toBeNull()
    const long = tidyNote(`${'word '.repeat(200)}end`)!
    expect([...long].length).toBeLessThanOrEqual(600)
    expect(long.endsWith('word…')).toBe(true)
  })
})

describe('video attachment', () => {
  const news = (videos: FranchiseVideo[], parts: FranchisePart[] = [part()]) =>
    composePosts(input({
      franchises: [franchise({ videos, parts })],
      observations: {
        [FID]: [observation({ evidence: [evidence({ publishedAt: iso(NOW - 50 * D) })] })],
      },
    }))[0]

  it('attaches the closest official cut within ten days of the news', () => {
    const post = news([
      video({ id: 'far00000001', publishedAt: iso(NOW - 70 * D) }),
      video({ id: 'near0000001', publishedAt: iso(NOW - 47 * D) }),
      video({ id: 'mid00000001', publishedAt: iso(NOW - 55 * D) }),
    ])
    expect(post?.video?.id).toBe('near0000001')
  })

  it("never attaches another part's video, nor a part video when no part matched", () => {
    const other = video({ id: 'other000001', publishedAt: iso(NOW - 50 * D), scope: { type: 'part', mediaId: 999, label: 'Season 9' } })
    expect(news([other], [part(), nyr()])?.video).toBeNull()
    const own = video({ id: 'own00000001', publishedAt: iso(NOW - 50 * D), scope: { type: 'part', mediaId: 200, label: 'Season 2' } })
    expect(news([own], [part(), nyr()])?.video?.id).toBe('own00000001')
    // No part matches "Season 2" here, so its part-scoped video is not this news's trailer.
    expect(news([own], [part()])?.video).toBeNull()
  })

  it('excludes disowned cuts and non-trailer kinds', () => {
    expect(news([video({ official: false, publishedAt: iso(NOW - 50 * D) })])?.video).toBeNull()
    expect(news([video({ kind: 'clip', publishedAt: iso(NOW - 50 * D) })])?.video).toBeNull()
    expect(news([video({ official: null, publishedAt: iso(NOW - 50 * D) })])?.video?.official).toBeNull()
  })

  it('serves only https video links', () => {
    const post = news([video({ publishedAt: iso(NOW - 50 * D), url: 'http://youtube.com/x', thumbnail: 'javascript:1' })])
    expect(post?.video).toMatchObject({ url: null, thumbnail: null })
  })
})

describe('trailer posts', () => {
  const trailers = (videos: FranchiseVideo[], opts: { parts?: FranchisePart[]; observations?: ComposeObservation[] } = {}) =>
    composePosts(input({
      franchises: [franchise({ videos, parts: opts.parts ?? [part()] })],
      observations: opts.observations ? { [FID]: opts.observations } : {},
    })).filter((p) => p.kind === 'trailer')

  it('keeps the last 200 days and nothing from the future', () => {
    const posts = trailers([
      video({ id: 'old00000001', publishedAt: iso(NOW - 201 * D), scope: { type: 'part', mediaId: 1, label: 'A' } }),
      video({ id: 'ok000000001', publishedAt: iso(NOW - 199 * D), scope: { type: 'part', mediaId: 2, label: 'B' } }),
      video({ id: 'future00001', publishedAt: iso(NOW + 3_600_000), scope: { type: 'part', mediaId: 3, label: 'C' } }),
    ])
    expect(posts.map((p) => p.video?.id)).toEqual(['ok000000001'])
  })

  it('posts one trailer per installment, the newest cut, newest first', () => {
    const posts = trailers([
      video({ id: 's2old000001', publishedAt: iso(NOW - 40 * D), scope: { type: 'part', mediaId: 200, label: 'Season 2' } }),
      video({ id: 's2new000001', publishedAt: iso(NOW - 10 * D), scope: { type: 'part', mediaId: 200, label: 'Season 2' } }),
      video({ id: 'show0000001', publishedAt: iso(NOW - 20 * D) }),
      video({ id: 'show0000002', publishedAt: iso(NOW - 25 * D) }),
    ], { parts: [part(), nyr()] })
    expect(posts.map((p) => p.video?.id)).toEqual(['s2new000001', 'show0000001'])
    expect(posts.map((p) => p.installment)).toEqual(['Season 2', ''])
  })

  it("skips the news post's own video, anything within ten days of the news, and audio-described copies", () => {
    const newsObs = [observation({ evidence: [evidence({ publishedAt: iso(NOW - 50 * D) })] })]
    const videos = [
      video({ id: 'attached001', publishedAt: iso(NOW - 49 * D) }),
      video({ id: 'close000001', publishedAt: iso(NOW - 58 * D), scope: { type: 'part', mediaId: 2, label: 'B' } }),
      video({ id: 'desc0000001', publishedAt: iso(NOW - 5 * D), title: 'Trailer (Audio Described)', scope: { type: 'part', mediaId: 3, label: 'C' } }),
      video({ id: 'fine0000001', publishedAt: iso(NOW - 5 * D), scope: { type: 'part', mediaId: 4, label: 'D' } }),
    ]
    const all = composePosts(input({ franchises: [franchise({ videos })], observations: { [FID]: newsObs } }))
    expect(newsOf(all)?.video?.id).toBe('attached001')
    expect(trailers(videos, { observations: newsObs }).map((p) => p.video?.id)).toEqual(['fine0000001'])
    // Without news, the same videos are all posts (one per installment), bar the audio-described copy.
    expect(trailers(videos).map((p) => p.video?.id)).toEqual(['fine0000001', 'attached001', 'close000001'])
  })

  it('marks only an official video official (D7)', () => {
    const [unknown] = trailers([video({ official: null, publishedAt: iso(NOW - 5 * D) })])
    expect(unknown?.sources).toEqual([{
      publisher: 'YouTube',
      tier: 'unknown',
      url: 'https://www.youtube.com/watch?v=vid00000001',
      publishedAt: NOW - 5 * D,
      dateOnly: false,
      primary: true,
    }])
    expect(unknown?.isOfficial).toBe(false)
    const [official] = trailers([video({ official: true, publishedAt: iso(NOW - 5 * D), site: 'vimeo', id: '12345' })])
    expect(official?.sources[0]).toMatchObject({ publisher: 'Vimeo', tier: 'official' })
    expect(official?.isOfficial).toBe(true)
  })

  it("dates the premiere from the scoped part's slot, else the first announced part with a slot", () => {
    const scopedSlot = NOW + 15 * D
    const [scoped] = trailers(
      [video({ publishedAt: iso(NOW - 5 * D), scope: { type: 'part', mediaId: 200, label: 'Season 2' } })],
      { parts: [part(), nyr({ nextAiringAt: scopedSlot })] },
    )
    expect(scoped).toMatchObject({ premiere: { at: scopedSlot, precision: 'exact' }, part: { mediaId: 200 } })

    const otherSlot = NOW + 60 * D
    const [fallback] = trailers(
      [video({ publishedAt: iso(NOW - 5 * D) })],
      { parts: [part(), nyr({ mediaId: 300, label: 'Season 3', nextAiringAt: otherSlot })] },
    )
    expect(fallback).toMatchObject({ premiere: { at: otherSlot, precision: 'exact' }, part: null, installment: '' })
  })

  it('ids a trailer trailer:<franchise>:<site>:<video id> and skips ids that do not parse', () => {
    const posts = trailers([
      video({ id: 'Ab_c-123', site: 'YouTube', publishedAt: iso(NOW - 5 * D) }),
      video({ id: 'bad/id', publishedAt: iso(NOW - 6 * D), scope: { type: 'part', mediaId: 7, label: 'X' } }),
    ])
    expect(posts.map((p) => p.id)).toEqual([`trailer:${FID}:youtube:Ab_c-123`])
    expect(posts[0]).toMatchObject({ kind: 'trailer', origin: 'video', time: { at: NOW - 5 * D, dateOnly: false, basis: 'published' }, discoveredAt: NOW - 5 * D })
  })
})

describe('orderPosts', () => {
  const p = (id: string, at: number, discoveredAt: number) => ({ id, time: { at, dateOnly: false, basis: 'observed' as const }, discoveredAt })

  it('puts the fresh block first, each block newest first then by id', () => {
    const prev = NOW - 2 * D
    const ordered = orderPosts([
      p('old-b', NOW - 10 * D, NOW - 10 * D),
      p('fresh-old-time', NOW - 30 * D, NOW - D),
      p('old-a', NOW - 10 * D, NOW - 10 * D),
      p('fresh-new-time', NOW - 5 * D, NOW),
      p('old-newest', NOW - 3 * D, NOW - 3 * D),
    ], prev)
    expect(ordered.map((x) => [x.id, x.fresh])).toEqual([
      ['fresh-new-time', true],
      ['fresh-old-time', true],
      ['old-newest', false],
      ['old-a', false],
      ['old-b', false],
    ])
  })

  it('marks nothing fresh without a previous visit', () => {
    const ordered = orderPosts([p('a', NOW, NOW), p('b', NOW - D, NOW)], 0)
    expect(ordered.every((x) => !x.fresh)).toBe(true)
  })

  it('orders equal times by id, whatever the input order', () => {
    const a = p('news:a', NOW, NOW)
    const b = p('news:b', NOW, NOW)
    expect(orderPosts([b, a], 0).map((x) => x.id)).toEqual(['news:a', 'news:b'])
    expect(orderPosts([a, b], 0).map((x) => x.id)).toEqual(['news:a', 'news:b'])
  })
})

describe('composePostById (D16)', () => {
  it('still composes a news post whose franchise is now airing, as not live', () => {
    const history = [
      observation({ announcementId: null, status: 'airing', next: 'Season 2', release: '', observedAt: NOW - D }),
      observation({ status: 'upcoming_dated', release: '2026-07-01', observedAt: NOW - 90 * D }),
    ]
    const found = composePostById(input({ observations: { [FID]: history }, announcements: { [FID]: [announcement()] } }), `news:${A1}`)
    expect(found?.live).toBe(false)
    expect(found?.post).toMatchObject({ id: `news:${A1}`, kind: 'dated', premiere: { at: day(2026, 7, 1), precision: 'date_only' } })
  })

  it('marks a post the feed carries as live', () => {
    const data = input({ observations: { [FID]: [observation()] } })
    expect(composePostById(data, `news:${A1}`)?.live).toBe(true)
    expect(composePostById(data, `news:${A2}`)).toBeNull()
  })

  it('composes a trailer beyond the 200-day horizon', () => {
    const data = input({ franchises: [franchise({ videos: [video({ id: 'ancient0001', publishedAt: iso(NOW - 400 * D) })] })] })
    expect(composePosts(data)).toEqual([])
    const found = composePostById(data, `trailer:${FID}:youtube:ancient0001`)
    expect(found).toMatchObject({ live: false, post: { kind: 'trailer', id: `trailer:${FID}:youtube:ancient0001` } })
    expect(composePostById(data, `trailer:${FID}:youtube:missing0001`)).toBeNull()
    expect(composePostById(data, `trailer:${FID2}:youtube:ancient0001`)).toBeNull()
  })

  it('keeps a catalogue post composable after its part premieres, as not live', () => {
    const live = input({ franchises: [franchise({ parts: [part(), nyr()] })] })
    expect(composePostById(live, 'catalog:200')).toMatchObject({ live: true, post: { id: 'catalog:200' } })

    // Premiered two days ago; the payload still carries episode 1's slot: that is the premiere.
    const premiered = NOW - 2 * D
    const released = input({
      franchises: [franchise({
        parts: [part(), nyr({
          status: 'RELEASING',
          nextAiringAt: NOW + 5 * D,
          airings: [{ episode: 1, at: premiered }, { episode: 2, at: NOW + 5 * D }],
        })],
      })],
    })
    expect(composePosts(released).filter((p) => p.id === 'catalog:200')).toEqual([])
    expect(composePostById(released, 'catalog:200')).toMatchObject({
      live: false,
      post: { id: 'catalog:200', origin: 'catalogue', kind: 'dated', premiere: { at: premiered, precision: 'exact' } },
    })

    // Episode 1 has left the payload's window: the installment has arrived, date unknown.
    const later = input({ franchises: [franchise({ parts: [part(), nyr({ status: 'FINISHED', nextAiringAt: null })] })] })
    expect(composePostById(later, 'catalog:200')).toMatchObject({ live: false, post: { kind: 'announced', premiere: null } })

    expect(composePostById(live, 'catalog:999')).toBeNull()
  })

  it('keeps a delisted trailer reachable only while someone holds a row on it', () => {
    const data = input({ franchises: [franchise({ videos: [] })] })
    const id = `trailer:${FID}:youtube:gone0000001`
    expect(composePostById(data, id)).toBeNull()
    const found = composePostById(data, id, { orphanAt: NOW - 3 * D })
    expect(found).toEqual({
      live: false,
      post: {
        id,
        kind: 'trailer',
        origin: 'video',
        franchiseId: FID,
        installment: '',
        isMovie: false,
        part: null,
        episode: null,
        time: { at: NOW - 3 * D, dateOnly: false, basis: 'observed' },
        discoveredAt: 0,
        premiere: null,
        window: null,
        note: null,
        video: null,
        sources: [],
        isOfficial: false,
        thread: [],
      },
    })
    // A disowned cut is no longer postable: bare too.
    const disowned = input({ franchises: [franchise({ videos: [video({ id: 'gone0000001', official: false })] })] })
    expect(composePostById(disowned, id, { orphanAt: NOW - D })?.post.video).toBeNull()
    // A listed trailer composes as itself, whatever the caller passed.
    const listed = input({ franchises: [franchise({ videos: [video({ id: 'gone0000001' })] })] })
    expect(composePostById(listed, id, { orphanAt: NOW - D })?.post.video?.id).toBe('gone0000001')
    // The franchise itself is gone: nothing to compose.
    expect(composePostById(data, `trailer:${FID2}:youtube:gone0000001`, { orphanAt: NOW - D })).toBeNull()
  })

  it('returns null for a malformed id, and for an episode nothing dates', () => {
    const data = input({ observations: { [FID]: [observation()] } })
    // Episode 1 of a finished season is out, but its air instant is not in the payload and nobody
    // holds a row on it (see "episode posts").
    expect(composePostById(data, 'ep:100:1')).toBeNull()
    expect(composePostById(data, 'news:not-a-uuid')).toBeNull()
  })
})

describe('episode posts ("Episode N is out")', () => {
  const H = 3_600_000
  const watching = { status: 'watching', addedAt: ADDED } as const
  /** A season on air: episode 5 aired two days ago, episode 6 airs in five. */
  const airing = (overrides: Partial<FranchisePart> = {}) =>
    part({
      status: 'RELEASING',
      isReleasing: true,
      airedEpisodes: 5,
      airings: [{ episode: 5, at: NOW - 2 * D }, { episode: 6, at: NOW + 5 * D }],
      ...overrides,
    })
  /** The episode posts of a request that asked for them. */
  const episodes = (f: Franchise, nowMs = NOW) =>
    composePosts(input({ franchises: [f], episodes: true, nowMs })).filter((p) => p.kind === 'episode')

  it('composes none unless the request asked: a client that predates the kind never receives it', () => {
    const f = franchise({ subscription: watching, videos: [video()], parts: [airing(), nyr()] })
    const asked = composePosts(input({ franchises: [f], episodes: true }))
    expect(asked.map((p) => p.kind).sort()).toEqual(['dated', 'episode', 'trailer'])
    // Not asked (the default, and an explicit false): the feed exactly as it was — the same posts
    // minus the episode one, nothing else moved.
    for (const off of [input({ franchises: [f] }), input({ franchises: [f], episodes: false })]) {
      expect(composePosts(off)).toEqual(asked.filter((p) => p.kind !== 'episode'))
    }
  })

  it('posts the newest aired episode of a show the viewer watches, keyed on the episode\'s own subject', () => {
    const p = airing()
    const f = franchise({ subscription: watching, parts: [p] })
    expect(episodes(f)).toEqual([{
      id: 'ep:100:5',
      kind: 'episode',
      origin: 'catalogue',
      franchiseId: FID,
      installment: 'Season 1',
      isMovie: false,
      part: toPartRef(p),
      episode: 5,
      time: { at: NOW - 2 * D, dateOnly: false, basis: 'aired' },
      // New from the moment it aired.
      discoveredAt: NOW - 2 * D,
      premiere: null,
      window: null,
      note: null,
      video: null,
      sources: [],
      isOfficial: false,
      thread: [],
    }])
  })

  it('keeps an episode for seven days after it airs, and only the newest one', () => {
    const at = (days: number, episode = 5) => franchise({ subscription: watching, parts: [airing({ airings: [{ episode, at: NOW - days * D }] })] })
    expect(episodes(at(6.9)).map((p) => p.id)).toEqual(['ep:100:5'])
    expect(episodes(at(7.1))).toEqual([])
    // Two aired inside the week: one post, the later one.
    const two = franchise({
      subscription: watching,
      parts: [airing({ airings: [{ episode: 4, at: NOW - 6 * D }, { episode: 5, at: NOW - D }, { episode: 6, at: NOW + 6 * D }] })],
    })
    expect(episodes(two).map((p) => p.id)).toEqual(['ep:100:5'])
    // Nothing in the dated window has aired yet: no post.
    expect(episodes(franchise({ subscription: watching, parts: [airing({ airings: [{ episode: 6, at: NOW + D }] })] }))).toEqual([])
  })

  it('counts a slot the moment it strikes, before the hourly sync moves the catalogue on', () => {
    const next = (at: number) =>
      franchise({ subscription: watching, parts: [airing({ airings: [{ episode: 5, at: NOW - 7 * D + H }, { episode: 6, at }] })] })
    expect(episodes(next(NOW - 60_000)).map((p) => p.id)).toEqual(['ep:100:6'])
    expect(episodes(next(NOW)).map((p) => p.id)).toEqual(['ep:100:6'])
    expect(episodes(next(NOW + 60_000)).map((p) => p.id)).toEqual(['ep:100:5'])
  })

  it('counts a date-only (TMDB) episode from 10:00 UTC of its date, carries it at noon and never prints its clock', () => {
    // TMDB gives a calendar date; the sync synthesises 17:00 UTC. NOW is 12:00 UTC of that date.
    const today = Date.UTC(2026, 8, 25)
    const f = franchise({ source: 'tmdb', subscription: watching, parts: [airing({ airings: [{ episode: 3, at: today + 17 * H }] })] })
    // 09:59 UTC: no time zone has reached the day after it yet.
    expect(episodes(f, today + 10 * H - 60_000)).toEqual([])
    // 11:00 UTC: out. The post is never dated after now, and is new from 10:00 — not from its noon.
    expect(episodes(f, today + 11 * H)).toMatchObject([{
      id: 'ep:100:3',
      episode: 3,
      time: { at: today + 11 * H, dateOnly: true, basis: 'aired' },
      discoveredAt: today + 10 * H,
    }])
    // Afterwards: noon of its date.
    expect(episodes(f, NOW + 2 * D)[0]).toMatchObject({ time: { at: today + 12 * H, dateOnly: true }, discoveredAt: today + 10 * H })
    // The week runs from the instant it struck.
    expect(episodes(f, today + 10 * H + 7 * D)).toHaveLength(1)
    expect(episodes(f, today + 10 * H + 7 * D + 60_000)).toEqual([])
  })

  it('posts for watching, watched and paused shows only', () => {
    const of = (status: string | null) =>
      episodes(franchise({ subscription: status ? { status: status as 'watching', addedAt: ADDED } : null, parts: [airing()] })).length
    expect(['watching', 'completed', 'paused'].map(of)).toEqual([1, 1, 1])
    expect(['planned', 'dropped'].map(of)).toEqual([0, 0])
    // A franchise loaded for nobody (For you): no library, no episode posts.
    expect(of(null)).toBe(0)
  })

  it('posts once per main-story part, whether or not the viewer has seen the episode', () => {
    const f = franchise({
      subscription: watching,
      parts: [
        airing({ progress: 5 }),
        airing({ mediaId: 300, sequence: 2, watchOrder: 2, label: 'Season 2', airings: [{ episode: 1, at: NOW - 3 * H }] }),
      ],
    })
    expect(episodes(f).map((p) => [p.id, p.installment, p.episode])).toEqual([
      ['ep:100:5', 'Season 1', 5],
      ['ep:300:1', 'Season 2', 1],
    ])
  })

  it('leaves shorts, spin-offs and extras out; ONAs speak only for a show with no season', () => {
    const side = (overrides: Partial<FranchisePart>) => airing({ mediaId: 300, sequence: 2, watchOrder: 2, label: 'Extra', ...overrides })
    const ids = (parts: FranchisePart[]) => episodes(franchise({ subscription: watching, parts })).map((p) => p.id)
    expect(ids([airing(), side({ format: 'TV_SHORT' })])).toEqual(['ep:100:5'])
    expect(ids([airing(), side({ relationship: 'SPIN_OFF' })])).toEqual(['ep:100:5'])
    expect(ids([airing(), side({ kind: 'special' })])).toEqual(['ep:100:5'])
    expect(ids([airing(), side({ kind: 'ona', format: 'ONA' })])).toEqual(['ep:100:5'])
    // A sequel season is the main story.
    expect(ids([airing(), side({ relationship: 'SEQUEL' })])).toEqual(['ep:100:5', 'ep:300:5'])
    // No main-story season at all: the show's main ONAs are its episodes — not its spin-off ONA,
    // nor one whose only tie is a parent (the shorts beside a season, as the old rows store them).
    expect(ids([
      airing({ kind: 'ona', format: 'ONA' }),
      side({ kind: 'ona', format: 'ONA', relationship: 'SPIN_OFF' }),
      side({ mediaId: 400, format: 'TV_SHORT' }),
      side({ mediaId: 500, kind: 'ona', format: 'ONA', relationship: 'PARENT' }),
    ])).toEqual(['ep:100:5'])
  })

  it('a season is the story whatever the stored rows call it: `optional` and SIDE_STORY are not trusted', () => {
    // The stored flags were written for seasons that merely HAVE a side story (My Hero Academia,
    // Gintama): the app counts them as seasons, so their episodes are posts.
    const season = (overrides: Partial<FranchisePart>) => airing({ mediaId: 300, sequence: 2, watchOrder: 2, label: 'Season 2', ...overrides })
    const ids = (parts: FranchisePart[]) => episodes(franchise({ subscription: watching, parts })).map((p) => p.id)
    expect(ids([airing(), season({ optional: true })])).toEqual(['ep:100:5', 'ep:300:5'])
    expect(ids([airing(), season({ relationship: 'SIDE_STORY', optional: true })])).toEqual(['ep:100:5', 'ep:300:5'])
  })

  it('never posts for a part that has not premiered, and names the last episode of a same-day drop', () => {
    const unreleased = franchise({ subscription: watching, parts: [airing({ status: 'NOT_YET_RELEASED', airings: [{ episode: 1, at: NOW - H }] })] })
    expect(episodes(unreleased)).toEqual([])
    const drop = franchise({
      subscription: watching,
      parts: [airing({ airings: [1, 2, 3, 4].map((episode) => ({ episode, at: NOW - D })) })],
    })
    expect(episodes(drop).map((p) => p.id)).toEqual(['ep:100:4'])
  })

  it('rides beside the show\'s news and trailers, and orders as any post: new since the visit first', () => {
    const f = franchise({
      subscription: watching,
      videos: [video({ publishedAt: iso(NOW - 30 * D) })],
      parts: [airing(), nyr()],
    })
    const posts = composePosts(input({ franchises: [f], episodes: true }))
    expect(posts.map((p) => p.kind).sort()).toEqual(['dated', 'episode', 'trailer'])
    // The episode aired after the previous visit; the catalogue post and the trailer did not arrive since.
    const ordered = orderPosts(posts, NOW - 3 * D)
    expect(ordered.map((p) => [p.kind, p.fresh])).toEqual([['episode', true], ['trailer', false], ['dated', false]])
  })

  describe('by id', () => {
    const data = (status: 'watching' | 'planned' | null = 'watching', asked = true) =>
      input({
        franchises: [franchise({ subscription: status ? { status, addedAt: ADDED } : null, parts: [airing()] })],
        episodes: asked,
      })

    it('composes the feed\'s post, live for a viewer whose Following carries it', () => {
      expect(composePostById(data(), 'ep:100:5')).toMatchObject({
        live: true,
        post: { id: 'ep:100:5', kind: 'episode', episode: 5, time: { at: NOW - 2 * D, basis: 'aired' } },
      })
      // By id the post composes whether or not the input composes episodes; only `live` follows it.
      expect(composePostById(data('watching', false), 'ep:100:5')).toMatchObject({ live: false, post: { id: 'ep:100:5', episode: 5 } })
      // The same post for anyone else it is out for — a planned show, or no library row at all.
      expect(composePostById(data('planned'), 'ep:100:5')).toMatchObject({ live: false, post: { id: 'ep:100:5', episode: 5 } })
      expect(composePostById(data(null), 'ep:100:5')).toMatchObject({ live: false, post: { id: 'ep:100:5' } })
    })

    it('is null for an episode that has not aired, and for a part the catalogue does not hold', () => {
      expect(composePostById(data(), 'ep:100:6')).toBeNull()
      expect(composePostById(data(), 'ep:100:6', { orphanAt: NOW - D })).toBeNull()
      expect(composePostById(data(), 'ep:100:99', { orphanAt: NOW - D })).toBeNull()
      expect(composePostById(data(), 'ep:999:1', { orphanAt: NOW - D })).toBeNull()
      const unreleased = input({ franchises: [franchise({ parts: [nyr({ airedEpisodes: 3 })] })] })
      expect(composePostById(unreleased, 'ep:200:1', { orphanAt: NOW - D })).toBeNull()
    })

    it('keeps an older episode reachable only while someone holds a row on it, dated at that row', () => {
      // Episode 3 is out (5 have aired) but its air instant left the payload with the dated window.
      expect(composePostById(data(), 'ep:100:3')).toBeNull()
      expect(composePostById(data(), 'ep:100:3', { orphanAt: NOW - 20 * D })).toMatchObject({
        live: false,
        post: {
          id: 'ep:100:3',
          kind: 'episode',
          episode: 3,
          installment: 'Season 1',
          time: { at: NOW - 20 * D, dateOnly: false, basis: 'observed' },
          discoveredAt: 0,
        },
      })
    })
  })
})

describe('the discovery trailer (For you, a recommended show)', () => {
  const old = (overrides: Partial<FranchiseVideo> = {}) => video({ publishedAt: iso(NOW - 400 * D), ...overrides })
  /** The show's feed posts as composed, then its discovery trailer. */
  const discover = (f: Franchise, observations: ComposeObservation[] = []) => {
    const data = input({ franchises: [f], observations: observations.length ? { [FID]: observations } : {} })
    const posts = composePosts(data)
    return { data, posts, trailer: discoveryTrailer(f, posts, NOW) }
  }

  it('posts a trailer the feed left out for its age: the same post, honestly dated', () => {
    const f = franchise({ videos: [old()] })
    const { data, posts, trailer } = discover(f)
    expect(posts).toEqual([])
    expect(trailer).toMatchObject({
      id: `trailer:${FID}:youtube:vid00000001`,
      kind: 'trailer',
      origin: 'video',
      franchiseId: FID,
      episode: null,
      time: { at: NOW - 400 * D, dateOnly: false, basis: 'published' },
      video: { id: 'vid00000001' },
      isOfficial: true,
    })
    // It is the post the id composes to, so its page, likes and saves work as any trailer's.
    expect(composePostById(data, trailer!.id)).toEqual({ post: trailer, live: false })
  })

  it('adds nothing when the feed already carries a trailer for the show', () => {
    const f = franchise({ videos: [old(), video({ id: 'new00000001', publishedAt: iso(NOW - 20 * D) })] })
    const { posts, trailer } = discover(f)
    expect(posts.map((p) => p.video?.id)).toEqual(['new00000001'])
    expect(trailer).toBeNull()
    // Another show's trailer in the list is not this show's.
    expect(discoveryTrailer(franchise({ id: FID2, videos: [old()] }), posts, NOW)?.video?.id).toBe('vid00000001')
  })

  it('leads with the featured video, else an official cut, a trailer before a teaser, the newest first', () => {
    const videos = [
      old({ id: 'teaser00001', kind: 'teaser', publishedAt: iso(NOW - 250 * D) }),
      old({ id: 'unmarked001', official: null, publishedAt: iso(NOW - 210 * D) }),
      old({ id: 'trailer0001', publishedAt: iso(NOW - 900 * D) }),
      old({ id: 'trailer0002', publishedAt: iso(NOW - 500 * D) }),
    ]
    expect(discover(franchise({ videos })).trailer?.video?.id).toBe('trailer0002')
    expect(discover(franchise({ videos, featuredVideo: videos[2]! })).trailer?.video?.id).toBe('trailer0001')
    // A featured video that is not postable (a featurette) is passed over.
    const featurette = old({ id: 'feature0001', kind: 'featurette' })
    expect(discover(franchise({ videos: [...videos, featurette], featuredVideo: featurette })).trailer?.video?.id).toBe('trailer0002')
    // With no official cut, the newest unmarked one.
    expect(discover(franchise({ videos: [videos[1]!, old({ id: 'unmarked002', official: null })] })).trailer?.video?.id).toBe('unmarked001')
  })

  it('needs a usable video: postable, dated, and not from the future', () => {
    const none = (v: FranchiseVideo) => expect(discover(franchise({ videos: [v] })).trailer).toBeNull()
    // An AniList trailer carries no publish date, and a date is never invented.
    none(old({ publishedAt: null }))
    none(old({ official: false }))
    none(old({ kind: 'clip' }))
    none(old({ title: 'Official Trailer (Audio Described)' }))
    none(old({ publishedAt: iso(NOW + 2 * 3_600_000) }))
    expect(discover(franchise({ videos: [] })).trailer).toBeNull()
    // A part's own video counts as the show's.
    const scoped = old({ id: 'part0000001', scope: { type: 'part', mediaId: 100, label: 'Season 1' } })
    expect(discover(franchise({ parts: [part({ videos: [scoped] })] })).trailer).toMatchObject({ installment: 'Season 1', video: { id: 'part0000001' } })
  })

  it('never re-posts the live news post\'s own campaign', () => {
    const news = [observation({ observedAt: NOW - D })]
    const attached = video({ id: 'attached001', publishedAt: iso(NOW - 2 * D) })
    const sameWeek = video({ id: 'sameweek001', publishedAt: iso(NOW - 9 * D) })
    // The news post carries one cut and claims the other; neither becomes a trailer post.
    const claimed = discover(franchise({ videos: [attached, sameWeek] }), news)
    expect(claimed.posts.map((p) => [p.kind, p.video?.id])).toEqual([['window', 'attached001']])
    expect(claimed.trailer).toBeNull()
    // An older cut is a different story: it introduces the show beside the news.
    const withOld = discover(franchise({ videos: [attached, sameWeek, old()] }), news)
    expect(withOld.trailer?.video?.id).toBe('vid00000001')
  })
})

describe('spent news (the installment has arrived)', () => {
  it('leaves a research post out of the feed once its part has left NOT_YET_RELEASED; by id it is not live', () => {
    for (const status of ['upcoming_dated', 'announced', 'announced_no_date', 'rumored']) {
      const data = input({
        franchises: [franchise({ parts: [part(), nyr({ status: 'RELEASING', nextAiringAt: NOW + 6 * D })] })],
        observations: { [FID]: [observation({ status, release: status === 'upcoming_dated' ? '2026-09-20' : 'Fall 2026' })] },
      })
      expect(composePosts(data).filter((p) => p.origin === 'research')).toEqual([])
      expect(composePostById(data, `news:${A1}`)).toMatchObject({ live: false, post: { id: `news:${A1}`, part: { mediaId: 200 } } })
    }
  })

  it('leaves a research post out once its premiere has passed everywhere', () => {
    const at = (release: string) =>
      composePosts(input({ observations: { [FID]: [observation({ status: 'upcoming_dated', release, next: 'The Movie' })] } }))
    // 12:00 UTC on 23 Sep is two days ago: the day is over in every zone.
    expect(at('2026-09-23')).toEqual([])
    // 12:00 UTC on 24 Sep was 24 h ago to the minute: over too.
    expect(at('2026-09-24')).toEqual([])
    // Today's premiere is still news (the client says "premieres today").
    expect(at('2026-09-25')[0]).toMatchObject({ kind: 'dated', premiere: { at: day(2026, 9, 25), precision: 'date_only' } })
  })

  it("keeps a spent post's trailer out of the feed with it", () => {
    const videos = [video({ id: 'withnews001', publishedAt: iso(NOW - 40 * D), scope: { type: 'part', mediaId: 200, label: 'Season 2' } })]
    const posts = composePosts(input({
      franchises: [franchise({ videos, parts: [part(), nyr({ status: 'RELEASING', nextAiringAt: NOW + D, videos: [] })] })],
      observations: {
        [FID]: [observation({ status: 'upcoming_dated', release: '2026-09-20', evidence: [evidence({ publishedAt: iso(NOW - 40 * D) })] })],
      },
    }))
    expect(posts).toEqual([])
  })

  it("never points a trailer at a premiere that has passed", () => {
    const [post] = composePosts(input({
      franchises: [franchise({
        videos: [video({ publishedAt: iso(NOW - 5 * D) })],
        // A stale unreleased row (its slot struck an hour ago; the hourly sync has not flipped it).
        parts: [part(), nyr({ nextAiringAt: NOW - 3_600_000 })],
      })],
    })).filter((p) => p.kind === 'trailer')
    expect(post?.premiere).toBeNull()

    const [scoped] = composePosts(input({
      franchises: [franchise({
        videos: [video({ publishedAt: iso(NOW - 5 * D), scope: { type: 'part', mediaId: 200, label: 'Season 2' } })],
        parts: [part(), nyr({ nextAiringAt: NOW - 3_600_000 })],
      })],
    })).filter((p) => p.kind === 'trailer')
    expect(scoped?.premiere).toBeNull()
  })
})

describe('dates never ahead of now', () => {
  it("clamps a report dated tomorrow (a JST publisher's day) to now, keeping it date-only", () => {
    const [post] = composePosts(input({
      nowMs: Date.UTC(2026, 8, 25, 20),
      observations: {
        [FID]: [observation({
          observedAt: Date.UTC(2026, 8, 25, 19),
          evidence: [evidence({ publishedAt: '2026-09-26', primary: true })],
        })],
      },
    }))
    expect(post?.time).toEqual({ at: Date.UTC(2026, 8, 25, 20), dateOnly: true, basis: 'primary' })
    expect(post?.discoveredAt).toBe(Date.UTC(2026, 8, 25, 19))
  })

  it('clamps a trailer composed by id whose publish instant is ahead of now', () => {
    const data = input({ franchises: [franchise({ videos: [video({ id: 'soon0000001', publishedAt: iso(NOW + 6 * 3_600_000) })] })] })
    const found = composePostById(data, `trailer:${FID}:youtube:soon0000001`)
    expect(found?.post.time.at).toBe(NOW)
  })
})

describe('a day-precise window is a date', () => {
  it('files an `announced` result with a day-precise release as dated, date-only', () => {
    const [post] = composePosts(input({
      observations: { [FID]: [observation({ status: 'announced', release: 'November 20, 2026', next: 'The Movie' })] },
    }))
    expect(post).toMatchObject({ kind: 'dated', premiere: { at: day(2026, 11, 20), precision: 'date_only' }, window: null })
  })

  it("prefers the matched part's own slot, as for upcoming_dated", () => {
    const slot = NOW + 40 * D
    const [post] = composePosts(input({
      franchises: [franchise({ parts: [part(), nyr({ nextAiringAt: slot })] })],
      observations: { [FID]: [observation({ status: 'announced', release: '2026-11-20' })] },
    }))
    expect(post).toMatchObject({ kind: 'dated', premiere: { at: slot, precision: 'exact' } })
  })

  it('keeps a coarser `announced` window a window', () => {
    const [post] = composePosts(input({ observations: { [FID]: [observation({ status: 'announced', release: 'November 2026' })] } }))
    expect(post).toMatchObject({ kind: 'window', premiere: null, window: { release: 'November 2026' } })
  })
})

describe('determinism', () => {
  it('composes the same posts twice without reading the clock', () => {
    const spy = vi.spyOn(Date, 'now')
    const build = () => input({
      franchises: [
        franchise({
          parts: [part(), nyr()],
          videos: [
            video({ publishedAt: iso(NOW - 5 * D) }),
            video({ id: 'vid00000002', publishedAt: iso(NOW - 45 * D), scope: { type: 'part', mediaId: 200, label: 'Season 2' } }),
          ],
        }),
        franchise({ id: FID2, parts: [part({ mediaId: 300 })] }),
      ],
      observations: {
        [FID]: [observation({
          id: '00000000-0000-4000-8000-999999999999',
          status: 'rumored',
          evidence: [evidence({ publishedAt: '2026-08-12' }), evidence({ url: 'https://z.example/1', publisher: 'Z', publishedAt: '2026-08-11', primary: true })],
        })],
      },
      announcements: { [FID]: [announcement()] },
    })
    const first = composePosts(build())
    const second = composePosts(build())
    expect(second).toEqual(first)
    expect(first.length).toBeGreaterThan(0)
    const ordered = orderPosts(first, NOW - 7 * D)
    expect(orderPosts(second, NOW - 7 * D)).toEqual(ordered)
    expect(composePostById(build(), first[0]!.id)).toEqual(composePostById(build(), first[0]!.id))
    expect(spy).not.toHaveBeenCalled()
  })
})

describe('wire rows', () => {
  it('maps a franchise to its author row with the viewer status', () => {
    const f = franchise({ year: 2019, isReleasing: true })
    expect(toFeedFranchise(f, 'watching')).toEqual({
      id: FID,
      source: 'anilist',
      title: 'Show',
      cover: 'https://img.example/f.jpg',
      banner: '',
      images: f.images,
      artwork: f.artwork,
      year: 2019,
      isReleasing: true,
      status: 'watching',
      upcoming: null,
    })
    expect(toFeedFranchise(f, null).status).toBeNull()
  })

  it("carries only a part's art inputs", () => {
    const p = nyr()
    expect(toPartRef(p)).toEqual({
      mediaId: 200,
      label: 'Season 2',
      kind: 'season',
      status: 'NOT_YET_RELEASED',
      cover: p.cover,
      banner: p.banner,
      images: p.images,
      artwork: p.artwork,
    })
  })
})

describe('data integrity retractions', () => {
  it('suppresses retracted research in both live and saved-post resolution', () => {
    const i = input({ observations: { [FID]: [observation()] }, announcements: { [FID]: [announcement({ status: 'retracted' })] } })
    expect(composePosts(i).some(p => p.id === `news:${A1}`)).toBe(false)
    expect(composePostById(i, `news:${A1}`)).toBeNull()
  })
  it('retains a real future catalogue part after withdrawing unrelated research', () => {
    const i = input({ franchises: [franchise({ parts: [part({ mediaId: 200, status: 'NOT_YET_RELEASED', label: 'Season 2', sequence: 2 })] })], observations: { [FID]: [observation()] }, announcements: { [FID]: [announcement({ status: 'retracted' })] } })
    expect(composePosts(i).some(p => p.id === 'catalog:200')).toBe(true)
  })
})
