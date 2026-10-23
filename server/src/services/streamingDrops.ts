// When a streaming platform's new episodes become watchable (23 Oct: "Let's have platform specific
// table", owner, of Avatar: Seven Havens — Paramount+ — reading "Airs today" with no time). TMDB
// dates a streaming drop with no clock and TVmaze leaves a web channel's airtime blank, so a
// platform's own release CONVENTION is the best fact there is: one wall-clock time in one zone, on
// TMDB's date, for every original it drops. Only platforms whose convention TheTVDB records
// consistently are listed; every other network stays a date (services/broadcast.ts). Pure and
// import-free, so the slot rule (airingSlot.ts) and the feed's composer can share it.
//
// Checked 23 Oct 2026 against TheTVDB's per-show "Airs" time (US Eastern) for 133 shows, and TMDB's
// episode dates against TVmaze's for 31 (docs/audits/2026-10-23/README.md):
//   Netflix, Prime Video, Paramount+, Peacock — 3:00 AM Eastern (12:00 AM Pacific), worldwide.
//     Netflix's event drops (Stranger Things' 8 PM Eastern finale) are the known exception.
//   HBO Max ("Max" until 2025) and Disney+ — 9:00 PM Eastern for a US original (The Pitt, Hacks,
//     Andor, Daredevil: Born Again); an international original drops at the global 3:00 AM
//     Eastern (Disney+'s Korean series at 4 PM in Seoul, HBO Max's Paolo, Collision).
//   Hulu — 12:00 AM Eastern; TMDB and TVmaze date its episodes alike.
//   Apple TV — 12:00 AM Eastern, but TMDB files a US original under the PACIFIC date, the evening
//     before (Severance, Silo, Dark Matter, Pluribus: 8 of 10), so its rule is 9:00 PM Pacific on
//     TMDB's date; a British original (Slow Horses, Last Seen) carries the Eastern date.
// A show of unknown origin (`media.origin_countries` not yet written) and a co-production that lists
// the US (Collision: MX, US) read the US rule, which is never earlier than the international one. Left out: MGM+, STARZ (broadcast slots TVmaze times),
// the Chinese and Korean platforms (a different time per show) and YouTube.

/** A wall-clock time in one zone (DST-aware). */
export interface StreamingDrop {
  hour: number
  minute: number
  /** IANA zone the wall-clock time is in. */
  zone: string
}

/** One platform's convention: its TMDB network names, the drop of a US original, and the drop of
 *  an original made elsewhere when that differs. */
export interface StreamingPlatform {
  /** TMDB network names, exactly as `media.studios` stores them. */
  networks: readonly string[]
  drop: StreamingDrop
  international?: StreamingDrop
}

const PACIFIC_MIDNIGHT: StreamingDrop = { hour: 0, minute: 0, zone: 'America/Los_Angeles' }
const EASTERN_3AM: StreamingDrop = { hour: 3, minute: 0, zone: 'America/New_York' }
const EASTERN_9PM: StreamingDrop = { hour: 21, minute: 0, zone: 'America/New_York' }

export const STREAMING_PLATFORMS: readonly StreamingPlatform[] = [
  { networks: ['Netflix'], drop: PACIFIC_MIDNIGHT },
  { networks: ['Prime Video'], drop: PACIFIC_MIDNIGHT },
  { networks: ['Paramount+'], drop: EASTERN_3AM },
  { networks: ['Peacock'], drop: EASTERN_3AM },
  { networks: ['HBO Max', 'Max'], drop: EASTERN_9PM, international: EASTERN_3AM },
  { networks: ['Disney+'], drop: EASTERN_9PM, international: EASTERN_3AM },
  { networks: ['Hulu'], drop: { hour: 0, minute: 0, zone: 'America/New_York' } },
  {
    networks: ['Apple TV'],
    drop: { hour: 21, minute: 0, zone: 'America/Los_Angeles' },
    international: { hour: 0, minute: 0, zone: 'America/New_York' },
  },
]

/**
 * When a TMDB season drops: the platform of its FIRST network (the original one — a show that moved
 * from broadcast to a platform lists the broadcaster first and stays a date), at the international
 * time for a show made outside the US (`countries`: TMDB's origin countries), else the US time.
 */
export function streamingDrop(
  networks: readonly string[] | null | undefined,
  countries?: readonly string[] | null,
): StreamingDrop | null {
  const first = networks?.[0]
  if (!first) return null
  const platform = STREAMING_PLATFORMS.find((entry) => entry.networks.includes(first))
  if (!platform) return null
  const abroad = countries != null && countries.length > 0 && !countries.includes('US')
  return abroad && platform.international ? platform.international : platform.drop
}

const DAY_MS = 86_400_000
const formatters = new Map<string, Intl.DateTimeFormat>()

/** `zone`'s offset from UTC at `atMs`, in ms (positive east of Greenwich). */
function zoneOffset(zone: string, atMs: number): number {
  let format = formatters.get(zone)
  if (!format) {
    format = new Intl.DateTimeFormat('en-US', {
      timeZone: zone, hourCycle: 'h23',
      year: 'numeric', month: 'numeric', day: 'numeric', hour: 'numeric', minute: 'numeric', second: 'numeric',
    })
    formatters.set(zone, format)
  }
  const part = (type: Intl.DateTimeFormatPartTypes) =>
    Number(format.formatToParts(atMs).find((p) => p.type === type)?.value ?? 0)
  const wall = Date.UTC(part('year'), part('month') - 1, part('day'), part('hour'), part('minute'), part('second'))
  return wall - Math.floor(atMs / 1000) * 1000
}

/**
 * The instant a TMDB-dated episode drops on `drop`'s platform: the platform's wall-clock time on the
 * episode's UTC calendar date (TMDB's date; the sync synthesizes 17:00 UTC on it, tmdb/mapping.ts).
 */
export function dropInstant(drop: StreamingDrop, tmdbMs: number): number {
  const day = Math.floor(tmdbMs / DAY_MS) * DAY_MS
  const wall = day + (drop.hour * 60 + drop.minute) * 60_000
  // The offset at the guess, then again at the answer: a drop beside a DST change lands on its
  // own side of it.
  const guess = wall - zoneOffset(drop.zone, wall)
  return wall - zoneOffset(drop.zone, guess)
}
