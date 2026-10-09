import { eq, getTableName, sql } from 'drizzle-orm'
import type { PgColumn, PgTable } from 'drizzle-orm/pg-core'
import { db } from '../db/index.js'
import { isMissingTable } from './audience.js'
import {
  blocks,
  commentLikes,
  comments,
  episodeRatings,
  feedHides,
  likes,
  notifications,
  progress,
  recommendationFeedback,
  reminders,
  reports,
  saves,
  subscriptions,
  userAudience,
  userPreferences,
  userProfiles,
  users,
  watchSessions,
  clientMutationOperations,
  clientMutationResources,
} from '../db/schema.js'

type Transaction = Parameters<Parameters<typeof db.transaction>[0]>[0]

/**
 * A plan table read by a second-level step: rows of `table` whose `owner` is the caller, and the
 * `key` a child's foreign key points at (the parent's id).
 */
export interface ErasureParent {
  table: PgTable
  key: PgColumn
  owner: PgColumn
}

/**
 * One delete of `DELETE /me`: every row of `table` whose `column` is the caller — or, with `via`,
 * whose `column` points at one of the caller's rows of another plan table (`via.table`).
 */
export interface ErasureStep {
  table: PgTable
  column: PgColumn
  via?: ErasureParent
  /**
   * The table comes with a migration that may not have been applied where this code already runs
   * (the API is served from the working tree): the step is skipped when the table does not exist,
   * instead of failing the erasure. Its rows cascade from `users` once it does.
   */
  optional?: boolean
}

/** The caller's comments, for the rows that hang off them. */
const VIA_COMMENTS: ErasureParent = { table: comments, key: comments.id, owner: comments.userId }

/**
 * Every row that is the user's (owner) or ABOUT the user (the other side of a relationship), in
 * foreign-key-safe order: the rows hanging off the user's comments go before the comments, and the
 * `users` row goes after all of it (the route appends it).
 *
 * Exported so `me.account.test.ts` can hold it against the schema: every foreign key to `users` or
 * to a plan table (whatever its column is called — `actor_user_id`, `blocked_user_id`) must have an
 * owner step, a `via` step that runs before its parent's rows go, or be ON DELETE SET NULL; and
 * every column named like a user id (`…user_id`, `clerk_id`) must have a step or be a disclosed
 * retention.
 *
 * Other people's replies to the user's comments SURVIVE: `comments.parent_id` is ON DELETE SET
 * NULL, so they become top-level comments of the same thread. `comments.report_count` on other
 * people's comments this user reported stays too, as an anonymous aggregate.
 */
export const accountErasurePlan: readonly ErasureStep[] = [
  { table: commentLikes, column: commentLikes.userId }, //                        likes BY the user
  { table: commentLikes, column: commentLikes.commentId, via: VIA_COMMENTS }, //  likes ON the user's comments
  { table: reports, column: reports.userId }, //                                  reports BY the user
  { table: reports, column: reports.commentId, via: VIA_COMMENTS }, //            reports ABOUT the user's comments
  { table: notifications, column: notifications.userId }, //                      the user's inbox
  { table: notifications, column: notifications.actorUserId }, //                 rows about the user's actions in others' inboxes
  { table: notifications, column: notifications.commentId, via: VIA_COMMENTS }, // anything else hanging off their comments
  { table: comments, column: comments.userId }, //                                hard delete; others' replies → parent_id NULL (FK)
  { table: likes, column: likes.userId },
  { table: saves, column: saves.userId },
  { table: reminders, column: reminders.userId },
  { table: feedHides, column: feedHides.userId },
  { table: episodeRatings, column: episodeRatings.userId },
  { table: blocks, column: blocks.userId }, //                                    whom they blocked
  { table: blocks, column: blocks.blockedUserId }, //                             who blocked them
  { table: userProfiles, column: userProfiles.userId }, //                        frees the handle
  { table: subscriptions, column: subscriptions.userId },
  { table: progress, column: progress.userId },
  { table: clientMutationOperations, column: clientMutationOperations.userId },
  { table: clientMutationResources, column: clientMutationResources.userId },
  { table: watchSessions, column: watchSessions.userId }, //                    tombstones included
  { table: userPreferences, column: userPreferences.userId },
  { table: userAudience, column: userAudience.userId, optional: true }, //         migration 0012
  { table: recommendationFeedback, column: recommendationFeedback.userId },
]

/**
 * The tables `DELETE /me` erases before the `users` row itself, derived from the plan (kept for
 * compatibility): if a future table gains a `userId` column and is not in the plan,
 * `me.account.test.ts` fails rather than the deletion quietly leaving that table's rows behind.
 */
export const accountOwnedTableNames: readonly string[] = [
  ...new Set(accountErasurePlan.map((step) => getTableName(step.table))),
]


/** Shared by an explicit deletion and conservative replay of a durably accepted deletion. */
export async function eraseOwnedAccount(tx: Transaction, userId: string): Promise<void> {
  for (const step of accountErasurePlan) {
    const scope = step.via
      ? sql`${step.column} in (select ${step.via.key} from ${step.via.table} where ${step.via.owner} = ${userId})`
      : eq(step.column, userId)
    if (!step.optional) {
      await tx.delete(step.table).where(scope)
      continue
    }
    // Undefined optional tables roll back only their savepoint. Any other error aborts erasure.
    try {
      await tx.transaction(async (savepoint) => { await savepoint.delete(step.table).where(scope) })
    } catch (error) { if (!isMissingTable(error)) throw error }
  }
  await tx.delete(users).where(eq(users.id, userId))
}
