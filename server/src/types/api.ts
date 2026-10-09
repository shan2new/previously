import type { PartKind } from '../grouping/partKind.js'

/**
 * The user's own verdict on a franchise. Stored in `subscriptions.status`, which is a `text()`
 * column — adding a value needs no migration.
 */
export type WatchStatus = 'watching' | 'completed' | 'planned' | 'paused' | 'dropped'

/** Which catalogue a franchise (and all its parts) came from. A franchise never mixes sources. */
export type MediaSource = 'anilist' | 'tmdb'

/** How a title can be streamed in the requested country. Purchase/rental stores are excluded. */
export type WatchAccess = 'subscription' | 'free' | 'ads'
export type WatchAvailabilityStatus = 'available' | 'not_available' | 'unmatched' | 'disabled'

export interface WatchProvider {
  id: number
  name: string
  logo: string | null
  access: WatchAccess
  /** Present/true when the authenticated user saved this service as a preference. */
  preferred?: boolean
}

/** Country-specific streaming availability returned by GET /franchises/:id/watch-providers. */
export interface WatchAvailability {
  /** ISO 3166-1 alpha-2 country code echoed from the request. */
  country: string
  /** Why providers is populated or empty; consumers must not infer this from array length. */
  status: WatchAvailabilityStatus
  /** Subscription first, then free/ad-supported; TMDB display priority within each group. */
  providers: WatchProvider[]
  /** TMDB's regional watch page. Provider entries do not include reliable deep links. */
  link: string | null
  /** Required attribution for TMDB watch-provider data. */
  attribution: 'JustWatch'
  /** When this regional snapshot was last checked. Null only for disabled/unpersisted responses. */
  checkedAt?: string | null
}

/** Compact regional fact safe to attach to list/search rows. */
export type WatchAvailabilityPreview = WatchAvailability

/** Explicit artwork orientation. Legacy `cover`/`banner` remain for older clients. */
export interface ArtworkSet {
  portrait: string | null
  landscape: string | null
}

export interface ArtworkImage {
  url: string
  source: MediaSource
  width: number | null
  height: number | null
  language: string | null
  score: number | null
}

/** Ranked alternatives for layouts/share cards; `images` remains the single best pair. */
export interface ArtworkGallery {
  portraits: ArtworkImage[]
  landscapes: ArtworkImage[]
  logos: ArtworkImage[]
}

export type VideoKind = 'trailer' | 'teaser' | 'announcement' | 'featurette' | 'clip' | 'other'

/** A catalogue-curated video. Previously stores provider ids/links; it never hosts the video. */
export interface CatalogVideo {
  id: string
  site: string
  kind: VideoKind
  title: string | null
  url: string | null
  thumbnail: string | null
  official: boolean | null
  language: string | null
  country: string | null
  publishedAt: string | null
}

export type VideoScope =
  | { type: 'franchise' }
  | { type: 'part'; mediaId: number; label: string }

/** A video returned to clients, annotated with the franchise/part it belongs to. */
export type FranchiseVideo = CatalogVideo & { scope: VideoScope }

export interface ContentRating {
  country: string
  rating: string
}

export interface AudienceInfo {
  isAdult: boolean | null
  /** Rating for the caller-supplied country, or null when that market has no rating. */
  contentRating: ContentRating | null
  /** Every country rating in the catalogue, so clients can change region without re-fetching. */
  availableRatings: ContentRating[]
}

export interface CatalogPerson {
  source: MediaSource
  externalId: number
  name: string
  role: string | null
  image: string | null
}

export interface FranchisePeople {
  creators: CatalogPerson[]
  directors: CatalogPerson[]
  cast: CatalogPerson[]
}

/** Source-native recommendation; franchiseId is filled when that title is already materialized. */
export interface RelatedTitle {
  source: MediaSource
  externalId: number
  franchiseId: string | null
  title: string
  year: number | null
  images: ArtworkSet
  /** Source-native recommendation strength where available. */
  score?: number | null
}

export type CatalogProvider = 'anilist' | 'tmdb'
export type CatalogMediaType = 'tv' | 'movie' | 'anime'

export interface CatalogLinkView {
  provider: CatalogProvider
  mediaType: CatalogMediaType
  externalId: number
  matchMethod: string
  confidence: number | null
  checkedAt: string
}

