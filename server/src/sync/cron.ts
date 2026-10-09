import cron, { type ScheduledTask } from 'node-cron'
import { env } from '../env.js'
import { refreshSubscribedNews } from '../news/service.js'
import {
  refreshSubscribedAniListEnrichment,
  refreshSubscribedTmdbRecommendations,
} from '../services/catalogEnrichment.js'
import { materialiseTopRecommendations } from '../services/recommendations.js'
import { refreshAnimeMetadataFallback } from '../services/animeVideoFallback.js'
import { refreshPreferredAvailability } from '../services/watchAvailability.js'
import { clampUnairedProgress } from '../services/library.js'
import { purgeCommentTombstones } from '../services/commentRetention.js'
import { alertStaleReports } from '../services/moderationAlert.js'
import { tmdbEnabled } from '../tmdb/client.js'
import {
  attachNewSeasons,
  refreshAiring,
  refreshAiringTv,
  seedTrending,
  seedTrendingTv,
  sweepAniListTrailers,
} from './sync.js'

let stopCurrent: (() => Promise<void>) | undefined

// Static job names and aggregate counts survive the private operational log sanitizer. Never
// include provider errors, user identities, catalogue titles or query strings in these records.
function jobLog(job: string, outcome: 'completed' | 'failed' | 'deferred', count?: number): void {
  const row = JSON.stringify({ event: `cron.${outcome}`, job,
    level: outcome === 'failed' ? 50 : outcome === 'deferred' ? 40 : 30,
    ...(count === undefined ? {} : { count }) })
  if (outcome === 'failed') console.error(row)
  else if (outcome === 'deferred') console.warn(row)
  else console.log(row)
}

