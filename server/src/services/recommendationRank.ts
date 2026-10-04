import { createHash } from 'node:crypto'
import type {
  ArtworkSet,
  MediaSource,
  RecommendationFeedbackKind,
  RecommendationReason,
  RecommendationReasonKind,
  WatchStatus,
} from '../types/api.js'
import { displayTitle } from '../util/text.js'

// "Recommended for you": second-degree recommendations out of the user's own library, ranked by a
// PURE function so the whole policy is testable against a fixture with no database. A port of the
// approved spike (scratchpad reco-spike/rank.py + rotation.py, REPORT §2):
//
//   1 AFFINITY  every show the user has gets a weight from its status, how much of it was watched
//               (one cour = fully engaged) and how recently it was touched.
//   2 EDGES     each show casts ONE vote, spread over its catalogue list (AniList community votes,
//               TMDB /recommendations rank), so a famous show cannot drown a small one.
//   3 CANDIDATE keyed by series (AniList root / TMDB show): seasons of one show merge.
//   4 DROP      owned (incl. members of owned franchises and title twins), JP animation on TMDB,
//               dismissed/seen, films/OVA/specials/music/TV_SHORT, reality/talk/news/soap TV,
//               unreleased, adult.
//   5 RELEVANCE consensus x Bayesian quality x genre fit x freshness x popularity damper.
//   6 SELECT    MMR (<= 2 per show, <= 1 same-universe), a TV quota with one TV title in the
//               first 4, daily jitter, then a seeded draw of the 4 visible tiles.
//   7 REASON    an honest reason in the user's own shows: the kind (consensus / finished /
//               watching / watched / planned / world), how many agree, and up to three of them,
//               strongest first — the client picks which to name by Today's state.
//
// The weights are hand-set (there are no usage logs to learn from yet); every constant below is the
// spike's. Change one only with a new fixture run — `recommendations.test.ts` pins the list.

const DAY_MS = 86_400_000

const STATUS_BASE: Record<WatchStatus, number> = {
  watching: 1.0,
  completed: 1.0,
  paused: 0.5,
  planned: 0.35,
  dropped: -0.6,
}
/** One cour watched = fully engaged. */
const FULL_ENGAGEMENT_EPISODES = 12
const RECENCY_BOOST = 0.25
const RECENCY_DAYS = 30
/** A seed that was the main reason for this many dismissed titles counts half. */
const DISMISS_THRESHOLD = 3
const DISMISS_PENALTY = 0.5

const ANILIST_VOTE_CONFIDENCE = 15
const TMDB_RANK_DECAY = 0.6
const TMDB_RELIABILITY = 0.8

const CONSENSUS_STEP = 0.15
const CONSENSUS_MAX_EXTRA = 3
const QUALITY_PRIOR_MEAN = 68
const ANILIST_PRIOR_VOTES = 3000
const TMDB_PRIOR_VOTES = 200
const QUALITY_FLOOR_SCORE = 55
const QUALITY_SPAN = 30
const UNKNOWN_AVERAGE_SCORE = 65
const FRESH_AIRING = 1.15
const FRESH_ANNOUNCED = 1.05
const POP_DAMP = 0.35
const POP_KNEE_LOG10 = 5.3
const SAME_WORLD = 0.85
/** Stands in for the missing quality signal on unmeasured TMDB rows only. */
const ERA_PRIOR = 0.85
const ERA_YEAR = 2010
const UNMEASURED = 0.5

const POOL_SIZE = 80
const MMR_LAMBDA = 0.5
const PER_SEED_CAP = 2
const JITTER = 0.12
const TV_SHARE_MIN = 0.2
const TV_SHARE_MAX = 0.5
const TV_CREDIBLE_RANK = 2
const VISIBLE = 4
const VISIBLE_HEAD = 8
const YESTERDAY_DAMP = 0.6

/** The only formats served: series. MOVIE / OVA / SPECIAL / MUSIC / TV_SHORT never are. */
const SERIES_FORMATS = new Set(['TV', 'ONA'])
const RELEASED_STATUSES = new Set(['FINISHED', 'RELEASING', 'HIATUS'])
/** TV genres that are not the kind of series this shelf recommends. */
const EXCLUDED_TV_GENRES = new Set(['Reality', 'Talk', 'News', 'Soap'])
/** TMDB's compound genres, split into the shared (AniList-shaped) taxonomy. */
const TMDB_SPLIT: Record<string, string[]> = {
  'Sci-Fi & Fantasy': ['Sci-Fi', 'Fantasy'],
  'Action & Adventure': ['Action', 'Adventure'],
  'War & Politics': ['War'],
  Animation: [],
  Family: ['Family'],
  Kids: ['Kids'],
}

// ---------------------------------------------------------------- input

