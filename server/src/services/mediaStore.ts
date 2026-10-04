import { eq, inArray } from 'drizzle-orm'
import { fetchByIds, type AniListRequestOptions } from '../anilist/client.js'
import type { AniListMedia } from '../anilist/types.js'
import { db } from '../db/index.js'
import { media, mediaRelations } from '../db/schema.js'
import type { ArtworkGallery, ArtworkImage, CatalogVideo, EpisodeMeta } from '../types/api.js'

export type MediaRow = typeof media.$inferInsert

/** Strip AniList's "Episode 12 - " prefix from a streaming-episode title. */
function cleanEpisodeTitle(raw: string): string {
  const m = raw.match(/^\s*Episode\s+\d+\s*[-–:]\s*(.+)$/i)
  return (m?.[1] ?? raw).trim()
}

/**
 * Best-effort per-episode metadata for an AniList media, from `streamingEpisodes`. AniList exposes
 * titles/thumbnails in a potentially reversed or sparse list. Only explicit episode numbers can
 * identify those entries; airingSchedule supplies dates. Sparse or empty for many titles — the client then falls
 * back to "Episode N", and the next-episode date badge uses the season-level `nextAiringAt`.
 */
export function aniListEpisodes(m: AniListMedia): EpisodeMeta[] {
  const se = m.streamingEpisodes ?? []
  // Streaming entries are often newest-first or incomplete. Their position is not an episode
  // number. Unnumbered titles cannot safely be attached to an episode.
  const byNumber = new Map<number, (typeof se)[number]>()
  for (const episode of se) {
    const match = /^\s*Episode\s+(\d+)\s*(?:[-–:]|$)/i.exec(episode.title ?? '')
    const number = match ? Number(match[1]) : 0
    if (number > 0 && number <= 10_000) byNumber.set(number, episode)
  }
  // AniList's airingSchedule gives the exact instant per episode (seconds). It is the only source
  // of per-episode dates for anime, so the list carries it even for episodes without a streaming
  // entry (no title/still yet) — the client then never has to invent a cadence.
  const airBy = new Map<number, number>()
  for (const n of m.airingSchedule?.nodes ?? []) {
    if (n.episode > 0 && n.airingAt > 0) airBy.set(n.episode, n.airingAt * 1000)
  }
  const count = Math.max(...byNumber.keys(), ...airBy.keys(), 0)
  const out: EpisodeMeta[] = []
  for (let i = 0; i < count; i++) {
    const e = byNumber.get(i + 1)
    out.push({
      number: i + 1,
      title: e?.title ? cleanEpisodeTitle(e.title) : null,
      airDate: airBy.get(i + 1) ?? null,
      overview: null,
      still: e?.thumbnail ?? null,
      runtime: m.duration ?? null,
    })
  }
  return out
}

/** Studio names for an AniList media, preferring animation studios. */
function aniListStudios(m: AniListMedia): string[] {
  const nodes = m.studios?.nodes ?? []
  const anim = nodes.filter((n) => n.isAnimationStudio).map((n) => n.name)
  const names = anim.length ? anim : nodes.map((n) => n.name)
  return names.slice(0, 3)
}

/** AniList supplies a provider id and thumbnail but no title/publish date/official flag. */
export function aniListVideos(m: AniListMedia): CatalogVideo[] {
  const trailer = m.trailer
  const id = trailer?.id?.trim()
  const site = trailer?.site?.trim().toLowerCase()
  if (!id || !site) return []
  const url =
    site === 'youtube'
      ? `https://www.youtube.com/watch?v=${encodeURIComponent(id)}`
      : site === 'dailymotion'
        ? `https://www.dailymotion.com/video/${encodeURIComponent(id)}`
        : null
  return [{
    id,
    site,
    kind: 'trailer',
    title: null,
    url,
    thumbnail: trailer?.thumbnail ?? null,
    official: null,
    language: null,
    country: null,
    publishedAt: null,
  }]
}

function aniListArtwork(m: AniListMedia): ArtworkGallery {
  const image = (url: string | null | undefined): ArtworkImage[] => url ? [{
    url,
    source: 'anilist',
    width: null,
    height: null,
    language: null,
    score: null,
  }] : []
  return {
    portraits: image(m.coverImage.extraLarge ?? m.coverImage.large),
    landscapes: image(m.bannerImage),
    logos: [],
  }
}

export function toMediaRow(m: AniListMedia): MediaRow {
  return {
    id: m.id,
    source: 'anilist',
    externalId: null,
    titleRomaji: m.title.romaji,
    titleEnglish: m.title.english,
    titleNative: m.title.native ?? null,
    synonyms: [...new Set((m.synonyms ?? []).map((value) => value.trim()).filter(Boolean))].slice(0, 30),
    format: m.format,
    status: m.status,
    episodes: m.episodes,
    cover: m.coverImage.extraLarge ?? m.coverImage.large ?? null,
    // Never put portrait art in the landscape slot; an honest null lets clients choose layout.
    banner: m.bannerImage ?? null,
    artwork: aniListArtwork(m),
    description: m.description,
    genres: m.genres ?? [],
    studios: aniListStudios(m),
    episodesList: aniListEpisodes(m),
    videos: aniListVideos(m),
    nextAiringEpisode: m.nextAiringEpisode,
    seasonYear: m.seasonYear,
    season: m.season,
    popularity: m.popularity,
    trending: m.trending,
    fetchedAt: new Date(),
  }
}

