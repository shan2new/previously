import { and, eq, inArray } from 'drizzle-orm'
import { fetchRootNodes, type AniListRequestOptions } from '../anilist/client.js'
import type { AniListRootNode } from '../anilist/types.js'
import { db } from '../db/index.js'
import { franchise, franchiseMember, media, mediaRelations } from '../db/schema.js'
import type { ArtworkSet, MediaSource } from '../types/api.js'
import type { RecommendationTargetFacts } from './recommendationRank.js'

// A recommendation names a SERIES. AniList's community picks often point at a later season
// ("My Hero Academia Season 4", "Tower of God Season 2"), so each AniList target is walked up its
// PREQUEL/PARENT chain to the series root — the first season — which is what the recommendation is
// keyed, titled and materialised by, and what two seeds recommending different seasons merge on.
// The walk is local-first (a materialised franchise, then the cached media graph) and only asks
// AniList for what the catalogue has never seen, one batched request per level.

const SERIES = new Set(['TV', 'TV_SHORT', 'ONA'])
const SEASON_RANK: Record<string, number> = { WINTER: 0, SPRING: 1, SUMMER: 2, FALL: 3 }
const UP = new Set(['PREQUEL', 'PARENT'])
const MAX_LEVELS = 8
const MAX_NODES_PER_TARGET = 40

interface OrderFacts {
  id: number
  format: string | null
  season: string | null
  seasonYear: number | null
}

/**
 * The series root's order: the earliest SERIES-format entry wins over any film/OVA before it, then
 * by air date, then id — the spike's rule, also used for a materialised franchise, so a title keeps
 * its key when it is materialised.
 */
export function rootOrder(a: OrderFacts, b: OrderFacts): number {
  const series = (x: OrderFacts) => (x.format && SERIES.has(x.format) ? 0 : 1)
  return series(a) - series(b) ||
    (a.seasonYear ?? 9999) - (b.seasonYear ?? 9999) ||
    (SEASON_RANK[a.season ?? ''] ?? 9) - (SEASON_RANK[b.season ?? ''] ?? 9) ||
    a.id - b.id
}

/** A materialised franchise, reduced to what a recommendation shows and keys on. */
export interface FranchiseSeries {
  franchiseId: string
  source: MediaSource
  externalId: number | null
  title: string
  genres: string[]
  rootId: number
  rootYear: number | null
  rootFormat: string | null
  rootEpisodes: number | null
  images: ArtworkSet
  memberIds: number[]
  /** Episodes across the main parts (seasons / ONAs), when any part states a count. */
  episodes: number | null
  airing: boolean
  announced: boolean
}

/** Series facts for materialised franchises, keyed by franchise id (two indexed reads). */
export async function loadFranchiseSeries(franchiseIds: string[]): Promise<Map<string, FranchiseSeries>> {
  const ids = [...new Set(franchiseIds)]
  const out = new Map<string, FranchiseSeries>()
  if (ids.length === 0) return out
  const [rows, members] = await Promise.all([
    db
      .select({
        id: franchise.id,
        source: franchise.source,
        externalId: franchise.externalId,
        title: franchise.title,
        genres: franchise.genres,
        cover: franchise.cover,
        banner: franchise.banner,
      })
      .from(franchise)
      .where(inArray(franchise.id, ids)),
    db
      .select({
        franchiseId: franchiseMember.franchiseId,
        id: franchiseMember.mediaId,
        partKind: franchiseMember.partKind,
        format: media.format,
        status: media.status,
        season: media.season,
        seasonYear: media.seasonYear,
        episodes: media.episodes,
        cover: media.cover,
        banner: media.banner,
      })
      .from(franchiseMember)
      .innerJoin(media, eq(media.id, franchiseMember.mediaId))
      .where(inArray(franchiseMember.franchiseId, ids)),
  ])
  const byFranchise = new Map<string, typeof members>()
  for (const m of members) {
    const list = byFranchise.get(m.franchiseId) ?? []
    list.push(m)
    byFranchise.set(m.franchiseId, list)
  }
  for (const row of rows) {
    const parts = (byFranchise.get(row.id) ?? []).slice().sort(rootOrder)
    const root = parts[0]
    if (!root) continue
    const main = parts.filter((p) => p.partKind === 'season' || p.partKind === 'ona')
    const counted = main.filter((p) => p.episodes != null)
    out.set(row.id, {
      franchiseId: row.id,
      source: row.source === 'tmdb' ? 'tmdb' : 'anilist',
      externalId: row.externalId,
      title: row.title,
      genres: row.genres ?? [],
      rootId: root.id,
      rootYear: root.seasonYear,
      rootFormat: root.format,
      rootEpisodes: root.episodes,
      images: { portrait: row.cover || root.cover || null, landscape: row.banner || root.banner || null },
      memberIds: parts.map((p) => p.id),
      episodes: counted.length ? counted.reduce((sum, p) => sum + (p.episodes ?? 0), 0) : null,
      // On air means a SEASON (or ONA run) is releasing — a special or a film tie-in airing does
      // not make the show "Airing now" (review i5, F7: Kaiju No. 8 was tagged AIRING while only
      // "Special 2" was releasing).
      airing: main.some((p) => p.status === 'RELEASING'),
      announced: parts.some((p) => p.status === 'NOT_YET_RELEASED'),
    })
  }
  return out
}