/** One show in the user's library. */
export interface RankSeed {
  franchiseId: string
  title: string
  source: MediaSource
  status: WatchStatus
  genres: string[]
  /** Episodes watched across the main parts (seasons / ONAs). */
  watchedEpisodes: number
  /** Episodes aired across the main parts. */
  airedEpisodes: number
  /** A part of it is releasing now. */
  airing: boolean
  /** ms epoch: the last progress write, else when it was added. */
  lastActivityAt: number
  /** AniList media ids of its parts (empty for TV). */
  memberIds: number[]
  /** TMDB show id for a TV seed. */
  externalId: number | null
}

/** One entry of a seed's catalogue list. */
export interface RankEdge {
  seedId: string
  source: MediaSource
  externalId: number
  /** 0-based, strongest first. */
  rank: number
  /** AniList community votes; null for TMDB (rank only). */
  votes: number | null
}

/** The facts about one recommended title (a `recommendation_targets` row, resolved live). */
export interface RankTarget {
  source: MediaSource
  externalId: number
  /** Overrides `${source}:${rootId}` — e.g. a TMDB twin resolved to an AniList franchise. */
  key?: string
  /** The local franchise, resolved on read. */
  franchiseId: string | null
  title: string
  year: number | null
  images: ArtworkSet
  format: string | null
  status: string | null
  episodes: number | null
  /** 0–100 on both sources. */
  averageScore: number | null
  /** TMDB vote_count; null = unmeasured. */
  voteCount: number | null
  popularity: number | null
  genres: string[]
  isAdult: boolean
  countryOfOrigin: string | null
  airing: boolean
  announced: boolean
  /** YYYY-MM-DD (TMDB first air date). */
  releaseDate: string | null
  rootId: number
  rootTitle: string
  rootYear: number | null
  rootFormat: string | null
  rootEpisodes: number | null
  rootImages: ArtworkSet
  memberIds: number[]
  worldIds: number[]
}

/** What the refreshers write to `recommendation_targets` (resolution happens on read). */
export type RecommendationTargetFacts = Omit<RankTarget, 'franchiseId' | 'key'>
/** What the refreshers write to `recommendation_edges`, per seed. */
export type RecommendationEdgeFacts = Omit<RankEdge, 'seedId'>

export interface RankFeedback {
  key: string
  kind: RecommendationFeedbackKind
}

export interface RankInput {
  now: number
  seeds: RankSeed[]
  edges: RankEdge[]
  targets: RankTarget[]
  feedback: RankFeedback[]
}

export interface RankOptions {
  /** Seeds the daily rotation together with the UTC calendar day. */
  userId: string
  limit: number
  /**
   * false = the reference list: MMR order with no daily jitter and no visible draw (what the spike
   * printed). The API always rotates.
   */
  rotation?: boolean
  /**
   * The viewer's audience as a catalogue (services/audience.ts): only titles of this source are
   * candidates. Applied BEFORE selection, so a filtered list is still as full as the library
   * allows. null / absent = both catalogues, with the TV quota — today's list.
   */
  source?: MediaSource | null
}

// ---------------------------------------------------------------- output

export interface RankBreakdown {
  cf: number
  nSeeds: number
  consensus: number
  quality: number
  averageScore: number | null
  popularity: number | null
  fit: number
  fresh: number
  popDamp: number
  era: number
  sameWorld: string | null
  rel: number
  jitter: number
  contributions: { franchiseId: string; title: string; value: number }[]
}

export interface RankedRecommendation {
  key: string
  source: MediaSource
  externalId: number
  franchiseId: string | null
  title: string
  year: number | null
  images: ArtworkSet
  format: string | null
  episodes: number | null
  airing: boolean
  genres: string[]
  reason: RecommendationReason
  score: number
  breakdown: RankBreakdown
}

export interface RankResult {
  items: RankedRecommendation[]
  stats: {
    candidates: number
    /** Edges dropped by the hard filters, by class (owned, twin, format, unreleased, …). */
    excludedEdges: Record<string, number>
    /**
     * Whole candidates dropped: no show the user values votes for them (e.g. only a dropped one),
     * feedback, or — when the ranking is scoped to one catalogue — a title of the other one.
     */
    excludedCandidates: { unsupported: number; feedback: number; audience: number }
    tvShare: number
    tvQuota: number
    penalisedSeeds: string[]
  }
}

// ---------------------------------------------------------------- helpers

/** The spike's title normaliser: ASCII-folded, lower-case, "(…)" dropped, punctuation → spaces. */
export function normTitle(value: string | null | undefined): string {
  return (value ?? '')
    .normalize('NFKD')
    .replace(/[^\x00-\x7F]/g, '')
    .toLowerCase()
    .replace(/\(.*?\)/g, ' ')
    .replace(/[^a-z0-9]+/g, ' ')
    .trim()
}

