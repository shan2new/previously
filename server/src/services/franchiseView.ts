import { partKindForFormat } from '../grouping/partKind.js'
import type { MediaFormat } from '../anilist/types.js'
import { and, eq, inArray, sql } from 'drizzle-orm'
import { db } from '../db/index.js'
import { franchise, franchiseMember, media, progress, subscriptions } from '../db/schema.js'
import type { PartKind } from '../grouping/partKind.js'
import type {
  Airing,
  ArtworkGallery,
  ArtworkImage,
  ArtworkSet,
  AudienceInfo,
  CatalogVideo,
  ContinueWatching,
  EpisodeMeta,
  Franchise,
  FranchisePart,
  FranchiseSummary,
  FranchiseVideo,
  LibraryFranchise,
  MediaSource,
  ReleasePrecision,
  WatchStatus,
} from '../types/api.js'
import {
  deriveCatalogUpcoming,
  resolveUpcomingWithCatalog,
  type CatalogUpcomingPart,
} from './catalogUpcoming.js'
import { withReleaseWindow } from './releaseWindow.js'
import { resolveRelatedFranchiseIds } from './catalogEnrichment.js'
import { stripHtml } from '../util/text.js'
import { catalogLinkViews } from './catalogLinks.js'
import { limitArtwork, rankLogos } from '../util/artwork.js'
import { consumerFranchiseConditions } from './consumerContent.js'

const D = 86_400_000
const KIND_ORDER: PartKind[] = ['season', 'movie', 'ova', 'ona', 'special', 'music']

const EMPTY_PEOPLE = { creators: [], directors: [], cast: [] }

function artwork(portrait: string | null | undefined, landscape: string | null | undefined): ArtworkSet {
  return { portrait: portrait || null, landscape: landscape || null }
}

function artworkGallery(
  stored: ArtworkGallery | null | undefined,
  images: ArtworkSet,
  source: MediaSource,
  additions: ArtworkGallery[] = [],
): ArtworkGallery {
  const fallback = (url: string | null): ArtworkImage[] => url ? [{
    url, source, width: null, height: null, language: null, score: null,
  }] : []
  const merge = (items: ArtworkImage[], preserveTextless = true) => limitArtwork(items, 6, preserveTextless)
  return {
    portraits: merge([...(stored?.portraits ?? []), ...fallback(images.portrait), ...additions.flatMap((item) => item.portraits)]),
    landscapes: merge([...(stored?.landscapes ?? []), ...fallback(images.landscape), ...additions.flatMap((item) => item.landscapes)]),
    // Re-ranked on READ, so galleries stored under the old size-first order are corrected
    // without a re-enrichment pass (`rankLogos`).
    logos: rankLogos([...(stored?.logos ?? []), ...additions.flatMap((item) => item.logos)], 6),
  }
}

function scopedPartVideos(m: MediaRow, member: MemberRow): FranchiseVideo[] {
  return (m.videos ?? []).map((video) => ({
    ...video,
    scope: { type: 'part', mediaId: m.id, label: member.label ?? m.titleEnglish ?? m.titleRomaji ?? `Part ${member.sequence}` },
  }))
}

function franchiseVideos(
  stored: CatalogVideo[] | null | undefined,
  parts: FranchisePart[],
): FranchiseVideo[] {
  // Part scope is more precise than a duplicate show-level record, so it enters the map first.
  const candidates: FranchiseVideo[] = [
    ...parts.flatMap((part) => part.videos),
    ...(stored ?? []).map((video): FranchiseVideo => ({ ...video, scope: { type: 'franchise' } })),
  ]
  const seen = new Set<string>()
  return candidates.filter((video) => {
    const key = `${video.site.toLowerCase()}:${video.id}`
    if (seen.has(key)) return false
    seen.add(key)
    return true
  })
}

const VIDEO_KIND_WEIGHT: Record<FranchiseVideo['kind'], number> = {
  trailer: 5,
  teaser: 4,
  announcement: 3,
  featurette: 2,
  clip: 1,
  other: 0,
}

