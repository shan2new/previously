import type { AniListMedia } from '../anilist/types.js'
import { partKindForFormat, type PartKind } from './partKind.js'
import {
  isChildRelationship,
  isOptionalPart,
  nextSeasonNumber,
  partLabel,
  partRelationship,
  type RelationEdge,
} from './relationship.js'

// Attaching new members to an existing franchise (a new season, a newly listed short): what each
// becomes. Pure — grouping/service.ts loads the franchise's parts and writes the rows.

export const SEASON_RANK: Readonly<Record<string, number>> = { WINTER: 0, SPRING: 1, SUMMER: 2, FALL: 3 }

export function catalogueOrderKey(media: Pick<AniListMedia, 'seasonYear' | 'season'>): number {
  return (media.seasonYear ?? 9999) * 10 + (SEASON_RANK[media.season ?? ''] ?? 0)
}

/** What the plan reads of a part the franchise already has (a `franchise_member` row satisfies it). */
export interface ExistingPart {
  partKind: string
  sequence: number
  watchOrder: number
  label: string | null
}

export interface PlannedMember {
  mediaId: number
  partKind: PartKind
  sequence: number
  watchOrder: number
  relationship: string | null
  optional: boolean
  label: string
}

/**
 * The rows for the component's members the franchise does not have yet, in catalogue order.
 *
 * What a new member IS to the work is read off every relation among the members, old and new
 * (grouping/relationship.ts) — the edge an existing member points at it as well as the one it
 * declares itself. Reading only its own edge, uninverted, stored "my PARENT is the series" as
 * PARENT, so Re:ZERO's shorts came in as chapters of the story.
 *
 * Labels: a real season wears the next season NUMBER ("Season 5" after "Season 4", whatever the
 * `season` sequence has counted); a side series of season kind (TV shorts, a spin-off run) is NAMED
 * by its title, never numbered among the seasons; every other kind is its kind and its sequence
 * ("ONA 4").
 */
export function planAttach(
  existing: readonly ExistingPart[],
  component: ReadonlyMap<number, AniListMedia>,
  alreadyMembers: ReadonlySet<number>,
): PlannedMember[] {
  const fresh = [...component.values()].filter((m) => !alreadyMembers.has(m.id))
  if (fresh.length === 0) return []

  const nextSeq = new Map<string, number>()
  for (const p of existing) nextSeq.set(p.partKind, Math.max(nextSeq.get(p.partKind) ?? 0, p.sequence))
  let nextWatchOrder = Math.max(0, ...existing.map((part) => part.watchOrder))
  const seasonLabels = existing.filter((p) => p.partKind === 'season').map((p) => p.label)

  const memberIds = new Set([...alreadyMembers, ...fresh.map((m) => m.id)])
  const edges: RelationEdge[] = [...component.values()]
    .filter((m) => memberIds.has(m.id))
    .flatMap((m) =>
      (m.relations?.edges ?? [])
        .filter((e) => e.node.type === 'ANIME' && memberIds.has(e.node.id))
        .map((e) => ({ from: m.id, to: e.node.id, type: e.relationType })),
    )

  return fresh
    .slice()
    .sort((a, b) => catalogueOrderKey(a) - catalogueOrderKey(b) || a.id - b.id)
    .map((m) => {
      const kind = partKindForFormat(m.format)
      const sequence = (nextSeq.get(kind) ?? 0) + 1
      nextSeq.set(kind, sequence)
      const relationship = partRelationship(m.id, edges)
      let label: string
      if (kind !== 'season') {
        label = partLabel(kind, sequence)
      } else if (isChildRelationship(relationship)) {
        label = m.title.english || m.title.romaji || partLabel(kind, sequence)
      } else {
        label = partLabel(kind, nextSeasonNumber(seasonLabels, sequence))
        seasonLabels.push(label)
      }
      return {
        mediaId: m.id,
        partKind: kind,
        sequence,
        watchOrder: ++nextWatchOrder,
        relationship,
        optional: isOptionalPart(relationship, kind),
        label,
      }
    })
}
