import { and, asc, desc, eq, inArray, isNull, sql } from 'drizzle-orm'
import { alias } from 'drizzle-orm/pg-core'
import { db } from '../db/index.js'
import { comments, moderationBans, notifications, reports, userProfiles, users } from '../db/schema.js'
import { env } from '../env.js'
import { noticeCommentsHidden, noticeReportsResolved } from './moderationNotices.js'

// Moderation IO (docs/api-contract.md, "Social"; App Review 1.2): the ban list `authenticate`
// checks, and the operator's queue behind `npm run moderation -- …` (scripts/moderation.ts, whose
// argument grammar is the pure scripts/moderationArgs.ts).
//
// Bans are keyed on the Clerk identity, never users.id, so a ban survives DELETE /me.

// ---------- The ban list, as authenticate reads it ----------

export interface BanCache {
  /** True while `clerkId` holds an unlifted ban, as of the last refresh. */
  has(clerkId: string, nowMs?: number): Promise<boolean>
  /** Forget the loaded list so the next check reloads it. */
  invalidate(): void
}

/**
 * A process-wide cache of the active ban list, refreshed when older than `ttlMs` (0 = every check).
 * The refresh is single-flight: concurrent requests that find it stale share one query. When a
 * refresh fails and a list was loaded before, the old list keeps answering (and the next check
 * retries) — a database blip must not lift every ban, nor fail every request that the user upsert
 * right after would have served. With nothing ever loaded (the server restarted before
 * `db:migrate`, or the database was down at boot) it FAILS OPEN: the check answers "not banned",
 * logs `moderation.ban_cache_unavailable` and retries on the next check. The blast radius of a
 * failed load is otherwise the whole API — every authenticated route a 500, `/me/library`
 * included — for a check whose miss costs at most one TTL of a ban.
 *
 * The operator CLI runs in another process, so a ban reaches this cache within one TTL.
 */
export function createBanCache(load: () => Promise<Iterable<string>>, ttlMs: number): BanCache {
  let banned: ReadonlySet<string> | null = null
  let loadedAt = Number.NEGATIVE_INFINITY
  let inflight: Promise<ReadonlySet<string>> | null = null
  let generation = 0

  function refresh(nowMs: number): Promise<ReadonlySet<string>> {
    if (inflight) return inflight
    const startedIn = generation
    const pending = (async () => {
      const next: ReadonlySet<string> = new Set(await load())
      // An `invalidate()` while this was in flight means the list may predate a new ban: answer
      // this request with it, but do not keep it.
      if (startedIn === generation) {
        banned = next
        loadedAt = nowMs
      }
      return next
    })()
    inflight = pending
    pending.then(
      () => {
        if (inflight === pending) inflight = null
      },
      () => {
        if (inflight === pending) inflight = null
      },
    )
    return pending
  }

  return {
    async has(clerkId: string, nowMs: number = Date.now()): Promise<boolean> {
      if (banned && nowMs - loadedAt < ttlMs) return banned.has(clerkId)
      try {
        return (await refresh(nowMs)).has(clerkId)
      } catch (error) {
        const message = 'diagnostic details redacted'
        if (!banned) {
          // Nothing cached: nothing is kept either, so the very next check retries the load.
          console.warn({ event: 'moderation.ban_cache_unavailable', error: message })
          return false
        }
        console.warn('ban list refresh failed; using the previous list:', message)
        return banned.has(clerkId)
      }
    },
    invalidate(): void {
      generation += 1
      loadedAt = Number.NEGATIVE_INFINITY
      inflight = null
    },
  }
}

async function loadActiveBans(): Promise<string[]> {
  const rows = await db
    .select({ clerkId: moderationBans.clerkId })
    .from(moderationBans)
    .where(isNull(moderationBans.liftedAt))
  return rows.map((r) => r.clerkId)
}

const banCache = createBanCache(loadActiveBans, env.SOCIAL_BAN_CACHE_SECONDS * 1000)

/** Whether this Clerk identity is suspended (see `createBanCache` for the freshness contract). */
export function isSuspended(clerkId: string, nowMs?: number): Promise<boolean> {
  return banCache.has(clerkId, nowMs)
}

/** Drop this process's cached ban list (the CLI calls it after a write; a no-op for the server). */
export function invalidateBanCache(): void {
  banCache.invalidate()
}