/** Python's round(): halves go to the even neighbour (the spike's quota arithmetic). */
function roundHalfEven(x: number): number {
  return Math.abs(x % 1) === 0.5 ? 2 * Math.round(x / 2) : Math.round(x)
}

function clamp01(x: number): number {
  return Math.min(1, Math.max(0, x))
}

function round4(x: number): number {
  return Math.round(x * 10_000) / 10_000
}

function utcDay(ms: number): string {
  return new Date(ms).toISOString().slice(0, 10)
}

function hashBytes(value: string): Buffer {
  return createHash('sha256').update(value).digest()
}

/** Daily rotation: +/-12% seeded by (user, item, day) — reorders near-ties, never a strong item under a weak one. */
function dailyJitter(userId: string, key: string, day: string): number {
  return 1 + JITTER * (2 * (hashBytes(`${userId}:${key}:${day}`)[0]! / 255) - 1)
}

/** A deterministic uniform draw in [0, 1) for (user, day, n). */
function dailyDraw(userId: string, day: string, n: number): number {
  return hashBytes(`${userId}:${day}:draw:${n}`).readUInt32BE(0) / 2 ** 32
}

/** Genres in the shared taxonomy (TMDB's compound genres split, order kept, duplicates dropped). */
export function taxonomyGenres(source: MediaSource, genres: string[]): string[] {
  const out: string[] = []
  for (const genre of genres ?? []) {
    for (const g of source === 'tmdb' ? (TMDB_SPLIT[genre] ?? [genre]) : [genre]) {
      if (!out.includes(g)) out.push(g)
    }
  }
  return out
}

/** How much of a show was watched: one cour counts as fully engaged. */
export function seedEngagement(seed: Pick<RankSeed, 'watchedEpisodes' | 'airedEpisodes'>): number {
  const denominator = Math.max(1, Math.min(seed.airedEpisodes || FULL_ENGAGEMENT_EPISODES, FULL_ENGAGEMENT_EPISODES))
  return Math.min(1, seed.watchedEpisodes / denominator)
}

/** Section 2, step 1: the seed's weight before the dismissal penalty. */
export function seedAffinity(seed: RankSeed, now: number): number {
  const e = seedEngagement(seed)
  let a: number
  if (seed.status === 'planned') {
    // "Planned" with 57 episodes in is being watched: progress outranks the label.
    a = STATUS_BASE.planned + 0.6 * e
  } else if (seed.status === 'watching' || seed.status === 'completed') {
    a = STATUS_BASE[seed.status] * (0.7 + 0.3 * e)
  } else {
    a = STATUS_BASE[seed.status] ?? 0.3
  }
  const days = Math.max(0, (now - seed.lastActivityAt) / DAY_MS)
  return a * (1 + RECENCY_BOOST * Math.exp(-days / RECENCY_DAYS))
}

function isPlannedWithoutProgress(seed: RankSeed): boolean {
  return seed.status === 'planned' && seedEngagement(seed) < 0.3
}

function targetKey(target: RankTarget): string {
  return target.key ?? `${target.source}:${target.rootId}`
}

function tvUnreleased(target: RankTarget, today: string, year: number): boolean {
  if (target.releaseDate) return target.releaseDate.slice(0, 10) > today
  return target.year == null || target.year > year
}

// ---------------------------------------------------------------- candidates

interface WeightedEdge {
  edge: RankEdge
  target: RankTarget
  weight: number
}

interface Candidate {
  key: string
  source: MediaSource
  contrib: Map<string, number>
  edges: WeightedEdge[]
  title: string
  quality: number
  averageScore: number | null
  popularity: number | null
  genres: string[]
  fitRaw: number | null
  fit: number
  fresh: number
  popDamp: number
  era: number
  sameWorld: string | null
  nSeeds: number
  cf: number
  consensus: number
  rel: number
  display: Omit<RankedRecommendation, 'reason' | 'score' | 'breakdown' | 'key'>
  distribution: Map<string, number>
}

interface Context {
  now: number
  today: string
  year: number
  seeds: Map<string, RankSeed>
  ownedFranchiseIds: Set<string>
  ownedMembers: Set<number>
  memberToSeed: Map<number, string>
  ownedTmdb: Set<number>
  /** norm(title) → seed, in library order (the last seed wins a duplicate, as a dict would). */
  ownedTitles: Map<string, string>
  targets: Map<string, RankTarget>
  /** Edge weights: every seed spreads ONE vote over its whole stored list, junk included. */
  weights: Map<RankEdge, number>
}

