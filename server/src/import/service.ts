import { randomUUID } from 'node:crypto'
import { and, eq, inArray, sql } from 'drizzle-orm'
import { fetchByIds } from '../anilist/client.js'
import type { AniListMedia } from '../anilist/types.js'
import { db } from '../db/index.js'
import { franchise, franchiseMember, media, progress, subscriptions } from '../db/schema.js'
import { airedCount, clampProgressValue } from '../services/aired.js'
import { refreshAnimeVideoFallback } from '../services/animeVideoFallback.js'
import { getSummaries } from '../services/franchiseView.js'
import { progressWritesForCommand, type ProgressMediaRow } from '../services/library.js'
import { franchisesOfMedia } from '../services/recommendationRoots.js'
import { env } from '../env.js'
import { groupFromSeed } from '../grouping/service.js'
import type { MediaFetcher } from '../grouping/graph.js'
import { upsertMedia } from '../services/mediaStore.js'
import { materialiseRecommendation } from '../services/recommendations.js'
import { ContentExcludedError, consumerAnimeFetcher, consumerFranchiseIds, isExcludedContent } from '../services/consumerContent.js'
import { tmdbEnabled } from '../tmdb/client.js'
import { isJapaneseAnimation } from '../tmdb/mapping.js'
import type { FranchiseSummary } from '../types/api.js'
import { mapWithConcurrency } from '../util/concurrency.js'
import {
  planAnimeFranchise,
  planTvFranchise,
  planTvShowAsAnime,
  type AnimeEntry,
  type FranchisePlan,
  type ListStatus,
  type MemberRow,
  type TvShow,
} from './plan.js'
import {
  fetchAniListEntries,
  findAnimeByTitle,
  ImportSourceError,
  mapMalRows,
  paceImportAniList,
  resolveTvShows,
  type MalRow,
} from './sources.js'

// History import (4 Oct 2026): AniList by username, a MyAnimeList export, a TV Time export.
//
// TWO STEPS, so nothing is written on a guess. PREVIEW reads the source, finds each show in the
// catalogue and answers with what WOULD be added — how many shows, in which states, which it
// could not place — and keeps that plan for a few minutes. APPLY writes it: the shows the
// catalogue already holds at once, in the request; the rest (shows nobody has added before) are
// fetched and added in the background, one at a time — what they are watching first, every AniList
// request spaced — and `GET /me/import/:id` says how far that has got. A long anime list is mostly
// tail (the catalogue holds a few hundred series, a list can hold a thousand entries), and it takes
// as long as AniList allows: about five seconds a series. A session lives in this process's memory: a restart forgets it, and importing again is
// safe — an import only ever ADDS a show and RAISES a count (it never lowers progress, and never
// changes the status of a show already in the library).

export type ImportSource = 'anilist' | 'mal' | 'tvtime'

export type ImportRequest =
  | { source: 'anilist'; username: string }
  | { source: 'mal'; rows: MalRow[] }
  | { source: 'tvtime'; shows: TvShow[] }

export interface ImportPreview {
  id: string
  source: ImportSource
  /**
   * What the list holds, in the SOURCE's unit: AniList's and MyAnimeList's entries (a season, a
   * film — the number their own profile shows), TV Time's shows. Never called "shows" for an anime
   * list: this app keeps a series' seasons together, so the library ends up with fewer.
   */
  listed: number
  /** Shows the catalogue already holds: added the moment the import is applied. */
  ready: number
  /** Still to fetch, in the source's unit: added in the background after it is applied. */
  toFetch: number
  /** Episodes watched, in all: the ready shows' as they will be written, the rest as the list counts them. */
  episodes: number
  /** The ready shows by the shelf they land on. */
  byStatus: Record<ListStatus, number>
  /** What could not be placed, by name (the first few) and in all. */
  unmatched: { count: number; titles: string[] }
  /** A few of the ready shows, for the preview's wall. */
  sample: FranchiseSummary[]
  /** Source entries intentionally omitted by policy; never counted as provider failures. */
  skipped: { count: number; reasons: { adult_content: number } }
}

