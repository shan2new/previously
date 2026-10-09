import { and, asc, eq, inArray, isNotNull, or } from 'drizzle-orm'
import { db } from '../db/index.js'
import {
  catalogLinks,
  franchise,
  franchiseMember,
  media,
  progress,
  recommendationEdges,
  recommendationFeedback,
  recommendationTargets,
  subscriptions,
} from '../db/schema.js'
import { env } from '../env.js'
import { groupFromSeed } from '../grouping/service.js'
import { tmdbEnabled } from '../tmdb/client.js'
import { ensureTvFranchise } from '../tmdb/service.js'
import type {
  MediaSource,
  RecommendationFeedbackKind,
  RecommendationItem,
  RecommendationsResponse,
  WatchStatus,
} from '../types/api.js'
import { createPacer } from '../util/pacer.js'
import { BoundedTaskQueue } from '../util/taskQueue.js'
import { enqueueAnimeVideoFallback } from './animeVideoFallback.js'
import { audienceSource } from './audience.js'
import { deriveAiredEpisodes, getSummaries } from './franchiseView.js'
import {
  rankRecommendations,
  type RankedRecommendation,
  type RankInput,
  type RankSeed,
  type RankTarget,
} from './recommendationRank.js'
import { applyFranchiseSeries, franchisesOfMedia, loadFranchiseSeries, type FranchiseSeries } from './recommendationRoots.js'
import { ContentExcludedError, consumerFranchiseConditions, consumerFranchiseIds, consumerAnimeFetcher } from './consumerContent.js'
import { makeAniListFetcher } from './mediaStore.js'

// The loader around the pure ranker (recommendationRank.ts): everything personal is read LIVE on
// every request — what the user owns right now, their progress and their feedback — and never
// trusted from the time a recommendation list was written. ~10 indexed reads; no per-user cache.

const DAY_MS = 86_400_000
const WATCH_STATUSES = new Set<WatchStatus>(['watching', 'completed', 'planned', 'paused', 'dropped'])
const SERIES_FORMATS = new Set(['TV', 'ONA'])
const ANILIST_BACKGROUND_INTERVAL_MS = 2_100

// Served titles with no show page yet are built in the background so a tap opens a real page —
// grouping one takes 2–10 AniList round trips (3–15 s), far too slow for the tap itself. Bounded
// in width and depth like Search's warming queue: excess work is dropped, never accumulated.
const materialiser = new BoundedTaskQueue(1, 24, (key, error) => {
  console.warn(`recommendation materialisation failed (${key}):`, 'diagnostic details redacted')
})

export interface LoadedRankInput {
  input: RankInput
  /** Materialised franchises the targets resolved to (for presenting served items). */
  series: Map<string, FranchiseSeries>
}

