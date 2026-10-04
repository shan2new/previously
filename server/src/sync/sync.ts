import { and, asc, eq, gt, inArray, isNotNull, or, sql } from 'drizzle-orm'
import { fetchByIds, fetchLastAired, fetchTrending } from '../anilist/client.js'
import { db } from '../db/index.js'
import { franchise, franchiseMember, media, subscriptions, syncState } from '../db/schema.js'
import { env } from '../env.js'
import { groupFromSeed } from '../grouping/service.js'
import { upsertMedia } from '../services/mediaStore.js'
import { getTrendingTv, tmdbEnabled } from '../tmdb/client.js'
import { isJapaneseAnimation } from '../tmdb/mapping.js'
import { ensureTvFranchise, refreshTvShow } from '../tmdb/service.js'
import { mapWithConcurrency } from '../util/concurrency.js'

// v3 rechecks metadata after fixing reversed/sparse streaming episode numbering. It also retains
// the v2 native-title, synonym and artwork enrichment.
const ANILIST_TRAILER_SWEEP_KEY = 'anilist_catalog_metadata_v3'
const ANILIST_TRAILER_SWEEP_LIMIT = 2_500
const ANILIST_TRAILER_REQUEST_SIZE = 50
const ANILIST_TRAILER_REQUEST_INTERVAL_MS = 2_300

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms))

function chunked<T>(values: T[], size: number): T[][] {
  const out: T[][] = []
  for (let index = 0; index < values.length; index += size) out.push(values.slice(index, index + size))
  return out
}

async function saveTrailerSweepState(cursor: number, complete: boolean): Promise<void> {
  await db
    .insert(syncState)
    .values({
      key: ANILIST_TRAILER_SWEEP_KEY,
      value: { cursor, complete },
      updatedAt: new Date(),
    })
    .onConflictDoUpdate({
      target: syncState.key,
      set: { value: { cursor, complete }, updatedAt: new Date() },
    })
}

export interface AniListTrailerSweepResult {
  scanned: number
  upserted: number
  complete: boolean
  /** null means the sweep had already completed and made no provider request. */
  providerReachable: boolean | null
}

/**
 * One-time, resumable repair for media rows written before videos/native titles/synonyms/artwork
 * existed. Empty fields cannot identify unfinished work because many titles genuinely omit them, so progress is a
 * durable id cursor rather than `WHERE videos = []`. One hourly run covers the current catalogue;
 * each 50-id request is spaced below AniList's degraded 30 requests/minute ceiling. A provider-wide
 * outage leaves the cursor untouched and the next hour retries without requiring a page visit.
 */
export async function sweepAniListTrailers(
  options: { limit?: number; requestIntervalMs?: number } = {},
): Promise<AniListTrailerSweepResult> {
  const [saved] = await db
    .select({ value: syncState.value })
    .from(syncState)
    .where(eq(syncState.key, ANILIST_TRAILER_SWEEP_KEY))
    .limit(1)
  if (saved?.value?.complete === true) {
    return { scanned: 0, upserted: 0, complete: true, providerReachable: null }
  }
  const rawCursor = saved?.value?.cursor
  const cursor = typeof rawCursor === 'number' && Number.isInteger(rawCursor) ? rawCursor : 0
  const limit = Math.max(1, options.limit ?? ANILIST_TRAILER_SWEEP_LIMIT)
  const rows = await db
    .select({ id: media.id })
    .from(media)
    .where(and(eq(media.source, 'anilist'), gt(media.id, cursor)))
    .orderBy(asc(media.id))
    .limit(limit + 1)
  if (rows.length === 0) {
    await saveTrailerSweepState(cursor, true)
    return { scanned: 0, upserted: 0, complete: true, providerReachable: null }
  }

  const hasMore = rows.length > limit
  const batch = rows.slice(0, limit)
  const chunks = chunked(batch, ANILIST_TRAILER_REQUEST_SIZE)
  let scanned = 0
  let upserted = 0
  for (let index = 0; index < chunks.length; index++) {
    const ids = chunks[index]!.map((row) => row.id)
    const fresh = await fetchByIds(ids, { maxRetries: 1, timeoutMs: 10_000 })
    // fetchByIds deliberately degrades failed batches to []; for this repair pass an all-empty
    // response means "do not advance" rather than "all these known ids vanished".
    if (fresh.length === 0) {
      return { scanned, upserted, complete: false, providerReachable: false }
    }
    await upsertMedia(fresh)
    scanned += ids.length
    upserted += fresh.length
    const nextCursor = ids.at(-1)!
    const complete = !hasMore && index === chunks.length - 1
    await saveTrailerSweepState(nextCursor, complete)
    if (index < chunks.length - 1) {
      await sleep(Math.max(0, options.requestIntervalMs ?? ANILIST_TRAILER_REQUEST_INTERVAL_MS))
    }
  }
  return { scanned, upserted, complete: !hasMore, providerReachable: true }
}

