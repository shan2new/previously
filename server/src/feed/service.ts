import { asc, desc, eq } from 'drizzle-orm'
import { db } from '../db/index.js'
import { announcements, franchiseMember, reminders, saves, subscriptions } from '../db/schema.js'
import { env } from '../env.js'
import { announcementForPart } from '../news/installment.js'
import { inAudience, resolveAudience, sourceFor } from '../services/audience.js'
import { getFeedFranchises, getSummaries, trendingFranchiseIds } from '../services/franchiseView.js'
import { rankRecommendations, type RankSeed } from '../services/recommendationRank.js'
import { loadRankInput } from '../services/recommendations.js'
import { consumerFranchiseIds } from '../services/consumerContent.js'
import { clientAnchor, readVisitAnchors } from '../services/visits.js'
import { formatSubject, parseSubject } from '../social/subjects.js'
import type {
  FeedCapabilities,
  FeedFranchise,
  FeedPost,
  FeedPostContext,
  FeedPostDetailResponse,
  FeedResponse,
  FeedTab,
  Franchise,
  FranchiseSummary,
  MediaSource,
  RemindersResponse,
  SavedResponse,
  WatchStatus,
} from '../types/api.js'
import {
  composePostById,
  composePosts,
  discoveryTrailer,
  orderPosts,
  toFeedFranchise,
  type ComposeByIdOptions,
  type ComposedPost,
  type ComposeInput,
} from './compose.js'
import { isSharp, rankForYou, type ForYouPick, type TasteFranchise } from './forYou.js'
import { loadResearchHistory } from './history.js'
import { storyline, threadSources } from './storyline.js'
import { emptyPostSocial, firstActivityAt, loadHides, loadPostSocial, type PostSocial } from './viewerState.js'

// The Today feed's IO (docs/api-contract.md, "Today feed"): load, compose (feed/compose.ts, pure),
// rank For you for the viewer (feed/forYou.ts, pure), apply the viewer's hides and social state.
// The feed never enqueues research (D15): research runs on a personal subscription, so feed traffic
// must not spend it — and For you reads the recommender without its materialisation queue.
//
// For you only ever suggests titles of the viewer's AUDIENCE (services/audience.ts): its trending
// pool, the recommender's picks and the Trending module are all of one catalogue for an anime or a
// TV viewer. Following is the viewer's own library and is never filtered.

/** Feed sizes are code constants, not env (spec §8). */
export const FEED_LIMITS = {
  following: 200,
  /** Short on purpose: twenty posts worth looking at, one per show where it can be (feed/forYou.ts). */
  forYou: 20,
  /** Trending franchises For you composes from. */
  forYouCandidates: 150,
  /** How long one For you composition serves every viewer (and one viewer's part serves them). */
  forYouTtlMs: 10 * 60_000,
  /** How many of the recommender's picks For you asks for. */
  forYouRecommended: 40,
  /** Viewers whose part of For you is kept; the oldest goes first. */
  forYouViewers: 500,
  /** The Trending module under For you. */
  trendingModule: 8,
} as const

function feedCapabilities(): FeedCapabilities {
  return { comments: env.SOCIAL_COMMENTS_ENABLED }
}

/**
 * The wire post: the composed post without its internal thread, plus the viewer's state. `context`
 * is For you's alone (feed/forYou.ts); every other surface sends null.
 */
function toFeedPost(
  post: ComposedPost,
  fresh: boolean,
  social: PostSocial | undefined,
  context: FeedPostContext | null = null,
): FeedPost {
  const { thread: _thread, ...rest } = post
  const state = social ?? emptyPostSocial()
  return { ...rest, fresh, context, viewer: state.viewer, counts: state.counts }
}

const isFresh = (discoveredAt: number, prevOpenedAt: number): boolean => prevOpenedAt > 0 && discoveredAt > prevOpenedAt

/** The author rows for exactly the franchises `posts` reference, in first-reference order. */
function referencedFranchises(
  posts: readonly { franchiseId: string }[],
  authorOf: (franchiseId: string) => FeedFranchise | null,
): FeedFranchise[] {
  const out: FeedFranchise[] = []
  const seen = new Set<string>()
  for (const post of posts) {
    if (seen.has(post.franchiseId)) continue
    seen.add(post.franchiseId)
    const author = authorOf(post.franchiseId)
    if (author) out.push(author)
  }
  return out
}

