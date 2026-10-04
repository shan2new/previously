import { describe, expect, it } from 'vitest'
import {
  fromAniListStatus,
  fromMalStatus,
  normalizeTitle,
  planAnimeFranchise,
  planTvFranchise,
  planTvShowAsAnime,
  RECENT_WATCH_MS,
  watchedThrough,
  type AnimeEntry,
  type MemberRow,
  type TvShow,
} from './plan.js'

const NOW = 1_790_000_000_000

function member(mediaId: number, over: Partial<MemberRow> = {}): MemberRow {
  return { mediaId, franchiseId: 'f', partKind: 'season', sequence: mediaId, relationship: null, status: 'FINISHED', released: 12, ...over }
}

function entry(mediaId: number, status: AnimeEntry['status'], progress: number, finished = status === 'completed'): AnimeEntry {
  return { mediaId, status, progress, finished, title: null }
}

function show(over: Partial<TvShow> = {}): TvShow {
  return { tvdbId: 1, title: 'Show', seasons: [], followed: true, forLater: false, archived: false, lastWatchedAt: NOW - 1000, ...over }
}

describe('planAnimeFranchise', () => {
  const members = [member(1), member(2), member(3, { status: 'RELEASING', released: 5 })]

  it('marks a finished entry whole, whatever count the list carried', () => {
    const plan = planAnimeFranchise([entry(1, 'completed', 0)], [member(1)])
    expect(plan).toEqual({ franchiseId: 'f', status: 'completed', parts: [{ mediaId: 1, episodes: 12 }] })
  })

  it('is watching when any part is being watched', () => {
    const plan = planAnimeFranchise([entry(1, 'completed', 12), entry(2, 'completed', 12), entry(3, 'watching', 4)], members)
    expect(plan?.status).toBe('watching')
    expect(plan?.parts).toContainEqual({ mediaId: 3, episodes: 4 })
  })

  it('is NOT completed because one season was: a finished Season 1 with more released is paused, its place kept', () => {
    const plan = planAnimeFranchise([entry(1, 'completed', 12)], [member(1), member(2)])
    expect(plan?.status).toBe('paused')
    expect(plan?.parts).toEqual([{ mediaId: 1, episodes: 12 }])
  })

  it('…and planned when the next season is on their plan-to-watch list', () => {
    const plan = planAnimeFranchise([entry(1, 'completed', 12), entry(2, 'planned', 0)], [member(1), member(2)])
    expect(plan?.status).toBe('planned')
  })

  it('is completed when every released season is watched, extras notwithstanding', () => {
    const withOva = [member(1), member(2), member(9, { partKind: 'ova', released: 2 })]
    expect(planAnimeFranchise([entry(1, 'completed', 12), entry(2, 'completed', 12)], withOva)?.status).toBe('completed')
  })

  it('a rewatch in flight is the finished show, being watched', () => {
    const mapped = fromAniListStatus('REPEATING')!
    const plan = planAnimeFranchise([{ mediaId: 1, progress: 3, title: null, ...mapped }], [member(1)])
    expect(plan).toEqual({ franchiseId: 'f', status: 'watching', parts: [{ mediaId: 1, episodes: 12 }] })
  })

  it('paused outranks dropped, dropped outranks completed, and plan-to-watch alone is planned with no parts', () => {
    expect(planAnimeFranchise([entry(1, 'completed', 12), entry(2, 'paused', 3)], members)?.status).toBe('paused')
    expect(planAnimeFranchise([entry(1, 'completed', 12), entry(2, 'dropped', 3)], members)?.status).toBe('dropped')
    expect(planAnimeFranchise([entry(1, 'planned', 0)], members)).toEqual({ franchiseId: 'f', status: 'planned', parts: [] })
  })

  it('ignores entries that are not this franchise, and plans nothing from none', () => {
    expect(planAnimeFranchise([entry(77, 'watching', 3)], members)).toBeNull()
  })

  it('previews only the progress that can be written, including a known zero aired count', () => {
    expect(planAnimeFranchise([entry(1, 'watching', 99)], [member(1, { released: 5, ceiling: 5 })])?.parts)
      .toEqual([{ mediaId: 1, episodes: 5 }])
    expect(planAnimeFranchise([entry(1, 'completed', 12)], [member(1, { status: 'NOT_YET_RELEASED', released: 0, ceiling: 0 })])?.parts)
      .toEqual([])
  })
})

