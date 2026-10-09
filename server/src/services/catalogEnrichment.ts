import { and, eq, inArray, isNotNull, max, or, sql } from 'drizzle-orm'
import { fetchEnrichmentByIds, type AniListRequestOptions } from '../anilist/client.js'
import type {
  AniListCharacterEdge,
  AniListMedia,
  AniListMediaEnrichment,
  AniListPerson,
  AniListRecommendedMedia,
  AniListStaffEdge,
} from '../anilist/types.js'
import { db } from '../db/index.js'
import { franchise, franchiseMember, media, recommendationEdges, recommendationTargets, subscriptions } from '../db/schema.js'
import { getShow, tmdbEnabled, type TmdbRequestOptions } from '../tmdb/client.js'
import { tmdbArtwork, tmdbFranchiseEnrichment, tmdbRecommendationTargets } from '../tmdb/mapping.js'
import type { ArtworkGallery, CatalogPerson, FranchiseEnrichment, FranchisePeople, RelatedTitle } from '../types/api.js'
import { rankArtwork } from '../util/artwork.js'
import { mapWithConcurrency } from '../util/concurrency.js'
import { createPacer } from '../util/pacer.js'
import { BoundedTaskQueue } from '../util/taskQueue.js'
import { storedRoots, syncRecommendationEdges, type RecommendationTargetWrite } from './recommendationEdges.js'
import type { RecommendationEdgeFacts } from './recommendationRank.js'
import { resolveSeriesRoots, type RootWalkOptions, type RootWalkStart } from './recommendationRoots.js'
import { consumerFranchiseIds, isExcludedContent } from './consumerContent.js'

const D = 86_400_000
const REFRESH_AFTER_MS = 7 * D
/** A series root rarely changes; re-walk it monthly. */
const ROOT_REFRESH_MS = 30 * D
const TMDB_RECOMMENDATIONS_REFRESH_MS = 20 * 60 * 60 * 1000
const ANILIST_BACKGROUND_INTERVAL_MS = 2_100
const EMPTY_PEOPLE: FranchisePeople = { creators: [], directors: [], cast: [] }

const queue = new BoundedTaskQueue(2, 48, (key, error) => {
  console.warn(`catalog enrichment failed (${key}):`, 'diagnostic details redacted')
})

function aniListPerson(person: AniListPerson, role: string | null): CatalogPerson | null {
  const name = person.name.full?.trim()
  if (!name) return null
  return {
    source: 'anilist',
    externalId: person.id,
    name,
    role: role?.trim() || null,
    image: person.image.large ?? null,
  }
}

function dedupePeople(people: (CatalogPerson | null)[], limit: number): CatalogPerson[] {
  const seen = new Set<number>()
  const out: CatalogPerson[] = []
  for (const person of people) {
    if (!person || seen.has(person.externalId)) continue
    seen.add(person.externalId)
    out.push(person)
    if (out.length >= limit) break
  }
  return out
}

function aniListPeople(items: AniListMediaEnrichment[]): FranchisePeople {
  const staff = items.flatMap((item) => item.staff?.edges ?? [])
  const creators = dedupePeople(
    staff
      .filter((edge: AniListStaffEdge) => /original (creator|story)|creator|mangaka/i.test(edge.role ?? ''))
      .map((edge) => aniListPerson(edge.node, edge.role)),
    4,
  )
  const directors = dedupePeople(
    staff
      .filter((edge: AniListStaffEdge) => /director/i.test(edge.role ?? ''))
      .map((edge) => aniListPerson(edge.node, edge.role)),
    4,
  )
  const cast = dedupePeople(
    items.flatMap((item) =>
      (item.characters?.edges ?? []).flatMap((edge: AniListCharacterEdge) => {
        const character = edge.node.name.full?.trim() || edge.role?.trim() || null
        return (edge.voiceActors ?? []).map((actor) => aniListPerson(actor, character))
      }),
    ),
    10,
  )
  return { creators, directors, cast }
}

/** A cheap row available from the normal AniList media payload; deep graphs arrive later. */
export function basicAniListEnrichment(
  primary: AniListMedia | undefined,
  genres: string[],
  nowMs = Date.now(),
): FranchiseEnrichment {
  return {
    level: 'basic',
    themes: [...new Set(genres)].slice(0, 10),
    isAdult: primary?.isAdult ?? null,
    contentRatings: [],
    people: EMPTY_PEOPLE,
    related: [],
    videos: [],
    checkedAt: new Date(nowMs).toISOString(),
  }
}

