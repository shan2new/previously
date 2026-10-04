import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

// services/audience.ts: the one place the audience preference is read and turned into a catalogue.
// The database is a fake that answers — or fails — the one query each call issues, so the
// missing-table tolerance (the migration may not have run where this code is served) is exercised
// for real: Postgres answers "undefined_table" as an error with code 42P01.

const fake = vi.hoisted(() => {
  const state = {
    /** What the next reads answer. */
    rows: [] as { audience: string; updatedAt: Date }[],
    /** Thrown by every read and write while set. */
    error: null as unknown,
    reads: 0,
    writes: [] as { values: unknown; set: unknown }[],
  }
  const db = {
    select: () => ({
      from: () => ({
        where: () => ({
          limit: async () => {
            state.reads += 1
            if (state.error) throw state.error
            return state.rows
          },
        }),
      }),
    }),
    insert: () => ({
      values: (values: unknown) => ({
        onConflictDoUpdate: async (conflict: { set: unknown }) => {
          if (state.error) throw state.error
          state.writes.push({ values, set: conflict.set })
        },
      }),
    }),
  }
  return { state, db }
})

vi.mock('../db/index.js', () => ({ db: fake.db, sql: {} }))

const {
  audienceSource,
  inAudience,
  isAudience,
  isMissingTable,
  readAudience,
  resetAudienceState,
  resolveAudience,
  saveAudience,
  sourceFor,
  suggestionSource,
} = await import('./audience.js')

const USER = '11111111-1111-4111-8111-111111111111'
const NOW = Date.UTC(2026, 9, 4, 12)
const CHOSEN = new Date('2026-10-01T00:00:00Z')
/** What postgres.js throws for a relation that does not exist. */
const missingTable = () => Object.assign(new Error('relation "user_audience" does not exist'), { code: '42P01' })

let warn: ReturnType<typeof vi.spyOn>
/** Move the process's clock: the retry after a missing table is measured on it. */
const at = (ms: number) => vi.setSystemTime(ms)

beforeEach(() => {
  vi.useFakeTimers()
  at(NOW)
  fake.state.rows = []
  fake.state.error = null
  fake.state.reads = 0
  fake.state.writes.length = 0
  resetAudienceState()
  warn = vi.spyOn(console, 'warn').mockImplementation(() => {})
})

afterEach(() => {
  vi.useRealTimers()
})

describe('sourceFor / inAudience', () => {
  it('maps an audience to its one catalogue, and both — or no choice — to every catalogue', () => {
    expect(sourceFor('anime')).toBe('anilist')
    expect(sourceFor('tv')).toBe('tmdb')
    expect(sourceFor('both')).toBeNull()
    expect(sourceFor(null)).toBeNull()
    expect(sourceFor(undefined)).toBeNull()
  })

  it('lets every title through for both, and only its own catalogue for a scoped viewer', () => {
    expect(inAudience(null, 'anilist')).toBe(true)
    expect(inAudience(null, 'tmdb')).toBe(true)
    expect(inAudience('anilist', 'anilist')).toBe(true)
    expect(inAudience('anilist', 'tmdb')).toBe(false)
    expect(inAudience('tmdb', 'anilist')).toBe(false)
    // A title whose catalogue is unknown is not suggested to a scoped viewer.
    expect(inAudience('tmdb', undefined)).toBe(false)
    expect(inAudience(null, undefined)).toBe(true)
  })

  it('knows the three audiences and nothing else', () => {
    expect(['anime', 'tv', 'both'].every(isAudience)).toBe(true)
    expect(['all', 'ANIME', '', null, undefined, 1].some(isAudience)).toBe(false)
  })
})