/** `referencedFranchises`' lookup over loaded franchises and the viewer's status for each. */
function authorsFrom(
  byId: ReadonlyMap<string, Franchise>,
  statusById: ReadonlyMap<string, WatchStatus>,
): (franchiseId: string) => FeedFranchise | null {
  return (id) => {
    const f = byId.get(id)
    return f ? toFeedFranchise(f, statusById.get(id) ?? null) : null
  }
}

async function subscribedFranchiseIds(userId: string): Promise<string[]> {
  const rows = await db
    .select({ franchiseId: subscriptions.franchiseId })
    .from(subscriptions)
    .where(eq(subscriptions.userId, userId))
    .orderBy(asc(subscriptions.createdAt), asc(subscriptions.franchiseId))
  return rows.map((row) => row.franchiseId)
}

// ---------- For you: one user-independent composition per catalogue scope, refreshed every 10 minutes ----------

/**
 * A For you candidate as it is kept between requests: the post, plus what the ranker reads of it
 * that the wire never carries (`getFeed` strips both). `sharp`: it has a video or a sharp picture
 * (`isSharp`). `evergreen`: it is a recommended show's discovery trailer.
 */
type ForYouComposed = ComposedPost & { sharp: boolean; evergreen?: boolean }

interface ForYouPosts {
  posts: ForYouComposed[]
  franchisesById: Map<string, Franchise>
}

/** The catalogue a For you response is drawn from: the viewer's audience, or null for both. */
type ForYouScope = MediaSource | null

interface ForYouSnapshot extends ForYouPosts {
  /** The catalogue it was composed for: every show in it is of this source (null = both). */
  scope: ForYouScope
  /** Trending summaries, rank order. */
  summaries: FranchiseSummary[]
  /** When it was composed (ms): its identity for the viewers' parts built against it. */
  builtAt: number
}

const scopeKey = (scope: ForYouScope): string => scope ?? 'all'

/** One snapshot per scope ('all', 'anilist', 'tmdb'): at most three, each built on first use. */
const forYouCache = new Map<string, { builtAt: number; snapshot: ForYouSnapshot }>()
const forYouInFlight = new Map<string, Promise<ForYouSnapshot>>()

/** The posts about a set of shows as nobody in particular sees them: no viewer, no progress. */
async function composeForAnyone(ids: string[], nowMs: number): Promise<ForYouPosts> {
  const [loaded, history] = await Promise.all([getFeedFranchises(ids, null), loadResearchHistory(ids)])
  const posts = composePosts({
    franchises: loaded.franchises,
    observations: history.observations,
    announcements: history.announcements,
    memberAddedAt: loaded.memberAddedAt,
    externalIds: loaded.externalIdById,
    nowMs,
  })
  const franchisesById = new Map(loaded.franchises.map((f) => [f.id, f]))
  return {
    posts: posts.map((post) => ({ ...post, sharp: isSharp(post, franchisesById.get(post.franchiseId)) })),
    franchisesById,
  }
}

/**
 * The trending pool of one scope. A catalogue's pool is that catalogue's OWN top 150 — never the
 * mixed ranking filtered, whose head is all anime (only AniList carries a trend score), which would
 * leave a TV viewer with nothing.
 */
async function buildForYou(nowMs: number, scope: ForYouScope): Promise<ForYouSnapshot> {
  const ids = await trendingFranchiseIds(FEED_LIMITS.forYouCandidates, scope)
  const [composed, summaries] = await Promise.all([composeForAnyone(ids, nowMs), getSummaries(ids)])
  return { ...composed, scope, summaries, builtAt: nowMs }
}