/** Show page "More like this" keeps ten; the recommendation ranker reads twenty (twice the consensus). */
const ANILIST_RELATED_TITLES = 10
const ANILIST_RANKED_RECOMMENDATIONS = 20
/** Relations that keep a title inside its own series (the grouping graph's FOLLOW set). */
const SERIES_RELATIONS = new Set(['SEQUEL', 'PREQUEL', 'PARENT', 'SIDE_STORY'])
/** Relations to a separate work of the same universe. */
const WORLD_RELATIONS = new Set(['SPIN_OFF', 'ALTERNATIVE', 'CHARACTER', 'OTHER', 'SUMMARY'])
const UP_RELATIONS = new Set(['PREQUEL', 'PARENT'])

interface RankedAniListRecommendation {
  media: AniListRecommendedMedia
  rating: number | null
  title: string
}

/**
 * A franchise's AniList recommendations in stored order: anime only, never one of its own parts,
 * titled, strongest community vote first, each title once. Both the show page's ten and the ranker's
 * twenty are prefixes of this one list.
 */
function rankedAniListRecommendations(
  items: AniListMediaEnrichment[],
  memberIds: Set<number>,
): RankedAniListRecommendation[] {
  const nodes = items
    .flatMap((item) => item.recommendations?.nodes ?? [])
    .filter((node) => node.mediaRecommendation?.type === 'ANIME' && !memberIds.has(node.mediaRecommendation.id))
    .sort((a, b) => (b.rating ?? 0) - (a.rating ?? 0))
  const seen = new Set<number>()
  const out: RankedAniListRecommendation[] = []
  for (const node of nodes) {
    const candidate = node.mediaRecommendation
    if (!candidate || seen.has(candidate.id)) continue
    const title = (candidate.title.english || candidate.title.romaji || '').trim()
    if (!title) continue
    seen.add(candidate.id)
    out.push({ media: candidate, rating: node.rating ?? null, title })
  }
  return out
}

function isoDate(date: AniListRecommendedMedia['startDate']): string | null {
  if (!date?.year || !date.month || !date.day) return null
  return `${date.year}-${String(date.month).padStart(2, '0')}-${String(date.day).padStart(2, '0')}`
}

/**
 * The ranker's view of a franchise's AniList recommendations: up to twenty edges (community vote,
 * rank) and the facts about each title, with the walk starts that give each its series root.
 * Pure — the series-root walk (I/O) runs on `starts` afterwards.
 */
export function aniListRecommendationTargets(items: AniListMediaEnrichment[], memberIds: Set<number>): {
  edges: RecommendationEdgeFacts[]
  targets: RecommendationTargetWrite[]
  starts: RootWalkStart[]
} {
  const ranked = rankedAniListRecommendations(items, memberIds).slice(0, ANILIST_RANKED_RECOMMENDATIONS)
  const starts = ranked.map(({ media: m, title }): RootWalkStart => {
    const relations = (m.relations?.edges ?? []).filter((edge) => edge.node.type === 'ANIME')
    const series = relations.filter((edge) => SERIES_RELATIONS.has(edge.relationType) && edge.node.format !== 'MUSIC')
    const images = { portrait: m.coverImage.extraLarge ?? m.coverImage.large ?? null, landscape: m.bannerImage ?? null }
    const target: RecommendationTargetWrite = {
      source: 'anilist',
      externalId: m.id,
      title,
      year: m.seasonYear ?? null,
      images,
      format: m.format ?? null,
      status: m.status ?? null,
      episodes: m.episodes ?? null,
      averageScore: (m.averageScore || m.meanScore) ?? null,
      voteCount: null,
      popularity: m.popularity ?? null,
      genres: m.genres ?? [],
      isAdult: m.isAdult === true,
      countryOfOrigin: m.countryOfOrigin ?? null,
      airing: m.status === 'RELEASING' || series.some((edge) => edge.node.status === 'RELEASING'),
      announced: series.some((edge) => edge.node.status === 'NOT_YET_RELEASED'),
      releaseDate: isoDate(m.startDate),
      // Its own root until the walk says otherwise.
      rootId: m.id,
      rootTitle: title,
      rootYear: m.seasonYear ?? null,
      rootFormat: m.format ?? null,
      rootEpisodes: m.episodes ?? null,
      rootImages: images,
      memberIds: [...new Set([m.id, ...series.map((edge) => edge.node.id)])],
      worldIds: [...new Set(relations.filter((edge) => WORLD_RELATIONS.has(edge.relationType)).map((edge) => edge.node.id))],
    }
    return {
      target,
      ups: series.filter((edge) => UP_RELATIONS.has(edge.relationType)).map((edge) => edge.node.id),
      season: m.season ?? null,
    }
  })
  return {
    edges: ranked.map(({ media: m, rating }, rank) => ({ source: 'anilist', externalId: m.id, rank, votes: rating ?? 0 })),
    targets: starts.map((start) => start.target),
    starts,
  }
}

