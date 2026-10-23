// When a streaming platform's new episodes become watchable (23 Oct: "Let's have platform specific
// table", owner, of Avatar: Seven Havens — Paramount+ — reading "Airs today" with no time). TMDB
// dates a streaming drop with no clock and TVmaze leaves a web channel's airtime blank, so a
// platform's own release CONVENTION is the best fact there is: one wall-clock time in one zone for
// every original it drops. Only platforms whose convention is reported consistently are listed;
// every other network stays a date (services/broadcast.ts). Pure and import-free, so the slot rule
// (airingSlot.ts) and the feed's composer can share it.
//
// Sources (23 Oct 2026):
//   Netflix — 12:00 AM Pacific / 3:00 AM Eastern, worldwide at once; live events and anime are the
//     exceptions (Dexerto, "What time does Netflix release new shows"; Netflix Life). Anime is
//     AniList's, never a TMDB show here.
//   Prime Video — 12:00 AM Pacific / 3:00 AM Eastern, 8:00 AM in the UK (Invincible S4, Fallout S2
//     guides; National World's Clarkson's Farm release-time piece). Some premieres move to 6 PM
//     Pacific the evening before: the app is then later than the platform, never earlier.
//   Paramount+ — 3:00 AM Eastern / 12:00 AM Pacific (Avatar: Seven Havens release guides).
// Left out for want of one convention: Apple TV, Disney+, HBO Max, Hulu, Peacock — their originals
// drop at different times show by show (9 PM Eastern the evening before is common).

/** One platform's convention: its TMDB network names and the local wall-clock time of a drop. */
export interface StreamingDrop {
  /** TMDB network names, exactly as `media.studios` stores them. */
  networks: readonly string[]
  hour: number
  minute: number
  /** IANA zone the wall-clock time is in (DST-aware). */
  zone: string
}

export const STREAMING_DROPS: readonly StreamingDrop[] = [
  { networks: ['Netflix'], hour: 0, minute: 0, zone: 'America/Los_Angeles' },
  { networks: ['Prime Video'], hour: 0, minute: 0, zone: 'America/Los_Angeles' },
  { networks: ['Paramount+'], hour: 3, minute: 0, zone: 'America/New_York' },
]

/** The platform a TMDB season drops on: its FIRST network (the original one — a show that moved
 *  from broadcast to a platform lists the broadcaster first and stays a date), when it is listed. */
export function streamingDrop(networks: readonly string[] | null | undefined): StreamingDrop | null {
  const first = networks?.[0]
  if (!first) return null
  return STREAMING_DROPS.find((drop) => drop.networks.includes(first)) ?? null
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