export interface MetadataCompleteness {
  artwork: boolean
  episodes: boolean
  people: boolean
  ratings: boolean
  related: boolean
  videos: boolean
}

export interface FranchiseMetadataState {
  completeness: MetadataCompleteness
  sources: CatalogLinkView[]
}

/** Deep catalogue metadata persisted separately from the latency-sensitive search index. */
export interface FranchiseEnrichment {
  level: 'basic' | 'full'
  themes: string[]
  isAdult: boolean | null
  contentRatings: ContentRating[]
  people: FranchisePeople
  related: RelatedTitle[]
  /** Show/franchise-level videos; part-specific videos live on `media.videos`. */
  videos: CatalogVideo[]
  /**
   * Internal provenance/cache state for AniList-owned anime enriched from TMDB. This never changes
   * franchise identity: `source` remains AniList and the matched TMDB title is metadata-only.
   */
  videoFallback?: {
    source: 'tmdb'
    mediaType: 'tv' | 'movie'
    externalId: number | null
    status: 'matched' | 'unmatched'
    checkedAt: string
    /** Bump when the fallback starts persisting another class of metadata. */
    metadataVersion?: number
  }
  checkedAt: string
}

export type AnnouncementEvidenceTier = 'official' | 'trade' | 'reputable' | 'catalogue' | 'unknown'

export interface AnnouncementEvidence {
  url: string
  publisher: string | null
  publishedAt: string | null
  tier: AnnouncementEvidenceTier
  primary: boolean
}

/**
 * "What's next" for a franchise (announced/airing seasons, films, etc.). Usually populated by
 * web research and stored on franchise.upcoming; the read path can also derive the same shape from
 * a future part already confirmed by AniList/TMDB. `release` is a human-readable date or window
 * ("2026-10", "January 2027", "TBA") because announcements often provide only a window.
 */
export interface FranchiseUpcoming {
  status: string // airing | upcoming_dated | announced | announced_no_date | recently_aired | rumored | concluded
  next: string // e.g. "Season 2", "Infinity Castle - Part 2 (movie)"
  release: string // human-readable date or window
  note: string | null
  source: string | null
  checked: string | null // ISO date the info was last verified
  /** Multiple inspectable sources. Older stored rows may omit this and read back as an empty list. */
  evidence?: AnnouncementEvidence[]
}

/**
 * `FranchiseUpcoming.release` resolved into something orderable. Derived on read (never stored),
 * so a row written before this existed still ships one — see `services/releaseWindow.ts`.
 *
 * `release` remains the only thing a client PRINTS; `sortKey` is the only thing it SORTS BY.
 * Clients must not parse `release` themselves: an ISO-only reading of a corpus full of "October
 * 2026" and "Summer 2027" silently orders a franchise's return by January of its year.
 */
export interface ReleaseWindow {
  /** "YYYY-MM-DD" | "YYYY-MM" | "YYYY" — the window at the precision actually known, or null. */
  date: string | null
  /**
   * day/month = `date` is exactly what was announced · quarter = a broadcast season or Qn, whose
   * `date` is that quarter's FIRST month (safe to order by, never to print as a month) · year =
   * only the year may be printed · unknown = TBA, rumored, or prose with no date in it.
   */
  precision: 'day' | 'month' | 'quarter' | 'year' | 'unknown'
  /**
   * `yyyymmdd` of the EARLIEST instant the window can mean, so ascending = soonest first.
   * `null` (unknown) sorts last — never as 0, and never as January of a year nobody stated.
   */
  sortKey: number | null
}

/** What the API actually ships for `upcoming`: the stored news plus its resolved window. */
export type FranchiseUpcomingView = FranchiseUpcoming & { releaseWindow: ReleaseWindow }

/**
 * Per-episode metadata. Richness is source-dependent: TMDB gives title/overview/still/runtime/date;
 * AniList gives per-episode air dates (from airingSchedule) and best-effort titles/stills (from
 * streamingEpisodes), but no per-episode overview. Any field may be null/absent.
 */
export interface EpisodeMeta {
  number: number
  title: string | null
  airDate: number | null // ms epoch
  overview: string | null
  still: string | null // thumbnail/still image url
  runtime: number | null // minutes
}

/** The first already-aired episode the authenticated user has not watched. */
export interface ContinueWatching {
  mediaId: number
  partLabel: string
  episode: EpisodeMeta
}

