import { and, eq, inArray } from 'drizzle-orm'
import { db } from '../db/index.js'
import { franchise, franchiseMember } from '../db/schema.js'
import type { GroupedPart } from '../grouping/llm.js'
import { persistFranchises, type GroupOutcome } from '../grouping/service.js'
import { upsertMediaRows } from '../services/mediaStore.js'
import { resolveUpcomingWithCatalog } from '../services/catalogUpcoming.js'
import { enqueueFranchiseEnrichment } from '../services/catalogEnrichment.js'
import { upsertCatalogLink } from '../services/catalogLinks.js'
import { syncRecommendationEdges } from '../services/recommendationEdges.js'
import type { CatalogVideo, EpisodeMeta, FranchiseUpcoming } from '../types/api.js'
import { getSeason, getShow, tmdbEnabled, type TmdbRequestOptions } from './client.js'
import {
  imageUrl,
  includedSeasons,
  isJapaneseAnimationShow,
  tmdbEpisodes,
  tmdbFranchiseEnrichment,
  tmdbArtwork,
  tmdbRecommendationTargets,
  tmdbSeasonToMediaRow,
  tmdbShowUpcoming,
  tmdbShowToGroupingResult,
  tmdbVideos,
} from './mapping.js'
import type { TmdbSeason } from './types.js'
import { ContentExcludedError, consumerFranchiseIds, isExcludedContent } from '../services/consumerContent.js'

/**
 * One-show, one-request refresh for the exact-search path. Unlike refreshTvShow this intentionally
 * skips every season-detail call: Search needs the next-season fact now, not full episode metadata.
 */
export async function refreshTvUpcomingFact(
  franchiseId: string,
  request: TmdbRequestOptions = {},
): Promise<FranchiseUpcoming | null> {
  const [row] = await db
    .select({
      source: franchise.source,
      externalId: franchise.externalId,
      upcoming: franchise.upcoming,
      enrichment: franchise.enrichment,
    })
    .from(franchise)
    .where(eq(franchise.id, franchiseId))
    .limit(1)
  if (!row || row.source !== 'tmdb' || row.externalId == null || !tmdbEnabled()) return row?.upcoming ?? null

  // The route also calls this when a summary has no featured video. A present enrichment row is
  // the durable "catalogue checked" marker: some shows genuinely publish no trailer, and those
  // exact searches must not pay the same provider request forever. News refresh runs separately.
  if (row.upcoming && row.enrichment) return row.upcoming

  const show = await getShow(row.externalId, request)
  if (!show) return row.upcoming ?? null
  const catalogUpcoming = tmdbShowUpcoming(show)
  const resolved = resolveUpcomingWithCatalog(row.upcoming, catalogUpcoming)
  const basic = tmdbFranchiseEnrichment(show)
  // The lightweight Search request carries show-level videos but not credits/ratings. Preserve a
  // previously deep-enriched row while refreshing just the fields this response can authoritatively
  // improve; otherwise persist the basic row so the very same Search response can expose a trailer.
  const enrichment = row.enrichment?.level === 'full'
    ? {
        ...row.enrichment,
        isAdult: basic.isAdult ?? row.enrichment.isAdult,
        videos: basic.videos,
      }
    : basic
  await db
    .update(franchise)
    .set({
      enrichment,
      upcoming: resolved,
      updatedAt: new Date(),
    })
    .where(eq(franchise.id, franchiseId))
  return resolved
}

/**
 * Best-effort per-episode metadata for every included season, keyed by season_number. A failed
 * season fetch degrades to no episodes rather than failing the whole materialization.
 */
interface SeasonMetadata {
  episodes: EpisodeMeta[]
  videos: CatalogVideo[]
}

async function fetchSeasonMetadata(
  showId: number,
  seasons: TmdbSeason[],
  request: TmdbRequestOptions = {},
): Promise<Map<number, SeasonMetadata>> {
  const entries = await Promise.all(
    seasons.map(async (s): Promise<[number, SeasonMetadata]> => {
      try {
        const detail = await getSeason(showId, s.season_number, request)
        return [s.season_number, {
          episodes: detail ? tmdbEpisodes(detail.episodes) : [],
          videos: tmdbVideos(detail?.videos?.results),
        }]
      } catch {
        return [s.season_number, { episodes: [], videos: [] }]
      }
    }),
  )
  return new Map(entries)
}

