import type {
  Airing,
  AnnouncementEvidenceTier,
  FeedFranchise,
  FeedPartRef,
  FeedPost,
  FeedPostKind,
  FeedPremiere,
  FeedSource,
  FeedTime,
  FeedWindow,
  Franchise,
  FranchisePart,
  FranchiseUpcoming,
  FranchiseVideo,
  ReleaseWindow,
  WatchStatus,
} from '../types/api.js'
import { announcementForPart, installmentName, matchPart } from '../news/installment.js'
import { slotPassed, slotStrikesAt } from '../services/airingSlot.js'
import { catalogProviderUrl, currentUpcoming, pickCatalogUpcomingPart } from '../services/catalogUpcoming.js'
import { resolveReleaseWindow } from '../services/releaseWindow.js'
import { formatSubject, parseSubject } from '../social/subjects.js'
import {
  AGENT_TEXT_LIMITS,
  isCleanAgentText,
  parseEvidenceDate,
  rankSources,
  safeHttpsUrl,
  sanitizeAgentText,
  sanitizeEvidence,
} from './evidence.js'

// The Today feed's one composer (docs/api-contract.md, "Today feed"): research observations, the
// catalogue and the trailer catalogue in, posts out. A rule-for-rule port of the spike's
// FeedSpikeModel.swift, with every deviation named at its rule — plus two kinds of post the spike
// never had: "Episode N is out" (Following) and the discovery trailer (For you). Pure and
// deterministic given `nowMs` — nothing in here reads the clock or the database, and the only thing
// read of the viewer is the library status a franchise was loaded with.

const DAY_MS = 86_400_000
/** Reports within this span of the newest one are one news cluster ("when the news broke"). */
const CLUSTER_SPAN_MS = 120 * DAY_MS
/** A "primary" report older than this relative to the newest report is a stale re-flag. */
const PRIMARY_SPAN_MS = 400 * DAY_MS
/** A video is the news's own trailer when it was published within this of the news. */
const VIDEO_NEAR_MS = 10 * DAY_MS
/** Trailers older than this are not news any more. */
const TRAILER_HORIZON_MS = 200 * DAY_MS
const NOTE_MAX_CODE_POINTS = AGENT_TEXT_LIMITS.note
/**
 * Parts attached within this of a franchise's first member came with the show's (re)grouping: the
 * catalogue already listed them when the app first saw the show, so their attach instant is not
 * news. One grouping writes every member in one transaction; the daily attach pass that finds a
 * genuinely new season runs hours or days later.
 */
const FOUNDING_WINDOW_MS = 60 * 60_000
/**
 * A premiere this far in the past has happened everywhere (a date-only premiere sits at 12:00 UTC
 * of its day, which ends in the last time zone 24 h later): the post is no longer news.
 */
const PREMIERE_SPENT_MS = DAY_MS
/** An episode is news for this long after it airs. */
const EPISODE_NEWS_MS = 7 * DAY_MS

// ---------- Inputs ----------

export interface ComposeEvidence {
  url: string
  publisher: string | null
  publishedAt: string | null
  tier: AnnouncementEvidenceTier
  primary: boolean
}

export interface ComposeObservation {
  id: string
  announcementId: string | null
  status: string
  next: string
  release: string
  note: string | null
  /** ms epoch. */
  observedAt: number
  evidence: ComposeEvidence[]
}

export interface ComposeAnnouncement {
  id: string
  dedupeKey: string
  status: string
  next: string
  /** ms epoch. */
  firstSeenAt: number
}

export interface ComposeInput {
  /** Built by `getFeedFranchises` (services/franchiseView.ts). Posts come out in this order. */
  franchises: Franchise[]
  /** Per franchise, NEWEST FIRST, the FULL history (never a capped page). */
  observations: ReadonlyMap<string, ComposeObservation[]>
  /** Per franchise. */
  announcements: ReadonlyMap<string, ComposeAnnouncement[]>
  /** mediaId → franchise_member.added_at (ms): when the catalogue attached the part. */
  memberAddedAt: ReadonlyMap<number, number>
  /**
   * franchise id → `franchise.external_id` (the TMDB show id). Only a TMDB catalogue post's source
   * link needs it; without an entry that link is null. Additive to the spec's input (see the P1 notes).
   */
  externalIds?: ReadonlyMap<string, number | null>
  /**
   * Compose "Episode N is out" posts (kind 'episode'). OFF unless asked for: a client that predates
   * the kind renders an unknown one with the "announced" wording, so only a request that opts in
   * (`GET /me/feed?episodes=1`) — or one for a single `ep:` post by id — may be answered with them.
   */
  episodes?: boolean
  nowMs: number
}

/** A post before per-viewer state. `thread` is internal (the storyline's input); routes strip it. */
export type ComposedPost = Omit<FeedPost, 'viewer' | 'counts' | 'fresh' | 'context'> & { thread: ComposeObservation[] }

type NewsKind = Exclude<FeedPostKind, 'trailer' | 'episode'>

/** Research status → post kind. Every other status (airing, recently_aired, concluded) is not news. */
const KIND: Readonly<Record<string, NewsKind>> = {
  upcoming_dated: 'dated',
  announced: 'window',
  announced_no_date: 'announced',
  rumored: 'rumour',
}

const kindOf = (status: string): NewsKind | null => (Object.hasOwn(KIND, status) ? KIND[status]! : null)

const VIDEO_KINDS = new Set<FranchiseVideo['kind']>(['trailer', 'teaser', 'announcement'])

// ---------- Small shared pieces ----------

