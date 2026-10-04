import { env } from '../env.js'
import { abortReason, abortableSleep, isAbortError, withTimeout } from '../util/abort.js'
import type {
  TmdbMovie,
  TmdbMovieSearchResult,
  TmdbSeasonDetail,
  TmdbSearchResult,
  TmdbShow,
  TmdbVideoResponse,
  TmdbWatchProviderResponse,
} from './types.js'

const BASE = 'https://api.themoviedb.org/3'

/** TV support is opt-in: without a token the whole TMDB path is disabled (anime-only mode). */
export function tmdbEnabled(): boolean {
  return !!env.TMDB_ACCESS_TOKEN
}

/** Full movie detail for metadata-only anime trailer fallback. Null on a missing/merged title. */
export async function getMovie(movieId: number, options: TmdbRequestOptions = {}): Promise<TmdbMovie | null> {
  try {
    return await tmdbGet<TmdbMovie>(
      `/movie/${movieId}`,
      {
        language: 'en-US',
        include_video_language: 'en,null',
        include_image_language: 'en,null',
        append_to_response: 'videos,images,alternative_titles',
      },
      options,
    )
  } catch (err) {
    if ((err as Error).message === 'TMDB 404') return null
    throw err
  }
}

const DEFAULT_MAX_RETRIES = 4
const DEFAULT_TIMEOUT_MS = 10_000

export interface TmdbRequestOptions {
  signal?: AbortSignal
  maxRetries?: number
  timeoutMs?: number
}

export type TmdbShowRequestOptions = TmdbRequestOptions & { enrichment?: boolean }

/**
 * GET a TMDB v3 path with bounded retry — same contract as the AniList `gql()` client:
 * honor `Retry-After` on 429/5xx (else exponential backoff), retry network errors, throw
 * after retries are spent. TMDB allows ~40 req/s per IP, so retries here are rare.
 */
async function tmdbGet<T>(
  path: string,
  params: Record<string, string> = {},
  options: TmdbRequestOptions = {},
  attempt = 0,
): Promise<T> {
  const maxRetries = options.maxRetries ?? DEFAULT_MAX_RETRIES
  const url = new URL(`${BASE}${path}`)
  for (const [k, v] of Object.entries(params)) url.searchParams.set(k, v)
  try {
    const res = await fetch(url, {
      headers: { Authorization: `Bearer ${env.TMDB_ACCESS_TOKEN}`, Accept: 'application/json' },
      signal: withTimeout(options.signal, options.timeoutMs ?? DEFAULT_TIMEOUT_MS),
    })
    if (res.status === 429 || res.status >= 500) {
      if (attempt >= maxRetries) throw new Error(`TMDB ${res.status}`)
      const retryAfter = Number(res.headers.get('Retry-After'))
      const waitMs = Number.isFinite(retryAfter) && retryAfter > 0 ? retryAfter * 1000 : 2 ** attempt * 1000
      await abortableSleep(waitMs, options.signal)
      return tmdbGet<T>(path, params, options, attempt + 1)
    }
    if (!res.ok) throw new Error(`TMDB ${res.status}`)
    return (await res.json()) as T
  } catch (err) {
    if (options.signal?.aborted) throw abortReason(options.signal)
    if (attempt < maxRetries && (err instanceof TypeError || isAbortError(err))) {
      await abortableSleep(2 ** attempt * 1000, options.signal)
      return tmdbGet<T>(path, params, options, attempt + 1)
    }
    throw err
  }
}

/** Search TV shows by name (TMDB does its own fuzzy matching). */
export async function searchTv(
  query: string,
  options: TmdbRequestOptions & { limit?: number } = {},
): Promise<TmdbSearchResult[]> {
  const json = await tmdbGet<{ results?: TmdbSearchResult[] }>('/search/tv', {
    query,
    include_adult: 'false',
    page: '1',
  }, options)
  return (json.results ?? []).slice(0, Math.max(1, Math.min(options.limit ?? 20, 20)))
}

/**
 * The TMDB show for a TheTVDB SERIES id (`/find`), or null — how a TV Time export's shows are
 * found (its ids are TheTVDB's). Only `tv_results` count: TheTVDB's series and episode id spaces
 * overlap, so for a series id TMDB does not know `/find` can answer with an unrelated EPISODE.
 */
