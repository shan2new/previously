import { gql, searchMedia } from '../anilist/client.js'
import { findTvByTvdbId, searchTv } from '../tmdb/client.js'
import type { TmdbSearchResult } from '../tmdb/types.js'
import { mapWithConcurrency } from '../util/concurrency.js'
import { createPacer } from '../util/pacer.js'
import { fromAniListStatus, fromMalStatus, normalizeTitle, type AnimeEntry, type TvShow } from './plan.js'

// History import's upstream reads (IO; nothing is written here).
export const paceImportAniList = createPacer(3_000)

/** Why a list could not be read — said to the viewer in their words, never a status code. */
export class ImportSourceError extends Error {
  constructor(public readonly reason: 'not_found' | 'private' | 'unavailable') {
    super(reason)
  }
}

const LIST_QUERY = `query ($name: String, $chunk: Int) {
  MediaListCollection(userName: $name, type: ANIME, chunk: $chunk, perChunk: 500, forceSingleCompletedList: true) {
    hasNextChunk
    lists { isCustomList entries { mediaId status progress media { title { english romaji } } } }
  }
}`

interface ListChunk {
  MediaListCollection: {
    hasNextChunk: boolean
    lists: {
      isCustomList: boolean
      entries: { mediaId: number; status: string; progress: number | null; media: { title: { english: string | null; romaji: string | null } | null } | null }[]
    }[]
  } | null
}

/**
 * A PUBLIC AniList user's anime list, by name — no sign-in: AniList serves public lists to anyone.
 * Custom lists repeat entries the status lists already hold, so they are skipped; an entry is one
 * media (a season, a film), deduplicated by id.
 */
export async function fetchAniListEntries(username: string): Promise<AnimeEntry[]> {
  const out = new Map<number, AnimeEntry>()
  for (let chunk = 1; chunk <= 20; chunk++) {
    let data: ListChunk
    try {
      await paceImportAniList()
      data = await gql<ListChunk>(LIST_QUERY, { name: username, chunk }, { maxRetries: 2, timeoutMs: 15_000 })
    } catch (err) {
      const message = err instanceof Error ? err.message : ''
      if (/private user/i.test(message)) throw new ImportSourceError('private')
      if (/user not found|404/i.test(message)) throw new ImportSourceError('not_found')
      throw new ImportSourceError('unavailable')
    }
    const collection = data.MediaListCollection
    if (!collection) throw new ImportSourceError('not_found')
    for (const list of collection.lists) {
      if (list.isCustomList) continue
      for (const entry of list.entries) {
        const mapped = fromAniListStatus(entry.status)
        if (!mapped || out.has(entry.mediaId)) continue
        out.set(entry.mediaId, {
          mediaId: entry.mediaId,
          status: mapped.status,
          finished: mapped.finished,
          progress: Math.max(0, Math.floor(entry.progress ?? 0)),
          title: entry.media?.title?.english ?? entry.media?.title?.romaji ?? null,
        })
      }
    }
    if (!collection.hasNextChunk) break
  }
  return [...out.values()]
}

export interface MalRow {
  malId: number
  status: string
  watched: number
  title?: string | null
}

const MAL_QUERY = `query ($ids: [Int], $page: Int) {
  Page(page: $page, perPage: 50) { media(idMal_in: $ids, type: ANIME) { id idMal } }
}`

/**
 * A MyAnimeList export's rows as AniList entries: AniList records each media's MAL id (`idMal`),
 * so the mapping is a lookup, fifty at a time. A row with no AniList twin, or a status this app
 * has no word for, comes back in `unmatched` by title.
 */
export async function mapMalRows(rows: MalRow[]): Promise<{ entries: AnimeEntry[]; unmatched: string[] }> {
  const byMal = new Map<number, MalRow>()
  for (const row of rows) if (Number.isInteger(row.malId) && row.malId > 0 && !byMal.has(row.malId)) byMal.set(row.malId, row)
  const ids = [...byMal.keys()]
  const anilistOf = new Map<number, number>()
  for (let i = 0; i < ids.length; i += 50) {
    const chunk = ids.slice(i, i + 50)
    let data: { Page: { media: { id: number; idMal: number | null }[] } }
    try {
      await paceImportAniList()
      data = await gql(MAL_QUERY, { ids: chunk, page: 1 }, { maxRetries: 3, timeoutMs: 15_000 })
    } catch {
      throw new ImportSourceError('unavailable')
    }
    for (const media of data.Page.media) if (media.idMal != null) anilistOf.set(media.idMal, media.id)
  }
  const entries: AnimeEntry[] = []
  const unmatched: string[] = []
  for (const [malId, row] of byMal) {
    const mapped = fromMalStatus(row.status)
    const mediaId = anilistOf.get(malId)
    if (!mapped || mediaId == null) {
      unmatched.push(row.title?.trim() || `MyAnimeList #${malId}`)
      continue
    }
    entries.push({
      mediaId,
      status: mapped.status,
      finished: mapped.finished,
      progress: Math.max(0, Math.floor(Number.isFinite(row.watched) ? row.watched : 0)),
      title: row.title?.trim() || null,
    })
  }
  return { entries, unmatched }
}

/** A TV Time show, found on TMDB — and whether it is Japanese animation (AniList's, here). */
export interface ResolvedTvShow {
  show: TvShow
  tmdb: TmdbSearchResult | null
}

/**
 * TV Time's shows on TMDB: by TheTVDB id (`/find`), else by an exact title match — some exports
 * carry legacy TheTVDB ids TMDB does not know, and a fuzzy title match would import someone
 * else's show.
 */
export async function resolveTvShows(shows: TvShow[]): Promise<ResolvedTvShow[]> {
  return mapWithConcurrency(shows, 6, async (show): Promise<ResolvedTvShow> => {
    try {
      if (show.tvdbId != null) {
        const found = await findTvByTvdbId(show.tvdbId, { maxRetries: 1, timeoutMs: 8_000 })
        if (found) return { show, tmdb: found }
      }
      const wanted = normalizeTitle(show.title)
      if (!wanted) return { show, tmdb: null }
      const results = await searchTv(show.title.replace(/\(\d{4}\)\s*$/u, '').trim(), { limit: 8, maxRetries: 1, timeoutMs: 8_000 })
      const year = show.title.match(/\((\d{4})\)\s*$/u)?.[1]
      const exact = results.filter((r) =>
        (normalizeTitle(r.name) === wanted || normalizeTitle(r.original_name ?? '') === wanted)
        && (!year || r.first_air_date?.startsWith(year)))
      // A remake can have the very same name. Search order is not identity evidence.
      return { show, tmdb: exact.length === 1 ? exact[0]! : null }
    } catch {
      throw new ImportSourceError('unavailable')
    }
  })
}

/** The AniList media whose title IS `title` (exact, normalised): a TV Time anime's way in. */
export async function findAnimeByTitle(title: string): Promise<number | null> {
  const wanted = normalizeTitle(title)
  if (!wanted) return null
  try {
    await paceImportAniList()
    const results = await searchMedia(title, { limit: 8, maxRetries: 1, timeoutMs: 8_000 })
    const tv = results.filter((m) => m.format === 'TV' || m.format === 'TV_SHORT' || m.format === 'ONA')
    const exact = tv.filter((m) =>
      [m.title?.english, m.title?.romaji, ...(m.synonyms ?? [])].some((t) => t && normalizeTitle(t) === wanted))
    return exact.length === 1 ? exact[0]!.id : null
  } catch {
    throw new ImportSourceError('unavailable')
  }
}
