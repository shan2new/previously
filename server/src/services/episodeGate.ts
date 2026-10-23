import { and, eq, inArray } from 'drizzle-orm'
import { db } from '../db/index.js'
import { franchise, franchiseMember, media, progress } from '../db/schema.js'
import type { EpisodeAccess } from '../types/api.js'
import { airedCount, episodeAccess, gatedProgress, type AiredCount } from './aired.js'

// The spoiler gate for episode discussions (`ep:<mediaId>:<n>`): a viewer may read and post only
// when their progress on mediaId is ≥ n AND episode n has aired by now. "Aired by now" is the rule
// the progress clamp uses (services/aired.ts), so a room and a mark can never disagree about
// whether an episode is out.
//
// A `reset` (PUT /me/franchises/:id/progress { mode: 'reset' }) re-locks rooms for the resetting
// viewer; comments they already wrote stay visible to everyone else. That is intended.

export interface EpisodeAccessResult {
  access: EpisodeAccess
  franchiseId: string
  franchiseTitle: string
  /** The viewer's progress on the part, under the read-time guard (NOT_YET_RELEASED ≤ aired). */
  progress: number
  aired: AiredCount
}

/** One query: media ⋈ franchise_member ⋈ franchise ⟕ progress(user). null = no such media, or not a franchise member. */
export async function getEpisodeAccess(
  userId: string,
  mediaId: number,
  episode: number,
  nowMs: number = Date.now(),
): Promise<EpisodeAccessResult | null> {
  const [row] = await db
    .select({
      franchiseId: franchise.id,
      franchiseTitle: franchise.title,
      source: media.source,
      status: media.status,
      episodes: media.episodes,
      next: media.nextAiringEpisode,
      episodesList: media.episodesList,
      networks: media.studios,
      watched: progress.episodesWatched,
    })
    .from(media)
    .innerJoin(franchiseMember, eq(franchiseMember.mediaId, media.id))
    .innerJoin(franchise, eq(franchise.id, franchiseMember.franchiseId))
    .leftJoin(progress, and(eq(progress.mediaId, media.id), eq(progress.userId, userId)))
    .where(eq(media.id, mediaId))
    .limit(1)
  if (!row) return null

  const aired = airedCount(
    {
      source: row.source,
      status: row.status,
      episodes: row.episodes,
      next: row.next ?? null,
      episodesList: row.episodesList ?? null,
      networks: row.networks,
    },
    nowMs,
  )
  const watched = gatedProgress(row.status, row.watched ?? 0, aired)
  return {
    access: episodeAccess({ progress: watched, episode, count: aired }),
    franchiseId: row.franchiseId,
    franchiseTitle: row.franchiseTitle,
    progress: watched,
    aired,
  }
}

/** Whether `ep:<mediaId>:<episode>` is open to the viewer a predicate was built for. */
export type EpisodeOpenCheck = (mediaId: number, episode: number) => boolean

/**
 * The same gate for MANY parts in one query (media ⟕ progress(user) over `mediaIds`), as a
 * predicate — for a page of rows that each name a room (the Activity sheet's excerpts). An id the
 * catalogue does not hold answers false: nothing is shown from a room that cannot be resolved.
 */
export async function episodeOpenChecker(
  userId: string,
  mediaIds: readonly number[],
  nowMs: number = Date.now(),
): Promise<EpisodeOpenCheck> {
  const ids = [...new Set(mediaIds)]
  if (ids.length === 0) return () => false
  const rows = await db
    .select({
      mediaId: media.id,
      source: media.source,
      status: media.status,
      episodes: media.episodes,
      next: media.nextAiringEpisode,
      episodesList: media.episodesList,
      networks: media.studios,
      watched: progress.episodesWatched,
    })
    .from(media)
    .leftJoin(progress, and(eq(progress.mediaId, media.id), eq(progress.userId, userId)))
    .where(inArray(media.id, ids))
  const gates = new Map<number, { aired: AiredCount; watched: number }>()
  for (const row of rows) {
    const aired = airedCount(
      {
        source: row.source,
        status: row.status,
        episodes: row.episodes,
        next: row.next ?? null,
        episodesList: row.episodesList ?? null,
        networks: row.networks,
      },
      nowMs,
    )
    gates.set(row.mediaId, { aired, watched: gatedProgress(row.status, row.watched ?? 0, aired) })
  }
  return (mediaId, episode) => {
    const gate = gates.get(mediaId)
    return gate != null && episodeAccess({ progress: gate.watched, episode, count: gate.aired }) === 'open'
  }
}
