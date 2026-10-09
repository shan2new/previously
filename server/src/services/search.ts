import { and, desc, eq, inArray, sql, type SQL } from 'drizzle-orm'
import { searchMedia } from '../anilist/client.js'
import type { AniListMedia } from '../anilist/types.js'
import { db } from '../db/index.js'
import { franchise, franchiseMember, media } from '../db/schema.js'
import { expandComponent } from '../grouping/graph.js'
import { DeterministicGrouper } from '../grouping/llm.js'
import { groupKnownComponent } from '../grouping/service.js'
import { searchTv, tmdbEnabled } from '../tmdb/client.js'
import { isJapaneseAnimation } from '../tmdb/mapping.js'
import { ensureTvFranchise } from '../tmdb/service.js'
import type { TmdbSearchResult } from '../tmdb/types.js'
import type { FranchiseListResponse, SourceOutcome } from '../types/api.js'
import { abortableSleep, withTimeout } from '../util/abort.js'
import { BoundedTaskQueue, type EnqueuedTask } from '../util/taskQueue.js'
import { getSummaries, getTrendingFranchises } from './franchiseView.js'
import { makeAniListFetcher, upsertMedia } from './mediaStore.js'
import { isExcludedContent, consumerFranchiseConditions, consumerAnimeFetcher } from './consumerContent.js'
import { correctSearchQuery } from './queryCorrect.js'

// Search is interactive typeahead, not a catalogue-ingestion job. These are deliberately tighter
// than the iOS client's 16.6 s logical-request budget: fail soft while the result is still useful.
const SEARCH_BUDGET_MS = 2_400
const SOURCE_TIMEOUT_MS = 1_050
const CORRECTION_TIMEOUT_MS = 650
const COLD_ENRICH_WAIT_MS = 600
const ENRICHMENT_BUDGET_MS = 8_000
const MIN_REMOTE_QUERY_LENGTH = 3
const ANILIST_ENRICH_CAP = 3
const TV_ENRICH_CAP = 2

// Capacity includes active work. Excess typeahead cache warming is dropped, never accumulated.
const enrichment = new BoundedTaskQueue(2, 24, (key, error) => {
  console.warn('[search] enrichment failed')
})

export interface SearchProfile {
  mode: 'trending' | 'local' | 'remote' | 'corrected-local'
  queryLength: number
  localMs: number
  upstreamMs: number
  enrichmentWaitMs: number
  localResults: number
  anilistHits: number
  tmdbHits: number
  queued: number
  dropped: number
  queueDepth: number
  resultCount: number
  totalMs: number
}

export interface SearchFilters {
  source?: 'anilist' | 'tmdb'
  year?: number
  status?: 'FINISHED' | 'RELEASING' | 'NOT_YET_RELEASED' | 'CANCELLED' | 'HIATUS'
  theme?: string
  providerId?: number
  country?: string
}

interface SearchOptions {
  exact?: boolean
  /** Aborted when the iOS client supersedes this query or disconnects. */
  signal?: AbortSignal
  /** Route-level structured logging hook; never receives the raw query. */
  onProfile?: (profile: SearchProfile) => void
  filters?: SearchFilters
}

/**
 * Search the locally-materialized catalogue first. Only a genuine local miss reaches providers,
 * and that lookup gets one short attempt—never the sync client's retry policy. Unknown hits are
 * materialized by a bounded queue and cannot dominate request latency or multiply per keystroke.
 */
