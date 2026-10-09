import { and, eq, gt, inArray, sql } from 'drizzle-orm'
import { db } from '../db/index.js'
import { franchise, franchiseMember, media, progress, subscriptions, users } from '../db/schema.js'
import type { EpisodeMeta, FranchiseProgressCommandResponse, WatchStatus } from '../types/api.js'
import { airedCount, caughtUpValue, clampProgressValue, type AiredInput } from './aired.js'
import { withClientMutation, type ClientMutationContext, type MutationConnection, type MutationScope } from './clientMutations.js'
import { spine, type MemberRow } from '../import/plan.js'

/** Subscribe to a franchise. Defaults status to `watching` if any part is releasing, else `planned`. */
export async function subscribe(userId: string, franchiseId: string, status?: WatchStatus,
  context?: ClientMutationContext, connection: MutationConnection = db): Promise<boolean> {
  if (context) return withClientMutation(context, 'subscribe', { franchiseId, status }, async (tx, scope) => {
    if (!await scope.apply([`subscription:${franchiseId}`])) return false
    return subscribe(userId, franchiseId, status, undefined, tx)
  })
  let resolved = status
  if (!resolved) {
    const members = await connection
      .select({ mediaId: franchiseMember.mediaId })
      .from(franchiseMember)
      .where(eq(franchiseMember.franchiseId, franchiseId))
    const ids = members.map((m) => m.mediaId)
    const releasing = ids.length
      ? await connection.select({ id: media.id }).from(media).where(and(inArray(media.id, ids), eq(media.status, 'RELEASING')))
      : []
    resolved = releasing.length > 0 ? 'watching' : 'planned'
  }
  await connection
    .insert(subscriptions)
    .values({ userId, franchiseId, status: resolved })
    .onConflictDoUpdate({ target: [subscriptions.userId, subscriptions.franchiseId], set: { status: resolved } })
  return true
}

export async function setSubscriptionStatus(userId: string, franchiseId: string, status: WatchStatus,
  context?: ClientMutationContext, connection: MutationConnection = db): Promise<boolean> {
  if (context) return withClientMutation(context, 'subscription_status', { franchiseId, status }, async (tx, scope) => {
    if (!await scope.apply([`subscription:${franchiseId}`])) return false
    return setSubscriptionStatus(userId, franchiseId, status, undefined, tx)
  })
  await connection
    .update(subscriptions)
    .set({ status })
    .where(and(eq(subscriptions.userId, userId), eq(subscriptions.franchiseId, franchiseId)))
  return true
}

export async function unsubscribe(userId: string, franchiseId: string,
  context?: ClientMutationContext, connection: MutationConnection = db): Promise<boolean> {
  if (context) return withClientMutation(context, 'unsubscribe', { franchiseId }, async (tx, scope) => {
    const key = `subscription:${franchiseId}`
    if (!await scope.apply([key], { deleted: [key] })) return false
    return unsubscribe(userId, franchiseId, undefined, tx)
  })
  await connection
    .delete(subscriptions)
    .where(and(eq(subscriptions.userId, userId), eq(subscriptions.franchiseId, franchiseId)))
  return true
}

export type SetProgressResult = { ok: true; episodes: number; applied?: boolean } | { ok: false; reason: 'media_not_found' }

