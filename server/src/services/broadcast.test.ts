import { describe, expect, it, vi } from 'vitest'

vi.mock('../db/index.js', () => ({ db: {}, sql: {} }))

const { exactSchedule } = await import('./broadcast.js')

// TMDB's synthesized instant for a calendar date (tmdb/mapping.ts: 17:00 UTC).
const date = (y: number, m: number, d: number) => Date.UTC(y, m - 1, d, 17)
const H = 3_600_000
const ep = (number: number, airDate: number | null) => ({ number, title: null, airDate, overview: null, still: null, runtime: null })

describe('exactSchedule', () => {
  // A Sunday 9 PM ET network slot: 01:00 UTC on Monday, TMDB's date being the Sunday.
  const sun = date(2026, 9, 27)
  const mon1am = Date.UTC(2026, 8, 28, 1)
  const season = [ep(1, sun - 7 * 24 * H), ep(2, sun), ep(3, sun + 7 * 24 * H)]
  const times = { '1': mon1am - 7 * 24 * H, '2': mon1am, '3': mon1am + 7 * 24 * H }

  it('puts every dated episode and the next slot at its broadcast instant', () => {
    const out = exactSchedule({ source: 'tmdb', episodes: season, next: { episode: 3, airingAt: (sun + 7 * 24 * H) / 1000 }, broadcast: times })
    expect(out?.episodes.map((e) => e.airDate)).toEqual([times['1'], times['2'], times['3']])
    expect(out?.next).toEqual({ episode: 3, airingAt: times['3'] / 1000 })
  })

  it('keeps an undated episode as it is, and needs something dated to be exact at all', () => {
    expect(exactSchedule({ source: 'tmdb', episodes: [...season, ep(4, null)], next: null, broadcast: times })?.episodes[3]?.airDate).toBeNull()
    expect(exactSchedule({ source: 'tmdb', episodes: [ep(1, null)], next: null, broadcast: times })).toBeNull()
  })

  it('is all or nothing: one dated episode without a time leaves the whole season on dates', () => {
    expect(exactSchedule({ source: 'tmdb', episodes: season, next: null, broadcast: { '1': times['1'], '2': times['2'] } })).toBeNull()
    expect(exactSchedule({ source: 'tmdb', episodes: season.slice(0, 2), next: { episode: 3, airingAt: (sun + 7 * 24 * H) / 1000 }, broadcast: { '1': times['1'], '2': times['2'] } })).toBeNull()
  })

  it('refuses a time that disagrees with TMDB\'s date (a renumbered season, a moved episode)', () => {
    expect(exactSchedule({ source: 'tmdb', episodes: season, next: null, broadcast: { ...times, '2': mon1am + 3 * 24 * H } })).toBeNull()
  })

  it('refuses a time before the server\'s date-only strike, so a client is never earlier than the gate', () => {
    // 06:00 local in UTC+13 on the Sunday = 17:00 UTC Saturday: before 10:00 UTC Sunday.
    const early = { ...times, '2': Date.UTC(2026, 8, 26, 17) }
    expect(exactSchedule({ source: 'tmdb', episodes: season, next: null, broadcast: early })).toBeNull()
  })

  it('never touches AniList, and needs times to exist', () => {
    expect(exactSchedule({ source: 'anilist', episodes: season, next: null, broadcast: times })).toBeNull()
    expect(exactSchedule({ source: 'tmdb', episodes: season, next: null, broadcast: null })).toBeNull()
  })
})