/**
 * Idempotently materialize a TMDB show as a franchise (seasons as members). Deterministic —
 * no relation graph, no LLM. Returns null when the show doesn't exist or has no usable
 * seasons (we never create empty franchises). Safe to call concurrently: the partial unique
 * index on franchise (source, external_id) plus deterministic member ids make a lost create
 * race resolve to the winner inside persistFranchises.
 */
export async function ensureTvFranchise(
  showId: number,
  opts: { hydrateEpisodes?: boolean; request?: TmdbRequestOptions; consumerOnly?: boolean } = {},
): Promise<GroupOutcome | null> {
  const [existing] = await db
    .select({ id: franchise.id })
    .from(franchise)
    .where(and(eq(franchise.source, 'tmdb'), eq(franchise.externalId, showId)))
    .limit(1)
  if (existing) {
    if (opts.consumerOnly && !(await consumerFranchiseIds([existing.id])).has(existing.id)) throw new ContentExcludedError()
    await upsertCatalogLink({
      franchiseId: existing.id,
      provider: 'tmdb',
      mediaType: 'tv',
      externalId: showId,
      matchMethod: 'catalogue_owner',
      confidence: 1,
    })
    return { franchiseId: existing.id, created: false, attached: 0 }
  }

  const show = await getShow(showId, { ...opts.request, enrichment: opts.hydrateEpisodes !== false })
  if (!show) return null
  if (opts.consumerOnly && isExcludedContent({ adult: show.adult, genres: show.genres?.map((genre) => genre.name) })) throw new ContentExcludedError()
  if (includedSeasons(show).length === 0) return null
  // Source boundary, enforced at the one place that CREATES a TMDB franchise rather than in each
  // caller. Checked against the full show payload (authoritative) and before the per-season
  // episode fetches, so a suppressed show costs one request instead of N.
  if (isJapaneseAnimationShow(show)) return null

  const now = Date.now()
  const seasons = includedSeasons(show)
  // Search only needs a real franchise id + summary. Fetching every season's episode list here
  // made one cold result fan out into dozens of provider calls. The hourly TV refresh hydrates
  // those lists later; explicit scripts and sync retain the full default behavior.
  const metadataBySeason =
    opts.hydrateEpisodes === false ? new Map<number, SeasonMetadata>() : await fetchSeasonMetadata(showId, seasons, opts.request)
  let rows
  try {
    rows = seasons.map((s) => {
      const metadata = metadataBySeason.get(s.season_number)
      return tmdbSeasonToMediaRow(show, s, now, metadata?.episodes ?? [], metadata?.videos ?? [])
    })
  } catch (err) {
    // Season id outside the offset-safe range — skip the show rather than corrupt the keyspace.
    console.warn(`ensureTvFranchise: skipping show ${showId}:`, 'diagnostic details redacted')
    return null
  }
  await upsertMediaRows(rows, { setLastAired: true })

  const result = tmdbShowToGroupingResult(show)
  const parts = result.franchises[0]!.parts
  const seasonOne = parts.find((p) => p.sequence === 1 && p.partKind === 'season')
  const outcome = await persistFranchises({
    result,
    seedId: parts[0]!.id,
    allIds: parts.map((p) => p.id),
    metaFor: () => ({
      title: show.name,
      primaryMediaId: seasonOne?.id ?? parts[0]!.id,
      cover: imageUrl(show.poster_path, 'w780'),
      banner: imageUrl(show.backdrop_path, 'w1280'),
      artwork: tmdbArtwork(show),
      description: show.overview || null,
      genres: (show.genres ?? []).map((g) => g.name).slice(0, 6),
      groupingSource: 'tmdb',
      groupingModel: null,
      confidence: 1,
      source: 'tmdb',
      externalId: show.id,
      upcoming: tmdbShowUpcoming(show, now),
      enrichment: tmdbFranchiseEnrichment(show, now),
    }),
    // One show = one franchise, so every raced member points at the same winner.
    onRaced: async (raced) => ({ franchiseId: raced[0]!.franchiseId, created: false, attached: 0 }),
  })
  await upsertCatalogLink({
    franchiseId: outcome.franchiseId,
    provider: 'tmdb',
    mediaType: 'tv',
    externalId: show.id,
    matchMethod: 'catalogue_owner',
    confidence: 1,
  })
  // The deep payload's enrichment is born "full" and fresh, so the queued refresh below skips it
  // for a week: write the recommendation list from this same payload now, or a show someone just
  // added would recommend nothing until then.
  if (outcome.created && show.recommendations) {
    const reco = tmdbRecommendationTargets(show)
    await syncRecommendationEdges(outcome.franchiseId, reco.edges, reco.targets)
  }
  enqueueFranchiseEnrichment(outcome.franchiseId)
  return outcome
}