/** Single-flight per scope: concurrent callers share one build. A failed refresh serves the last snapshot. */
function forYouSnapshot(nowMs: number, scope: ForYouScope = null): Promise<ForYouSnapshot> {
  const key = scopeKey(scope)
  const cached = forYouCache.get(key)
  if (cached && nowMs - cached.builtAt < FEED_LIMITS.forYouTtlMs) return Promise.resolve(cached.snapshot)
  let inFlight = forYouInFlight.get(key)
  if (!inFlight) {
    inFlight = buildForYou(nowMs, scope)
      .then((snapshot) => {
        forYouCache.set(key, { builtAt: nowMs, snapshot })
        return snapshot
      })
      .catch((err: unknown) => {
        const previous = forYouCache.get(key)
        if (!previous) throw err
        console.warn('[feed] For you refresh failed; serving the previous snapshot:', 'diagnostic details redacted')
        return previous.snapshot
      })
      .finally(() => {
        forYouInFlight.delete(key)
      })
    forYouInFlight.set(key, inFlight)
  }
  return inFlight
}

// ---------- For you: the viewer's part, kept per user for the snapshot's 10 minutes ----------

/** What For you reads of a show once its posts are composed: the author row and the taste inputs. */
interface ForYouShow {
  author: FeedFranchise
  genres: string[]
}

interface ForYouViewer {
  /**
   * The snapshot this part complements (its `builtAt`, never the snapshot itself — a kept viewer
   * must not keep a retired snapshot alive): `posts` are what THAT snapshot does not carry about
   * the picks, so a new snapshot (other trending shows) rebuilds it rather than double or lose a show.
   */
  snapshotBuiltAt: number
  /**
   * The audience it was built for. Part of the cache's identity: a viewer who switches audience is
   * served the new one on their next request, not when the ten minutes run out.
   */
  scope: ForYouScope
  /** The viewer's library, for the taste profile. */
  seeds: RankSeed[]
  /** The recommender's picks that have a show page, strongest first, each once. */
  recommended: ForYouPick[]
  /**
   * Feed posts about the picks outside the snapshot, and every pick's discovery trailer
   * (`evergreen`) — the snapshot's own picks included. Kept lean: no thread (the feed strips it).
   */
  posts: ForYouComposed[]
  /**
   * The picks outside the snapshot that posted. There is one of these maps per viewer, so it holds
   * the rows the feed sends and ranks by, never the franchises they were composed from.
   */
  shows: Map<string, ForYouShow>
}

/** Insertion order is age order: a rebuilt viewer is re-inserted, the first key is the oldest. */
const forYouViewers = new Map<string, { builtAt: number; viewer: ForYouViewer }>()

async function buildForYouViewer(userId: string, snapshot: ForYouSnapshot, nowMs: number): Promise<ForYouViewer> {
  // The loader and the pure ranker, never `getRecommendations`: that one queues show pages to
  // build, and a feed read must not start work. A pick with no show page yet has no posts either.
  const { input } = await loadRankInput(userId, nowMs)
  // The reference order, without the shelf's daily rotation: the feed moves with the news and the
  // library, not with the date.
  // Of the viewer's audience only: the ranker drops the other catalogue's titles before it selects.
  const scope = snapshot.scope
  const ranked = rankRecommendations(input, {
    userId,
    limit: FEED_LIMITS.forYouRecommended,
    rotation: false,
    source: scope,
  })
  const recommended: ForYouPick[] = []
  const picked = new Set<string>()
  for (const item of ranked.items) {
    if (!item.franchiseId || picked.has(item.franchiseId) || !inAudience(scope, item.source)) continue
    picked.add(item.franchiseId)
    recommended.push({ franchiseId: item.franchiseId, reason: item.reason })
  }
  const missing = recommended.map((pick) => pick.franchiseId).filter((id) => !snapshot.franchisesById.has(id))
  const extra: ForYouPosts =
    missing.length > 0 ? await composeForAnyone(missing, nowMs) : { posts: [], franchisesById: new Map() }

  // Most picks have no news, and a trailer is new to someone who has not seen the show: each pick
  // gets its discovery trailer, whatever its age, unless its feed already carries a trailer
  // (compose.ts `discoveryTrailer`). The catalogue's own video, never a fetch: nothing is enqueued.
  const feedPosts = new Map<string, ForYouComposed[]>()
  for (const post of [...snapshot.posts, ...extra.posts]) {
    if (!picked.has(post.franchiseId)) continue
    const own = feedPosts.get(post.franchiseId) ?? []
    own.push(post)
    feedPosts.set(post.franchiseId, own)
  }
  const posts = [...extra.posts]
  for (const pick of recommended) {
    const f = snapshot.franchisesById.get(pick.franchiseId) ?? extra.franchisesById.get(pick.franchiseId)
    const trailer = f && inAudience(scope, f.source) ? discoveryTrailer(f, feedPosts.get(pick.franchiseId) ?? [], nowMs) : null
    // A trailer's video is its picture.
    if (trailer) posts.push({ ...trailer, sharp: true, evergreen: true })
  }

  const shows = new Map<string, ForYouShow>()
  for (const post of posts) {
    const f = shows.has(post.franchiseId) ? undefined : extra.franchisesById.get(post.franchiseId)
    if (f) shows.set(f.id, { author: toFeedFranchise(f, null), genres: f.genres })
  }
  return {
    snapshotBuiltAt: snapshot.builtAt,
    scope,
    seeds: input.seeds,
    recommended,
    posts: posts.map((post) => ({ ...post, thread: [] })),
    shows,
  }
}