/** Prefer an exact upcoming/current part, then franchise campaigns, then finished-part trailers. */
export function pickFeaturedVideo(parts: FranchisePart[], videos: FranchiseVideo[]): FranchiseVideo | null {
  if (videos.length === 0) return null
  const partPriority = new Map<number, number>()
  for (const part of parts) {
    const state = part.status === 'NOT_YET_RELEASED' ? 3 : part.isReleasing ? 2 : 0
    partPriority.set(part.mediaId, state * 10_000 + part.sequence)
  }
  return videos.slice().sort((a, b) => {
    // A franchise-scoped video cannot outrank a known future/current part, but it should outrank
    // finished-part trailers: fallback catalogues often carry the newest campaign only at show
    // scope, and otherwise an old Season 1 trailer would stay featured forever.
    const scope = (video: FranchiseVideo) => video.scope.type === 'part'
      ? (partPriority.get(video.scope.mediaId) ?? 0)
      : 10_000
    return scope(b) - scope(a) ||
      Number(b.official === true) - Number(a.official === true) ||
      VIDEO_KIND_WEIGHT[b.kind] - VIDEO_KIND_WEIGHT[a.kind] ||
      (b.publishedAt ?? '').localeCompare(a.publishedAt ?? '')
  })[0] ?? null
}

/** First already-aired episode the user has not watched, with best-effort episode context. */
export function deriveContinueWatching(
  parts: FranchisePart[],
  episodesByMediaId: ReadonlyMap<number, EpisodeMeta[]>,
): ContinueWatching | null {
  const candidates = parts.filter((part) => part.progress < part.airedEpisodes)
  const part = candidates.find((candidate) => candidate.progress > 0) ?? candidates[0]
  if (!part) return null
  const number = part.progress + 1
  const metadata = episodesByMediaId.get(part.mediaId)?.find((episode) => episode.number === number)
  return {
    mediaId: part.mediaId,
    partLabel: part.label,
    episode: metadata ?? { number, title: null, airDate: null, overview: null, still: null, runtime: null },
  }
}

/** Latest aired episode number from a dated episode list, or null when the list carries no dates
 *  at all (AniList `streamingEpisodes` have titles/thumbnails but never air dates). */
function latestAiredFromEpisodes(episodes: EpisodeMeta[], nowMs: number): number | null {
  let dated = false
  let latest = 0
  for (const e of episodes) {
    if (e.airDate == null) continue
    dated = true
    if (e.airDate <= nowMs && e.number > latest) latest = e.number
  }
  return dated ? latest : null
}

/**
 * How many episodes of a part are actually out. Pure so it can be unit-tested (see
 * `franchiseView.test.ts`); everything it needs comes from the media row, never from the user.
 *
 * The tricky case is RELEASING with **no** next slot — reachable on both sources: TMDB nulls
 * `next_episode_to_air.air_date` while the season still derives as RELEASING, and AniList leaves a
 * window between a finale airing and `status` flipping to FINISHED. The old fallback there was the
 * user's own `watched` count, which is not evidence of anything: a fresh subscriber saw every
 * episode as un-aired ("upcoming", progress 0), and a partway viewer got a season header claiming
 * they were caught up. Derive it from the episode list when it is dated, else from the catalogue's
 * total only once it is finished — never from progress. A releasing part with no evidence
 * reports zero verified episodes, not the advertised future total.
 */
export function deriveAiredEpisodes(m: {
  status: string | null
  totalEpisodes: number
  next: { episode: number } | null
  episodes: EpisodeMeta[]
  nowMs: number
}): number {
  // An announced part has aired NOTHING, whatever episode count the catalogue advertises for it.
  // TMDB publishes `episode_count` for announced seasons, so a One Piece season that hadn't aired
  // an episode surfaced as a backlog ("S3 · 1 left") and lost its premiere-date treatment.
  if (m.status === 'NOT_YET_RELEASED') return 0
  if (m.next) return Math.max(0, m.next.episode - 1)
  if (m.status === 'RELEASING') return latestAiredFromEpisodes(m.episodes, m.nowMs) ?? 0
  return m.totalEpisodes
}

/** Schedule's window, in days either side of now. A day wider than the client's own −7…+14 so a
 *  device at UTC±14 never sees an edge day arrive undated; the client windows precisely. */
export const SCHEDULE_WINDOW = { backDays: 8, aheadDays: 15 } as const