describe('planTvFranchise', () => {
  const members = [member(101, { sequence: 1, released: 10 }), member(102, { sequence: 2, released: 10 })]

  it('takes the highest episode seen in each season', () => {
    const plan = planTvFranchise(show({ seasons: [{ number: 1, watched: [1, 2, 3, 5] }] }), members, NOW)
    expect(plan?.parts).toEqual([{ mediaId: 101, episodes: 5 }])
  })

  it('caps a TV preview to what can actually be stored', () => {
    expect(planTvFranchise(show({ seasons: [{ number: 1, watched: [99] }] }), members, NOW)?.parts)
      .toEqual([{ mediaId: 101, episodes: 10 }])
  })

  it('part-way and watched lately is watching; part-way and long untouched is paused', () => {
    const seasons = [{ number: 1, watched: [1, 2, 3] }]
    expect(planTvFranchise(show({ seasons }), members, NOW)?.status).toBe('watching')
    expect(planTvFranchise(show({ seasons, lastWatchedAt: NOW - RECENT_WATCH_MS - 1 }), members, NOW)?.status).toBe('paused')
    expect(planTvFranchise(show({ seasons, lastWatchedAt: null }), members, NOW)?.status).toBe('paused')
  })

  it('watched through is completed, or watching while more is on the way', () => {
    const all = [{ number: 1, watched: [10] }, { number: 2, watched: [10] }]
    expect(planTvFranchise(show({ seasons: all }), members, NOW)?.status).toBe('completed')
    const airing = [...members, member(103, { sequence: 3, status: 'NOT_YET_RELEASED', released: 0 })]
    expect(planTvFranchise(show({ seasons: all }), airing, NOW)?.status).toBe('watching')
  })

  it('nothing watched: planned when followed, not imported when archived or never kept', () => {
    expect(planTvFranchise(show(), members, NOW)).toEqual({ franchiseId: 'f', status: 'planned', parts: [] })
    expect(planTvFranchise(show({ archived: true }), members, NOW)).toBeNull()
    expect(planTvFranchise(show({ followed: false }), members, NOW)).toBeNull()
  })

  it('an archived show part-way is paused, and a season the catalogue lacks is left out', () => {
    const plan = planTvFranchise(show({ archived: true, seasons: [{ number: 1, watched: [4] }, { number: 7, watched: [2] }] }), members, NOW)
    expect(plan).toEqual({ franchiseId: 'f', status: 'paused', parts: [{ mediaId: 101, episodes: 4 }] })
  })
})

describe('planTvShowAsAnime', () => {
  it('lays the episodes seen along the story in order, specials aside', () => {
    const members = [member(1, { released: 25 }), member(2, { released: 12 }), member(3, { released: 12 })]
    const seen = show({ seasons: [{ number: 0, watched: [1, 2] }, { number: 1, watched: range(1, 30) }] })
    expect(planTvShowAsAnime(seen, members, NOW)?.parts).toEqual([{ mediaId: 1, episodes: 25 }, { mediaId: 2, episodes: 5 }])
  })

  it('every episode seen is the story watched through', () => {
    const members = [member(1, { released: 25 }), member(2, { released: 12 })]
    const seen = show({ seasons: [{ number: 1, watched: range(1, 25) }, { number: 2, watched: range(1, 12) }] })
    expect(planTvShowAsAnime(seen, members, NOW)?.status).toBe('completed')
  })
})

describe('watchedThrough', () => {
  it('needs every released season, and nothing of an announced one', () => {
    const members = [member(1), member(2, { status: 'NOT_YET_RELEASED', released: 0 })]
    expect(watchedThrough(members, new Map([[1, 12]]))).toBe(true)
    expect(watchedThrough(members, new Map([[1, 11]]))).toBe(false)
    expect(watchedThrough([], new Map())).toBe(false)
  })

  it('a spin-off season does not hold the story open; a film series is its films', () => {
    const members = [member(1), member(2, { relationship: 'SPIN_OFF' })]
    expect(watchedThrough(members, new Map([[1, 12]]))).toBe(true)
    const films = [member(5, { partKind: 'movie', released: 1 }), member(6, { partKind: 'movie', released: 1 })]
    expect(watchedThrough(films, new Map([[5, 1]]))).toBe(false)
    expect(watchedThrough(films, new Map([[5, 1], [6, 1]]))).toBe(true)
  })
})

describe('source vocabularies', () => {
  it('reads MyAnimeList statuses as words and as the older numbers', () => {
    expect(fromMalStatus('Watching')?.status).toBe('watching')
    expect(fromMalStatus('On-Hold')?.status).toBe('paused')
    expect(fromMalStatus('Plan to Watch')?.status).toBe('planned')
    expect(fromMalStatus('2')).toEqual({ status: 'completed', finished: true })
    expect(fromMalStatus('Reading')).toBeNull()
  })

  it('compares titles without case, punctuation or a trailing year', () => {
    expect(normalizeTitle('The Office (2005)')).toBe(normalizeTitle('the office'))
    expect(normalizeTitle('Re:ZERO -Starting Life in Another World-')).toBe('re zero starting life in another world')
  })
})

function range(a: number, b: number): number[] {
  return Array.from({ length: b - a + 1 }, (_, i) => a + i)
}
