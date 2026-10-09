// Explicitly invoked load QA: production routes/services, real disposable PostgreSQL, fixture IO.
import assert from 'node:assert/strict'
import { AsyncLocalStorage } from 'node:async_hooks'
import { randomUUID, timingSafeEqual } from 'node:crypto'
import { mkdir, writeFile } from 'node:fs/promises'
import { Socket, type AddressInfo } from 'node:net'
import { dirname, join } from 'node:path'
import { monitorEventLoopDelay, performance, PerformanceObserver } from 'node:perf_hooks'
import { getHeapStatistics } from 'node:v8'
import postgres from 'postgres'
import { installProviderStubs, type KnownLoadMedia } from './load-provider-stubs.js'

const target = new URL(process.env.DATABASE_URL ?? '')
assert.equal(target.hostname, '127.0.0.1')
assert.match(target.pathname, /^\/previously_qa_load_[a-f0-9]{32}$/)
assert.equal(process.env.DOTENV_CONFIG_PATH, '/dev/null')
assert.equal(process.env.APP_ENV, 'test')
assert.equal(process.env.DEV_AUTH_BYPASS, '1')
for (const key of ['CLERK_SECRET_KEY', 'CLERK_JWT_KEY', 'OPENROUTER_API_KEY', 'CEREBRAS_API_KEY', 'TMDB_ACCESS_TOKEN']) {
  assert.equal(process.env[key], '', `${key} must be explicitly empty`)
}
for (const key of ['GROUPING_LLM_DISABLED', 'SEARCH_CORRECT_DISABLED', 'NEWS_AGENT_DISABLED']) {
  assert.equal(process.env[key], '1', `${key} must be explicitly disabled`)
}
assert.ok(process.env.LOAD_READY_PATH)
assert.ok(process.env.LOAD_RESULTS_DIR)
const controlToken = process.env.LOAD_CONTROL_TOKEN ?? ''
assert.ok(controlToken.length >= 32)
const database = target.pathname.slice(1)
const readyPath = process.env.LOAD_READY_PATH
const resultsDir = process.env.LOAD_RESULTS_DIR
const knownMedia: KnownLoadMedia[] = Array.from({ length: 3000 }, (_, index) => ({
  id: 310_000_000 + index, malId: 900_000 + index,
  title: `Load catalogue${String(Math.floor(index / 3)).padStart(4, '0')} season ${index % 3 + 1}`,
  episodes: 12,
}))
const provider = installProviderStubs({ knownMedia, coldCount: 1000, providerLatencyMs: 20 })
// Fail closed for SDK/node:http/net paths that bypass global fetch. No real provider socket
// can leave this QA process; the only allowed network is the owned loopback HTTP and PG path.
const originalConnect = Socket.prototype.connect
const socketGuard = { rejectedConnections: 0, rejectedHosts: [] as string[] }
const guardedConnect = function (this: Socket, ...args: unknown[]): Socket {
  const value = Array.isArray(args[0]) ? args[0][0] : args[0]
  let host: string
  if (value && typeof value === 'object') {
    const options = value as { host?: unknown; hostname?: unknown; path?: unknown }
    if (options.path != null) host = '[unix-socket-disallowed]'
    else host = String(options.host ?? options.hostname ?? 'localhost')
  } else if (typeof value === 'number') {
    host = typeof args[1] === 'string' ? args[1] : 'localhost'
  } else {
    host = '[unsupported-socket-address]'
  }
  host = host.toLowerCase().replace(/^\[|\]$/g, '')
  if (!['127.0.0.1', 'localhost', '::1'].includes(host)) {
    socketGuard.rejectedConnections++
    if (socketGuard.rejectedHosts.length < 20 && !socketGuard.rejectedHosts.includes(host)) socketGuard.rejectedHosts.push(host)
    throw new Error(`QA socket boundary blocked host ${host}`)
  }
  return (originalConnect as (...values: unknown[]) => Socket).apply(this, args)
}
Socket.prototype.connect = guardedConnect as Socket['connect']
// QA alone uses tsx. The HTTP app and its shared database client are the exact
// compiled production modules, with source imports used only for type checking.
const runtimeServerModule = '../dist/server.js'
const runtimeDatabaseModule = '../dist/db/index.js'
const { buildServer } = await import(runtimeServerModule) as typeof import('../src/server.js')
const { sql } = await import(runtimeDatabaseModule) as typeof import('../src/db/index.js')
const monitorSql = postgres(process.env.DATABASE_URL!, { max: 1, connection: { application_name: 'previously-qa-load-monitor' } })
const [identity] = await sql`select current_database() as name`
assert.equal(identity?.name, database)
const app = await buildServer()
const now = new Date()
const enrichment = {
  level: 'full', themes: ['Drama'], isAdult: false, contentRatings: [],
  people: { creators: [], directors: [], cast: [] }, related: [],
  videos: [{ id: 'qa-video', site: 'QA', kind: 'trailer', title: 'Synthetic QA video metadata',
    url: null, thumbnail: null, official: true, language: 'en', country: null,
    publishedAt: '2024-01-01T00:00:00.000Z' }],
  checkedAt: now.toISOString(),
  videoFallback: { source: 'tmdb', mediaType: 'tv', externalId: null, status: 'unmatched',
    checkedAt: now.toISOString(), metadataVersion: 6 },
}
const franchises = Array.from({ length: 1000 }, (_, index) => ({
  id: randomUUID(), title: `Load catalogue${String(index).padStart(4, '0')}`,
  mediaIds: [310_000_000 + index * 3, 310_000_001 + index * 3, 310_000_002 + index * 3],
  primaryMediaId: 310_000_000 + index * 3,
}))
const users = Array.from({ length: 500 }, (_, index) => {
  const owned = Array.from({ length: 50 }, (_, offset) => franchises[(index * 7 + offset) % franchises.length]!)
  return { id: randomUUID(), clerkId: `qa-load-${String(index).padStart(4, '0')}`,
    franchiseIds: owned.map((item) => item.id), primaryMediaIds: owned.map((item) => item.primaryMediaId) }
})
// Keep ordinary payload sizes while varying prose across titles/episodes. Repeating one
// description in every row would make gzip artificially favorable. No real catalogue is copied.
const proseNames = ['Amelia', 'Oliver', 'Sophia', 'Thomas', 'Marcus', 'Aurora', 'Daniel', 'Sophie',
  'Victor', 'Helena', 'Andrew', 'Juliet', 'Adrian', 'Evelyn', 'Stella', 'Samuel', 'Hannah', 'Claire',
  'Martin', 'Nathan', 'Astrid', 'Jasper', 'Morgan', 'Elliot']
