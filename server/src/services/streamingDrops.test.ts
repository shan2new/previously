import { describe, expect, it } from 'vitest'
import { dropInstant, streamingDrop } from './streamingDrops.js'

// TMDB's synthesized instant for a calendar date (tmdb/mapping.ts: 17:00 UTC).
const date = (y: number, m: number, d: number) => Date.UTC(y, m - 1, d, 17)

describe('streamingDrop', () => {
  it('reads the show\'s FIRST network: a broadcaster first stays a date', () => {
    expect(streamingDrop(['Netflix'])?.zone).toBe('America/Los_Angeles')
    expect(streamingDrop(['Paramount+'])?.hour).toBe(3)
    expect(streamingDrop(['FOX', 'Netflix'])).toBeNull()
    expect(streamingDrop(['Apple TV'])).toBeNull()
    expect(streamingDrop([])).toBeNull()
    expect(streamingDrop(null)).toBeNull()
  })
})

describe('dropInstant', () => {
  const netflix = streamingDrop(['Netflix'])!
  const prime = streamingDrop(['Prime Video'])!
  const paramount = streamingDrop(['Paramount+'])!

  it('is 12 AM Pacific on TMDB\'s date, DST included', () => {
    expect(dropInstant(netflix, date(2026, 10, 23))).toBe(Date.UTC(2026, 9, 23, 7)) // PDT
    expect(dropInstant(prime, date(2026, 11, 6))).toBe(Date.UTC(2026, 10, 6, 8)) // PST
  })

  it('is 3 AM Eastern for Paramount+ — the same instant as Pacific midnight', () => {
    expect(dropInstant(paramount, date(2026, 10, 23))).toBe(Date.UTC(2026, 9, 23, 7))
    expect(dropInstant(paramount, date(2026, 1, 15))).toBe(Date.UTC(2026, 0, 15, 8))
  })

  it('lands on its own side of a DST change', () => {
    // 1 Nov 2026: Pacific midnight is still PDT (the clocks go back at 2 AM).
    expect(dropInstant(netflix, date(2026, 11, 1))).toBe(Date.UTC(2026, 10, 1, 7))
    // 8 Mar 2026: Pacific midnight is still PST; 3 AM Eastern is already EDT.
    expect(dropInstant(netflix, date(2026, 3, 8))).toBe(Date.UTC(2026, 2, 8, 8))
    expect(dropInstant(paramount, date(2026, 3, 8))).toBe(Date.UTC(2026, 2, 8, 7))
  })

  it('reads the UTC calendar date whatever the hour of the stored instant', () => {
    expect(dropInstant(netflix, Date.UTC(2026, 9, 23, 0))).toBe(Date.UTC(2026, 9, 23, 7))
    expect(dropInstant(netflix, Date.UTC(2026, 9, 23, 23, 59))).toBe(Date.UTC(2026, 9, 23, 7))
  })
})