/** AniList media id → the local franchise that owns it. */
export async function franchisesOfMedia(ids: number[]): Promise<Map<number, string>> {
  const unique = [...new Set(ids)]
  if (unique.length === 0) return new Map()
  const rows = await db
    .select({ mediaId: franchiseMember.mediaId, franchiseId: franchiseMember.franchiseId })
    .from(franchiseMember)
    .innerJoin(franchise, eq(franchise.id, franchiseMember.franchiseId))
    .where(and(inArray(franchiseMember.mediaId, unique), eq(franchise.source, 'anilist')))
  return new Map(rows.map((row) => [row.mediaId, row.franchiseId]))
}

/** Fold a materialised franchise's series identity into a target. */
export function applyFranchiseSeries(target: RecommendationTargetFacts, series: FranchiseSeries): void {
  target.rootId = series.rootId
  target.rootTitle = series.title
  target.rootYear = series.rootYear
  target.rootFormat = series.rootFormat
  target.rootEpisodes = series.rootEpisodes
  target.rootImages = {
    portrait: series.images.portrait ?? target.rootImages.portrait,
    landscape: series.images.landscape ?? target.rootImages.landscape,
  }
  target.memberIds = [...new Set([...target.memberIds, ...series.memberIds])]
  target.airing ||= series.airing
  target.announced ||= series.announced
}

export interface WalkNode extends OrderFacts {
  status: string | null
  episodes: number | null
  title: string
  images: ArtworkSet
  ups: number[]
}

function nodeFromAniList(node: AniListRootNode): WalkNode {
  return {
    id: node.id,
    format: node.format,
    status: node.status,
    season: node.season,
    seasonYear: node.seasonYear,
    episodes: node.episodes,
    title: (node.title.english || node.title.romaji || '').trim(),
    images: { portrait: node.coverImage.extraLarge ?? node.coverImage.large ?? null, landscape: node.bannerImage ?? null },
    ups: (node.relations?.edges ?? [])
      .filter((edge) => edge.node.type === 'ANIME' && UP.has(edge.relationType) && edge.node.format !== 'MUSIC')
      .map((edge) => edge.node.id),
  }
}

/** Cached catalogue nodes (media + their stored relation edges) — no provider request. */
async function localNodes(ids: number[]): Promise<Map<number, WalkNode>> {
  const out = new Map<number, WalkNode>()
  if (ids.length === 0) return out
  const [rows, edges] = await Promise.all([
    db
      .select({
        id: media.id,
        format: media.format,
        status: media.status,
        season: media.season,
        seasonYear: media.seasonYear,
        episodes: media.episodes,
        titleEnglish: media.titleEnglish,
        titleRomaji: media.titleRomaji,
        cover: media.cover,
        banner: media.banner,
      })
      .from(media)
      .where(and(inArray(media.id, ids), eq(media.source, 'anilist'))),
    db
      .select({ mediaId: mediaRelations.mediaId, relatedId: mediaRelations.relatedId })
      .from(mediaRelations)
      .where(and(inArray(mediaRelations.mediaId, ids), inArray(mediaRelations.relationType, [...UP]))),
  ])
  const ups = new Map<number, number[]>()
  for (const edge of edges) ups.set(edge.mediaId, [...(ups.get(edge.mediaId) ?? []), edge.relatedId])
  for (const row of rows) {
    out.set(row.id, {
      id: row.id,
      format: row.format,
      status: row.status,
      season: row.season,
      seasonYear: row.seasonYear,
      episodes: row.episodes,
      title: (row.titleEnglish || row.titleRomaji || '').trim(),
      images: { portrait: row.cover ?? null, landscape: row.banner ?? null },
      ups: ups.get(row.id) ?? [],
    })
  }
  return out
}

export interface RootWalkStart {
  target: RecommendationTargetFacts
  /** The target's own PREQUEL/PARENT ids (from its one level of relations). */
  ups: number[]
  /** WINTER | SPRING | SUMMER | FALL — orders two entries of one year. */
  season?: string | null
}

/** The walk's data access — the catalogue and AniList — injectable for tests. */
export interface RootWalkIo {
  franchisesOfMedia(ids: number[]): Promise<Map<number, string>>
  localNodes(ids: number[]): Promise<Map<number, WalkNode>>
  fetchRootNodes(ids: number[], request?: AniListRequestOptions): Promise<AniListRootNode[]>
  loadFranchiseSeries(franchiseIds: string[]): Promise<Map<string, FranchiseSeries>>
}

