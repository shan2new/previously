import { describe, expect, it } from 'vitest'
import type { EpisodeMeta } from '../types/api.js'
import {
  airedCount,
  caughtUpValue,
  clampProgressValue,
  DATE_ONLY_LEAD_MS,
  episodeAccess,
  gatedProgress,
  slotPassed,
  slotStrikesAt,
  type AiredInput,
} from './aired.js'

// Fixed "now": 2026-09-25T12:00Z. Nothing here reads the clock.
const NOW = Date.UTC(2026, 8, 25, 12)
const MIN = 60_000
const H = 3_600_000
const D = 86_400_000

function eps(count: number, firstAirDate: number | null, stepMs = 7 * D): EpisodeMeta[] {
  return Array.from({ length: count }, (_, i) => ({
    number: i + 1,
    title: null,
    airDate: firstAirDate == null ? null : firstAirDate + i * stepMs,
    overview: null,
    still: null,
    runtime: null,
  }))
}

function row(over: Partial<AiredInput>): AiredInput {
  return { source: 'anilist', status: 'RELEASING', episodes: null, next: null, episodesList: [], ...over }
}

/** `next_airing_episode.airingAt` is in SECONDS. */
const sec = (ms: number) => Math.floor(ms / 1000)

describe('slotPassed', () => {
  it('counts a timed (AniList) slot from its instant', () => {
    expect(slotPassed(NOW, 'anilist', NOW)).toBe(true)
    expect(slotPassed(NOW - 1, 'anilist', NOW)).toBe(true)
    expect(slotPassed(NOW + 1, 'anilist', NOW)).toBe(false)
  })

  it('counts a date-only (TMDB) slot from 10:00 UTC on its UTC date — UTC+14 reaching the next day', () => {
    // TMDB's 2026-10-03 is synthesised at 17:00 UTC.
    const at = Date.UTC(2026, 9, 3, 17)
    expect(slotPassed(at, 'tmdb', Date.parse('2026-10-03T09:59:59.999Z'))).toBe(false)
    expect(slotPassed(at, 'tmdb', Date.parse('2026-10-03T10:00:00.000Z'))).toBe(true)
    // Wherever in the day the synthesised instant sits, the date is what counts.
    expect(slotPassed(Date.UTC(2026, 9, 3, 0), 'tmdb', Date.parse('2026-10-03T10:00:00.000Z'))).toBe(true)
    expect(slotPassed(Date.UTC(2026, 9, 3, 23, 59), 'tmdb', Date.parse('2026-10-03T09:59:59.999Z'))).toBe(false)
    expect(DATE_ONLY_LEAD_MS).toBe(14 * H)
  })

  it('strikes at the instant slotPassed counts from: a timed slot its own, a date-only one 10:00 UTC of its date', () => {
    expect(slotStrikesAt(NOW, 'anilist')).toBe(NOW)
    expect(slotStrikesAt(Date.UTC(2026, 9, 3, 17), 'tmdb')).toBe(Date.UTC(2026, 9, 3, 10))
    expect(slotStrikesAt(Date.UTC(2026, 9, 3, 0), 'tmdb')).toBe(Date.UTC(2026, 9, 3, 10))
  })
})

