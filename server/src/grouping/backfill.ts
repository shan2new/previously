import type { PartKind } from './partKind.js'
import { isChildRelationship, isOptionalPart, partLabel, partRelationship, type RelationEdge } from './relationship.js'

// Re-deriving stored members after the relation fix (grouping/relationship.ts): `relationship` and
// `optional` were written by the old inversion, and the attach path's mechanical labels ("Ona 4",
// and "Season 6" for a short-form child) with them. Pure — scripts/relations-backfill.ts loads the
// rows, prints the plan and, only when asked, writes it.

/** A `franchise_member` row with the two catalogue facts its label depends on. */
export interface StoredMember {
  mediaId: number
  partKind: string
  watchOrder: number
  relationship: string | null
  optional: boolean
  label: string | null
  /** `media.format` */
  format: string | null
  /** The catalogue's title for the member (English, else romaji). */
  title: string | null
}

export interface MemberChange {
  mediaId: number
  relationship?: { from: string | null; to: string | null }
  optional?: { from: boolean; to: boolean }
  label?: { from: string | null; to: string }
}

const MECHANICAL_EXTRA = /^(Ona|Ova) (\d+)$/
const MECHANICAL_SEASON = /^Season \d+$/

const CHAIN: ReadonlySet<string> = new Set(['SEQUEL', 'PREQUEL'])

/**
 * What changes for one franchise's members, given the relation edges among them.
 *
 * Only what the old writers got WRONG is rewritten — never a value that is merely spelled another
 * way. A member the edges say nothing about (or only "has children") keeps what is stored, except
 * the old PARENT, which is cleared: that is a first season the first migration marked because its
 * side stories point at it. The root (lowest watch order) keeps its chain word as it is — the
 * migration stored PREQUEL for a first season, the grouper stores nothing — but not a child's: a
 * side-story OVA that happens to be the earliest member (One Piece's 1998 special) stays one.
 *
 * Labels are touched only where they are the attach path's own mistakes: "Ona N" / "Ova N" become
 * initialisms, and a "Season N" worn by a SHORT-FORM child of the story takes its title. A label a
 * model or a person wrote is never rewritten.
 */
export function planRelationshipBackfill(members: readonly StoredMember[], edges: readonly RelationEdge[]): MemberChange[] {
  if (members.length === 0) return []
  const ids = new Set(members.map((member) => member.mediaId))
  const within = edges.filter((edge) => ids.has(edge.from) && ids.has(edge.to))
  const root = [...members].sort((a, b) => a.watchOrder - b.watchOrder || a.mediaId - b.mediaId)[0]!

  const changes: MemberChange[] = []
  for (const member of members) {
    const kind = member.partKind as PartKind
    const derived = partRelationship(member.mediaId, within)
    const stored = member.relationship
    let relationship: string | null
    if (derived === null) {
      relationship = stored === 'PARENT' ? null : stored
    } else if (member.mediaId === root.mediaId && (stored === null || CHAIN.has(stored)) && CHAIN.has(derived)) {
      relationship = stored
    } else {
      relationship = derived
    }
    const optional = isOptionalPart(relationship, kind)
    const change: MemberChange = { mediaId: member.mediaId }
    if (relationship !== member.relationship) change.relationship = { from: member.relationship, to: relationship }
    if (optional !== member.optional) change.optional = { from: member.optional, to: optional }

    const label = member.label ?? ''
    const extra = MECHANICAL_EXTRA.exec(label)
    if (extra && (kind === 'ona' || kind === 'ova')) {
      change.label = { from: member.label, to: partLabel(kind, Number(extra[2])) }
    } else if (
      kind === 'season' &&
      member.format === 'TV_SHORT' &&
      isChildRelationship(relationship) &&
      MECHANICAL_SEASON.test(label) &&
      member.title
    ) {
      change.label = { from: member.label, to: member.title }
    }
    if (change.relationship || change.optional || change.label) changes.push(change)
  }
  return changes
}