/**
 * Every dated episode of a part inside Schedule's window, oldest first — the per-episode facts a
 * calendar needs, without shipping the whole list on the library payload.
 *
 * Three sources of a date, merged and de-duplicated by episode number: the dated episode list
 * (TMDB always; AniList once `backfill-episodes` has run), the catalogue's own next slot (AniList
 * always has one while releasing, even with no per-episode dates), and `lastAiredAt` for the
 * latest aired episode (so an un-backfilled AniList part still puts its most recent episode on
 * the calendar). The list wins on a conflict: it is the only one of the three that is per-episode.
 * Pure so it can be unit-tested (see `franchiseView.test.ts`).
 */
export function airingsWindow(m: {
  episodes: EpisodeMeta[]
  next: { episode: number; airingAt: number } | null
  airedEpisodes: number
  lastAiredAt: number | null
  nowMs: number
}): Airing[] {
  const lo = m.nowMs - SCHEDULE_WINDOW.backDays * D
  const hi = m.nowMs + SCHEDULE_WINDOW.aheadDays * D
  const byEpisode = new Map<number, number>()
  const consider = (episode: number, at: number | null | undefined) => {
    if (at == null || at <= 0 || episode <= 0) return
    if (at < lo || at > hi) return
    if (!byEpisode.has(episode)) byEpisode.set(episode, at)
  }
  for (const e of m.episodes) consider(e.number, e.airDate)
  if (m.next) consider(m.next.episode, m.next.airingAt * 1000)
  if (m.airedEpisodes > 0) consider(m.airedEpisodes, m.lastAiredAt)
  return [...byEpisode.entries()]
    .map(([episode, at]) => ({ episode, at }))
    .sort((a, b) => a.at - b.at || a.episode - b.episode)
}

type MediaRow = typeof media.$inferSelect
type MemberRow = typeof franchiseMember.$inferSelect
type FranchiseRow = typeof franchise.$inferSelect

/**
 * State the precision of a next-release instant instead of leaving the client to infer it from
 * `source`. AniList publishes a real broadcast instant; TMDB publishes a calendar date that the TV
 * sync synthesizes to 17:00 UTC, so its clock half is not a fact and must never be rendered.
 */
function releasePrecision(nextAiringAt: number | null, source: MediaSource): ReleasePrecision {
  if (nextAiringAt == null) return { precision: 'unknown', at: null, date: null }
  if (source === 'tmdb') {
    return { precision: 'date_only', at: nextAiringAt, date: new Date(nextAiringAt).toISOString().slice(0, 10) }
  }
  return { precision: 'exact', at: nextAiringAt, date: null }
}

/** Derive a FranchisePart's airing fields from a media row + the user's progress. Mirrors legacy `toShow`.
 *  `opts.episodes` includes the full per-episode list (detail only; omitted from lean list payloads). */
function toPart(
  m: MediaRow,
  member: MemberRow,
  watched: number,
  source: MediaSource,
  opts?: { episodes?: boolean },
): FranchisePart {
  const title = m.titleEnglish || m.titleRomaji || `Anime #${m.id}`
  const isReleasing = m.status === 'RELEASING'
  const total = m.episodes ?? 0
  const next = m.nextAiringEpisode && m.nextAiringEpisode.airingAt > 0 ? m.nextAiringEpisode : null
  const eps = m.episodesList ?? []
  const airedEpisodes = deriveAiredEpisodes({
    status: m.status,
    totalEpisodes: total,
    next,
    episodes: eps,
    nowMs: Date.now(),
  })
  const nextAiringAt = next ? next.airingAt * 1000 : null
  const release = releasePrecision(nextAiringAt, source)
  const lastAiredAt =
    m.lastAiredAt != null && m.lastAiredAt > 0
      ? m.lastAiredAt
      : eps.reduce<number | null>((latest, episode) =>
          episode.airDate != null && episode.airDate <= Date.now()
            ? Math.max(latest ?? 0, episode.airDate) : latest, null)

  // Episodes sharing the exact next airing instant ⇒ a same-day multi-episode / full-season drop.
  const nextAiringCount = nextAiringAt != null ? eps.filter((e) => e.airDate === nextAiringAt).length : 0
  const airings = airingsWindow({ episodes: eps, next, airedEpisodes, lastAiredAt, nowMs: Date.now() })

  return {
    mediaId: m.id,
    kind: member.partKind as PartKind,
    sequence: member.sequence,
    watchOrder: member.watchOrder || member.sequence,
    relationship: member.relationship ?? null,
    optional: member.optional,
    label: member.label ?? title,
    title,
    cover: m.cover ?? '',
    // Keep artwork semantics honest. A portrait cover is not a landscape banner; clients need
    // the distinction to choose a composition that does not crop the subject into a wide slot.
    banner: m.banner ?? '',
    images: artwork(m.cover, m.banner),
    artwork: artworkGallery(m.artwork, artwork(m.cover, m.banner), source),
    format: m.format,
    status: m.status,
    isReleasing,
    totalEpisodes: total,
    airedEpisodes,
    nextEpisodeNumber: next?.episode ?? null,
    nextAiringAt,
    release,
    lastAiredAt,
    synopsis: stripHtml(m.description),
    genres: (m.genres ?? []).slice(0, 4),
    // Read-time guard for rows written before the write clamp (`clampProgress`): a season that
    // has not premiered reports only what has aired of it, so a stale mark cannot pre-empt it.
    progress: m.status === 'NOT_YET_RELEASED' ? Math.min(watched, airedEpisodes) : watched,
    year: m.seasonYear ?? null,
    studios: m.studios ?? [],
    nextAiringCount,
    episodes: opts?.episodes ? eps : [],
    airings,
    videos: scopedPartVideos(m, member),
  }
}