/** The art inputs of a part. The client picks the frame with its existing accessors. */
export function toPartRef(p: FranchisePart): FeedPartRef {
  return {
    mediaId: p.mediaId,
    label: p.label,
    kind: p.kind,
    status: p.status,
    cover: p.cover,
    banner: p.banner,
    images: p.images,
    artwork: p.artwork,
  }
}

/** The post's author row, shipped once per response. `status` is the viewer's library status. */
export function toFeedFranchise(f: Franchise, status: WatchStatus | null): FeedFranchise {
  return {
    id: f.id,
    source: f.source,
    title: f.title,
    cover: f.cover,
    banner: f.banner,
    images: f.images,
    artwork: f.artwork,
    year: f.year,
    isReleasing: f.isReleasing,
    status,
    upcoming: f.upcoming,
  }
}

const precisionFor = (f: Franchise): FeedPremiere['precision'] => (f.source === 'tmdb' ? 'date_only' : 'exact')

/** A part's own premiere slot: its next airing, else its first dated airing. */
const slotOf = (p: FranchisePart): number | null => p.nextAiringAt ?? p.airings[0]?.at ?? null

/** `slotOf`, only while it is still to come (a past slot on an unreleased row is stale catalogue). */
function futureSlotOf(p: FranchisePart, nowMs: number): number | null {
  const slot = slotOf(p)
  return slot != null && slot > nowMs ? slot : null
}

/**
 * When a part premiered or premieres: an unreleased part's slot; for a part that has since
 * premiered, its first episode's airing when the payload still carries it (`airings` spans a few
 * days either side of now), else unknown.
 */
function premiereOf(p: FranchisePart): number | null {
  if (p.status === 'NOT_YET_RELEASED') return slotOf(p)
  return p.airings.find((a) => a.episode === 1)?.at ?? null
}

/** The research note as the feed prints it: tidied, and dropped when it carries a link or a blocked term. */
function cleanNote(note: string | null | undefined): string | null {
  const tidy = tidyNote(note)
  return tidy != null && isCleanAgentText(tidy) ? tidy : null
}

/** The URLs a client may open, and nothing else. */
function sanitizeVideo(v: FranchiseVideo): FranchiseVideo {
  return { ...v, url: safeHttpsUrl(v.url), thumbnail: safeHttpsUrl(v.thumbnail) }
}

const videoKey = (v: Pick<FranchiseVideo, 'site' | 'id'>): string => `${v.site.toLowerCase()}:${v.id}`

/** The feed's one text order (code units, no locale): equal times and scores never flicker. */
export function compareText(a: string, b: string): number {
  return a < b ? -1 : a > b ? 1 : 0
}

/**
 * The research note, tidied: C0/C1 control characters removed (a newline kept, a tab read as a
 * space), runs of spaces collapsed, trimmed, and cut at 600 code points on a word boundary with an
 * ellipsis. Null when nothing is left.
 */
export function tidyNote(note: string | null | undefined): string | null {
  if (typeof note !== 'string') return null
  let s = note
    .replace(/\r\n?/g, '\n')
    .replace(/\t/g, ' ')
    .replace(/[\u0000-\u0009\u000b-\u001f\u007f-\u009f]/g, '')
    .replace(/ {2,}/g, ' ')
    .trim()
  if (s === '') return null
  const points = [...s]
  if (points.length > NOTE_MAX_CODE_POINTS) {
    let cut = points.slice(0, NOTE_MAX_CODE_POINTS - 1).join('')
    const boundary = Math.max(cut.lastIndexOf(' '), cut.lastIndexOf('\n'))
    if (boundary > 0) cut = cut.slice(0, boundary)
    s = `${cut.trimEnd()}…`
  }
  return s
}

/** Every observation's evidence through `sanitizeEvidence` before any rule reads it (D6). */
function observationsFor(input: ComposeInput, franchiseId: string): ComposeObservation[] {
  return (input.observations.get(franchiseId) ?? []).map((o) => ({ ...o, evidence: sanitizeEvidence(o.evidence) }))
}

// ---------- Video attachment (spike `video(for:in:near:)`, FeedSpikeModel.swift:690-702) ----------

/**
 * The trailer that came WITH the news: the official cut published closest to it, within ten days,
 * from the installment's own videos or the show's. A video made for ANOTHER part is never it, and
 * a part-scoped video is never attached when no part matched.
 */
export function attachVideo(f: Franchise, part: FranchisePart | null, near: number, nowMs: number): FranchiseVideo | null {
  let best: { video: FranchiseVideo; distance: number; key: string } | null = null
  for (const v of [...f.videos, ...(part?.videos ?? [])]) {
    if (!VIDEO_KINDS.has(v.kind) || v.official === false) continue
    if (v.scope.type === 'part' && (!part || v.scope.mediaId !== part.mediaId)) continue
    const t = parseEvidenceDate(v.publishedAt, nowMs)
    if (!t) continue
    const distance = Math.abs(t.ms - near)
    if (distance > VIDEO_NEAR_MS) continue
    const key = videoKey(v)
    if (!best || distance < best.distance || (distance === best.distance && key < best.key)) {
      best = { video: v, distance, key }
    }
  }
  return best ? sanitizeVideo(best.video) : null
}

// ---------- The news post ----------

/** The kind and premiere the catalogue dictates when it confirms a rumoured installment. */
interface CatalogueOverride {
  kind: 'dated' | 'announced'
  premiere: FeedPremiere | null
}

function catalogueOverride(f: Franchise, p: FranchisePart): CatalogueOverride {
  const slot = slotOf(p)
  return slot != null
    ? { kind: 'dated', premiere: { at: slot, precision: precisionFor(f) } }
    : { kind: 'announced', premiere: null }
}