/**
 * Store one part's watched count, clamped by `clampProgressValue` (services/aired.ts):
 *
 * - a NOT_YET_RELEASED part takes 0 — a season that has not premiered cannot have been watched;
 * - a RELEASING part takes at most what has AIRED by now (a slot that struck counts before the
 *   hourly sync advances `next`). The old ceiling was the season's size, `max(episodes, aired)`,
 *   which let a 12-episode season with 5 aired be marked to 12 — and that mark then opened
 *   episode rooms for episodes nobody could have seen;
 * - anything else takes at most its size, `max(episodes, aired)`. Unsized stays unbounded.
 *
 * The ceiling bounds only an INCREASE: the stored count stays reachable, so a mark written before
 * the aired ceiling existed (12 of a season with 5 aired) is never pulled down by the next write —
 * unmarking 12 → 11 stores 11, not 5 ("a progress mark never rolls back").
 *
 * Belt-and-braces against any client with an unbounded "+1" control: one such control walked a
 * 10-episode season up to 59 watched, and a bad value written once stays wrong until something
 * overwrites it. The client must bound itself to a number no higher (`FranchisePart.progressCeiling`
 * = its aired-by-now count for a releasing part, which never exceeds the server's), or the server
 * cuts a mark the client showed.
 *
 * An unknown `mediaId` writes NOTHING and says so (the route answers 404 `media not found`, which is
 * final): it used to be written unclamped, a row no read would ever surface.
 */
export async function setProgress(userId: string, mediaId: number, episodes: number,
  context?: ClientMutationContext, connection: MutationConnection = db): Promise<SetProgressResult> {
  if (context) return withClientMutation(context, 'progress', { mediaId, episodes }, async (tx, scope) => {
    const planned = await planProgressWrite(tx, userId, mediaId, episodes)
    if (!planned.ok) return planned
    const { plan } = planned
    // The show's subscription is the mark's barrier: an unsubscribe sequenced after this mark wins.
    const applied = await scope.apply([`media:${mediaId}`], { barriers: plan.franchiseIds.map((id) => `subscription:${id}`) })
    if (!applied) {
      const [saved] = await tx.select({ episodes: progress.episodesWatched }).from(progress)
        .where(and(eq(progress.userId, userId), eq(progress.mediaId, mediaId))).limit(1)
      return { ok: true, episodes: saved?.episodes ?? 0, applied: false }
    }
    // A status the mark moves is a word on the subscription, sequenced like the client's own: a
    // status this writer already set LATER keeps its place, and the mark still lands on its own.
    const statusWrites: ProgressWritePlan['statusWrites'] = []
    for (const write of plan.statusWrites) {
      if (await scope.apply([`subscription:${write.franchiseId}`])) statusWrites.push(write)
    }
    await commitProgressWrite(tx, userId, { ...plan, statusWrites })
    return { ok: true, episodes: plan.episodes, applied: true }
  })
  const planned = await planProgressWrite(connection, userId, mediaId, episodes)
  if (!planned.ok) return planned
  await commitProgressWrite(connection, userId, planned.plan)
  return { ok: true, episodes: planned.plan.episodes }
}

interface ProgressWritePlan {
  mediaId: number
  /** The count after the clamp. */
  episodes: number
  /** Every franchise the part belongs to (its subscription is the write's barrier). */
  franchiseIds: string[]
  /** The subscription statuses this write moves (`statusAfterWrites`). */
  statusWrites: { franchiseId: string; status: WatchStatus }[]
}

/** The clamp and the status rule, read before anything is written. */
async function planProgressWrite(connection: MutationConnection, userId: string, mediaId: number, episodes: number,
  nowMs: number = Date.now()): Promise<{ ok: true; plan: ProgressWritePlan } | { ok: false; reason: 'media_not_found' }> {
  const [row] = await connection
    .select({
      source: media.source,
      status: media.status,
      episodes: media.episodes,
      next: media.nextAiringEpisode,
      episodesList: media.episodesList,
      watched: progress.episodesWatched,
    })
    .from(media)
    .leftJoin(progress, and(eq(progress.mediaId, media.id), eq(progress.userId, userId)))
    .where(eq(media.id, mediaId))
    .limit(1)
  if (!row) return { ok: false, reason: 'media_not_found' }
  const clamped = clampProgressValue(toAiredInput(row), episodes, nowMs, row.watched ?? 0)
  const memberships = await connection.select({ id: franchiseMember.franchiseId }).from(franchiseMember)
    .where(eq(franchiseMember.mediaId, mediaId))
  const franchiseIds = memberships.map((membership) => membership.id)
  const statusWrites: ProgressWritePlan['statusWrites'] = []
  for (const franchiseId of franchiseIds) {
    const [subscription] = await connection.select({ status: subscriptions.status }).from(subscriptions)
      .where(and(eq(subscriptions.userId, userId), eq(subscriptions.franchiseId, franchiseId))).limit(1)
    if (!subscription) continue
    const status = statusAfterWrites(subscription.status as WatchStatus, await statusMemberRows(connection, userId, franchiseId),
      [{ mediaId, episodes: clamped }], nowMs)
    if (status) statusWrites.push({ franchiseId, status })
  }
  return { ok: true, plan: { mediaId, episodes: clamped, franchiseIds, statusWrites } }
}

