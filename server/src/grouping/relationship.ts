import type { PartKind } from './partKind.js'

// What a franchise part IS to the work it belongs to, derived from the catalogue's relation edges —
// in one place, for the three writers of `franchise_member.relationship` (the deterministic
// grouper, the post-LLM ordering pass and the attach of new members).
//
// AniList states a relation from the CURRENT media's side: an edge `from → to` of type T reads
// "`to` is the T of `from`". So the edge says what `to` is, as written — and what `from` is only
// through T's inverse. The writers used to invert PREQUEL/SEQUEL and pass every other type through
// unchanged, which stored the relation backwards for everything else:
//   • a side story whose one tie is "my PARENT is the series" was stored as PARENT — Re:ZERO's
//     "Break Time" shorts, which the app then took for the story's spine (4 Oct 2026);
//   • a season that HAS a side story was stored as SIDE_STORY (and so `optional`) — One-Punch Man's
//     Season 2, which the app had to special-case.

/** A catalogue relation between two members: `to` is the `type` of `from`. */
export interface RelationEdge {
  from: number
  to: number
  type: string
}

const INVERSE: Readonly<Record<string, string>> = {
  SEQUEL: 'PREQUEL',
  PREQUEL: 'SEQUEL',
  // "My parent is X": I am X's child. The catalogue's children are side stories and spin-offs;
  // without the parent's own word for it (see `partRoles`), a child is a side story.
  PARENT: 'SIDE_STORY',
  SIDE_STORY: 'PARENT',
  SPIN_OFF: 'PARENT',
  SUMMARY: 'PARENT',
  ADAPTATION: 'SOURCE',
  SOURCE: 'ADAPTATION',
  COMPILATION: 'CONTAINS',
  CONTAINS: 'COMPILATION',
}

/** What `from` is to `to`, given that `to` is the `type` of `from`. Symmetric types are their own. */
export function inverseRelation(type: string): string {
  return INVERSE[type] ?? type
}

/**
 * Everything the edges say the part is, in edge order. An edge pointing AT the part states its role
 * as written. An edge the part itself declares gives the inverse — unless the other member also
 * declares one back, in which case its statement about the part is the one kept (the parent calling
 * a child its SPIN_OFF is more exact than the child's "my parent is…").
 */
export function partRoles(partId: number, edges: readonly RelationEdge[]): string[] {
  const statedBy = new Set(edges.filter((edge) => edge.to === partId).map((edge) => edge.from))
  const roles: string[] = []
  for (const edge of edges) {
    if (edge.to === partId) roles.push(edge.type)
    else if (edge.from === partId && !statedBy.has(edge.to)) roles.push(inverseRelation(edge.type))
  }
  return roles
}

/**
 * The part's one relationship to the work. A child of the story comes first — a side story stays
 * one even when it has a sequel of its own, and so does a spin-off — then its place in the story's
 * chain (SEQUEL for every part that follows another; PREQUEL only for the one that opens the
 * chain, whatever order the edges arrive in), then whatever else the catalogue says. Never PARENT:
 * "this part has children" is not what the part is, and it is exactly the value the old inversion
 * stored for the children themselves. Null when the edges say nothing (or only that it is a
 * parent): a root.
 */
export function partRelationship(partId: number, edges: readonly RelationEdge[]): string | null {
  const roles = partRoles(partId, edges)
  return (
    roles.find((role) => role === 'SIDE_STORY') ??
    roles.find((role) => role === 'SPIN_OFF') ??
    roles.find((role) => role === 'SEQUEL') ??
    roles.find((role) => role === 'PREQUEL') ??
    roles.find((role) => role !== 'PARENT') ??
    null
  )
}

/**
 * A part the story can be followed without — the contract's "source-identified side/optional
 * material": a child of the story (side story, spin-off), a special, a music video. One rule for
 * every writer: the first migration flagged specials and anything that TOUCHED a side-story edge
 * (so the seasons that have one), the grouper only side stories.
 */
export function isOptionalPart(relationship: string | null, kind: PartKind): boolean {
  return isChildRelationship(relationship) || kind === 'special' || kind === 'music'
}

/** A child of the story rather than a chapter of it. */
export function isChildRelationship(relationship: string | null): boolean {
  return relationship === 'SIDE_STORY' || relationship === 'SPIN_OFF'
}

const KIND_WORD: Readonly<Record<PartKind, string>> = {
  season: 'Season',
  movie: 'Movie',
  ova: 'OVA',
  ona: 'ONA',
  special: 'Special',
  music: 'Music',
}

/** The mechanical label of a part: "Season 3", "OVA 2", "ONA 4" (initialisms, not "Ona 4"). */
export function partLabel(kind: PartKind, n: number): string {
  return `${KIND_WORD[kind]} ${n}`
}

/**
 * The number the next real season wears: one past the highest "Season N" already labelled. Not the
 * `season` sequence, which counts every member of that kind — split cours ("Season 2 Part 2") and
 * short-form children included — so Re:ZERO's shorts arrived as "Season 6" and "Season 7" after
 * "Season 4". Falls back to `sequence` when no label carries a number.
 */
export function nextSeasonNumber(labels: readonly (string | null)[], sequence: number): number {
  let highest = 0
  for (const label of labels) {
    const match = /^Season (\d+)\b/.exec(label ?? '')
    if (match) highest = Math.max(highest, Number(match[1]))
  }
  return highest > 0 ? highest + 1 : sequence
}