// ---------- The operator's queue (npm run moderation) ----------

export class ModerationError extends Error {}

const BODY_PREVIEW_CODE_POINTS = 120

function preview(body: string): string {
  const points = [...body.replace(/\s+/g, ' ')]
  return points.length > BODY_PREVIEW_CODE_POINTS ? `${points.slice(0, BODY_PREVIEW_CODE_POINTS).join('')}…` : points.join('')
}

export interface ReportQueueEntry {
  commentId: string
  subject: string
  authorHandle: string | null
  authorClerkId: string
  reportCount: number
  /** Distinct reasons among the listed reports, sorted. */
  reasons: string[]
  /** Reports listed for this comment (open ones, or all with `--all`). */
  reports: number
  hiddenAt: Date | null
  hiddenReason: string | null
  deletedAt: Date | null
  /** The first 120 code points of the body, whitespace flattened. '' once the author deleted it. */
  bodyPreview: string
  /** ms epoch of the oldest listed report: the queue's age. */
  oldestReportAt: number
}

/**
 * Open reports (or every report with `all`), one entry per comment, most-reported first and then
 * the longest-waiting first.
 */
export async function listReportQueue(opts: { all: boolean; limit: number }): Promise<ReportQueueEntry[]> {
  const oldest = sql`min(${reports.createdAt})`
  const rows = await db
    .select({
      commentId: comments.id,
      subject: comments.subject,
      body: comments.body,
      reportCount: comments.reportCount,
      hiddenAt: comments.hiddenAt,
      hiddenReason: comments.hiddenReason,
      deletedAt: comments.deletedAt,
      authorHandle: userProfiles.handle,
      authorClerkId: users.clerkId,
      reasons: sql<string>`string_agg(distinct ${reports.reason}, ',' order by ${reports.reason})`,
      reports: sql<number>`count(${reports.id})::int`.mapWith(Number),
      oldestReportAt: sql<number>`(extract(epoch from ${oldest}) * 1000)::float8`.mapWith(Number),
    })
    .from(reports)
    .innerJoin(comments, eq(comments.id, reports.commentId))
    .innerJoin(users, eq(users.id, comments.userId))
    .leftJoin(userProfiles, eq(userProfiles.userId, comments.userId))
    .where(opts.all ? undefined : isNull(reports.resolvedAt))
    .groupBy(comments.id, users.clerkId, userProfiles.handle)
    .orderBy(desc(comments.reportCount), sql`${oldest} asc`, asc(comments.id))
    .limit(opts.limit)
  return rows.map((r) => ({
    commentId: r.commentId,
    subject: r.subject,
    authorHandle: r.authorHandle,
    authorClerkId: r.authorClerkId,
    reportCount: r.reportCount,
    reasons: (r.reasons ?? '').split(',').filter((x) => x.length > 0),
    reports: r.reports,
    hiddenAt: r.hiddenAt,
    hiddenReason: r.hiddenReason,
    deletedAt: r.deletedAt,
    bodyPreview: preview(r.body),
    oldestReportAt: r.oldestReportAt,
  }))
}

export interface CommentDetail {
  comment: {
    id: string
    subject: string
    franchiseId: string
    parentId: string | null
    body: string
    createdAt: Date
    deletedAt: Date | null
    hiddenAt: Date | null
    hiddenReason: string | null
    reportCount: number
  }
  author: { userId: string; clerkId: string; handle: string | null; displayName: string | null; banned: boolean }
  reports: {
    reporterHandle: string | null
    reporterClerkId: string
    reason: string
    note: string | null
    createdAt: Date
    resolvedAt: Date | null
    resolution: string | null
  }[]
}