/**
 * Series identity for every AniList target: a root checked within the last month is reused from
 * `recommendation_targets`; the rest are walked (local first, then AniList).
 */
async function attachSeriesRoots(starts: RootWalkStart[], options: RootWalkOptions): Promise<void> {
  const stored = await storedRoots(
    starts.map((start) => start.target.externalId),
    new Date(Date.now() - ROOT_REFRESH_MS),
  )
  const walk: RootWalkStart[] = []
  for (const start of starts) {
    const previous = stored.get(start.target.externalId)
    if (!previous) {
      walk.push(start)
      continue
    }
    const target = start.target as RecommendationTargetWrite
    target.rootId = previous.rootId
    target.rootTitle = previous.rootTitle
    target.rootYear = previous.rootYear
    target.rootFormat = previous.rootFormat
    target.rootEpisodes = previous.rootEpisodes
    target.rootImages = previous.rootImages
    target.memberIds = [...new Set([...target.memberIds, ...previous.memberIds])]
    target.rootCheckedAt = previous.rootCheckedAt
  }
  await resolveSeriesRoots(walk, options)
}

/** Map AniList's explicit spoiler flags into a conservative source-neutral franchise payload. */
export function aniListFranchiseEnrichment(
  items: AniListMediaEnrichment[],
  genres: string[],
  memberIds: Set<number>,
  nowMs = Date.now(),
): FranchiseEnrichment {
  const safeTags = items
    .flatMap((item) => item.tags ?? [])
    .filter((tag) => !tag.isGeneralSpoiler && !tag.isMediaSpoiler && !tag.isAdult)
    .sort((a, b) => b.rank - a.rank)
    .map((tag) => tag.name.trim())
    .filter(Boolean)
  const themes = [...new Set([...safeTags, ...genres])].slice(0, 10)
  const adultValues = items.map((item) => item.isAdult).filter((value): value is boolean => value != null)

  const related: RelatedTitle[] = rankedAniListRecommendations(items, memberIds)
    .filter(({ media: candidate }) => !isExcludedContent(candidate))
    .slice(0, ANILIST_RELATED_TITLES)
    .map(({ media: candidate, rating, title }) => ({
      source: 'anilist',
      externalId: candidate.id,
      franchiseId: null,
      title,
      year: candidate.seasonYear ?? null,
      images: {
        portrait: candidate.coverImage.extraLarge ?? candidate.coverImage.large ?? null,
        landscape: candidate.bannerImage ?? null,
      },
      score: rating,
    }))

  return {
    level: 'full',
    themes,
    isAdult: adultValues.length ? adultValues.some(Boolean) : null,
    contentRatings: [],
    people: aniListPeople(items),
    related,
    videos: [],
    checkedAt: new Date(nowMs).toISOString(),
  }
}

function stillFresh(value: { level?: string | null; checkedAt?: string | null } | null | undefined): boolean {
  if (value?.level !== 'full') return false
  const checked = Date.parse(value.checkedAt ?? '')
  return Number.isFinite(checked) && checked > Date.now() - REFRESH_AFTER_MS
}

