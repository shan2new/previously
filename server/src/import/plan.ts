// History import (4 Oct 2026): how what another tracker knew becomes this one's library. PURE —
// no IO; the service (import/service.ts) reads the catalogue and writes the result.
//
// The complaint about every importer the TV Time shutdown produced was FIDELITY, not
// availability: episodes missing, finished series left half-marked, a history re-ticked by hand
// (design/onboarding-2026-10-04/SPIKE.md). So the rules here are about not inventing anything:
//
// - progress is only ever what the source said, capped by what has aired (the service clamps);
// - a show is `completed` only when the story is watched THROUGH — every released season — and
//   never because one season's entry said so;
// - a show nobody has touched in months is not handed to Home as a backlog (`paused`, not
//   `watching`): an obligation invented out of an old list is the app's own failure mode.

export type ListStatus = 'watching' | 'completed' | 'planned' | 'paused' | 'dropped'

/** One list entry about ONE AniList media (a season, a film, an OVA) — AniList's and MAL's unit. */
export interface AnimeEntry {
  /** AniList media id. */
  mediaId: number
  status: ListStatus
  /** Episodes watched of this media, as the source counted them. */
  progress: number
  /** The source filed it finished (COMPLETED, or a rewatch of something finished). */
  finished: boolean
  title: string | null
  /** Source explicitly classified this entry under the existing adult-content exclusion. */
  contentExcluded?: boolean
}

/** One show as TV Time knew it: seasons and the episodes seen in each, by TheTVDB's numbering. */
export interface TvShow {
  tvdbId: number | null
  title: string
  seasons: { number: number; watched: number[] }[]
  followed: boolean
  forLater: boolean
  archived: boolean
  /** The newest watch, ms epoch; null when the export carried no dates. */
  lastWatchedAt: number | null
}

/** A catalogue member as the planner needs it. */
export interface MemberRow {
  mediaId: number
  franchiseId: string
  partKind: string
  /** TV: the season number. Anime: the member's place in the franchise. */
  sequence: number
  relationship: string | null
  status: string | null
  /** Episodes out by now (the aired count; a finished part's size). */
  released: number
  /** Same ceiling as a library progress write; omitted by pure fixtures. */
  ceiling?: number
}

export interface FranchisePlan {
  franchiseId: string
  status: ListStatus
  /** Absolute watched counts per member; only members with something watched. */
  parts: { mediaId: number; episodes: number }[]
}

/** A show watched within this long is still being watched; older, it is paused. */
export const RECENT_WATCH_MS = 120 * 24 * 60 * 60 * 1000

const isUpcoming = (m: MemberRow) => m.status === 'NOT_YET_RELEASED'
const isReleasing = (m: MemberRow) => m.status === 'RELEASING'
const capped = (m: MemberRow, n: number) => Math.min(n,
  m.ceiling ?? (isUpcoming(m) ? 0 : m.released > 0 ? m.released : Number.MAX_SAFE_INTEGER))

/**
 * The story's spine: its seasons, less spin-offs; a franchise with no season (a film series) is
 * its films. Extras (OVAs, specials, music) never hold a show open — the app's own rule for
 * "watched through" (`Franchise.isWatchedThrough`).
 */
export function spine(members: MemberRow[]): MemberRow[] {
  const seasons = members.filter((m) => m.partKind === 'season' && m.relationship?.toUpperCase() !== 'SPIN_OFF')
  if (seasons.length > 0) return seasons
  return members.filter((m) => m.partKind === 'movie')
}

/** Every released part of the spine is watched to what has come out. */
export function watchedThrough(members: MemberRow[], watched: Map<number, number>): boolean {
  const released = spine(members).filter((m) => !isUpcoming(m) && m.released > 0)
  return released.length > 0 && released.every((m) => (watched.get(m.mediaId) ?? 0) >= m.released)
}

/**
 * An anime franchise from its list entries (one per season / film the viewer had on their list).
 *
 * Status, in order: someone watching any part of it is WATCHING; else paused if any part was put
 * on hold; else dropped if any part was dropped; else COMPLETED when the story is watched through.
 * What is left is a show with more released than they have seen and nobody watching it: PLANNED
 * when a part of it is on their plan-to-watch list (or nothing is watched at all), else PAUSED —
 * "finished Naruto and Shippuden, never started Boruto" is where they stopped, not a plan. Either
 * way their place is kept and the show stays off Home until they come back to it.
 */
export function planAnimeFranchise(entries: AnimeEntry[], members: MemberRow[]): FranchisePlan | null {
  const byId = new Map(members.map((m) => [m.mediaId, m]))
  const mine = entries.filter((e) => byId.has(e.mediaId))
  if (mine.length === 0) return null

  const watched = new Map<number, number>()
  for (const entry of mine) {
    const member = byId.get(entry.mediaId)!
    // A finished entry is the whole part, whatever count the list carried (MAL keeps 0 watched on
    // some completed rows; a rewatch in flight counts only the rewatch).
    const episodes = capped(member, entry.finished ? Math.max(entry.progress, member.released) : entry.progress)
    if (episodes > 0) watched.set(entry.mediaId, Math.max(watched.get(entry.mediaId) ?? 0, episodes))
  }

  const statuses = new Set(mine.map((e) => e.status))
  let status: ListStatus
  if (statuses.has('watching')) status = 'watching'
  else if (statuses.has('paused')) status = 'paused'
  else if (statuses.has('dropped')) status = 'dropped'
  else if (watchedThrough(members, watched)) status = 'completed'
  else if (statuses.has('planned') || watched.size === 0) status = 'planned'
  else status = 'paused'

  return {
    franchiseId: members[0]!.franchiseId,
    status,
    parts: [...watched].map(([mediaId, episodes]) => ({ mediaId, episodes })),
  }
}