/**
 * Refresh airing data for currently-releasing AniList media (next episode + exact last-aired
 * time). Keeps countdowns and "out now" detection accurate. Source-filtered: TMDB rows live in
 * the same table but must never be sent to AniList (their ids are offset TMDB season ids).
 */
export async function refreshAiring(): Promise<number> {
  // Announced parts whose premiere instant has already passed are refreshed too. A status-only
  // filter never looks at them again, so the row freezes at NOT_YET_RELEASED with a premiere date
  // in the past — which the client then reads as a live airing ("today", every day) instead of the
  // RELEASING season it has actually become. `airingAt` is stored in SECONDS.
  const duePremiere = and(
    eq(media.status, 'NOT_YET_RELEASED'),
    sql`(${media.nextAiringEpisode} ->> 'airingAt')::bigint <= ${Math.floor(Date.now() / 1000)}`,
  )
  const rows = await db
    .select({ id: media.id })
    .from(media)
    .where(and(eq(media.source, 'anilist'), or(eq(media.status, 'RELEASING'), duePremiere)))
  const ids = rows.map((r) => r.id)
  if (ids.length === 0) return 0

  const fresh = await fetchByIds(ids)
  if (fresh.length === 0) throw new Error(`AniList returned no airing media (requested ${ids.length})`)
  await upsertMedia(fresh)

  const lastAired = await fetchLastAired(ids)
  for (const [id, ts] of Object.entries(lastAired)) {
    await db.update(media).set({ lastAiredAt: ts }).where(eq(media.id, Number(id)))
  }
  return fresh.length
}

/**
 * TV sibling of refreshAiring: re-fetch every TMDB show that is releasing or subscribed.
 * The show payload carries seasons[], so this also attaches newly-announced seasons — TV
 * needs no separate attachNewSeasons pass.
 */
export async function refreshAiringTv(): Promise<number> {
  if (!tmdbEnabled()) return 0
  const rows = await db
    .select({ id: franchise.id, externalId: franchise.externalId })
    .from(franchise)
    .leftJoin(franchiseMember, eq(franchiseMember.franchiseId, franchise.id))
    .leftJoin(media, eq(media.id, franchiseMember.mediaId))
    .leftJoin(subscriptions, eq(subscriptions.franchiseId, franchise.id))
    .where(
      and(eq(franchise.source, 'tmdb'), or(
        inArray(media.status, ['RELEASING', 'NOT_YET_RELEASED']),
        isNotNull(subscriptions.userId),
        sql`${franchise.updatedAt} < now() - interval '7 days'`,
      )),
    )
    .groupBy(franchise.id, franchise.externalId)
    // Rotate through oldest media; an unordered LIMIT starves the same titles forever.
    .orderBy(sql`min(${media.fetchedAt}) asc nulls first`, asc(franchise.id))
    .limit(100)

  const results = await mapWithConcurrency(rows, 5, async ({ id, externalId }) => {
    if (externalId == null) return false
    try {
      return (await refreshTvShow(id, externalId)).refreshed
    } catch (err) {
      console.warn(`refreshAiringTv: failed for franchise ${id}:`, (err as Error).message)
      return false
    }
  })
  return results.filter(Boolean).length
}