/** Section 2, step 4 — the hard filters. Returns the junk class, or null for a usable edge. */
function exclusion(target: RankTarget, ctx: Context): string | null {
  if (target.franchiseId && ctx.ownedFranchiseIds.has(target.franchiseId)) return 'owned'
  if (target.source === 'anilist') {
    if (
      ctx.ownedMembers.has(target.externalId) ||
      ctx.ownedMembers.has(target.rootId) ||
      target.memberIds.some((id) => ctx.ownedMembers.has(id))
    ) return 'owned'
    if (target.isAdult || target.genres.includes('Hentai')) return 'adult'
    if (!target.format || !SERIES_FORMATS.has(target.format)) return 'format'
    if (!target.status || !RELEASED_STATUSES.has(target.status)) return 'unreleased'
    if (ctx.ownedTitles.has(normTitle(target.title)) || ctx.ownedTitles.has(normTitle(target.rootTitle))) return 'twin'
    return null
  }
  if (ctx.ownedTmdb.has(target.externalId)) return 'owned'
  if (ctx.ownedTitles.has(normTitle(target.title))) return 'twin'
  // Japanese animation belongs to AniList: its TMDB twin is never a TV recommendation.
  if (target.genres.includes('Animation') && target.countryOfOrigin === 'JP') return 'jp-animation'
  if (tvUnreleased(target, ctx.today, ctx.year)) return 'unreleased'
  if (target.isAdult) return 'adult'
  if (target.genres.some((genre) => EXCLUDED_TV_GENRES.has(genre))) return 'tv-genre'
  return null
}

function edgeWeights(edges: RankEdge[]): Map<RankEdge, number> {
  const bySeed = new Map<string, RankEdge[]>()
  for (const edge of edges) {
    const list = bySeed.get(edge.seedId) ?? []
    list.push(edge)
    bySeed.set(edge.seedId, list)
  }
  const weights = new Map<RankEdge, number>()
  for (const list of bySeed.values()) {
    if (list[0]!.source === 'anilist') {
      // Tempered share of the seed's vote x confidence in the pair (a 3-vote pair is noise).
      const total = list.reduce((sum, edge) => sum + Math.sqrt(Math.max(edge.votes ?? 0, 0)), 0) || 1
      for (const edge of list) {
        const v = Math.max(edge.votes ?? 0, 0)
        weights.set(edge, (Math.sqrt(v) / total) * (v / (v + ANILIST_VOTE_CONFIDENCE)))
      }
    } else {
      // Rank share x TMDB reliability (its lists are noisier than AniList's human picks).
      let total = 0
      for (let i = 0; i < list.length; i++) total += 1 / (i + 1) ** TMDB_RANK_DECAY
      for (const edge of list) weights.set(edge, ((1 / (edge.rank + 1) ** TMDB_RANK_DECAY) / total) * TMDB_RELIABILITY)
    }
  }
  return weights
}

function tasteProfile(seeds: RankSeed[], affinity: Map<string, number>): Map<string, number> {
  const profile = new Map<string, number>()
  for (const seed of seeds) {
    const a = affinity.get(seed.franchiseId) ?? 0
    if (a <= 0) continue
    const genres = taxonomyGenres(seed.source, seed.genres)
    for (const g of genres) profile.set(g, (profile.get(g) ?? 0) + a / genres.length)
  }
  let total = 0
  for (const v of profile.values()) total += v
  if (total > 0) for (const [g, v] of profile) profile.set(g, v / total)
  return profile
}

function sameWorldOf(key: string, first: RankTarget, ctx: Context): string | null {
  if (key.startsWith('tmdb:')) {
    const title = normTitle(first.title)
    for (const [owned, seedId] of ctx.ownedTitles) {
      if (owned.length > 5 && title.startsWith(`${owned} `)) return seedId
    }
    return null
  }
  for (const id of first.worldIds) {
    const seedId = ctx.memberToSeed.get(id)
    if (seedId) return seedId
  }
  return null
}

function pickImages(primary: ArtworkSet, fallback: ArtworkSet): ArtworkSet {
  return {
    portrait: primary.portrait ?? fallback.portrait ?? null,
    landscape: primary.landscape ?? fallback.landscape ?? null,
  }
}

