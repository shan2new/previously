// Re-file the library rows the status rule (`statusAfterWrites`, services/library.ts) would have
// moved had it existed when their marks were written: a PLANNED show with something watched is
// being watched; a Planned or Watching show whose story is watched through is Watched. Nothing
// else is touched — Watched, Paused and Dropped are the user's own word, and a Watched show whose
// story went on is the app's call (it knows about rewatches).
//
//   npm run status:backfill                 DRY RUN — prints the plan, writes nothing
//   npm run status:backfill -- <clerkId>    one account (dry run)
//   npm run status:backfill -- --apply      writes, one statement per row
//
// 9 Oct 2026: Seven Dials (one finished season, 3 of 3 marked in one write, 17 Sep) sat on Planned
// for three weeks; at least five more rows across production were in the same state.

import { and, eq, inArray } from 'drizzle-orm'
import { db, sql } from '../db/index.js'
import { franchise, franchiseMember, media, progress, subscriptions, users } from '../db/schema.js'
import { derivedStatusAfterProgress, storyWatchedThrough, type StatusMemberRow } from '../services/library.js'
import type { WatchStatus } from '../types/api.js'

const args = process.argv.slice(2).map((arg) => arg.trim())
const apply = args.includes('--apply')
const only = args.find((arg) => !arg.startsWith('--'))
const nowMs = Date.now()

try {
  const rows = await db
    .select({ userId: subscriptions.userId, franchiseId: subscriptions.franchiseId, status: subscriptions.status,
      clerkId: users.clerkId, title: franchise.title })
    .from(subscriptions)
    .innerJoin(users, eq(users.id, subscriptions.userId))
    .innerJoin(franchise, eq(franchise.id, subscriptions.franchiseId))
    .where(only
      ? and(inArray(subscriptions.status, ['planned', 'watching']), eq(users.clerkId, only))
      : inArray(subscriptions.status, ['planned', 'watching']))

  const moves: { userId: string; franchiseId: string; clerkId: string; title: string; from: string; to: WatchStatus }[] = []
  for (const row of rows) {
    const members: StatusMemberRow[] = await db
      .select({
        mediaId: media.id, source: media.source, status: media.status, episodes: media.episodes,
        next: media.nextAiringEpisode, episodesList: media.episodesList, watched: progress.episodesWatched,
        partKind: franchiseMember.partKind, relationship: franchiseMember.relationship, optional: franchiseMember.optional,
      })
      .from(franchiseMember)
      .innerJoin(media, eq(media.id, franchiseMember.mediaId))
      .leftJoin(progress, and(eq(progress.mediaId, media.id), eq(progress.userId, row.userId)))
      .where(eq(franchiseMember.franchiseId, row.franchiseId))
    const watched = new Map(members.map((m) => [m.mediaId, m.watched ?? 0]))
    const to = derivedStatusAfterProgress(row.status as WatchStatus, {
      forward: members.some((m) => (m.watched ?? 0) > 0),
      watchedThrough: storyWatchedThrough(members, watched, nowMs),
    })
    if (to) moves.push({ userId: row.userId, franchiseId: row.franchiseId, clerkId: row.clerkId, title: row.title, from: row.status, to })
  }

  console.log(`[status:backfill] ${rows.length} planned/watching rows read, ${moves.length} to move${apply ? '' : ' (dry run)'}`)
  for (const move of moves) {
    console.log(`  ${move.clerkId.slice(0, 12)}…  ${move.title}: ${move.from} → ${move.to}`)
  }
  if (apply) {
    for (const move of moves) {
      await db.update(subscriptions).set({ status: move.to })
        .where(and(eq(subscriptions.userId, move.userId), eq(subscriptions.franchiseId, move.franchiseId)))
    }
    console.log(`[status:backfill] ${moves.length} rows written`)
  }
} finally {
  await sql.end({ timeout: 5 })
}
