// Raw TMDB v3 wire shapes (only the fields we consume).

export type TmdbShowStatus =
  | 'Returning Series'
  | 'Ended'
  | 'Canceled'
  | 'In Production'
  | 'Planned'
  | 'Pilot'
  | (string & {})

export interface TmdbSearchResult {
  id: number
  name: string
  original_name?: string | null
  genre_ids: number[]
  origin_country: string[]
  poster_path: string | null
  first_air_date: string | null
  popularity: number
  overview: string | null
}

export interface TmdbMovieSearchResult {
  id: number
  title: string
  original_title?: string | null
  genre_ids: number[]
  origin_country?: string[]
  original_language?: string | null
  poster_path: string | null
  release_date: string | null
  popularity: number
  overview: string | null
}

/** Movie detail fields needed by metadata-only trailer fallback. */
export interface TmdbMovie {
  id: number
  title: string
  original_title?: string | null
  overview?: string | null
  poster_path?: string | null
  backdrop_path?: string | null
  release_date?: string | null
  adult?: boolean
  genres?: { id: number; name: string }[]
  videos?: TmdbVideoResponse
  images?: TmdbImages
  alternative_titles?: { titles?: { iso_3166_1?: string; title: string }[] }
}

export interface TmdbImage {
  file_path: string
  width?: number | null
  height?: number | null
  iso_639_1?: string | null
  vote_average?: number | null
  vote_count?: number | null
}

export interface TmdbImages {
  posters?: TmdbImage[]
  backdrops?: TmdbImage[]
  logos?: TmdbImage[]
}

export interface TmdbWatchProvider {
  provider_id: number
  provider_name: string
  logo_path: string | null
  display_priority: number
}

export interface TmdbWatchProviderMarket {
  link?: string | null
  flatrate?: TmdbWatchProvider[]
  free?: TmdbWatchProvider[]
  ads?: TmdbWatchProvider[]
  rent?: TmdbWatchProvider[]
  buy?: TmdbWatchProvider[]
}

export interface TmdbWatchProviderResponse {
  id: number
  results?: Record<string, TmdbWatchProviderMarket>
}

export interface TmdbEpisodeStub {
  air_date: string | null
  episode_number: number
  season_number: number
}

export interface TmdbVideo {
  id: string
  key: string
  site: string
  type: string
  name: string | null
  official: boolean
  iso_639_1: string | null
  iso_3166_1: string | null
  published_at: string | null
}

export interface TmdbVideoResponse {
  results?: TmdbVideo[]
}

// Full episode from the season-detail endpoint (/tv/{id}/season/{n}).
export interface TmdbEpisode {
  episode_number: number
  name: string | null
  overview: string | null
  air_date: string | null
  still_path: string | null
  runtime: number | null
}

export interface TmdbSeasonDetail {
  id: number
  season_number: number
  episodes: TmdbEpisode[]
  videos?: TmdbVideoResponse
}

export interface TmdbSeason {
  id: number
  season_number: number
  episode_count: number
  air_date: string | null
  poster_path: string | null
  name: string
  overview: string | null
}

export interface TmdbShow {
  id: number
  name: string
  first_air_date?: string | null
  original_name?: string | null
  status: TmdbShowStatus
  number_of_seasons: number
  seasons: TmdbSeason[]
  next_episode_to_air: TmdbEpisodeStub | null
  last_episode_to_air: TmdbEpisodeStub | null
  genres: { id: number; name: string }[]
  networks?: { id: number; name: string }[]
  created_by?: { id: number; name: string; profile_path: string | null }[]
  adult?: boolean
  overview: string | null
  backdrop_path: string | null
  poster_path: string | null
  popularity: number
  origin_country: string[]
  videos?: TmdbVideoResponse
  images?: TmdbImages
  alternative_titles?: { results?: { iso_3166_1?: string; title: string }[] }
  content_ratings?: {
    results?: { iso_3166_1: string; rating: string; descriptors?: string[] }[]
  }
  aggregate_credits?: {
    cast?: {
      id: number
      name: string
      profile_path: string | null
      order?: number
      total_episode_count?: number
      roles?: { character: string; episode_count?: number }[]
    }[]
    crew?: {
      id: number
      name: string
      profile_path: string | null
      department?: string
      total_episode_count?: number
      jobs?: { job: string; episode_count?: number }[]
    }[]
  }
  keywords?: { results?: { id: number; name: string }[] }
  recommendations?: { results?: TmdbRecommendation[] }
}

/** One entry of `/tv/{id}` `recommendations` (page 1: up to 20). */
export interface TmdbRecommendation {
  id: number
  name: string
  poster_path: string | null
  backdrop_path: string | null
  first_air_date: string | null
  adult?: boolean
  media_type?: string
  // Already in the payload; the recommendation ranker's quality / taste / boundary facts.
  vote_average?: number | null
  vote_count?: number | null
  popularity?: number | null
  genre_ids?: number[]
  origin_country?: string[]
  original_language?: string | null
}