/**
 * How precisely the next release instant is known. Sources differ in kind, not just in quality:
 * AniList publishes a real broadcast instant, TMDB publishes a calendar date that the sync
 * synthesizes to 17:00 UTC. Stating it here is what stops a client from inferring precision from
 * `source` — and from ever rendering a clock time that nobody published.
 */
export interface ReleasePrecision {
  /** exact = `at` is a real instant · date_only = `date` is the fact, `at` is synthesized · unknown = nothing scheduled. */
  precision: 'exact' | 'date_only' | 'unknown'
  /** ms epoch. Authoritative only when `precision` is "exact"; synthesized when "date_only". */
  at: number | null
  /** "YYYY-MM-DD" (UTC). Authoritative only when `precision` is "date_only". */
  date: string | null
}

export interface FranchisePart {
  mediaId: number
  kind: PartKind
  sequence: number
  /** Global order across seasons, movies and specials. */
  watchOrder: number
  /** Source relation to the main work (SEQUEL, SIDE_STORY, etc.) when known. */
  relationship: string | null
  /** True only when source evidence identifies optional/side material. */
  optional: boolean
  label: string
  title: string
  cover: string
  banner: string
  images: ArtworkSet
  artwork: ArtworkGallery
  format: string | null
  status: string | null
  isReleasing: boolean
  totalEpisodes: number
  airedEpisodes: number
  nextEpisodeNumber: number | null
  /** Derived compatibility field: always `release.at`. Prefer `release` for anything user-facing. */
  nextAiringAt: number | null
  /** The honest shape of the next release date. See ReleasePrecision. */
  release: ReleasePrecision
  lastAiredAt: number | null
  synopsis: string
  genres: string[]
  progress: number
  /** Premiere/season year (AniList seasonYear or TMDB season air-date year). */
  year: number | null
  /** Studios (AniList) or networks (TMDB) — names only, for the detail meta line. */
  studios: string[]
  /**
   * Episodes sharing the next airing date. `> 1` marks a same-day multi-episode / full-season
   * "drop" (TMDB), so Schedule can label it "Season drop" without shipping the whole episode list.
   * Computed from `episodes` server-side; `0` when nothing is upcoming or episode data is absent.
   */
  nextAiringCount: number
  /**
   * Full per-episode list. Populated ONLY on the franchise-detail response (`GET /franchises/:id`);
   * empty on the library/summary payloads to keep those lean.
   */
  episodes: EpisodeMeta[]
  /**
   * Dated episodes inside Schedule's window (`SCHEDULE_WINDOW`: 8 days back … 15 days ahead of
   * now), oldest first. Present on EVERY payload — list, library and detail — because it is the
   * one per-episode fact Schedule needs and it is tiny; `episodes` stays detail-only. A weekly
   * show therefore appears on every one of its air dates in the window, not once on its next.
   * Empty when nothing in the window is dated.
   */
  airings: Airing[]
  /** Part-specific trailers/teasers. Populated on detail/library; safe to ignore when empty. */
  videos: FranchiseVideo[]
}

/** One dated episode: its number and its air instant (ms epoch; TMDB's is date-only at 17:00 UTC). */
export interface Airing {
  episode: number
  at: number
}

export interface Franchise {
  id: string
  source: MediaSource
  title: string
  cover: string
  banner: string
  images: ArtworkSet
  artwork: ArtworkGallery
  synopsis: string
  genres: string[]
  isReleasing: boolean
  partCounts: Partial<Record<PartKind, number>>
  parts: FranchisePart[]
  subscription: { status: WatchStatus; addedAt: number } | null
  upcoming: FranchiseUpcomingView | null
  /** Premiere year of the franchise (earliest dated part). */
  year: number | null
  /** Studios (anime) or networks (TV) for the primary installment — the detail meta line. */
  studios: string[]
  /** Conservative, spoiler-screened themes. AniList spoiler-tag flags are honoured. */
  themes: string[]
  featuredVideo: FranchiseVideo | null
  videos: FranchiseVideo[]
  audience: AudienceInfo
  people: FranchisePeople
  related: RelatedTitle[]
  continueWatching: ContinueWatching | null
  /** Regional availability when a country was requested/resolved for this response. */
  availability?: WatchAvailabilityPreview
  /** Why fields are present/missing and which catalogues were safely linked. */
  metadata: FranchiseMetadataState
}