export async function searchFranchises(
  query: string,
  limit = 30,
  opts: SearchOptions = {},
): Promise<FranchiseListResponse> {
  const started = performance.now()
  const trimmed = query.trim().replace(/\s+/g, ' ')
  const requestSignal = withTimeout(opts.signal, SEARCH_BUDGET_MS)
  const sources: { anilist: SourceOutcome; tmdb: SourceOutcome } = {
    anilist: 'ok',
    tmdb: tmdbEnabled() ? 'ok' : 'disabled',
  }
  const profile: SearchProfile = {
    mode: 'local',
    queryLength: trimmed.length,
    localMs: 0,
    upstreamMs: 0,
    enrichmentWaitMs: 0,
    localResults: 0,
    anilistHits: 0,
    tmdbHits: 0,
    queued: 0,
    dropped: 0,
    queueDepth: enrichment.pendingCount,
    resultCount: 0,
    totalMs: 0,
  }

  const finish = (response: FranchiseListResponse, mode: SearchProfile['mode']): FranchiseListResponse => {
    profile.mode = mode
    profile.resultCount = response.franchises.length
    profile.queueDepth = enrichment.pendingCount
    profile.totalMs = roundMs(performance.now() - started)
    opts.onProfile?.(profile)
    return response
  }

  if (!trimmed) {
    // One catalogue's trending is ranked within that catalogue: the mixed ranking's head is all
    // anime (TMDB rows carry no trend score), so filtering it for TV would come back empty.
    const candidates = await getTrendingFranchises(Math.min(100, Math.max(limit, limit * 4)), opts.filters?.source)
    const allowed = await filterFranchiseIds(candidates.map((item) => item.id), opts.filters)
    const allowedSet = new Set(allowed)
    const franchises = candidates.filter((item) => allowedSet.has(item.id)).slice(0, limit)
    return finish({ franchises, sources }, 'trending')
  }

  // One- and two-character typeahead never triggers network, LLM, or catalogue writes. Indexed
  // prefix search still returns known titles; an empty result simply waits for the next keystroke.
  const localStarted = performance.now()
  const localIds = await searchLocalFranchiseIds(trimmed, limit, opts.filters)
  profile.localMs = roundMs(performance.now() - localStarted)
  profile.localResults = localIds.length
  if (localIds.length > 0 || trimmed.length < MIN_REMOTE_QUERY_LENGTH) {
    return finish({ franchises: await getSummaries(localIds), sources }, 'local')
  }

  const upstreamStarted = performance.now()
  let [animeHits, rawTvHits] = await searchProviders(trimmed, limit, requestSignal, sources, opts.filters)
  let correctedQuery: string | undefined

  // Correction is deliberately serial and only runs after at least one provider positively
  // returned no hits. This avoids spending an LLM request on every cold local miss and avoids
  // turning a total provider outage into another fan-out.
  const providerResponded = sources.anilist === 'ok' || sources.tmdb === 'ok'
  if (
    animeHits.length === 0 &&
    rawTvHits.length === 0 &&
    providerResponded &&
    !opts.exact &&
    trimmed.length >= 4 &&
    !requestSignal.aborted
  ) {
    const corrected = await correctSearchQuery(trimmed, {
      signal: requestSignal,
      timeoutMs: CORRECTION_TIMEOUT_MS,
    })
    if (corrected && !requestSignal.aborted) {
      // Typo repair usually points at a known popular title. Re-check Postgres before paying for
      // a second provider fan-out.
      const correctedLocal = await searchLocalFranchiseIds(corrected, limit, opts.filters)
      if (correctedLocal.length > 0) {
        correctedQuery = corrected
        profile.upstreamMs = roundMs(performance.now() - upstreamStarted)
        return finish(
          {
            franchises: await getSummaries(correctedLocal),
            correctedQuery,
            originalQuery: query,
            sources,
          },
          'corrected-local',
        )
      }

      ;[animeHits, rawTvHits] = await searchProviders(corrected, limit, requestSignal, sources, opts.filters)
      if (animeHits.length > 0 || rawTvHits.length > 0) correctedQuery = corrected
    }
  }
  profile.upstreamMs = roundMs(performance.now() - upstreamStarted)
  profile.anilistHits = animeHits.length

  const tvHits = rawTvHits.filter((hit) => !isJapaneseAnimation(hit))
  profile.tmdbHits = tvHits.length
  let resolved = await resolveProviderHits(animeHits, tvHits)
  let ids = await filterFranchiseIds(interleave(resolved.animeIds, resolved.tvIds), opts.filters)

  const tasks = requestSignal.aborted
    ? []
    : enqueueEnrichment(animeHits, tvHits, resolved.unknownAnime, resolved.unknownTv)
  profile.queued = tasks.filter((task) => task.accepted && !task.shared).length
  profile.dropped = tasks.filter((task) => !task.accepted).length

  // Known results return immediately. A completely cold query waits only a small, fixed window
  // for its first materialized franchise; useful warming continues in the bounded queue.
  if (ids.length === 0 && tasks.some((task) => task.accepted) && !requestSignal.aborted) {
    const remaining = Math.max(0, SEARCH_BUDGET_MS - (performance.now() - started) - 50)
    const waitMs = Math.min(COLD_ENRICH_WAIT_MS, remaining)
    if (waitMs > 0) {
      const waitStarted = performance.now()
      await Promise.race([
        Promise.all(tasks.map((task) => task.done)),
        abortableSleep(waitMs, requestSignal).catch(() => undefined),
      ])
      profile.enrichmentWaitMs = roundMs(performance.now() - waitStarted)
      resolved = await resolveProviderHits(animeHits, tvHits)
      ids = await filterFranchiseIds(interleave(resolved.animeIds, resolved.tvIds), opts.filters)
    }
  }

  return finish(
    {
      franchises: await getSummaries(ids.slice(0, limit)),
      ...(correctedQuery ? { correctedQuery, originalQuery: query } : {}),
      sources,
    },
    'remote',
  )
}

