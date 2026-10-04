import { describe, expect, it } from 'vitest'
import type { EpisodeMeta, FranchisePart, FranchiseVideo } from '../types/api.js'
import { airingsWindow, deriveAiredEpisodes, deriveContinueWatching, pickFeaturedVideo } from './franchiseView.js'

// Fixed "now": 2026-07-01T00:00Z.
const NOW = Date.UTC(2026, 6, 1)
const D = 86_400_000

function eps(count: number, firstAirDate: number | null): EpisodeMeta[] {
  return Array.from({ length: count }, (_, i) => ({
    number: i + 1,
    title: `Episode ${i + 1}`,
    airDate: firstAirDate == null ? null : firstAirDate + i * 7 * D,
    overview: null,
    still: null,
    runtime: null,
  }))
}

describe('deriveAiredEpisodes', () => {
  it('reads the next slot as "everything before it has aired"', () => {
    expect(
      deriveAiredEpisodes({ status: 'RELEASING', totalEpisodes: 12, next: { episode: 5 }, episodes: [], nowMs: NOW }),
    ).toBe(4)
    // A next slot of episode 1 (an announced premiere) means nothing has aired.
    expect(
      deriveAiredEpisodes({ status: 'RELEASING', totalEpisodes: 12, next: { episode: 1 }, episodes: [], nowMs: NOW }),
    ).toBe(0)
  })

  it('is 0 for an announced part whatever the catalogue advertises', () => {
    expect(
      deriveAiredEpisodes({
        status: 'NOT_YET_RELEASED',
        totalEpisodes: 10,
        next: { episode: 1 },
        episodes: eps(10, NOW + 30 * D),
        nowMs: NOW,
      }),
    ).toBe(0)
  })

  it('counts the dated episode list when a releasing part has no next slot', () => {
    // TMDB nulls next_episode_to_air.air_date while the season still derives as RELEASING; AniList
    // has the same window between a finale airing and status flipping to FINISHED.
    const episodes = eps(10, NOW - 4 * 7 * D) // 5 aired (weeks -4..0), 5 still to come
    expect(deriveAiredEpisodes({ status: 'RELEASING', totalEpisodes: 10, next: null, episodes, nowMs: NOW })).toBe(5)
  })

  it('never reports the user´s own progress for a releasing part with no next slot', () => {
    // The regression this guards: the count must not move with `watched`, and an undated list
    // (AniList streamingEpisodes carry no airDate) cannot prove the advertised run has aired.
    const episodes = eps(12, null)
    expect(deriveAiredEpisodes({ status: 'RELEASING', totalEpisodes: 12, next: null, episodes, nowMs: NOW })).toBe(0)
    expect(deriveAiredEpisodes({ status: 'RELEASING', totalEpisodes: 12, next: null, episodes: [], nowMs: NOW })).toBe(0)
  })

  it('takes the latest aired number, not the count, from a sparse dated list', () => {
    const episodes: EpisodeMeta[] = [
      { number: 1, title: null, airDate: NOW - 14 * D, overview: null, still: null, runtime: null },
      { number: 4, title: null, airDate: NOW - 1 * D, overview: null, still: null, runtime: null },
      { number: 5, title: null, airDate: NOW + 6 * D, overview: null, still: null, runtime: null },
    ]
    expect(deriveAiredEpisodes({ status: 'RELEASING', totalEpisodes: 8, next: null, episodes, nowMs: NOW })).toBe(4)
  })

  it('reports the full run for finished/cancelled parts', () => {
    expect(deriveAiredEpisodes({ status: 'FINISHED', totalEpisodes: 25, next: null, episodes: [], nowMs: NOW })).toBe(25)
    expect(deriveAiredEpisodes({ status: 'CANCELLED', totalEpisodes: 8, next: null, episodes: [], nowMs: NOW })).toBe(8)
    expect(deriveAiredEpisodes({ status: null, totalEpisodes: 0, next: null, episodes: [], nowMs: NOW })).toBe(0)
  })
})