/**
 * Upsert prepared media rows (any source). `setLastAired` lets the TMDB path own lastAiredAt
 * via the upsert; the AniList path must NOT set it — there lastAiredAt belongs to
 * fetchLastAired (airingSchedules), which runs after the upsert.
 */
export async function upsertMediaRows(rows: MediaRow[], opts: { setLastAired?: boolean } = {}): Promise<void> {
  if (rows.length === 0) return
  // Postgres refuses an ON CONFLICT DO UPDATE that would touch the same row twice in one
  // statement ("cannot affect row a second time"), so each id may appear only once per batch.
  // Duplicates are ordinary input here, not a caller bug: fetchTrending paginates, and AniList's
  // TRENDING_DESC ordering can shift between page requests, so one media can land on two pages.
  // Last occurrence wins — a later page/BFS frontier carries the fresher payload.
  const byId = new Map<MediaRow['id'], MediaRow>()
  for (const r of rows) byId.set(r.id, r)
  await db
    .insert(media)
    .values([...byId.values()])
    .onConflictDoUpdate({
      target: media.id,
      set: {
        source: sqlExcluded('source'),
        externalId: sqlExcluded('external_id'),
        titleRomaji: sqlExcluded('title_romaji'),
        titleEnglish: sqlExcluded('title_english'),
        titleNative: sqlExcluded('title_native'),
        synonyms: sqlExcluded('synonyms'),
        format: sqlExcluded('format'),
        status: sqlExcluded('status'),
        episodes: sqlExcluded('episodes'),
        cover: sqlExcluded('cover'),
        banner: sqlExcluded('banner'),
        artwork: sqlExcluded('artwork'),
        description: sqlExcluded('description'),
        genres: sqlExcluded('genres'),
        studios: sqlExcluded('studios'),
        episodesList: sqlExcluded('episodes_list'),
        videos: sqlExcluded('videos'),
        nextAiringEpisode: sqlExcluded('next_airing_episode'),
        seasonYear: sqlExcluded('season_year'),
        season: sqlExcluded('season'),
        popularity: sqlExcluded('popularity'),
        trending: sqlExcluded('trending'),
        ...(opts.setLastAired ? { lastAiredAt: sqlExcluded('last_aired_at') } : {}),
        fetchedAt: sqlExcluded('fetched_at'),
      },
    })
}

/** Upsert AniList media + their relation edges. */
export async function upsertMedia(items: AniListMedia[]): Promise<void> {
  if (items.length === 0) return
  await upsertMediaRows(items.map(toMediaRow))

  const edges = items.flatMap((m) =>
    (m.relations?.edges ?? [])
      .filter((e) => e.node.type === 'ANIME')
      .map((e) => ({ mediaId: m.id, relatedId: e.node.id, relationType: e.relationType })),
  )
  if (edges.length > 0) {
    await db.insert(mediaRelations).values(edges).onConflictDoNothing()
  }
}

export async function getMediaRows(ids: number[]): Promise<MediaRow[]> {
  if (ids.length === 0) return []
  return db.select().from(media).where(inArray(media.id, ids))
}

export async function getMediaRow(id: number): Promise<MediaRow | undefined> {
  const [row] = await db.select().from(media).where(eq(media.id, id)).limit(1)
  return row
}

/**
 * A batched MediaFetcher for graph expansion: fetches a whole BFS frontier from AniList in
 * one batched request (chunked internally), upserts the results in a single write, and
 * memoises across the expansion so overlapping components never re-fetch the same node.
 *
 * The memo stores per-id *promises*, registered synchronously before the network await, so
 * concurrent expansions (the parallel search path) that request the same id share one fetch
 * instead of racing to fetch it twice. Ids AniList omits resolve to `undefined` and are
 * cached as such, so a dead id is never re-requested either.
 */
export function makeAniListFetcher(
  options: { seed?: AniListMedia[]; request?: AniListRequestOptions } = {},
) {
  const memo = new Map<number, Promise<AniListMedia | undefined>>()
  // Search already paid for these complete Media payloads. Priming the BFS with them removes the
  // old, redundant first graph request and lets overlapping seeds share the same objects.
  for (const item of options.seed ?? []) memo.set(item.id, Promise.resolve(item))
  return async (ids: number[]): Promise<AniListMedia[]> => {
    const need = ids.filter((id) => !memo.has(id))
    if (need.length > 0) {
      const batch = fetchByIds(need, options.request).then(async (fetched) => {
        if (fetched.length > 0) await upsertMedia(fetched) // one batched write per frontier
        return fetched
      })
      // Register a promise for every requested id up front so concurrent callers dedupe.
      for (const id of need) {
        const p = batch.then((fetched) => fetched.find((m) => m.id === id))
        // Evict on failure so a transient AniList error doesn't permanently poison this id (or
        // overlapping expansions sharing this fetcher); the .catch also keeps the rejection handled.
        p.catch(() => memo.delete(id))
        memo.set(id, p)
      }
    }
    const resolved = await Promise.all(ids.map((id) => memo.get(id)!))
    return resolved.filter((m): m is AniListMedia => m !== undefined)
  }
}

// drizzle helper: reference the conflicting INSERT row's column (Postgres `excluded`).
import { sql } from 'drizzle-orm'
function sqlExcluded(col: string) {
  return sql.raw(`excluded.${col}`)
}
