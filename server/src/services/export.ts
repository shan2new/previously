import { asc, eq } from 'drizzle-orm'
import { alias } from 'drizzle-orm/pg-core'
import { db } from '../db/index.js'
import {
  blocks,
  commentLikes,
  comments,
  episodeRatings,
  feedHides,
  franchise,
  likes,
  moderationBans,
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
} from '../db/schema.js'
import type { AccountExport, WatchStatus } from '../types/api.js'
import { isAudience, isMissingTable, type StoredAudience } from './audience.js'
import { withAudience } from './preferences.js'
import { toWatchSession } from './watchSessions.js'

// GET /me/export (docs/api-contract.md, "Account export"): everything the server holds FOR the
// caller, as one JSON document. Only the caller's own rows — never who blocked them, never reports
// about their comments, never anyone else's comment text — and the same tables DELETE /me erases,
// plus the one record kept after an erasure: the caller's own ban row (`moderation`), if any.
//
// Every list is one query scoped to the caller, and they all run in ONE read-only, repeatable-read
// transaction, so the document is a consistent snapshot even while the app keeps writing.

/** `previously-export-2026-09-25.json`: the UTC day of the export. */
export function exportFilename(exportedAtMs: number): string {
  return `previously-export-${new Date(exportedAtMs).toISOString().slice(0, 10)}.json`
}

const ms = (d: Date): number => d.getTime()
const msOrNull = (d: Date | null): number | null => (d ? d.getTime() : null)

/** `users.last_opened_at` / `prev_opened_at` are ms epochs where 0 means "never" (services/visits.ts). */
export function openedAtOrNull(v: number | null | undefined): number | null {
  return typeof v === 'number' && Number.isFinite(v) && v > 0 ? v : null
}

/**
 * The caller's ban record, keyed on their Clerk id — the one row the server keeps after an erasure,
 * so an access request must show it. null when the identity was never suspended; a lifted ban is
 * still reported (`suspended: false`, `liftedAt` set).
 */
export function moderationRecord(
  ban: { reason: string | null; createdAt: Date; liftedAt: Date | null } | null | undefined,
): AccountExport['moderation'] {
  if (!ban) return null
  return {
    suspended: ban.liftedAt == null,
    reason: ban.reason,
    since: ms(ban.createdAt),
    liftedAt: msOrNull(ban.liftedAt),
  }
}