async function commitProgressWrite(connection: MutationConnection, userId: string, plan: ProgressWritePlan): Promise<void> {
  const now = new Date()
  await connection
    .insert(progress)
    .values({ userId, mediaId: plan.mediaId, episodesWatched: plan.episodes, updatedAt: now })
    .onConflictDoUpdate({
      target: [progress.userId, progress.mediaId],
      set: { episodesWatched: plan.episodes, updatedAt: now },
    })
  for (const write of plan.statusWrites) {
    await connection.update(subscriptions).set({ status: write.status })
      .where(and(eq(subscriptions.userId, userId), eq(subscriptions.franchiseId, write.franchiseId)))
  }
}

/** A franchise's member rows with the caller's counts, as `statusAfterWrites` reads them. */
async function statusMemberRows(connection: MutationConnection, userId: string, franchiseId: string): Promise<StatusMemberRow[]> {
  return connection
    .select({
      mediaId: media.id,
      source: media.source,
      status: media.status,
      episodes: media.episodes,
      next: media.nextAiringEpisode,
      episodesList: media.episodesList,
      watched: progress.episodesWatched,
      partKind: franchiseMember.partKind,
      relationship: franchiseMember.relationship,
      optional: franchiseMember.optional,
    })
    .from(franchiseMember)
    .innerJoin(media, eq(media.id, franchiseMember.mediaId))
    .leftJoin(progress, and(eq(progress.mediaId, media.id), eq(progress.userId, userId)))
    .where(eq(franchiseMember.franchiseId, franchiseId))
}

export interface ProgressMediaRow {
  mediaId: number
  /** media.source ('anilist' | 'tmdb'): a TMDB slot is date-only, which moves when it counts as aired. */
  source: string
  status: string | null
  episodes: number | null
  next: { episode: number; airingAt: number } | null
  episodesList: EpisodeMeta[] | null
  /** The caller's stored count for the part (null / absent = none): a write never pulls it down. */
  watched?: number | null
}

/** A media select's nullable jsonb columns as the aired rule's input. */
function toAiredInput(row: Omit<ProgressMediaRow, 'mediaId'>): AiredInput {
  return {
    source: row.source,
    status: row.status,
    episodes: row.episodes,
    next: row.next ?? null,
    episodesList: row.episodesList ?? null,
  }
}

function airedForProgress(row: Omit<ProgressMediaRow, 'mediaId'>, nowMs: number = Date.now()): number {
  return airedCount(toAiredInput(row), nowMs).aired
}

/** A franchise member as the status rule reads it: the progress row plus the member's place. */
export interface StatusMemberRow extends ProgressMediaRow {
  partKind: string
  relationship: string | null
  optional: boolean
}

/**
 * What a progress write does to the show's STATUS — the server's half of a rule the app also keeps
 * (`AppModel.settleCompletion` / `resume`), so every writer agrees: a FORWARD mark on a Planned
 * show is watching it; the story watched THROUGH files a Planned or Watching show under Watched.
 * Nothing else moves here. A show filed Watched whose story goes on is the client's call (it knows
 * about a rewatch in flight); Paused and Dropped are the user's own word. Null = unchanged.
 *
 * Why the server derives it at all (9 Oct 2026): a show added to Planned and finished in ONE write
 * stayed Planned for good — the client's settle rule asked for Watching first, its resume rule
 * bailed once the story was through, and the server never looked. Imports, replays and a second
 * device all pass through here.
 */