function upcomingOf(o: ComposeObservation, next: string): FranchiseUpcoming {
  return { status: o.status, next, release: o.release, note: o.note, source: null, checked: null }
}

/** 12:00 UTC of a `YYYY-MM-DD` window, or null for any coarser window. */
function dayWindowInstant(w: ReleaseWindow): number | null {
  if (w.precision !== 'day' || !w.date) return null
  const [y, m, d] = w.date.split('-').map(Number)
  if (y == null || m == null || d == null) return null
  return Date.UTC(y, m - 1, d, 12)
}

/**
 * A research post (the spike's `newsPost`, FeedSpikeModel.swift:388-443), from `latest` — an
 * observation with a KIND status, an announcement id and a non-empty `next`. The thread is every
 * observation of the same announcement (D5); the post is dated from the full history of the
 * current state.
 */
function researchPost(
  f: Franchise,
  latest: ComposeObservation,
  obs: readonly ComposeObservation[],
  override: CatalogueOverride | null,
  nowMs: number,
): ComposedPost | null {
  const announcementId = latest.announcementId
  const kind0 = override?.kind ?? kindOf(latest.status)
  if (!announcementId || !kind0) return null
  const next = latest.next.trim()
  if (next === '') return null

  const id = formatSubject({ kind: 'news', announcementId })
  if (!parseSubject(id)) return null

  const thread = obs.filter((o) => o.announcementId === announcementId)
  const { name, isMovie } = installmentName(next)
  const release = latest.release
  // Matched on the agent's own words; printed only once they are clean (the name is the headline
  // and a reminder's body). A name carrying a link or a blocked term falls back to the matched
  // part's catalogue label, else there is no post.
  const part = matchPart(name, f.parts)
  const installment =
    sanitizeAgentText(name, AGENT_TEXT_LIMITS.installment) ?? (part && part.label.trim() !== '' ? part.label : null)
  if (installment == null) return null

  // When the news broke. Every report of the CURRENT state (the snapshots that saw this status and
  // release) is one cluster; the news is its primary announcement, unless that "primary" is stale
  // (a 2018 renewal flagged under a 2026 window), else the cluster's first report, else the day
  // research first saw this state. `latest` is in `sameState`, so it is never empty.
  const sameState = thread.filter((o) => o.status === latest.status && o.release === latest.release)
  const oldestSame = sameState[sameState.length - 1] ?? latest
  const dated: { ms: number; dateOnly: boolean; primary: boolean }[] = []
  for (const o of sameState) {
    for (const e of o.evidence) {
      if (e.tier === 'catalogue') continue
      const d = parseEvidenceDate(e.publishedAt, nowMs)
      if (d) dated.push({ ...d, primary: e.primary })
    }
  }
  let time: FeedTime = { at: oldestSame.observedAt, dateOnly: false, basis: 'observed' }
  if (dated.length > 0) {
    const newest = Math.max(...dated.map((d) => d.ms))
    let primary: (typeof dated)[number] | null = null
    let first: (typeof dated)[number] | null = null
    for (const d of dated) {
      if (d.primary && newest - d.ms <= PRIMARY_SPAN_MS && (!primary || d.ms > primary.ms)) primary = d
      if (newest - d.ms <= CLUSTER_SPAN_MS && (!first || d.ms < first.ms)) first = d
    }
    if (primary) time = { at: primary.ms, dateOnly: primary.dateOnly, basis: 'primary' }
    else if (first) time = { at: first.ms, dateOnly: first.dateOnly, basis: 'first_report' }
  }
  // A report dated up to a day ahead is accepted (a JST publisher's date is "tomorrow" in UTC), but
  // the news cannot have happened after now: the instant is clamped, its day-only flag kept.
  if (time.at > nowMs) time = { ...time, at: nowMs }

  // The premiere: the catalogue's own slot when the part is there and still to come, else a
  // day-precise window (read with the server's canonical window parser — a deviation from the
  // spike's ISO-only prefix parse, so the feed never disagrees with `releaseWindow`). A day-precise
  // release is a date whatever the status called it: an `announced` "November 20, 2026" is dated
  // news, not a window "in Nov 20, 2026".
  const releaseWindow = resolveReleaseWindow(upcomingOf(latest, next))
  const releaseDay = dayWindowInstant(releaseWindow)
  let premiere: FeedPremiere | null = null
  let kind: NewsKind
  if (override) {
    premiere = override.premiere
    kind = override.kind
  } else if (kind0 === 'dated' || (kind0 === 'window' && releaseDay != null)) {
    const slot = part && part.status === 'NOT_YET_RELEASED' ? slotOf(part) : null
    if (slot != null) premiere = { at: slot, precision: precisionFor(f) }
    else if (releaseDay != null) premiere = { at: releaseDay, precision: 'date_only' }
    kind = premiere != null ? 'dated' : 'window'
  } else {
    kind = kind0
  }
  // `release` is printed verbatim by the client, so it is agent text like any other: a window whose
  // release carries a link or a blocked term (or is empty) is an announcement without a date.
  const printedRelease = sanitizeAgentText(release, AGENT_TEXT_LIMITS.release)
  if (kind === 'window' && printedRelease == null) kind = 'announced'
  const window: FeedWindow | null =
    kind === 'window' && printedRelease != null ? { release: printedRelease, releaseWindow } : null

  const sources = rankSources(
    thread.flatMap((o) => o.evidence.map((e) => ({ ...e, observedAt: o.observedAt }))),
    nowMs,
  )

  return {
    id,
    kind,
    origin: 'research',
    franchiseId: f.id,
    installment,
    isMovie,
    part: part ? toPartRef(part) : null,
    episode: null,
    time,
    discoveredAt: oldestSame.observedAt,
    premiere,
    window,
    note: cleanNote(latest.note),
    video: attachVideo(f, part, time.at, nowMs),
    sources,
    isOfficial: sources[0]?.tier === 'official',
    thread,
  }
}