export interface ImportProgress {
  id: string
  state: 'preview' | 'running' | 'done'
  /** Shows in the library from this import so far (a series' seasons are one show). */
  shows: number
  /** Still to fetch, in the source's unit (list entries for an anime list). */
  remaining: number
  failed: number
  skipped: { count: number; reasons: { adult_content: number } }
}

interface PendingTv {
  show: TvShow
  unitKeys: string[]
  /** The TMDB show to materialise, or — for Japanese animation — the AniList media. */
  tmdbId: number | null
  anilistId: number | null
}

interface ImportOwnership { status: ListStatus; createdAt: Date; revoked?: boolean }

interface Session {
  id: string
  userId: string
  source: ImportSource
  createdAt: number
  ready: FranchisePlan[]
  /** Every anime entry of the import (a fetched franchise is planned from all of its entries). */
  animeEntries: AnimeEntry[]
  /** AniList media not in the catalogue yet. */
  pendingAnime: number[]
  pendingTv: PendingTv[]
  unmatched: string[]
  state: ImportProgress['state']
  /** The shows written so far, and of those the ones this import put in the library itself. */
  written: Set<string>
  mine: Map<string, ImportOwnership>
  /** Pending units (entries / shows) not yet settled, and those that could not be built. */
  remaining: number
  failed: number
  listed: number
  skippedAdult: Set<string>
  readyUnits: Map<string, Set<string>>
  animeUnits: Map<number, Set<string>>
}

const SESSION_TTL_MS = 30 * 60_000
const MAX_SESSIONS = 200
const sessions = new Map<string, Session>()

function prune(nowMs: number): void {
  for (const [id, s] of sessions) {
    if (s.state !== 'running' && nowMs - s.createdAt > SESSION_TTL_MS) sessions.delete(id)
  }
}

/** Test seam. */
export function resetImportSessions(): void {
  sessions.clear()
}

// MARK: Catalogue reads

/** The members of some franchises, as the planner reads them (`released` = out by now). */
async function membersOf(franchiseIds: string[], nowMs: number): Promise<Map<string, MemberRow[]>> {
  const out = new Map<string, MemberRow[]>()
  const unique = [...new Set(franchiseIds)]
  for (let i = 0; i < unique.length; i += 400) {
    const rows = await db
      .select({
        mediaId: franchiseMember.mediaId,
        franchiseId: franchiseMember.franchiseId,
        partKind: franchiseMember.partKind,
        sequence: franchiseMember.sequence,
        relationship: franchiseMember.relationship,
        source: media.source,
        status: media.status,
        episodes: media.episodes,
        next: media.nextAiringEpisode,
        episodesList: media.episodesList,
      })
      .from(franchiseMember)
      .innerJoin(media, eq(media.id, franchiseMember.mediaId))
      .where(inArray(franchiseMember.franchiseId, unique.slice(i, i + 400)))
    for (const row of rows) {
      const count = airedCount(
        { source: row.source, status: row.status, episodes: row.episodes, next: row.next ?? null, episodesList: row.episodesList ?? null },
        nowMs,
      )
      const member: MemberRow = {
        mediaId: row.mediaId,
        franchiseId: row.franchiseId,
        partKind: row.partKind,
        sequence: row.sequence,
        relationship: row.relationship,
        status: row.status,
        released: count.known ? count.aired : Math.max(0, row.episodes ?? 0),
        ceiling: clampProgressValue(row, Number.MAX_SAFE_INTEGER, nowMs),
      }
      const list = out.get(row.franchiseId)
      if (list) list.push(member)
      else out.set(row.franchiseId, [member])
    }
  }
  return out
}

