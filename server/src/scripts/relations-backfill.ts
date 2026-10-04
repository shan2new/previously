// Re-derive every anime franchise member's relationship, `optional` flag and mechanical label from
// the stored relation edges (grouping/backfill.ts). The members were written by an inversion that
// only knew PREQUEL/SEQUEL: side stories whose one tie was "my PARENT is the series" were stored as
// PARENT, and seasons that HAVE a side story as SIDE_STORY (and optional).
//
//   npm run relations:backfill                    DRY RUN — prints the plan, writes nothing
//   npm run relations:backfill -- <franchiseId>   one franchise (dry run)
//   npm run relations:backfill -- --apply         writes, one transaction per franchise
//
// No network, no model: the edges are `media_relations`, as fetched when the members were grouped.
// Idempotent — a second run plans nothing. TV (TMDB) franchises have no relations and are skipped.

import { and, eq, inArray } from 'drizzle-orm'
import { db, sql } from '../db/index.js'
import { franchise, franchiseMember, media, mediaRelations } from '../db/schema.js'
import { planRelationshipBackfill, type MemberChange } from '../grouping/backfill.js'

const args = process.argv.slice(2).map((arg) => arg.trim())
const apply = args.includes('--apply')
const only = args.find((arg) => !arg.startsWith('--'))

try {
  const franchises = await db
    .select({ id: franchise.id, title: franchise.title })
    .from(franchise)
    .where(only ? and(eq(franchise.source, 'anilist'), eq(franchise.id, only)) : eq(franchise.source, 'anilist'))
  if (franchises.length === 0) console.log('[relations:backfill] no anime franchise matches')

  const transitions = new Map<string, number>()
  const samples: string[] = []
  let touched = 0
  let members = 0
  let relabelled = 0
  let optionalFlips = 0

  for (const f of franchises) {
    const rows = await db
      .select({
        mediaId: franchiseMember.mediaId,
        partKind: franchiseMember.partKind,
        watchOrder: franchiseMember.watchOrder,
        relationship: franchiseMember.relationship,
        optional: franchiseMember.optional,
        label: franchiseMember.label,
        format: media.format,
        titleEnglish: media.titleEnglish,
        titleRomaji: media.titleRomaji,
      })
      .from(franchiseMember)
      .leftJoin(media, eq(media.id, franchiseMember.mediaId))
      .where(eq(franchiseMember.franchiseId, f.id))
    if (rows.length < 2) continue
    const ids = rows.map((row) => row.mediaId)
    const edges = await db
      .select({ from: mediaRelations.mediaId, to: mediaRelations.relatedId, type: mediaRelations.relationType })
      .from(mediaRelations)
      .where(and(inArray(mediaRelations.mediaId, ids), inArray(mediaRelations.relatedId, ids)))

    const changes: MemberChange[] = planRelationshipBackfill(
      rows.map((row) => ({ ...row, title: row.titleEnglish || row.titleRomaji })),
      edges,
    )
    if (changes.length === 0) continue
    touched++
    members += changes.length
    for (const change of changes) {
      if (change.relationship) {
        const key = `${change.relationship.from ?? 'null'} -> ${change.relationship.to ?? 'null'}`
        transitions.set(key, (transitions.get(key) ?? 0) + 1)
      }
      if (change.optional) optionalFlips++
      if (change.label) relabelled++
      if (samples.length < 40) {
        const bits = [
          change.relationship ? `relationship ${change.relationship.from ?? 'null'} -> ${change.relationship.to ?? 'null'}` : null,
          change.optional ? `optional ${change.optional.from} -> ${change.optional.to}` : null,
          change.label ? `label "${change.label.from ?? ''}" -> "${change.label.to}"` : null,
        ].filter(Boolean)
        const was = rows.find((row) => row.mediaId === change.mediaId)
        samples.push(`  ${f.title} · ${was?.label ?? change.mediaId}: ${bits.join('; ')}`)
      }
    }

    if (apply) {
      await db.transaction(async (tx) => {
        for (const change of changes) {
          await tx
            .update(franchiseMember)
            .set({
              ...(change.relationship ? { relationship: change.relationship.to } : {}),
              ...(change.optional ? { optional: change.optional.to } : {}),
              ...(change.label ? { label: change.label.to } : {}),
            })
            .where(eq(franchiseMember.mediaId, change.mediaId))
        }
        await tx.update(franchise).set({ updatedAt: new Date() }).where(eq(franchise.id, f.id))
      })
    }
  }

  console.log(`[relations:backfill] ${apply ? 'APPLIED' : 'DRY RUN (nothing written; pass --apply to write)'}`)
  console.log(`  franchises scanned ${franchises.length}, with changes ${touched}; members changed ${members}`)
  console.log(`  optional flips ${optionalFlips}, labels rewritten ${relabelled}`)
  for (const [key, count] of [...transitions].sort((a, b) => b[1] - a[1])) console.log(`  relationship ${key}: ${count}`)
  if (samples.length > 0) console.log(`  first ${samples.length} changes:\n${samples.join('\n')}`)
} finally {
  await sql.end()
}