export interface FranchiseSummary {
  id: string
  source: MediaSource
  title: string
  cover: string
  banner: string
  images: ArtworkSet
  artwork: ArtworkGallery
  isReleasing: boolean
  partCount: number
  nextAiringAt: number | null
  upcoming: FranchiseUpcomingView | null
  /** Premiere year (for "Anime · 2023" / "TV · 2024" on discover cards). */
  year: number | null
  themes: string[]
  featuredVideo: FranchiseVideo | null
  status?: WatchStatus
  behind?: number
  newParts?: number
  /** Cached/bounded regional preview when a country was requested/resolved. */
  availability?: WatchAvailabilityPreview
}

export type LibraryFranchise = Franchise & { status: WatchStatus; behind: number; newParts: number }

/** Per-catalogue outcome for a fan-out search, so the client can say which half failed. */
export type SourceOutcome = 'ok' | 'failed' | 'disabled'

/** The envelope every franchise list route returns (`/franchises/trending`, `/search`). */
export interface FranchiseListResponse {
  franchises: FranchiseSummary[]
  /** Set when the query was spell-corrected/completed before searching (see queryCorrect.ts). */
  correctedQuery?: string
  /** The query the caller sent, echoed when `correctedQuery` is present. */
  originalQuery?: string
  /** Per-catalogue outcome. Absent on routes that do not fan out. */
  sources?: { anilist: SourceOutcome; tmdb: SourceOutcome }
}

/**
 * Which catalogue the server SUGGESTS titles from for a viewer: anime (AniList), TV (TMDB) or both.
 * It governs everything the viewer did not ask for by name — For you, recommendations, trending,
 * genre browsing, and search with no explicit `source` — and never their own library.
 */
export type Audience = 'anime' | 'tv' | 'both'

export interface UserPreferences {
  country: string | null
  language: string
  providerIds: number[]
  updatedAt: string | null
  /** null = the viewer has not chosen yet; the server treats null as 'both'. */
  audience: Audience | null
}

/**
 * Why a title is recommended, in the user's own terms (see docs/api-contract.md):
 * - `consensus` — several of the user's shows point at it ("Like A and B", "Like A and 4 more of yours")
 * - `finished` / `watching` / `watched` — one show, named by what the user did with it
 * - `planned` — one show that is only on the user's list ("Like A, on your list")
 * - `world` — a separate work from the same universe as a show the user has ("From the world of A")
 */
export type RecommendationReasonKind = 'consensus' | 'finished' | 'watching' | 'watched' | 'planned' | 'world'

export interface RecommendationReason {
  kind: RecommendationReasonKind
  /**
   * The user's shows behind the reason, strongest vote first (display titles — the short form the
   * app uses, e.g. "Re:ZERO", never "Re:ZERO -Starting Life in Another World-"). One entry for a
   * single-show reason and for `world`; up to three when `count` >= 2, so the client can choose
   * which to name by Today's state. A Planned show with no progress never comes first while
   * another show qualifies.
   */
  seeds: { franchiseId: string; title: string }[]
  /** How many of the user's shows point at this title (>= seeds.length). */
  count: number
}

export interface RecommendationItem {
  /** Stable per target: `${source}:${externalId}` of the canonical target (AniList: the series root). */
  key: string
  /** The local franchise when materialised (a tap opens it); null otherwise. */
  franchiseId: string | null
  source: MediaSource
  externalId: number
  /** The series' display title (English when available, else romaji; never a "Season 4" title). */
  title: string
  year: number | null
  images: ArtworkSet
  /** The materialised franchise's gallery (logos, titled portraits) when franchiseId != null. */
  artwork: ArtworkGallery | null
  /** TV | ONA | … — series only; films/OVA/specials/music/TV_SHORT are never served. */
  format: string | null
  episodes: number | null
  airing: boolean
  genres: string[]
  reason: RecommendationReason
  score: number
}

/** `GET /me/recommendations`. Deterministic for (user, UTC calendar day). */
export interface RecommendationsResponse {
  items: RecommendationItem[]
  /** ms epoch */
  generatedAt: number
}

export type RecommendationFeedbackKind = 'dismissed' | 'seen'

/**
 * One watch of a franchise (`/me/watch-sessions`): the implicit first watch or a rewatch. The
 * client generates `id` and owns every field; the server stores what it is sent. Times are ms
 * epochs; `completedAt: 0` means "finished, date unknown" (the implicit first watch).
 */