/**
 * A franchise's parts in WATCH order: watch order, then kind, then sequence. Exported so the
 * installment index (social/resolve.ts) scans parts exactly as the feed's composer does — the part
 * an announcement names is the first match in this order.
 */
export function comparePartOrder(
  a: Pick<FranchisePart, 'watchOrder' | 'kind' | 'sequence'>,
  b: Pick<FranchisePart, 'watchOrder' | 'kind' | 'sequence'>,
): number {
  const order = a.watchOrder - b.watchOrder
  if (order !== 0) return order
  const k = KIND_ORDER.indexOf(a.kind) - KIND_ORDER.indexOf(b.kind)
  return k !== 0 ? k : a.sequence - b.sequence
}

function sortParts(parts: FranchisePart[]): FranchisePart[] {
  return parts.sort(comparePartOrder)
}

/** Unwatched aired episodes for a part (0 unless releasing). */
function episodesBehind(p: FranchisePart): number {
  return p.isReleasing ? Math.max(0, p.airedEpisodes - p.progress) : 0
}

async function loadProgressMap(userId: string | undefined, mediaIds: number[]): Promise<Map<number, number>> {
  const map = new Map<number, number>()
  if (!userId || mediaIds.length === 0) return map
  const rows = await db
    .select()
    .from(progress)
    .where(and(eq(progress.userId, userId), inArray(progress.mediaId, mediaIds)))
  for (const r of rows) map.set(r.mediaId, r.episodesWatched)
  return map
}

function catalogUpcomingParts(mems: MemberRow[], mediaById: Map<number, MediaRow>): CatalogUpcomingPart[] {
  return mems.flatMap((mem) => {
    const m = mediaById.get(mem.mediaId)
    if (!m) return []
    const nextAiringAt =
      m.nextAiringEpisode && m.nextAiringEpisode.airingAt > 0 ? m.nextAiringEpisode.airingAt * 1000 : null
    return [{
      mediaId: m.id,
      kind: mem.partKind as PartKind,
      sequence: mem.sequence,
      label: mem.label || m.titleEnglish || m.titleRomaji || `Part ${mem.sequence}`,
      title: m.titleEnglish || m.titleRomaji || '',
      status: m.status,
      nextAiringAt,
      fetchedAt: m.fetchedAt,
    }]
  })
}

