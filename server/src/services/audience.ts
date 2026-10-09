import { eq } from 'drizzle-orm'
import { db } from '../db/index.js'
import { userAudience } from '../db/schema.js'
import type { Audience, MediaSource } from '../types/api.js'

// The audience preference (docs/api-contract.md, "Audience"): Anime, TV or Both — which catalogue
// the server SUGGESTS titles from for one viewer. A franchise is anime (`source: 'anilist'`) or TV
// (`'tmdb'`), never both, so the whole rule is one comparison: `sourceFor(audience)`.
//
// This file is the one place the preference is read and turned into a catalogue; every surface
// that suggests titles asks it (For you, recommendations, trending, genre browsing, search with no
// explicit `source`). A viewer's own library is never filtered by it.
//
// The table (`user_audience`) arrives with a migration that may not have run yet when this code is
// first served, so a READ never fails a route: no table (or any error) reads as "not chosen", which
// is 'both' — today's behaviour. A WRITE that cannot land says so (`saveAudience` → null).

const AUDIENCES: ReadonlySet<string> = new Set<Audience>(['anime', 'tv', 'both'])

export function isAudience(value: unknown): value is Audience {
  return typeof value === 'string' && AUDIENCES.has(value)
}

/** The catalogue an audience is shown: anime → AniList, TV → TMDB, both (or not chosen) → null = every catalogue. */
export function sourceFor(audience: Audience | null | undefined): MediaSource | null {
  return audience === 'anime' ? 'anilist' : audience === 'tv' ? 'tmdb' : null
}

/** Whether a title of `source` may be suggested to a viewer scoped to `scope` (null = both). */
export function inAudience(scope: MediaSource | null, source: MediaSource | null | undefined): boolean {
  return scope == null || source === scope
}

/** Postgres `undefined_table` (42P01), on the error itself or the driver error a wrapper carries. */
export function isMissingTable(error: unknown): boolean {
  for (let e: unknown = error, depth = 0; e != null && depth < 4; e = (e as { cause?: unknown }).cause, depth++) {
    if ((e as { code?: unknown }).code === '42P01') return true
  }
  return false
}

/** The stored choice. `updatedAt` is when it was last written. */
export interface StoredAudience {
  audience: Audience
  updatedAt: Date
}

/**
 * While the table is known to be missing, reads are not attempted again for this long. Measured on
 * the process's own clock, never a caller's: a job that ranks "as of tomorrow" must not be able to
 * put the retry a day away.
 */
const MISSING_TABLE_RETRY_MS = 30_000
let missingUntil = 0
const warned = new Set<string>()

/** One line per kind of failure per process: a missing table would otherwise log on every request. */
function note(error: unknown): void {
  const missing = isMissingTable(error)
  if (missing) missingUntil = Date.now() + MISSING_TABLE_RETRY_MS
  const kind = missing ? 'missing' : 'error'
  if (warned.has(kind)) return
  warned.add(kind)
  console.warn(
    missing
      ? '[audience] table user_audience does not exist yet (migration not applied): every viewer is treated as "both" until it does'
      : `[audience] the audience could not be read or saved; treating the viewer as "both": diagnostic details redacted`,
  )
}

/**
 * The viewer's stored audience, or null: not chosen yet, a value this code does not know, a table
 * that does not exist yet, or any error. Never throws.
 */
export async function readAudience(userId: string): Promise<StoredAudience | null> {
  if (Date.now() < missingUntil) return null
  try {
    const [row] = await db
      .select({ audience: userAudience.audience, updatedAt: userAudience.updatedAt })
      .from(userAudience)
      .where(eq(userAudience.userId, userId))
      .limit(1)
    missingUntil = 0
    return row && isAudience(row.audience) ? { audience: row.audience, updatedAt: row.updatedAt } : null
  } catch (error) {
    note(error)
    return null
  }
}

/** The audience the server enforces for a viewer: their stored choice, else 'both'. Never throws. */
export async function resolveAudience(userId: string): Promise<Audience> {
  return (await readAudience(userId))?.audience ?? 'both'
}

/** `sourceFor(resolveAudience(userId))`: the one catalogue this viewer is suggested, or null for both. */
export async function audienceSource(userId: string): Promise<MediaSource | null> {
  return sourceFor(await resolveAudience(userId))
}

/**
 * The catalogue a suggestion route reads. An explicit `source` wins — that is how a client lets
 * someone deliberately look across — and with none the viewer's audience decides (null = both
 * catalogues). The preference is only read when it is needed.
 */
export async function suggestionSource(userId: string, requested: MediaSource | undefined): Promise<MediaSource | null> {
  return requested ?? audienceSource(userId)
}

/**
 * Store the viewer's choice. Null when it could not be stored — the table does not exist yet, or
 * the write failed — so the caller can say so instead of pretending. Never throws.
 */
export async function saveAudience(userId: string, audience: Audience): Promise<StoredAudience | null> {
  try {
    const updatedAt = new Date()
    await db
      .insert(userAudience)
      .values({ userId, audience, updatedAt })
      .onConflictDoUpdate({ target: userAudience.userId, set: { audience, updatedAt } })
    missingUntil = 0
    return { audience, updatedAt }
  } catch (error) {
    note(error)
    return null
  }
}

/** Test seam: forget what was learned about the table and what was logged. */
export function resetAudienceState(): void {
  missingUntil = 0
  warned.clear()
}