export async function findTvByTvdbId(
  tvdbId: number,
  options: TmdbRequestOptions = {},
): Promise<TmdbSearchResult | null> {
  const json = await tmdbGet<{ tv_results?: TmdbSearchResult[] }>(
    `/find/${tvdbId}`,
    { external_source: 'tvdb_id' },
    options,
  )
  return json.tv_results?.[0] ?? null
}

/** Search movies by name (used to resolve anime franchises whose primary work is a film). */
export async function searchMovies(
  query: string,
  options: TmdbRequestOptions & { limit?: number } = {},
): Promise<TmdbMovieSearchResult[]> {
  const json = await tmdbGet<{ results?: TmdbMovieSearchResult[] }>('/search/movie', {
    query,
    include_adult: 'false',
    page: '1',
  }, options)
  return (json.results ?? []).slice(0, Math.max(1, Math.min(options.limit ?? 20, 20)))
}

/** Full show detail (status, seasons, next/last episode). Null on 404 (deleted/merged show). */
export async function getShow(showId: number, options: TmdbShowRequestOptions = {}): Promise<TmdbShow | null> {
  const { enrichment = false, ...request } = options
  try {
    return await tmdbGet<TmdbShow>(
      `/tv/${showId}`,
      {
        language: 'en-US',
        include_video_language: 'en,null',
        include_image_language: 'en,null',
        // Videos are cheap and useful on the very first materialization. Credits/ratings/
        // recommendations are appended only by background/full refreshes.
        append_to_response: enrichment
          ? 'videos,content_ratings,aggregate_credits,keywords,recommendations,images,alternative_titles'
          : 'videos,alternative_titles',
      },
      request,
    )
  } catch (err) {
    if ((err as Error).message === 'TMDB 404') return null
    throw err
  }
}

/** Season detail with the full per-episode list. Null on 404 (season absent/unpublished). */
export async function getSeason(
  showId: number,
  seasonNumber: number,
  options: TmdbRequestOptions = {},
): Promise<TmdbSeasonDetail | null> {
  try {
    return await tmdbGet<TmdbSeasonDetail>(
      `/tv/${showId}/season/${seasonNumber}`,
      { language: 'en-US', include_video_language: 'en,null', append_to_response: 'videos' },
      options,
    )
  } catch (err) {
    if ((err as Error).message === 'TMDB 404') return null
    throw err
  }
}

/** Season-scoped videos without downloading the (occasionally enormous) episode list. */
export async function getSeasonVideos(
  showId: number,
  seasonNumber: number,
  options: TmdbRequestOptions = {},
): Promise<TmdbVideoResponse | null> {
  try {
    return await tmdbGet<TmdbVideoResponse>(`/tv/${showId}/season/${seasonNumber}/videos`, {
      language: 'en-US',
      include_video_language: 'en,null',
    }, options)
  } catch (err) {
    if ((err as Error).message === 'TMDB 404') return null
    throw err
  }
}

/** Country-keyed JustWatch availability for one TMDB TV series. */
export async function getTvWatchProviders(
  showId: number,
  options: TmdbRequestOptions = {},
): Promise<TmdbWatchProviderResponse> {
  return tmdbGet<TmdbWatchProviderResponse>(`/tv/${showId}/watch/providers`, {}, options)
}

/** Country-keyed JustWatch availability for one TMDB movie. */
export async function getMovieWatchProviders(
  movieId: number,
  options: TmdbRequestOptions = {},
): Promise<TmdbWatchProviderResponse> {
  return tmdbGet<TmdbWatchProviderResponse>(`/movie/${movieId}/watch/providers`, {}, options)
}

/** Daily-trending TV, paged (20/page) up to `limit`. */
export async function getTrendingTv(limit: number, options: TmdbRequestOptions = {}): Promise<TmdbSearchResult[]> {
  const out: TmdbSearchResult[] = []
  const pages = Math.max(1, Math.ceil(limit / 20))
  for (let page = 1; page <= pages && out.length < limit; page++) {
    const json = await tmdbGet<{ results?: TmdbSearchResult[] }>(
      '/trending/tv/day',
      { page: String(page) },
      options,
    )
    const results = json.results ?? []
    out.push(...results)
    if (results.length === 0) break
  }
  return out.slice(0, limit)
}