/** The TMDB shows the catalogue already holds, by TMDB id. */
async function tvFranchises(tmdbIds: number[]): Promise<Map<number, string>> {
  const unique = [...new Set(tmdbIds)]
  if (unique.length === 0) return new Map()
  const rows = await db
    .select({ id: franchise.id, externalId: franchise.externalId })
    .from(franchise)
    .where(and(eq(franchise.source, 'tmdb'), inArray(franchise.externalId, unique)))
  return new Map(rows.flatMap((row) => (row.externalId == null ? [] : [[row.externalId, row.id] as const])))
}

/** Anime entries → one plan per franchise the catalogue holds; the media it does not, by id. */
async function planAnime(entries: AnimeEntry[], nowMs: number): Promise<{
  plans: FranchisePlan[]; missing: number[]; excluded: number[]; units: Map<string, number[]>
}> {
  const owner = await franchisesOfMedia(entries.map((e) => e.mediaId))
  const allowed = await consumerFranchiseIds([...new Set(owner.values())])
  const members = await membersOf([...allowed], nowMs)
  const byFranchise = new Map<string, AnimeEntry[]>()
  const missing: number[] = []
  const excluded: number[] = []
  for (const entry of entries) {
    const id = owner.get(entry.mediaId)
    if (!id) {
      missing.push(entry.mediaId)
      continue
    }
    if (!allowed.has(id)) { excluded.push(entry.mediaId); continue }
    const list = byFranchise.get(id)
    if (list) list.push(entry)
    else byFranchise.set(id, [entry])
  }
  const plans: FranchisePlan[] = []
  for (const [id, mine] of byFranchise) {
    const plan = planAnimeFranchise(mine, members.get(id) ?? [])
    if (plan) plans.push(plan)
  }
  return { plans, missing, excluded, units: new Map([...byFranchise].map(([id, mine]) => [id, mine.map((entry) => entry.mediaId)])) }
}

function recordReadyUnits(session: Session, franchiseId: string, keys: Iterable<string>): void {
  const units = session.readyUnits.get(franchiseId) ?? new Set<string>()
  for (const key of keys) units.add(key)
  session.readyUnits.set(franchiseId, units)
}

function skipAnime(session: Session, mediaId: number): void {
  for (const key of session.animeUnits.get(mediaId) ?? []) session.skippedAdult.add(key)
}

function skippedOf(session: Session): ImportProgress['skipped'] {
  return { count: session.skippedAdult.size, reasons: { adult_content: session.skippedAdult.size } }
}

// MARK: Preview

/** A TV Time show worth looking up at all: something watched, or kept on a list. */
function worthImporting(show: TvShow): boolean {
  return show.seasons.some((s) => s.watched.length > 0) || ((show.followed || show.forLater) && !show.archived)
}