/** Assemble a Franchise from already-loaded rows (no DB access). Shared by detail + library. */
function buildFranchise(
  f: FranchiseRow,
  mems: MemberRow[],
  mediaById: Map<number, MediaRow>,
  watchedById: Map<number, number>,
  sub: { status: WatchStatus; addedAt: number } | null,
  opts?: { episodes?: boolean },
): Franchise {
  const source: MediaSource = (f.source as MediaSource) ?? 'anilist'
  const parts = sortParts(
    mems
      .map((mem) => {
        const m = mediaById.get(mem.mediaId)
        return m ? toPart(m, mem, watchedById.get(mem.mediaId) ?? 0, source, opts) : null
      })
      .filter((p): p is FranchisePart => p !== null),
  )

  const partCounts: Partial<Record<PartKind, number>> = {}
  for (const p of parts) partCounts[p.kind] = (partCounts[p.kind] ?? 0) + 1

  // Franchise-level meta for the detail header: premiere year (earliest dated part) + the primary
  // installment's studios/networks (fall back to the first part that has any).
  const primary = f.primaryMediaId != null ? mediaById.get(f.primaryMediaId) : undefined
  // Premiere year = the earliest dated SEASON or MOVIE; an OVA or music video dated before the
  // first season must not become the work's year.
  const episodic = parts.filter((p) => p.kind === 'season' || p.kind === 'movie')
  const years = (episodic.length ? episodic : parts).map((p) => p.year).filter((y): y is number => y != null)
  const year = years.length ? Math.min(...years) : (primary?.seasonYear ?? null)
  const studios = (primary?.studios?.length ? primary.studios : parts.find((p) => p.studios.length > 0)?.studios) ?? []
  const catalogUpcoming = deriveCatalogUpcoming({
    source,
    franchiseExternalId: f.externalId,
    parts: catalogUpcomingParts(mems, mediaById),
  })
  const upcoming = resolveUpcomingWithCatalog(f.upcoming, catalogUpcoming, { parts })
  const videos = franchiseVideos(f.enrichment?.videos, parts)
  const images = artwork(
    f.cover || parts.find((part) => part.images.portrait)?.images.portrait,
    f.banner || parts.find((part) => part.images.landscape)?.images.landscape,
  )
  const gallery = artworkGallery(f.artwork, images, source, parts.map((part) => part.artwork))
  const audience: AudienceInfo = {
    isAdult: f.enrichment?.isAdult ?? null,
    contentRating: null,
    availableRatings: f.enrichment?.contentRatings ?? [],
  }
  const episodesByMediaId = new Map(
    [...mediaById.entries()].map(([id, value]) => [id, value.episodesList ?? []] as const),
  )

  return {
    id: f.id,
    source,
    title: f.title,
    cover: f.cover ?? '',
    banner: f.banner ?? '',
    images,
    artwork: gallery,
    synopsis: f.description ?? '',
    genres: f.genres ?? [],
    isReleasing: parts.some((p) => p.isReleasing),
    partCounts,
    parts,
    subscription: sub,
    upcoming: withReleaseWindow(upcoming),
    year,
    studios,
    themes: f.enrichment?.themes?.length ? f.enrichment.themes : (f.genres ?? []).slice(0, 10),
    featuredVideo: pickFeaturedVideo(parts, videos),
    videos,
    audience,
    people: f.enrichment?.people ?? EMPTY_PEOPLE,
    related: f.enrichment?.related ?? [],
    continueWatching: deriveContinueWatching(parts, episodesByMediaId),
    metadata: {
      completeness: {
        artwork: gallery.portraits.length > 0 && gallery.landscapes.length > 0,
        episodes: parts.some((part) => (mediaById.get(part.mediaId)?.episodesList?.length ?? 0) > 0),
        people: (f.enrichment?.people?.creators?.length ?? 0) + (f.enrichment?.people?.directors?.length ?? 0) + (f.enrichment?.people?.cast?.length ?? 0) > 0,
        ratings: (f.enrichment?.contentRatings.length ?? 0) > 0,
        related: (f.enrichment?.related.length ?? 0) > 0,
        videos: videos.length > 0,
      },
      sources: [],
    },
  }
}

/** Full franchise detail with parts + (optional) the user's progress and subscription. */
export async function getFranchise(franchiseId: string, userId?: string, country?: string): Promise<Franchise | null> {
  const [f] = await db.select().from(franchise).where(and(eq(franchise.id, franchiseId), ...consumerFranchiseConditions())).limit(1)
  if (!f) return null

  const members = await db.select().from(franchiseMember).where(eq(franchiseMember.franchiseId, franchiseId))
  const mediaIds = members.map((m) => m.mediaId)
  const mediaRows = mediaIds.length ? await db.select().from(media).where(inArray(media.id, mediaIds)) : []
  const mediaById = new Map(mediaRows.map((m) => [m.id, m]))
  const watchedById = await loadProgressMap(userId, mediaIds)

  let sub: { status: WatchStatus; addedAt: number } | null = null
  if (userId) {
    const [s] = await db
      .select()
      .from(subscriptions)
      .where(and(eq(subscriptions.userId, userId), eq(subscriptions.franchiseId, franchiseId)))
      .limit(1)
    if (s) sub = { status: s.status as WatchStatus, addedAt: s.createdAt.getTime() }
  }

  // Detail is the only response that ships the full per-episode list.
  const built = buildFranchise(f, members, mediaById, watchedById, sub, { episodes: true })
  built.metadata.sources = (await catalogLinkViews([franchiseId])).get(franchiseId) ?? []
  built.related = await resolveRelatedFranchiseIds(built.related)
  const normalizedCountry = country?.toUpperCase()
  built.audience.contentRating = normalizedCountry
    ? built.audience.availableRatings.find((rating) => rating.country === normalizedCountry) ?? null
    : null
  return built
}

