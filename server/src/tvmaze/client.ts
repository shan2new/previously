import { abortableSleep, withTimeout } from '../util/abort.js'
import { createPacer } from '../util/pacer.js'

// TVmaze's public API (https://www.tvmaze.com/api): no key, CC BY-SA — the data may be used for any
// purpose with credit to TVmaze (the app credits it where it shows a broadcast time). At least 20
// calls per 10 seconds per IP; a 429 means wait and retry.

const BASE = 'https://api.tvmaze.com'
const TIMEOUT_MS = 10_000
const MAX_RETRIES = 3
/** 20 calls per 10 s is the floor TVmaze promises: stay under it with room to spare. */
const pace = createPacer(600)

export interface TvmazeShow {
  id: number
  name: string
  externals?: { thetvdb?: number | null; imdb?: string | null } | null
}

export interface TvmazeEpisode {
  season: number
  /** null for a special. */
  number: number | null
  /** "YYYY-MM-DD", the network's local date. */
  airdate: string
  /** "HH:MM" in the network's time zone; "" when the slot has no time (a streaming drop). */
  airtime: string
  /** ISO 8601 with offset. Noon UTC of the date when `airtime` is empty — not a time. */
  airstamp: string | null
}

async function tvmazeGet<T>(path: string, attempt = 0): Promise<T | null> {
  await pace()
  const res = await fetch(`${BASE}${path}`, {
    headers: { Accept: 'application/json', 'User-Agent': 'Previously/1.0 (TV tracker; +https://anime.cognipin.com)' },
    signal: withTimeout(undefined, TIMEOUT_MS),
  })
  if (res.status === 404) return null
  if (res.status === 429 || res.status >= 500) {
    if (attempt >= MAX_RETRIES) throw new Error(`TVmaze ${res.status}`)
    await abortableSleep(2 ** attempt * 2_000, undefined)
    return tvmazeGet<T>(path, attempt + 1)
  }
  if (!res.ok) throw new Error(`TVmaze ${res.status}`)
  return (await res.json()) as T
}

/** The TVmaze show for a TheTVDB or IMDb id (`/lookup/shows`), or null. */
export async function lookupShow(ids: { tvdbId: number | null; imdbId: string | null }): Promise<{ show: TvmazeShow; via: 'tvdb' | 'imdb' } | null> {
  if (ids.tvdbId != null) {
    const show = await tvmazeGet<TvmazeShow>(`/lookup/shows?thetvdb=${ids.tvdbId}`)
    if (show) return { show, via: 'tvdb' }
  }
  if (ids.imdbId != null) {
    const show = await tvmazeGet<TvmazeShow>(`/lookup/shows?imdb=${encodeURIComponent(ids.imdbId)}`)
    if (show) return { show, via: 'imdb' }
  }
  return null
}

/** Every regular episode of a show (specials excluded), oldest first. Empty for a show TVmaze dropped. */
export async function showEpisodes(showId: number): Promise<TvmazeEpisode[]> {
  return (await tvmazeGet<TvmazeEpisode[]>(`/shows/${showId}/episodes`)) ?? []
}
