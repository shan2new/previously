import { eq, sql } from 'drizzle-orm'
import { db } from '../db/index.js'
import { franchise, franchiseMember, media, subscriptions } from '../db/schema.js'
import {
  getMovie,
  getSeason,
  getShow,
  tmdbEnabled,
  type TmdbRequestOptions,
} from '../tmdb/client.js'
import { tmdbArtwork, tmdbEpisodes, tmdbFranchiseEnrichment, tmdbMovieArtwork, tmdbVideos } from '../tmdb/mapping.js'
import type { TmdbSeason, TmdbSeasonDetail, TmdbShow, TmdbVideo } from '../tmdb/types.js'
import type { ArtworkGallery, CatalogVideo, EpisodeMeta, FranchiseEnrichment } from '../types/api.js'
import { BoundedTaskQueue } from '../util/taskQueue.js'
import { rankArtwork, rankLogos } from '../util/artwork.js'
import {
  resolveAnimeTmdbTarget,
  type AnimeTmdbMediaType,
  type AnimeTmdbTarget,
} from './animeTmdbMatch.js'
import { getCatalogLink, upsertCatalogLink } from './catalogLinks.js'
import { isExcludedContent } from './consumerContent.js'

const D = 86_400_000
const VIDEO_TTL_MS = 7 * D
const EMPTY_TTL_MS = D
const BACKGROUND_INTERVAL_MS = 150
const ANIME_TMDB_METADATA_VERSION = 1
const TV_FORMATS = new Set(['TV', 'TV_SHORT', 'ONA'])

const queue = new BoundedTaskQueue(2, 48, (key, error) => {
  console.warn(`anime video fallback failed (${key}):`, 'diagnostic details redacted')
})

interface AnimeIdentityPart {
  id: number
  titleEnglish: string | null
  titleRomaji: string | null
  titleNative: string | null
  synonyms: string[] | null
  format: string | null
  year: number | null
  sequence: number
  totalEpisodes: number | null
  episodes: EpisodeMeta[] | null
  artwork: ArtworkGallery | null
  videos: CatalogVideo[] | null
}

export interface AnimeVideoFallbackResult {
  checked: boolean
  matched: boolean
  updated: boolean
  videos: number
}

export interface AnimePartSeasonMatch {
  mediaId: number
  seasonNumber: number
  confidence: number
}

function fallbackFresh(value: FranchiseEnrichment | null | undefined, nowMs = Date.now()): boolean {
  const state = value?.videoFallback
  // `videoFallback` originally cached trailers only. Treat those rows as stale once so every
  // existing match passes through the wider metadata path and gains TMDB artwork as well.
  if (!state || state.metadataVersion !== ANIME_TMDB_METADATA_VERSION) return false
  const checked = Date.parse(state.checkedAt)
  const ttl = (value?.videos?.length ?? 0) > 0 ? VIDEO_TTL_MS : EMPTY_TTL_MS
  return Number.isFinite(checked) && checked > nowMs - ttl
}

function pickIdentityPart(parts: AnimeIdentityPart[], primaryMediaId: number | null): AnimeIdentityPart | undefined {
  const declared = parts.find((part) => part.id === primaryMediaId)
  return (
    (declared && TV_FORMATS.has(declared.format ?? '') ? declared : undefined)
    ?? parts.find((part) => TV_FORMATS.has(part.format ?? ''))
    ?? (declared?.format === 'MOVIE' ? declared : undefined)
    ?? parts.find((part) => part.format === 'MOVIE')
    ?? parts.slice().sort((a, b) => a.sequence - b.sequence)[0]
  )
}

/**
 * Fetch only the season video endpoints most likely to carry the current campaign. Show-level
 * videos are always included separately; this list is capped so long-running anime stay cheap.
 */
export function animeTrailerSeasonNumbers(show: TmdbShow, animeYears: number[], limit = 3): number[] {
  const seasons = (show.seasons ?? []).filter((season) => season.season_number > 0)
  const available = new Set(seasons.map((season) => season.season_number))
  const out: number[] = []
  const add = (value: number | null | undefined) => {
    if (value != null && available.has(value) && !out.includes(value) && out.length < limit) out.push(value)
  }

  add(show.next_episode_to_air?.season_number)
  add(Math.max(0, ...seasons.map((season) => season.season_number)))
  add(show.last_episode_to_air?.season_number)

  // If current/last/latest all collapse to one season, use dated seasons nearest the newest
  // AniList installments before falling back to simple reverse season order.
  const newestAnimeYear = Math.max(0, ...animeYears)
  for (const season of seasons
    .filter((item) => !!item.air_date)
    .sort((a, b) => {
      const ay = Number(a.air_date?.slice(0, 4)) || 0
      const by = Number(b.air_date?.slice(0, 4)) || 0
      return Math.abs(ay - newestAnimeYear) - Math.abs(by - newestAnimeYear) || b.season_number - a.season_number
    })) add(season.season_number)
  for (const season of seasons.slice().sort((a, b) => b.season_number - a.season_number)) add(season.season_number)
  return out
}