/**
 * A catalogue-only post: the catalogue lists a NOT_YET_RELEASED part research has not (or not
 * yet) confirmed. It keeps an existing announcement's thread when one names this part
 * (`announcementForPart`, D2); otherwise its id is `catalog:<mediaId>`, which research later adopts
 * (feed/adopt.ts).
 * Dated from when the catalogue attached the part — never from `media.fetched_at`, which resets on
 * every sync and re-dated the spike's post to "now" forever. No attach time, no post.
 *
 * Only a part attached AFTER the show was grouped is news of an attach. A part that came with the
 * grouping (within `FOUNDING_WINDOW_MS` of the franchise's first member — every part of a freshly
 * materialised show, and every part of a show a re-grouping re-stamped) was already listed when the
 * app first saw the show: its attach instant says nothing about when it was announced, so the post
 * is never "new" (`discoveredAt` 0). Its `time` stays the attach instant, the only one known.
 *
 * Composed by id (D16) the part may have premiered since: the post is then about an installment
 * that has arrived, with the first episode's airing as its premiere when known.
 */
function cataloguePost(f: Franchise, p: FranchisePart, input: ComposeInput): ComposedPost | null {
  const addedAt = input.memberAddedAt.get(p.mediaId)
  if (addedAt == null) return null
  let founding = addedAt
  for (const other of f.parts) {
    const at = input.memberAddedAt.get(other.mediaId)
    if (at != null && at < founding) founding = at
  }
  const attachedLater = addedAt - founding > FOUNDING_WINDOW_MS

  // The one announcement ↔ part rule (`announcementForPart`), shared with adoption, the post-detail
  // alias and the write-side canonical subject, so the id shown is the id the thread is keyed on.
  const adopted = announcementForPart(p, input.announcements.get(f.id) ?? [], f.parts)
  const id = adopted
    ? formatSubject({ kind: 'news', announcementId: adopted.id })
    : formatSubject({ kind: 'catalog', mediaId: p.mediaId })
  if (!parseSubject(id)) return null

  const slot = premiereOf(p)
  const time: FeedTime = { at: addedAt, dateOnly: false, basis: 'catalogue' }
  const source: FeedSource = {
    publisher: f.source === 'tmdb' ? 'TMDB' : 'AniList',
    tier: 'catalogue',
    url: safeHttpsUrl(catalogProviderUrl(f.source, input.externalIds?.get(f.id) ?? null, p.mediaId)),
    publishedAt: null,
    dateOnly: false,
    primary: false,
  }
  return {
    id,
    kind: slot != null ? 'dated' : 'announced',
    origin: 'catalogue',
    franchiseId: f.id,
    installment: p.label,
    isMovie: p.kind === 'movie',
    part: toPartRef(p),
    episode: null,
    time,
    discoveredAt: attachedLater ? addedAt : 0,
    premiere: slot != null ? { at: slot, precision: precisionFor(f) } : null,
    window: null,
    note: null,
    video: attachVideo(f, p, time.at, input.nowMs),
    sources: [source],
    isOfficial: false,
    thread: [],
  }
}

/**
 * The franchise's one news post, of either origin, or null. The state comes from the NEWEST
 * observation, resolved against the catalogue exactly as `resolveUpcomingWithCatalog` does (D4),
 * so the feed can never say "rumoured" while Detail says "dated".
 */
function newsCandidate(f: Franchise, obs: readonly ComposeObservation[], input: ComposeInput): ComposedPost | null {
  const latest = obs[0]
  const catPart = pickCatalogUpcomingPart(f.parts, input.nowMs)
  if (latest && (input.announcements.get(f.id) ?? []).some(a => a.id === latest.announcementId && a.status === 'retracted')) {
    return catPart ? cataloguePost(f, catPart, input) : null
  }
  const research = !!latest && kindOf(latest.status) != null && !!latest.announcementId && latest.next.trim() !== ''

  const validResearch = latest && research && currentUpcoming({
    ...upcomingOf(latest, latest.next), checked: new Date(latest.observedAt).toISOString(),
  }, f.parts, input.nowMs) != null
  if (latest && validResearch) {
    if (latest.status !== 'rumored' || !catPart) return researchPost(f, latest, obs, null, input.nowMs)
    // A rumour the catalogue has since confirmed keeps its thread (`news:<id>`) and takes the
    // catalogue's kind; a rumour about some OTHER installment yields to the confirmed one — a
    // franchise carries one news post.
    const rumoured = matchPart(installmentName(latest.next).name, f.parts)
    if (rumoured?.mediaId === catPart.mediaId) {
      return researchPost(f, latest, obs, catalogueOverride(f, catPart), input.nowMs)
    }
    return cataloguePost(f, catPart, input)
  }
  // No research news. The catalogue speaks when research knows nothing, or only that the last
  // installment ended; a stored `airing` is kept over it, as `resolveUpcomingWithCatalog` does.
  if (catPart && (!latest || (research && !validResearch) || latest.status === 'unknown' || latest.status === 'recently_aired' || latest.status === 'concluded')) {
    return cataloguePost(f, catPart, input)
  }
  return null
}

// ---------- Trailer posts (spike `trailerPosts`, FeedSpikeModel.swift:447-489) ----------

