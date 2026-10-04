import type { FranchiseUpcoming, FranchiseUpcomingView, ReleaseWindow } from '../types/api.js'

/**
 * Resolving `FranchiseUpcoming.release` — the prose window the news agent writes ("October 2026",
 * "Summer 2027", "Late 2026", "2027-01-09", "TBA") — into a fact a client can ORDER BY.
 *
 * This lives on the server because the string is written here (news/agent.ts) and because two
 * clients parsing the same prose is two chances to disagree: iOS shipped an ISO-only sort key
 * beside a month-name-aware caption, so a row that READ "Returns Oct 2026" SORTED as January 2026
 * and sat ahead of a show returning that August. Clients must render `release` and sort by
 * `sortKey`; they must never parse `release` themselves.
 */

const UNKNOWN: ReleaseWindow = { date: null, precision: 'unknown', sortKey: null }

const MONTHS = [
  'january', 'february', 'march', 'april', 'may', 'june',
  'july', 'august', 'september', 'october', 'november', 'december',
] as const

/** Broadcast seasons, as the catalogue means them: the quarter's FIRST month. */
const SEASONS: Record<string, number> = { winter: 1, spring: 4, summer: 7, fall: 10, autumn: 10 }

/**
 * Vague halves of a year. These resolve to the EARLIEST month the window can plausibly mean, which
 * is what `sortKey` promises — "Late 2026" belongs after "Spring 2026" and before "January 2027",
 * and only a month can express that. `precision` stays `year`, because the month is an ordering
 * device and not something a client may print.
 */
const QUALIFIERS: Record<string, number> = { early: 1, mid: 5, late: 9 }

const MONTH_ALTERNATION = MONTHS.map((m) => `${m.slice(0, 3)}(?:${m.slice(3)})?`).join('|')
const YEAR = '(20[0-9]{2})'

// "2027-01-09" / "2027-1-9". Bare `-` separators only: the agent writes ISO, never "01/09/2027".
const ISO_DAY = new RegExp(`${YEAR}-([0-9]{1,2})-([0-9]{1,2})(?![0-9])`)
// "2026-10". A range like "2027-2028" cannot match: 20 is not a month, and validation rejects it.
const ISO_MONTH = new RegExp(`${YEAR}-([0-9]{1,2})(?![0-9-])`)
// "January 9, 2027" / "Jan 9 2027" — the day must be adjacent to the year, so the "April 3 –
// September 2026" of a range falls through to the month rule below rather than inventing April 3.
const NAMED_DAY = new RegExp(`(${MONTH_ALTERNATION})\\.?\\s+([0-9]{1,2})(?:st|nd|rd|th)?,?\\s+${YEAR}`)
// "9 January 2027" — the same fact with the day first.
const DAY_NAMED = new RegExp(`([0-9]{1,2})(?:st|nd|rd|th)?\\s+(${MONTH_ALTERNATION})\\.?,?\\s+${YEAR}`)
const NAMED_MONTH = new RegExp(`(${MONTH_ALTERNATION})\\.?,?\\s+${YEAR}`)
const SEASON_ALTERNATION = Object.keys(SEASONS).join('|')
const SEASON_YEAR = new RegExp(`(${SEASON_ALTERNATION})\\s+${YEAR}`)
const YEAR_SEASON = new RegExp(`${YEAR}\\s+(${SEASON_ALTERNATION})`)
// "Q3 2026" / "3Q 2026" — quarters, written the way trade press writes them.
const QUARTER_YEAR = new RegExp(`q([1-4])\\s*${YEAR}|${YEAR}\\s*q([1-4])`)
const QUALIFIER_YEAR = new RegExp(`(${Object.keys(QUALIFIERS).join('|')})[\\s-]+${YEAR}`)
const BARE_YEAR = new RegExp(`(?<![0-9])${YEAR}(?![0-9])`)

const monthIndex = (name: string): number => MONTHS.findIndex((m) => m.startsWith(name.slice(0, 3))) + 1

const key = (y: number, m: number, d: number): number => y * 10000 + m * 100 + d
const pad = (n: number): string => String(n).padStart(2, '0')

const day = (y: number, m: number, d: number): ReleaseWindow => ({
  date: `${y}-${pad(m)}-${pad(d)}`,
  precision: 'day',
  sortKey: key(y, m, d),
})

const month = (y: number, m: number, precision: 'month' | 'quarter'): ReleaseWindow => ({
  date: `${y}-${pad(m)}`,
  precision,
  sortKey: key(y, m, 1),
})