/** Build a list of FranchiseSummary for the given franchise ids (trending/search). */
export async function getSummaries(franchiseIds: string[]): Promise<FranchiseSummary[]> {
  if (franchiseIds.length === 0) return []
  const fr = await db.select().from(franchise).where(and(inArray(franchise.id, franchiseIds), ...consumerFranchiseConditions()))
  const members = await db.select().from(franchiseMember).where(inArray(franchiseMember.franchiseId, franchiseIds))
  const mediaIds = members.map((m) => m.mediaId)
  const mediaRows = mediaIds.length ? await db.select().from(media).where(inArray(media.id, mediaIds)) : []
  const mediaById = new Map(mediaRows.map((m) => [m.id, m]))

  const byFranchise = new Map<string, MemberRow[]>()
  for (const m of members) {
    const arr = byFranchise.get(m.franchiseId) ?? []
    arr.push(m)
    byFranchise.set(m.franchiseId, arr)
  }

  const order = new Map(franchiseIds.map((id, i) => [id, i]))
  return fr
    .map((f): FranchiseSummary => {
      const mems = byFranchise.get(f.id) ?? []
      const source: MediaSource = (f.source as MediaSource) ?? 'anilist'
      let nextAiringAt: number | null = null
      let releasing = false
      let minYear: number | null = null
      for (const mem of mems) {
        const m = mediaById.get(mem.mediaId)
        if (!m) continue
        if (m.status === 'RELEASING') releasing = true
        const next = m.nextAiringEpisode && m.nextAiringEpisode.airingAt > 0 ? m.nextAiringEpisode.airingAt * 1000 : null
        if (next && (nextAiringAt == null || next < nextAiringAt)) nextAiringAt = next
        if (m.seasonYear != null && (minYear == null || m.seasonYear < minYear)) minYear = m.seasonYear
      }
      const primary = f.primaryMediaId != null ? mediaById.get(f.primaryMediaId) : undefined
      const portrait = f.cover || primary?.cover || mems
        .map((member) => mediaById.get(member.mediaId)?.cover)
        .find((value): value is string => !!value)
      const landscape = f.banner || primary?.banner || mems
        .map((member) => mediaById.get(member.mediaId)?.banner)
        .find((value): value is string => !!value)
      const images = artwork(portrait, landscape)
      const gallery = artworkGallery(
        f.artwork,
        images,
        source,
        mems.flatMap((member) => {
          const value = mediaById.get(member.mediaId)?.artwork
          return value ? [value] : []
        }),
      )
      return {
        id: f.id,
        source,
        title: f.title,
        cover: f.cover ?? '',
        banner: f.banner ?? '',
        images,
        artwork: gallery,
        isReleasing: releasing,
        // The count Detail prints under "Seasons & movies": episodic members only, never OVAs,
        // specials or music videos — Search and Detail must agree. RELEASED members only: an
        // announced season is news, not a season you can watch ("3 seasons" for ONE PIECE with
        // two aired — review i4, N11).
        partCount: mems.filter((mem) => {
          const m = mediaById.get(mem.mediaId)
          if (!m || m.status === 'NOT_YET_RELEASED') return false
          const kind = partKindForFormat((m.format as MediaFormat | null) ?? null)
          return kind === 'season' || kind === 'movie'
        }).length,
        nextAiringAt,
        upcoming: withReleaseWindow(
          resolveUpcomingWithCatalog(
            f.upcoming,
            deriveCatalogUpcoming({
              source,
              franchiseExternalId: f.externalId,
              parts: catalogUpcomingParts(mems, mediaById),
            }),
            { parts: catalogUpcomingParts(mems, mediaById) },
          ),
        ),
        year: primary?.seasonYear ?? minYear,
        themes: f.enrichment?.themes?.length ? f.enrichment.themes : (f.genres ?? []).slice(0, 10),
        featuredVideo: (() => {
          const summaryParts = sortParts(
            mems.flatMap((member) => {
              const row = mediaById.get(member.mediaId)
              return row ? [toPart(row, member, 0, source)] : []
            }),
          )
          const videos = franchiseVideos(f.enrichment?.videos, summaryParts)
          return pickFeaturedVideo(summaryParts, videos)
        })(),
      }
    })
    .sort((a, b) => (order.get(a.id) ?? 0) - (order.get(b.id) ?? 0))
}