/** Every video of the franchise and its parts, once per `site:id` (the first entry wins). */
function videoPool(f: Franchise): FranchiseVideo[] {
  const seen = new Set<string>()
  const pool: FranchiseVideo[] = []
  for (const v of [...f.videos, ...f.parts.flatMap((p) => p.videos)]) {
    const key = videoKey(v)
    if (seen.has(key)) continue
    seen.add(key)
    pool.push(v)
  }
  return pool
}

const publisherForSite = (site: string): string => {
  const s = site.toLowerCase()
  if (s === 'youtube') return 'YouTube'
  const [first = '', ...rest] = [...s]
  return first.toUpperCase() + rest.join('')
}

/** A video that may be a post at all: a trailer/teaser/announcement, not disowned, not a re-cut. */
function isPostableVideo(v: FranchiseVideo): boolean {
  if (!VIDEO_KINDS.has(v.kind) || v.official === false) return false
  // Audio-described copies of a trailer are the same news.
  return !(v.title ?? '').toLowerCase().includes('audio described')
}

function trailerId(f: Franchise, v: FranchiseVideo): string | null {
  const id = formatSubject({ kind: 'trailer', franchiseId: f.id, site: v.site, videoId: v.id })
  return parseSubject(id) ? id : null
}

function trailerPost(
  f: Franchise,
  v: FranchiseVideo,
  t: { ms: number; dateOnly: boolean },
  id: string,
  nowMs: number,
): ComposedPost {
  const scope = v.scope
  const part = scope.type === 'part' ? (f.parts.find((p) => p.mediaId === scope.mediaId) ?? null) : null
  const label = scope.type === 'part' ? scope.label : ''
  // The premiere the trailer points at is always still to come (the filter `pickCatalogUpcomingPart`
  // applies): a slot that has passed on a row the hourly sync has not flipped yet is stale, and a
  // trailer never announces a premiere that already happened.
  const scopedSlot = part && part.status === 'NOT_YET_RELEASED' ? futureSlotOf(part, nowMs) : null
  const premiereAt =
    scopedSlot ??
    f.parts.find((p) => p.status === 'NOT_YET_RELEASED' && p.nextAiringAt != null && p.nextAiringAt > nowMs)?.nextAiringAt ??
    null
  return {
    id,
    kind: 'trailer',
    origin: 'video',
    franchiseId: f.id,
    installment: installmentName(label || part?.label || '').name,
    isMovie: part?.kind === 'movie',
    part: part ? toPartRef(part) : null,
    episode: null,
    // A publish date up to a day ahead parses (D6); the post still cannot be dated after now.
    time: { at: Math.min(t.ms, nowMs), dateOnly: t.dateOnly, basis: 'published' },
    // Video rows carry no first-seen stamp; the trailer sweep's lag is small (spec §14.1).
    discoveredAt: t.ms,
    premiere: premiereAt != null ? { at: premiereAt, precision: precisionFor(f) } : null,
    window: null,
    note: null,
    video: sanitizeVideo(v),
    sources: [{
      publisher: publisherForSite(v.site),
      // D7: the gold check belongs only to a video its catalogue marks official.
      tier: v.official === true ? 'official' : 'unknown',
      url: safeHttpsUrl(v.url),
      publishedAt: t.ms,
      dateOnly: t.dateOnly,
      primary: true,
    }],
    isOfficial: v.official === true,
    thread: [],
  }
}

/**
 * New trailers and teasers from the last 200 days, one per installment (the newest cut), newest
 * first. A video already riding on the news post — or published within ten days of it — is not
 * posted twice.
 */
function trailerPosts(f: Franchise, news: ComposedPost | null, nowMs: number): ComposedPost[] {
  const horizon = nowMs - TRAILER_HORIZON_MS
  const recent: { v: FranchiseVideo; t: { ms: number; dateOnly: boolean }; id: string }[] = []
  for (const v of videoPool(f)) {
    if (!isPostableVideo(v)) continue
    const t = parseEvidenceDate(v.publishedAt, nowMs)
    if (!t || t.ms < horizon || t.ms > nowMs) continue
    if (news?.video && videoKey(news.video) === videoKey(v)) continue
    if (news && Math.abs(t.ms - news.time.at) <= VIDEO_NEAR_MS) continue
    const id = trailerId(f, v)
    if (!id) continue
    recent.push({ v, t, id })
  }
  recent.sort((a, b) => b.t.ms - a.t.ms || compareText(a.v.id, b.v.id) || compareText(a.id, b.id))

  const byScope = new Set<string>()
  const posts: ComposedPost[] = []
  for (const { v, t, id } of recent) {
    const label = v.scope.type === 'part' ? v.scope.label : ''
    if (byScope.has(label)) continue
    byScope.add(label)
    posts.push(trailerPost(f, v, t, id, nowMs))
  }
  return posts
}

/**
 * A trailer post whose video the catalogue no longer lists (an enrichment refresh delisted it)
 * while people still hold rows on it — a like, a save, a reminder or a reply. The thread stays
 * reachable, so the post is composed bare: no video, no installment, no source, never live and
 * never new, dated at `at` (the thread's first activity, supplied by the caller).
 */
function orphanTrailerPost(f: Franchise, id: string, at: number): ComposedPost {
  return {
    id,
    kind: 'trailer',
    origin: 'video',
    franchiseId: f.id,
    installment: '',
    isMovie: false,
    part: null,
    episode: null,
    time: { at, dateOnly: false, basis: 'observed' },
    discoveredAt: 0,
    premiere: null,
    window: null,
    note: null,
    video: null,
    sources: [],
    isOfficial: false,
    thread: [],
  }
}

