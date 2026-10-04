import { and, eq, isNotNull, sql } from 'drizzle-orm'
import { db } from '../db/index.js'
import { franchise, franchiseMember, media } from '../db/schema.js'
import type { FranchiseSummary, MediaSource } from '../types/api.js'
import { baseConditions } from './discover.js'
import { getSummaries } from './franchiseView.js'

// First run's "pick your shows" list (GET /franchises/starter). IO: reads the catalogue; writes
// nothing.
//
// Trending is the wrong list for someone who has not picked anything yet: it is this season's
// chart, so a new viewer's first screen held titles they had never heard of, with Attack on Titan
// 56th and Demon Slayer absent (4 Oct). A picker works when people RECOGNISE what is on it, so this
// one is ranked by the catalogue's own popularity — AniList's member count, TMDB's popularity —
// which is each source's all-time (anime) or current (TV) best-known shows.

/** The most the route serves; the picker shows about sixty and pages nothing. */
export const STARTER_MAX = 120

/**
 * One catalogue's best-known franchises, most popular first. The same qualifying rule as Discover
 * (`baseConditions`: a member, not adult), plus a cover: a picker tile is its poster.
 */
export async function starterFranchiseIds(source: MediaSource, limit: number): Promise<string[]> {
  const rows = await db
    .select({ id: franchise.id })
    .from(franchise)
    .innerJoin(franchiseMember, eq(franchiseMember.franchiseId, franchise.id))
    .innerJoin(media, eq(media.id, franchiseMember.mediaId))
    .where(and(...baseConditions(source), isNotNull(franchise.cover)))
    .groupBy(franchise.id)
    .orderBy(sql`max(${media.popularity}) desc nulls last`, sql`${franchise.id} asc`)
    .limit(limit)
  return rows.map((row) => row.id)
}

/**
 * Both catalogues in one list, turn about. The two popularity scales cannot be compared (AniList
 * counts members in the hundred thousands, TMDB scores in the hundreds), so a merged ranking would
 * be all anime; each catalogue is ranked on its own and they alternate, anime first. When one runs
 * out the other carries on.
 */
export function alternateStarter(anime: string[], tv: string[], limit: number): string[] {
  const out: string[] = []
  const seen = new Set<string>()
  for (let i = 0; i < Math.max(anime.length, tv.length) && out.length < limit; i++) {
    for (const id of [anime[i], tv[i]]) {
      if (id == null || seen.has(id) || out.length >= limit) continue
      seen.add(id)
      out.push(id)
    }
  }
  return out
}

/** The list for a scope: one catalogue, or both alternating (`source` null). */
export async function getStarterFranchises(source: MediaSource | null, limit: number): Promise<FranchiseSummary[]> {
  const capped = Math.max(1, Math.min(STARTER_MAX, Math.floor(limit)))
  if (source) return getSummaries(await starterFranchiseIds(source, capped))
  const [anime, tv] = await Promise.all([
    starterFranchiseIds('anilist', capped),
    starterFranchiseIds('tmdb', capped),
  ])
  return getSummaries(alternateStarter(anime, tv, capped))
}