export async function previewImport(userId: string, request: ImportRequest, nowMs: number = Date.now()): Promise<ImportPreview> {
  prune(nowMs)
  // Make room only for a new preview, never while somebody is reading an existing job.
  for (const [id, s] of sessions) {
    if (sessions.size < MAX_SESSIONS) break
    if (s.state !== 'running') sessions.delete(id)
  }
  if (sessions.size >= MAX_SESSIONS) throw new ImportSourceError('unavailable')
  const session: Session = {
    id: randomUUID(),
    userId,
    source: request.source,
    createdAt: nowMs,
    ready: [],
    animeEntries: [],
    pendingAnime: [],
    pendingTv: [],
    unmatched: [],
    state: 'preview',
    written: new Set(),
    mine: new Map(),
    remaining: 0,
    failed: 0,
    listed: 0,
    skippedAdult: new Set(),
    readyUnits: new Map(),
    animeUnits: new Map(),
  }

  if (request.source === 'tvtime') {
    if (!tmdbEnabled()) throw new ImportSourceError('unavailable')
    const shows = request.shows.filter(worthImporting)
    session.listed = shows.length
    const keysByShow = new Map<TvShow, string[]>()
    shows.forEach((show, index) => keysByShow.set(show, [...(keysByShow.get(show) ?? []), `tv:${index}`]))
    const rawResolved = await resolveTvShows(shows)
    const resolved = rawResolved.filter((row) => {
      if (!row.tmdb || !isExcludedContent(row.tmdb)) return true
      for (const key of keysByShow.get(row.show) ?? []) session.skippedAdult.add(key)
      return false
    })
    const tv = resolved.filter((r) => r.tmdb && !isJapaneseAnimation(r.tmdb))
    const anime = resolved.filter((r) => r.tmdb && isJapaneseAnimation(r.tmdb))
    for (const r of resolved) if (!r.tmdb) session.unmatched.push(r.show.title || 'Untitled')

    const known = await tvFranchises(tv.map((r) => r.tmdb!.id))
    const allowedTv = await consumerFranchiseIds([...known.values()])
    const members = await membersOf([...known.values()], nowMs)
    for (const r of tv) {
      const franchiseId = known.get(r.tmdb!.id)
      if (!franchiseId) {
        session.pendingTv.push({ show: r.show, unitKeys: keysByShow.get(r.show) ?? [], tmdbId: r.tmdb!.id, anilistId: null })
        continue
      }
      if (!allowedTv.has(franchiseId)) {
        for (const key of keysByShow.get(r.show) ?? []) session.skippedAdult.add(key)
        continue
      }
      const plan = planTvFranchise(r.show, members.get(franchiseId) ?? [], nowMs)
      if (plan) { session.ready.push(plan); recordReadyUnits(session, franchiseId, keysByShow.get(r.show) ?? []) }
    }
    // Japanese animation is AniList's here: found by its exact title, laid along the story.
    const titled = await mapWithConcurrency(anime, 2, async (r) => {
      try {
        return { r, anilistId: await findAnimeByTitle(r.tmdb!.name || r.show.title), excluded: false }
      } catch (error) {
        if (!(error instanceof ContentExcludedError)) throw error
        for (const key of keysByShow.get(r.show) ?? []) session.skippedAdult.add(key)
        return { r, anilistId: null, excluded: true }
      }
    })
    const owner = await franchisesOfMedia(titled.flatMap((t) => (t.anilistId == null ? [] : [t.anilistId])))
    const allowedAnime = await consumerFranchiseIds([...new Set(owner.values())])
    const animeMembers = await membersOf([...new Set(owner.values())], nowMs)
    for (const { r, anilistId, excluded } of titled) {
      if (excluded) continue
      if (anilistId == null) {
        session.unmatched.push(r.show.title || r.tmdb!.name)
        continue
      }
      const franchiseId = owner.get(anilistId)
      if (!franchiseId) {
        session.pendingTv.push({ show: r.show, unitKeys: keysByShow.get(r.show) ?? [], tmdbId: null, anilistId })
        continue
      }
      if (!allowedAnime.has(franchiseId)) {
        for (const key of keysByShow.get(r.show) ?? []) session.skippedAdult.add(key)
        continue
      }
      const plan = planTvShowAsAnime(r.show, animeMembers.get(franchiseId) ?? [], nowMs)
      if (plan) { session.ready.push(plan); recordReadyUnits(session, franchiseId, keysByShow.get(r.show) ?? []) }
    }
  } else {
    let entries: AnimeEntry[]
    if (request.source === 'anilist') {
      entries = await fetchAniListEntries(request.username)
      session.listed = entries.length
    } else {
      const mapped = await mapMalRows(request.rows)
      entries = mapped.entries
      session.unmatched.push(...mapped.unmatched)
      session.listed = entries.length + mapped.unmatched.length
    }
    entries.forEach((entry, index) => {
      const keys = session.animeUnits.get(entry.mediaId) ?? new Set<string>()
      keys.add(`anime:${index}`); session.animeUnits.set(entry.mediaId, keys)
    })
    for (const entry of entries) if (entry.contentExcluded) skipAnime(session, entry.mediaId)
    session.animeEntries = entries.filter((entry) => !entry.contentExcluded)
    const { plans, missing, excluded, units } = await planAnime(session.animeEntries, nowMs)
    for (const id of excluded) skipAnime(session, id)
    for (const [id, mediaIds] of units) recordReadyUnits(session, id, mediaIds.flatMap((mediaId) => [...session.animeUnits.get(mediaId) ?? []]))
    session.ready = plans
    // The tail in the order it matters to them: what they are watching, then what they put down,
    // then the history, then the plans.
    const byId = new Map(session.animeEntries.map((e) => [e.mediaId, e]))
    session.pendingAnime = [...missing].sort(
      (a, b) => TAIL_ORDER.indexOf(byId.get(a)!.status) - TAIL_ORDER.indexOf(byId.get(b)!.status),
    )
  }
  // TV: the shows watched most recently first.
  session.pendingTv.sort((a, b) => (b.show.lastWatchedAt ?? 0) - (a.show.lastWatchedAt ?? 0))

  // One plan per franchise: two sources of the same show (a TV Time anime twice) merge upward.
  session.ready = mergePlans(session.ready)
  session.remaining = session.pendingAnime.length + session.pendingTv.length
  sessions.set(session.id, session)

  const byStatus: Record<ListStatus, number> = { watching: 0, completed: 0, planned: 0, paused: 0, dropped: 0 }
  let episodes = 0
  for (const plan of session.ready) {
    byStatus[plan.status]++
    for (const part of plan.parts) episodes += part.episodes
  }
  // The tail's episodes as the list counted them (nothing in the catalogue to clamp against yet).
  const pendingIds = new Set(session.pendingAnime)
  for (const entry of session.animeEntries) if (pendingIds.has(entry.mediaId)) episodes += entry.progress
  for (const pending of session.pendingTv) {
    for (const season of pending.show.seasons) if (season.number > 0) episodes += new Set(season.watched).size
  }
  // The wall leads with what they are watching, then what they finished.
  const order: ListStatus[] = ['watching', 'completed', 'paused', 'planned', 'dropped']
  const sampleIds = [...session.ready]
    .sort((a, b) => order.indexOf(a.status) - order.indexOf(b.status))
    .slice(0, 9)
    .map((p) => p.franchiseId)
  return {
    id: session.id,
    source: session.source,
    listed: session.listed,
    ready: session.ready.length,
    toFetch: session.remaining,
    episodes,
    byStatus,
    unmatched: { count: session.unmatched.length, titles: session.unmatched.slice(0, 12) },
    sample: await getSummaries(sampleIds),
    skipped: skippedOf(session),
  }
}