function buildCandidates(input: RankInput, affinity: Map<string, number>, ctx: Context): {
  candidates: Candidate[]
  excluded: Record<string, number>
  unsupported: number
} {
  const excluded: Record<string, number> = {}
  let unsupported = 0
  const byKey = new Map<string, Candidate>()
  for (const edge of input.edges) {
    const a = affinity.get(edge.seedId)
    const target = ctx.targets.get(`${edge.source}:${edge.externalId}`)
    if (a === undefined || !target) continue
    const why = exclusion(target, ctx)
    if (why) {
      excluded[why] = (excluded[why] ?? 0) + 1
      continue
    }
    const key = targetKey(target)
    let c = byKey.get(key)
    if (!c) {
      c = { key, source: key.startsWith('tmdb:') ? 'tmdb' : 'anilist', contrib: new Map(), edges: [] } as unknown as Candidate
      byKey.set(key, c)
    }
    const weight = ctx.weights.get(edge) ?? 0
    c.contrib.set(edge.seedId, (c.contrib.get(edge.seedId) ?? 0) + a * weight)
    c.edges.push({ edge, target, weight })
  }

  const profile = tasteProfile(input.seeds, affinity)
  const candidates = [...byKey.values()]
  for (const c of candidates) features(c, profile, ctx)
  let fitMax = 0
  for (const c of candidates) if (c.fitRaw != null && c.fitRaw > fitMax) fitMax = c.fitRaw
  const kept: Candidate[] = []
  for (const c of candidates) {
    c.fit = c.fitRaw == null || fitMax <= 0 ? UNMEASURED : c.fitRaw / fitMax
    let cf = 0
    let nSeeds = 0
    for (const v of c.contrib.values()) {
      if (v === 0) continue
      cf += v
      if (v > 0) nSeeds++
    }
    c.cf = cf
    c.nSeeds = nSeeds
    c.consensus = 1 + CONSENSUS_STEP * Math.min(CONSENSUS_MAX_EXTRA, Math.max(0, nSeeds - 1))
    c.sameWorld = sameWorldOf(c.key, c.edges[0]!.target, ctx)
    c.rel = c.cf * c.consensus * (0.6 + 0.4 * c.quality) * (0.7 + 0.6 * c.fit) *
      c.fresh * c.popDamp * c.era * (c.sameWorld ? SAME_WORLD : 1.0)
    // A title only a dropped show points at is gone, not merely ranked low.
    if (c.nSeeds === 0 || c.cf <= 0) {
      unsupported++
      continue
    }
    const positive = [...c.contrib].filter(([, v]) => v > 0)
    const total = positive.reduce((sum, [, v]) => sum + v, 0) || 1
    c.distribution = new Map(positive.map(([seedId, v]) => [seedId, v / total]))
    kept.push(c)
  }
  return { candidates: kept, excluded, unsupported }
}

function features(c: Candidate, profile: Map<string, number>, ctx: Context): void {
  const aniList = c.edges.map((x) => x.target).filter((t) => t.source === 'anilist')
  const first = c.edges[0]!.target
  if (aniList.length > 0) {
    // The work's facts: the most popular recommended entry. The name and art: its series root.
    let best = aniList[0]!
    for (const t of aniList) if ((t.popularity || 0) > (best.popularity || 0)) best = t
    const lead = first.source === 'anilist' ? first : best
    const avg = best.averageScore || UNKNOWN_AVERAGE_SCORE
    const pop = best.popularity || 0
    const bayes = (pop * avg + ANILIST_PRIOR_VOTES * QUALITY_PRIOR_MEAN) / (pop + ANILIST_PRIOR_VOTES)
    const genres = [...new Set(best.genres)]
    const airing = aniList.some((t) => t.status === 'RELEASING' && !!t.format && SERIES_FORMATS.has(t.format))
    c.title = lead.rootTitle
    c.quality = clamp01((bayes - QUALITY_FLOOR_SCORE) / QUALITY_SPAN)
    c.averageScore = avg
    c.popularity = pop
    c.genres = genres
    c.fitRaw = genres.reduce((sum, g) => sum + (profile.get(g) ?? 0), 0) / Math.max(1, genres.length)
    c.fresh = airing ? FRESH_AIRING : lead.announced ? FRESH_ANNOUNCED : 1.0
    c.popDamp = 1 / (1 + POP_DAMP * Math.max(0, Math.log10(Math.max(pop, 1)) - POP_KNEE_LOG10))
    c.era = 1.0
    c.display = {
      source: 'anilist',
      externalId: 0,
      franchiseId: c.edges.find((x) => x.target.franchiseId)?.target.franchiseId ?? null,
      title: lead.rootTitle,
      year: lead.rootYear ?? best.year,
      images: pickImages(lead.rootImages, pickImages(lead.images, best.images)),
      format: lead.rootFormat && SERIES_FORMATS.has(lead.rootFormat) ? lead.rootFormat : best.format,
      episodes: lead.rootEpisodes ?? best.episodes,
      // Only a series-format entry on air makes the title "Airing now" (review i5, F7).
      airing: aniList.some((t) => t.airing && !!t.format && SERIES_FORMATS.has(t.format)),
      genres: best.genres.slice(0, 4),
    }
  } else {
    const t = first
    const measured = t.voteCount != null && t.averageScore != null
    const genres = taxonomyGenres('tmdb', t.genres)
    c.title = t.title
    c.averageScore = t.averageScore
    c.popularity = t.popularity
    if (measured) {
      const n = t.voteCount!
      const bayes = (n * t.averageScore! + TMDB_PRIOR_VOTES * QUALITY_PRIOR_MEAN) / (n + TMDB_PRIOR_VOTES)
      c.quality = clamp01((bayes - QUALITY_FLOOR_SCORE) / QUALITY_SPAN)
      c.era = 1.0
    } else {
      c.quality = UNMEASURED
      c.era = (t.year || ctx.year) < ERA_YEAR ? ERA_PRIOR : 1.0
    }
    c.genres = genres
    c.fitRaw = genres.length ? genres.reduce((sum, g) => sum + (profile.get(g) ?? 0), 0) / genres.length : null
    c.fresh = t.airing ? FRESH_AIRING : t.announced ? FRESH_ANNOUNCED : 1.0
    c.popDamp = 1.0
    c.display = {
      source: 'tmdb',
      externalId: 0,
      franchiseId: c.edges.find((x) => x.target.franchiseId)?.target.franchiseId ?? null,
      title: t.title,
      year: t.year,
      images: pickImages(t.images, t.rootImages),
      format: 'TV',
      episodes: t.episodes,
      airing: t.airing,
      genres: t.genres.slice(0, 4),
    }
  }
  const [source, id] = c.key.split(':')
  c.display.source = source === 'tmdb' ? 'tmdb' : 'anilist'
  c.display.externalId = Number(id)
}