describe('airedCount', () => {
  it('counts a struck AniList slot before the hourly sync advances next (the hour-lag fix)', () => {
    const r = row({ episodes: 12, next: { episode: 8, airingAt: sec(NOW - 30 * MIN) } })
    expect(airedCount(r, NOW)).toEqual({ aired: 8, known: true })
  })

  it('does not count a slot still in the future', () => {
    const r = row({ episodes: 12, next: { episode: 8, airingAt: sec(NOW + 30 * MIN) } })
    expect(airedCount(r, NOW)).toEqual({ aired: 7, known: true })
  })

  it('counts nothing on a part that has not premiered, even with a passed slot', () => {
    const r = row({ status: 'NOT_YET_RELEASED', episodes: 10, next: { episode: 1, airingAt: sec(NOW - H) } })
    expect(airedCount(r, NOW)).toEqual({ aired: 0, known: true })
  })

  it('counts a finished part as its size', () => {
    expect(airedCount(row({ status: 'FINISHED', episodes: 12 }), NOW)).toEqual({ aired: 12, known: true })
  })

  it('does not know the count of a releasing part with no slot, no dates and no size', () => {
    expect(airedCount(row({ episodes: 0, episodesList: eps(3, null) }), NOW)).toEqual({ aired: 0, known: false })
    expect(airedCount(row({ episodes: null, episodesList: null }), NOW)).toEqual({ aired: 0, known: false })
  })

  it('counts a TMDB releasing season from its dated list, on the date-only rule', () => {
    // Episode 1 on 2026-09-04 (17:00 UTC), weekly: episode 4 is 2026-09-25, episode 5 2026-10-02.
    const list = eps(10, Date.UTC(2026, 8, 4, 17))
    const tmdb = row({ source: 'tmdb', episodes: 10, episodesList: list })
    // At 12:00 UTC on the 25th the day after the 25th has begun at UTC+14, so episode 4 counts.
    expect(airedCount(tmdb, NOW)).toEqual({ aired: 4, known: true })
    // At 09:00 UTC it has not, yet: episode 3.
    expect(airedCount(tmdb, Date.UTC(2026, 8, 25, 9))).toEqual({ aired: 3, known: true })
  })

  it('counts a TMDB next slot on the date-only rule', () => {
    const next = { episode: 6, airingAt: sec(Date.UTC(2026, 8, 25, 17)) }
    const tmdb = row({ source: 'tmdb', episodes: 10, next })
    expect(airedCount(tmdb, NOW).aired).toBe(6)
    expect(airedCount(tmdb, Date.UTC(2026, 8, 25, 9)).aired).toBe(5)
  })

  it('ignores a next slot with no instant: it is no evidence of a count', () => {
    const r = row({ episodes: 0, next: { episode: 4, airingAt: 0 } })
    expect(airedCount(r, NOW)).toEqual({ aired: 0, known: false })
    // …so it cannot clamp every mark on the part to 0.
    expect(clampProgressValue(r, 3, NOW)).toBe(3)
  })

  it('knows a releasing part whose first episode has not aired yet has aired nothing', () => {
    const r = row({ episodes: 12, next: { episode: 1, airingAt: sec(NOW + D) } })
    expect(airedCount(r, NOW)).toEqual({ aired: 0, known: true })
    expect(clampProgressValue(r, 1, NOW)).toBe(0)
  })

  it('never counts the catalogue total as aired for a releasing part in a schedule gap', () => {
    // AniList, RELEASING, no next slot (a delayed week), an undated list, 12 announced: the old
    // count said all 12 had aired, which opened rooms 6–12 before they aired.
    const r = row({ episodes: 12, next: null, episodesList: eps(12, null) })
    expect(airedCount(r, NOW)).toEqual({ aired: 0, known: false })
    expect(episodeAccess({ progress: 12, episode: 6, count: airedCount(r, NOW) })).toBe('unaired')
  })

  it('counts a releasing part with no next slot from its dated list', () => {
    // Weekly from 2026-08-21 13:00 UTC: episodes 1–5 have aired by NOW; 6 airs an hour from now.
    const r = row({ episodes: 12, next: null, episodesList: eps(12, Date.UTC(2026, 7, 21, 13)) })
    expect(airedCount(r, NOW)).toEqual({ aired: 5, known: true })
  })

  it('counts a HIATUS part from its evidence, not its size', () => {
    // 24 announced, 10 dated in the past.
    const list = eps(24, null).map((e, i) => (i < 10 ? { ...e, airDate: NOW - (10 - i) * 7 * D } : e))
    expect(airedCount(row({ status: 'HIATUS', episodes: 24, episodesList: list }), NOW)).toEqual({ aired: 10, known: true })
    // No evidence at all: unknown, so the gate stays closed.
    expect(airedCount(row({ status: 'HIATUS', episodes: 24, episodesList: eps(24, null) }), NOW)).toEqual({
      aired: 0,
      known: false,
    })
  })

  it('counts a CANCELLED part from its evidence, not its size', () => {
    const list = eps(12, NOW - 20 * D, 7 * D) // episodes 1–3 dated in the past, 4–12 in the future
    expect(airedCount(row({ status: 'CANCELLED', episodes: 12, episodesList: list }), NOW)).toEqual({
      aired: 3,
      known: true,
    })
    expect(airedCount(row({ status: 'CANCELLED', episodes: 12, episodesList: [] }), NOW).known).toBe(false)
  })
})