/** null when the caller has no users row (it is created by `authenticate`, so only in a race with DELETE /me). */
export async function buildAccountExport(userId: string, nowMs: number = Date.now()): Promise<AccountExport | null> {
  const blockedProfile = alias(userProfiles, 'blocked_profile')

  return db.transaction(
    async (tx) => {
      const [account] = await tx
        .select({
          id: users.id,
          clerkId: users.clerkId,
          createdAt: users.createdAt,
          email: users.email,
          lastOpenedAt: users.lastOpenedAt,
          prevOpenedAt: users.prevOpenedAt,
        })
        .from(users)
        .where(eq(users.id, userId))
        .limit(1)
      if (!account) return null

      const [profile] = await tx
        .select({
          handle: userProfiles.handle,
          displayName: userProfiles.displayName,
          termsAcceptedAt: userProfiles.termsAcceptedAt,
          termsVersion: userProfiles.termsVersion,
          createdAt: userProfiles.createdAt,
          updatedAt: userProfiles.updatedAt,
        })
        .from(userProfiles)
        .where(eq(userProfiles.userId, userId))
        .limit(1)

      // The ban list is keyed on the Clerk identity, not the account (it survives DELETE /me).
      const [ban] = await tx
        .select({ reason: moderationBans.reason, createdAt: moderationBans.createdAt, liftedAt: moderationBans.liftedAt })
        .from(moderationBans)
        .where(eq(moderationBans.clerkId, account.clerkId))
        .limit(1)

      const subscriptionRows = await tx
        .select({
          franchiseId: subscriptions.franchiseId,
          title: franchise.title,
          status: subscriptions.status,
          addedAt: subscriptions.createdAt,
        })
        .from(subscriptions)
        .innerJoin(franchise, eq(franchise.id, subscriptions.franchiseId))
        .where(eq(subscriptions.userId, userId))
        .orderBy(asc(subscriptions.createdAt), asc(subscriptions.franchiseId))

      const progressRows = await tx
        .select({ mediaId: progress.mediaId, episodes: progress.episodesWatched, updatedAt: progress.updatedAt })
        .from(progress)
        .where(eq(progress.userId, userId))
        .orderBy(asc(progress.mediaId))

      const [preferences] = await tx
        .select()
        .from(userPreferences)
        .where(eq(userPreferences.userId, userId))
        .limit(1)

      // The audience has its own table, which a not-yet-applied migration creates. Read inside a
      // SAVEPOINT: "no such table" then undoes only this read (it would otherwise abort the whole
      // snapshot transaction) and the export says what the server holds — no audience.
      let audience: StoredAudience | null = null
      try {
        audience = await tx.transaction(async (savepoint) => {
          const [row] = await savepoint
            .select({ audience: userAudience.audience, updatedAt: userAudience.updatedAt })
            .from(userAudience)
            .where(eq(userAudience.userId, userId))
            .limit(1)
          return row && isAudience(row.audience) ? { audience: row.audience, updatedAt: row.updatedAt } : null
        })
      } catch (error) {
        if (!isMissingTable(error)) throw error
      }

      const feedbackRows = await tx
        .select({ key: recommendationFeedback.key, kind: recommendationFeedback.kind, createdAt: recommendationFeedback.createdAt })
        .from(recommendationFeedback)
        .where(eq(recommendationFeedback.userId, userId))
        .orderBy(asc(recommendationFeedback.createdAt), asc(recommendationFeedback.key))

      // Deleted sessions are included as the tombstones they are, like comments.
      const sessionRows = await tx
        .select()
        .from(watchSessions)
        .where(eq(watchSessions.userId, userId))
        .orderBy(asc(watchSessions.franchiseId), asc(watchSessions.ordinal), asc(watchSessions.id))

      // Soft-deleted comments are included as the tombstones they are (body '' — the text is gone).
      const commentRows = await tx
        .select({
          id: comments.id,
          subject: comments.subject,
          parentId: comments.parentId,
          body: comments.body,
          createdAt: comments.createdAt,
          deletedAt: comments.deletedAt,
          hiddenAt: comments.hiddenAt,
          hiddenReason: comments.hiddenReason,
        })
        .from(comments)
        .where(eq(comments.userId, userId))
        .orderBy(asc(comments.createdAt), asc(comments.id))

      const likeRows = await tx
        .select({ subject: likes.subject, createdAt: likes.createdAt })
        .from(likes)
        .where(eq(likes.userId, userId))
        .orderBy(asc(likes.createdAt), asc(likes.subject))

      const commentLikeRows = await tx
        .select({ commentId: commentLikes.commentId, createdAt: commentLikes.createdAt })
        .from(commentLikes)
        .where(eq(commentLikes.userId, userId))
        .orderBy(asc(commentLikes.createdAt), asc(commentLikes.commentId))

      const saveRows = await tx
        .select({ postId: saves.postId, createdAt: saves.createdAt })
        .from(saves)
        .where(eq(saves.userId, userId))
        .orderBy(asc(saves.createdAt), asc(saves.postId))

      const reminderRows = await tx
        .select({ postId: reminders.postId, createdAt: reminders.createdAt })
        .from(reminders)
        .where(eq(reminders.userId, userId))
        .orderBy(asc(reminders.createdAt), asc(reminders.postId))

      const hideRows = await tx
        .select({ kind: feedHides.kind, target: feedHides.target, createdAt: feedHides.createdAt })
        .from(feedHides)
        .where(eq(feedHides.userId, userId))
        .orderBy(asc(feedHides.createdAt), asc(feedHides.kind), asc(feedHides.target))

      const ratingRows = await tx
        .select({
          mediaId: episodeRatings.mediaId,
          episode: episodeRatings.episode,
          score: episodeRatings.score,
          updatedAt: episodeRatings.updatedAt,
        })
        .from(episodeRatings)
        .where(eq(episodeRatings.userId, userId))
        .orderBy(asc(episodeRatings.mediaId), asc(episodeRatings.episode))

      // Whom the caller blocked, with the handle they wore (null once that account is gone or never
      // picked one). Who blocked the caller is someone else's data and is not exported.
      const blockRows = await tx
        .select({ userId: blocks.blockedUserId, handle: blockedProfile.handle, createdAt: blocks.createdAt })
        .from(blocks)
        .leftJoin(blockedProfile, eq(blockedProfile.userId, blocks.blockedUserId))
        .where(eq(blocks.userId, userId))
        .orderBy(asc(blocks.createdAt), asc(blocks.blockedUserId))

      // Reports the caller FILED. Reports about the caller's comments belong to their reporters.
      const reportRows = await tx
        .select({
          commentId: reports.commentId,
          reason: reports.reason,
          note: reports.note,
          createdAt: reports.createdAt,
          resolvedAt: reports.resolvedAt,
          resolution: reports.resolution,
        })
        .from(reports)
        .where(eq(reports.userId, userId))
        .orderBy(asc(reports.createdAt), asc(reports.commentId))

      const notificationRows = await tx
        .select({
          id: notifications.id,
          kind: notifications.kind,
          franchiseId: notifications.franchiseId,
          title: notifications.title,
          body: notifications.body,
          subject: notifications.subject,
          postId: notifications.postId,
          commentId: notifications.commentId,
          createdAt: notifications.createdAt,
          readAt: notifications.readAt,
        })
        .from(notifications)
        .where(eq(notifications.userId, userId))
        .orderBy(asc(notifications.createdAt), asc(notifications.id))

      const result: AccountExport = {
        exportedAt: nowMs,
        account: {
          id: account.id,
          createdAt: ms(account.createdAt),
          email: account.email,
          lastOpenedAt: openedAtOrNull(account.lastOpenedAt),
          prevOpenedAt: openedAtOrNull(account.prevOpenedAt),
        },
        profile: profile
          ? {
              handle: profile.handle,
              displayName: profile.displayName,
              termsAcceptedAt: msOrNull(profile.termsAcceptedAt),
              termsVersion: profile.termsVersion,
              createdAt: ms(profile.createdAt),
              updatedAt: ms(profile.updatedAt),
            }
          : null,
        moderation: moderationRecord(ban),
        library: {
          subscriptions: subscriptionRows.map((r) => ({
            franchiseId: r.franchiseId,
            title: r.title,
            status: r.status as WatchStatus,
            addedAt: ms(r.addedAt),
          })),
          progress: progressRows.map((r) => ({ mediaId: r.mediaId, episodes: r.episodes, updatedAt: ms(r.updatedAt) })),
          // null only when the server holds neither a preferences row nor an audience.
          preferences: preferences || audience
            ? withAudience(
                {
                  country: preferences?.country ?? null,
                  language: preferences?.language ?? 'en',
                  providerIds: preferences?.providerIds ?? [],
                  updatedAt: preferences ? preferences.updatedAt.toISOString() : null,
                },
                audience,
              )
            : null,
          recommendationFeedback: feedbackRows.map((r) => ({ key: r.key, kind: r.kind, createdAt: ms(r.createdAt) })),
          watchSessions: sessionRows.map((r) => ({ ...toWatchSession(r), deletedAt: msOrNull(r.deletedAt) })),
        },
        social: {
          comments: commentRows.map((r) => ({
            id: r.id,
            subject: r.subject,
            parentId: r.parentId,
            body: r.body,
            createdAt: ms(r.createdAt),
            deletedAt: msOrNull(r.deletedAt),
            hiddenAt: msOrNull(r.hiddenAt),
            hiddenReason: r.hiddenReason,
          })),
          likes: likeRows.map((r) => ({ subject: r.subject, createdAt: ms(r.createdAt) })),
          commentLikes: commentLikeRows.map((r) => ({ commentId: r.commentId, createdAt: ms(r.createdAt) })),
          saves: saveRows.map((r) => ({ postId: r.postId, createdAt: ms(r.createdAt) })),
          reminders: reminderRows.map((r) => ({ postId: r.postId, createdAt: ms(r.createdAt) })),
          hides: hideRows.map((r) => ({ kind: r.kind, target: r.target, createdAt: ms(r.createdAt) })),
          ratings: ratingRows.map((r) => ({
            mediaId: r.mediaId,
            episode: r.episode,
            score: r.score,
            updatedAt: ms(r.updatedAt),
          })),
          blocks: blockRows.map((r) => ({ userId: r.userId, handle: r.handle ?? null, createdAt: ms(r.createdAt) })),
          reports: reportRows.map((r) => ({
            commentId: r.commentId,
            reason: r.reason,
            note: r.note,
            createdAt: ms(r.createdAt),
            resolvedAt: msOrNull(r.resolvedAt),
            resolution: r.resolution,
          })),
          notifications: notificationRows.map((r) => ({
            id: r.id,
            kind: r.kind,
            franchiseId: r.franchiseId,
            title: r.title,
            body: r.body,
            subject: r.subject,
            postId: r.postId,
            commentId: r.commentId,
            createdAt: ms(r.createdAt),
            readAt: msOrNull(r.readAt),
          })),
        },
      }
      return result
    },
    { isolationLevel: 'repeatable read', accessMode: 'read only' },
  )
}
