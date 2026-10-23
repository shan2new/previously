import { describe, expect, it } from 'vitest'
import { dropInstant, streamingDrop } from './streamingDrops.js'

// TMDB's synthesized instant for a calendar date (tmdb/mapping.ts: 17:00 UTC).
const date = (y: number, m: number, d: number) => Date.UTC(y, m - 1, d, 17)
/** The instant a show on `networks` drops on TMDB's date y-m-d. */
const drops = (networks: string[], y: number, m: number, d: number, countries?: string[]) =>
  dropInstant(streamingDrop(networks, countries)!, date(y, m, d))

describe('streamingDrop', () => {
  it('reads the show\'s FIRST network: a broadcaster first stays a date', () => {
    expect(streamingDrop(['Netflix'])?.zone).toBe('America/Los_Angeles')
    expect(streamingDrop(['Paramount+'])?.hour).toBe(3)
    expect(streamingDrop(['FOX', 'Netflix'])).toBeNull()
    expect(streamingDrop(['MGM+'])).toBeNull()
    expect(streamingDrop(['Tencent Video'])).toBeNull()
    expect(streamingDrop([])).toBeNull()
    expect(streamingDrop(null)).toBeNull()
  })

  it('knows HBO Max by its 2023–25 name too', () => {
    expect(streamingDrop(['Max'])).toEqual(streamingDrop(['HBO Max']))
  })

  it('takes the international time only for a show made outside the US, and the US time when unknown', () => {
    expect(streamingDrop(['Disney+'], ['KR'])?.hour).toBe(3)
    expect(streamingDrop(['Disney+'], ['US'])?.hour).toBe(21)
    expect(streamingDrop(['Disney+'], ['GB', 'US'])?.hour).toBe(21)
    expect(streamingDrop(['Disney+'], null)?.hour).toBe(21)
    expect(streamingDrop(['Disney+'], [])?.hour).toBe(21)
    // A platform with one time keeps it wherever the show was made.
    expect(streamingDrop(['Netflix'], ['KR'])).toEqual(streamingDrop(['Netflix']))
  })
})

describe('dropInstant', () => {
  it('is 12 AM Pacific on TMDB\'s date for Netflix and Prime Video, DST included', () => {
    expect(drops(['Netflix'], 2026, 10, 23)).toBe(Date.UTC(2026, 9, 23, 7)) // PDT
    expect(drops(['Prime Video'], 2026, 11, 6)).toBe(Date.UTC(2026, 10, 6, 8)) // PST
  })

  it('is 3 AM Eastern for Paramount+ and Peacock — the same instant as Pacific midnight', () => {
    expect(drops(['Paramount+'], 2026, 10, 23)).toBe(Date.UTC(2026, 9, 23, 7))
    expect(drops(['Peacock'], 2026, 1, 15)).toBe(Date.UTC(2026, 0, 15, 8))
  })

  it('is 9 PM Eastern for a US original on HBO Max and Disney+, 3 AM Eastern for one made abroad', () => {
    // The Pitt, Thursday 16 Apr 2026: 9 PM EDT is 01:00 UTC on the Friday.
    expect(drops(['Max', 'HBO Max'], 2026, 4, 16, ['US'])).toBe(Date.UTC(2026, 3, 17, 1))
    // A Korean Disney+ series, Wednesday 21 Oct 2026: 4 PM in Seoul.
    expect(drops(['Disney+'], 2026, 10, 21, ['KR'])).toBe(Date.UTC(2026, 9, 21, 7))
  })

  it('is 12 AM Eastern for Hulu', () => {
    expect(drops(['Hulu'], 2025, 10, 28)).toBe(Date.UTC(2025, 9, 28, 4))
  })

  it('reads Apple TV\'s Pacific-dated US originals at 9 PM Pacific — midnight Eastern the next day', () => {
    // Dark Matter S2E9: TMDB says Thursday 22 Oct; it drops Friday 00:00 EDT.
    expect(drops(['Apple TV'], 2026, 10, 22, ['US'])).toBe(Date.UTC(2026, 9, 23, 4))
    // Slow Horses (GB) S6E6: TMDB says Wednesday 21 Oct, the Eastern date itself.
    expect(drops(['Apple TV'], 2026, 10, 21, ['GB'])).toBe(Date.UTC(2026, 9, 21, 4))
  })

  it('lands on its own side of a DST change', () => {
    // 1 Nov 2026: Pacific midnight is still PDT (the clocks go back at 2 AM).
    expect(drops(['Netflix'], 2026, 11, 1)).toBe(Date.UTC(2026, 10, 1, 7))
    // 8 Mar 2026: Pacific midnight is still PST; 3 AM Eastern is already EDT.
    expect(drops(['Netflix'], 2026, 3, 8)).toBe(Date.UTC(2026, 2, 8, 8))
    expect(drops(['Paramount+'], 2026, 3, 8)).toBe(Date.UTC(2026, 2, 8, 7))
  })

  it('reads the UTC calendar date whatever the hour of the stored instant', () => {
    const netflix = streamingDrop(['Netflix'])!
    expect(dropInstant(netflix, Date.UTC(2026, 9, 23, 0))).toBe(Date.UTC(2026, 9, 23, 7))
    expect(dropInstant(netflix, Date.UTC(2026, 9, 23, 23, 59))).toBe(Date.UTC(2026, 9, 23, 7))
  })
})