/** The seed with the largest contribution (the first one on a tie, as Counter.most_common). */
function primarySeed(c: Candidate): string {
  let best = ''
  let bestValue = -Infinity
  for (const [seedId, v] of c.contrib) {
    if (v > bestValue) {
      best = seedId
      bestValue = v
    }
  }
  return best
}

/** Every identity a recommendation answers to, so feedback survives a key drifting to a root. */
function identities(c: Candidate): Set<string> {
  const out = new Set<string>([c.key])
  for (const { target } of c.edges) {
    out.add(`${target.source}:${target.externalId}`)
    out.add(`${target.source}:${target.rootId}`)
    if (target.source === 'anilist') for (const id of target.memberIds) out.add(`anilist:${id}`)
  }
  return out
}

// ---------------------------------------------------------------- selection

function similarity(a: Candidate, b: Candidate): number {
  let s = 0
  for (const [seedId, share] of a.distribution) s += Math.min(share, b.distribution.get(seedId) ?? 0)
  s *= 0.6
  if (a.genres.length && b.genres.length) {
    const bSet = new Set(b.genres)
    const union = new Set([...a.genres, ...b.genres])
    let shared = 0
    for (const g of new Set(a.genres)) if (bSet.has(g)) shared++
    s += (0.4 * shared) / union.size
  } else if (a.source === 'tmdb' && b.source === 'tmdb') {
    s += 0.1
  }
  return s
}

function tvCredible(c: Candidate): boolean {
  return c.source === 'tmdb' && (c.nSeeds >= 2 || Math.min(...c.edges.map((x) => x.edge.rank)) <= TV_CREDIBLE_RANK)
}

function mmrSelect(
  candidates: Candidate[],
  limit: number,
  quota: number,
  scoreOf: (c: Candidate) => number,
): Candidate[] {
  const pool = [...candidates].sort((a, b) => b.rel - a.rel).slice(0, POOL_SIZE)
  const scores = new Map(pool.map((c) => [c, scoreOf(c)]))
  const chosen: Candidate[] = []
  const perSeed = new Map<string, number>()
  while (chosen.length < limit && pool.length > 0) {
    const tvChosen = chosen.filter((c) => c.source === 'tmdb').length
    const needTv = quota - tvChosen
    const slotsLeft = limit - chosen.length
    let best: Candidate | null = null
    let bestScore = -1e9
    for (const c of pool) {
      if ((perSeed.get(primarySeed(c)) ?? 0) >= PER_SEED_CAP) continue
      if (c.sameWorld && chosen.some((x) => x.sameWorld)) continue
      if (needTv >= slotsLeft && !tvCredible(c)) continue
      // A TV title inside the first 4 whenever the library has TV shows.
      if (quota && chosen.length === VISIBLE - 1 && tvChosen === 0 && !tvCredible(c)) continue
      let redundancy = 0
      for (const s of chosen) redundancy = Math.max(redundancy, similarity(c, s))
      const score = scores.get(c)! * (1 - MMR_LAMBDA * redundancy)
      if (score > bestScore) {
        best = c
        bestScore = score
      }
    }
    if (!best) break
    chosen.push(best)
    const seedId = primarySeed(best)
    perSeed.set(seedId, (perSeed.get(seedId) ?? 0) + 1)
    pool.splice(pool.indexOf(best), 1)
  }
  return chosen
}