export function derivedStatusAfterProgress(current: WatchStatus | null | undefined,
  change: { forward: boolean; watchedThrough: boolean }): WatchStatus | null {
  if (!current) return null
  if (change.watchedThrough && (current === 'planned' || current === 'watching')) return 'completed'
  if (change.forward && current === 'planned') return 'watching'
  return null
}

/**
 * The story watched through, read CONSERVATIVELY: every season that is not a spin-off (the import
 * planner's spine), plus every non-optional OVA, ONA and film that is not a side story, watched to
 * what has aired — and no part of the show still releasing or announced (the app's own
 * `Franchise.isWatchedThrough`). Where this and the app's finer main-story rule disagree, this one
 * stays silent and the app's settle rule decides on the device: a server that files a show Watched
 * too early is the worse failure.
 */
export function storyWatchedThrough(rows: StatusMemberRow[], watched: Map<number, number>, nowMs: number): boolean {
  if (rows.some((row) => row.status === 'RELEASING' || row.status === 'NOT_YET_RELEASED')) return false
  const members: MemberRow[] = rows.map((row) => ({
    mediaId: row.mediaId, franchiseId: '', partKind: row.partKind, sequence: 0,
    relationship: row.relationship, status: row.status, released: airedForProgress(row, nowMs),
  }))
  const byId = new Map(rows.map((row) => [row.mediaId, row]))
  const story = spine(members)
  const extras = members.filter((member) => {
    if (story.includes(member)) return false
    const tie = (member.relationship ?? '').toUpperCase()
    return ['ova', 'ona', 'movie'].includes(member.partKind) && !byId.get(member.mediaId)!.optional
      && tie !== 'SIDE_STORY' && tie !== 'SPIN_OFF'
  })
  const required = [...story, ...extras].filter((member) => member.released > 0)
  return required.length > 0 && required.every((member) => (watched.get(member.mediaId) ?? 0) >= member.released)
}

/**
 * The status `writes` leave a subscription in, from the member rows as they are BEFORE the writes
 * (`watched` = the stored count). Null when nothing moves.
 */
export function statusAfterWrites(current: WatchStatus | null | undefined, rows: StatusMemberRow[],
  writes: { mediaId: number; episodes: number }[], nowMs: number): WatchStatus | null {
  if (current !== 'planned' && current !== 'watching') return null
  const after = new Map(rows.map((row) => [row.mediaId, row.watched ?? 0]))
  let forward = false
  for (const write of writes) {
    if (write.episodes > (after.get(write.mediaId) ?? 0)) forward = true
    after.set(write.mediaId, write.episodes)
  }
  return derivedStatusAfterProgress(current, { forward, watchedThrough: storyWatchedThrough(rows, after, nowMs) })
}

/**
 * One-off, idempotent repair (review i4): progress stored on a season that has not premiered —
 * written before the write clamp existed — comes back the day the season does. Every read guard
 * stops at the premiere: Avatar: Seven Havens, 13 of 13 marked a fortnight before its 9 Oct
 * premiere, would open that day at "Season 1 · Episode 14" with thirteen watched discs over
 * unaired episodes, never behind and never on Today. Each unaired season is set to what has aired
 * (nothing, until it does). Run at boot and hourly; a no-op once the rows are clean.
 */