/** Register the scheduled sync jobs (idempotent; safe to call once at boot). */
export function startCron(): () => Promise<void> {
  if (stopCurrent) return stopCurrent
  let stopping = false
  const tasks: ScheduledTask[] = []
  const pending = new Set<Promise<void>>()
  const busy = new Set<string>()
  const run = (name: string, work: () => Promise<void>): Promise<void> => {
    if (stopping || busy.has(name)) return Promise.resolve()
    busy.add(name)
    const promise = Promise.resolve().then(work).catch(() => {
      jobLog(name, 'failed')
    }).finally(() => { pending.delete(promise); busy.delete(name) })
    pending.add(promise)
    return promise
  }
  const schedule = (name: string, expression: string, work: () => Promise<void>) => {
    tasks.push(cron.schedule(expression, () => run(name, work), { noOverlap: true, unref: true }))
  }
  stopCurrent = async () => {
    stopping = true
    await Promise.allSettled(tasks.map((task) => task.destroy()))
    await Promise.allSettled([...pending])
    stopCurrent = undefined
  }

  // The unaired-season progress repair (`clampUnairedProgress`): once at boot, then hourly — a
  // no-op once the rows are clean.
  const repairUnaired = async () => {
    try {
      const n = await clampUnairedProgress()
      if (n > 0) jobLog('unaired-repair', 'completed', n)
    } catch {
      jobLog('unaired-repair', 'failed')
    }
  }
  void run('boot-repair', repairUnaired)

  // Hourly: keep airing schedules + "out now" fresh (both sources).
  schedule('hourly-catalogue', '0 * * * *', async () => {
    await repairUnaired()
    try {
      const n = await refreshAiring()
      jobLog('anime-airing', 'completed', n)
    } catch {
      jobLog('anime-airing', 'failed')
    }
    if (tmdbEnabled()) {
      try {
        const n = await refreshAiringTv()
        jobLog('tv-airing', 'completed', n)
      } catch {
        jobLog('tv-airing', 'failed')
      }
    }
    try {
      const result = await sweepAniListTrailers()
      if (result.providerReachable === false) {
        jobLog('anilist-trailers', 'deferred')
      } else if (result.scanned > 0) {
        jobLog('anilist-trailers', 'completed', result.upserted)
      }
    } catch {
      jobLog('anilist-trailers', 'failed')
    }
  })

  // Hourly at :20: while any report has waited more than 12 hours, log it and nudge the operator's
  // webhook (services/moderationAlert.ts) — App Review expects reports acted on within 24 hours, and
  // there is one operator. Its own schedule and catch, so the catalogue jobs cannot delay it.
  schedule('stale-reports', '20 * * * *', async () => {
    try {
      await alertStaleReports()
    } catch {
      jobLog('stale-reports', 'failed')
    }
  })

  // Daily 03:10: remove comments their authors deleted more than 30 days ago (social/retention.ts).
  // The tombstone only has to outlive a client's replay of the same POST; past that it is who
  // commented on what, kept after they deleted it. Likes, reports and notifications cascade.
  schedule('comment-retention', '10 3 * * *', async () => {
    try {
      const n = await purgeCommentTombstones()
      if (n > 0) jobLog('comment-retention', 'completed', n)
    } catch {
      jobLog('comment-retention', 'failed')
    }
  })

  // Daily 03:30: re-seed trending franchises + attach newly-aired seasons to followed franchises.
  // The two steps get their own try/catch on purpose: they share only the schedule, and under one
  // catch a transient AniList failure in seedTrending (which calls out first) also skipped
  // attachNewSeasons for the whole day, so followed shows missed new parts for an unrelated reason.
  schedule('daily-catalogue', '30 3 * * *', async () => {
    try {
      const { grouped } = await seedTrending()
      jobLog('anime-seed', 'completed', grouped)
    } catch {
      jobLog('anime-seed', 'failed')
    }
    try {
      const attached = await attachNewSeasons()
      jobLog('attach-seasons', 'completed', attached)
    } catch {
      jobLog('attach-seasons', 'failed')
    }
    if (tmdbEnabled()) {
      try {
        const { created } = await seedTrendingTv()
        jobLog('tv-seed', 'completed', created)
      } catch {
        jobLog('tv-seed', 'failed')
      }
    }
  })

  // Daily 04:15: fill graph-heavy anime metadata for followed titles. This is separately caught
  // because AniList outages must not suppress the 05:00 announcement researcher. It also rewrites
  // each refreshed show's ranked recommendation list (and its series-root walk).
  schedule('anime-enrichment', '15 4 * * *', async () => {
    try {
      const { refreshed } = await refreshSubscribedAniListEnrichment()
      jobLog('anime-enrichment', 'completed', refreshed)
    } catch {
      jobLog('anime-enrichment', 'failed')
    }
  })

  // Daily 04:20: re-read followed TV shows' TMDB recommendation lists (one request per show). The
  // hourly TV refresh keeps their seasons fresh but never rewrites their recommendation edges.
  if (tmdbEnabled()) {
    schedule('tv-recommendations', '20 4 * * *', async () => {
      try {
        const { refreshed } = await refreshSubscribedTmdbRecommendations()
        jobLog('tv-recommendations', 'completed', refreshed)
      } catch {
        jobLog('tv-recommendations', 'failed')
      }
    })
  }

  // Daily 04:40, after both refreshes: build show pages for every user's top 12 recommendations
  // (today's and tomorrow's lists, capped at 40 titles) so a tap opens a real page instantly.
  schedule('recommendation-pages', '40 4 * * *', async () => {
    try {
      const { materialised } = await materialiseTopRecommendations({ perUser: 12, cap: 40 })
      jobLog('recommendation-pages', 'completed', materialised)
    } catch {
      jobLog('recommendation-pages', 'failed')
    }
  })

  // Daily 04:30: repair sparse anime metadata from TMDB independently of AniList. Followed titles
  // are first, then the rest of the materialized catalogue; this never changes AniList identity.
  if (tmdbEnabled()) {
    schedule('anime-fallback', '30 4 * * *', async () => {
      try {
        const { matched } = await refreshAnimeMetadataFallback()
        jobLog('anime-fallback', 'completed', matched)
      } catch {
        jobLog('anime-fallback', 'failed')
      }
    })

    // Daily 04:45: keep list-card availability warm only for explicitly saved user countries.
    // This changes no subscriptions and emits no provider-change notifications.
    schedule('regional-availability', '45 4 * * *', async () => {
      try {
        const { available } = await refreshPreferredAvailability()
        jobLog('regional-availability', 'completed', available)
      } catch {
        jobLog('regional-availability', 'failed')
      }
    })
  }

  // Daily 05:00: agent-based announcement research over subscribed franchises → notifications.
  if (!env.NEWS_AGENT_DISABLED) {
    schedule('news-refresh', '0 5 * * *', async () => {
      try {
        const { notified } = await refreshSubscribedNews()
        jobLog('news-refresh', 'completed', notified)
      } catch {
        jobLog('news-refresh', 'failed')
      }
    })
  }
  return stopCurrent
}