const RANK: Record<ListStatus, number> = { watching: 5, paused: 4, dropped: 3, completed: 2, planned: 1 }

/** The order the background tail is fetched in. */
const TAIL_ORDER: ListStatus[] = ['watching', 'paused', 'completed', 'planned', 'dropped']

/**
 * Every AniList request the tail makes waits its turn here — ONE pacer for the process, so two
 * imports at once still add up to one request every three seconds. AniList allows 30 a minute (its
 * "degraded" limit, which is the one in force), and unlike the nightly sweeps (2.1 s, at 03:30,
 * alone) a tail runs at any hour for up to an hour: it takes two thirds of the budget and leaves
 * the rest to Search and the hourly airing refresh.
 */
const paceTail = paceImportAniList

/**
 * The tail's AniList reads: ONE fetcher for the whole tail, every request paced, and every request
 * WIDENED with the next entries of the list until it carries fifty media (AniList's page). A
 * series' seasons are usually all on the list, so most series are built from media that rode in
 * on an earlier request and cost none of their own. Measured without it (4 Oct, a 512-entry
 * tail): ~2.5 requests a series, ten seconds each — an hour and a half.
 *
 * Its own memo, not `makeAniListFetcher`'s: that one remembers an id AniList did not answer as
 * dead, and here one failed request would then bury fifty entries. An id that did not come back
 * is simply asked for again when its turn comes.
 */