export interface WatchSessionBody {
  franchiseId: string
  /** null = the whole franchise; else the one part (media id) the session covers. */
  scopeMediaId: number | null
  /** 1 = first watch, 2 = second, … */
  ordinal: number
  startedAt: number | null
  completedAt: number | null
  cancelledAt: number | null
  cancelledAtEpisode: number | null
  /** Episodes the session covers; 0 when unknown. */
  episodes: number
  /** Where the show stood before the rewatch (media id → episodes), so stopping it can restore. */
  restoreProgress: Record<string, number> | null
  restoreStatus: WatchStatus | null
}

export interface WatchSession extends WatchSessionBody {
  id: string
  /** ms epoch of the last write the server accepted. */
  updatedAt: number
}

/** `GET /me/watch-sessions`. Live sessions only (no tombstones), ordered by franchise then ordinal. */
export interface WatchSessionsResponse {
  sessions: WatchSession[]
}

export interface AnnouncementObservationView {
  id: string
  announcementId: string | null
  status: string
  next: string
  release: string
  note: string | null
  observedAt: string
  evidence: AnnouncementEvidence[]
}

export interface FranchiseProgressCommandResponse {
  ok: true
  applied?: boolean
  franchiseId: string
  status: WatchStatus | null
  progress: { mediaId: number; episodes: number }[]
}

/**
 * `DELETE /me`. The account and everything it owned are gone, so there is nothing left to
 * describe: the response carries only the fact that the erasure completed.
 *
 * `deleted` is a literal `true` rather than the codebase's usual `{ ok: true }` so a client can
 * never read "the request was accepted" as "the account no longer exists".
 */
export interface AccountDeletedResponse {
  deleted: boolean
  status: 'complete' | 'pending'
  appleRevocation: 'revoked' | 'manual_required' | 'not_applicable'
}

// ---------- Notifications (GET /me/notifications) ----------

export type NotificationKind =
  | 'news_rumored'
  | 'news_announced'
  | 'news_dated'
  | 'reply'
  | 'like_comment'
  // Moderation notices (services/moderationNotices.ts): no actor, subject, post or comment — the
  // row opens nothing. `body` is a machine category, never English:
  | 'comment_hidden' //  your comment was hidden — body 'reports' | 'operator'
  | 'report_resolved' // your report was decided — body 'hidden' | 'dismissed'

/**
 * A stored per-user notification: announcement news for a subscribed franchise or a reminded post,
 * a social event (a reply to you, likes on your comment), or a moderation notice (your comment was
 * hidden, your report was decided).
 *
 * Deep link: `commentId` set → open the thread `subject` at that comment; else `postId` set → open
 * `/feed/posts/:postId`; else → open the franchise. A moderation notice opens nothing.
 *
 * The six social fields are always sent by the §5.2 read path. They are declared optional only so
 * the pre-social `listNotifications` still compiles until services/notifications.ts builds the full
 * row; tighten them to required once it does.
 */
export interface NotificationItem {
  id: string
  franchiseId: string
  kind: NotificationKind | string // decode leniently; unknown kinds render as a plain row
  title: string // franchise title
  body: string // news: server English, the FALLBACK when `news` is null (never parsed); social: ''; moderation: the category
  createdAt: number // ms epoch
  readAt: number | null // ms epoch, null while unread
  /** reply / like_comment: who did it. */
  actor: PublicUser | null
  /** like_comment: distinct likers folded into this row (≥1); 0 otherwise. */
  actorCount: number
  /** The thread to open (social kinds). */
  subject: string | null
  /** The post to open. */
  postId: string | null
  /** The comment to scroll to. */
  commentId: string | null
  /** Live: the first 140 code points of the comment (reply: the reply; like: your comment); null if gone. */
  excerpt: string | null
  /**
   * News kinds: the structured fact to word the row from (the feed's headline grammar), read LIVE
   * from the announcement like `excerpt`. Null for social kinds and for a news row whose
   * announcement is gone — only then does the client fall back to `body`.
   */
  news: NotificationNews | null
}

/**
 * The announcement behind a news notification, as it stands NOW (an older row shows the
 * installment's current state; `kind` says which event created the row). Time text is the
 * client's, from `releaseWindow` — `body` and `release` are never parsed (brief §3).
 */
