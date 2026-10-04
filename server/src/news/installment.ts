// Installment naming: how research's free-text `next` ("Season 4", "Infinity Castle - Part 2
// (movie)") is keyed, named and matched to a catalogue part. Pure.
//
// Two keys live here on purpose, and they must not be merged:
// - `dedupeKey`/`sameInstallment` decide which `announcements` row a research result belongs to
//   (ASCII, keeps "movie"). They are the write side's identity and changing them re-threads rows.
// - `installmentKey` is only for matching a name to a PART (Unicode-aware, drops "(movie)"), the
//   port of the Today feed spike's `key()` (FeedSpikeModel.swift:383-386).

/** Stable per-installment key so "Season 4" / "season 4!" / "SEASON 4" collapse to one row. */
export const dedupeKey = (next: string): string => next.toLowerCase().replace(/[^a-z0-9]+/g, ' ').trim()

/**
 * Whether two normalized keys name the same installment. Exact match, or one key's tokens
 * fully contained in the other's, with identical numeric identity. Adding a subtitle can retain
 * an announcement; adding another part number cannot.
 */
export function sameInstallment(a: string, b: string): boolean {
  if (a === b) return true
  // Numbers carry identity: Season 2 and Season 2 Part 2 are not the same announcement. A set
  // loses the repeated 2 and silently merges their evidence, reminders and release dates.
  if (JSON.stringify(a.match(/\d+/g) ?? []) !== JSON.stringify(b.match(/\d+/g) ?? [])) return false
  const ta = new Set(a.split(' ').filter(Boolean))
  const tb = new Set(b.split(' ').filter(Boolean))
  const [small, big] = ta.size <= tb.size ? [ta, tb] : [tb, ta]
  if (small.size === 0) return false
  for (const t of small) if (!big.has(t)) return false
  return true
}

/**
 * The part-matching key: lowercase, "(movie)" dropped, split on anything that is not a letter or
 * a number (in any script), empty tokens dropped, joined with single spaces.
 */
export function installmentKey(s: string): string {
  return s
    .toLowerCase()
    .replaceAll('(movie)', '')
    .split(/[^\p{L}\p{N}]+/u)
    .filter((token) => token !== '')
    .join(' ')
}

/** "Infinity Castle - Part 2 (movie)" → { name: "Infinity Castle - Part 2", isMovie: true }. */
export function installmentName(next: string): { name: string; isMovie: boolean } {
  const isMovie = next.toLowerCase().includes('(movie)')
  const name = next.replace(/\s*\(movie\)/gi, '').trim()
  return { name, isMovie }
}

/** The fields part matching reads. `FranchisePart` satisfies it. */
export interface MatchablePart {
  mediaId: number
  label: string
  title: string
  status: string | null
}

/**
 * The catalogue part an installment name refers to (the spike's `part(named:)`,
 * FeedSpikeModel.swift:667-672). Parts are scanned in the order given, which callers keep as the
 * franchise's watch order, so the first match wins:
 *
 * 1. a part whose label keys exactly to the name;
 * 2. else a part whose title contains the name's key, or — for a NOT_YET_RELEASED part only — whose
 *    (non-empty) label key is contained in the name's key ("Season 2: Swordsmith Village" → the
 *    announced "Season 2").
 */
export function matchPart<P extends MatchablePart>(name: string, parts: readonly P[]): P | null {
  const k = installmentKey(name)
  if (k === '') return null
  const exact = parts.filter((p) => installmentKey(p.label) === k)
  if (exact.length > 1) return null // Ambiguous labels cannot identify a release reliably.
  if (exact.length === 1) return exact[0]!
  return (
    parts.find((p) => {
      const contains = (whole: string, term: string) => (` ${whole} `).includes(` ${term} `)
      const numbers = (value: string) => JSON.stringify(value.match(/\d+/g) ?? [])
      if (contains(installmentKey(p.title), k) && numbers(installmentKey(p.title)) === numbers(k)) return true
      const label = installmentKey(p.label)
      return label !== '' && contains(k, label) && numbers(k) === numbers(label) && p.status === 'NOT_YET_RELEASED'
    }) ?? null
  )
}

/**
 * THE predicate that joins a research announcement to a catalogue part: the part its installment
 * name (`next`) matches (`matchPart`, parts in watch order). The research post's `part`, the
 * catalogue post's id (feed/compose.ts), the post-detail alias (feed/service.ts), adoption
 * (feed/adopt.ts) and the write-side canonical subject (social/resolve.ts) all read this one rule,
 * so a thread can never be keyed on one id while the feed shows another.
 *
 * `sameInstallment` is the announcement table's identity; this separately resolves catalogue parts.
 */
export function announcedPart<P extends MatchablePart>(next: string, parts: readonly P[]): P | null {
  return matchPart(installmentName(next).name, parts)
}

/**
 * The announcement whose installment names `part`, or null. When several do, the FIRST in the order
 * given wins; callers pass a franchise's announcements oldest first (`first_seen_at`, then id), so
 * the answer never moves once a thread has been keyed on it.
 */
export function announcementForPart<A extends { next: string; status?: string }>(
  part: Pick<MatchablePart, 'mediaId'>,
  announcements: readonly A[],
  parts: readonly MatchablePart[],
): A | null {
  return announcements.find((a) => a.status !== 'retracted' && a.next.trim() !== '' && announcedPart(a.next, parts)?.mediaId === part.mediaId) ?? null
}