function tailFetcher(pending: number[]): MediaFetcher {
  const have = new Map<number, AniListMedia>()
  let cursor = 0
  return async (ids) => {
    const batch = ids.filter((id) => !have.has(id))
    if (batch.length > 0) {
      while (batch.length < 50 && cursor < pending.length) {
        const id = pending[cursor++]!
        if (!have.has(id) && !batch.includes(id)) batch.push(id)
      }
      for (let start = 0; start < batch.length; start += 50) {
        await paceTail()
        const fetched = await fetchByIds(batch.slice(start, start + 50), { maxRetries: 2, timeoutMs: 15_000 })
        if (fetched.length > 0) await upsertMedia(fetched)
        for (const item of fetched) have.set(item.id, item)
      }
    }
    return ids.flatMap((id) => have.get(id) ?? [])
  }
}

/** An anime series nobody has added before, built through the grouper on the bulk model. */
async function buildAnime(mediaId: number, fetcher: MediaFetcher): Promise<string> {
  const known = (await franchisesOfMedia([mediaId])).get(mediaId)
  if (known) return known
  return (await groupFromSeed(mediaId, { model: env.OPENROUTER_MODEL_BULK,
    fetcher: consumerAnimeFetcher(mediaId, fetcher), enrich: false })).franchiseId
}

/**
 * A show the tail built is not enriched on the spot (`enrich: false`: the enrichment queue's
 * unpaced AniList reads ran the budget out under the tail, and Search with it — measured 4 Oct).
 * Its cast, related titles and recommendation list arrive on first sight or with the nightly
 * sweep, as for any show nobody has opened yet. What cannot wait is the PICTURE of a show that
 * lands on Home: a WATCHING show gets its TMDB twin's art here (TMDB only — none of AniList's
 * budget), so the billboard is not an upscaled 460-px cover.
 */
async function pictureForHome(plan: FranchisePlan): Promise<void> {
  if (plan.status !== 'watching') return
  await refreshAnimeVideoFallback(plan.franchiseId, { request: { maxRetries: 1, timeoutMs: 4_000 } }).catch(() => undefined)
}

function mergePlans(plans: FranchisePlan[]): FranchisePlan[] {
  const out = new Map<string, FranchisePlan>()
  for (const plan of plans) {
    const prior = out.get(plan.franchiseId)
    if (!prior) {
      out.set(plan.franchiseId, plan)
      continue
    }
    const parts = new Map(prior.parts.map((p) => [p.mediaId, p.episodes]))
    for (const p of plan.parts) parts.set(p.mediaId, Math.max(parts.get(p.mediaId) ?? 0, p.episodes))
    out.set(plan.franchiseId, {
      franchiseId: plan.franchiseId,
      status: RANK[plan.status] > RANK[prior.status] ? plan.status : prior.status,
      parts: [...parts].map(([mediaId, episodes]) => ({ mediaId, episodes })),
    })
  }
  return [...out.values()]
}

// MARK: Apply

/**
 * One show, written: the membership if there is none (a show already in the library keeps its
 * status), and each part's count raised to the import's — clamped to what has aired, exactly as a
 * mark is, and never lowered. Answers whether the membership is NEW.
 *
 * `restate` is for a show this same import added a moment ago and now knows more about (a season
 * the catalogue did not hold was attached to it): its status is the import's to correct.
 */