/**
 * A TV show from TV Time's episode log. Seasons map by number (a TMDB franchise's members carry
 * `sequence` = season number); a season's count is the HIGHEST episode seen — the app's progress
 * is "watched through N", and the highest is where the viewer is.
 *
 * Status: nothing watched is PLANNED when the show was followed or saved for later (and not
 * archived), else it is not imported at all. Watched through with nothing airing is COMPLETED;
 * watched through with more on the way is WATCHING (caught up). Part-way: archived is PAUSED;
 * otherwise WATCHING if they watched it lately (`RECENT_WATCH_MS`) and PAUSED if not — a show
 * last touched two years ago is not tonight's backlog.
 */
export function planTvFranchise(show: TvShow, members: MemberRow[], nowMs: number): FranchisePlan | null {
  if (members.length === 0) return null
  const bySeason = new Map(members.filter((m) => m.partKind === 'season' || m.partKind === 'special').map((m) => [m.sequence, m]))
  const watched = new Map<number, number>()
  for (const season of show.seasons) {
    const member = bySeason.get(season.number)
    const highest = season.watched.reduce((max, n) => (Number.isFinite(n) && n > max ? Math.floor(n) : max), 0)
    if (!member || highest <= 0) continue
    const episodes = capped(member, highest)
    if (episodes > 0) watched.set(member.mediaId, Math.max(watched.get(member.mediaId) ?? 0, episodes))
  }
  const franchiseId = members[0]!.franchiseId
  const parts = [...watched].map(([mediaId, episodes]) => ({ mediaId, episodes }))

  if (parts.length === 0) {
    if (show.archived || !(show.followed || show.forLater)) return null
    return { franchiseId, status: 'planned', parts: [] }
  }
  if (watchedThrough(members, watched)) {
    const more = spine(members).some((m) => isReleasing(m) || isUpcoming(m))
    return { franchiseId, status: more ? 'watching' : 'completed', parts }
  }
  if (show.archived) return { franchiseId, status: 'paused', parts }
  const recent = show.lastWatchedAt != null && nowMs - show.lastWatchedAt <= RECENT_WATCH_MS
  return { franchiseId, status: recent ? 'watching' : 'paused', parts }
}

// MARK: Source vocabularies

/** AniList's `MediaListStatus`. REPEATING is a rewatch: the show itself is finished. */
export function fromAniListStatus(status: string | null | undefined): { status: ListStatus; finished: boolean } | null {
  switch (status) {
    case 'CURRENT': return { status: 'watching', finished: false }
    case 'REPEATING': return { status: 'watching', finished: true }
    case 'COMPLETED': return { status: 'completed', finished: true }
    case 'PLANNING': return { status: 'planned', finished: false }
    case 'PAUSED': return { status: 'paused', finished: false }
    case 'DROPPED': return { status: 'dropped', finished: false }
    default: return null
  }
}

/** MyAnimeList's `my_status`, as the export writes it (words) or as older exports did (numbers). */
export function fromMalStatus(status: string | null | undefined): { status: ListStatus; finished: boolean } | null {
  switch ((status ?? '').trim().toLowerCase()) {
    case 'watching': case '1': return { status: 'watching', finished: false }
    case 'completed': case '2': return { status: 'completed', finished: true }
    case 'on-hold': case 'on hold': case '3': return { status: 'paused', finished: false }
    case 'dropped': case '4': return { status: 'dropped', finished: false }
    case 'plan to watch': case '6': return { status: 'planned', finished: false }
    default: return null
  }
}

/** Titles compared for an exact match: case, punctuation and a trailing "(2019)" do not count. */
export function normalizeTitle(value: string): string {
  return value
    .normalize('NFKC')
    .toLocaleLowerCase('en-US')
    .replace(/\(\d{4}\)\s*$/u, '')
    .replace(/[^\p{L}\p{N}]+/gu, ' ')
    .trim()
}

/**
 * A TV Time show that is really an ANIME (the catalogue keeps Japanese animation under AniList,
 * whose seasons are not TheTVDB's): the episodes seen are counted and laid along the story's spine
 * in order — the first N episodes of the story — because the two sources cut the same run into
 * seasons differently, and a per-season mapping would mark the wrong half. Specials (season 0)
 * are left out of the count. Status follows the TV rule.
 */
export function planTvShowAsAnime(show: TvShow, members: MemberRow[], nowMs: number): FranchisePlan | null {
  if (members.length === 0) return null
  const franchiseId = members[0]!.franchiseId
  let left = show.seasons
    .filter((s) => s.number > 0)
    .reduce((sum, s) => sum + new Set(s.watched.filter((n) => Number.isFinite(n) && n > 0)).size, 0)
  const watched = new Map<number, number>()
  for (const member of [...spine(members)].sort((a, b) => a.sequence - b.sequence)) {
    if (left <= 0) break
    if (member.released <= 0) continue
    const take = Math.min(left, member.released)
    watched.set(member.mediaId, take)
    left -= take
  }
  const parts = [...watched].map(([mediaId, episodes]) => ({ mediaId, episodes }))
  if (parts.length === 0) {
    if (show.archived || !(show.followed || show.forLater)) return null
    return { franchiseId, status: 'planned', parts: [] }
  }
  if (watchedThrough(members, watched)) {
    const more = spine(members).some((m) => isReleasing(m) || isUpcoming(m))
    return { franchiseId, status: more ? 'watching' : 'completed', parts }
  }
  if (show.archived) return { franchiseId, status: 'paused', parts }
  const recent = show.lastWatchedAt != null && nowMs - show.lastWatchedAt <= RECENT_WATCH_MS
  return { franchiseId, status: recent ? 'watching' : 'paused', parts }
}
