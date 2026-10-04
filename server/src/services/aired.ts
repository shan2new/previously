import type { EpisodeAccess, EpisodeMeta } from '../types/api.js'
import { slotPassed } from './airingSlot.js'
import { deriveAiredEpisodes } from './franchiseView.js'

// "Has episode n aired by now?" — ONE rule, shared by the progress clamp (`PUT /me/progress`, the
// franchise progress commands, the unaired-season repair) and the episode-discussion gate
// (`services/episodeGate.ts`). Pure: everything comes from the media row and an explicit `nowMs`.
//
// Three things the older `deriveAiredEpisodes`-only count got wrong, all fixed here:
//   - `media.next_airing_episode` is refreshed HOURLY (sync/cron.ts), so for up to an hour after a
//     slot struck the catalogue still said "episode 8 is next". A slot that has passed IS an aired
//     episode, so a passed `next` (and any passed dated entry) counts at once.
//   - the RELEASING ceiling was `max(media.episodes, aired)`, the season's SIZE, which let a
//     12-episode season with 5 aired be marked to 12. A releasing part is now capped at what has
//     aired, whenever that is known at all.
//   - for an open-ended part (RELEASING, HIATUS, CANCELLED) with no `next` slot and an undated
//     list, `deriveAiredEpisodes` falls back to the catalogue's TOTAL — every announced episode
//     "aired" — which let a schedule gap open rooms for episodes still to come. Those parts count
//     only from EVIDENCE (a slot or a dated episode); with none the count is unknown and the gate
//     fails closed. Only a FINISHED part is its size.

export interface AiredInput {
  /** media.source: 'anilist' | 'tmdb'. TMDB slots are date-only (17:00 UTC is synthesised). */
  source: string
  status: string | null
  episodes: number | null
  /** media.next_airing_episode — `airingAt` in SECONDS. */
  next: { episode: number; airingAt: number } | null
  episodesList: EpisodeMeta[] | null
}

/** `aired`: episodes out by now. `known`: whether the row carries any evidence of a count at all. */
export interface AiredCount {
  aired: number
  known: boolean
}

// The slot rule itself lives in airingSlot.ts (no imports, so the feed's pure composer can share it).
export { DATE_ONLY_LEAD_MS, slotPassed, slotStrikesAt } from './airingSlot.js'

/** The statuses whose episodes are still (or were only partly) coming: counted from evidence only. */
const OPEN_ENDED = new Set(['RELEASING', 'HIATUS', 'CANCELLED'])

/** A whole, non-negative count; NaN and ±Infinity read as 0. */
function whole(n: number | null | undefined): number {
  return typeof n === 'number' && Number.isFinite(n) ? Math.max(0, Math.floor(n)) : 0
}

/** How many episodes of a part are out by `nowMs`, and whether that is known at all. */
export function airedCount(row: AiredInput, nowMs: number): AiredCount {
  // An announced part has aired nothing, whatever a passed slot or the catalogue's size says.
  if (row.status === 'NOT_YET_RELEASED') return { aired: 0, known: true }

  const list = row.episodesList ?? []
  // The SANITISED slot: one with no instant (airingAt ≤ 0) is no evidence of a count, and treating
  // it as known would clamp every mark on the part to 0.
  const next = row.next && row.next.airingAt > 0 ? row.next : null

  if (row.status != null && OPEN_ENDED.has(row.status)) {
    // Evidence only — never the catalogue's total, which counts announced episodes as aired.
    let aired = next ? Math.max(0, next.episode - 1) : 0
    if (next && next.episode > aired && slotPassed(next.airingAt * 1000, row.source, nowMs)) aired = next.episode
    for (const e of list) {
      if (e.airDate != null && e.number > aired && slotPassed(e.airDate, row.source, nowMs)) aired = e.number
    }
    return { aired, known: next != null || list.some((e) => e.airDate != null) }
  }

  const derived = deriveAiredEpisodes({
    status: row.status,
    totalEpisodes: row.episodes ?? 0,
    next,
    episodes: list,
    nowMs,
  })
  return { aired: derived, known: derived > 0 || (row.episodes ?? 0) > 0 }
}

/**
 * The value a progress write may store for a part (replaces library.ts `clampProgress`). The
 * ceiling bounds only an INCREASE: `current` (the stored count) always stays reachable, so a mark
 * written before this ceiling existed — 12 of a season with 5 aired — is never pulled DOWN by the
 * next write ("a progress mark never rolls back"; unmarking 12 → 11 writes 11, not 5).
 *
 * - NOT_YET_RELEASED: 0 — a season that has not premiered cannot have been watched.
 * - RELEASING: capped at the aired count when it is known. When nothing about the count is known
 *   (no slot, no dated episode) the gate no longer relies on progress (it is locked), so the cap
 *   falls back to the part's size, or none when unsized.
 * - Anything else: capped at the part's size `max(episodes, aired)`; unsized stays unbounded.
 */
export function clampProgressValue(row: AiredInput, value: number, nowMs: number, current: number = 0): number {
  const v = whole(value)
  if (row.status === 'NOT_YET_RELEASED') return 0
  const count = airedCount(row, nowMs)
  const airedCap = row.status === 'RELEASING' && count.known
  const ceiling = airedCap ? count.aired : Math.max(row.episodes ?? 0, count.aired)
  // A size ceiling of 0 is no size at all: an unsized part stays unbounded.
  if (!airedCap && ceiling <= 0) return v
  return Math.min(v, Math.max(ceiling, whole(current)))
}

/**
 * The value `caught_up` / `completed` store for a part: everything that has aired (or, when the
 * count is unknown, the part's size, as before), and never less than what is already stored —
 * only a `reset` walks progress back.
 */
export function caughtUpValue(row: AiredInput, nowMs: number, current: number = 0): number {
  if (row.status === 'NOT_YET_RELEASED') return 0
  const count = airedCount(row, nowMs)
  const target = count.known ? count.aired : whole(row.episodes)
  return Math.max(whole(current), clampProgressValue(row, target, nowMs, current))
}

/**
 * The episode-room gate: `unaired` first (a known count below `episode`, or no count at all —
 * a room fails CLOSED until the catalogue has a slot or dates, or the part finishes), then
 * `unwatched` (progress below it), else `open`.
 */
export function episodeAccess(input: { progress: number; episode: number; count: AiredCount }): EpisodeAccess {
  if (!input.count.known || input.episode > input.count.aired) return 'unaired'
  if (input.progress < input.episode) return 'unwatched'
  return 'open'
}

/**
 * The progress a gate compares against: the stored count under the same read-time guard as
 * franchiseView `toPart` — a NOT_YET_RELEASED part reports at most what has aired of it (nothing),
 * so a mark written before the write clamp existed cannot open a room on an unaired season.
 */
export function gatedProgress(status: string | null, watched: number, count: AiredCount): number {
  const w = Number.isFinite(watched) ? Math.max(0, Math.floor(watched)) : 0
  return status === 'NOT_YET_RELEASED' ? Math.min(w, count.aired) : w
}
