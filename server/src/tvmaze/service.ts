import { and, eq, inArray } from 'drizzle-orm'
import { db } from '../db/index.js'
import { franchise, franchiseMember, mediaBroadcastTimes, subscriptions } from '../db/schema.js'
import { env } from '../env.js'
import { isMissingTable } from '../services/audience.js'
import { getCatalogLink, upsertCatalogLink } from '../services/catalogLinks.js'
import { getTvExternalIds, tmdbEnabled } from '../tmdb/client.js'
import { lookupShow, showEpisodes } from './client.js'
import { broadcastTimesBySeason } from './mapping.js'

// TVmaze broadcast times for followed TMDB shows (23 Oct): TMDB dates episodes with no clock, so a
// Sunday 9 PM ET broadcast was "Sunday" everywhere — Monday morning in India. A show is matched to
// TVmaze once, by the ids TMDB knows for it (TheTVDB's, else IMDb's), and the match is kept in
// `catalog_links` (provider 'tvmaze'); each sync then reads its episode list (one call) and stores
// every season's timed episodes in `media_broadcast_times`. Whether a season is READ at those
// instants is `exactSchedule`'s call (services/broadcast.ts), at read time, so a stale or partial
// list never shows. Streaming drops have no time on TVmaze and stay dates.

/** A show TVmaze did not know is asked about again after this long. */
const UNMATCHED_RETRY_MS = 7 * 86_400_000

export interface BroadcastSyncResult {
  checked: number
  matched: number
  unmatched: number
  /** Seasons whose broadcast times were written (or cleared). */
  seasons: number
  failed: number
}

/** Followed TMDB shows (or `franchiseIds`), synced one at a time under TVmaze's pacing. */
export async function syncBroadcastTimes(options: { franchiseIds?: string[]; now?: number } = {}): Promise<BroadcastSyncResult> {
  const result: BroadcastSyncResult = { checked: 0, matched: 0, unmatched: 0, seasons: 0, failed: 0 }
  if (env.TVMAZE_DISABLED || !tmdbEnabled()) return result
  const now = options.now ?? Date.now()
  const shows = await db
    .selectDistinct({ id: franchise.id, externalId: franchise.externalId })
    .from(franchise)
    .innerJoin(subscriptions, eq(subscriptions.franchiseId, franchise.id))
    .where(and(eq(franchise.source, 'tmdb'), options.franchiseIds ? inArray(franchise.id, options.franchiseIds) : undefined))
  for (const show of shows) {
    if (show.externalId == null) continue
    result.checked++
    try {
      const tvmazeId = await matchShow(show.id, show.externalId, now)
      if (tvmazeId == null) {
        result.unmatched++
        continue
      }
      result.matched++
      result.seasons += await writeSeasons(show.id, tvmazeId, now)
    } catch (error) {
      if (isMissingTable(error)) {
        console.warn('[broadcast] table media_broadcast_times does not exist yet (migration not applied): sync skipped')
        return result
      }
      result.failed++
      console.warn(`[broadcast] sync failed (${show.id}):`, 'diagnostic details redacted')
    }
  }
  return result
}

/** The show's TVmaze id: the kept match, else a lookup by TMDB's ids (kept either way). */
async function matchShow(franchiseId: string, tmdbId: number, now: number): Promise<number | null> {
  const link = await getCatalogLink(franchiseId, 'tvmaze')
  if (link?.status === 'matched' && link.externalId != null) return link.externalId
  if (link && now - link.checkedAt.getTime() < UNMATCHED_RETRY_MS) return null
  const ids = await getTvExternalIds(tmdbId, { maxRetries: 2 })
  const found = ids ? await lookupShow(ids) : null
  const kept = await upsertCatalogLink({
    franchiseId,
    provider: 'tvmaze',
    mediaType: 'tv',
    externalId: found?.show.id ?? null,
    matchMethod: found ? `tvmaze_lookup_${found.via}` : 'tvmaze_lookup',
    confidence: found ? 1 : null,
    evidence: { tvdbId: ids?.tvdbId ?? null, imdbId: ids?.imdbId ?? null, name: found?.show.name ?? null },
    checkedAt: new Date(now),
  })
  // Another show already holds this TVmaze id: identity stays with it (`upsertCatalogLink`).
  return kept ? (found?.show.id ?? null) : null
}

/** Store each season's timed episodes; clear a season TVmaze no longer times. Returns seasons touched. */
async function writeSeasons(franchiseId: string, tvmazeId: number, now: number): Promise<number> {
  const bySeason = broadcastTimesBySeason(await showEpisodes(tvmazeId))
  const seasons = await db
    .select({ mediaId: franchiseMember.mediaId, sequence: franchiseMember.sequence })
    .from(franchiseMember)
    .where(and(eq(franchiseMember.franchiseId, franchiseId), eq(franchiseMember.partKind, 'season')))
  let touched = 0
  for (const season of seasons) {
    const times = bySeason.get(season.sequence)
    if (times && Object.keys(times).length > 0) {
      await db
        .insert(mediaBroadcastTimes)
        .values({ mediaId: season.mediaId, provider: 'tvmaze', times, checkedAt: new Date(now) })
        .onConflictDoUpdate({ target: mediaBroadcastTimes.mediaId, set: { times, checkedAt: new Date(now) } })
      touched++
    } else {
      const removed = await db.delete(mediaBroadcastTimes).where(eq(mediaBroadcastTimes.mediaId, season.mediaId)).returning({ id: mediaBroadcastTimes.mediaId })
      touched += removed.length
    }
  }
  return touched
}