/**
 * The 4 visible tiles are a seeded weighted draw from the top 8 (yesterday's four count x0.6), so
 * the shelf a person actually sees changes day to day; the rest keeps MMR order.
 */
function visibleDraw(list: Candidate[], userId: string, day: string, yesterday: Set<string>): Candidate[] {
  const head = list.slice(0, VISIBLE_HEAD)
  const weight = new Map(head.map((c) => [c, c.rel * (yesterday.has(c.key) ? YESTERDAY_DAMP : 1)]))
  const first: Candidate[] = []
  const pool = [...head]
  let draw = 0
  while (first.length < VISIBLE && pool.length > 0) {
    const needTv =
      first.length === VISIBLE - 1 && !first.some((c) => c.source === 'tmdb') && pool.some((c) => c.source === 'tmdb')
    const eligible = pool.filter((c) => c.source === 'tmdb' || !needTv)
    const total = eligible.reduce((sum, c) => sum + weight.get(c)!, 0)
    let r = dailyDraw(userId, day, draw++) * total
    let pick = eligible[eligible.length - 1]!
    for (const c of eligible) {
      r -= weight.get(c)!
      if (r <= 0) {
        pick = c
        break
      }
    }
    first.push(pick)
    pool.splice(pool.indexOf(pick), 1)
  }
  return [...first, ...list.filter((c) => !first.includes(c))]
}

// ---------------------------------------------------------------- reasons

/** Up to this many of the user's shows ride along with a consensus reason. */
const REASON_SEEDS = 3

function reasonFor(c: Candidate, ctx: Context): RecommendationReason {
  const ref = (seedId: string) => ({ franchiseId: seedId, title: displayTitle(ctx.seeds.get(seedId)!.title) })
  if (c.sameWorld) return { kind: 'world', seeds: [ref(c.sameWorld)], count: Math.max(1, c.nSeeds) }

  // The user's shows behind the title, strongest vote for it first. The client names one or two of
  // them by Today's state (a Watching show on a new-episode day, a finished one when caught up), so
  // a consensus carries up to three. One honesty rule survives here: a Planned show with no
  // progress never leads while another show qualifies.
  const quiet = (seedId: string) => isPlannedWithoutProgress(ctx.seeds.get(seedId)!)
  const ranked = [...c.contrib]
    .filter(([, v]) => v > 0)
    .sort((a, b) => b[1] - a[1])
    .map(([seedId]) => seedId)
    .sort((a, b) => Number(quiet(a)) - Number(quiet(b)))
  const lead = ranked[0]!
  if (ranked.length >= 2) {
    return { kind: 'consensus', seeds: ranked.slice(0, REASON_SEEDS).map(ref), count: ranked.length }
  }
  const seed = ctx.seeds.get(lead)!
  const e = seedEngagement(seed)
  let kind: RecommendationReasonKind
  if (seed.status !== 'completed' && seed.status !== 'watching' && e >= 0.9 && !seed.airing) kind = 'watched'
  else if (seed.status === 'completed') kind = 'finished'
  else if (seed.status === 'watching' || (seed.status === 'planned' && e >= 0.3)) kind = 'watching'
  else kind = 'planned'
  return { kind, seeds: [ref(lead)], count: 1 }
}

// ---------------------------------------------------------------- entry point

function context(input: RankInput): Context {
  const seeds = new Map(input.seeds.map((seed) => [seed.franchiseId, seed]))
  const memberToSeed = new Map<number, string>()
  const ownedTitles = new Map<string, string>()
  for (const seed of input.seeds) {
    if (seed.source === 'anilist') for (const id of seed.memberIds) memberToSeed.set(id, seed.franchiseId)
    ownedTitles.set(normTitle(seed.title), seed.franchiseId)
  }
  return {
    now: input.now,
    today: utcDay(input.now),
    year: new Date(input.now).getUTCFullYear(),
    seeds,
    ownedFranchiseIds: new Set(seeds.keys()),
    ownedMembers: new Set(memberToSeed.keys()),
    memberToSeed,
    ownedTmdb: new Set(
      input.seeds.filter((s) => s.source === 'tmdb' && s.externalId != null).map((s) => s.externalId!),
    ),
    ownedTitles,
    targets: new Map(input.targets.map((t) => [`${t.source}:${t.externalId}`, t])),
    weights: edgeWeights(input.edges),
  }
}

/**
 * Rank second-degree recommendations for one user. Pure: the same input, user and UTC day always
 * give the same list. The loader (`getRecommendations`) supplies live ownership and feedback.
 */
