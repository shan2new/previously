// "Has this airing slot struck?" — the one instant rule under the progress clamp, the
// episode-discussion gate (services/aired.ts) and the feed's "Episode N is out" posts
// (feed/compose.ts). Pure (its one import is the pure platform table), so the composer shares it
// without loading the catalogue.

import { dropInstant, streamingDrop } from './streamingDrops.js'

const DAY_MS = 86_400_000

/** The earliest instant ANY time zone's local date passes a date-only slot's UTC date (UTC+14). */
export const DATE_ONLY_LEAD_MS = 14 * 3_600_000

/**
 * The instant from which a slot counts as struck: its own instant when timed (AniList); 10:00 UTC of
 * its date when it is a calendar DATE (TMDB — the sync synthesises 17:00 UTC, tmdb/mapping.ts). The
 * iOS client counts a date-only slot from the day after that date in the DEVICE's local day, and the
 * earliest zone on Earth (UTC+14) reaches that day at 10:00 UTC on the slot's own UTC date.
 *
 * `networks` (`media.studios`): a TMDB season on a platform in the drop table strikes at that
 * platform's drop instant when it is earlier (12 AM Pacific is 07:00–08:00 UTC) — the clients read
 * such a show at the drop instant (franchiseView, `timesExact`), and the server is never stricter.
 */
export function slotStrikesAt(atMs: number, source: string, networks?: readonly string[] | null): number {
  if (source === 'tmdb') {
    const utcMidnight = Math.floor(atMs / DAY_MS) * DAY_MS
    const dateStrike = utcMidnight + DAY_MS - DATE_ONLY_LEAD_MS
    const drop = streamingDrop(networks)
    return drop ? Math.min(dateStrike, dropInstant(drop, atMs)) : dateStrike
  }
  return atMs
}

/**
 * The slot rule's `source` for one part: a TMDB season at real instants (`timesExact` — TVmaze's
 * broadcast or a platform's drop, services/broadcast.ts) strikes at its instant, as AniList's do;
 * any other TMDB season is a date.
 */
export function slotSource(source: string, timesExact: boolean): string {
  return source === 'tmdb' && timesExact ? 'tmdb:broadcast' : source
}

/**
 * Whether an airing slot has struck by `nowMs` (`slotStrikesAt`). Never stricter than any client —
 * a room the app shows unlocked, the server accepts.
 */
export function slotPassed(atMs: number, source: string, nowMs: number, networks?: readonly string[] | null): boolean {
  return slotStrikesAt(atMs, source, networks) <= nowMs
}
