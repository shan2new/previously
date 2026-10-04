import { and, asc, eq, isNull, sql } from 'drizzle-orm'
import { db } from '../db/index.js'
import { franchise, watchSessions } from '../db/schema.js'
import type { WatchSession, WatchSessionBody, WatchStatus } from '../types/api.js'

// Watch sessions (`/me/watch-sessions`, docs/api-contract.md "Watch sessions"). The app owns the
// history and writes whole sessions; the server keeps them so a new phone, or a reinstall, gets
// them back. Every query is scoped to the caller.

export type WatchSessionWrite = 'saved' | 'deleted' | 'not_found' | 'franchise_not_found'

type Row = typeof watchSessions.$inferSelect

export function toWatchSession(row: Row): WatchSession {
  return {
    id: row.id,
    franchiseId: row.franchiseId,
    scopeMediaId: row.scopeMediaId,
    ordinal: row.ordinal,
    startedAt: row.startedAt,
    completedAt: row.completedAt,
    cancelledAt: row.cancelledAt,
    cancelledAtEpisode: row.cancelledAtEpisode,
    episodes: row.episodes,
    restoreProgress: row.restoreProgress ?? null,
    restoreStatus: (row.restoreStatus as WatchStatus | null) ?? null,
    updatedAt: row.updatedAt.getTime(),
  }
}

/** The caller's live sessions. Tombstones stay out: a deleted session is gone from every device. */
export async function listWatchSessions(userId: string): Promise<WatchSession[]> {
  const rows = await db
    .select()
    .from(watchSessions)
    .where(and(eq(watchSessions.userId, userId), isNull(watchSessions.deletedAt)))
    .orderBy(asc(watchSessions.franchiseId), asc(watchSessions.ordinal), asc(watchSessions.id))
  return rows.map(toWatchSession)
}

/**
 * Creates or replaces session `id` with `body`. Newest word wins: the client queues one write per
 * session and always sends its whole current state. A tombstoned id answers 'deleted' and is left
 * alone (a replay cannot resurrect it); an id owned by someone else answers 'not_found'.
 */
export async function putWatchSession(userId: string, id: string, body: WatchSessionBody): Promise<WatchSessionWrite> {
  const [known] = await db.select({ id: franchise.id }).from(franchise).where(eq(franchise.id, body.franchiseId)).limit(1)
  if (!known) return 'franchise_not_found'

  const fields = {
    franchiseId: body.franchiseId,
    scopeMediaId: body.scopeMediaId,
    ordinal: body.ordinal,
    startedAt: body.startedAt,
    completedAt: body.completedAt,
    cancelledAt: body.cancelledAt,
    cancelledAtEpisode: body.cancelledAtEpisode,
    episodes: body.episodes,
    restoreProgress: body.restoreProgress,
    restoreStatus: body.restoreStatus,
  }
  const written = await db
    .insert(watchSessions)
    .values({ id, userId, ...fields })
    .onConflictDoUpdate({
      target: watchSessions.id,
      set: { ...fields, updatedAt: sql`now()` },
      // Only the owner's live row is replaced; anything else falls through to the lookup below.
      setWhere: and(eq(watchSessions.userId, userId), isNull(watchSessions.deletedAt)),
    })
    .returning({ id: watchSessions.id })
  if (written.length > 0) return 'saved'

  const [existing] = await db
    .select({ userId: watchSessions.userId, deletedAt: watchSessions.deletedAt })
    .from(watchSessions)
    .where(eq(watchSessions.id, id))
    .limit(1)
  return existing?.userId === userId && existing.deletedAt ? 'deleted' : 'not_found'
}

/**
 * Tombstones session `id`. Idempotent: deleting a session that is already deleted, never reached
 * the server, or belongs to someone else changes nothing.
 */
export async function deleteWatchSession(userId: string, id: string): Promise<void> {
  await db
    .update(watchSessions)
    .set({ deletedAt: sql`now()`, restoreProgress: null, updatedAt: sql`now()` })
    .where(and(eq(watchSessions.id, id), eq(watchSessions.userId, userId), isNull(watchSessions.deletedAt)))
}