/**
 * The viewer's part of For you, or null when it could not be built — the feed is then the trending
 * one, in time order, as it was before it was personal. A failure is never kept.
 */
async function forYouViewer(userId: string, snapshot: ForYouSnapshot, nowMs: number): Promise<ForYouViewer | null> {
  const cached = forYouViewers.get(userId)
  if (
    cached &&
    cached.viewer.scope === snapshot.scope &&
    cached.viewer.snapshotBuiltAt === snapshot.builtAt &&
    nowMs - cached.builtAt < FEED_LIMITS.forYouTtlMs
  ) return cached.viewer
  try {
    const viewer = await buildForYouViewer(userId, snapshot, nowMs)
    forYouViewers.delete(userId)
    forYouViewers.set(userId, { builtAt: nowMs, viewer })
    // Oldest first: everything past its 10 minutes goes, then whatever is over the cap.
    for (const [id, entry] of forYouViewers) {
      if (forYouViewers.size <= FEED_LIMITS.forYouViewers && nowMs - entry.builtAt < FEED_LIMITS.forYouTtlMs) break
      forYouViewers.delete(id)
    }
    return viewer
  } catch (err: unknown) {
    console.warn('[feed] For you could not be personalised; serving trending only:', 'diagnostic details redacted')
    return null
  }
}

// ---------- GET /me/feed ----------

/** What a request may ask of the feed beyond its tab. */
export interface FeedOptions {
  /**
   * Include Following's "Episode N is out" posts (`?episodes=1`). Off by default: a client that
   * predates the `episode` kind renders it as an announcement, so the kind is only ever sent to a
   * request that asked for it. For you has none either way.
   */
  episodes?: boolean
}

/**
 * `since` is the client's anchor (`?since=`): the `prevOpenedAt` its own `POST /me/opened` answered
 * this session. When it is a real past instant (`clientAnchor`) it is THE anchor — `fresh`, the
 * order and the echoed `prevOpenedAt` all use it — because the stored one moves under the client
 * when that stamp failed or another device stamped a visit. Otherwise the stored anchor is read.
 */