function mergeArtwork(
  current: ArtworkGallery | null | undefined,
  incoming: ArtworkGallery,
): ArtworkGallery {
  const merge = (stored: ArtworkGallery['portraits'] = [], fetched: ArtworkGallery['portraits'] = []) =>
    rankArtwork([...stored, ...fetched])
  return {
    portraits: merge(current?.portraits, incoming.portraits),
    landscapes: merge(current?.landscapes, incoming.landscapes),
    logos: merge(current?.logos, incoming.logos),
  }
}

/** Refresh one franchise's expensive catalogue metadata. Safe to call repeatedly. */
export async function refreshFranchiseEnrichment(
  franchiseId: string,
  options: {
    force?: boolean
    anilistRequest?: AniListRequestOptions
    tmdbRequest?: TmdbRequestOptions
    /** Awaited before every AniList request (background sweeps space them ~2.1 s apart). */
    pace?: () => Promise<void>
  } = {},
): Promise<boolean> {
  const [row] = await db.select().from(franchise).where(eq(franchise.id, franchiseId)).limit(1)
  if (!row || (!options.force && stillFresh(row.enrichment))) return false

  if (row.source === 'tmdb') {
    if (row.externalId == null) return false
    const show = await getShow(row.externalId, { ...options.tmdbRequest, enrichment: true })
    if (!show) return false
    const value = tmdbFranchiseEnrichment(show)
    const artwork = mergeArtwork(row.artwork, tmdbArtwork(show))
    await db
      .update(franchise)
      .set({ enrichment: value, artwork, updatedAt: new Date() })
      .where(eq(franchise.id, franchiseId))
    const reco = tmdbRecommendationTargets(show)
    await syncRecommendationEdges(franchiseId, reco.edges, reco.targets)
    return true
  }

  const members = await db
    .select({
      mediaId: franchiseMember.mediaId,
      sequence: franchiseMember.sequence,
      status: media.status,
    })
    .from(franchiseMember)
    .innerJoin(media, eq(media.id, franchiseMember.mediaId))
    .where(eq(franchiseMember.franchiseId, franchiseId))
  if (members.length === 0) return false

  // Primary + current/future/latest parts capture canonical staff, current voice cast and useful
  // recommendations in one small GraphQL request without traversing every OVA/special.
  const ranked = members.slice().sort((a, b) => {
    const priority = (status: string | null) => status === 'NOT_YET_RELEASED' ? 2 : status === 'RELEASING' ? 1 : 0
    return priority(b.status) - priority(a.status) || b.sequence - a.sequence
  })
  const representativeIds = [row.primaryMediaId, ...ranked.map((item) => item.mediaId)]
    .filter((id): id is number => id != null)
    .filter((id, index, all) => all.indexOf(id) === index)
    .slice(0, 3)
  await options.pace?.()
  const enriched = await fetchEnrichmentByIds(representativeIds, options.anilistRequest)
  if (enriched.length === 0) return false

  const memberIds = new Set(members.map((item) => item.mediaId))
  const value = aniListFranchiseEnrichment(enriched, row.genres ?? [], memberIds)
  const reco = aniListRecommendationTargets(enriched, memberIds)
  await attachSeriesRoots(reco.starts, { request: options.anilistRequest, pace: options.pace })
  // TMDB is metadata-only for anime. Merge fallback fields from the row AT UPDATE TIME rather than
  // the snapshot read above: Search queues both enrichers together, and a read/modify/write here
  // could otherwise erase a trailer that arrived while the AniList request was in flight.
  await db.update(franchise).set({
    enrichment: sql`jsonb_strip_nulls(
      ${JSON.stringify(value)}::jsonb || jsonb_build_object(
        'videos', coalesce(${franchise.enrichment}->'videos', '[]'::jsonb),
        'videoFallback', ${franchise.enrichment}->'videoFallback'
      )
    )`,
    updatedAt: new Date(),
  }).where(eq(franchise.id, franchiseId))
  await syncRecommendationEdges(franchiseId, reco.edges, reco.targets)
  return true
}

/** Stale-while-revalidate entry point for Search and Detail. Never blocks either response. */
export function enqueueFranchiseEnrichment(franchiseId: string): void {
  queue.enqueue(`franchise:${franchiseId}`, async () => {
    await refreshFranchiseEnrichment(franchiseId)
  })
}