export interface NotificationNews {
  /** rumored | announced_no_date | announced | upcoming_dated (decode leniently). */
  status: string
  /** "Season 2", "Infinity Castle - Part 2": never contains "(movie)" (as `FeedPost.installment`). */
  installment: string
  isMovie: boolean
  /** Research's prose window, printed as-is only where the feed prints `FeedWindow.release`. */
  release: string
  /** `release` resolved (a rumour's is always `unknown`): what the client formats and sorts by. */
  releaseWindow: ReleaseWindow
}

export interface NotificationsPage {
  items: NotificationItem[]
  unread: number
  nextCursor: string | null
}

// ---------- Today feed (GET /me/feed, /feed/posts/:id, /me/saved, /me/reminders) ----------

export type FeedTab = 'following' | 'foryou'
/** `episode` = "Episode N is out": Following only, one per main-story part, for a week after it airs. */
export type FeedPostKind = 'dated' | 'window' | 'announced' | 'rumour' | 'trailer' | 'episode'
export type FeedPostOrigin = 'research' | 'catalogue' | 'video'

/** When the news happened. A date-only fact is carried at 12:00 UTC of its day (dateOnly: true). */
export interface FeedTime {
  at: number
  dateOnly: boolean
  /** primary = the original announcement's date; first_report = earliest report in the 120-day
   *  cluster; observed = when research first saw this state; catalogue = when the catalogue
   *  attached the part; published = the video's publish instant; aired = the episode's air instant
   *  (kind 'episode'; a TMDB episode is date-only). */
  basis: 'primary' | 'first_report' | 'observed' | 'catalogue' | 'published' | 'aired'
}

export interface FeedPremiere {
  at: number
  precision: 'exact' | 'date_only'
}

/** `release` is printed, `releaseWindow` is sorted/formatted by. Clients never parse `release`. */
export interface FeedWindow {
  release: string
  releaseWindow: ReleaseWindow
}

export interface FeedSource {
  publisher: string
  tier: AnnouncementEvidenceTier
  /** https only. Null when there is no https link (the entry is kept only for the catalogue fallback). */
  url: string | null
  publishedAt: number | null
  dateOnly: boolean
  primary: boolean
}

/** The part a post is about: art inputs only. The client picks the frame with its existing accessors. */
export interface FeedPartRef {
  mediaId: number
  label: string
  kind: PartKind
  status: string | null
  cover: string
  banner: string
  images: ArtworkSet
  artwork: ArtworkGallery
}

/** The post's author row ("the show"), shipped once per response. */
export interface FeedFranchise {
  id: string
  source: MediaSource
  title: string
  cover: string
  banner: string
  images: ArtworkSet
  artwork: ArtworkGallery
  year: number | null
  isReleasing: boolean
  /** The viewer's library status; null when the show is not in their library. */
  status: WatchStatus | null
  upcoming: FranchiseUpcomingView | null
}

export interface FeedViewerState {
  liked: boolean
  saved: boolean
  reminded: boolean
}

export interface FeedCounts {
  likes: number
  comments: number
}

export interface FeedCapabilities {
  comments: boolean
}

/** Why a For you post is in THIS viewer's feed; null on Following and where no reason is known. */
export type FeedPostContext =
  | { kind: 'recommended'; reason: RecommendationReason }
  | { kind: 'taste'; genres: string[] } // 1–2 taxonomy genres, the viewer's strongest first

export interface FeedPost {
  /**
   * PostId: `news:<announcement uuid>` | `catalog:<media id>` | `trailer:<franchise uuid>:<site>:<video id>`,
   * or — kind 'episode' only — the episode's own thread subject `ep:<media id>:<episode>`.
   */
  id: string
  kind: FeedPostKind
  origin: FeedPostOrigin
  franchiseId: string
  /** "Season 2", "Infinity Castle Part 2". Never contains "(movie)". '' for a franchise-scope trailer. */
  installment: string
  isMovie: boolean
  part: FeedPartRef | null
  /** The episode number, for kind 'episode' only; null for every other kind. */
  episode: number | null
  time: FeedTime
  /** When the app first knew this post in its current state (ms). "New" compares this, never `time`. */
  discoveredAt: number
  /** Set by the server against the response's `prevOpenedAt`. Fresh posts come first. */
  fresh: boolean
  /** Only for kind 'dated' (and a trailer whose installment has a slot). */
  premiere: FeedPremiere | null
  /** Only for kind 'window'. */
  window: FeedWindow | null
  /** The research note, tidied. Research posts only. */
  note: string | null
  video: FranchiseVideo | null
  /** Ranked. `sources[0]` is the lead. */
  sources: FeedSource[]
  /** True only when sources[0].tier === 'official': the ONLY condition for the gold check. */
  isOfficial: boolean
  /** For you only (feed/forYou.ts); null on Following, the post page, Saved and Reminders. */
  context: FeedPostContext | null
  viewer: FeedViewerState
  counts: FeedCounts
}

