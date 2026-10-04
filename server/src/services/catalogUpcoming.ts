import type { PartKind } from '../grouping/partKind.js'
import type { FranchiseUpcoming, MediaSource } from '../types/api.js'
import { matchPart } from '../news/installment.js'
import { parseReleaseWindow } from './releaseWindow.js'

/** Minimal catalogue fields needed to turn a known future part into an `upcoming` fact. */
export interface CatalogUpcomingPart {
  mediaId: number
  kind: PartKind
  sequence: number
  label: string
  title?: string
  status: string | null
  nextAiringAt: number | null
  fetchedAt: Date | null
}

const KIND_ORDER: PartKind[] = ['season', 'movie', 'ona', 'ova', 'special', 'music']

export const FUTURE_NEWS_STATUSES: ReadonlySet<string> = new Set(['rumored', 'announced', 'announced_no_date', 'upcoming_dated'])

/** The END of a stated window, never its sorting anchor. A quarter stays valid all quarter. */
export function releaseWindowEnd(release: string | null): number | null {
  const window = parseReleaseWindow(release)
  if (!window.date) return null
  const [y, m = 1, d = 1] = window.date.split('-').map(Number) as [number, number?, number?]
  switch (window.precision) {
    case 'day': return Date.UTC(y, m - 1, d + 1)
    case 'month': return Date.UTC(y, m, 1)
    case 'quarter': return Date.UTC(y, m + 2, 1)
    case 'year': return Date.UTC(y + 1, 0, 1)
    default: return null
  }
}

/** One read-time rule for Search, Library, Detail and live feed claims. Expiry means unknown,
 * never "ended": a missed date may mean a delay, and a missing announcement proves no conclusion. */
export function currentUpcoming(
  stored: FranchiseUpcoming | null | undefined,
  parts: readonly { mediaId: number; label: string; title?: string; status: string | null }[] = [],
  nowMs = Date.now(),
): FranchiseUpcoming | null {
  if (!stored) return null
  const future = FUTURE_NEWS_STATUSES.has(stored.status)
  if (future) {
    const end = releaseWindowEnd(stored.release)
    if (end != null && end <= nowMs) return null
  }
  if (future || stored.status === 'airing') {
    const part = matchPart(stored.next ?? '', parts.map(p => ({ ...p, title: p.title ?? '' })))
    if (part && (['FINISHED', 'CANCELLED'].includes(part.status ?? '') ||
      (future && part.status === 'RELEASING'))) return null
    // Airing is a live claim, not an evergreen announcement. Without recent verification or a
    // releasing catalogue match it must expire rather than advertise last month's broadcasts.
    const checked = Date.parse(stored.checked ?? '')
    if (stored.status === 'airing' && part?.status !== 'RELEASING' &&
      (!Number.isFinite(checked) || nowMs - checked > 14 * 86_400_000)) return null
  }
  return stored
}

export function isCatalogueUpcoming(u: Pick<FranchiseUpcoming, 'source'>): boolean {
  try {
    const host = new URL(u.source ?? '').hostname
    return ['www.themoviedb.org', 'themoviedb.org', 'anilist.co'].includes(host)
  } catch { return false }
}

/**
 * The catalogue page a catalogue-derived fact links to: the AniList entry for the part, or the
 * TMDB show page (TMDB has no public page per season id). Null for a TMDB show with no known id.
 */
export function catalogProviderUrl(source: MediaSource, franchiseExternalId: number | null, mediaId: number): string | null {
  if (source === 'tmdb') {
    return franchiseExternalId == null ? null : `https://www.themoviedb.org/tv/${franchiseExternalId}`
  }
  return `https://anilist.co/anime/${mediaId}`
}

/**
 * The catalogue's own next installment: the NOT_YET_RELEASED part that premieres soonest (a dated
 * part before an undated one), else the first undated one by kind and sequence. The one rule shared
 * by `deriveCatalogUpcoming` (the `upcoming` fact) and the Today feed's catalogue posts
 * (feed/compose.ts), so the two can never name different parts. `FranchisePart` satisfies the bound.
 */
export function pickCatalogUpcomingPart<
  P extends { status: string | null; nextAiringAt: number | null; kind: PartKind; sequence: number },
>(parts: readonly P[], nowMs: number): P | null {
  const candidates = parts.filter((part) => {
    if (part.status !== 'NOT_YET_RELEASED') return false
    // A past premiere on a NOT_YET_RELEASED row is stale catalogue data, not an undated
    // announcement. The normal sync will advance it; until then, do not publish a false return.
    return part.nextAiringAt == null || part.nextAiringAt > nowMs
  })
  if (candidates.length === 0) return null

  candidates.sort((a, b) => {
    if (a.nextAiringAt != null && b.nextAiringAt != null) return a.nextAiringAt - b.nextAiringAt
    if (a.nextAiringAt != null) return -1
    if (b.nextAiringAt != null) return 1
    const kind = KIND_ORDER.indexOf(a.kind) - KIND_ORDER.indexOf(b.kind)
    return kind !== 0 ? kind : a.sequence - b.sequence
  })
  return candidates[0] ?? null
}

/**
 * Build a confirmed fallback from catalogue data already held by the backend.
 *
 * The web-news result remains authoritative when present because it carries richer context and a
 * primary announcement URL. This fallback closes the gap where AniList/TMDB already lists a future
 * season but the slower news researcher has never examined the franchise.
 */
export function deriveCatalogUpcoming(input: {
  source: MediaSource
  franchiseExternalId: number | null
  parts: CatalogUpcomingPart[]
  nowMs?: number
}): FranchiseUpcoming | null {
  const next = pickCatalogUpcomingPart(input.parts, input.nowMs ?? Date.now())
  if (!next) return null
  const release = next.nextAiringAt == null ? 'TBA' : new Date(next.nextAiringAt).toISOString().slice(0, 10)
  const source = catalogProviderUrl(input.source, input.franchiseExternalId, next.mediaId)
  return {
    status: next.nextAiringAt == null ? 'announced_no_date' : 'upcoming_dated',
    next: next.label,
    release,
    note: null,
    source,
    checked: next.fetchedAt?.toISOString() ?? null,
    evidence: source ? [{
      url: source,
      publisher: input.source === 'tmdb' ? 'TMDB' : 'AniList',
      publishedAt: null,
      tier: 'catalogue',
      primary: false,
    }] : [],
  }
}

/**
 * A confirmed future catalogue part disproves a stored rumor/conclusion. Richer official web-news
 * remains preferred in every other case.
 */
export function resolveUpcomingWithCatalog(
  stored: FranchiseUpcoming | null | undefined,
  catalog: FranchiseUpcoming | null,
  options: { parts?: Parameters<typeof currentUpcoming>[1]; nowMs?: number } = {},
): FranchiseUpcoming | null {
  // Recompute catalogue claims; the old resolver let an inferred Season N live forever after the
  // provider removed it or after its premiere. Research and catalogue have distinct provenance.
  if (stored && isCatalogueUpcoming(stored)) return catalog ?? (stored.status === 'concluded' ? stored : null)
  const current = currentUpcoming(stored, options.parts, options.nowMs)
  if (!current) return catalog
  if (!catalog) return current
  return ['rumored', 'recently_aired', 'concluded'].includes(current.status) ? catalog : current
}