const prosePlaces = ['harbor', 'forest', 'palace', 'island', 'valley', 'market', 'castle', 'tunnel',
  'desert', 'summit', 'temple', 'bridge', 'garden', 'meadow', 'museum', 'quarry', 'canals', 'plains',
  'ravine', 'canyon', 'marina', 'border', 'square', 'shrine']
const proseAdjectives = ['missing', 'strange', 'fragile', 'distant', 'lasting', 'renewed', 'careful',
  'guarded', 'patient', 'hopeful', 'fateful', 'restful', 'curious', 'nervous', 'wistful', 'playful']
const proseNouns = ['message', 'promise', 'witness', 'warning', 'visitor', 'rivalry', 'journey',
  'request', 'mystery', 'brother', 'captain', 'council', 'fortune', 'teacher']
function proseWord(words: readonly string[], seed: number, salt: number) {
  let value = (seed ^ Math.imul(salt, 0x9e3779b9)) >>> 0
  value = Math.imul(value ^ value >>> 16, 0x7feb352d)
  value = Math.imul(value ^ value >>> 15, 0x846ca68b)
  return words[((value ^ (value >>> 16)) >>> 0) % words.length]!
}
function episodeMetadataFor(mediaId: number) {
  return Array.from({ length: 12 }, (_, index) => {
    const salt = index * 7
    const name = proseWord(proseNames, mediaId, salt + 1)
    const place = proseWord(prosePlaces, mediaId, salt + 2)
    const adjective = proseWord(proseAdjectives, mediaId, salt + 3)
    const noun = proseWord(proseNouns, mediaId, salt + 4)
    return { number: index + 1, title: `The ${adjective} ${noun}`, airDate: Date.UTC(2024, 0, index + 1),
      overview: `${name} follows a hidden clue through the ${place}, where a ${adjective} ${noun} now awaits.`,
      still: null, runtime: 24 }
  })
}
function newsNoteFor(titleIndex: number) {
  const sentences = Array.from({ length: 10 }, (_, index) => {
    const salt = index * 13
    const name = proseWord(proseNames, titleIndex, salt + 1)
    const second = proseWord(proseNames, titleIndex, salt + 2)
    const place = proseWord(prosePlaces, titleIndex, salt + 3)
    const adjective = proseWord(proseAdjectives, titleIndex, salt + 4)
    const next = proseWord(proseAdjectives, titleIndex, salt + 5)
    const noun = proseWord(proseNouns, titleIndex, salt + 6)
    const other = proseWord(proseNouns, titleIndex, salt + 7)
    return [
      `The coming season follows ${name} into a ${place} where a ${adjective} ${noun} changes the journey.`,
      `${name} returns with a ${adjective} ${noun} while a ${next} ${other} approaches the ${place} before dawn.`,
      `The cast faces unfamiliar choices as ${name} discovers a ${adjective} ${noun} beneath the ${place} gate.`,
      `This update connects the ${place} mystery to a ${adjective} ${noun} that slowly reshapes ${second} completely.`,
      `The team prepares for another chapter while ${name} questions a ${adjective} ${noun} beside the ${place}.`,
    ][index % 5]!
  })
  const note = sentences.join(' ')
  assert.equal(note.split(/\s+/).length, 150)
  return note
}
async function seed() {
  const [rows] = await sql`select count(*)::int as count from users`
  assert.equal(rows?.count, 0, 'Scratch DB must be freshly migrated and empty')
  for (let offset = 0; offset < knownMedia.length; offset += 500) {
    const values = knownMedia.slice(offset, offset + 500).map((item) => ({
      id: item.id, title_english: item.title, title_romaji: item.title, format: 'TV', status: 'FINISHED',
      // Drizzle configures this shared postgres client to pass JSON/timestamps through: its
      // callers normally pre-encode them. This QA bulk insert must do the same explicitly.
      episodes: 12, genres: JSON.stringify(['Drama']), episodes_list: JSON.stringify(episodeMetadataFor(item.id)),
      popularity: 100, trending: 10, season_year: 2024, fetched_at: now.toISOString(),
    }))
    await sql`insert into media ${sql(values)}`
  }
  for (let offset = 0; offset < franchises.length; offset += 250) {
    await sql`insert into franchise ${sql(franchises.slice(offset, offset + 250).map((item) => ({
      id: item.id, title: item.title, primary_media_id: item.primaryMediaId,
      genres: JSON.stringify(['Drama']), grouping_source: 'manual',
      enrichment: JSON.stringify(enrichment), updated_at: now.toISOString(),
    })))}`
  }
  const members = franchises.flatMap((item) => item.mediaIds.map((mediaId, index) => ({
    media_id: mediaId, franchise_id: item.id, part_kind: 'season', sequence: index + 1,
    watch_order: index + 1, label: `Season ${index + 1}`,
  })))
  for (let offset = 0; offset < members.length; offset += 1000) {
    await sql`insert into franchise_member ${sql(members.slice(offset, offset + 1000))}`
  }
  // One current synthetic report per franchise exercises Following's research/history/social
  // composition rather than measuring an empty feed. URLs are inert .invalid metadata only.
  const news = franchises.map((item, index) => ({ id: randomUUID(), franchise_id: item.id,
    dedupe_key: 'season 4', status: 'announced_no_date', next: 'Season 4', release: 'TBA',
    note: newsNoteFor(index), source: `https://qa.invalid/news/catalogue-${index}-season-four-announced`,
    first_seen_at: now.toISOString(), last_seen_at: now.toISOString() }))
  const observations = news.map((item) => ({ id: randomUUID(), franchise_id: item.franchise_id,
    announcement_id: item.id, dedupe_key: item.dedupe_key, status: item.status,
    next: item.next, release: item.release, note: item.note, observed_at: now.toISOString() }))
  const evidence = observations.map((item, index) => ({ observation_id: item.id,
    url: news[index]!.source, publisher: 'Synthetic QA', published_at: now.toISOString(),
    tier: 'unknown', primary: false }))
  for (let offset = 0; offset < news.length; offset += 500) {
    await sql`insert into announcements ${sql(news.slice(offset, offset + 500))}`
    await sql`insert into announcement_observations ${sql(observations.slice(offset, offset + 500))}`
    await sql`insert into announcement_evidence ${sql(evidence.slice(offset, offset + 500))}`
  }
  await sql`insert into users ${sql(users.map((item) => ({ id: item.id, clerk_id: item.clerkId })))}`
  const statuses = ['watching', 'completed', 'planned', 'paused', 'dropped']
  const subscriptions = users.flatMap((user) => user.franchiseIds.map((id, index) => ({
    user_id: user.id, franchise_id: id, status: statuses[index % statuses.length]!,
  })))
  for (let offset = 0; offset < subscriptions.length; offset += 1000) {
    await sql`insert into subscriptions ${sql(subscriptions.slice(offset, offset + 1000))}`
  }
  const progress = users.flatMap((user) => user.primaryMediaIds.flatMap((id, index) => [0, 1, 2].map((part) => ({
    user_id: user.id, media_id: id + part,
    episodes_watched: index % 5 === 1 ? 12 : index % 5 === 0 ? (part === 0 ? 6 : 0) : 0,
  }))))
  for (let offset = 0; offset < progress.length; offset += 1000) {
    await sql`insert into progress ${sql(progress.slice(offset, offset + 1000))}`
  }
  await sql`analyze`
}
await seed()
// An independent SQL read verifies the actual seeded rows are varied and remain comparable
// in payload size to the earlier fixture (83-byte overview / 940-byte150word report).
const [proseAudit] = await sql`
  with episodes as (
    select item->>'overview' as overview from media
      cross join lateral jsonb_array_elements(episodes_list) as episode(item)
  ) select count(*)::int as episode_rows, count(distinct overview)::int as distinct_overviews,
    min(octet_length(overview))::int as overview_min_bytes,
    max(octet_length(overview))::int as overview_max_bytes,
    (select count(distinct note)::int from announcements) as distinct_notes,
    (select min(octet_length(note))::int from announcements) as note_min_bytes,
    (select max(octet_length(note))::int from announcements) as note_max_bytes from episodes`
