import type { BroadcastTimes } from '../services/broadcast.js'
import type { TvmazeEpisode } from './client.js'

/**
 * TVmaze's episodes as broadcast times per season: season number → (episode number → instant, ms).
 * Only TIMED episodes count — a streaming drop has an empty `airtime` and a noon-UTC placeholder
 * stamp, which is a date, not a time — and specials (no number) never do. Pure.
 */
export function broadcastTimesBySeason(episodes: TvmazeEpisode[]): Map<number, BroadcastTimes> {
  const out = new Map<number, BroadcastTimes>()
  for (const e of episodes) {
    if (e.number == null || e.number <= 0 || e.season <= 0) continue
    if (!/^\d{2}:\d{2}$/.test(e.airtime ?? '') || !e.airstamp) continue
    const at = Date.parse(e.airstamp)
    if (!Number.isFinite(at)) continue
    const season = out.get(e.season) ?? {}
    season[String(e.number)] = at
    out.set(e.season, season)
  }
  return out
}