export async function applyPlan(
  userId: string,
  plan: FranchisePlan,
  nowMs: number = Date.now(),
  restate?: ImportOwnership,
): Promise<boolean> {
  return db.transaction(async (tx) => {
    const [content] = await tx.select({ id: franchise.id, enrichment: franchise.enrichment, genres: franchise.genres })
      .from(franchise).where(eq(franchise.id, plan.franchiseId)).limit(1)
    if (!content) throw new Error('import franchise not found')
    if (isExcludedContent(content)) throw new ContentExcludedError()
    if (restate) {
      const [owned] = await tx.select({ createdAt: subscriptions.createdAt }).from(subscriptions)
        .where(and(eq(subscriptions.userId, userId), eq(subscriptions.franchiseId, plan.franchiseId))).for('update')
      if (!owned || owned.createdAt.getTime() !== restate.createdAt.getTime()) {
        restate.revoked = true
        return false // The viewer removed this show, or removed and re-added it.
      }
    }
    const rows: (ProgressMediaRow & { genres: string[] | null })[] = await tx
      .select({
        mediaId: media.id,
        source: media.source,
        status: media.status,
        episodes: media.episodes,
        next: media.nextAiringEpisode,
        episodesList: media.episodesList,
        watched: progress.episodesWatched,
        genres: media.genres,
      })
      .from(franchiseMember)
      .innerJoin(media, eq(media.id, franchiseMember.mediaId))
      .leftJoin(progress, and(eq(progress.mediaId, media.id), eq(progress.userId, userId)))
      .where(eq(franchiseMember.franchiseId, plan.franchiseId))
    if (rows.some(isExcludedContent)) throw new ContentExcludedError()
    const current = new Map(rows.map((row) => [row.mediaId, row.watched ?? 0]))
    const raise = plan.parts.filter((p) => current.has(p.mediaId) && p.episodes > (current.get(p.mediaId) ?? 0))
    const writes = progressWritesForCommand(rows, { parts: raise }, nowMs)
    const now = new Date(nowMs)
    for (const write of writes) {
      if (write.episodes <= (current.get(write.mediaId) ?? 0)) continue
      await tx
        .insert(progress)
        .values({ userId, mediaId: write.mediaId, episodesWatched: write.episodes, updatedAt: now })
        .onConflictDoUpdate({
          target: [progress.userId, progress.mediaId],
          // The SELECT above may precede another import/watch write. Compare at the write,
          // under Postgres's row lock, so even simultaneous imports only raise progress.
          set: { episodesWatched: sql`greatest(${progress.episodesWatched}, ${write.episodes})`, updatedAt: now },
        })
    }
    const inserted = await tx
      .insert(subscriptions)
      .values({ userId, franchiseId: plan.franchiseId, status: plan.status, createdAt: now })
      .onConflictDoNothing({ target: [subscriptions.userId, subscriptions.franchiseId] })
      .returning({ franchiseId: subscriptions.franchiseId })
    if (inserted.length === 0 && restate && !restate.revoked) {
      const updated = await tx
        .update(subscriptions)
        .set({ status: plan.status })
        .where(and(eq(subscriptions.userId, userId), eq(subscriptions.franchiseId, plan.franchiseId),
          eq(subscriptions.status, restate.status), eq(subscriptions.createdAt, restate.createdAt)))
        .returning({ id: subscriptions.franchiseId })
      if (updated.length === 0) restate.revoked = true
    }
    return inserted.length > 0
  })
}

/** `applyPlan` for a session: keeps its books (what is written, what it added itself). */
async function write(session: Session, plan: FranchisePlan): Promise<void> {
  const nowMs = Date.now()
  const prior = session.mine.get(plan.franchiseId)
  const added = await applyPlan(session.userId, plan, nowMs, prior)
  if (added) session.mine.set(plan.franchiseId, { status: plan.status, createdAt: new Date(nowMs) })
  else if (prior && !prior.revoked) prior.status = plan.status
  session.written.add(plan.franchiseId)
}

function progressOf(session: Session): ImportProgress {
  return {
    id: session.id,
    state: session.state,
    shows: session.written.size,
    remaining: session.state === 'done' ? 0 : session.remaining,
    failed: session.failed,
    skipped: skippedOf(session),
  }
}