/** The full comment, its author (with their ban state) and every report on it, oldest first. */
export async function getCommentDetail(commentId: string): Promise<CommentDetail | null> {
  const [row] = await db
    .select({
      id: comments.id,
      subject: comments.subject,
      franchiseId: comments.franchiseId,
      parentId: comments.parentId,
      body: comments.body,
      createdAt: comments.createdAt,
      deletedAt: comments.deletedAt,
      hiddenAt: comments.hiddenAt,
      hiddenReason: comments.hiddenReason,
      reportCount: comments.reportCount,
      userId: users.id,
      clerkId: users.clerkId,
      handle: userProfiles.handle,
      displayName: userProfiles.displayName,
      banId: moderationBans.clerkId,
    })
    .from(comments)
    .innerJoin(users, eq(users.id, comments.userId))
    .leftJoin(userProfiles, eq(userProfiles.userId, comments.userId))
    .leftJoin(moderationBans, and(eq(moderationBans.clerkId, users.clerkId), isNull(moderationBans.liftedAt)))
    .where(eq(comments.id, commentId))
    .limit(1)
  if (!row) return null

  const reporter = alias(users, 'reporter')
  const reporterProfile = alias(userProfiles, 'reporter_profile')
  const reportRows = await db
    .select({
      reporterHandle: reporterProfile.handle,
      reporterClerkId: reporter.clerkId,
      reason: reports.reason,
      note: reports.note,
      createdAt: reports.createdAt,
      resolvedAt: reports.resolvedAt,
      resolution: reports.resolution,
    })
    .from(reports)
    .innerJoin(reporter, eq(reporter.id, reports.userId))
    .leftJoin(reporterProfile, eq(reporterProfile.userId, reports.userId))
    .where(eq(reports.commentId, commentId))
    .orderBy(asc(reports.createdAt), asc(reports.id))

  return {
    comment: {
      id: row.id,
      subject: row.subject,
      franchiseId: row.franchiseId,
      parentId: row.parentId,
      body: row.body,
      createdAt: row.createdAt,
      deletedAt: row.deletedAt,
      hiddenAt: row.hiddenAt,
      hiddenReason: row.hiddenReason,
      reportCount: row.reportCount,
    },
    author: {
      userId: row.userId,
      clerkId: row.clerkId,
      handle: row.handle,
      displayName: row.displayName,
      banned: row.banId != null,
    },
    reports: reportRows,
  }
}

type Tx = Parameters<Parameters<typeof db.transaction>[0]>[0]

/**
 * Operator-hide `ids` inside `tx`: `hidden_reason = 'operator'`, their open reports resolved as
 * `hidden`, and every notification that hangs off them deleted (a reply alert must not open a
 * comment nobody can see). Both sides are told (services/moderationNotices.ts): the author of each
 * comment that was still up gets `comment_hidden` ('operator'), each reporter whose report this
 * resolved gets `report_resolved` ('hidden'). Those rows hang off no comment, so they survive the
 * delete above.
 */
async function hideIn(tx: Tx, ids: readonly string[]): Promise<{ resolvedReports: number; removedNotifications: number }> {
  if (ids.length === 0) return { resolvedReports: 0, removedNotifications: 0 }
  const now = new Date()
  // Only a comment that was still up is news to its author (an auto-hidden one was told already).
  const wasVisible = await tx
    .select({ id: comments.id })
    .from(comments)
    .where(and(inArray(comments.id, [...ids]), isNull(comments.hiddenAt), isNull(comments.deletedAt)))
  await tx.update(comments).set({ hiddenAt: now, hiddenReason: 'operator' }).where(inArray(comments.id, [...ids]))
  const resolved = await tx
    .update(reports)
    .set({ resolvedAt: now, resolution: 'hidden' })
    .where(and(inArray(reports.commentId, [...ids]), isNull(reports.resolvedAt)))
    .returning({ id: reports.id })
  const removed = await tx
    .delete(notifications)
    .where(inArray(notifications.commentId, [...ids]))
    .returning({ id: notifications.id })
  await noticeCommentsHidden(
    tx,
    wasVisible.map((c) => c.id),
    'operator',
  )
  await noticeReportsResolved(
    tx,
    resolved.map((r) => r.id),
    'hidden',
  )
  return { resolvedReports: resolved.length, removedNotifications: removed.length }
}

async function requireComment(tx: Tx, commentId: string): Promise<void> {
  const [row] = await tx.select({ id: comments.id }).from(comments).where(eq(comments.id, commentId)).limit(1)
  if (!row) throw new ModerationError(`comment ${commentId} not found`)
}

export interface HideResult {
  commentId: string
  resolvedReports: number
  removedNotifications: number
}

export async function hideComment(commentId: string): Promise<HideResult> {
  return db.transaction(async (tx) => {
    await requireComment(tx, commentId)
    return { commentId, ...(await hideIn(tx, [commentId])) }
  })
}

/**
 * Un-hide, and zero `report_count` so it takes N NEW reporters to hide it again (the old ones
 * already hold their one report each). Its open reports are resolved as `dismissed`.
 */