assert.ok(proseAudit)
const proseProfile = Object.fromEntries(Object.entries(proseAudit).map(([key, value]) => [key, Number(value)]))
assert.equal(proseProfile.episode_rows, 36_000)
assert.ok(proseProfile.distinct_overviews! >= 25_000)
assert.equal(proseProfile.overview_min_bytes, 84)
assert.equal(proseProfile.overview_max_bytes, 84)
assert.equal(proseProfile.distinct_notes, 1000)
assert.equal(proseProfile.note_min_bytes, 969)
assert.equal(proseProfile.note_max_bytes, 969)

class Histogram {
  bins = new Uint32Array(60_001)
  count = 0
  totalMs = 0
  maxMs = 0
  add(ms: number) {
    this.count++; this.totalMs += ms; this.maxMs = Math.max(this.maxMs, ms)
    const index = Math.min(60_000, Math.max(0, Math.floor(ms)))
    this.bins[index] = (this.bins[index] ?? 0) + 1
  }
  snapshot() {
    const quantile = (q: number) => {
      if (!this.count) return null
      const targetCount = Math.ceil(this.count * q)
      let cumulative = 0
      for (let index = 0; index < this.bins.length; index++) {
        cumulative += this.bins[index] ?? 0
        if (cumulative >= targetCount) return index + 1
      }
      return 60_001
    }
    return { count: this.count, totalMs: Math.round(this.totalMs),
      meanMs: this.count ? Math.round(this.totalMs / this.count * 1000) / 1000 : null,
      p50Ms: quantile(0.5), p95Ms: quantile(0.95), p99Ms: quantile(0.99), maxMs: this.maxMs,
      binWidthMs: 1, overflowBinMs: 60_000 }
  }
}
function newPhase(name: string) {
  return { phase: name, startedAt: new Date().toISOString(), endedAt: null as string | null,
    queries: new Histogram(), dispatchWait: new Histogram(), errors: 0, inFlight: 0, peakInFlight: 0 }
}
let currentPhase = newPhase('startup')
const phases = [currentPhase]
const measureQueries = new AsyncLocalStorage<boolean>()
interface InstrumentedQuery {
  executed: boolean
  options: { onexecute?: (connection: unknown) => unknown }
  resolve: (value: unknown) => void
  reject: (value: unknown) => void
}
// Derive identity from the actual app client. TSX/conditional exports can create duplicate
// module identities; importing an internal Query file by path need not patch the app's class.
// This lazy probe is intentionally never awaited or executed.
const probe = sql`select 1`
const Query = { prototype: Object.getPrototypeOf(probe) } as {
  prototype: { handle: (this: InstrumentedQuery) => Promise<void> }
}
const originalHandle = Query.prototype.handle
Query.prototype.handle = async function () {
  if (!this.executed && measureQueries.getStore() !== false) {
    const phase = currentPhase
    const started = performance.now()
    phase.inFlight++; phase.peakInFlight = Math.max(phase.peakInFlight, phase.inFlight)
    const originalOnExecute = this.options.onexecute
    let dispatched = false
    this.options.onexecute = (connection) => {
      if (!dispatched) { phase.dispatchWait.add(performance.now() - started); dispatched = true }
      return originalOnExecute ? originalOnExecute(connection) : true
    }
    const resolve = this.resolve
    const reject = this.reject
    let settled = false
    const settle = (error: boolean) => {
      if (settled) return
      settled = true
      phase.queries.add(performance.now() - started); phase.inFlight--
      if (error) phase.errors++
    }
    this.resolve = (value) => { settle(false); resolve(value) }
    this.reject = (value) => { settle(true); reject(value) }
  }
  return originalHandle.call(this)
}
await sql`select 1 as qa_instrumentation_sanity`
assert.equal(currentPhase.queries.count, 1, 'QA query instrumentation must observe the actual app client')
const summarizePhase = (phase: typeof currentPhase) => ({
  phase: phase.phase, startedAt: phase.startedAt, endedAt: phase.endedAt,
  queries: phase.queries.snapshot(), dispatchWait: phase.dispatchWait.snapshot(),
  dispatchWaitDescription: 'Client query handle to postgres onexecute callback; includes client dispatch, connection availability and socket buffering. Callback does not cover every query and is not isolated pool wait.',
  dispatchCoverage: phase.queries.count ? phase.dispatchWait.count / phase.queries.count : null,
  errors: phase.errors, inFlight: phase.inFlight, peakInFlight: phase.peakInFlight,
})
const eventLoop = monitorEventLoopDelay({ resolution: 20 })
eventLoop.enable()
const gcTiming = new Histogram()
const gcKinds: Record<string, number> = {}
let previousGcCount = 0
let previousGcMs = 0
const gcObserver = new PerformanceObserver((list) => {
  for (const entry of list.getEntries()) {
    gcTiming.add(entry.duration)
    const kind = String((entry as typeof entry & { detail?: { kind?: number } }).detail?.kind ?? 'unknown')
    gcKinds[kind] = (gcKinds[kind] ?? 0) + 1
  }
})
gcObserver.observe({ entryTypes: ['gc'] })
let previousCpu = process.cpuUsage()
let previousTick = performance.now()
let previousUtilization = performance.eventLoopUtilization()
const resources: Record<string, unknown>[] = []
let sampling = false
async function sample() {
  if (sampling) return
  sampling = true
  try {
    const tick = performance.now()
    const cpu = process.cpuUsage(previousCpu)
    previousCpu = process.cpuUsage()
    const intervalMs = tick - previousTick
    previousTick = tick
    const utilization = performance.eventLoopUtilization(previousUtilization)
    previousUtilization = performance.eventLoopUtilization()
    const pg = await measureQueries.run(false, () => monitorSql`
      select state, wait_event_type, wait_event, count(*)::int as connections
      from pg_stat_activity where datname = current_database() and pid <> pg_backend_pid()
      group by state, wait_event_type, wait_event order by state, wait_event_type, wait_event`)
    resources.push({ at: new Date().toISOString(), phase: currentPhase.phase,
      ...process.memoryUsage(), intervalMs,
      cpuPercentOfOneCore: (cpu.user + cpu.system) / (intervalMs * 10),
      eventLoopUtilization: utilization.utilization,
      eventLoopDelayP95Ms: eventLoop.percentile(95) / 1_000_000,
      eventLoopDelayMaxMs: eventLoop.max / 1_000_000,
      gcCount: gcTiming.count - previousGcCount,
      gcWallDurationMs: gcTiming.totalMs - previousGcMs,
      pgActivity: [...pg] })
    previousGcCount = gcTiming.count
    previousGcMs = gcTiming.totalMs
    if (resources.length > 1000) resources.shift()
    eventLoop.reset()
  } finally { sampling = false }
}
const metrics = () => ({ phase: currentPhase.phase, providerStats: { ...provider.stats }, socketGuard,
  runtimeMemoryBudget: { heapSizeLimitBytes: getHeapStatistics().heap_size_limit,
    nodeOptions: process.env.NODE_OPTIONS ?? '', note: 'GC duration is wall time of observed GC entries, not isolated CPU cost. No forced GC.' },
  gc: { ...gcTiming.snapshot(), kinds: { ...gcKinds } },
  query: summarizePhase(currentPhase), resources: resources.at(-1) ?? null,
  phaseSnapshots: phases.map(summarizePhase), resourceSamples: resources.length })