// ---------- The discovery trailer (For you, a recommended show) ----------

/** The better cut to introduce a show with: a trailer before a teaser before an announcement. */
const DISCOVERY_KIND_ORDER: Partial<Record<FranchiseVideo['kind'], number>> = { trailer: 0, teaser: 1, announcement: 2 }

/**
 * The trailer that introduces a show to someone who has not seen it, WHATEVER ITS AGE — For you
 * adds it for a show the recommender picked (feed/service.ts), because most such shows have no news
 * and `trailerPosts` only posts the last 200 days. The same post as any trailer post (`trailerPost`,
 * the same id), honestly dated at the video's publish instant; the caller ranks it as evergreen.
 *
 * `posts` are the show's feed posts as composed. Null when:
 *   - the feed already carries a trailer post for the show (its recent cut keeps its real recency,
 *     and an old trailer must not outrank it);
 *   - the catalogue has no usable video — postable as `trailerPosts` means it (a trailer, teaser or
 *     announcement, not disowned, not a re-cut), DATED (an AniList trailer carries no publish date,
 *     and a date is never invented), not ahead of now, and not the live news post's own campaign
 *     (its attached video, or one published within ten days of it — the news post is that story).
 *
 * The pick: the franchise's featured video when it is usable (the cut the show page leads with),
 * else an official cut before an unmarked one, a trailer before a teaser before an announcement,
 * the newest first.
 */
export function discoveryTrailer(f: Franchise, posts: readonly ComposedPost[], nowMs: number): ComposedPost | null {
  const own = posts.filter((post) => post.franchiseId === f.id)
  if (own.some((post) => post.kind === 'trailer')) return null
  const news = own.find((post) => post.kind !== 'episode') ?? null

  const usable: { v: FranchiseVideo; t: { ms: number; dateOnly: boolean }; id: string }[] = []
  for (const v of videoPool(f)) {
    if (!isPostableVideo(v)) continue
    const t = parseEvidenceDate(v.publishedAt, nowMs)
    if (!t || t.ms > nowMs) continue
    if (news?.video && videoKey(news.video) === videoKey(v)) continue
    if (news && Math.abs(t.ms - news.time.at) <= VIDEO_NEAR_MS) continue
    const id = trailerId(f, v)
    if (!id) continue
    usable.push({ v, t, id })
  }
  const featuredKey = f.featuredVideo ? videoKey(f.featuredVideo) : null
  const best =
    usable.find((u) => videoKey(u.v) === featuredKey) ??
    usable.sort(
      (a, b) =>
        Number(b.v.official === true) - Number(a.v.official === true) ||
        (DISCOVERY_KIND_ORDER[a.v.kind] ?? 9) - (DISCOVERY_KIND_ORDER[b.v.kind] ?? 9) ||
        b.t.ms - a.t.ms ||
        compareText(a.v.id, b.v.id) ||
        compareText(a.id, b.id),
    )[0]
  return best ? trailerPost(f, best.v, best.t, best.id, nowMs) : null
}

// ---------- Episode posts ("Episode N is out", Following) ----------

/**
 * The library statuses whose shows post their episodes: being watched, watched, or paused. A
 * planned show has not been started and a dropped one was left; a franchise loaded for nobody
 * (For you) has no status at all — which is what keeps these posts in Following.
 */
const EPISODE_STATUSES: ReadonlySet<WatchStatus> = new Set<WatchStatus>(['watching', 'completed', 'paused'])
/**
 * A part of the main story, by the rule the app itself uses (ios `FranchisePart.isMainStory`) and by
 * nothing the stored rows are unreliable about: `optional`, and SIDE_STORY on a season, were written
 * for seasons that merely HAVE a side story (grouping/relationship.ts — true until
 * `npm run relations:backfill -- --apply` has run), and reading them here kept My Hero Academia's
 * and Gintama's seasons out of the episode posts.
 *   a season: not short-form, not a spin-off;
 *   an ONA run (a show with no such season): the root, or a link in its sequel chain.
 */
function isMainStory(p: FranchisePart): boolean {
  if (p.format === 'TV_SHORT') return false
  const relationship = (p.relationship ?? '').toUpperCase()
  if (p.kind === 'season') return relationship !== 'SPIN_OFF'
  return relationship === '' || relationship === 'SEQUEL' || relationship === 'PREQUEL'
}

/** The parts whose episodes are news: the main-story seasons; for a show with none, its main-story ONAs. */
function episodicParts(f: Franchise): FranchisePart[] {
  const seasons = f.parts.filter((p) => p.kind === 'season' && isMainStory(p))
  return seasons.length > 0 ? seasons : f.parts.filter((p) => p.kind === 'ona' && isMainStory(p))
}

/**
 * The part's newest episode that has aired by now — the rule the progress clamp and the episode
 * gate use (`slotPassed`: a timed slot at its instant, a date-only TMDB one from the day after its
 * date in the earliest time zone), read from the dated episodes the payload carries (`airings`: 8
 * days back). A slot that has struck counts at once, before the hourly sync moves `next` on. A part
 * still NOT_YET_RELEASED has aired nothing, whatever a passed slot says (as `airedCount`). Episodes
 * sharing an instant (a season drop) yield the highest number.
 */
function latestAired(p: FranchisePart, source: Franchise['source'], nowMs: number): Airing | null {
  if (p.status === 'NOT_YET_RELEASED') return null
  let latest: Airing | null = null
  for (const a of p.airings) {
    if (!slotPassed(a.at, source, nowMs)) continue
    if (!latest || a.at > latest.at || (a.at === latest.at && a.episode > latest.episode)) latest = a
  }
  return latest
}