/** Preserve AniList's deep metadata while replacing only the metadata-only trailer cache. */
export function mergeAnimeVideoFallback(
  current: FranchiseEnrichment | null | undefined,
  genres: string[],
  videos: CatalogVideo[],
  target: AnimeTmdbTarget | null,
  checkedAt: string,
  attemptedMediaType?: AnimeTmdbMediaType,
  fallback?: FranchiseEnrichment | null,
): FranchiseEnrichment {
  const base: FranchiseEnrichment = current ?? {
    level: 'basic',
    themes: [...new Set(genres)].slice(0, 10),
    isAdult: null,
    contentRatings: [],
    people: { creators: [], directors: [], cast: [] },
    related: [],
    videos: [],
    checkedAt,
  }
  const mediaType: AnimeTmdbMediaType =
    target?.mediaType ?? attemptedMediaType ?? current?.videoFallback?.mediaType ?? 'tv'
  return {
    ...base,
    level: base.level === 'full' || fallback?.level === 'full' ? 'full' : 'basic',
    themes: base.level === 'full' && base.themes.length
      ? base.themes
      : (fallback?.themes.length ? fallback.themes : base.themes),
    isAdult: base.isAdult ?? fallback?.isAdult ?? null,
    contentRatings: base.contentRatings.length ? base.contentRatings : (fallback?.contentRatings ?? []),
    people: {
      creators: base.people.creators.length ? base.people.creators : (fallback?.people.creators ?? []),
      directors: base.people.directors.length ? base.people.directors : (fallback?.people.directors ?? []),
      cast: base.people.cast.length ? base.people.cast : (fallback?.people.cast ?? []),
    },
    related: base.related.length ? base.related : (fallback?.related ?? []),
    videos,
    videoFallback: {
      source: 'tmdb',
      mediaType,
      externalId: target?.externalId ?? null,
      status: target ? 'matched' : 'unmatched',
      checkedAt,
      metadataVersion: ANIME_TMDB_METADATA_VERSION,
    },
    checkedAt,
  }
}

export function mergeArtwork(
  primary: ArtworkGallery | null | undefined,
  fallback: ArtworkGallery | null | undefined,
): ArtworkGallery {
  const merge = (a: ArtworkGallery['portraits'] = [], b: ArtworkGallery['portraits'] = [], preserveTextless = true) => {
    return rankArtwork([...a, ...b], 6, preserveTextless)
  }
  return {
    portraits: merge(primary?.portraits, fallback?.portraits),
    landscapes: merge(primary?.landscapes, fallback?.landscapes),
    logos: rankLogos([...(primary?.logos ?? []), ...(fallback?.logos ?? [])], 6),
  }
}

/**
 * Match only when year and episode count corroborate one another. Sequence alone is never enough:
 * split cours and specials routinely make AniList part numbers disagree with TMDB season numbers.
 */
export function matchAnimePartsToTmdbSeasons(
  parts: Pick<AnimeIdentityPart, 'id' | 'format' | 'year' | 'sequence' | 'totalEpisodes'>[],
  seasons: TmdbSeason[],
): AnimePartSeasonMatch[] {
  const candidates = seasons.filter((season) => season.season_number > 0)
  const used = new Set<number>()
  const out: AnimePartSeasonMatch[] = []
  for (const part of parts
    .filter((item) => TV_FORMATS.has(item.format ?? ''))
    .slice()
    .sort((a, b) => (a.year ?? 9999) - (b.year ?? 9999) || a.sequence - b.sequence)) {
    const scored = candidates.flatMap((season) => {
      if (used.has(season.season_number)) return []
      const seasonYear = Number(season.air_date?.slice(0, 4)) || null
      const yearDistance = part.year != null && seasonYear != null ? Math.abs(part.year - seasonYear) : null
      if (yearDistance != null && yearDistance > 1) return []
      const countKnown = (part.totalEpisodes ?? 0) > 0 && season.episode_count > 0
      const countExact = countKnown && part.totalEpisodes === season.episode_count
      let confidence = 0
      if (countExact && yearDistance === 0) confidence = 0.99
      else if (countExact && yearDistance === 1) confidence = 0.94
      else if (!countKnown && yearDistance === 0 && part.sequence === season.season_number) confidence = 0.92
      if (confidence < 0.92) return []
      return [{ season, confidence }]
    }).sort((a, b) => b.confidence - a.confidence || a.season.season_number - b.season.season_number)
    const best = scored[0]
    if (!best || (scored[1] && scored[1].confidence === best.confidence)) continue
    used.add(best.season.season_number)
    out.push({ mediaId: part.id, seasonNumber: best.season.season_number, confidence: best.confidence })
  }
  return out
}