/**
 * Trending franchises ranked by the catalogue's actual trend signal.
 *
 * `franchise.updatedAt` is a grouping/cache timestamp, not audience interest. Search lazily
 * groups catalogue misses, so ordering by it let the most recent query overwrite the zero-state
 * shelf (for example an "f" search became the next user's "Trending now"). AniList's persisted
 * `media.trending` score is the correct product fact; popularity is only a deterministic tie-break.
 */
export async function getTrendingFranchises(limit: number, source?: MediaSource | null): Promise<FranchiseSummary[]> {
  return getSummaries(await trendingFranchiseIds(limit, source))
}

/**
 * The trending ranking alone (see `getTrendingFranchises`): franchise ids, most trending first.
 *
 * `source` ranks ONE catalogue. It has to be part of the ranking, not a filter over its head: only
 * AniList carries a `trending` score (TMDB rows store null and rank by popularity), so every anime
 * franchise sorts above every TV one and the first N of the mixed ranking hold no TV show at all.
 */
export async function trendingFranchiseIds(limit: number, source?: MediaSource | null): Promise<string[]> {
  const rows = await db
    .select({ id: franchise.id })
    .from(franchise)
    .innerJoin(franchiseMember, eq(franchiseMember.franchiseId, franchise.id))
    .innerJoin(media, eq(media.id, franchiseMember.mediaId))
    .where(and(...consumerFranchiseConditions(), source ? eq(franchise.source, source) : undefined))
    .groupBy(franchise.id)
    .orderBy(
      sql`max(${media.trending}) desc nulls last`,
      sql`max(${media.popularity}) desc nulls last`,
      sql`max(${franchise.updatedAt}) desc`,
    )
    .limit(limit)
  return rows.map((r) => r.id)
}

/**
 * Batched franchises for the Today feed: lean parts (no episode lists), videos, upcoming, art; the
 * viewer's progress and subscription when `userId` is given. No related-title or catalogue-link
 * resolution — the feed shows neither. A fixed number of queries for any number of ids (the
 * `getLibrary` pattern without its per-item extras). Franchises come back in the order asked for;
 * an id with no franchise row is skipped.
 *
 * `externalIdById` (franchise id → `franchise.external_id`, the TMDB show id) is additive to the
 * feed spec's shape: a TMDB catalogue post links to the show page, which needs it.
 */