describe('readAudience / resolveAudience', () => {
  it('reads the stored choice', async () => {
    fake.state.rows = [{ audience: 'tv', updatedAt: CHOSEN }]
    expect(await readAudience(USER)).toEqual({ audience: 'tv', updatedAt: CHOSEN })
    expect(await resolveAudience(USER)).toBe('tv')
    expect(await audienceSource(USER)).toBe('tmdb')
  })

  it('treats no row — the viewer has not chosen — as both', async () => {
    expect(await readAudience(USER)).toBeNull()
    expect(await resolveAudience(USER)).toBe('both')
    expect(await audienceSource(USER)).toBeNull()
    expect(warn).not.toHaveBeenCalled()
  })

  it('treats a stored value it does not know as not chosen', async () => {
    fake.state.rows = [{ audience: 'movies', updatedAt: CHOSEN }]
    expect(await readAudience(USER)).toBeNull()
    expect(await resolveAudience(USER)).toBe('both')
  })

  it('never fails when the table does not exist yet: both, logged once, and not asked again for a while', async () => {
    fake.state.error = missingTable()

    expect(await resolveAudience(USER)).toBe('both')
    at(NOW + 1_000)
    expect(await readAudience(USER)).toBeNull()
    at(NOW + 29_000)
    expect(await audienceSource(USER)).toBeNull()

    // One query, one line: a missing table is not re-asked (or re-logged) on every request.
    expect(fake.state.reads).toBe(1)
    expect(warn).toHaveBeenCalledOnce()
    expect(String(warn.mock.calls[0]![0])).toContain('user_audience does not exist yet')

    // It is asked again after 30 seconds — still missing, still silent.
    at(NOW + 31_000)
    expect(await resolveAudience(USER)).toBe('both')
    expect(fake.state.reads).toBe(2)
    expect(warn).toHaveBeenCalledOnce()
  })

  it('picks the preference up without a restart once the migration has run', async () => {
    fake.state.error = missingTable()
    expect(await resolveAudience(USER)).toBe('both')

    fake.state.error = null
    fake.state.rows = [{ audience: 'anime', updatedAt: CHOSEN }]
    // Inside the retry window the table is not asked yet.
    at(NOW + 10_000)
    expect(await resolveAudience(USER)).toBe('both')
    at(NOW + 31_000)
    expect(await resolveAudience(USER)).toBe('anime')
    // And from then on every read is live again.
    fake.state.rows = [{ audience: 'tv', updatedAt: CHOSEN }]
    at(NOW + 31_001)
    expect(await resolveAudience(USER)).toBe('tv')
  })

  it('never fails on any other error either: both, logged once, and asked again on the next request', async () => {
    fake.state.error = new Error('connection terminated')

    expect(await resolveAudience(USER)).toBe('both')
    expect(await resolveAudience(USER)).toBe('both')

    // Not a missing table: nothing is assumed about the next request.
    expect(fake.state.reads).toBe(2)
    expect(warn).toHaveBeenCalledOnce()
    expect(String(warn.mock.calls[0]![0])).toContain('connection terminated')
  })
})

describe('isMissingTable', () => {
  it('recognises undefined_table on the error or on the driver error a wrapper carries', () => {
    expect(isMissingTable(missingTable())).toBe(true)
    expect(isMissingTable(new Error('query failed', { cause: missingTable() }))).toBe(true)
    expect(isMissingTable(Object.assign(new Error('duplicate key'), { code: '23505' }))).toBe(false)
    expect(isMissingTable(new Error('boom'))).toBe(false)
    expect(isMissingTable(null)).toBe(false)
    expect(isMissingTable('42P01')).toBe(false)
  })
})

describe('suggestionSource', () => {
  it('defaults a request with no source to the viewer\'s audience', async () => {
    fake.state.rows = [{ audience: 'anime', updatedAt: CHOSEN }]
    expect(await suggestionSource(USER, undefined)).toBe('anilist')
    fake.state.rows = [{ audience: 'tv', updatedAt: CHOSEN }]
    expect(await suggestionSource(USER, undefined)).toBe('tmdb')
    fake.state.rows = [{ audience: 'both', updatedAt: CHOSEN }]
    expect(await suggestionSource(USER, undefined)).toBeNull()
    fake.state.rows = []
    expect(await suggestionSource(USER, undefined)).toBeNull()
  })

  it('lets an explicit source win, without reading the preference at all', async () => {
    fake.state.rows = [{ audience: 'anime', updatedAt: CHOSEN }]
    expect(await suggestionSource(USER, 'tmdb')).toBe('tmdb')
    expect(await suggestionSource(USER, 'anilist')).toBe('anilist')
    expect(fake.state.reads).toBe(0)
  })

  it('is both when the table does not exist yet', async () => {
    fake.state.error = missingTable()
    expect(await suggestionSource(USER, undefined)).toBeNull()
    expect(await suggestionSource(USER, 'tmdb')).toBe('tmdb')
  })
})

describe('saveAudience', () => {
  it('upserts the choice with the time it was made', async () => {
    expect(await saveAudience(USER, 'anime')).toEqual({ audience: 'anime', updatedAt: new Date(NOW) })
    expect(fake.state.writes).toEqual([
      {
        values: { userId: USER, audience: 'anime', updatedAt: new Date(NOW) },
        set: { audience: 'anime', updatedAt: new Date(NOW) },
      },
    ])
  })

  it('answers null — never throws — when the table does not exist yet, or the write fails', async () => {
    fake.state.error = missingTable()
    expect(await saveAudience(USER, 'tv')).toBeNull()
    fake.state.error = new Error('connection terminated')
    expect(await saveAudience(USER, 'tv')).toBeNull()
    expect(fake.state.writes).toEqual([])
  })

  it('makes reads live again at once when a write lands after the table was missing', async () => {
    fake.state.error = missingTable()
    expect(await resolveAudience(USER)).toBe('both')

    fake.state.error = null
    at(NOW + 1_000)
    expect(await saveAudience(USER, 'tv')).not.toBeNull()
    fake.state.rows = [{ audience: 'tv', updatedAt: new Date(NOW + 1_000) }]
    at(NOW + 2_000)
    expect(await resolveAudience(USER)).toBe('tv')
  })
})