export async function getFeed(
  userId: string,
  tab: FeedTab,
  nowMs: number = Date.now(),
  since: number | null = null,
  options: FeedOptions = {},
): Promise<FeedResponse> {
  const anchor = clientAnchor(since, nowMs)
  const [prevOpenedAt, hides, owned, audience] = await Promise.all([
    anchor ?? readVisitAnchors(userId).then((anchors) => anchors.prevOpenedAt),
    loadHides(userId),
    subscribedFranchiseIds(userId),
    // Read on every For you request — never cached — so a change of audience shows at once.
    // Following is the viewer's own library: the audience does not apply and is not read.
    tab === 'foryou' ? resolveAudience(userId) : null,
  ])

  let ordered: (ComposedPost & { fresh: boolean; context: FeedPostContext | null })[]
  let authorOf: (franchiseId: string) => FeedFranchise | null
  let trending: FranchiseSummary[] = []
  let cap: number

  if (tab === 'following') {
    // Every library status (spike parity), minus muted shows. For a request that asked for them,
    // the composer adds the "Episode N is out" posts from each show's status (watching, watched,
    // paused); every other request gets the feed exactly as it was before that kind existed.
    const ids = owned.filter((id) => !hides.shows.has(id))
    const [loaded, history] = await Promise.all([getFeedFranchises(ids, userId), loadResearchHistory(ids)])
    const composed = composePosts({
      franchises: loaded.franchises,
      observations: history.observations,
      announcements: history.announcements,
      memberAddedAt: loaded.memberAddedAt,
      externalIds: loaded.externalIdById,
      episodes: options.episodes === true,
      nowMs,
    })
    // What arrived since the previous visit comes first (D8).
    ordered = orderPosts(
      composed.filter((post) => !hides.posts.has(post.id)),
      prevOpenedAt,
    ).map((post) => ({ ...post, context: null }))
    authorOf = authorsFrom(new Map(loaded.franchises.map((f) => [f.id, f])), loaded.statusById)
    cap = FEED_LIMITS.following
  } else {
    // News about shows the viewer does not track and has not muted: the trending snapshot everyone
    // of their audience shares, plus the shows the recommender picks out of THEIR library and those
    // shows' trailers.
    const scope = sourceFor(audience)
    const snapshot = await forYouSnapshot(nowMs, scope)
    const viewer = await forYouViewer(userId, snapshot, nowMs)
    const excluded = new Set([...owned, ...hides.shows])
    // The audience, once more, on what is about to be served: the snapshot and the picks are built
    // for the scope already, and nothing of the other catalogue gets past this line whatever they hold.
    const sourceOf = (id: string): MediaSource | undefined =>
      snapshot.franchisesById.get(id)?.source ?? viewer?.shows.get(id)?.author.source
    const candidates = [...snapshot.posts, ...(viewer?.posts ?? [])].filter(
      (post) => !excluded.has(post.franchiseId) && !hides.posts.has(post.id) && inAudience(scope, sourceOf(post.franchiseId)),
    )
    const tastes = new Map<string, TasteFranchise>(snapshot.franchisesById)
    for (const [id, show] of viewer?.shows ?? []) tastes.set(id, { source: show.author.source, genres: show.genres })
    // Ranked for the viewer (feed/forYou.ts): what the recommender picked and what matches their
    // library first, newer before older, nothing stale and nothing without a picture. Nothing here
    // is "new since your visit" (the client never marks it so), so no post is fresh. With no viewer
    // part — it failed, or the library says nothing — the ranker falls back to time alone. What the
    // ranker read of a candidate (`sharp`, `evergreen`) stays here.
    ordered = rankForYou({
      posts: candidates,
      franchises: tastes,
      recommended: viewer?.recommended ?? [],
      seeds: viewer?.seeds ?? [],
      nowMs,
    }).map(({ sharp: _sharp, evergreen: _evergreen, ...post }) => ({ ...post, fresh: false }))
    authorOf = (id) => {
      const f = snapshot.franchisesById.get(id)
      return f ? toFeedFranchise(f, null) : (viewer?.shows.get(id)?.author ?? null)
    }
    trending = snapshot.summaries
      .filter((summary) => !excluded.has(summary.id) && inAudience(scope, summary.source))
      .slice(0, FEED_LIMITS.trendingModule)
    // Cached composition may predate a catalogue classification change. Recheck visible cards
    // and named recommendation seeds without evicting shared caches or rewriting owned history.
    const namedSeeds = ordered.flatMap((post) => post.context?.kind === 'recommended'
      ? post.context.reason.seeds.map((seed) => seed.franchiseId) : [])
    const visible = await consumerFranchiseIds([...new Set([
      ...ordered.map((post) => post.franchiseId), ...trending.map((item) => item.id), ...namedSeeds,
    ])])
    ordered = ordered.filter((post) => visible.has(post.franchiseId)).map((post) => ({
      ...post,
      context: post.context?.kind === 'recommended' && post.context.reason.seeds.some((seed) => !visible.has(seed.franchiseId))
        ? null : post.context,
    }))
    trending = trending.filter((item) => visible.has(item.id))
    cap = FEED_LIMITS.forYou
  }

  const page = ordered.slice(0, cap)
  const social = await loadPostSocial(userId, page.map((post) => post.id))
  const posts = page.map((post) => toFeedPost(post, post.fresh, social.get(post.id), post.context))

  return {
    tab,
    generatedAt: nowMs,
    prevOpenedAt,
    capabilities: feedCapabilities(),
    franchises: referencedFranchises(posts, authorOf),
    posts,
    trending,
  }
}