/** Everything the ranker needs for one user, resolved live. */
export async function loadRankInput(userId: string, now = Date.now()): Promise<LoadedRankInput> {
  const library = await db
    .select({
      franchiseId: subscriptions.franchiseId,
      status: subscriptions.status,
      createdAt: subscriptions.createdAt,
      title: franchise.title,
      source: franchise.source,
      externalId: franchise.externalId,
      genres: franchise.genres,
    })
    .from(subscriptions)
    .innerJoin(franchise, eq(franchise.id, subscriptions.franchiseId))
    .where(and(eq(subscriptions.userId, userId), ...consumerFranchiseConditions()))
    .orderBy(asc(subscriptions.createdAt), asc(subscriptions.franchiseId))
  const feedback = await db
    .select({ key: recommendationFeedback.key, kind: recommendationFeedback.kind })
    .from(recommendationFeedback)
    .where(eq(recommendationFeedback.userId, userId))
  const empty: LoadedRankInput = { input: { now, seeds: [], edges: [], targets: [], feedback: [] }, series: new Map() }
  if (library.length === 0) return empty

  const ids = library.map((row) => row.franchiseId)
  const [parts, watched, edgeRows] = await Promise.all([
    db
      .select({
        franchiseId: franchiseMember.franchiseId,
        mediaId: franchiseMember.mediaId,
        partKind: franchiseMember.partKind,
        status: media.status,
        episodes: media.episodes,
        next: media.nextAiringEpisode,
      })
      .from(franchiseMember)
      .leftJoin(media, eq(media.id, franchiseMember.mediaId))
      .where(inArray(franchiseMember.franchiseId, ids)),
    db
      .select({ mediaId: progress.mediaId, episodes: progress.episodesWatched, updatedAt: progress.updatedAt })
      .from(progress)
      .where(eq(progress.userId, userId)),
    db
      .select({
        franchiseId: recommendationEdges.franchiseId,
        source: recommendationEdges.source,
        externalId: recommendationEdges.externalId,
        rank: recommendationEdges.rank,
        votes: recommendationEdges.votes,
      })
      .from(recommendationEdges)
      // Rows from before the ranked shape (no rank) carry no target facts; the backfill rewrites them.
      .where(and(inArray(recommendationEdges.franchiseId, ids), isNotNull(recommendationEdges.rank))),
  ])

  const progressByMedia = new Map(watched.map((row) => [row.mediaId, row]))
  const partsByFranchise = new Map<string, typeof parts>()
  for (const part of parts) {
    const list = partsByFranchise.get(part.franchiseId) ?? []
    list.push(part)
    partsByFranchise.set(part.franchiseId, list)
  }
  const seeds: RankSeed[] = library.map((row) => {
    const source: MediaSource = row.source === 'tmdb' ? 'tmdb' : 'anilist'
    const own = partsByFranchise.get(row.franchiseId) ?? []
    let watchedEpisodes = 0
    let airedEpisodes = 0
    let lastActivityAt = row.createdAt.getTime()
    for (const part of own) {
      const mark = progressByMedia.get(part.mediaId)
      if (mark && mark.updatedAt.getTime() > lastActivityAt) lastActivityAt = mark.updatedAt.getTime()
      if (part.partKind !== 'season' && part.partKind !== 'ona') continue
      watchedEpisodes += mark?.episodes ?? 0
      airedEpisodes += deriveAiredEpisodes({
        status: part.status,
        totalEpisodes: part.episodes ?? 0,
        next: part.next,
        episodes: [],
        nowMs: now,
      })
    }
    return {
      franchiseId: row.franchiseId,
      title: row.title,
      source,
      status: WATCH_STATUSES.has(row.status as WatchStatus) ? (row.status as WatchStatus) : 'planned',
      genres: row.genres ?? [],
      watchedEpisodes,
      airedEpisodes,
      airing: own.some((part) => part.status === 'RELEASING'),
      lastActivityAt,
      memberIds: source === 'anilist' ? own.map((part) => part.mediaId) : [],
      externalId: source === 'tmdb' ? row.externalId : null,
    }
  })

  // Library order, then each seed's own list order: the ranker's tie-breaks follow this order.
  const seedOrder = new Map(ids.map((id, index) => [id, index]))
  edgeRows.sort((a, b) =>
    seedOrder.get(a.franchiseId)! - seedOrder.get(b.franchiseId)! || a.rank! - b.rank! || a.externalId - b.externalId,
  )
  const edges = edgeRows.map((row) => ({
    seedId: row.franchiseId,
    source: (row.source === 'tmdb' ? 'tmdb' : 'anilist') as MediaSource,
    externalId: row.externalId,
    rank: row.rank!,
    votes: row.source === 'tmdb' ? null : (row.votes ?? 0),
  }))
  const { targets, series } = await loadTargets(edges)
  return {
    input: {
      now,
      seeds,
      edges,
      targets,
      feedback: feedback.map((row) => ({
        key: row.key,
        kind: row.kind === 'seen' ? 'seen' : 'dismissed',
      })),
    },
    series,
  }
}

