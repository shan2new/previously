import { describe, expect, it } from 'vitest'
import { broadcastTimesBySeason } from './mapping.js'

const e = (season: number, number: number | null, airtime: string, airstamp: string | null) =>
  ({ season, number, airdate: (airstamp ?? '2026-01-01').slice(0, 10), airtime, airstamp })

describe('broadcastTimesBySeason', () => {
  it('keeps timed episodes by season and number', () => {
    const out = broadcastTimesBySeason([
      e(1, 1, '21:00', '2026-09-28T01:00:00+00:00'),
      e(1, 2, '21:00', '2026-10-05T01:00:00+00:00'),
      e(2, 1, '20:00', '2027-01-04T01:00:00+00:00'),
    ])
    expect(out.get(1)).toEqual({ '1': Date.UTC(2026, 8, 28, 1), '2': Date.UTC(2026, 9, 5, 1) })
    expect(out.get(2)).toEqual({ '1': Date.UTC(2027, 0, 4, 1) })
  })

  it('drops streaming drops (no airtime, a noon placeholder), specials and broken stamps', () => {
    const out = broadcastTimesBySeason([
      e(1, 1, '', '2026-10-09T12:00:00+00:00'),
      e(1, null, '21:00', '2026-10-09T01:00:00+00:00'),
      e(0, 1, '21:00', '2026-10-09T01:00:00+00:00'),
      e(1, 2, '21:00', null),
      e(1, 3, '21:00', 'not a date'),
    ])
    expect(out.size).toBe(0)
  })
})
