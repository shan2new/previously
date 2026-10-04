import { seedEngagement, taxonomyGenres, type RankSeed } from '../services/recommendationRank.js'
import type { ArtworkGallery, FeedPostContext, FeedTime, MediaSource, RecommendationReason } from '../types/api.js'
import { compareText } from './compose.js'

// For you's order (docs/api-contract.md, "Today feed"): the candidates — news about trending shows
// and about the shows the recommender picks out of the viewer's library — ranked for ONE viewer, and
// the reason each post is there. Pure and deterministic given `nowMs`: nothing in here reads the
// clock, the database or the recommender (feed/service.ts loads all three).
//
//   1 AFFINITY   a recommended show: 0.7–1.0 by its place in the recommender's list; any other
//                show: 0.6 x how well its genres match the viewer's library (`tasteMatch`).
//   2 RECENCY    the news halves in value every 45 days. A pick's discovery trailer (EVERGREEN:
//                a trailer is new to someone who has not seen the show) holds at 0.6 instead, so
//                fresh news about the pick still outranks its old trailer and trailers mix with
//                the week's news rather than fill the list.
//   3 SCORE      0.5 x affinity + 0.5 x recency; then newest, then id. Even weights: a pick's
//                two-year-old rumour must not sit above this week's news about a show in the
//                viewer's genres (at 0.65 / 0.35 a 743-day-old post ranked eighth on a real library).
//   4 FLOOR      left out: a show the recommender did not pick and whose genres the library barely
//                touches; anything older than eight months (news about a show the viewer does not
//                follow has gone stale by then — an evergreen trailer excepted); and a post with
//                nothing worth looking at (no video and no sharp picture: with 20 slots a 460-px
//                cover blown up to a poster is not a post) — unless that would leave fewer than 20
//                posts.
//   5 DIVERSITY  never the same show twice in a row while another remains; one post per show in
//                the first 20 — the whole feed, so it is 20 different shows where it can be.
//   6 CONTEXT    why: the recommender's reason, or the one or two genres that matched.
//
// A viewer the library says nothing about (empty, or only dropped shows) gets the feed everyone
// got before this file existed: newest first, no context, nothing left out.
//
// The weights are hand-set (no usage logs to learn from yet); `forYou.test.ts` pins the behaviour.

const DAY_MS = 86_400_000

export const FOR_YOU_RANK = {
  affinityWeight: 0.5,
  recencyWeight: 0.5,
  /** News halves in value over this many days. */
  halfLifeDays: 45,
  /** Older than this, a post is left out (the floor's refill may bring it back). */
  maxAgeDays: 240,
  /**
   * An evergreen post's recency, whatever its age: what news 33 days old is worth, so a pick's
   * fresher news leads its trailer and week-old news about a show in the viewer's genres can too.
   */
  evergreenRecency: 0.6,
  /** A picture measured at this width or more fills the feed's media slot without blur. */
  sharpWidth: 1000,
  /** The recommender's last pick; its first is worth 1. */
  recommendedBase: 0.7,
  /** The most a genre match alone is worth: always under a recommendation. */
  tasteCeiling: 0.6,
  /** A show's best-matching genres that make its taste match. */
  tasteGenres: 3,
  /** Under this match a show the recommender did not pick is not for this viewer. */
  tasteFloor: 0.15,
  /**
   * From this match the post says which of the viewer's genres it met. High: on an Action/Fantasy
   * library 0.35 labelled three posts in four, and a line on every post explains nothing.
   */
  tasteContext: 0.6,
  /** Genres a `taste` context names. */
  contextGenres: 2,
  /** The floor never leaves fewer posts than this while candidates remain. */
  minPosts: 20,
  /** The stretch of the feed held to `perFranchise` posts per show: all of it (the cap is 20). */
  head: 20,
  perFranchise: 1,
} as const

// ---------- Inputs ----------

/** What the ranking reads of a post. */
export interface ForYouCandidate {
  id: string
  franchiseId: string
  time: FeedTime
  /** It has something worth looking at: a video, or a picture that is sharp at feed size (`isSharp`). */
  sharp: boolean
  /** A recommended show's discovery trailer: never stale, and its recency does not decay. */
  evergreen?: boolean
}

/** What the taste match reads of a show (a `Franchise` satisfies it). */
export interface TasteFranchise {
  source: MediaSource
  genres: string[]
}

/** What the taste profile reads of a library show (a `RankSeed` satisfies it). */
export type TasteSeed = Pick<RankSeed, 'source' | 'status' | 'genres' | 'watchedEpisodes' | 'airedEpisodes'>

/** One of the recommender's picks that has a show page. */
export interface ForYouPick {
  franchiseId: string
  reason: RecommendationReason
}

export interface ForYouInput<T extends ForYouCandidate> {
  /** The candidates, already without the viewer's own, muted and hidden ones. */
  posts: readonly T[]
  /** The shows the posts are about, by franchise id. A show missing here matches no taste. */
  franchises: ReadonlyMap<string, TasteFranchise>
  /** The recommender's list for this viewer, strongest first. */
  recommended: readonly ForYouPick[]
  /** The viewer's library. */
  seeds: readonly TasteSeed[]
  nowMs: number
}