/** The target rows for a set of edges, with each title's local franchise resolved now. */
async function loadTargets(edges: { source: MediaSource; externalId: number }[]): Promise<{
  targets: RankTarget[]
  series: Map<string, FranchiseSeries>
}> {
  const aniIds = [...new Set(edges.filter((e) => e.source === 'anilist').map((e) => e.externalId))]
  const tvIds = [...new Set(edges.filter((e) => e.source === 'tmdb').map((e) => e.externalId))]
  if (aniIds.length === 0 && tvIds.length === 0) return { targets: [], series: new Map() }
  const rows = await db
    .select()
    .from(recommendationTargets)
    .where(or(
      aniIds.length ? and(eq(recommendationTargets.source, 'anilist'), inArray(recommendationTargets.externalId, aniIds)) : undefined,
      tvIds.length ? and(eq(recommendationTargets.source, 'tmdb'), inArray(recommendationTargets.externalId, tvIds)) : undefined,
    ))

  // Live resolution: the title itself or its series root may have become a show page since the
  // list was written; a TV title is either a TV franchise or a matched catalogue link.
  const aniRows = rows.filter((row) => row.source === 'anilist')
  const tvRows = rows.filter((row) => row.source === 'tmdb')
  const [aniOwner, tvFranchises, tvLinks] = await Promise.all([
    franchisesOfMedia(aniRows.flatMap((row) => [row.externalId, row.rootId])),
    tvRows.length
      ? db
          .select({ externalId: franchise.externalId, id: franchise.id })
          .from(franchise)
          .where(and(eq(franchise.source, 'tmdb'), inArray(franchise.externalId, tvRows.map((row) => row.externalId))))
      : Promise.resolve([]),
    tvRows.length
      ? db
          .select({ externalId: catalogLinks.externalId, id: catalogLinks.franchiseId })
          .from(catalogLinks)
          .where(and(
            eq(catalogLinks.provider, 'tmdb'),
            eq(catalogLinks.status, 'matched'),
            inArray(catalogLinks.externalId, tvRows.map((row) => row.externalId)),
          ))
      : Promise.resolve([]),
  ])
  const tvOwner = new Map<number, string>()
  for (const row of tvLinks) if (row.externalId != null) tvOwner.set(row.externalId, row.id)
  for (const row of tvFranchises) if (row.externalId != null) tvOwner.set(row.externalId, row.id)

  const targets: RankTarget[] = rows.map((row) => ({
    source: row.source === 'tmdb' ? 'tmdb' : 'anilist',
    externalId: row.externalId,
    franchiseId:
      row.source === 'tmdb'
        ? (tvOwner.get(row.externalId) ?? null)
        : (aniOwner.get(row.externalId) ?? aniOwner.get(row.rootId) ?? null),
    title: row.title,
    year: row.year,
    images: row.images,
    format: row.format,
    status: row.status,
    episodes: row.episodes,
    averageScore: row.averageScore,
    voteCount: row.voteCount,
    popularity: row.popularity,
    genres: row.genres ?? [],
    isAdult: row.isAdult,
    countryOfOrigin: row.countryOfOrigin,
    airing: row.airing,
    announced: row.announced,
    releaseDate: row.releaseDate,
    rootId: row.rootId,
    rootTitle: row.rootTitle,
    rootYear: row.rootYear,
    rootFormat: row.rootFormat,
    rootEpisodes: row.rootEpisodes,
    rootImages: row.rootImages,
    memberIds: row.memberIds ?? [],
    worldIds: row.worldIds ?? [],
  }))

  const series = await loadFranchiseSeries(
    targets.map((target) => target.franchiseId).filter((id): id is string => id != null),
  )
  for (const target of targets) {
    const value = target.franchiseId ? series.get(target.franchiseId) : undefined
    if (!value) continue
    if (value.source === 'anilist') {
      // A materialised title is keyed by its franchise's root, so its seasons (and a TMDB listing
      // of the same anime) merge into one recommendation.
      applyFranchiseSeries(target, value)
      if (target.source === 'tmdb') target.key = `anilist:${value.rootId}`
    } else {
      target.airing ||= value.airing
      target.announced ||= value.announced
      target.episodes = value.episodes ?? target.episodes
    }
  }
  return { targets, series }
}