export async function restoreComment(commentId: string): Promise<{ commentId: string; dismissedReports: number }> {
  return db.transaction(async (tx) => {
    await requireComment(tx, commentId)
    await tx
      .update(comments)
      .set({ hiddenAt: null, hiddenReason: null, reportCount: 0 })
      .where(eq(comments.id, commentId))
    const dismissed = await tx
      .update(reports)
      .set({ resolvedAt: new Date(), resolution: 'dismissed' })
      .where(and(eq(reports.commentId, commentId), isNull(reports.resolvedAt)))
      .returning({ id: reports.id })
    // The reporters learn the decision: it stays up.
    await noticeReportsResolved(
      tx,
      dismissed.map((r) => r.id),
      'dismissed',
    )
    return { commentId, dismissedReports: dismissed.length }
  })
}

/** Resolve the open reports as `dismissed`, leaving the comment as it is (visible or hidden). */
export async function dismissReports(commentId: string): Promise<{ commentId: string; dismissedReports: number }> {
  return db.transaction(async (tx) => {
    await requireComment(tx, commentId)
    const dismissed = await tx
      .update(reports)
      .set({ resolvedAt: new Date(), resolution: 'dismissed' })
      .where(and(eq(reports.commentId, commentId), isNull(reports.resolvedAt)))
      .returning({ id: reports.id })
    await noticeReportsResolved(
      tx,
      dismissed.map((r) => r.id),
      'dismissed',
    )
    return { commentId, dismissedReports: dismissed.length }
  })
}

/**
 * Open reports filed before `olderThan` — the hourly nudge (services/moderationAlert.ts): App
 * Review expects a report acted on within 24 hours.
 */
export async function staleOpenReports(olderThan: Date): Promise<{ count: number; oldestAt: number | null }> {
  const [row] = await db
    .select({
      count: sql<number>`count(*)::int`.mapWith(Number),
      oldestAt: sql<number | null>`(extract(epoch from min(${reports.createdAt})) * 1000)::float8`,
    })
    .from(reports)
    .where(and(isNull(reports.resolvedAt), sql`${reports.createdAt} <= ${olderThan}`))
  const oldest = row?.oldestAt
  return { count: row?.count ?? 0, oldestAt: oldest == null ? null : Number(oldest) }
}

export type BanTarget = { kind: 'clerk'; clerkId: string } | { kind: 'handle'; handle: string }

export interface BanResult {
  clerkId: string
  /** users.id, when the identity still has an account. */
  userId: string | null
  handle: string | null
  /** True when an unlifted ban already existed (the reason is refreshed, the start kept). */
  alreadyBanned: boolean
  hiddenComments: number
}

/**
 * Suspend an identity: a `@handle` is resolved through user_profiles to the account's clerk id.
 * The ban row is upserted with `lifted_at = null` (a re-ban after a lift starts a new ban; a ban
 * that is already active keeps its start and takes the new reason if one is given). With
 * `hideComments`, every comment of theirs still visible is operator-hidden the way `hide` does it.
 */
export async function banUser(
  target: BanTarget,
  opts: { reason: string | null; hideComments: boolean },
): Promise<BanResult> {
  const result = await db.transaction(async (tx) => {
    let clerkId: string
    let userId: string | null = null
    let handle: string | null = null
    if (target.kind === 'handle') {
      const [row] = await tx
        .select({ clerkId: users.clerkId, userId: users.id, handle: userProfiles.handle })
        .from(userProfiles)
        .innerJoin(users, eq(users.id, userProfiles.userId))
        .where(eq(userProfiles.handle, target.handle))
        .limit(1)
      if (!row) throw new ModerationError(`no account holds the handle @${target.handle}`)
      ;({ clerkId, userId, handle } = row)
    } else {
      clerkId = target.clerkId
      const [row] = await tx
        .select({ userId: users.id, handle: userProfiles.handle })
        .from(users)
        .leftJoin(userProfiles, eq(userProfiles.userId, users.id))
        .where(eq(users.clerkId, clerkId))
        .limit(1)
      userId = row?.userId ?? null
      handle = row?.handle ?? null
    }

    const [existing] = await tx
      .select({ liftedAt: moderationBans.liftedAt })
      .from(moderationBans)
      .where(eq(moderationBans.clerkId, clerkId))
      .limit(1)
    const alreadyBanned = existing != null && existing.liftedAt == null

    await tx
      .insert(moderationBans)
      .values({ clerkId, reason: opts.reason })
      .onConflictDoUpdate({
        target: moderationBans.clerkId,
        set: {
          liftedAt: null,
          reason: opts.reason == null ? sql`${moderationBans.reason}` : opts.reason,
          createdAt: sql`case when ${moderationBans.liftedAt} is null then ${moderationBans.createdAt} else now() end`,
        },
      })

    let hiddenComments = 0
    if (opts.hideComments && userId) {
      const visible = await tx
        .select({ id: comments.id })
        .from(comments)
        .where(and(eq(comments.userId, userId), isNull(comments.hiddenAt), isNull(comments.deletedAt)))
      await hideIn(
        tx,
        visible.map((c) => c.id),
      )
      hiddenComments = visible.length
    }
    return { clerkId, userId, handle, alreadyBanned, hiddenComments }
  })
  invalidateBanCache()
  return result
}