/**
 * Refresh a TV franchise from its show payload: season statuses, episode counts, next/last
 * airing. New seasons in the payload become new members, so this doubles as TV's
 * attachNewSeasons — no separate daily job.
 */
export async function refreshTvShow(
  franchiseId: string,
  showId: number,
): Promise<{ refreshed: boolean; attached: number }> {
  const show = await getShow(showId, { enrichment: true })
  if (!show || includedSeasons(show).length === 0) return { refreshed: false, attached: 0 }

  const now = Date.now()
  const seasons = includedSeasons(show)
  const metadataBySeason = await fetchSeasonMetadata(showId, seasons)
  let rows
  try {
    rows = seasons.map((s) => {
      const metadata = metadataBySeason.get(s.season_number)
      return tmdbSeasonToMediaRow(show, s, now, metadata?.episodes ?? [], metadata?.videos ?? [])
    })
  } catch (err) {
    console.warn(`refreshTvShow: skipping show ${showId}:`, 'diagnostic details redacted')
    return { refreshed: false, attached: 0 }
  }
  await upsertMediaRows(rows, { setLastAired: true })

  const attached = await attachTvMembers(franchiseId, tmdbShowToGroupingResult(show).franchises[0]!.parts)
  const catalogUpcoming = tmdbShowUpcoming(show, now)
  const [current] = await db.select({ upcoming: franchise.upcoming }).from(franchise).where(eq(franchise.id, franchiseId)).limit(1)
  const resolved = resolveUpcomingWithCatalog(current?.upcoming, catalogUpcoming)
  await db
    .update(franchise)
    .set({
      title: show.name,
      cover: imageUrl(show.poster_path, 'w780'),
      banner: imageUrl(show.backdrop_path, 'w1280'),
      artwork: tmdbArtwork(show),
      description: show.overview || null,
      genres: (show.genres ?? []).map((genre) => genre.name).slice(0, 6),
      enrichment: tmdbFranchiseEnrichment(show, now),
      upcoming: resolved,
      updatedAt: new Date(),
    })
    .where(eq(franchise.id, franchiseId))
  await upsertCatalogLink({
    franchiseId,
    provider: 'tmdb',
    mediaType: 'tv',
    externalId: show.id,
    matchMethod: 'catalogue_owner',
    confidence: 1,
  })
  return { refreshed: true, attached }
}

/**
 * TV sibling of grouping's attachNewMembers: sequences come straight from TMDB season numbers
 * (never route TV through attachNewMembers — its per-kind next-sequence counter would drift
 * when seasons arrive out of order).
 */
async function attachTvMembers(franchiseId: string, parts: GroupedPart[]): Promise<number> {
  const existing = await db
    .select({ mediaId: franchiseMember.mediaId })
    .from(franchiseMember)
    .where(eq(franchiseMember.franchiseId, franchiseId))
  const already = new Set(existing.map((r) => r.mediaId))
  const fresh = parts.filter((p) => !already.has(p.id))
  if (fresh.length === 0) return 0

  await db
    .insert(franchiseMember)
    .values(fresh.map((p) => ({
      mediaId: p.id,
      franchiseId,
      partKind: p.partKind,
      sequence: p.sequence,
      watchOrder: p.watchOrder ?? p.sequence,
      relationship: p.relationship ?? null,
      optional: p.optional ?? false,
      label: p.label,
    })))
    .onConflictDoNothing()
  await db.update(franchise).set({ updatedAt: new Date() }).where(inArray(franchise.id, [franchiseId]))
  return fresh.length
}