export interface FeedResponse {
  tab: FeedTab
  generatedAt: number
  /** The previous visit the server ordered against (users.prev_opened_at). */
  prevOpenedAt: number
  capabilities: FeedCapabilities
  /** Exactly the franchises the posts reference. */
  franchises: FeedFranchise[]
  posts: FeedPost[]
  /** For you only: untracked, unmuted trending shows (the Trending module), ranked. [] on following. */
  trending: FranchiseSummary[]
}

export interface StoryBeat {
  /** yyyymmdd (UTC) of the beat's day. */
  id: string
  /** ms of the lead report. */
  day: number
  publishers: string[]
  official: boolean
  primary: boolean
  headline: string | null
  /** https only. */
  url: string | null
}

export interface FeedPostDetailResponse {
  /** `post.id` is CANONICAL: use it as the thread subject. */
  post: FeedPost
  franchise: FeedFranchise
  /** False when the franchise's feed no longer carries this post (the thread is still open). */
  live: boolean
  storyline: StoryBeat[]
  /** Every https source across the thread, deduped by URL (the thread page's "Sources"). */
  threadSources: FeedSource[]
  capabilities: FeedCapabilities
}

/** `post: null` = the post can no longer be composed (e.g. a catalogue post whose part has released). */
export interface SavedItem {
  postId: string
  savedAt: number
  post: FeedPost | null
}

export interface SavedResponse {
  items: SavedItem[]
  franchises: FeedFranchise[]
}

export interface ReminderItem {
  postId: string
  remindedAt: number
  post: FeedPost | null
}

export interface RemindersResponse {
  items: ReminderItem[]
  franchises: FeedFranchise[]
}

// ---------- Social (likes, comments, episode rooms, identity) ----------

/** The only public face of an account. Never the email, never the Clerk id. */
export interface PublicUser {
  /** users.id */
  id: string
  handle: string
  displayName: string
}

export interface CommentView {
  id: string
  subject: string
  author: PublicUser
  body: string
  createdAt: number
  parentId: string | null
  /** The parent's author when the parent is still visible to the viewer. */
  replyTo: PublicUser | null
  likeCount: number
  liked: boolean
  replyCount: number
  mine: boolean
}

export type CommentSort = 'top' | 'latest'
export type EpisodeAccess = 'open' | 'unwatched' | 'unaired'

export interface CommentsPage {
  subject: string
  /** Episode rooms only: true when the viewer may not read it. `items` is then []. */
  locked: boolean
  /** null for post subjects. */
  access: EpisodeAccess | null
  /** Visible comments for this viewer (blocks and own reports applied). */
  total: number
  items: CommentView[]
  nextCursor: string | null
}

export interface CommentResponse {
  comment: CommentView
}

export interface EpisodeRoom {
  subject: string
  franchiseId: string
  mediaId: number
  episode: number
  access: EpisodeAccess
  /** Global visible count (drives "Mark it watched to join N comments"). */
  commentCount: number
  likeCount: number
  liked: boolean
  rating: {
    count: number
    /** 0–100, 1 dp; null when locked or count 0. */
    average: number | null
    yours: number | null
  }
}

export type ReportReason = 'spam' | 'harassment' | 'hate' | 'sexual' | 'violence' | 'spoiler' | 'other'

export interface BlockedUsersResponse {
  items: { user: PublicUser; blockedAt: number }[]
}

export interface HidesResponse {
  items: {
    kind: 'post' | 'show'
    target: string
    createdAt: number
    franchise: { id: string; title: string } | null
  }[]
}

export interface ProfileResponse {
  userId: string
  handle: string | null
  displayName: string | null
  termsAcceptedAt: number | null
  termsVersion: string | null
  currentTermsVersion: string
  /** handle && displayName && termsVersion === current && comments enabled. */
  canComment: boolean
}