/** Lift the active ban on `clerkId`. False when there was none. */
export async function unbanUser(clerkId: string): Promise<boolean> {
  const lifted = await db
    .update(moderationBans)
    .set({ liftedAt: new Date() })
    .where(and(eq(moderationBans.clerkId, clerkId), isNull(moderationBans.liftedAt)))
    .returning({ clerkId: moderationBans.clerkId })
  invalidateBanCache()
  return lifted.length > 0
}

export interface ActiveBan {
  clerkId: string
  handle: string | null
  reason: string | null
  createdAt: Date
}

/** Active bans, newest first, with the handle the account wears if it still has one. */
export async function listActiveBans(): Promise<ActiveBan[]> {
  return db
    .select({
      clerkId: moderationBans.clerkId,
      handle: userProfiles.handle,
      reason: moderationBans.reason,
      createdAt: moderationBans.createdAt,
    })
    .from(moderationBans)
    .leftJoin(users, eq(users.clerkId, moderationBans.clerkId))
    .leftJoin(userProfiles, eq(userProfiles.userId, users.id))
    .where(isNull(moderationBans.liftedAt))
    .orderBy(desc(moderationBans.createdAt), asc(moderationBans.clerkId))
}

// ---------- Identity reset (an offensive handle or name, short of a ban) ----------

export interface ResetIdentityResult {
  clerkId: string
  userId: string
  /** What the account wore before the reset; both null when it had no public identity. */
  previousHandle: string | null
  previousDisplayName: string | null
}

/**
 * Clear an account's public identity: `handle` and `display_name` go to null (the accepted rules
 * stay). The account must pick again at its next compose (POST /social/comments answers
 * `handle_required`, and GET /me/profile says `canComment: false`), and until it does its comments
 * leave every thread, which lists only authors who wear a handle. `@handle` resolves through
 * user_profiles; a clerk id through users. Unknown accounts are a ModerationError.
 */
export async function resetIdentity(target: BanTarget): Promise<ResetIdentityResult> {
  return db.transaction(async (tx) => {
    const [row] =
      target.kind === 'handle'
        ? await tx
            .select({
              clerkId: users.clerkId,
              userId: users.id,
              handle: userProfiles.handle,
              displayName: userProfiles.displayName,
            })
            .from(userProfiles)
            .innerJoin(users, eq(users.id, userProfiles.userId))
            .where(eq(userProfiles.handle, target.handle))
            .limit(1)
        : await tx
            .select({
              clerkId: users.clerkId,
              userId: users.id,
              handle: userProfiles.handle,
              displayName: userProfiles.displayName,
            })
            .from(users)
            .leftJoin(userProfiles, eq(userProfiles.userId, users.id))
            .where(eq(users.clerkId, target.clerkId))
            .limit(1)
    if (!row) {
      throw new ModerationError(
        target.kind === 'handle' ? `no account holds the handle @${target.handle}` : `no account for ${target.clerkId}`,
      )
    }
    await tx
      .update(userProfiles)
      .set({ handle: null, displayName: null, updatedAt: new Date() })
      .where(eq(userProfiles.userId, row.userId))
    return {
      clerkId: row.clerkId,
      userId: row.userId,
      previousHandle: row.handle ?? null,
      previousDisplayName: row.displayName ?? null,
    }
  })
}
