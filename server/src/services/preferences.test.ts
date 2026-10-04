import { beforeEach, describe, expect, it, vi } from 'vitest'

// services/preferences.ts: provider ordering (pure), and how the audience — a second, tolerant
// table (services/audience.ts) — rides with the `user_preferences` row on the wire. The database
// is a fake for that one row; the audience's own reads and writes are stubbed.

const fake = vi.hoisted(() => ({
  /** The stored `user_preferences` row, if any. */
  row: null as null | { country: string | null; language: string; providerIds: number[]; updatedAt: Date },
  upserts: [] as Record<string, unknown>[],
  readAudience: vi.fn(),
  saveAudience: vi.fn(),
}))

vi.mock('../db/index.js', () => ({
  db: {
    select: () => ({ from: () => ({ where: () => ({ limit: async () => (fake.row ? [fake.row] : []) }) }) }),
    insert: () => ({
      values: (values: Record<string, unknown>) => ({
        onConflictDoUpdate: () => ({
          returning: async () => {
            fake.upserts.push(values)
            fake.row = values as typeof fake.row
            return [values]
          },
        }),
      }),
    }),
  },
}))
vi.mock('./audience.js', () => ({ readAudience: fake.readAudience, saveAudience: fake.saveAudience }))

const { applyProviderPreferences, getUserPreferences, resolveUserPreferences, updateUserPreferences, withAudience } =
  await import('./preferences.js')

const USER = '11111111-1111-4111-8111-111111111111'
const SAVED = new Date('2026-09-05T00:00:00Z')
const CHOSEN = new Date('2026-10-01T00:00:00Z')

beforeEach(() => {
  fake.row = null
  fake.upserts.length = 0
  fake.readAudience.mockReset().mockResolvedValue(null)
  fake.saveAudience.mockReset().mockImplementation(async (_user: string, audience: string) => ({ audience, updatedAt: CHOSEN }))
})

describe('applyProviderPreferences', () => {
  it('puts saved services first and marks them without disturbing the remaining provider order', () => {
    const result = applyProviderPreferences({
      country: 'IN',
      status: 'available',
      providers: [
        { id: 8, name: 'Netflix', logo: null, access: 'subscription' },
        { id: 283, name: 'Crunchyroll', logo: null, access: 'subscription' },
        { id: 119, name: 'Prime Video', logo: null, access: 'subscription' },
      ],
      link: null,
      attribution: 'JustWatch',
    }, [283])

    expect(result.providers).toEqual([
      { id: 283, name: 'Crunchyroll', logo: null, access: 'subscription', preferred: true },
      { id: 8, name: 'Netflix', logo: null, access: 'subscription' },
      { id: 119, name: 'Prime Video', logo: null, access: 'subscription' },
    ])
  })
})

describe('withAudience', () => {
  const stored = { country: 'IN', language: 'en', providerIds: [8], updatedAt: SAVED.toISOString() }

  it('adds the choice, or null when the viewer has not chosen', () => {
    expect(withAudience(stored, null)).toEqual({ ...stored, audience: null })
    expect(withAudience(stored, { audience: 'anime', updatedAt: CHOSEN }).audience).toBe('anime')
  })

  it('stamps the later of the two writes', () => {
    expect(withAudience(stored, { audience: 'tv', updatedAt: CHOSEN }).updatedAt).toBe(CHOSEN.toISOString())
    expect(withAudience(stored, { audience: 'tv', updatedAt: new Date('2026-08-01T00:00:00Z') }).updatedAt).toBe(SAVED.toISOString())
    // A viewer who only ever chose an audience does not read "never updated".
    expect(withAudience({ ...stored, updatedAt: null }, { audience: 'tv', updatedAt: CHOSEN }).updatedAt).toBe(CHOSEN.toISOString())
    expect(withAudience({ ...stored, updatedAt: null }, null).updatedAt).toBeNull()
  })
})

describe('getUserPreferences', () => {
  it('answers the defaults with audience: null for a viewer who has saved nothing', async () => {
    expect(await getUserPreferences(USER)).toEqual({ country: null, language: 'en', providerIds: [], updatedAt: null, audience: null })
  })

  it('carries the stored row and the chosen audience', async () => {
    fake.row = { country: 'IN', language: 'hi', providerIds: [8], updatedAt: SAVED }
    fake.readAudience.mockResolvedValue({ audience: 'anime', updatedAt: CHOSEN })
    expect(await getUserPreferences(USER)).toEqual({
      country: 'IN',
      language: 'hi',
      providerIds: [8],
      updatedAt: CHOSEN.toISOString(),
      audience: 'anime',
    })
  })

  it('still answers when the audience cannot be read (its table does not exist yet): audience null', async () => {
    fake.row = { country: 'IN', language: 'en', providerIds: [], updatedAt: SAVED }
    // `readAudience` never throws; a missing table reads as "not chosen".
    fake.readAudience.mockResolvedValue(null)
    expect(await getUserPreferences(USER)).toMatchObject({ country: 'IN', audience: null })
  })

  it('does not read the audience for the routes that only need the country and providers', async () => {
    fake.row = { country: 'IN', language: 'en', providerIds: [8], updatedAt: SAVED }
    expect(await resolveUserPreferences(USER, 'us')).toEqual({ country: 'US', language: 'en', providerIds: [8], updatedAt: SAVED.toISOString() })
    expect(fake.readAudience).not.toHaveBeenCalled()
  })
})

describe('updateUserPreferences', () => {
  it('saves the row as ever when the body names no audience, and reports the stored one', async () => {
    fake.readAudience.mockResolvedValue({ audience: 'tv', updatedAt: new Date('2026-08-01T00:00:00Z') })
    const result = await updateUserPreferences(USER, { country: 'IN' })
    expect(result).toMatchObject({ ok: true, preferences: { country: 'IN', language: 'en', providerIds: [], audience: 'tv' } })
    expect(fake.upserts).toHaveLength(1)
    expect(fake.saveAudience).not.toHaveBeenCalled()
  })

  it('saves both when the body names both', async () => {
    const result = await updateUserPreferences(USER, { country: 'IN', audience: 'anime' })
    expect(result).toMatchObject({ ok: true, preferences: { country: 'IN', audience: 'anime', updatedAt: expect.any(String) } })
    expect(fake.upserts).toHaveLength(1)
    expect(fake.saveAudience).toHaveBeenCalledWith(USER, 'anime')
  })

  it('leaves the preferences row alone when the body names only an audience', async () => {
    fake.row = { country: 'IN', language: 'en', providerIds: [8], updatedAt: SAVED }
    const result = await updateUserPreferences(USER, { audience: 'both' })
    expect(result).toEqual({
      ok: true,
      preferences: { country: 'IN', language: 'en', providerIds: [8], updatedAt: CHOSEN.toISOString(), audience: 'both' },
    })
    expect(fake.upserts).toEqual([])
  })

  it('reports audience_unavailable when the choice cannot be stored — after saving the other fields', async () => {
    fake.saveAudience.mockResolvedValue(null)
    const result = await updateUserPreferences(USER, { country: 'IN', providerIds: [8], audience: 'tv' })
    expect(result).toEqual({ ok: false, error: 'audience_unavailable' })
    expect(fake.upserts).toMatchObject([{ userId: USER, country: 'IN', providerIds: [8] }])
  })
})
