import { and, eq, inArray, sql, type SQL } from 'drizzle-orm'
import { db } from '../db/index.js'
import { franchise, franchiseMember, media, subscriptions } from '../db/schema.js'
import {
  buildGenreTiles,
  encodeGenreCursor,
  GENRES,
  MAX_GENRE_OFFSET,
  POSTERS_PER_GENRE,
  rankGenreTiles,
  scopeSources,
  sourceGenreNames,
  type GenreDef,
} from '../discover/genres.js'
import type {
  DiscoverGenre,
  DiscoverGenrePage,
  DiscoverGenresResponse,
  MediaSource,
  WatchStatus,
} from '../types/api.js'
import { getSummaries } from './franchiseView.js'
import { consumerFranchiseConditions } from './consumerContent.js'

// Discover's genre browse (brief §17, server spec §10.2). IO: reads the catalogue and the viewer's
// subscriptions; writes nothing.
//
// A franchise QUALIFIES for a genre when it has at least one member (the same inner join the
// trending ranking uses, so a tile's count is exactly what its page can list), it is not adult
// (`enrichment.isAdult` is not true, and it does not carry AniList's Hentai genre — the rule
// recommendationRank.ts already uses for "adult"), it is in the requested catalogue, and its stored
// `genres` hold one of the key's names for ITS OWN catalogue (see discover/genres.ts).

/** Tile lists are user-independent and change with the hourly sync; 30 minutes per scope. */
const GENRE_LIST_TTL_MS = 30 * 60_000
/**
 * Ranked candidates read per genre for its collage. More than the four posters it shows, so a
 * franchise without a portrait does not leave the tile a poster short.
 */
const POSTER_CANDIDATES = POSTERS_PER_GENRE + 2

const WATCH_STATUSES: ReadonlySet<string> = new Set<WatchStatus>(['watching', 'completed', 'planned', 'paused', 'dropped'])

/**
 * `franchise.genres` as a jsonb ARRAY whatever is stored: a SQL NULL or a stray JSON scalar would make
 * `jsonb_array_elements_text` throw, and one bad row must not take the whole tab down.
 */
const genresArray = sql`(case when jsonb_typeof(${franchise.genres}) = 'array' then ${franchise.genres} else '[]'::jsonb end)`

/** The non-genre half of the qualifying rule (the member join is the caller's). */
export function baseConditions(source: MediaSource | null): SQL[] {
  const conditions = consumerFranchiseConditions()
  if (source) conditions.push(sql`${franchise.source} = ${source}`)
  return conditions
}

/** Genre membership for one key, per catalogue; null when the scope has no names for it. */
function genreMembership(def: GenreDef, source: MediaSource | null): SQL | null {
  const clauses = scopeSources(source).flatMap((s) => {
    const names = sourceGenreNames(def, s)
    if (names.length === 0) return []
    const list = sql.join(names.map((name) => sql`${name}`), sql`, `)
    return [sql`(${franchise.source} = ${s} and exists (
      select 1 from jsonb_array_elements_text(${genresArray}) as discover_genre(value)
      where discover_genre.value in (${list})
    ))`]
  })
  return clauses.length > 0 ? sql`(${sql.join(clauses, sql` or `)})` : null
}

// ---------- The genre list ----------

interface GenreCatalogue {
  generatedAt: number
  /** Every genre in scope, uncut (the page header reads a genre below the tile threshold too). */
  tiles: DiscoverGenre[]
}

const catalogueCache = new Map<string, { expiresAt: number; value: GenreCatalogue }>()
const catalogueInFlight = new Map<string, Promise<GenreCatalogue>>()

const scopeKey = (source: MediaSource | null): string => source ?? 'all'

/**
 * Counts and collage candidates for every genre in scope, in ONE query: each qualifying franchise's
 * trending signal is aggregated once, joined to the (key, catalogue, name) vocabulary, and ranked
 * per key with the trending order (spec §2.5: trending, popularity, recency; id last so ties are
 * deterministic).
 */
async function loadGenreCatalogue(source: MediaSource | null): Promise<GenreCatalogue> {
  const vocabulary = GENRES.flatMap((def) =>
    scopeSources(source).flatMap((s) =>
      sourceGenreNames(def, s).map((name) => sql`(${def.key}::text, ${s}::text, ${name}::text)`),
    ),
  )
  const rows = vocabulary.length === 0 ? [] : await db.execute<{ key: string; id: string; total: number; rn: number }>(sql`
    with genre_names(key, source, name) as (values ${sql.join(vocabulary, sql`, `)}),
    qualifying as (
      select ${franchise.id} as id,
             ${franchise.source} as source,
             ${genresArray} as genres,
             max(${media.trending}) as trending,
             max(${media.popularity}) as popularity,
             ${franchise.updatedAt} as updated_at
      from ${franchise}
      join ${franchiseMember} on ${franchiseMember.franchiseId} = ${franchise.id}
      join ${media} on ${media.id} = ${franchiseMember.mediaId}
      where ${sql.join(baseConditions(source), sql` and `)}
      group by ${franchise.id}
    ),
    matches as (
      select distinct genre_names.key, qualifying.id, qualifying.trending, qualifying.popularity, qualifying.updated_at
      from qualifying
      cross join lateral jsonb_array_elements_text(qualifying.genres) as franchise_genre(value)
      join genre_names on genre_names.source = qualifying.source and genre_names.name = franchise_genre.value
    ),
    numbered as (
      select key, id,
             (count(*) over (partition by key))::int as total,
             (row_number() over (
               partition by key
               order by trending desc nulls last, popularity desc nulls last, updated_at desc, id asc
             ))::int as rn
      from matches
    )
    select key, id::text as id, total, rn from numbered where rn <= ${POSTER_CANDIDATES} order by key, rn
  `)

  const totals = new Map<string, number>()
  const rankedIds = new Map<string, string[]>()
  for (const row of rows) {
    totals.set(row.key, Number(row.total))
    const ids = rankedIds.get(row.key) ?? []
    ids.push(row.id)
    rankedIds.set(row.key, ids)
  }
  const candidateIds = [...new Set([...rankedIds.values()].flat())]
  const summaries = await getSummaries(candidateIds)
  const portraitOf = new Map(summaries.map((summary) => [summary.id, summary.images.portrait]))
  return { generatedAt: Date.now(), tiles: buildGenreTiles(source, totals, rankedIds, portraitOf) }
}

