// "Has this airing slot struck?" — the one instant rule under the progress clamp, the
// episode-discussion gate (services/aired.ts) and the feed's "Episode N is out" posts
// (feed/compose.ts). Pure and import-free, so the composer shares it without loading the catalogue.

const DAY_MS = 86_400_000

/** The earliest instant ANY time zone's local date passes a date-only slot's UTC date (UTC+14). */
export const DATE_ONLY_LEAD_MS = 14 * 3_600_000

/**
 * The instant from which a slot counts as struck: its own instant when timed (AniList); 10:00 UTC of
 * its date when it is a calendar DATE (TMDB — the sync synthesises 17:00 UTC, tmdb/mapping.ts). The
 * iOS client counts a date-only slot from the day after that date in the DEVICE's local day, and the
 * earliest zone on Earth (UTC+14) reaches that day at 10:00 UTC on the slot's own UTC date.
 */
export function slotStrikesAt(atMs: number, source: string): number {
  if (source === 'tmdb') {
    const utcMidnight = Math.floor(atMs / DAY_MS) * DAY_MS
    return utcMidnight + DAY_MS - DATE_ONLY_LEAD_MS
  }
  return atMs
}

/**
 * Whether an airing slot has struck by `nowMs` (`slotStrikesAt`). Never stricter than any client —
 * a room the app shows unlocked, the server accepts.
 */
export function slotPassed(atMs: number, source: string, nowMs: number): boolean {
  return slotStrikesAt(atMs, source) <= nowMs
}