const defaultIo: RootWalkIo = { franchisesOfMedia, localNodes, fetchRootNodes, loadFranchiseSeries }

export interface RootWalkOptions {
  request?: AniListRequestOptions
  /** Awaited before every AniList request (the backfill spaces them ~2.1 s apart). */
  pace?: () => Promise<void>
}

/**
 * Give every AniList target its series identity, in place: a materialised franchise's root when
 * the title (or anything above it) is materialised, else the earliest series entry on its
 * PREQUEL/PARENT chain. Best-effort — a provider failure leaves a target as its own root, which is
 * what it was before the walk.
 */
export async function resolveSeriesRoots(
  starts: RootWalkStart[],
  options: RootWalkOptions = {},
  io: RootWalkIo = defaultIo,
): Promise<{ providerRequests: number }> {
  let providerRequests = 0
  const pending = starts.filter((start) => start.target.source === 'anilist')
  if (pending.length === 0) return { providerRequests }

  const known = new Map<number, WalkNode>()
  for (const { target, ups, season } of pending) {
    known.set(target.externalId, {
      id: target.externalId,
      format: target.format,
      status: target.status,
      season: season ?? null,
      seasonYear: target.year,
      episodes: target.episodes,
      title: target.title,
      images: target.images,
      ups,
    })
  }
  const franchiseOf = await io.franchisesOfMedia(pending.map((start) => start.target.externalId))
  const hit = new Map<RootWalkStart, string>()
  const walks = new Map<RootWalkStart, { visited: Set<number>; frontier: number[] }>()
  for (const start of pending) {
    const own = franchiseOf.get(start.target.externalId)
    if (own) hit.set(start, own)
    else if (start.ups.length > 0) walks.set(start, { visited: new Set([start.target.externalId]), frontier: start.ups })
  }

  for (let level = 0; level < MAX_LEVELS && walks.size > 0; level++) {
    const frontier = [...new Set([...walks.values()].flatMap((walk) => walk.frontier))]
    const owners = await io.franchisesOfMedia(frontier.filter((id) => !franchiseOf.has(id)))
    for (const [id, fid] of owners) franchiseOf.set(id, fid)
    const unknown = frontier.filter((id) => !known.has(id) && !franchiseOf.has(id))
    for (const [id, node] of await io.localNodes(unknown)) known.set(id, node)
    const remote = unknown.filter((id) => !known.has(id))
    if (remote.length > 0) {
      try {
        await options.pace?.()
        providerRequests++
        for (const node of await io.fetchRootNodes(remote, options.request)) known.set(node.id, nodeFromAniList(node))
      } catch (error) {
        console.warn('series-root walk: AniList request failed:', 'diagnostic details redacted')
      }
    }
    for (const [start, walk] of walks) {
      const owner = walk.frontier.map((id) => franchiseOf.get(id)).find((fid): fid is string => !!fid)
      if (owner) {
        for (const id of walk.frontier) walk.visited.add(id)
        settle(start, walk.visited, known)
        hit.set(start, owner)
        walks.delete(start)
        continue
      }
      const next: number[] = []
      for (const id of walk.frontier) {
        walk.visited.add(id)
        for (const up of known.get(id)?.ups ?? []) {
          if (!walk.visited.has(up) && !next.includes(up)) next.push(up)
        }
      }
      walk.frontier = walk.visited.size >= MAX_NODES_PER_TARGET ? [] : next
      if (walk.frontier.length === 0) walks.delete(start)
      settle(start, walk.visited, known)
    }
  }
  // Walks cut off by the level cap keep the best root they reached.
  for (const [start, walk] of walks) settle(start, walk.visited, known)

  const series = await io.loadFranchiseSeries([...new Set(hit.values())])
  for (const [start, fid] of hit) {
    const value = series.get(fid)
    if (value) applyFranchiseSeries(start.target, value)
  }
  return { providerRequests }
}

/** Root = the earliest series entry the walk saw; ancestors join the target's known members. */
function settle(start: RootWalkStart, visited: Set<number>, known: Map<number, WalkNode>): void {
  const nodes = [...visited].map((id) => known.get(id)).filter((node): node is WalkNode => !!node)
  const root = nodes.sort(rootOrder)[0]
  const target = start.target
  target.memberIds = [...new Set([...target.memberIds, ...visited])]
  target.announced ||= nodes.some((node) => node.status === 'NOT_YET_RELEASED')
  target.airing ||= nodes.some((node) => node.status === 'RELEASING')
  if (!root || root.id === target.rootId) return
  target.rootId = root.id
  target.rootTitle = root.title || target.rootTitle
  target.rootYear = root.seasonYear
  target.rootFormat = root.format
  target.rootEpisodes = root.episodes
  target.rootImages = {
    portrait: root.images.portrait ?? target.rootImages.portrait,
    landscape: root.images.landscape ?? target.rootImages.landscape,
  }
}