/**
 * The scope's genre catalogue: cached per scope, refreshed single-flight (concurrent callers share one
 * load), and a stale copy is served when a refresh fails rather than failing the tab.
 */
async function genreCatalogue(source: MediaSource | null): Promise<GenreCatalogue> {
  const key = scopeKey(source)
  const cached = catalogueCache.get(key)
  if (cached && cached.expiresAt > Date.now()) return cached.value
  const pending = catalogueInFlight.get(key)
  if (pending) return pending

  const load = (async () => {
    try {
      const value = await loadGenreCatalogue(source)
      catalogueCache.set(key, { expiresAt: Date.now() + GENRE_LIST_TTL_MS, value })
      return value
    } catch (error) {
      if (cached) {
        console.warn(`discover genres refresh failed (${key}), serving stale:`, 'diagnostic details redacted')
        return cached.value
      }
      throw error
    } finally {
      catalogueInFlight.delete(key)
    }
  })()
  catalogueInFlight.set(key, load)
  return load
}

/** GET /discover/genres: the tiles for a scope (null = All). */
export async function getDiscoverGenres(source: MediaSource | null): Promise<DiscoverGenresResponse> {
  const catalogue = await genreCatalogue(source)
  return { source, genres: rankGenreTiles(catalogue.tiles), generatedAt: catalogue.generatedAt }
}

// ---------- The genre page ----------

export interface GenrePageOptions {
  source: MediaSource | null
  /** 1…50 (the route validates). */
  limit: number
  /** From the decoded cursor; 0 for the first page. */
  offset: number
}

/**
 * GET /discover/genres/:key: one page of the genre, ranked by trending, then popularity, then id.
 * Owned titles are MARKED (`status` from the viewer's subscriptions), never excluded.
 */
export async function getDiscoverGenrePage(
  userId: string,
  def: GenreDef,
  options: GenrePageOptions,
): Promise<DiscoverGenrePage> {
  const { source, limit, offset } = options
  // The header is the tile the viewer tapped (same count and collage), from the scope's cache.
  const catalogue = await genreCatalogue(source)
  const genre: DiscoverGenre = catalogue.tiles.find((tile) => tile.key === def.key)
    ?? { key: def.key, name: def.name, count: 0, posters: [] }

  const membership = genreMembership(def, source)
  // A key with no names in this scope (Romance on TV, Crime on anime) is a real genre with nothing
  // in it here: an empty page, not a 404.
  if (!membership || offset >= MAX_GENRE_OFFSET) return { genre, franchises: [], nextCursor: null }

  const rows = await db
    .select({ id: franchise.id })
    .from(franchise)
    .innerJoin(franchiseMember, eq(franchiseMember.franchiseId, franchise.id))
    .innerJoin(media, eq(media.id, franchiseMember.mediaId))
    .where(and(...baseConditions(source), membership))
    .groupBy(franchise.id)
    .orderBy(
      sql`max(${media.trending}) desc nulls last`,
      sql`max(${media.popularity}) desc nulls last`,
      sql`${franchise.id} asc`,
    )
    // One extra row says whether another page exists without a count query.
    .limit(limit + 1)
    .offset(offset)

  const hasMore = rows.length > limit
  const ids = rows.slice(0, limit).map((row) => row.id)
  const franchises = await getSummaries(ids)

  if (franchises.length > 0) {
    const owned = await db
      .select({ franchiseId: subscriptions.franchiseId, status: subscriptions.status })
      .from(subscriptions)
      .where(and(eq(subscriptions.userId, userId), inArray(subscriptions.franchiseId, ids)))
    const statusById = new Map(owned.map((row) => [row.franchiseId, row.status]))
    for (const summary of franchises) {
      const status = statusById.get(summary.id)
      if (status && WATCH_STATUSES.has(status)) summary.status = status as WatchStatus
    }
  }

  const nextOffset = offset + limit
  return {
    genre,
    franchises,
    nextCursor: hasMore && nextOffset <= MAX_GENRE_OFFSET ? encodeGenreCursor(nextOffset) : null,
  }
}