export async function clampUnairedProgress(): Promise<number> {
  const rows = await db
    .select({
      userId: progress.userId,
      mediaId: progress.mediaId,
      watched: progress.episodesWatched,
      source: media.source,
      status: media.status,
      episodes: media.episodes,
      next: media.nextAiringEpisode,
      episodesList: media.episodesList,
    })
    .from(progress)
    .innerJoin(media, eq(media.id, progress.mediaId))
    .where(and(eq(media.status, 'NOT_YET_RELEASED'), gt(progress.episodesWatched, 0)))
  let fixed = 0
  for (const row of rows) {
    const aired = airedForProgress(row)
    if (row.watched <= aired) continue
    await db
      .update(progress)
      .set({ episodesWatched: aired, updatedAt: new Date() })
      .where(and(eq(progress.userId, row.userId), eq(progress.mediaId, row.mediaId)))
    fixed++
  }
  return fixed
}

export type FranchiseProgressCommand =
  | { mode: 'caught_up' | 'completed' | 'reset'; status?: WatchStatus }
  | { parts: { mediaId: number; episodes: number }[]; status?: WatchStatus }

export class FranchiseProgressError extends Error {
  constructor(
    public readonly reason: 'not_found' | 'invalid_part',
    message: string,
  ) {
    super(message)
  }
}

/**
 * The writes a franchise-level command makes. `caught_up` / `completed` mark each part to what has
 * aired by `nowMs` (a slot that struck counts before the hourly sync notices), never below what the
 * part already holds (`caughtUpValue`); explicit parts are clamped exactly as `PUT /me/progress`
 * clamps (`clampProgressValue`, the stored count kept reachable). Only `reset` walks progress back.
 */
export function progressWritesForCommand(
  rows: ProgressMediaRow[],
  command: FranchiseProgressCommand,
  nowMs: number = Date.now(),
): { mediaId: number; episodes: number }[] {
  if ('mode' in command) {
    return rows.map((row) => ({
      mediaId: row.mediaId,
      episodes: command.mode === 'reset' ? 0 : caughtUpValue(toAiredInput(row), nowMs, row.watched ?? 0),
    }))
  }
  const byId = new Map(rows.map((row) => [row.mediaId, row]))
  const seen = new Set<number>()
  return command.parts.map((part) => {
    const row = byId.get(part.mediaId)
    if (!row || seen.has(part.mediaId)) {
      throw new FranchiseProgressError('invalid_part', `media ${part.mediaId} is not a unique member of this franchise`)
    }
    seen.add(part.mediaId)
    return {
      mediaId: part.mediaId,
      episodes: clampProgressValue(toAiredInput(row), part.episodes, nowMs, row.watched ?? 0),
    }
  })
}

/**
 * Apply a franchise-level progress action in one transaction. This is intentionally separate from
 * the legacy single-part endpoint: clients can migrate without losing the simple primitive, while
 * catch-up/reset/completion can no longer leave half a franchise updated after an interrupted run.
 */
export async function setFranchiseProgress(
  userId: string,
  franchiseId: string,
  command: FranchiseProgressCommand,
  context?: ClientMutationContext,
): Promise<FranchiseProgressCommandResponse> {
  if (context) return withClientMutation(context, 'franchise_progress', { franchiseId, command },
    (tx, scope) => setFranchiseProgressOn(tx, userId, franchiseId, command, scope, !!context.stamp))
  return db.transaction((tx) => setFranchiseProgressOn(tx, userId, franchiseId, command))
}