/** Shape the ranker's list for the client, with live show-page facts for materialised titles. */
async function present(
  ranked: RankedRecommendation[],
  series: Map<string, FranchiseSeries>,
): Promise<RecommendationItem[]> {
  const franchiseIds = [...new Set(ranked.map((item) => item.franchiseId).filter((id): id is string => id != null))]
  const summaries = new Map((await getSummaries(franchiseIds)).map((summary) => [summary.id, summary]))
  return ranked.filter((item) => !item.franchiseId || summaries.has(item.franchiseId)).map((item): RecommendationItem => {
    const summary = item.franchiseId ? summaries.get(item.franchiseId) : undefined
    const facts = item.franchiseId ? series.get(item.franchiseId) : undefined
    return {
      key: item.key,
      franchiseId: summary ? item.franchiseId : null,
      source: item.source,
      externalId: item.externalId,
      title: summary?.title ?? item.title,
      year: summary?.year ?? item.year,
      images: summary?.images ?? item.images,
      artwork: summary?.artwork ?? null,
      format: facts?.rootFormat && SERIES_FORMATS.has(facts.rootFormat) ? facts.rootFormat : item.format,
      episodes: facts?.episodes ?? item.episodes,
      // The series facts' "on air" (a season or ONA releasing), not the summary's any-member
      // `isReleasing`, which a special or film tie-in also sets (review i5, F7).
      airing: facts ? facts.airing : item.airing,
      genres: facts ? facts.genres.slice(0, 4) : item.genres,
      reason: item.reason,
      score: item.score,
    }
  })
}

/**
 * `GET /me/recommendations`: the user's ranked list for today (deterministic for user + UTC day).
 * Served titles without a show page are queued for background materialisation.
 *
 * Only titles of the viewer's AUDIENCE (services/audience.ts) — resolved HERE, not in the callers,
 * so the route, the nightly materialiser and any future call site inherit the rule; `source`
 * overrides it (null = both catalogues). The ranker filters before it selects, so the list is full.
 */
export async function getRecommendations(
  userId: string,
  limit = 12,
  options: { now?: number; materialise?: boolean; source?: MediaSource | null } = {},
): Promise<RecommendationsResponse> {
  const now = options.now ?? Date.now()
  const [{ input, series }, source] = await Promise.all([
    loadRankInput(userId, now),
    options.source !== undefined ? options.source : audienceSource(userId),
  ])
  const ranked = rankRecommendations(input, { userId, limit, source })
  const items = await present(ranked.items, series)
  if (options.materialise !== false) {
    queueMaterialisation(items)
    queueArtUpgrade(items)
  }
  return { items, generatedAt: now }
}

export async function recordRecommendationFeedback(
  userId: string,
  key: string,
  kind: RecommendationFeedbackKind,
): Promise<void> {
  await db
    .insert(recommendationFeedback)
    .values({ userId, key, kind })
    .onConflictDoUpdate({
      target: [recommendationFeedback.userId, recommendationFeedback.key],
      set: { kind, createdAt: new Date() },
    })
}

export async function clearRecommendationFeedback(userId: string, key: string): Promise<void> {
  await db
    .delete(recommendationFeedback)
    .where(and(eq(recommendationFeedback.userId, userId), eq(recommendationFeedback.key, key)))
}

/** The show page that already exists for a catalogue title, if any (no provider call). */
export async function findLocalFranchise(source: MediaSource, externalId: number): Promise<string | null> {
  if (source === 'anilist') {
    return (await franchisesOfMedia([externalId])).get(externalId) ?? null
  }
  const [row] = await db
    .select({ id: franchise.id })
    .from(franchise)
    .where(and(eq(franchise.source, 'tmdb'), eq(franchise.externalId, externalId)))
    .limit(1)
  return row?.id ?? null
}