/** Overlay descriptive TMDB fields while keeping AniList's exact broadcast instants authoritative. */
export function overlayAnimeEpisodes(existing: EpisodeMeta[], fallback: EpisodeMeta[]): EpisodeMeta[] {
  const byNumber = new Map(existing.map((episode) => [episode.number, episode]))
  const tmdb = new Map(fallback.map((episode) => [episode.number, episode]))
  const numbers = [...new Set([...existing, ...fallback].map((episode) => episode.number))].sort((a, b) => a - b)
  return numbers.map((number) => {
    const current = byNumber.get(number)
    const extra = tmdb.get(number)
    return {
      number,
      title: current?.title ?? extra?.title ?? null,
      airDate: current?.airDate ?? null,
      overview: current?.overview ?? extra?.overview ?? null,
      still: current?.still ?? extra?.still ?? null,
      runtime: current?.runtime ?? extra?.runtime ?? null,
    }
  })
}

/**
 * Enrich one AniList franchise from its conservatively matched TMDB twin without materializing a
 * second franchise or changing AniList identity. Failures throw and therefore never become durable
 * "unmatched" facts.
 */
export async function refreshAnimeVideoFallback(
  franchiseId: string,
  options: { force?: boolean; request?: TmdbRequestOptions } = {},
): Promise<AnimeVideoFallbackResult> {
  if (!tmdbEnabled()) return { checked: false, matched: false, updated: false, videos: 0 }
  const [row] = await db
    .select({
      source: franchise.source,
      title: franchise.title,
      primaryMediaId: franchise.primaryMediaId,
      genres: franchise.genres,
      enrichment: franchise.enrichment,
      artwork: franchise.artwork,
    })
    .from(franchise)
    .where(eq(franchise.id, franchiseId))
    .limit(1)
  if (!row || row.source !== 'anilist') return { checked: false, matched: false, updated: false, videos: 0 }
  if (!options.force && fallbackFresh(row.enrichment)) {
    return {
      checked: false,
      matched: row.enrichment?.videoFallback?.status === 'matched',
      updated: false,
      videos: row.enrichment?.videos?.length ?? 0,
    }
  }

  const parts = await db
    .select({
      id: media.id,
      titleEnglish: media.titleEnglish,
      titleRomaji: media.titleRomaji,
      titleNative: media.titleNative,
      synonyms: media.synonyms,
      format: media.format,
      year: media.seasonYear,
      sequence: franchiseMember.sequence,
      totalEpisodes: media.episodes,
      episodes: media.episodesList,
      artwork: media.artwork,
      videos: media.videos,
    })
    .from(franchiseMember)
    .innerJoin(media, eq(media.id, franchiseMember.mediaId))
    .where(eq(franchiseMember.franchiseId, franchiseId))
  const primary = pickIdentityPart(parts, row.primaryMediaId)
  if (!primary) return { checked: false, matched: false, updated: false, videos: 0 }
  const mediaType: AnimeTmdbMediaType = primary.format === 'MOVIE' ? 'movie' : 'tv'
  const aliases = [
    primary.titleEnglish,
    primary.titleRomaji,
    primary.titleNative,
    ...(primary.synonyms ?? []),
    ...parts.flatMap((part) => [part.titleEnglish, part.titleRomaji, part.titleNative, ...(part.synonyms ?? [])]),
  ].filter((value): value is string => !!value)
  const previous = row.enrichment?.videoFallback
  const durable = await getCatalogLink(franchiseId, 'tmdb')
  let target: AnimeTmdbTarget | null =
    durable?.status === 'matched' && durable.externalId != null && durable.mediaType === mediaType
      ? { mediaType, externalId: durable.externalId }
      : previous?.status === 'matched' && previous.externalId != null && previous.mediaType === mediaType
        ? { mediaType, externalId: previous.externalId }
        : await resolveAnimeTmdbTarget({ title: row.title, aliases, year: primary.year, mediaType }, options.request)

  let rawVideos: TmdbVideo[] = []
  let fallbackEnrichment: FranchiseEnrichment | null = null
  let fallbackArtwork: ArtworkGallery | null = null
  let partMappings: AnimePartSeasonMatch[] = []
  if (target?.mediaType === 'movie') {
    const movie = await getMovie(target.externalId, options.request)
    if (movie && !isExcludedContent({ adult: movie.adult, genres: movie.genres?.map((genre) => genre.name) })) {
      rawVideos = movie.videos?.results ?? []
      fallbackArtwork = tmdbMovieArtwork(movie)
    } else {
      target = null
    }
  } else if (target) {
    const show = await getShow(target.externalId, { ...options.request, enrichment: true })
    if (show && !isExcludedContent({ adult: show.adult, genres: show.genres.map((genre) => genre.name) })) {
      fallbackEnrichment = tmdbFranchiseEnrichment(show)
      fallbackArtwork = tmdbArtwork(show)
      partMappings = matchAnimePartsToTmdbSeasons(parts, show.seasons ?? [])
      const seasonNumbers = animeTrailerSeasonNumbers(
        show,
        parts.map((part) => part.year).filter((year): year is number => year != null),
      )
      const needed = [...new Set([...seasonNumbers, ...partMappings.map((match) => match.seasonNumber)])].slice(0, 12)
      const seasons = await Promise.all(needed.map((season) => getSeason(target!.externalId, season, options.request)))
      rawVideos = [
        ...(show.videos?.results ?? []),
        ...seasons.flatMap((season) => season?.videos?.results ?? []),
      ]

      const detailBySeason = new Map(
        seasons
          .filter((season): season is TmdbSeasonDetail => season != null)
          .map((season) => [season.season_number, season]),
      )
      for (const match of partMappings) {
        const part = parts.find((item) => item.id === match.mediaId)
        const season = detailBySeason.get(match.seasonNumber)
        const seasonStub = show.seasons.find((item) => item.season_number === match.seasonNumber)
        if (!part || !season || !seasonStub) continue
        await db.update(media).set({
          episodesList: overlayAnimeEpisodes(part.episodes ?? [], tmdbEpisodes(season.episodes)),
          artwork: mergeArtwork(part.artwork, tmdbArtwork(show, seasonStub)),
        }).where(eq(media.id, part.id))
      }
    } else {
      target = null
    }
  }

  const videos = target ? tmdbVideos(rawVideos) : []
  const checkedAt = new Date().toISOString()
  const enrichment = mergeAnimeVideoFallback(
    row.enrichment,
    row.genres ?? [],
    videos,
    target,
    checkedAt,
    mediaType,
    fallbackEnrichment,
  )
  const patch = {
    level: enrichment.level,
    themes: enrichment.themes,
    isAdult: enrichment.isAdult,
    contentRatings: enrichment.contentRatings,
    people: enrichment.people,
    related: enrichment.related,
    videos: enrichment.videos,
    videoFallback: enrichment.videoFallback,
    checkedAt: enrichment.checkedAt,
  }
  // `cover` / `banner` are the legacy best-pair fields shipped to the current iOS app. Keeping the
  // TMDB images only in the new gallery leaves the billboard rendering AniList's 460x639 cover even
  // after a successful match. Promote the twin's canonical art here; the gallery retains both
  // providers, and franchise.source remains `anilist`.
  const mergedArtwork = fallbackArtwork ? mergeArtwork(row.artwork, fallbackArtwork) : row.artwork
  const enrichedCover = mergedArtwork?.portraits[0]?.url ?? null
  const enrichedBanner = mergedArtwork?.landscapes[0]?.url ?? null
  // Merge only the fallback fields into the value present AT UPDATE TIME. The AniList deep
  // enricher can run concurrently from Search, and neither writer may clobber the other's facts.
  await db.update(franchise).set({
    enrichment: sql`coalesce(${franchise.enrichment}, ${JSON.stringify(enrichment)}::jsonb) || ${JSON.stringify(patch)}::jsonb`,
    ...(enrichedCover ? { cover: enrichedCover } : {}),
    ...(enrichedBanner ? { banner: enrichedBanner } : {}),
    ...(mergedArtwork ? { artwork: mergedArtwork } : {}),
    updatedAt: new Date(),
  }).where(eq(franchise.id, franchiseId))
  await upsertCatalogLink({
    franchiseId,
    provider: 'tmdb',
    mediaType,
    externalId: target?.externalId ?? null,
    status: target ? 'matched' : 'unmatched',
    matchMethod: target ? 'title_year_animation' : 'title_year_no_match',
    confidence: target ? 0.9 : null,
    evidence: { aliases: aliases.slice(0, 10), year: primary.year, partMappings },
  })
  // No recommendation edges here: an anime's ranked list is AniList's own (catalogEnrichment writes
  // it with the ranker's facts). The TMDB twin's `related` only fills the show page's "More like
  // this" when AniList has none; re-writing edges from it clobbered the ranked list every night.
  return { checked: true, matched: target != null, updated: true, videos: videos.length }
}