async function searchProviders(
  query: string,
  limit: number,
  signal: AbortSignal,
  sources: { anilist: SourceOutcome; tmdb: SourceOutcome },
  filters?: SearchFilters,
): Promise<[AniListMedia[], TmdbSearchResult[]]> {
  const providerLimit = Math.min(Math.max(limit, 10), 20)
  const searchAniList = filters?.source === 'tmdb' ? Promise.resolve([]) : searchMedia(query, {
    signal,
    maxRetries: 0,
    timeoutMs: SOURCE_TIMEOUT_MS,
    limit: providerLimit,
  }).then(
    (hits) => {
      sources.anilist = 'ok'
      return hits.filter((hit) =>
        !isExcludedContent(hit) && (filters?.year == null || hit.seasonYear === filters.year) &&
        (filters?.status == null || hit.status === filters.status),
      )
    },
    () => {
      sources.anilist = 'failed'
      return []
    },
  )

  const searchTmdb = !tmdbEnabled() || filters?.source === 'anilist'
    ? Promise.resolve([])
    : searchTv(query, {
        signal,
        maxRetries: 0,
        timeoutMs: SOURCE_TIMEOUT_MS,
        limit: providerLimit,
      }).then(
        (hits) => {
          sources.tmdb = 'ok'
          return hits.filter((hit) => {
            const year = Number(hit.first_air_date?.slice(0, 4)) || null
            return !isExcludedContent(hit) && (filters?.year == null || year === filters.year)
          })
        },
        () => {
          sources.tmdb = 'failed'
          return []
        },
      )

  return Promise.all([searchAniList, searchTmdb])
}

interface ResolvedHits {
  animeIds: string[]
  tvIds: string[]
  unknownAnime: Set<number>
  unknownTv: Set<number>
}

/** Bulk-resolve provider-native ids without materializing anything on the request path. */
async function resolveProviderHits(
  animeHits: AniListMedia[],
  tvHits: TmdbSearchResult[],
): Promise<ResolvedHits> {
  const animeNativeIds = dedupe(animeHits.map((hit) => hit.id))
  const tvNativeIds = dedupe(tvHits.map((hit) => hit.id))
  const [members, tvFranchises] = await Promise.all([
    animeNativeIds.length
      ? db
          .select({ mediaId: franchiseMember.mediaId, franchiseId: franchiseMember.franchiseId })
          .from(franchiseMember)
          .where(inArray(franchiseMember.mediaId, animeNativeIds))
      : Promise.resolve([]),
    tvNativeIds.length
      ? db
          .select({ id: franchise.id, externalId: franchise.externalId })
          .from(franchise)
          .where(and(eq(franchise.source, 'tmdb'), inArray(franchise.externalId, tvNativeIds)))
      : Promise.resolve([]),
  ])

  const animeByNative = new Map(members.map((row) => [row.mediaId, row.franchiseId]))
  const tvByNative = new Map(
    tvFranchises
      .filter((row): row is typeof row & { externalId: number } => row.externalId != null)
      .map((row) => [row.externalId, row.id]),
  )

  return {
    animeIds: orderedDistinct(animeHits.map((hit) => animeByNative.get(hit.id))),
    tvIds: orderedDistinct(tvHits.map((hit) => tvByNative.get(hit.id))),
    unknownAnime: new Set(animeNativeIds.filter((id) => !animeByNative.has(id))),
    unknownTv: new Set(tvNativeIds.filter((id) => !tvByNative.has(id))),
  }
}