/**
 * Seed/refresh trending franchises: fetch top trending anime, cache them, and group any that
 * aren't grouped yet. Grouping is idempotent and component-deduped, so the number of actual
 * grouping calls is far smaller than the seed count.
 */
export async function seedTrending(count = env.TRENDING_SEED_COUNT): Promise<{ fetched: number; grouped: number }> {
  const trending = await fetchTrending(count)
  // An empty page is a degraded AniList response (HTTP 200, `media: []`), not a real state — the
  // catalogue is never empty. Left silent it logged "fetched 0 trending" and read as a success;
  // raising makes the run visibly fail instead of quietly doing nothing.
  if (count > 0 && trending.length === 0) {
    throw new Error(`AniList returned no trending media (requested ${count})`)
  }
  await upsertMedia(trending)

  const ids = trending.map((m) => m.id)
  const alreadyGrouped = new Set(
    (await db.select({ mediaId: franchiseMember.mediaId }).from(franchiseMember).where(inArray(franchiseMember.mediaId, ids))).map(
      (r) => r.mediaId,
    ),
  )

  let grouped = 0
  for (const m of trending) {
    if (alreadyGrouped.has(m.id)) continue
    try {
      // Pass the bulk model (not a pre-built grouper) so the per-component gate still applies:
      // most trending shows are simple sequel chains and never reach the LLM at all.
      const outcome = await groupFromSeed(m.id, { model: env.OPENROUTER_MODEL_BULK })
      grouped++
      // Mark every member of the resulting component as grouped so we skip them this run.
      const members = await db
        .select({ mediaId: franchiseMember.mediaId })
        .from(franchiseMember)
        .where(eq(franchiseMember.franchiseId, outcome.franchiseId))
      for (const mem of members) alreadyGrouped.add(mem.mediaId)
    } catch (err) {
      console.warn(`seedTrending: failed to group media ${m.id}:`, (err as Error).message)
    }
  }
  return { fetched: trending.length, grouped }
}

/**
 * Seed trending TV (capped low so getTrendingFranchises' updatedAt-DESC feed isn't swamped by
 * TV on day one). Known shows short-circuit on the franchise external-id fast path.
 */
export async function seedTrendingTv(count = 40): Promise<{ fetched: number; created: number }> {
  if (!tmdbEnabled()) return { fetched: 0, created: 0 }
  const trending = await getTrendingTv(count)
  const keep = trending.filter((r) => !isJapaneseAnimation(r))

  let created = 0
  for (const r of keep) {
    try {
      const outcome = await ensureTvFranchise(r.id)
      if (outcome?.created) created++
    } catch (err) {
      console.warn(`seedTrendingTv: failed for show ${r.id}:`, (err as Error).message)
    }
  }
  return { fetched: keep.length, created }
}

/**
 * Detect new parts that have joined AniList franchises a user follows (e.g. a new season aired
 * and the relation graph now links it). Re-expands from each subscribed franchise's members.
 * TMDB franchises are excluded — their new seasons attach via refreshAiringTv.
 */
export async function attachNewSeasons(): Promise<number> {
  const subbedFranchises = await db
    .selectDistinct({ franchiseId: subscriptions.franchiseId })
    .from(subscriptions)
    .innerJoin(franchise, eq(franchise.id, subscriptions.franchiseId))
    .where(eq(franchise.source, 'anilist'))
  let attached = 0
  for (const { franchiseId } of subbedFranchises) {
    const members = await db
      .select({ mediaId: franchiseMember.mediaId })
      .from(franchiseMember)
      .where(eq(franchiseMember.franchiseId, franchiseId))
    if (members[0]) {
      try {
        const outcome = await groupFromSeed(members[0].mediaId)
        attached += outcome.attached
      } catch (err) {
        console.warn(`attachNewSeasons: failed to regroup franchise ${franchiseId}:`, (err as Error).message)
      }
    }
  }
  return attached
}