/** The post itself. Its id is the episode's own thread subject: the post and the room are one. */
function episodePost(f: Franchise, p: FranchisePart, episode: number, time: FeedTime, discoveredAt: number): ComposedPost | null {
  const id = formatSubject({ kind: 'episode', mediaId: p.mediaId, episode })
  if (parseSubject(id)?.kind !== 'episode') return null
  return {
    id,
    kind: 'episode',
    origin: 'catalogue',
    franchiseId: f.id,
    installment: p.label,
    isMovie: p.kind === 'movie',
    part: toPartRef(p),
    episode,
    time,
    discoveredAt,
    // No title, no still, no synopsis: an episode's own details are spoilers.
    premiere: null,
    window: null,
    note: null,
    video: null,
    sources: [],
    isOfficial: false,
    thread: [],
  }
}

/**
 * An aired episode as a post, dated from its airing. A TMDB airing is a calendar date (its 17:00
 * UTC is synthesised): the post is carried at 12:00 UTC of that date, never after now, and never
 * prints a clock. It is NEW from the instant the slot struck (`slotStrikesAt`) — for a date-only
 * episode that is before its noon, so a visit between the two does not see it as new twice.
 */
function airedEpisodePost(f: Franchise, p: FranchisePart, airing: Airing, nowMs: number): ComposedPost | null {
  const dateOnly = f.source === 'tmdb'
  const at = dateOnly ? Math.min(Math.floor(airing.at / DAY_MS) * DAY_MS + DAY_MS / 2, nowMs) : airing.at
  return episodePost(f, p, airing.episode, { at, dateOnly, basis: 'aired' }, slotStrikesAt(airing.at, f.source))
}

/**
 * "Episode N is out": for a show the viewer watches, watched or paused, one post per main-story
 * part — its newest aired episode, for a week after it aired, whether or not the viewer has seen it.
 * Composed only for a request that asked (`ComposeInput.episodes`).
 */
function episodePosts(f: Franchise, nowMs: number): ComposedPost[] {
  const status = f.subscription?.status
  if (!status || !EPISODE_STATUSES.has(status)) return []
  const posts: ComposedPost[] = []
  for (const p of episodicParts(f)) {
    const airing = latestAired(p, f.source, nowMs)
    if (!airing || nowMs - slotStrikesAt(airing.at, f.source) > EPISODE_NEWS_MS) continue
    const post = airedEpisodePost(f, p, airing, nowMs)
    if (post) posts.push(post)
  }
  return posts
}

/**
 * An episode post by id, for any part of the franchise and any episode that is out (D16: its likes,
 * saves and room stay reachable after the feed lets it go). Dated from its airing while the payload
 * still carries it; an older episode's air instant is gone from the lean payload, so — as a delisted
 * trailer — it composes only while someone holds a row on it, dated at that row (`orphanAt`), and is
 * never new. Null for an episode that has not aired.
 */
function episodePostById(f: Franchise, p: FranchisePart, episode: number, nowMs: number, orphanAt: number | null): ComposedPost | null {
  if (p.status === 'NOT_YET_RELEASED') return null
  const airing = p.airings.find((a) => a.episode === episode)
  if (airing) return slotPassed(airing.at, f.source, nowMs) ? airedEpisodePost(f, p, airing, nowMs) : null
  if (episode > p.airedEpisodes || orphanAt == null) return null
  return episodePost(f, p, episode, { at: Math.min(orphanAt, nowMs), dateOnly: false, basis: 'observed' }, 0)
}

// ---------- Composition ----------

/**
 * A research post whose installment has arrived is not news any more — the story tray and the show
 * page own an airing installment. Research re-runs at most daily and not at all for shows nobody
 * follows, so its last word ("premieres 24 September", "arrives this fall") can outlive the
 * premiere by days. The feed leaves such a post out when the installment's part has left
 * NOT_YET_RELEASED, or when its premiere passed more than a day ago; by id it still composes (D16),
 * as not live. A catalogue post is unreleased by construction.
 */
function isSpentNews(post: ComposedPost, nowMs: number): boolean {
  if (post.origin !== 'research') return false
  const status = post.part?.status ?? null
  if (status != null && status !== 'NOT_YET_RELEASED') return true
  return post.premiere != null && post.premiere.at + PREMIERE_SPENT_MS <= nowMs
}

function composeFranchise(f: Franchise, input: ComposeInput): ComposedPost[] {
  const obs = observationsFor(input, f.id)
  const news = newsCandidate(f, obs, input)
  const live = news && !isSpentNews(news, input.nowMs) ? news : null
  const latest = obs[0]
  const withdrawn = latest && (input.announcements.get(f.id) ?? []).some(a => a.id === latest.announcementId && a.status === 'retracted')
  const trailerOwner = news ?? (latest && !withdrawn ? researchPost(f, latest, obs, null, input.nowMs) : null)
  // A spent news post still claims its own trailer (and the ones cut around it): the installment's
  // story is over in the feed, not re-told as a trailer post.
  return [
    ...(live ? [live] : []),
    ...trailerPosts(f, trailerOwner, input.nowMs),
    ...(input.episodes === true ? episodePosts(f, input.nowMs) : []),
  ]
}

/** Every post for every franchise, in franchise order, unordered within. `orderPosts` sorts them. */
export function composePosts(input: ComposeInput): ComposedPost[] {
  return input.franchises.flatMap((f) => composeFranchise(f, input))
}