export function rankRecommendations(input: RankInput, options: RankOptions): RankResult {
  const limit = Math.max(0, Math.floor(options.limit))
  const rotation = options.rotation !== false
  const ctx = context(input)
  const empty: RankResult = {
    items: [],
    stats: {
      candidates: 0,
      excludedEdges: {},
      excludedCandidates: { unsupported: 0, feedback: 0, audience: 0 },
      tvShare: 0,
      tvQuota: 0,
      penalisedSeeds: [],
    },
  }
  if (limit === 0 || input.seeds.length === 0) return empty

  const affinity = new Map(input.seeds.map((seed) => [seed.franchiseId, seedAffinity(seed, input.now)]))
  const blocked = new Set(input.feedback.map((f) => f.key))

  // Dismissals teach: a show that was the main reason for >= 3 dismissed titles counts half.
  let built = buildCandidates(input, affinity, ctx)
  const dismissed = input.feedback.filter((f) => f.kind === 'dismissed').map((f) => f.key)
  const penalised: string[] = []
  if (dismissed.length >= DISMISS_THRESHOLD) {
    const blame = new Map<string, number>()
    for (const c of built.candidates) {
      const ids = identities(c)
      const hits = dismissed.filter((key) => ids.has(key)).length
      if (hits > 0) {
        const seedId = primarySeed(c)
        blame.set(seedId, (blame.get(seedId) ?? 0) + hits)
      }
    }
    for (const [seedId, n] of blame) {
      if (n < DISMISS_THRESHOLD) continue
      penalised.push(seedId)
      affinity.set(seedId, affinity.get(seedId)! * DISMISS_PENALTY)
    }
    if (penalised.length > 0) built = buildCandidates(input, affinity, ctx)
  }
  const unblocked = built.candidates.filter((c) => {
    for (const id of identities(c)) if (blocked.has(id)) return false
    return true
  })
  // The audience: one catalogue's titles only. Here, before the quota and the selection, so the
  // list fills up from what is left instead of being cut short after the fact.
  const candidates = options.source ? unblocked.filter((c) => c.source === options.source) : unblocked
  const excludedEdges = built.excluded
  const excludedCandidates = {
    unsupported: built.unsupported,
    feedback: built.candidates.length - unblocked.length,
    audience: unblocked.length - candidates.length,
  }

  let affAll = 0
  let affTv = 0
  for (const seed of input.seeds) {
    const a = affinity.get(seed.franchiseId)!
    if (a <= 0) continue
    affAll += a
    if (seed.source === 'tmdb') affTv += a
  }
  if (affAll <= 0) {
    return { ...empty, stats: { ...empty.stats, excludedEdges, excludedCandidates, penalisedSeeds: penalised } }
  }
  const tvShare = Math.min(TV_SHARE_MAX, Math.max(TV_SHARE_MIN, affTv / affAll))
  const credibleTv = candidates.filter(tvCredible).length
  const quota = affTv > 0 ? Math.min(roundHalfEven(limit * tvShare), credibleTv) : 0

  const today = utcDay(input.now)
  let list: Candidate[]
  const jitters = new Map<Candidate, number>()
  if (rotation) {
    const yesterdayDay = utcDay(input.now - DAY_MS)
    const yesterdayList = mmrSelect(candidates, limit, quota, (c) => c.rel * dailyJitter(options.userId, c.key, yesterdayDay))
    const yesterdayFour = new Set(visibleDraw(yesterdayList, options.userId, yesterdayDay, new Set()).slice(0, VISIBLE).map((c) => c.key))
    for (const c of candidates) jitters.set(c, dailyJitter(options.userId, c.key, today))
    list = visibleDraw(mmrSelect(candidates, limit, quota, (c) => c.rel * jitters.get(c)!), options.userId, today, yesterdayFour)
  } else {
    list = mmrSelect(candidates, limit, quota, (c) => c.rel)
  }

  const items = list.map((c): RankedRecommendation => ({
    key: c.key,
    ...c.display,
    reason: reasonFor(c, ctx),
    score: round4(c.rel),
    breakdown: {
      cf: round4(c.cf),
      nSeeds: c.nSeeds,
      consensus: round4(c.consensus),
      quality: round4(c.quality),
      averageScore: c.averageScore,
      popularity: c.popularity,
      fit: round4(c.fit),
      fresh: c.fresh,
      popDamp: round4(c.popDamp),
      era: c.era,
      sameWorld: c.sameWorld,
      rel: round4(c.rel),
      jitter: round4(jitters.get(c) ?? 1),
      contributions: [...c.contrib]
        .sort((a, b) => b[1] - a[1])
        .map(([seedId, value]) => ({ franchiseId: seedId, title: ctx.seeds.get(seedId)!.title, value: round4(value) })),
    },
  }))
  return {
    items,
    stats: {
      candidates: candidates.length,
      excludedEdges,
      excludedCandidates,
      tvShare: round4(tvShare),
      tvQuota: quota,
      penalisedSeeds: penalised,
    },
  }
}