const year = (y: number, m = 1): ReleaseWindow => ({
  date: String(y),
  precision: 'year',
  sortKey: key(y, m, 1),
})

const validYear = (y: number): boolean => y >= 1900 && y <= 2100
const validMonth = (m: number): boolean => m >= 1 && m <= 12
const validDay = (y: number, m: number, d: number): boolean => {
  const back = new Date(Date.UTC(y, m - 1, d))
  return back.getUTCFullYear() === y && back.getUTCMonth() === m - 1 && back.getUTCDate() === d
}

/**
 * Parse one release window. Rules are tried strongest-precision first, and each one matches
 * ANYWHERE in the string, because the agent writes sentences as often as dates ("Airing now
 * (April 3 – September 2026, cours 1–2 of 5)"). Anything that resolves to no year at all — "TBA",
 * an empty string, prose with no date in it — is `unknown`, which sorts last rather than to 1970.
 */
export function parseReleaseWindow(release: string | null | undefined): ReleaseWindow {
  const s = (release ?? '').toLowerCase().replace(/\s+/g, ' ').trim()
  if (!s) return UNKNOWN

  const iso = ISO_DAY.exec(s)
  if (iso) {
    const [y, m, d] = [Number(iso[1]), Number(iso[2]), Number(iso[3])]
    return validYear(y) && validMonth(m) && validDay(y, m, d) ? day(y, m, d) : UNKNOWN
  }

  for (const re of [NAMED_DAY, DAY_NAMED]) {
    const hit = re.exec(s)
    if (!hit) continue
    // The two rules order their captures differently; the year is always last.
    const [name, num] = re === NAMED_DAY ? [hit[1]!, Number(hit[2])] : [hit[2]!, Number(hit[1])]
    const y = Number(hit[3])
    const m = monthIndex(name)
    return validYear(y) && validMonth(m) && validDay(y, m, num) ? day(y, m, num) : UNKNOWN
  }

  const isoMonth = ISO_MONTH.exec(s)
  if (isoMonth) {
    const [y, m] = [Number(isoMonth[1]), Number(isoMonth[2])]
    return validYear(y) && validMonth(m) ? month(y, m, 'month') : UNKNOWN
  }

  const named = NAMED_MONTH.exec(s)
  if (named) {
    const y = Number(named[2])
    const m = monthIndex(named[1]!)
    if (validYear(y) && validMonth(m)) return month(y, m, 'month')
  }

  for (const re of [SEASON_YEAR, YEAR_SEASON]) {
    const hit = re.exec(s)
    if (!hit) continue
    const [name, y] = re === SEASON_YEAR ? [hit[1]!, Number(hit[2])] : [hit[2]!, Number(hit[1])]
    if (validYear(y)) return month(y, SEASONS[name]!, 'quarter')
  }

  const quarter = QUARTER_YEAR.exec(s)
  if (quarter) {
    // Either "q3 2026" (groups 1,2) or "2026 q3" (groups 3,4) matched.
    const q = Number(quarter[1] ?? quarter[4])
    const y = Number(quarter[2] ?? quarter[3])
    if (validYear(y)) return month(y, (q - 1) * 3 + 1, 'quarter')
  }

  const qualified = QUALIFIER_YEAR.exec(s)
  if (qualified) {
    const y = Number(qualified[2])
    if (validYear(y)) return year(y, QUALIFIERS[qualified[1]!]!)
  }

  const bare = BARE_YEAR.exec(s)
  if (bare) {
    const y = Number(bare[1])
    if (validYear(y)) return year(y)
  }

  return UNKNOWN
}

/**
 * The window for a franchise's `upcoming`, with one policy on top of the parse: a **rumored**
 * installment has no release window, whatever date the rumor names. An unconfirmed report is not a
 * schedule, so it must not outrank an announced season on a "when does it come back" list — it
 * sorts to the end with the genuinely undated. Every other status states what it knows.
 */
export function resolveReleaseWindow(u: FranchiseUpcoming): ReleaseWindow {
  if (['rumored', 'concluded', 'recently_aired', 'announced_no_date'].includes(u.status)) return UNKNOWN
  return parseReleaseWindow(u.release)
}

/** Attach the resolved window to a stored `upcoming` for the wire. Null passes through. */
export function withReleaseWindow(u: FranchiseUpcoming | null | undefined): FranchiseUpcomingView | null {
  if (!u) return null
  return { ...u, releaseWindow: resolveReleaseWindow(u) }
}