export function importProgress(userId: string, id: string): ImportProgress | null {
  prune(Date.now())
  const session = sessions.get(id)
  return session && session.userId === userId ? progressOf(session) : null
}

/**
 * Write a previewed import. The ready shows are in before this returns; the rest follow in the
 * background (`finishInBackground`). Applying twice is a no-op the second time.
 */
export async function applyImport(userId: string, id: string): Promise<ImportProgress | null> {
  prune(Date.now())
  const session = sessions.get(id)
  if (!session || session.userId !== userId) return null
  if (session.state !== 'preview') return progressOf(session)
  session.state = 'running'
  for (const plan of session.ready) {
    try {
      await write(session, plan)
    } catch (error) {
      if (error instanceof ContentExcludedError) {
        for (const key of session.readyUnits.get(plan.franchiseId) ?? []) session.skippedAdult.add(key)
      } else session.failed++
    }
  }
  if (session.pendingAnime.length + session.pendingTv.length === 0) {
    session.state = 'done'
    session.createdAt = Date.now()
  } else {
    void finishInBackground(session).catch(() => {
      session.failed += session.remaining
      session.remaining = 0
      session.state = 'done'
      session.createdAt = Date.now()
    })
  }
  return progressOf(session)
}

/**
 * The shows nobody had added before: each is built (an anime through the grouper, a TV show from
 * TMDB — the path a tapped recommendation takes), then planned and written like the rest. One at
 * a time, in `TAIL_ORDER`, every AniList request paced (`paceTail`).
 */
async function finishInBackground(session: Session): Promise<void> {
  const fetcher = tailFetcher(session.pendingAnime)
  const settled = new Set<number>()
  const settle = (ids: number[]) => {
    for (const id of ids) {
      if (settled.has(id)) continue
      settled.add(id)
      session.remaining = Math.max(0, session.remaining - 1)
    }
  }
  for (const mediaId of session.pendingAnime) {
    if (settled.has(mediaId)) continue
    try {
      const franchiseId = await buildAnime(mediaId, fetcher)
      const members = (await membersOf([franchiseId], Date.now())).get(franchiseId) ?? []
      const ids = new Set(members.map((m) => m.mediaId))
      const mine = session.animeEntries.filter((e) => ids.has(e.mediaId))
      const plan = planAnimeFranchise(mine, members)
      if (!plan) throw new Error('import has no matching members')
      await write(session, plan)
      // Every pending entry of this series is settled by the one write — counted before the
      // enrichment, since the show is in the library already.
      settle([mediaId, ...session.pendingAnime.filter((id) => ids.has(id))])
      await pictureForHome(plan)
    } catch (error) {
      settle([mediaId])
      if (error instanceof ContentExcludedError) skipAnime(session, mediaId)
      else session.failed++
    }
  }
  for (const pending of session.pendingTv) {
    try {
      const franchiseId = pending.anilistId != null
        ? await buildAnime(pending.anilistId, fetcher)
        : await materialiseRecommendation('tmdb', pending.tmdbId!)
      if (!franchiseId) throw new Error('not built')
      const members = (await membersOf([franchiseId], Date.now())).get(franchiseId) ?? []
      const plan = pending.anilistId != null
        ? planTvShowAsAnime(pending.show, members, Date.now())
        : planTvFranchise(pending.show, members, Date.now())
      if (!plan) throw new Error('import has no matching members')
      await write(session, plan)
      if (plan && pending.anilistId != null) await pictureForHome(plan)
    } catch (error) {
      if (error instanceof ContentExcludedError) {
        for (const key of pending.unitKeys) session.skippedAdult.add(key)
      } else session.failed++
    }
    session.remaining = Math.max(0, session.remaining - 1)
  }
  session.state = 'done'
  session.createdAt = Date.now()
}