function enqueueEnrichment(
  animeHits: AniListMedia[],
  tvHits: TmdbSearchResult[],
  unknownAnime: Set<number>,
  unknownTv: Set<number>,
): EnqueuedTask[] {
  const tasks: EnqueuedTask[] = []
  const animeSeeds = animeHits.filter((hit) => unknownAnime.has(hit.id)).slice(0, ANILIST_ENRICH_CAP)
  if (animeSeeds.length > 0) {
    // The queue is bounded in width and depth; bound each batch in time as well so a degraded
    // provider cannot occupy both workers indefinitely and starve later cache warming.
    const enrichmentSignal = withTimeout(undefined, ENRICHMENT_BUDGET_MS)
    const fetcher = makeAniListFetcher({
      seed: animeHits,
      request: { signal: enrichmentSignal, maxRetries: 1, timeoutMs: 2_500 },
    })
    let primed: Promise<void> | undefined
    const prime = () => (primed ??= upsertMedia(animeHits))
    for (const hit of animeSeeds) {
      tasks.push(
        enrichment.enqueue(`anilist:${hit.id}`, async () => {
          await prime()
          const component = await expandComponent(hit.id, consumerAnimeFetcher(hit.id, fetcher))
          if (component.size === 0) return
          // Search warming must not depend on a third provider. The scheduled seed path retains
          // LLM refinement; cold interactive search uses the deterministic relation graph.
          await groupKnownComponent(component, hit.id, { grouper: new DeterministicGrouper() })
        }),
      )
    }
  }

  for (const hit of tvHits.filter((item) => unknownTv.has(item.id)).slice(0, TV_ENRICH_CAP)) {
    tasks.push(
      enrichment.enqueue(`tmdb:${hit.id}`, async () => {
        await ensureTvFranchise(hit.id, {
          hydrateEpisodes: false,
          consumerOnly: true,
          request: {
            signal: withTimeout(undefined, ENRICHMENT_BUDGET_MS),
            maxRetries: 1,
            timeoutMs: 2_500,
          },
        })
      }),
    )
  }
  return tasks
}

/**
 * Local typeahead over canonical names plus every installment alias. Both expressions have GIN
 * indexes in schema.ts. Prefix tsquery lexemes keep typeahead index-backed as the catalogue grows.
 */
function searchFilterConditions(filters?: SearchFilters): SQL[] {
  const conditions = consumerFranchiseConditions()
  if (!filters) return conditions
  if (filters.source) conditions.push(sql`${franchise.source} = ${filters.source}`)
  if (filters.year != null) conditions.push(sql`exists (
    select 1 from franchise_member sfm
    join media sm on sm.id = sfm.media_id
    where sfm.franchise_id = ${franchise.id} and sm.season_year = ${filters.year}
  )`)
  if (filters.status) conditions.push(sql`exists (
    select 1 from franchise_member sfm
    join media sm on sm.id = sfm.media_id
    where sfm.franchise_id = ${franchise.id} and sm.status = ${filters.status}
  )`)
  if (filters.theme) conditions.push(sql`exists (
    select 1 from jsonb_array_elements_text(
      case when jsonb_array_length(coalesce(${franchise.enrichment}->'themes', '[]'::jsonb)) > 0
        then ${franchise.enrichment}->'themes' else coalesce(${franchise.genres}, '[]'::jsonb) end
    ) as search_theme(value)
    where lower(search_theme.value) = lower(${filters.theme})
  )`)
  if (filters.providerId != null && filters.country) conditions.push(sql`(
    not exists (
      select 1 from watch_availability_snapshots swas
      where swas.franchise_id = ${franchise.id}
        and swas.country = ${filters.country}
        and swas.expires_at > now()
    )
    or exists (
      select 1 from watch_availability_snapshots swas
      where swas.franchise_id = ${franchise.id}
        and swas.country = ${filters.country}
        and swas.expires_at > now()
        and swas.status = 'available'
        and swas.providers @> ${JSON.stringify([{ id: filters.providerId }])}::jsonb
    )
  )`)
  return conditions
}

async function filterFranchiseIds(ids: string[], filters?: SearchFilters): Promise<string[]> {
  if (ids.length === 0 || !filters || Object.keys(filters).length === 0) return ids
  const rows = await db
    .select({ id: franchise.id })
    .from(franchise)
    .where(and(inArray(franchise.id, ids), ...searchFilterConditions(filters)))
  const allowed = new Set(rows.map((row) => row.id))
  return ids.filter((id) => allowed.has(id))
}