/** Single-flight stale-while-revalidate hook for Search, Detail, and Subscribe. */
export function enqueueAnimeVideoFallback(franchiseId: string): void {
  queue.enqueue(`franchise:${franchiseId}`, async () => {
    await refreshAnimeVideoFallback(franchiseId, { request: { maxRetries: 1, timeoutMs: 4_000 } })
  })
}

/** Refresh followed anime even when no user visits Search or Detail. */
export async function refreshSubscribedAnimeVideoFallback(
  limit = 25,
  options: { force?: boolean } = {},
): Promise<{ checked: number; matched: number; videos: number }> {
  if (!tmdbEnabled()) return { checked: 0, matched: 0, videos: 0 }
  const candidates = await db
    .selectDistinct({ id: franchise.id, enrichment: franchise.enrichment })
    .from(subscriptions)
    .innerJoin(franchise, eq(franchise.id, subscriptions.franchiseId))
    .where(eq(franchise.source, 'anilist'))
    .limit(100)
  const stale = candidates
    .filter((row) => options.force || !fallbackFresh(row.enrichment))
    .slice(0, limit)
  let checked = 0
  let matched = 0
  let videos = 0
  let consecutiveFailures = 0
  for (const row of stale) {
    try {
      const result = await refreshAnimeVideoFallback(row.id, {
        force: options.force,
        request: { maxRetries: 1, timeoutMs: 8_000 },
      })
      if (result.checked) checked++
      if (result.matched) matched++
      videos += result.videos
      consecutiveFailures = 0
    } catch (error) {
      consecutiveFailures++
      console.warn(`anime video fallback failed (${row.id}):`, 'diagnostic details redacted')
      if (consecutiveFailures >= 3) break
    }
    await new Promise((resolve) => setTimeout(resolve, BACKGROUND_INTERVAL_MS))
  }
  return { checked, matched, videos }
}