// ---------- One post: detail, Saved, Reminders ----------

/**
 * The franchise a post id belongs to, from the database (announcement row, member row, or the id).
 * An `ep:` id is the "Episode N is out" post of the part it names.
 */
async function franchiseIdForPost(postId: string): Promise<string | null> {
  const parsed = parseSubject(postId)
  if (!parsed) return null
  switch (parsed.kind) {
    case 'news': {
      const [row] = await db
        .select({ franchiseId: announcements.franchiseId })
        .from(announcements)
        .where(eq(announcements.id, parsed.announcementId))
        .limit(1)
      return row?.franchiseId ?? null
    }
    case 'catalog':
    case 'episode': {
      const [row] = await db
        .select({ franchiseId: franchiseMember.franchiseId })
        .from(franchiseMember)
        .where(eq(franchiseMember.mediaId, parsed.mediaId))
        .limit(1)
      return row?.franchiseId ?? null
    }
    case 'trailer':
      return parsed.franchiseId
  }
}

/**
 * `composePostById`, canonicalised: a `catalog:<mediaId>` whose part an announcement of the same
 * franchise already names (`announcementForPart`, the rule adoption and every write share) is served
 * as that announcement's `news:<id>` post (the id the feed and the thread use since adoption). Falls
 * back to the catalogue post when the news post cannot be composed.
 */
function composeCanonical(
  input: ComposeInput,
  postId: string,
  opts: ComposeByIdOptions = {},
): { post: ComposedPost; live: boolean } | null {
  const parsed = parseSubject(postId)
  if (parsed?.kind === 'catalog') {
    for (const f of input.franchises) {
      const part = f.parts.find((p) => p.mediaId === parsed.mediaId)
      if (!part) continue
      const match = announcementForPart(part, input.announcements.get(f.id) ?? [], f.parts)
      if (match) {
        const aliased = composePostById(input, formatSubject({ kind: 'news', announcementId: match.id }))
        if (aliased) return aliased
      }
      break
    }
  }
  return composePostById(input, postId, opts)
}

/**
 * The ids among `postIds` that did not compose but that a held row can still date — a trailer the
 * catalogue delisted, an episode whose air instant has left the payload — mapped to their thread's
 * first activity. Only those somebody still holds a row on: one nobody touched stays gone.
 */
async function orphanTimes(postIds: readonly string[]): Promise<Map<string, number>> {
  const ids = postIds.filter((id) => {
    const kind = parseSubject(id)?.kind
    return kind === 'trailer' || kind === 'episode'
  })
  return ids.length > 0 ? firstActivityAt(ids) : new Map()
}

/** Everything `composePostById` needs for a set of franchises, loaded in one batch. */
async function loadComposeInput(franchiseIds: string[], userId: string, nowMs: number): Promise<{
  input: ComposeInput
  franchisesById: Map<string, Franchise>
  statusById: Map<string, WatchStatus>
}> {
  const [loaded, history] = await Promise.all([getFeedFranchises(franchiseIds, userId), loadResearchHistory(franchiseIds)])
  return {
    input: {
      franchises: loaded.franchises,
      observations: history.observations,
      announcements: history.announcements,
      memberAddedAt: loaded.memberAddedAt,
      externalIds: loaded.externalIdById,
      // By id an `ep:` post composes for whoever asks (only a client that knows the kind does);
      // this makes `live` say whether such a client's Following carries it.
      episodes: true,
      nowMs,
    },
    franchisesById: new Map(loaded.franchises.map((f) => [f.id, f])),
    statusById: loaded.statusById,
  }
}

/**
 * `GET /feed/posts/:id`: the post (composed even when the feed no longer carries it, D16), its
 * author row, the storyline and the thread's sources. A post the viewer hid is still served — they
 * followed a link to it. Null when the id names nothing that can be composed.
 */
