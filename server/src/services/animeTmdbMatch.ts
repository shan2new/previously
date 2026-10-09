import {
  searchMovies,
  searchTv,
  type TmdbRequestOptions,
} from '../tmdb/client.js'
import type { TmdbMovieSearchResult, TmdbSearchResult } from '../tmdb/types.js'

const ANIMATION_GENRE_ID = 16

export type AnimeTmdbMediaType = 'tv' | 'movie'

export interface AnimeTmdbCandidate {
  id: number
  adult?: boolean
  title: string
  originalTitle: string | null
  year: number | null
  popularity: number
  genreIds: number[]
  originCountries: string[]
  originalLanguage?: string | null
}

export interface AnimeTmdbTarget {
  mediaType: AnimeTmdbMediaType
  externalId: number
}

function normalizedTitle(value: string): string {
  return value
    .normalize('NFKD')
    .toLocaleLowerCase('en')
    .replace(/[^a-z0-9]+/g, ' ')
    .trim()
}

function titleTokens(value: string): Set<string> {
  return new Set(normalizedTitle(value).split(' ').filter((token) => token.length > 1))
}

function similarity(a: string, b: string): number {
  const left = titleTokens(a)
  const right = titleTokens(b)
  if (left.size === 0 || right.size === 0) return 0
  let overlap = 0
  for (const token of left) if (right.has(token)) overlap++
  return overlap / Math.max(left.size, right.size)
}

function yearFromDate(value: string | null | undefined): number | null {
  const match = /^(\d{4})-/.exec(value ?? '')
  return match ? Number(match[1]) : null
}

function animeCandidate(candidate: AnimeTmdbCandidate): boolean {
  return (
    candidate.genreIds.includes(ANIMATION_GENRE_ID) &&
    (candidate.originCountries.includes('JP') || candidate.originalLanguage === 'ja')
  )
}

/**
 * Pick a conservative TMDB match for an AniList-owned title. Search rank is never treated as
 * identity: the candidate must be Japanese animation, agree strongly on title, and corroborate a
 * known premiere year. This is shared by watch availability and trailer enrichment.
 */
export function pickAnimeTmdbCandidate(
  candidates: AnimeTmdbCandidate[],
  aliases: string[],
  year: number | null,
): AnimeTmdbCandidate | null {
  const names = [...new Set(aliases.map(normalizedTitle).filter(Boolean))]
  if (names.length === 0) return null

  const scored = candidates.flatMap((candidate) => {
    if (candidate.adult === true || !animeCandidate(candidate)) return []
    const candidateNames = [candidate.title, candidate.originalTitle ?? ''].map(normalizedTitle).filter(Boolean)
    const exact = candidateNames.some((name) => names.includes(name))
    const bestSimilarity = Math.max(
      0,
      ...candidateNames.flatMap((candidateName) => names.map((name) => similarity(candidateName, name))),
    )
    if (!exact && bestSimilarity < 0.72) return []

    if (year != null && candidate.year == null) return []
    const yearDistance = year != null && candidate.year != null ? Math.abs(year - candidate.year) : null
    if (yearDistance != null && yearDistance > 2) return []
    const yearScore = yearDistance == null ? 0 : yearDistance === 0 ? 20 : yearDistance === 1 ? 10 : 4
    const titleScore = exact ? 100 : Math.round(bestSimilarity * 70)
    return [{ candidate, score: titleScore + yearScore + Math.log10(Math.max(1, candidate.popularity)) }]
  })

  scored.sort((a, b) => b.score - a.score || a.candidate.id - b.candidate.id)
  return scored[0]?.candidate ?? null
}

function tvCandidate(hit: TmdbSearchResult): AnimeTmdbCandidate {
  return {
    id: hit.id,
    adult: hit.adult,
    title: hit.name,
    originalTitle: hit.original_name ?? null,
    year: yearFromDate(hit.first_air_date),
    popularity: hit.popularity ?? 0,
    genreIds: hit.genre_ids ?? [],
    originCountries: hit.origin_country ?? [],
  }
}

function movieCandidate(hit: TmdbMovieSearchResult): AnimeTmdbCandidate {
  return {
    id: hit.id,
    adult: hit.adult,
    title: hit.title,
    originalTitle: hit.original_title ?? null,
    year: yearFromDate(hit.release_date),
    popularity: hit.popularity ?? 0,
    genreIds: hit.genre_ids ?? [],
    originCountries: hit.origin_country ?? [],
    originalLanguage: hit.original_language,
  }
}

/** Resolve at most two title aliases; a miss is honest and never falls back to the top search hit. */
export async function resolveAnimeTmdbTarget(
  input: {
    title: string
    aliases: string[]
    year: number | null
    mediaType: AnimeTmdbMediaType
  },
  request: TmdbRequestOptions = {},
): Promise<AnimeTmdbTarget | null> {
  const aliases = [input.title, ...input.aliases]
  const queries = [...new Set(aliases.map((value) => value.trim()).filter(Boolean))].slice(0, 2)
  for (const query of queries) {
    const candidates = input.mediaType === 'movie'
      ? (await searchMovies(query, { ...request, limit: 10 })).map(movieCandidate)
      : (await searchTv(query, { ...request, limit: 10 })).map(tvCandidate)
    const picked = pickAnimeTmdbCandidate(candidates, aliases, input.year)
    if (picked) return { mediaType: input.mediaType, externalId: picked.id }
  }
  return null
}