export type ForYouPost<T> = T & { context: FeedPostContext | null }

// ---------- Taste ----------

/**
 * How much one library show says about the viewer's taste: what they watched counts by how much of
 * it they watched (one cour = all of it, `seedEngagement`; never under 0.3 — finishing or following
 * a show is itself a statement), a paused show half, a planned one a little less, a dropped one
 * nothing.
 */
function seedWeight(seed: TasteSeed): number {
  switch (seed.status) {
    case 'completed':
    case 'watching':
      return Math.max(0.3, seedEngagement(seed))
    case 'paused':
      return 0.5
    case 'planned':
      return 0.4
    case 'dropped':
      return 0
  }
}

/**
 * The viewer's genres in the shared taxonomy (`taxonomyGenres`: TMDB's compound genres split), each
 * the sum of the weights of the library shows carrying it, scaled so the strongest is 1. Empty when
 * the library says nothing (no shows, only dropped ones, or none with a genre).
 */
export function tasteProfile(seeds: readonly TasteSeed[]): Map<string, number> {
  const profile = new Map<string, number>()
  for (const seed of seeds) {
    const weight = seedWeight(seed)
    if (weight <= 0) continue
    for (const genre of taxonomyGenres(seed.source, seed.genres)) profile.set(genre, (profile.get(genre) ?? 0) + weight)
  }
  let strongest = 0
  for (const value of profile.values()) if (value > strongest) strongest = value
  if (strongest > 0) for (const [genre, value] of profile) profile.set(genre, value / strongest)
  return profile
}

export interface TasteMatch {
  /** 0–1: the mean profile weight of the show's (up to three) best-matching genres. */
  match: number
  /** The show's genres the viewer has, the viewer's strongest first (at most two). */
  genres: string[]
}

/** How well a show's genres meet the profile. A show with no genres matches nothing. */
export function tasteMatch(profile: ReadonlyMap<string, number>, franchise: TasteFranchise | undefined): TasteMatch {
  const weighted = (franchise ? taxonomyGenres(franchise.source, franchise.genres) : [])
    .map((genre) => ({ genre, weight: profile.get(genre) ?? 0 }))
    // Stable: genres of equal weight keep the catalogue's order.
    .sort((a, b) => b.weight - a.weight)
  const best = weighted.slice(0, FOR_YOU_RANK.tasteGenres)
  if (best.length === 0) return { match: 0, genres: [] }
  return {
    match: best.reduce((sum, entry) => sum + entry.weight, 0) / best.length,
    genres: best.filter((entry) => entry.weight > 0).slice(0, FOR_YOU_RANK.contextGenres).map((entry) => entry.genre),
  }
}

/** 1 for news from now (or dated ahead of it), halving every `halfLifeDays`. */
export function recency(at: number, nowMs: number): number {
  const ageDays = Math.max(0, nowMs - at) / DAY_MS
  return 0.5 ** (ageDays / FOR_YOU_RANK.halfLifeDays)
}

// ---------- Something to look at ----------

/**
 * A gallery holds a picture that is sharp at feed size: one the catalogue MEASURED at `sharpWidth`
 * or more. Most TMDB entries are measured; one that is not (the poster and backdrop a TV show is
 * stored with before enrichment measures its gallery) counts on its source — TMDB serves those from
 * originals far past the bar. An AniList cover (460 px) or banner is never measured and never sharp.
 */
function hasSharpArt(gallery: ArtworkGallery | null | undefined): boolean {
  if (!gallery) return false
  return [...(gallery.portraits ?? []), ...(gallery.landscapes ?? [])].some((image) =>
    image.width != null ? image.width >= FOR_YOU_RANK.sharpWidth : image.source === 'tmdb',
  )
}

/**
 * Whether a post has something worth looking at (the candidate's `sharp`): its video — the video's
 * still is the picture — or a sharp picture of its part or of its show. The selected `images` are
 * the galleries' own entries, so the galleries are all that is read.
 */
export function isSharp(
  post: { video: unknown; part: { artwork: ArtworkGallery } | null },
  franchise: { artwork: ArtworkGallery } | undefined,
): boolean {
  return post.video != null || hasSharpArt(post.part?.artwork) || hasSharpArt(franchise?.artwork)
}

// ---------- Ranking ----------

interface Scored<T> {
  post: T
  score: number
  recommended: boolean
  match: number
  /** Older than `maxAgeDays`, and not evergreen. */
  stale: boolean
  context: FeedPostContext | null
}

function byScore<T extends ForYouCandidate>(a: Scored<T>, b: Scored<T>): number {
  return b.score - a.score || b.post.time.at - a.post.time.at || compareText(a.post.id, b.post.id)
}

/**
 * The recommender's picks that have a candidate post, each with its 0-based place AMONG THOSE — a
 * pick with no news takes no place, so the first show that posted is the first, whatever sat above
 * it. A show listed twice keeps its first (stronger) place.
 */