export interface HandleAvailability {
  handle: string
  available: boolean
  reason: null | 'taken' | HandleRejection
}

export type ContentRejection = 'empty' | 'too_long' | 'link' | 'blocked_term' | 'invalid_characters'
export type HandleRejection = 'length' | 'characters' | 'dots' | 'no_letter' | 'reserved' | 'blocked_term'
export type DisplayNameRejection =
  | 'empty'
  | 'too_long'
  | 'invalid_characters'
  | 'link'
  | 'blocked_term'
  | 'no_letter'
  | 'at_sign'
  /** The app, its staff, a system voice or a brand (`RESERVED_NAME_WORDS`, social/identity.ts). */
  | 'reserved'

/** Machine codes clients branch on (409/410/422/429, and 403 account_suspended). */
export type SocialErrorCode =
  | 'handle_required'
  | 'terms_required'
  | 'episode_locked'
  | 'id_conflict'
  | 'handle_taken'
  | 'own_comment'
  | 'self_block'
  | 'terms_version_mismatch'
  | 'content_rejected'
  | 'invalid_handle'
  | 'invalid_display_name'
  | 'rate_limited'
  | 'account_suspended'

export interface SocialError {
  error: SocialErrorCode | string
  reason?: string
  retryAfter?: number
  currentVersion?: string
}

// ---------- Account export (GET /me/export) ----------

export interface AccountExport {
  exportedAt: number
  account: {
    id: string
    createdAt: number
    email: string | null
    /** ms epoch of the current visit's `POST /me/opened`; null = never. */
    lastOpenedAt: number | null
    /** ms epoch of the visit before it; null = never. */
    prevOpenedAt: number | null
  }
  profile: {
    handle: string | null
    displayName: string | null
    termsAcceptedAt: number | null
    termsVersion: string | null
    createdAt: number
    updatedAt: number
  } | null
  /**
   * The caller's ban record, read by their Clerk id — the one row kept after `DELETE /me`. null
   * when the identity was never suspended; a lifted ban reads `suspended: false` with `liftedAt`.
   */
  moderation: { suspended: boolean; reason: string | null; since: number | null; liftedAt: number | null } | null
  library: {
    subscriptions: { franchiseId: string; title: string; status: WatchStatus; addedAt: number }[]
    progress: { mediaId: number; episodes: number; updatedAt: number }[]
    preferences: UserPreferences | null
    recommendationFeedback: { key: string; kind: string; createdAt: number }[]
    /** Every session the server holds, deleted ones included as the tombstones they are. */
    watchSessions: (WatchSession & { deletedAt: number | null })[]
  }
  social: {
    comments: {
      id: string
      subject: string
      parentId: string | null
      body: string
      createdAt: number
      deletedAt: number | null
      hiddenAt: number | null
      /** 'reports' (auto-hidden) | 'operator'; null while visible. */
      hiddenReason: string | null
    }[]
    likes: { subject: string; createdAt: number }[]
    commentLikes: { commentId: string; createdAt: number }[]
    saves: { postId: string; createdAt: number }[]
    reminders: { postId: string; createdAt: number }[]
    hides: { kind: string; target: string; createdAt: number }[]
    ratings: { mediaId: number; episode: number; score: number; updatedAt: number }[]
    blocks: { userId: string; handle: string | null; createdAt: number }[]
    reports: {
      commentId: string
      reason: string
      note: string | null
      createdAt: number
      resolvedAt: number | null
      resolution: string | null
    }[]
    notifications: {
      id: string
      kind: string
      franchiseId: string
      /** As stored: the franchise title. */
      title: string
      /** As stored: news text, '' for social kinds, the category for moderation notices. */
      body: string
      subject: string | null
      postId: string | null
      commentId: string | null
      createdAt: number
      readAt: number | null
    }[]
  }
}

// ---------- Discover: genres (GET /discover/genres, /discover/genres/:key) ----------

export interface DiscoverGenre {
  key: string
  name: string
  count: number
  /** ≤ 4 portrait URLs: the genre's top trending, non-adult franchises. */
  posters: string[]
}

export interface DiscoverGenresResponse {
  source: MediaSource | null
  genres: DiscoverGenre[]
  generatedAt: number
}

export interface DiscoverGenrePage {
  genre: DiscoverGenre
  franchises: FranchiseSummary[]
  /** Opaque. */
  nextCursor: string | null
}
