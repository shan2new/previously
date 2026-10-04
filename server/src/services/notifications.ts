import { and, desc, eq, inArray, isNull, notInArray, sql, type SQL } from 'drizzle-orm'
import { db } from '../db/index.js'
import { announcements, blocks, comments, notifications, userProfiles } from '../db/schema.js'
import { AGENT_TEXT_LIMITS, isCleanAgentText, sanitizeAgentText } from '../feed/evidence.js'
import { installmentName } from '../news/installment.js'
import type {
  NotificationItem,
  NotificationNews,
  NotificationsPage,
  PublicUser,
  ReleaseWindow,
} from '../types/api.js'
import { resolveReleaseWindow } from './releaseWindow.js'
import { episodeOpenChecker, type EpisodeOpenCheck } from './episodeGate.js'
import { parseSubject } from '../social/subjects.js'
import { cursorAt, encodeCursor, type KeysetCursor } from '../util/cursor.js'

// The Activity sheet (GET /me/notifications): news rows written by the research job, plus the
// social kinds (a reply to you, likes on your comment) written by the comment transactions.
// Newest first, keyset-paged on (created_at, id), with the unread badge counted under the SAME
// filters — a row the list hides must not keep the bell lit.

/** The kinds that exist only while comments do (`SOCIAL_COMMENTS_ENABLED`). */
export const SOCIAL_NOTIFICATION_KINDS = ['reply', 'like_comment'] as const

/** An excerpt is the first this-many code points of the comment, read live. */
export const EXCERPT_CODE_POINTS = 140

/** One joined row: the notification, its actor's public profile, and the comment it points at. */
export interface NotificationRow {
  id: string
  franchiseId: string
  kind: string
  title: string
  body: string
  createdAt: Date
  readAt: Date | null
  actorUserId: string | null
  actorCount: number
  subject: string | null
  postId: string | null
  commentId: string | null
  /** user_profiles of the actor (left join): null when the actor has no profile yet. */
  actorHandle: string | null
  actorDisplayName: string | null
  /** comments (left join): null when the row has no comment. */
  commentBody: string | null
  commentDeletedAt: Date | null
  commentHiddenAt: Date | null
  /**
   * announcements (left join on `announcement_id`): null for social kinds and once the announcement
   * is gone. Optional only so a hand-built row without them reads as "no announcement".
   */
  newsStatus?: string | null
  newsNext?: string | null
  newsRelease?: string | null
  /** `created_at` exactly as Postgres holds it (µs, UTC): the keyset cursor's `at`. */
  cursorAt: string
}

/** The first `n` code points of `s` — never splits a surrogate pair. */
function firstCodePoints(s: string, n: number): string {
  let out = ''
  let count = 0
  for (const ch of s) {
    if (count === n) break
    out += ch
    count++
  }
  return out
}

/**
 * The public face of whoever did it. `PublicUser` promises a handle and a name, so an actor without
 * both (a liker who never set up a profile — likes do not require one) is sent as `null` and the
 * client words the row without a name; `actorCount` still carries how many people it folds.
 */
function actorOf(row: NotificationRow): PublicUser | null {
  if (!row.actorUserId || !row.actorHandle || !row.actorDisplayName) return null
  return { id: row.actorUserId, handle: row.actorHandle, displayName: row.actorDisplayName }
}

/**
 * The live excerpt: a reply row shows the reply, a like row YOUR liked comment. Null for a row with
 * no comment, and for a comment that has since been deleted (its body is erased) or hidden.
 *
 * A comment in an episode room (`ep:<mediaId>:<n>`) is shown only while that room is OPEN to the
 * recipient NOW (`episodeOpen`, the spoiler gate): a `reset` re-locks rooms, and the reply text must
 * not keep printing in Activity after it. No checker → no excerpt from a room (fail closed).
 */