/**
 * Catalogue-wide metadata repair, with followed franchises first. TMDB supplies more than video:
 * alternative artwork, episode descriptions/stills, ratings, people, themes and recommendations.
 * The old subscribed-only sweep left newly searched anime permanently sparse unless someone first
 * followed it; this bounded pass makes Search materialization itself enough to enter the repair
 * queue while preserving the same conservative identity matcher.
 */
export async function refreshAnimeMetadataFallback(
  limit = 40,
  options: { force?: boolean } = {},
): Promise<{ checked: number; matched: number; videos: number }> {
  if (!tmdbEnabled()) return { checked: 0, matched: 0, videos: 0 }
  const [candidates, followed] = await Promise.all([
    db
      .select({ id: franchise.id, enrichment: franchise.enrichment })
      .from(franchise)
      .where(eq(franchise.source, 'anilist'))
      .limit(2_000),
    db
      .selectDistinct({ id: subscriptions.franchiseId })
      .from(subscriptions),
  ])
  const followedIds = new Set(followed.map((row) => row.id))
  const checkedAt = (value: FranchiseEnrichment | null | undefined) =>
    Date.parse(value?.videoFallback?.checkedAt ?? '') || 0
  const due = candidates
    .filter((row) => options.force || !fallbackFresh(row.enrichment))
    .sort((a, b) => Number(followedIds.has(b.id)) - Number(followedIds.has(a.id)) || checkedAt(a.enrichment) - checkedAt(b.enrichment))
    .slice(0, Math.max(0, limit))

  let checked = 0
  let matched = 0
  let videos = 0
  let consecutiveFailures = 0
  for (const row of due) {
    try {
      const result = await refreshAnimeVideoFallback(row.id, {
        force: options.force,
        request: { maxRetries: 1, timeoutMs: 8_000 },
      })
      if (result.checked) checked++
      if (result.matched) matched++
      videos += result.videos
      consecutiveFailures = 0
    } catch (error) {
      consecutiveFailures++
      console.warn(`anime metadata fallback failed (${row.id}):`, 'diagnostic details redacted')
      if (consecutiveFailures >= 3) break
    }
    await new Promise((resolve) => setTimeout(resolve, BACKGROUND_INTERVAL_MS))
  }
  return { checked, matched, videos }
}