async function searchLocalFranchiseIds(query: string, limit: number, filters?: SearchFilters): Promise<string[]> {
  const lexemes = query.normalize('NFKC').toLocaleLowerCase('en-US').match(/[\p{L}\p{N}]+/gu) ?? []
  if (lexemes.length === 0) return []
  const tsQueryText = lexemes.map((token) => `${token}:*`).join(' & ')
  const phrase = lexemes.join(' ')
  const prefix = `${phrase}%`
  const tsQuery = sql`to_tsquery('simple', ${tsQueryText})`
  const franchiseVector = sql`to_tsvector('simple', coalesce(${franchise.title}, ''))`
  const mediaVector = sql`to_tsvector('simple', coalesce(${media.titleEnglish}, '') || ' ' || coalesce(${media.titleRomaji}, '') || ' ' || coalesce(${media.titleNative}, '') || ' ' || coalesce(${media.synonyms}::text, ''))`
  const rowLimit = Math.min(Math.max(limit * 2, 20), 100)

  const franchiseScore = sql<number>`(
    case
      when lower(${franchise.title}) = ${phrase} then 100
      when lower(${franchise.title}) like ${prefix} then 50
      else ts_rank_cd(${franchiseVector}, ${tsQuery}) * 10
    end
  )::float8`
  const mediaScore = sql<number>`max(
    case
      when lower(coalesce(${media.titleEnglish}, '')) = ${phrase}
        or lower(coalesce(${media.titleRomaji}, '')) = ${phrase} then 90
      when lower(coalesce(${media.titleEnglish}, '')) like ${prefix}
        or lower(coalesce(${media.titleRomaji}, '')) like ${prefix} then 45
      else ts_rank_cd(${mediaVector}, ${tsQuery}) * 10
    end
  )::float8`
  const popularity = sql<number>`coalesce(max(${media.popularity}), 0)`

  const [canonicalRows, aliasRows] = await Promise.all([
    db
      .select({ id: franchise.id, score: franchiseScore })
      .from(franchise)
      .where(and(sql`${franchiseVector} @@ ${tsQuery}`, ...searchFilterConditions(filters)))
      .orderBy(desc(franchiseScore), desc(franchise.updatedAt))
      .limit(rowLimit),
    db
      .select({ id: franchiseMember.franchiseId, score: mediaScore, popularity })
      .from(media)
      .innerJoin(franchiseMember, eq(franchiseMember.mediaId, media.id))
      .innerJoin(franchise, eq(franchise.id, franchiseMember.franchiseId))
      .where(and(sql`${mediaVector} @@ ${tsQuery}`, ...searchFilterConditions(filters)))
      .groupBy(franchiseMember.franchiseId)
      .orderBy(desc(mediaScore), desc(popularity))
      .limit(rowLimit),
  ])

  const scoreById = new Map<string, { score: number; popularity: number }>()
  for (const row of canonicalRows) scoreById.set(row.id, { score: Number(row.score), popularity: 0 })
  for (const row of aliasRows) {
    const previous = scoreById.get(row.id)
    const score = Math.max(previous?.score ?? 0, Number(row.score))
    scoreById.set(row.id, { score, popularity: Math.max(previous?.popularity ?? 0, Number(row.popularity)) })
  }

  return [...scoreById.entries()]
    .sort((a, b) => b[1].score - a[1].score || b[1].popularity - a[1].popularity)
    .slice(0, limit)
    .map(([id]) => id)
}

function interleave(anime: string[], tv: string[]): string[] {
  const out: string[] = []
  const seen = new Set<string>()
  for (let i = 0; i < Math.max(anime.length, tv.length); i++) {
    for (const id of [anime[i], tv[i]]) {
      if (id && !seen.has(id)) {
        seen.add(id)
        out.push(id)
      }
    }
  }
  return out
}

function orderedDistinct(items: (string | undefined)[]): string[] {
  const seen = new Set<string>()
  const out: string[] = []
  for (const item of items) {
    if (item && !seen.has(item)) {
      seen.add(item)
      out.push(item)
    }
  }
  return out
}

function dedupe<T>(items: T[]): T[] {
  return [...new Set(items)]
}

function roundMs(value: number): number {
  return Math.round(value * 10) / 10
}