function placedPicks(
  posts: readonly ForYouCandidate[],
  recommended: readonly ForYouPick[],
): Map<string, { place: number; reason: RecommendationReason }> {
  const posting = new Set(posts.map((post) => post.franchiseId))
  const placed = new Map<string, { place: number; reason: RecommendationReason }>()
  for (const pick of recommended) {
    if (!posting.has(pick.franchiseId) || placed.has(pick.franchiseId)) continue
    placed.set(pick.franchiseId, { place: placed.size, reason: pick.reason })
  }
  return placed
}

/**
 * The diversity pass over a best-first list: each slot takes the best remaining post that is not
 * about the show just placed and, inside the head, whose show has not had its one. When only
 * capped shows remain the cap gives way before the no-repeat rule does; when one show remains its
 * posts follow each other. A post passed over is only deferred, never lost.
 */
function diversify<T extends ForYouCandidate>(sorted: readonly Scored<T>[]): Scored<T>[] {
  const pending = [...sorted]
  const out: Scored<T>[] = []
  const placed = new Map<string, number>()
  while (pending.length > 0) {
    const last = out.at(-1)?.post.franchiseId
    const inHead = out.length < FOR_YOU_RANK.head
    const repeats = (s: Scored<T>) => s.post.franchiseId === last
    const capped = (s: Scored<T>) => inHead && (placed.get(s.post.franchiseId) ?? 0) >= FOR_YOU_RANK.perFranchise
    let index = pending.findIndex((s) => !repeats(s) && !capped(s))
    if (index < 0) index = pending.findIndex((s) => !repeats(s))
    if (index < 0) index = 0
    const [next] = pending.splice(index, 1)
    out.push(next!)
    placed.set(next!.post.franchiseId, (placed.get(next!.post.franchiseId) ?? 0) + 1)
  }
  return out
}

/**
 * For you for one viewer: the candidates in the order to show them (the caller caps the list), each
 * with its context. Posts the floor leaves out are simply absent.
 */
export function rankForYou<T extends ForYouCandidate>(input: ForYouInput<T>): ForYouPost<T>[] {
  const profile = tasteProfile(input.seeds)
  const picks = placedPicks(input.posts, input.recommended)
  if (profile.size === 0 && picks.size === 0) {
    // Nothing personal to rank by: the feed as it was — newest first, then id, no context.
    return [...input.posts]
      .sort((a, b) => b.time.at - a.time.at || compareText(a.id, b.id))
      .map((post) => ({ ...post, context: null }))
  }

  const span = Math.max(1, picks.size - 1)
  const tastes = new Map<string, TasteMatch>()
  const scored = input.posts.map((post): Scored<T> => {
    const pick = picks.get(post.franchiseId)
    let affinity: number
    let match = 0
    let context: FeedPostContext | null = null
    if (pick) {
      affinity = FOR_YOU_RANK.recommendedBase + (1 - FOR_YOU_RANK.recommendedBase) * (1 - pick.place / span)
      context = { kind: 'recommended', reason: pick.reason }
    } else {
      let taste = tastes.get(post.franchiseId)
      if (!taste) {
        taste = tasteMatch(profile, input.franchises.get(post.franchiseId))
        tastes.set(post.franchiseId, taste)
      }
      match = taste.match
      affinity = FOR_YOU_RANK.tasteCeiling * match
      if (match >= FOR_YOU_RANK.tasteContext && taste.genres.length > 0) context = { kind: 'taste', genres: taste.genres }
    }
    const evergreen = post.evergreen === true
    // Evergreen: never less than a recent post would get, never decaying under the constant.
    const fresh = recency(post.time.at, input.nowMs)
    const score =
      FOR_YOU_RANK.affinityWeight * affinity +
      FOR_YOU_RANK.recencyWeight * (evergreen ? Math.max(FOR_YOU_RANK.evergreenRecency, fresh) : fresh)
    const stale = !evergreen && input.nowMs - post.time.at > FOR_YOU_RANK.maxAgeDays * DAY_MS
    return { post, score, recommended: pick != null, match, stale, context }
  })

  // The taste floor needs a profile to measure against: with none (a library whose shows carry no
  // genres) every match is 0 and says nothing, so nothing is left out on its account. Age and the
  // picture need nothing: stale is stale and blurred is blurred, a pick's included.
  const fits = (s: Scored<T>): boolean =>
    !s.stale && s.post.sharp && (s.recommended || profile.size === 0 || s.match >= FOR_YOU_RANK.tasteFloor)
  let kept = scored.filter(fits)
  if (kept.length < FOR_YOU_RANK.minPosts) {
    const refill = scored
      .filter((s) => !fits(s))
      .sort(byScore)
      .slice(0, FOR_YOU_RANK.minPosts - kept.length)
    kept = [...kept, ...refill]
  }

  return diversify([...kept].sort(byScore)).map((s) => ({ ...s.post, context: s.context }))
}