const importRows = knownMedia.slice(0, 300).map((item, index) => ({
  malId: item.malId, status: index % 2 ? 'Watching' : 'Completed', watched: index % 2 ? 3 : 12, title: item.title,
}))
const fixture = { dbName: database, pid: process.pid, users, franchises, importRows,
  fixtures: { userCount: 500, franchiseCount: 1000, partsPerFranchise: 3, subscriptionsPerUser: 50,
    subscriptionCount: 25_000, progressRows: 75_000, providerLatencyMs: 20,
    announcementCount: 1000, observationCount: 1000, evidenceCount: 1000, storedNewsNoteWords: 150,
    proseFixture: 'Deterministic varied per-title150word notes and per-episode84byte overviews; no shared paragraph.',
    proseProfile } }
await app.register(async (control) => {
  control.addHook('preHandler', async (req, reply) => {
    const value = req.headers['x-load-token']
    if (typeof value !== 'string' || value.length !== controlToken.length ||
      !timingSafeEqual(Buffer.from(value), Buffer.from(controlToken))) {
      return reply.code(403).send({ error: 'forbidden' })
    }
  })
  control.get('/__load/fixture', async () => fixture)
  control.get('/__load/metrics', async () => metrics())
  control.post('/__load/phase', async (req, reply) => {
    const name = (req.body as { phase?: unknown } | null)?.phase
    if (typeof name !== 'string' || !/^[a-z0-9_-]{1,60}$/i.test(name)) return reply.code(400).send({ error: 'invalid phase' })
    currentPhase.endedAt = new Date().toISOString()
    currentPhase = newPhase(name)
    phases.push(currentPhase)
    if (phases.length > 100) return reply.code(400).send({ error: 'too many phases' })
    return metrics()
  })
  control.post('/__load/oracle', { bodyLimit: 4 * 1024 * 1024 }, async (req, reply) => {
    const expected = (req.body as { expected?: unknown } | null)?.expected
    if (!Array.isArray(expected) || expected.length > 10_000 || expected.some((item) =>
      !item || typeof item.userId !== 'string' || !/^[0-9a-f-]{36}$/i.test(item.userId) ||
      !Number.isInteger(item.mediaId) || !Number.isInteger(item.episodes) || item.episodes < 0 || item.episodes > 12)) {
      return reply.code(400).send({ error: 'invalid oracle expectations' })
    }
    return measureQueries.run(false, async () => {
      const mismatch = await monitorSql`
        select e."userId", e."mediaId", e.episodes as expected, p.episodes_watched as actual
        from jsonb_to_recordset(${monitorSql.json(expected)}::jsonb)
          as e("userId" uuid, "mediaId" integer, episodes integer)
        left join progress p on p.user_id=e."userId" and p.media_id=e."mediaId"
        where p.episodes_watched is distinct from e.episodes`
      const [counts] = await monitorSql`select
        (select count(*)::int from users) as users,
        (select count(*)::int from franchise) as franchises,
        (select count(*)::int from media) as media,
        (select count(*)::int from subscriptions) as subscriptions,
        (select count(*)::int from progress) as progress`
      return { ok: mismatch.length === 0, checked: expected.length, mismatchCount: mismatch.length,
        mismatches: [...mismatch].slice(0, 100), counts }
    })
  })
})
await app.listen({ host: '127.0.0.1', port: 0 })
const baseURL = `http://127.0.0.1:${(app.server.address() as AddressInfo).port}`
await mkdir(dirname(readyPath), { recursive: true })
await mkdir(resultsDir, { recursive: true })
await sample()
const interval = setInterval(() => { void sample().catch((error) => console.error('QA sampling error', error)) }, 5000)
await writeFile(readyPath, JSON.stringify({ baseURL, ...fixture }, null, 2) + '\n')
console.log('LOAD_SERVER_READY', JSON.stringify({ baseURL, database, fixtures: fixture.fixtures }))
let closing = false
async function close() {
  if (closing) return
  closing = true
  clearInterval(interval)
  await app.close()
  while (sampling) await new Promise((resolve) => setTimeout(resolve, 20))
  await sample()
  currentPhase.endedAt = new Date().toISOString()
  await writeFile(join(resultsDir, 'server-metrics.json'), JSON.stringify(metrics(), null, 2) + '\n')
  await writeFile(join(resultsDir, 'server-resources.json'), JSON.stringify(resources, null, 2) + '\n')
  eventLoop.disable()
  gcObserver.disconnect()
  Query.prototype.handle = originalHandle
  provider.restore()
  assert.equal(Socket.prototype.connect, guardedConnect)
  Socket.prototype.connect = originalConnect
  await sql.end({ timeout: 5 })
  await monitorSql.end({ timeout: 5 })
}
process.once('SIGTERM', () => { void close().then(() => process.exit(0), (error) => { console.error(error); process.exit(1) }) })
process.once('SIGINT', () => { void close().then(() => process.exit(0), (error) => { console.error(error); process.exit(1) }) })