export async function getFeedFranchises(franchiseIds: string[], userId: string | null): Promise<{
  franchises: Franchise[]
  statusById: Map<string, WatchStatus>
  memberAddedAt: Map<number, number>
  externalIdById: Map<string, number | null>
}> {
  const ids = [...new Set(franchiseIds)]
  const statusById = new Map<string, WatchStatus>()
  const memberAddedAt = new Map<number, number>()
  const externalIdById = new Map<string, number | null>()
  if (ids.length === 0) return { franchises: [], statusById, memberAddedAt, externalIdById }

  const [frRows, members, subs] = await Promise.all([
    db.select().from(franchise).where(and(inArray(franchise.id, ids), ...consumerFranchiseConditions())),
    db.select().from(franchiseMember).where(inArray(franchiseMember.franchiseId, ids)),
    userId
      ? db
        .select({ franchiseId: subscriptions.franchiseId, status: subscriptions.status, createdAt: subscriptions.createdAt })
        .from(subscriptions)
        .where(and(eq(subscriptions.userId, userId), inArray(subscriptions.franchiseId, ids)))
      : Promise.resolve([]),
  ])
  const mediaIds = members.map((m) => m.mediaId)
  const [mediaRows, watchedById] = await Promise.all([
    mediaIds.length ? db.select().from(media).where(inArray(media.id, mediaIds)) : Promise.resolve([]),
    loadProgressMap(userId ?? undefined, mediaIds),
  ])

  const frById = new Map(frRows.map((f) => [f.id, f]))
  const mediaById = new Map(mediaRows.map((m) => [m.id, m]))
  const membersByFranchise = new Map<string, MemberRow[]>()
  for (const mem of members) {
    const arr = membersByFranchise.get(mem.franchiseId) ?? []
    arr.push(mem)
    membersByFranchise.set(mem.franchiseId, arr)
    memberAddedAt.set(mem.mediaId, mem.addedAt.getTime())
  }
  const subById = new Map<string, { status: WatchStatus; addedAt: number }>()
  for (const s of subs) {
    const status = s.status as WatchStatus
    subById.set(s.franchiseId, { status, addedAt: s.createdAt.getTime() })
    statusById.set(s.franchiseId, status)
  }

  const franchises: Franchise[] = []
  for (const id of ids) {
    const f = frById.get(id)
    if (!f) continue
    externalIdById.set(f.id, f.externalId ?? null)
    franchises.push(buildFranchise(f, membersByFranchise.get(id) ?? [], mediaById, watchedById, subById.get(id) ?? null))
  }
  const related = await resolveRelatedFranchiseIds(franchises.flatMap((item) => item.related))
  const relatedByKey = new Map(related.map((item) => [`${item.source}:${item.externalId}`, item]))
  for (const item of franchises) item.related = item.related.flatMap((value) => {
    const resolved = relatedByKey.get(`${value.source}:${value.externalId}`)
    return resolved ? [resolved] : []
  })
  return { franchises, statusById, memberAddedAt, externalIdById }
}

/** The authenticated user's library: full franchises + status + behind + newParts. */
export async function getLibrary(userId: string, lastOpenedAt: number): Promise<LibraryFranchise[]> {
  const subs = await db.select().from(subscriptions).where(eq(subscriptions.userId, userId))
  if (subs.length === 0) return []

  const franchiseIds = subs.map((s) => s.franchiseId)
  const statusById = new Map(subs.map((s) => [s.franchiseId, s.status as WatchStatus]))

  // Batch every dependency in a fixed number of queries — no per-subscription round-trips.
  const frRows = await db.select().from(franchise).where(and(inArray(franchise.id, franchiseIds), ...consumerFranchiseConditions()))
  const members = await db.select().from(franchiseMember).where(inArray(franchiseMember.franchiseId, franchiseIds))
  const mediaIds = members.map((m) => m.mediaId)
  const mediaRows = mediaIds.length ? await db.select().from(media).where(inArray(media.id, mediaIds)) : []
  const watchedById = await loadProgressMap(userId, mediaIds)

  const frById = new Map(frRows.map((f) => [f.id, f]))
  const mediaById = new Map(mediaRows.map((m) => [m.id, m]))
  const membersByFranchise = new Map<string, MemberRow[]>()
  for (const mem of members) {
    const arr = membersByFranchise.get(mem.franchiseId) ?? []
    arr.push(mem)
    membersByFranchise.set(mem.franchiseId, arr)
  }

  // Iterate subs to preserve the user's subscription ordering.
  const out: LibraryFranchise[] = []
  for (const s of subs) {
    const f = frById.get(s.franchiseId)
    if (!f) continue
    const mems = membersByFranchise.get(s.franchiseId) ?? []
    const status = statusById.get(s.franchiseId) ?? 'planned'
    const fr = buildFranchise(f, mems, mediaById, watchedById, { status, addedAt: s.createdAt.getTime() })
    const behind = fr.parts.reduce((acc, p) => acc + episodesBehind(p), 0)
    // newParts: members added since the user last opened the app.
    const newParts = mems.filter((m) => m.addedAt.getTime() > lastOpenedAt).length
    out.push({ ...fr, status, behind, newParts })
  }
  const resolvedRelated = await resolveRelatedFranchiseIds(out.flatMap((item) => item.related))
  const links = await catalogLinkViews(out.map((item) => item.id))
  const relatedByKey = new Map(resolvedRelated.map((item) => [`${item.source}:${item.externalId}`, item]))
  for (const item of out) {
    item.related = item.related.flatMap((related) => {
      const resolved = relatedByKey.get(`${related.source}:${related.externalId}`)
      return resolved ? [resolved] : []
    })
    item.metadata.sources = links.get(item.id) ?? []
  }
  return out
}