/** Franchises (of `ids`) that already have a recommendation list in the ranked shape. */
async function withRankedList(ids: string[]): Promise<Set<string>> {
  if (ids.length === 0) return new Set()
  const rows = await db
    .selectDistinct({ franchiseId: recommendationEdges.franchiseId })
    .from(recommendationEdges)
    .where(and(inArray(recommendationEdges.franchiseId, ids), isNotNull(recommendationEdges.rank)))
  return new Set(rows.map((row) => row.franchiseId))
}

/**
 * A newly followed show must vote at once: when it has no ranked recommendation list (never
 * enriched, or enriched before lists were ranked), refresh it now rather than after the weekly
 * cadence says its enrichment is stale.
 */
export function enqueueRecommendationRefresh(franchiseId: string): void {
  queue.enqueue(`recommendations:${franchiseId}`, async () => {
    if ((await withRankedList([franchiseId])).has(franchiseId)) return
    const [row] = await db
      .select({ source: franchise.source, level: enrichmentLevel, related: enrichmentRelated })
      .from(franchise)
      .where(eq(franchise.id, franchiseId))
      .limit(1)
    if (!row || (row.source === 'tmdb' && !tmdbEnabled()) || !needsRankedList(row)) return
    await refreshFranchiseEnrichment(franchiseId, { force: true })
  })
}

const enrichmentLevel = sql<string | null>`${franchise.enrichment}->>'level'`
const enrichmentCheckedAt = sql<string | null>`${franchise.enrichment}->>'checkedAt'`
const enrichmentRelated = sql<number>`jsonb_array_length(coalesce(${franchise.enrichment}->'related', '[]'::jsonb))`.mapWith(Number)

/**
 * For a show with no ranked list: was it never read in the ranked shape? The show page's `related`
 * is written by the same refresh as the ranked edges, so thin enrichment, or related titles with no
 * ranked edge behind them, mean an old-shape read. Full enrichment with no related titles means the
 * catalogue genuinely recommends nothing — not a reason to read it again.
 */
function needsRankedList(row: { level: string | null; related: number }): boolean {
  return row.level !== 'full' || row.related > 0
}

/**
 * Slowly repair/refresh followed anime without depending on a Detail visit. AniList may enforce a
 * 30 requests/minute degraded limit, so this is intentionally sequential, capped, and stops after
 * three provider misses. Fresh rows short-circuit before any network request.
 */
export async function refreshSubscribedAniListEnrichment(limit = 25): Promise<{
  checked: number
  refreshed: number
}> {
  const candidates = await db
    .selectDistinct({ id: franchise.id, level: enrichmentLevel, checkedAt: enrichmentCheckedAt, related: enrichmentRelated })
    .from(subscriptions)
    .innerJoin(franchise, eq(franchise.id, subscriptions.franchiseId))
    .where(eq(franchise.source, 'anilist'))
  // Stalest first, so a capped night always makes progress on the oldest rows; a show whose list
  // predates the ranked shape counts as stale (and goes first) whatever its enrichment date says.
  const ranked = await withRankedList(candidates.map((row) => row.id))
  const unranked = (row: (typeof candidates)[number]) => !ranked.has(row.id) && needsRankedList(row)
  const age = (row: (typeof candidates)[number]) => (unranked(row) ? 0 : Date.parse(row.checkedAt ?? '') || 0)
  const stale = candidates
    .filter((row) => unranked(row) || !stillFresh(row))
    .sort((a, b) => age(a) - age(b))
    .slice(0, limit)
  let checked = 0
  let refreshed = 0
  let consecutiveMisses = 0
  // Every AniList request — the enrichment fetch and any series-root walk level — is spaced.
  const pace = createPacer(ANILIST_BACKGROUND_INTERVAL_MS)
  for (const row of stale) {
    checked++
    const didRefresh = await refreshFranchiseEnrichment(row.id, {
      anilistRequest: { maxRetries: 1, timeoutMs: 10_000 },
      pace,
    })
    if (didRefresh) {
      refreshed++
      consecutiveMisses = 0
    } else {
      consecutiveMisses++
      if (consecutiveMisses >= 3) break
    }
  }
  return { checked, refreshed }
}

