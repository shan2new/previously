import type { GroupingInput, GroupingResult, GroupedPart } from './llm.js'
import type { PartKind } from './partKind.js'
import { isOptionalPart, partLabel, partRelationship } from './relationship.js'

const seasonRank: Record<string, number> = { WINTER: 0, SPRING: 1, SUMMER: 2, FALL: 3 }

/**
 * No-LLM grouping: everything in the component becomes one franchise. part_kind comes from
 * AniList format; sequence is chronological within each kind. Used as a fallback and as the
 * baseline the tests assert against.
 */
export function deterministicGroup(input: GroupingInput): GroupingResult {
  const byKind = new Map<PartKind, typeof input.candidates>()
  for (const c of input.candidates) {
    const kind = formatToKind(c.format)
    const arr = byKind.get(kind) ?? []
    arr.push(c)
    byKind.set(kind, arr)
  }

  const parts: GroupedPart[] = []
  for (const [kind, arr] of byKind) {
    arr.sort((a, b) => sortKey(a) - sortKey(b))
    arr.forEach((c, i) => {
      parts.push({ id: c.id, partKind: kind, sequence: i + 1, label: partLabel(kind, i + 1) })
    })
  }

  const candidateById = new Map(input.candidates.map((candidate) => [candidate.id, candidate]))
  const ordered = parts
    .slice()
    .sort((a, b) => {
      const aa = candidateById.get(a.id)
      const bb = candidateById.get(b.id)
      const ak = (aa?.seasonYear ?? 9999) * 10 + (seasonRank[aa?.season ?? ''] ?? 0)
      const bk = (bb?.seasonYear ?? 9999) * 10 + (seasonRank[bb?.season ?? ''] ?? 0)
      return ak - bk || a.sequence - b.sequence || a.id - b.id
    })
  ordered.forEach((part, index) => {
      // The earliest member is the work's root; every other part is what the edges say it is
      // (grouping/relationship.ts).
      const relationship = index === 0 ? null : partRelationship(part.id, input.edges)
      part.watchOrder = index + 1
      part.relationship = relationship
      part.optional = isOptionalPart(relationship, part.partKind)
    })

  // Canonical name: the earliest TV season's title, else the first candidate's title.
  const seasons = input.candidates
    .filter((c) => formatToKind(c.format) === 'season')
    .sort((a, b) => sortKey(a) - sortKey(b))
  const canonicalName = (seasons[0] ?? input.candidates[0])?.title ?? 'Untitled'

  return { franchises: [{ canonicalName, parts }], confidence: 0.5, model: null }
}

function formatToKind(format: string | null): PartKind {
  switch (format) {
    case 'MOVIE':
      return 'movie'
    case 'OVA':
      return 'ova'
    case 'ONA':
      return 'ona'
    case 'SPECIAL':
      return 'special'
    case 'MUSIC':
      return 'music'
    default:
      return 'season'
  }
}

function sortKey(c: { seasonYear: number | null; title: string }): number {
  return (c.seasonYear ?? 9999) * 10
}