function excerptOf(row: NotificationRow, episodeOpen?: EpisodeOpenCheck): string | null {
  if (!row.commentId || row.commentBody == null) return null
  if (row.commentDeletedAt != null || row.commentHiddenAt != null) return null
  if (row.commentBody.length === 0) return null
  const room = row.subject ? parseSubject(row.subject) : null
  if (room?.kind === 'episode' && !(episodeOpen?.(room.mediaId, room.episode) ?? false)) return null
  return firstCodePoints(row.commentBody, EXCERPT_CODE_POINTS)
}

/** The media ids of the episode rooms a page of rows points at (for one batched gate query). */
export function episodeRoomMediaIds(rows: readonly Pick<NotificationRow, 'subject' | 'commentId'>[]): number[] {
  const ids = new Set<number>()
  for (const row of rows) {
    if (!row.commentId || !row.subject) continue
    const room = parseSubject(row.subject)
    if (room?.kind === 'episode') ids.add(room.mediaId)
  }
  return [...ids]
}

const UNKNOWN_WINDOW: ReleaseWindow = { date: null, precision: 'unknown', sortKey: null }

/**
 * The structured news fact, read live from the announcement (the feed composer's naming and window
 * rules: `installmentName`, `resolveReleaseWindow`), so the client never words a row from `body` —
 * server English with the raw `release` in it ("Season 2 arrives 2026-11-20").
 *
 * Research text is printed only once it is clean, as in the composer (`sanitizeAgentText`): a name
 * carrying a link or a blocked term leaves the row without facts; a release that cannot be printed
 * is sent as `''` and is no window — only a day-precise date, a structured fact, survives it.
 */
function newsOf(row: NotificationRow): NotificationNews | null {
  if (!row.kind.startsWith('news_') || row.newsStatus == null || row.newsNext == null) return null
  const { name, isMovie } = installmentName(row.newsNext.trim())
  const installment = sanitizeAgentText(name, AGENT_TEXT_LIMITS.installment)
  if (installment == null) return null
  const raw = row.newsRelease ?? ''
  const release = sanitizeAgentText(raw, AGENT_TEXT_LIMITS.release)
  const resolved = resolveReleaseWindow({
    status: row.newsStatus,
    next: row.newsNext,
    release: raw,
    note: null,
    source: null,
    checked: null,
  })
  return {
    status: row.newsStatus,
    installment,
    isMovie,
    release: release ?? '',
    releaseWindow: release == null && resolved.precision !== 'day' ? UNKNOWN_WINDOW : resolved,
  }
}

/** A news row's fallback text, `''` when research's words in it cannot be printed (see `newsOf`). */
function bodyOf(row: NotificationRow): string {
  return row.kind.startsWith('news_') && !isCleanAgentText(row.body) ? '' : row.body
}

/** Pure: one joined row as the wire item (`episodeOpen`: the recipient's spoiler gate, see `excerptOf`). */
export function toNotificationItem(row: NotificationRow, episodeOpen?: EpisodeOpenCheck): NotificationItem {
  return {
    id: row.id,
    franchiseId: row.franchiseId,
    kind: row.kind,
    title: row.title,
    body: bodyOf(row),
    createdAt: row.createdAt.getTime(),
    readAt: row.readAt ? row.readAt.getTime() : null,
    actor: actorOf(row),
    actorCount: row.actorCount,
    subject: row.subject,
    postId: row.postId,
    commentId: row.commentId,
    excerpt: excerptOf(row, episodeOpen),
    news: newsOf(row),
  }
}

/**
 * Pure: a `limit + 1` fetch as a page. The extra row only says there is more; the cursor is the
 * LAST row shown, so the next page starts strictly after it.
 */
export function toNotificationsPage(
  rows: NotificationRow[],
  limit: number,
  unread: number,
  episodeOpen?: EpisodeOpenCheck,
): NotificationsPage {
  const shown = rows.slice(0, limit)
  const last = shown.at(-1)
  return {
    items: shown.map((row) => toNotificationItem(row, episodeOpen)),
    unread,
    nextCursor: rows.length > limit && last ? encodeCursor({ at: last.cursorAt, id: last.id }) : null,
  }
}

