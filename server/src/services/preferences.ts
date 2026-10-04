import { eq } from 'drizzle-orm'
import { db } from '../db/index.js'
import { userPreferences } from '../db/schema.js'
import type { Audience, UserPreferences, WatchAvailability } from '../types/api.js'
import { readAudience, saveAudience, type StoredAudience } from './audience.js'

/**
 * What the `user_preferences` row holds: everything but the audience, which lives in its own table
 * (services/audience.ts) and is only read where a response carries it (`getUserPreferences`).
 */
export type StoredPreferences = Omit<UserPreferences, 'audience'>

const DEFAULTS: StoredPreferences = { country: null, language: 'en', providerIds: [], updatedAt: null }

/** The `user_preferences` row, or the defaults. */
export async function getStoredPreferences(userId: string): Promise<StoredPreferences> {
  const [row] = await db.select().from(userPreferences).where(eq(userPreferences.userId, userId)).limit(1)
  if (!row) return DEFAULTS
  return {
    country: row.country,
    language: row.language,
    providerIds: row.providerIds ?? [],
    updatedAt: row.updatedAt.toISOString(),
  }
}

/**
 * The wire preferences: the stored row plus the audience (null = not chosen). `updatedAt` is the
 * later of the two writes, so a viewer who only ever chose an audience does not read "never".
 */
export function withAudience(stored: StoredPreferences, audience: StoredAudience | null): UserPreferences {
  const chosenAt = audience ? audience.updatedAt.toISOString() : null
  const updatedAt = stored.updatedAt != null && chosenAt != null
    ? (Date.parse(chosenAt) > Date.parse(stored.updatedAt) ? chosenAt : stored.updatedAt)
    : (stored.updatedAt ?? chosenAt)
  return { ...stored, updatedAt, audience: audience?.audience ?? null }
}

/** `GET /me/preferences`. The audience read never fails it (no table yet → `audience: null`). */
export async function getUserPreferences(userId: string): Promise<UserPreferences> {
  const [stored, audience] = await Promise.all([getStoredPreferences(userId), readAudience(userId)])
  return withAudience(stored, audience)
}

export type PreferencesUpdate = { country?: string | null; language?: string; providerIds?: number[]; audience?: Audience }

/**
 * `PUT /me/preferences`. The row's fields are saved first, as ever; then the audience, when the
 * body names one. An audience that cannot be stored (its table does not exist yet) is reported as
 * `audience_unavailable` — AFTER the other fields were saved — rather than silently dropped. A body
 * that names only an audience leaves the `user_preferences` row alone.
 */
export async function updateUserPreferences(
  userId: string,
  value: PreferencesUpdate,
): Promise<{ ok: true; preferences: UserPreferences } | { ok: false; error: 'audience_unavailable' }> {
  const { audience, ...fields } = value
  const onlyAudience = audience !== undefined && Object.values(fields).every((field) => field === undefined)
  const stored = onlyAudience ? await getStoredPreferences(userId) : await saveUserPreferences(userId, fields)
  if (audience === undefined) return { ok: true, preferences: withAudience(stored, await readAudience(userId)) }
  const saved = await saveAudience(userId, audience)
  return saved ? { ok: true, preferences: withAudience(stored, saved) } : { ok: false, error: 'audience_unavailable' }
}

export async function saveUserPreferences(
  userId: string,
  value: { country?: string | null; language?: string; providerIds?: number[] },
): Promise<StoredPreferences> {
  const previous = await getStoredPreferences(userId)
  const next = {
    country: value.country === undefined ? previous.country : value.country,
    language: value.language ?? previous.language,
    providerIds: value.providerIds ?? previous.providerIds,
    updatedAt: new Date(),
  }
  const [row] = await db
    .insert(userPreferences)
    .values({ userId, ...next })
    .onConflictDoUpdate({
      target: userPreferences.userId,
      set: next,
    })
    .returning()
  return {
    country: row!.country,
    language: row!.language,
    providerIds: row!.providerIds ?? [],
    updatedAt: row!.updatedAt.toISOString(),
  }
}

export async function resolveUserCountry(userId: string, override?: string | null): Promise<string | null> {
  return (await resolveUserPreferences(userId, override)).country
}

export async function resolveUserPreferences(
  userId: string,
  countryOverride?: string | null,
): Promise<StoredPreferences> {
  const value = await getStoredPreferences(userId)
  return countryOverride ? { ...value, country: countryOverride.toUpperCase() } : value
}

/** Put explicitly preferred services first while retaining TMDB/JustWatch order for everything else. */
export function applyProviderPreferences(
  availability: WatchAvailability,
  providerIds: number[],
): WatchAvailability {
  if (providerIds.length === 0) return availability
  const rank = new Map(providerIds.map((id, index) => [id, index]))
  return {
    ...availability,
    providers: availability.providers
      .map((provider, index) => ({ provider, index }))
      .sort((a, b) => {
        const ar = rank.get(a.provider.id)
        const br = rank.get(b.provider.id)
        if (ar != null && br != null) return ar - br
        if (ar != null) return -1
        if (br != null) return 1
        return a.index - b.index
      })
      .map(({ provider }) => ({ ...provider, ...(rank.has(provider.id) ? { preferred: true } : {}) })),
  }
}