describe('airingsWindow', () => {
  it('lists every dated episode inside the window, oldest first, and nothing outside it', () => {
    // Weekly from 3 weeks ago: episodes 1–2 are past the 8-day floor, 3 aired last week,
    // 4 airs in 4 days, 5 in 11, 6 (in 18) is past the 15-day ceiling.
    const list = eps(6, NOW - 17 * D)
    const out = airingsWindow({ episodes: list, next: null, airedEpisodes: 3, lastAiredAt: null, nowMs: NOW })
    expect(out.map((a) => a.episode)).toEqual([3, 4, 5])
    expect(out[0]?.at).toBe(NOW - 3 * D)
    expect(out[2]?.at).toBe(NOW + 11 * D)
  })

  it('adds the catalogue next slot and lastAiredAt when the list carries no dates (AniList before backfill)', () => {
    const out = airingsWindow({
      episodes: eps(12, null),
      next: { episode: 8, airingAt: (NOW + 2 * D) / 1000 },
      airedEpisodes: 7,
      lastAiredAt: NOW - 5 * D,
      nowMs: NOW,
    })
    expect(out).toEqual([
      { episode: 7, at: NOW - 5 * D },
      { episode: 8, at: NOW + 2 * D },
    ])
  })

  it('lets the per-episode list win over the derived slots on the same episode number', () => {
    const list = eps(10, NOW - 42 * D) // ep n airs at NOW − 42d + (n−1)·7d ⇒ ep 7 = NOW
    const out = airingsWindow({
      episodes: list,
      next: { episode: 8, airingAt: (NOW + 6 * D) / 1000 }, // list says ep 8 = NOW + 7d
      airedEpisodes: 7,
      lastAiredAt: NOW - D, // list says ep 7 = NOW
      nowMs: NOW,
    })
    // 6 (−7d) and 9 (+14d) sit inside the window too; 5 (−14d) and 10 (+21d) do not.
    expect(out).toEqual([
      { episode: 6, at: NOW - 7 * D },
      { episode: 7, at: NOW },
      { episode: 8, at: NOW + 7 * D },
      { episode: 9, at: NOW + 14 * D },
    ])
  })

  it('drops undated, zero-numbered and zero-timestamp entries', () => {
    const out = airingsWindow({
      episodes: [{ number: 0, title: null, airDate: NOW, overview: null, still: null, runtime: null }],
      next: { episode: 3, airingAt: 0 },
      airedEpisodes: 0,
      lastAiredAt: NOW,
      nowMs: NOW,
    })
    expect(out).toEqual([])
  })
})

function part(overrides: Partial<FranchisePart> = {}): FranchisePart {
  return {
    mediaId: 1,
    kind: 'season',
    sequence: 1,
    watchOrder: 1,
    relationship: null,
    optional: false,
    label: 'Season 1',
    title: 'Show',
    cover: '',
    banner: '',
    images: { portrait: null, landscape: null },
    artwork: { portraits: [], landscapes: [], logos: [] },
    format: 'TV',
    status: 'FINISHED',
    isReleasing: false,
    totalEpisodes: 10,
    airedEpisodes: 10,
    nextEpisodeNumber: null,
    nextAiringAt: null,
    release: { precision: 'unknown', at: null, date: null },
    lastAiredAt: null,
    synopsis: '',
    genres: [],
    progress: 0,
    year: 2020,
    studios: [],
    nextAiringCount: 0,
    episodes: [],
    airings: [],
    videos: [],
    ...overrides,
  }
}

function video(scope: FranchiseVideo['scope'], overrides: Partial<FranchiseVideo> = {}): FranchiseVideo {
  return {
    id: 'video',
    site: 'youtube',
    kind: 'trailer',
    title: null,
    url: null,
    thumbnail: null,
    official: true,
    language: 'en',
    country: null,
    publishedAt: null,
    scope,
    ...overrides,
  }
}

describe('deriveContinueWatching', () => {
  it('returns the next already-aired episode with its available context', () => {
    const parts = [part({ progress: 3, airedEpisodes: 7 })]
    const metadata = eps(10, NOW - 70 * D)
    const next = deriveContinueWatching(parts, new Map([[1, metadata]]))

    expect(next).toEqual({ mediaId: 1, partLabel: 'Season 1', episode: metadata[3] })
  })

  it('prefers a started part over an earlier untouched part and never offers a future episode', () => {
    const parts = [
      part({ mediaId: 1, progress: 0, airedEpisodes: 10 }),
      part({ mediaId: 2, sequence: 2, label: 'Season 2', progress: 4, airedEpisodes: 6 }),
      part({ mediaId: 3, sequence: 3, status: 'NOT_YET_RELEASED', progress: 0, airedEpisodes: 0 }),
    ]
    expect(deriveContinueWatching(parts, new Map())).toMatchObject({
      mediaId: 2,
      partLabel: 'Season 2',
      episode: { number: 5 },
    })
    expect(deriveContinueWatching([parts[2]!], new Map())).toBeNull()
  })
})

describe('pickFeaturedVideo', () => {
  it('prefers a future part announcement over an older franchise-level trailer', () => {
    const future = part({ mediaId: 6, sequence: 6, label: 'Season 6', status: 'NOT_YET_RELEASED' })
    const announcement = video(
      { type: 'part', mediaId: 6, label: 'Season 6' },
      { id: 'renewal', kind: 'announcement', publishedAt: '2026-01-05T00:00:00Z' },
    )
    const oldTrailer = video(
      { type: 'franchise' },
      { id: 'old', kind: 'trailer', publishedAt: '2020-01-01T00:00:00Z' },
    )
    expect(pickFeaturedVideo([future], [oldTrailer, announcement])).toEqual(announcement)
  })

  it('prefers a current franchise campaign over a trailer tied to a finished part', () => {
    const finished = part({ mediaId: 1, sequence: 1, label: 'Season 1', status: 'FINISHED' })
    const oldPartTrailer = video(
      { type: 'part', mediaId: 1, label: 'Season 1' },
      { id: 'season-one', kind: 'trailer', publishedAt: '2020-01-01T00:00:00Z' },
    )
    const currentCampaign = video(
      { type: 'franchise' },
      { id: 'current', kind: 'trailer', publishedAt: '2026-05-19T00:00:00Z' },
    )
    expect(pickFeaturedVideo([finished], [oldPartTrailer, currentCampaign])).toEqual(currentCampaign)
  })
})