export async function getPostDetail(userId: string, postId: string, nowMs: number = Date.now()): Promise<FeedPostDetailResponse | null> {
  const franchiseId = await franchiseIdForPost(postId)
  if (!franchiseId) return null
  const [{ input, franchisesById, statusById }, anchors] = await Promise.all([
    loadComposeInput([franchiseId], userId, nowMs),
    readVisitAnchors(userId),
  ])
  const f = franchisesById.get(franchiseId)
  if (!f) return null
  let composed = composeCanonical(input, postId)
  if (!composed) {
    // A trailer whose video was delisted, or an episode from before the dated window, keeps its
    // thread while anyone holds a row on it.
    const orphanAt = (await orphanTimes([postId])).get(postId)
    if (orphanAt != null) composed = composeCanonical(input, postId, { orphanAt })
  }
  if (!composed) return null
  const { post, live } = composed
  const social = await loadPostSocial(userId, [post.id])
  return {
    post: toFeedPost(post, isFresh(post.discoveredAt, anchors.prevOpenedAt), social.get(post.id)),
    franchise: toFeedFranchise(f, statusById.get(f.id) ?? null),
    live,
    storyline: storyline(post.thread, nowMs),
    threadSources: threadSources(post.thread, nowMs),
    capabilities: feedCapabilities(),
  }
}

/** A viewer's saved or reminded posts, newest first, each composed from its own franchise. */
async function postCollection(
  rows: readonly { postId: string; franchiseId: string; createdAt: Date }[],
  userId: string,
  nowMs: number,
): Promise<{ items: { postId: string; at: number; post: FeedPost | null }[]; franchises: FeedFranchise[] }> {
  if (rows.length === 0) return { items: [], franchises: [] }
  const franchiseIds = [...new Set(rows.map((row) => row.franchiseId))]
  const [{ input, franchisesById, statusById }, anchors] = await Promise.all([
    loadComposeInput(franchiseIds, userId, nowMs),
    readVisitAnchors(userId),
  ])
  const composed = rows.map((row) => composeCanonical(input, row.postId)?.post ?? null)
  // A saved or reminded trailer whose video was delisted, or a saved episode from before the dated
  // window: the viewer's own row keeps it composable.
  const orphans = await orphanTimes(rows.flatMap((row, i) => (composed[i] ? [] : [row.postId])))
  if (orphans.size > 0) {
    rows.forEach((row, i) => {
      const orphanAt = composed[i] ? null : orphans.get(row.postId)
      if (orphanAt != null) composed[i] = composeCanonical(input, row.postId, { orphanAt })?.post ?? null
    })
  }
  const social = await loadPostSocial(
    userId,
    composed.flatMap((post) => (post ? [post.id] : [])),
  )
  const items = rows.map((row, i) => {
    const post = composed[i] ?? null
    return {
      postId: row.postId,
      at: row.createdAt.getTime(),
      post: post ? toFeedPost(post, isFresh(post.discoveredAt, anchors.prevOpenedAt), social.get(post.id)) : null,
    }
  })
  const franchises = referencedFranchises(
    items.flatMap((item) => (item.post ? [item.post] : [])),
    authorsFrom(franchisesById, statusById),
  )
  return { items, franchises }
}

/** `GET /me/saved`. `post: null` = the post can no longer be composed (its part or show is gone). */
export async function getSaved(userId: string, nowMs: number = Date.now()): Promise<SavedResponse> {
  const rows = await db
    .select({ postId: saves.postId, franchiseId: saves.franchiseId, createdAt: saves.createdAt })
    .from(saves)
    .where(eq(saves.userId, userId))
    .orderBy(desc(saves.createdAt), asc(saves.postId))
  const { items, franchises } = await postCollection(rows, userId, nowMs)
  return { items: items.map(({ postId, at, post }) => ({ postId, savedAt: at, post })), franchises }
}

/** `GET /me/reminders`, the same shape. */
export async function getReminders(userId: string, nowMs: number = Date.now()): Promise<RemindersResponse> {
  const rows = await db
    .select({ postId: reminders.postId, franchiseId: reminders.franchiseId, createdAt: reminders.createdAt })
    .from(reminders)
    .where(eq(reminders.userId, userId))
    .orderBy(desc(reminders.createdAt), asc(reminders.postId))
  const { items, franchises } = await postCollection(rows, userId, nowMs)
  return { items: items.map(({ postId, at, post }) => ({ postId, remindedAt: at, post })), franchises }
}