/**
 * Nightly: re-read the TMDB recommendation list of every followed TV show whose list is older than
 * a day. The hourly TV refresh rewrites these shows' enrichment (so the 7-day staleness rule never
 * fires for them) but not their recommendation edges; before this job TV lists only refreshed when
 * a search or a show page happened to trigger it. One TMDB request per show, four at a time.
 */
export async function refreshSubscribedTmdbRecommendations(limit = 200): Promise<{
  checked: number
  refreshed: number
}> {
  if (!tmdbEnabled()) return { checked: 0, refreshed: 0 }
  const followed = await db
    .selectDistinct({ id: franchise.id })
    .from(subscriptions)
    .innerJoin(franchise, eq(franchise.id, subscriptions.franchiseId))
    .where(eq(franchise.source, 'tmdb'))
  if (followed.length === 0) return { checked: 0, refreshed: 0 }
  const ids = followed.map((row) => row.id)
  const listed = await db
    .select({ franchiseId: recommendationEdges.franchiseId, checkedAt: max(recommendationEdges.checkedAt) })
    .from(recommendationEdges)
    .where(inArray(recommendationEdges.franchiseId, ids))
    .groupBy(recommendationEdges.franchiseId)
  const freshAfter = Date.now() - TMDB_RECOMMENDATIONS_REFRESH_MS
  const fresh = new Set(listed.filter((row) => (row.checkedAt?.getTime() ?? 0) > freshAfter).map((row) => row.franchiseId))
  const due = ids.filter((id) => !fresh.has(id)).slice(0, limit)
  const results = await mapWithConcurrency(due, 4, async (id) => {
    try {
      return await refreshFranchiseEnrichment(id, { force: true, tmdbRequest: { maxRetries: 2, timeoutMs: 10_000 } })
    } catch (error) {
      console.warn(`TMDB recommendations refresh failed (${id}):`, 'diagnostic details redacted')
      return false
    }
  })
  return { checked: due.length, refreshed: results.filter(Boolean).length }
}

/** Resolve related ids and omit known excluded local/provider facts in batched reads. */
export async function resolveRelatedFranchiseIds(items: RelatedTitle[]): Promise<RelatedTitle[]> {
  if (items.length === 0) return items
  const aniIds = [...new Set(items.filter((item) => item.source === 'anilist').map((item) => item.externalId))]
  const tmdbIds = [...new Set(items.filter((item) => item.source === 'tmdb').map((item) => item.externalId))]
  const [aniRows, tmdbRows] = await Promise.all([
    aniIds.length
      ? db
          .select({ externalId: franchiseMember.mediaId, franchiseId: franchiseMember.franchiseId })
          .from(franchiseMember)
          .where(inArray(franchiseMember.mediaId, aniIds))
      : Promise.resolve([]),
    tmdbIds.length
      ? db
          .select({ externalId: franchise.externalId, franchiseId: franchise.id })
          .from(franchise)
          .where(and(eq(franchise.source, 'tmdb'), inArray(franchise.externalId, tmdbIds)))
      : Promise.resolve([]),
  ])
  const local = new Map<string, string>()
  for (const row of aniRows) local.set(`anilist:${row.externalId}`, row.franchiseId)
  for (const row of tmdbRows) if (row.externalId != null) local.set(`tmdb:${row.externalId}`, row.franchiseId)
  const [allowed, facts] = await Promise.all([
    consumerFranchiseIds([...new Set(local.values())]),
    db.select({ source: recommendationTargets.source, externalId: recommendationTargets.externalId,
      isAdult: recommendationTargets.isAdult, genres: recommendationTargets.genres })
      .from(recommendationTargets).where(or(
        aniIds.length ? and(eq(recommendationTargets.source, 'anilist'), inArray(recommendationTargets.externalId, aniIds)) : undefined,
        tmdbIds.length ? and(eq(recommendationTargets.source, 'tmdb'), inArray(recommendationTargets.externalId, tmdbIds)) : undefined,
      )),
  ])
  const excluded = new Set(facts.filter(isExcludedContent).map((row) => `${row.source}:${row.externalId}`))
  return items.filter((item) => {
    const key = `${item.source}:${item.externalId}`
    const id = local.get(key)
    return !excluded.has(key) && (!id || allowed.has(id))
  }).map((item) => ({
    ...item,
    franchiseId: local.get(`${item.source}:${item.externalId}`) ?? null,
  }))
}