/**
 * The filters the list and the unread count share. Needs `comments` LEFT JOINed on
 * `notifications.comment_id`.
 *
 * - the caller's rows only;
 * - an actor blocked in EITHER direction silences the row (both social kinds);
 * - a row about a comment that has since been deleted or hidden is gone with it;
 * - with comments switched off, the social kinds are not listed at all.
 */
function visibleTo(userId: string, includeSocial: boolean): SQL {
  const conditions: SQL[] = [
    eq(notifications.userId, userId),
    sql`not exists (select 1 from ${announcements} where ${announcements.id} = ${notifications.announcementId} and ${announcements.status} = 'retracted')`,
    sql`(${notifications.actorUserId} is null or (
      ${notifications.actorUserId} not in (select ${blocks.blockedUserId} from ${blocks} where ${blocks.userId} = ${userId})
      and ${notifications.actorUserId} not in (select ${blocks.userId} from ${blocks} where ${blocks.blockedUserId} = ${userId})
    ))`,
    sql`(${comments.id} is null or (${comments.deletedAt} is null and ${comments.hiddenAt} is null))`,
  ]
  if (!includeSocial) conditions.push(notInArray(notifications.kind, [...SOCIAL_NOTIFICATION_KINDS]))
  return and(...conditions)!
}

/** Newest-first notifications for a user, keyset-paged, plus the unread count (for badging). */
export async function listNotifications(
  userId: string,
  opts: { limit: number; cursor: KeysetCursor | null; includeSocial: boolean },
): Promise<NotificationsPage> {
  const scope = visibleTo(userId, opts.includeSocial)
  const page = opts.cursor
    ? and(
        scope,
        sql`(${notifications.createdAt}, ${notifications.id}) < (${opts.cursor.at}::timestamptz, ${opts.cursor.id}::uuid)`,
      )!
    : scope

  const rows: NotificationRow[] = await db
    .select({
      id: notifications.id,
      franchiseId: notifications.franchiseId,
      kind: notifications.kind,
      title: notifications.title,
      body: notifications.body,
      createdAt: notifications.createdAt,
      readAt: notifications.readAt,
      actorUserId: notifications.actorUserId,
      actorCount: notifications.actorCount,
      subject: notifications.subject,
      postId: notifications.postId,
      commentId: notifications.commentId,
      actorHandle: userProfiles.handle,
      actorDisplayName: userProfiles.displayName,
      commentBody: comments.body,
      commentDeletedAt: comments.deletedAt,
      commentHiddenAt: comments.hiddenAt,
      newsStatus: announcements.status,
      newsNext: announcements.next,
      newsRelease: announcements.release,
      cursorAt: cursorAt(notifications.createdAt),
    })
    .from(notifications)
    .leftJoin(userProfiles, eq(userProfiles.userId, notifications.actorUserId))
    .leftJoin(comments, eq(comments.id, notifications.commentId))
    .leftJoin(announcements, eq(announcements.id, notifications.announcementId))
    .where(page)
    .orderBy(desc(notifications.createdAt), desc(notifications.id))
    .limit(opts.limit + 1)

  const [countRow] = await db
    .select({ unread: sql<number>`count(*)::int` })
    .from(notifications)
    .leftJoin(comments, eq(comments.id, notifications.commentId))
    .where(and(scope, isNull(notifications.readAt)))

  // One gate query for every episode room the page shows an excerpt from.
  const roomIds = episodeRoomMediaIds(rows.slice(0, opts.limit))
  const episodeOpen = roomIds.length > 0 ? await episodeOpenChecker(userId, roomIds) : undefined
  return toNotificationsPage(rows, opts.limit, countRow?.unread ?? 0, episodeOpen)
}

/** Mark the given notifications read (or all unread ones when ids is omitted). Returns the count. */
export async function markNotificationsRead(userId: string, ids?: string[]): Promise<number> {
  const scope = ids?.length
    ? and(eq(notifications.userId, userId), isNull(notifications.readAt), inArray(notifications.id, ids))
    : and(eq(notifications.userId, userId), isNull(notifications.readAt))
  const updated = await db.update(notifications).set({ readAt: new Date() }).where(scope).returning({ id: notifications.id })
  return updated.length
}