describe('clampProgressValue', () => {
  it('caps a releasing 12-episode season with 5 aired at 5, not at 12 (the brief\'s fix)', () => {
    const r = row({ episodes: 12, next: { episode: 6, airingAt: sec(NOW + 2 * D) } })
    expect(clampProgressValue(r, 12, NOW)).toBe(5)
    expect(clampProgressValue(r, 3, NOW)).toBe(3)
  })

  it('leaves an unsized releasing part whose count is unknown unbounded, and caps a sized one at its size', () => {
    expect(clampProgressValue(row({ episodes: null }), 40, NOW)).toBe(40)
    // The gate no longer trusts progress there (unknown → unaired), so the size is the only bound.
    expect(clampProgressValue(row({ episodes: 12, episodesList: eps(12, null) }), 99, NOW)).toBe(12)
    expect(clampProgressValue(row({ episodes: 12, episodesList: eps(12, null) }), 7, NOW)).toBe(7)
  })

  it('bounds only an increase: a stored mark above the ceiling is never pulled down', () => {
    // 5 aired of 12; a legacy mark of 12 exists.
    const r = row({ episodes: 12, next: { episode: 6, airingAt: sec(NOW + 2 * D) } })
    expect(clampProgressValue(r, 11, NOW, 12)).toBe(11) // unmark 12 → 11 writes 11, not 5
    expect(clampProgressValue(r, 12, NOW, 12)).toBe(12)
    expect(clampProgressValue(r, 14, NOW, 12)).toBe(12) // …and cannot climb past what it holds
    expect(clampProgressValue(r, 9, NOW, 3)).toBe(5) // a fresh increase is still capped at aired
    // The same for a size ceiling.
    expect(clampProgressValue(row({ status: 'FINISHED', episodes: 10 }), 11, NOW, 12)).toBe(11)
    // A season that has not premiered holds nothing, whatever was stored.
    expect(clampProgressValue(row({ status: 'NOT_YET_RELEASED', episodes: 10 }), 3, NOW, 5)).toBe(0)
  })

  it('leaves a finished part with no size unbounded, and caps a sized one at its size', () => {
    expect(clampProgressValue(row({ status: 'FINISHED', episodes: null }), 40, NOW)).toBe(40)
    expect(clampProgressValue(row({ status: 'FINISHED', episodes: 12 }), 99, NOW)).toBe(12)
  })

  it('takes 0 on a part that has not premiered', () => {
    expect(clampProgressValue(row({ status: 'NOT_YET_RELEASED', episodes: 13 }), 13, NOW)).toBe(0)
  })

  it('reads NaN, negatives and fractions as whole non-negative counts', () => {
    const finished = row({ status: 'FINISHED', episodes: 12 })
    expect(clampProgressValue(finished, Number.NaN, NOW)).toBe(0)
    expect(clampProgressValue(finished, Number.POSITIVE_INFINITY, NOW)).toBe(0)
    expect(clampProgressValue(finished, -3, NOW)).toBe(0)
    expect(clampProgressValue(finished, 4.9, NOW)).toBe(4)
  })
})

describe('episodeAccess', () => {
  const known = (aired: number) => ({ aired, known: true })

  it('says unaired before unwatched', () => {
    expect(episodeAccess({ progress: 0, episode: 9, count: known(8) })).toBe('unaired')
    expect(episodeAccess({ progress: 20, episode: 9, count: known(8) })).toBe('unaired')
  })

  it('opens at progress == n and stays locked below it', () => {
    expect(episodeAccess({ progress: 8, episode: 8, count: known(8) })).toBe('open')
    expect(episodeAccess({ progress: 7, episode: 8, count: known(8) })).toBe('unwatched')
  })

  it('fails closed on an unknown count: unaired, whatever the progress', () => {
    const unknown = { aired: 0, known: false }
    expect(episodeAccess({ progress: 30, episode: 30, count: unknown })).toBe('unaired')
    expect(episodeAccess({ progress: 99_999, episode: 1, count: unknown })).toBe('unaired')
  })
})

describe('caughtUpValue', () => {
  it('marks what has aired, never less than what is stored', () => {
    const r = row({ episodes: 12, next: { episode: 6, airingAt: sec(NOW + 2 * D) } })
    expect(caughtUpValue(r, NOW)).toBe(5)
    expect(caughtUpValue(r, NOW, 3)).toBe(5)
    expect(caughtUpValue(r, NOW, 12)).toBe(12)
  })

  it('an unknown count falls back to the size, and an unsized one keeps what is stored', () => {
    expect(caughtUpValue(row({ episodes: 12, episodesList: eps(12, null) }), NOW)).toBe(12)
    expect(caughtUpValue(row({ episodes: null }), NOW, 4)).toBe(4)
    expect(caughtUpValue(row({ status: 'FINISHED', episodes: null }), NOW, 4)).toBe(4)
  })

  it('a season that has not premiered takes 0', () => {
    expect(caughtUpValue(row({ status: 'NOT_YET_RELEASED', episodes: 10 }), NOW, 5)).toBe(0)
  })
})

describe('gatedProgress', () => {
  it('holds a stale mark on an unaired season to what has aired (the toPart read guard)', () => {
    expect(gatedProgress('NOT_YET_RELEASED', 13, { aired: 0, known: true })).toBe(0)
    expect(gatedProgress('RELEASING', 13, { aired: 5, known: true })).toBe(13)
    expect(gatedProgress('FINISHED', 12, { aired: 12, known: true })).toBe(12)
  })
})
