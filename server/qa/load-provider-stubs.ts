// Explicit QA use only: transport fixtures around real provider clients and production services.
// Install before importing buildServer. This file is never imported by the production server.
import assert from 'node:assert/strict'
import type { AniListMedia } from '../src/anilist/types.js'

export const COLD_MEDIA_BASE = 310_100_000

export interface KnownLoadMedia {
  id: number
  malId: number
  title: string
  episodes?: number
}

export interface ProviderStubStats {
  anilistCalls: number
  searches: number
  malMappings: number
  mediaReads: number
  loopbackRequests: number
  blockedRequests: number
  unsupportedQueries: number
  simulatedLatencyMs: number
}

export function syntheticLoadMedia(id: number, title: string, episodes = 12): AniListMedia {
  return {
    id, title: { english: title, romaji: title, native: null }, synonyms: [],
    coverImage: { extraLarge: null, large: null }, bannerImage: null, trailer: null,
    isAdult: false, description: 'Synthetic QA catalogue fixture.', genres: ['Drama'],
    episodes, format: 'TV', status: 'FINISHED', season: 'WINTER', seasonYear: 2024,
    popularity: 100, trending: 10, duration: 24, studios: { nodes: [] },
    streamingEpisodes: [], nextAiringEpisode: null, airingSchedule: { nodes: [] },
    relations: { edges: [] },
  }
}

export function installProviderStubs(options: {
  knownMedia: readonly KnownLoadMedia[]
  coldCount?: number
  providerLatencyMs?: number
}) {
  assert.equal(process.env.APP_ENV, 'test')
  assert.equal(process.env.DOTENV_CONFIG_PATH, '/dev/null')
  const target = new URL(process.env.DATABASE_URL ?? '')
  assert.equal(target.hostname, '127.0.0.1')
  assert.match(target.pathname, /^\/previously_qa_load_[a-f0-9]{32}$/)
  const coldCount = options.coldCount ?? 1000
  const providerLatencyMs = options.providerLatencyMs ?? 20
  assert.ok(Number.isInteger(coldCount) && coldCount > 0 && coldCount <= 10_000)
  assert.ok(Number.isFinite(providerLatencyMs) && providerLatencyMs >= 0 && providerLatencyMs <= 1000)
  const byMal = new Map(options.knownMedia.map((item) => [item.malId, item]))
  const byId = new Map(options.knownMedia.map((item) => [item.id, syntheticLoadMedia(item.id, item.title, item.episodes)]))
  assert.equal(byMal.size, options.knownMedia.length, 'MAL fixture IDs must be unique')
  assert.equal(byId.size, options.knownMedia.length, 'Media fixture IDs must be unique')
  for (const item of options.knownMedia) {
    assert.ok(item.id < COLD_MEDIA_BASE || item.id >= COLD_MEDIA_BASE + coldCount,
      'Known media must not overlap the cold-search fixture range')
  }
  const rawFetch = globalThis.fetch.bind(globalThis)
  const stats: ProviderStubStats = {
    anilistCalls: 0, searches: 0, malMappings: 0, mediaReads: 0,
    loopbackRequests: 0, blockedRequests: 0, unsupportedQueries: 0,
    simulatedLatencyMs: providerLatencyMs,
  }
  const json = (data: unknown) => new Response(JSON.stringify({ data }), {
    status: 200, headers: { 'content-type': 'application/json' },
  })
  const resolveMedia = (id: number): AniListMedia | null => {
    const known = byId.get(id)
    if (known) return known
    const index = id - COLD_MEDIA_BASE
    return index >= 0 && index < coldCount
      // A prefix match avoids /search's exact-title news/cast side jobs. The bounded search
      // materialization queue still runs with the real grouping and catalogue SQL.
      ? syntheticLoadMedia(id, `Cold${String(index).padStart(4, '0')} synthetic`) : null
  }
  const providerFetch: typeof globalThis.fetch = async (input, init) => {
    const url = new URL(typeof input === 'string' ? input : input instanceof URL ? input.href : input.url)
    if (url.hostname === '127.0.0.1' && url.protocol === 'http:') {
      stats.loopbackRequests++
      return rawFetch(input, init)
    }
    if (url.href !== 'https://graphql.anilist.co/') {
      stats.blockedRequests++
      throw new Error(`QA provider boundary blocked ${url.protocol}//${url.hostname}`)
    }
    stats.anilistCalls++
    const signal = init?.signal ?? (input instanceof Request ? input.signal : undefined)
    if (signal?.aborted) throw signal.reason ?? new DOMException('Aborted', 'AbortError')
    if (providerLatencyMs > 0) await new Promise<void>((resolve, reject) => {
      const timer = setTimeout(() => { signal?.removeEventListener('abort', aborted); resolve() }, providerLatencyMs)
      const aborted = () => { clearTimeout(timer); reject(signal?.reason ?? new DOMException('Aborted', 'AbortError')) }
      signal?.addEventListener('abort', aborted, { once: true })
    })
    const body = init?.body ?? (input instanceof Request ? await input.text() : undefined)
    if (typeof body !== 'string') throw new Error('QA AniList fixture requires a JSON string body')
    const { query, variables } = JSON.parse(body) as { query: string; variables: Record<string, unknown> }
    if (typeof query !== 'string' || !variables) throw new Error('QA AniList fixture requires query and variables')
    if (/idMal_in/.test(query)) {
      stats.malMappings++
      const ids = variables.ids as number[]
      return json({ Page: { media: ids.flatMap((id) => {
        const item = byMal.get(id)
        return item ? [{ id: item.id, idMal: item.malId }] : []
      }) } })
    }
    if (/media\(search:/.test(query)) {
      stats.searches++
      const match = typeof variables.search === 'string' ? /^Cold(\d{1,4})$/i.exec(variables.search.trim()) : null
      const index = match ? Number(match[1]) : -1
      return json({ Page: { media: index >= 0 && index < coldCount ? [resolveMedia(COLD_MEDIA_BASE + index)!] : [] } })
    }
    if (/media\(id_in:/.test(query)) {
      stats.mediaReads++
      return json({ Page: { media: (variables.ids as number[]).flatMap((id) => {
        const item = resolveMedia(id)
        return item ? [item] : []
      }) } })
    }
    if (/Media\(id:/.test(query)) {
      stats.mediaReads++
      return json({ Media: resolveMedia(Number(variables.id)) })
    }
    stats.unsupportedQueries++
    throw new Error('QA AniList fixture received an unsupported GraphQL operation')
  }
  globalThis.fetch = providerFetch
  return {
    stats,
    rawFetch,
    restore() {
      assert.equal(globalThis.fetch, providerFetch, 'Fetch changed after QA provider installation')
      globalThis.fetch = rawFetch
    },
  }
}