/**
 * Build the show page for a recommended title. Anime go through `groupFromSeed` on the bulk model
 * (off the interactive path, so the grouping cost tiers apply unchanged); TV through
 * `ensureTvFranchise` (no LLM; it refuses Japanese animation itself).
 */
export async function materialiseRecommendation(source: MediaSource, externalId: number): Promise<string | null> {
  const local = await findLocalFranchise(source, externalId)
  if (local) {
    if (!(await consumerFranchiseIds([local])).has(local)) throw new ContentExcludedError()
    return local
  }
  if (source === 'anilist') return (await groupFromSeed(externalId, {
    model: env.OPENROUTER_MODEL_BULK,
    fetcher: consumerAnimeFetcher(externalId, makeAniListFetcher()),
  })).franchiseId
  if (!tmdbEnabled()) return null
  return (await ensureTvFranchise(externalId, { consumerOnly: true }))?.franchiseId ?? null
}

/**
 * A served anime title with only AniList's 460-px cover gets the TMDB twin's art (and trailers)
 * through the same single-flight hook Detail and Search use — the client features a recommendation
 * on Today's billboard only with billboard-grade art (review i5, U5-N3), so without this an anime
 * pick could never take the stage.
 */
function queueArtUpgrade(items: RecommendationItem[]): void {
  if (!tmdbEnabled()) return
  for (const item of items) {
    if (item.source !== 'anilist' || !item.franchiseId) continue
    const portraits = item.artwork?.portraits ?? []
    if (portraits.some((p) => p.source === 'tmdb')) continue
    enqueueAnimeVideoFallback(item.franchiseId)
  }
}

function queueMaterialisation(items: RecommendationItem[]): void {
  for (const item of items) {
    if (item.franchiseId || (item.source === 'tmdb' && !tmdbEnabled())) continue
    materialiser.enqueue(`reco:${item.key}`, async () => {
      await materialiseRecommendation(item.source, item.externalId)
    })
  }
}

/**
 * Nightly: build show pages for every user's top recommendations — today's list and tomorrow's, so
 * the UTC day that starts after the job is covered whatever the host's timezone — round-robin
 * across users by position, each title once, capped. Serial and spaced: grouping talks to AniList.
 */
export async function materialiseTopRecommendations(options: { perUser?: number; cap?: number; now?: number } = {}): Promise<{
  users: number
  due: number
  materialised: number
  failed: number
}> {
  const perUser = options.perUser ?? 12
  const cap = options.cap ?? 40
  const now = options.now ?? Date.now()
  const people = await db.selectDistinct({ userId: subscriptions.userId }).from(subscriptions)
  const lists: RecommendationItem[][] = []
  for (const { userId } of people) {
    for (const day of [now, now + DAY_MS]) {
      try {
        lists.push((await getRecommendations(userId, perUser, { now: day, materialise: false })).items)
      } catch (error) {
        console.warn('[recommendations] refresh failed')
      }
    }
  }
  const due: RecommendationItem[] = []
  const seen = new Set<string>()
  for (let position = 0; position < perUser && due.length < cap; position++) {
    for (const list of lists) {
      const item = list[position]
      if (!item || item.franchiseId || seen.has(item.key)) continue
      if (item.source === 'tmdb' && !tmdbEnabled()) continue
      seen.add(item.key)
      due.push(item)
      if (due.length >= cap) break
    }
  }
  const pace = createPacer(ANILIST_BACKGROUND_INTERVAL_MS)
  let materialised = 0
  let failed = 0
  for (const item of due) {
    try {
      if (item.source === 'anilist') await pace()
      if (await materialiseRecommendation(item.source, item.externalId)) materialised++
    } catch (error) {
      failed++
      console.warn(`recommendation materialisation failed (${item.key}):`, 'diagnostic details redacted')
    }
  }
  return { users: people.length, due: due.length, materialised, failed }
}