async function setFranchiseProgressOn(tx: MutationConnection, userId: string, franchiseId: string,
  command: FranchiseProgressCommand, scope?: MutationScope, stamped = false): Promise<FranchiseProgressCommandResponse> {
    const [exists] = await tx.select({ id: franchise.id }).from(franchise).where(eq(franchise.id, franchiseId)).limit(1)
    if (!exists) throw new FranchiseProgressError('not_found', 'franchise not found')

    const rows: StatusMemberRow[] = await statusMemberRows(tx, userId, franchiseId)

    const writes = progressWritesForCommand(rows, command)

    const requestedStatus = command.status ?? ('mode' in command && command.mode === 'completed' ? 'completed' : undefined)
    // No status asked for: the writes may still move the one the show has (`statusAfterWrites`).
    const [current] = requestedStatus ? [] : await tx
      .select({ status: subscriptions.status })
      .from(subscriptions)
      .where(and(eq(subscriptions.userId, userId), eq(subscriptions.franchiseId, franchiseId)))
      .limit(1)
    const derivedStatus = requestedStatus ? null : statusAfterWrites(current?.status as WatchStatus | undefined, rows, writes, Date.now())
    const applied = !scope || await scope.apply([
      ...writes.map((write) => `media:${write.mediaId}`), ...(requestedStatus ? [`subscription:${franchiseId}`] : []),
    ], { barriers: [`subscription:${franchiseId}`] })
    const now = new Date()
    for (const write of applied ? writes : []) {
      await tx
        .insert(progress)
        .values({ userId, mediaId: write.mediaId, episodesWatched: write.episodes, updatedAt: now })
        .onConflictDoUpdate({
          target: [progress.userId, progress.mediaId],
          set: { episodesWatched: write.episodes, updatedAt: now },
        })
    }

    if (applied && requestedStatus) {
      await tx
        .insert(subscriptions)
        .values({ userId, franchiseId, status: requestedStatus })
        .onConflictDoUpdate({
          target: [subscriptions.userId, subscriptions.franchiseId],
          set: { status: requestedStatus },
        })
    } else if (applied && derivedStatus && (!scope || await scope.apply([`subscription:${franchiseId}`]))) {
      // Sequenced as a word on the subscription (see `setProgress`): a later status from this writer
      // keeps its place; the marks above have landed either way.
      await tx
        .update(subscriptions)
        .set({ status: derivedStatus })
        .where(and(eq(subscriptions.userId, userId), eq(subscriptions.franchiseId, franchiseId)))
    }

    const [subscription] = await tx
      .select({ status: subscriptions.status })
      .from(subscriptions)
      .where(and(eq(subscriptions.userId, userId), eq(subscriptions.franchiseId, franchiseId)))
      .limit(1)
    const saved = rows.length
      ? await tx
          .select({ mediaId: progress.mediaId, episodes: progress.episodesWatched })
          .from(progress)
          .where(and(eq(progress.userId, userId), inArray(progress.mediaId, rows.map((row) => row.mediaId))))
      : []
    const savedById = new Map(saved.map((row) => [row.mediaId, row.episodes]))
    return {
      ok: true,
      ...(stamped ? { applied } : {}),
      franchiseId,
      status: (subscription?.status as WatchStatus | undefined) ?? null,
      progress: rows.map((row) => ({ mediaId: row.mediaId, episodes: savedById.get(row.mediaId) ?? 0 })),
    }
}

/**
 * A new visit: move the last visit into `prev_opened_at` and stamp now, in ONE statement; return the
 * previous visit (for "since you were last here").
 *
 * Postgres evaluates every SET right-hand side against the OLD row, so `prev_opened_at =
 * last_opened_at` reads the stamp this statement replaces — atomic, with no read-then-write window
 * for a second foreground to slip through. Every later read in the session (`GET /me/library`,
 * `GET /me/feed`) answers `prev_opened_at`, never the stamp just written (the pre-0010 echo bug:
 * the pill and "new" compared against a moment ago). 0 for an unknown id.
 */
export async function markOpened(userId: string): Promise<number> {
  const [row] = await db
    .update(users)
    .set({ prevOpenedAt: sql`${users.lastOpenedAt}`, lastOpenedAt: Date.now() })
    .where(eq(users.id, userId))
    .returning({ prev: users.prevOpenedAt })
  return row?.prev ?? 0
}

/** Whether a franchise exists (for 404s on subscribe). */
export async function franchiseExists(franchiseId: string): Promise<boolean> {
  const [f] = await db.select({ id: franchise.id }).from(franchise).where(eq(franchise.id, franchiseId)).limit(1)
  return !!f
}