/** What `composePostById` needs beyond the input to keep a thread reachable. */
export interface ComposeByIdOptions {
  /**
   * The instant of the thread's first social row (like, comment, save or reminder), for a post the
   * catalogue can no longer date: a `trailer:` id whose video it no longer lists (composed bare,
   * `orphanTrailerPost`), or an `ep:` id whose air instant has left the payload (`episodePostById`).
   * Absent — nobody holds a row on it — such an id composes to null.
   */
  orphanAt?: number | null
}

/**
 * One post by id, including one the feed no longer carries (D16: real comments stay reachable from
 * notifications and Saved after the post leaves the feed). `live` is true exactly when
 * `composePosts` also emits the returned id — for an `ep:` id, only for a viewer whose Following
 * carries it (the franchise loaded with their status, the input composing episodes; the post
 * itself composes by id either way). A `catalog:` part that has premiered since
 * still composes (not live), as does a `news:` post whose installment has arrived and an episode
 * that is no longer its part's newest. Null for an unknown id, a part or franchise the catalogue no
 * longer has, an episode that has not aired, or a delisted trailer (or an episode the payload can
 * no longer date) nobody holds a row on.
 */
export function composePostById(
  input: ComposeInput,
  postId: string,
  opts: ComposeByIdOptions = {},
): { post: ComposedPost; live: boolean } | null {
  const parsed = parseSubject(postId)
  if (!parsed) return null

  let found: { f: Franchise; post: ComposedPost } | null = null
  switch (parsed.kind) {
    case 'news': {
      const a = parsed.announcementId
      const f = input.franchises.find(
        (candidate) =>
          (input.announcements.get(candidate.id) ?? []).some((row) => row.id === a) ||
          (input.observations.get(candidate.id) ?? []).some((o) => o.announcementId === a),
      )
      if (!f) return null
      // A corrected identity/source error must not resurrect from immutable snapshots on a saved link.
      if ((input.announcements.get(f.id) ?? []).some(row => row.id === a && row.status === 'retracted')) return null
      const obs = observationsFor(input, f.id)
      const ofAnnouncement = obs.filter((o) => o.announcementId === a && o.next.trim() !== '')
      // The newest observation of this announcement when it states news, else the newest one that did.
      const latest = ofAnnouncement.find((o) => kindOf(o.status) != null)
      if (!latest) return null
      let override: CatalogueOverride | null = null
      if (latest.status === 'rumored') {
        const catPart = pickCatalogUpcomingPart(f.parts, input.nowMs)
        const rumoured = matchPart(installmentName(latest.next).name, f.parts)
        if (catPart && rumoured?.mediaId === catPart.mediaId) override = catalogueOverride(f, catPart)
      }
      const post = researchPost(f, latest, obs, override, input.nowMs)
      if (post) found = { f, post }
      break
    }
    case 'catalog': {
      // Whatever the part's status now: its likes, saves, reminders and replies still hang off this
      // id after it premieres, so the thread stays reachable (not live — the feed carries only an
      // unreleased part).
      const f = input.franchises.find((candidate) => candidate.parts.some((p) => p.mediaId === parsed.mediaId))
      const part = f?.parts.find((p) => p.mediaId === parsed.mediaId)
      if (!f || !part) return null
      const post = cataloguePost(f, part, input)
      if (post) found = { f, post }
      break
    }
    case 'trailer': {
      const f = input.franchises.find((candidate) => candidate.id === parsed.franchiseId)
      if (!f) return null
      // The horizon, the news-video exclusion and the one-per-installment rule are feed curation,
      // not identity: a trailer someone saved stays openable.
      const v = videoPool(f).find((candidate) => candidate.site.toLowerCase() === parsed.site && candidate.id === parsed.videoId)
      const t = v && isPostableVideo(v) ? parseEvidenceDate(v.publishedAt, input.nowMs) : null
      const id = v ? trailerId(f, v) : null
      if (v && t && id) {
        found = { f, post: trailerPost(f, v, t, id, input.nowMs) }
      } else if (opts.orphanAt != null) {
        // Delisted (or no longer a postable, dated trailer) while the thread holds rows: bare.
        found = { f, post: orphanTrailerPost(f, formatSubject(parsed), opts.orphanAt) }
      } else {
        return null
      }
      break
    }
    case 'episode': {
      const f = input.franchises.find((candidate) => candidate.parts.some((p) => p.mediaId === parsed.mediaId))
      const part = f?.parts.find((p) => p.mediaId === parsed.mediaId)
      if (!f || !part) return null
      const post = episodePostById(f, part, parsed.episode, input.nowMs, opts.orphanAt ?? null)
      if (post) found = { f, post }
      break
    }
  }
  if (!found) return null
  const { f, post } = found
  const live = composeFranchise(f, input).some((p) => p.id === post.id)
  return { post, live }
}

/**
 * The feed's order (D8): the fresh block first — posts the app learned of since the viewer's
 * previous visit, so the pill and the caught-up marker have one boundary — then everything else;
 * inside each block newest `time` first, then id, so equal times never flicker. With no previous
 * visit (0) nothing is fresh.
 */
export function orderPosts<T extends { id: string; time: FeedTime; discoveredAt: number }>(
  posts: readonly T[],
  prevOpenedAt: number,
): (T & { fresh: boolean })[] {
  return posts
    .map((post) => ({ ...post, fresh: prevOpenedAt > 0 && post.discoveredAt > prevOpenedAt }))
    .sort((a, b) => (a.fresh ? 0 : 1) - (b.fresh ? 0 : 1) || b.time.at - a.time.at || compareText(a.id, b.id))
}
