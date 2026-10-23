import { inArray } from 'drizzle-orm'
import { db } from '../db/index.js'
import { mediaBroadcastTimes } from '../db/schema.js'
import { TMDB_ID_OFFSET } from '../tmdb/mapping.js'
import type { EpisodeMeta } from '../types/api.js'
import { slotStrikesAt } from './airingSlot.js'
import { isMissingTable } from './audience.js'

// Real broadcast instants for TMDB seasons (23 Oct: "It shows incorrect airing time and date… it
// doesn't match the timezone and the actual airing time well", owner). TMDB dates an episode with no
// clock, so everything downstream reads a TMDB timestamp as a calendar DATE; the TVmaze sync
// (tvmaze/service.ts) stores the network's slot per episode. A season becomes EXACT only as a
// whole: every dated episode has a broadcast instant that agrees with TMDB's date — so no client
// ever reads one season in two calendars.
//
// The server's own aired rule (the progress clamp, the episode gate) stays the date-only one
// (`slotStrikesAt`, the earliest any time zone reaches the next day). A season whose broadcast would
// strike BEFORE that is left date-only, so an exact client is only ever later than the server —
// the contract's "a client may unlock later than the server, never earlier".

/** TMDB episode number (a string key, as jsonb keeps it) → broadcast instant, ms epoch. */
export type BroadcastTimes = Record<string, number>

/** How far a broadcast instant may sit from TMDB's synthesized 17:00 UTC date and still be that
 *  episode: a local evening anywhere from UTC−12 to UTC+14, either side. */
const AGREE_MS = 36 * 3_600_000

export interface ExactSchedule {
  /** The part's episodes, the dated ones at their broadcast instants. */
  episodes: EpisodeMeta[]
  /** The next slot at its broadcast instant (`airingAt` in seconds), when there is one. */
  next: { episode: number; airingAt: number } | null
}

/**
 * A TMDB part's schedule at its real broadcast instants, or null when they cannot stand for the
 * whole part: not TMDB, no times, a dated episode (or the next slot) with no broadcast time, one
 * that lands more than 36 h from TMDB's date (a renumbered season, a moved episode), or one that
 * would strike before the server's date-only rule does. Pure.
 */
export function exactSchedule(m: {
  source: string
  episodes: EpisodeMeta[] | null
  next: { episode: number; airingAt: number } | null
  broadcast: BroadcastTimes | null | undefined
}): ExactSchedule | null {
  if (m.source !== 'tmdb' || !m.broadcast) return null
  const times = m.broadcast
  const instant = (episode: number, tmdbMs: number): number | null => {
    const t = times[String(episode)]
    if (typeof t !== 'number' || !Number.isFinite(t)) return null
    if (Math.abs(t - tmdbMs) > AGREE_MS || t < slotStrikesAt(tmdbMs, 'tmdb')) return null
    return t
  }
  let dated = 0
  const episodes: EpisodeMeta[] = []
  for (const e of m.episodes ?? []) {
    if (e.airDate == null) {
      episodes.push(e)
      continue
    }
    const t = instant(e.number, e.airDate)
    if (t == null) return null
    dated++
    episodes.push({ ...e, airDate: t })
  }
  let next: ExactSchedule['next'] = null
  if (m.next && m.next.airingAt > 0) {
    const t = instant(m.next.episode, m.next.airingAt * 1000)
    if (t == null) return null
    next = { episode: m.next.episode, airingAt: Math.round(t / 1000) }
  }
  if (dated === 0 && !next) return null
  return { episodes, next }
}

let missingWarned = false

/**
 * The broadcast times the TVmaze sync holds for these media rows (TMDB seasons only). Empty until
 * migration 0017 has been applied — the schedule is then date-only, as before. Not for use inside a
 * transaction (a missing table would abort it).
 */
export async function loadBroadcastTimes(mediaIds: number[]): Promise<Map<number, BroadcastTimes>> {
  const out = new Map<number, BroadcastTimes>()
  const ids = [...new Set(mediaIds)].filter((id) => id >= TMDB_ID_OFFSET)
  if (ids.length === 0) return out
  try {
    const rows = await db
      .select({ mediaId: mediaBroadcastTimes.mediaId, times: mediaBroadcastTimes.times })
      .from(mediaBroadcastTimes)
      .where(inArray(mediaBroadcastTimes.mediaId, ids))
    for (const row of rows) out.set(row.mediaId, row.times)
  } catch (error) {
    if (!isMissingTable(error)) throw error
    if (!missingWarned) {
      missingWarned = true
      console.warn('[broadcast] table media_broadcast_times does not exist yet (migration not applied): TV times stay date-only')
    }
  }
  return out
}
