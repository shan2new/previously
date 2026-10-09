// Open-loop generator for the owned disposable load server; never accepts a target URL.
import assert from 'node:assert/strict'
import { readFile, writeFile } from 'node:fs/promises'
import { join } from 'node:path'
import { performance } from 'node:perf_hooks'
import { randomUUID } from 'node:crypto'
import { Agent, createServer, request as httpRequest } from 'node:http'
import type { AddressInfo } from 'node:net'
import { promisify } from 'node:util'
import { gunzip, gzipSync } from 'node:zlib'

interface User { id: string; clerkId: string; franchiseIds: string[]; primaryMediaIds: number[] }
interface Fixture { baseURL: string; dbName: string; users: User[]; importRows: unknown[]; fixtures: unknown }
const sleep = (ms: number) => new Promise<void>(resolve => setTimeout(resolve, Math.max(0, ms)))
class Histogram {
  bins = new Uint32Array(30_001); count = 0; total = 0; max = 0
  add(ms: number) { assert.ok(Number.isFinite(ms)); ms = Math.max(0, ms); this.bins[Math.min(30_000, Math.ceil(ms))]!++; this.count++; this.total += ms; this.max = Math.max(this.max, ms) }
  percentile(p: number) { if (!this.count) return null; let n = 0; const threshold = Math.ceil(this.count * p / 100); for (let i = 0; i < this.bins.length; i++) { n += this.bins[i]!; if (n >= threshold) return i } return 30_000 }
  summary() { return { count: this.count, meanMs: this.count ? this.total / this.count : null, p50Ms: this.percentile(50), p95Ms: this.percentile(95), p99Ms: this.percentile(99), maxMs: this.max } }
}

const MAX_WIRE_BYTES = 4 * 1024 * 1024
const MAX_JSON_BYTES = 16 * 1024 * 1024
const decodeGzip = promisify(gunzip)
const agent = new Agent({ keepAlive: true, maxSockets: 400 })
interface RawResponse { status: number; body: Buffer; encoding: string }
async function decodeBody(response: RawResponse): Promise<Buffer> {
  const data = response.encoding === 'gzip'
    ? await decodeGzip(response.body, { maxOutputLength: MAX_JSON_BYTES })
    : response.body
  assert.ok(response.encoding === 'gzip' || response.encoding === 'identity', 'unsupported content encoding')
  assert.ok(data.length <= MAX_JSON_BYTES, 'decoded response exceeds bounded collection limit')
  return data
}
function rawRequest(url: URL, method: string, headers: Record<string, string>, body: unknown, timeoutMs: number): Promise<RawResponse> {
  assert.equal(url.hostname, '127.0.0.1')
  assert.equal(url.protocol, 'http:')
  const payload = body === undefined ? undefined : Buffer.from(JSON.stringify(body))
  return new Promise((resolve, reject) => {
    let settled = false
    let timer: ReturnType<typeof setTimeout>
    const finish = (error?: Error, value?: RawResponse) => {
      if (settled) return
      settled = true; clearTimeout(timer)
      if (error) reject(error); else resolve(value!)
    }
    const req = httpRequest(url, { method, agent, headers: { ...headers, 'accept-encoding': 'gzip',
      ...(payload ? { 'content-type': 'application/json', 'content-length': String(payload.length) } : {}) } }, (res) => {
      let received = 0
      const chunks: Buffer[] = []
      res.on('data', (chunk: Buffer) => {
        received += chunk.length
        if (received > MAX_WIRE_BYTES) {
          const error = new Error('wire response exceeds bounded collection limit')
          res.destroy(error); req.destroy(error); finish(error)
        } else { chunks.push(chunk) }
      })
      res.on('error', (error) => finish(error))
      res.on('aborted', () => finish(new Error('response aborted before completion')))
      res.on('end', () => finish(undefined, { status: res.statusCode ?? 0, body: Buffer.concat(chunks),
        encoding: String(res.headers['content-encoding'] ?? 'identity').toLowerCase() }))
    })
    timer = setTimeout(() => { const error = new Error('request exceeded total timeout'); error.name = 'TimeoutError'; req.destroy(error); finish(error) }, timeoutMs)
    req.on('error', (error) => finish(error))
    req.end(payload)
  })
}

if (process.argv.includes('--self-test')) {
  const histogram = new Histogram(); histogram.add(-0.4); histogram.add(2.2)
  assert.equal(histogram.count, 2); assert.equal(histogram.percentile(50), 0); assert.equal(histogram.percentile(100), 3)
  assert.equal(histogram.max, 2.2); assert.equal(histogram.total, 2.2)
  const json = Buffer.from(JSON.stringify({ fixture: 'a'.repeat(1000) }))
  const compressed = gzipSync(json)
  assert.ok(compressed.length < json.length)
  assert.deepEqual(await decodeBody({ status: 200, body: compressed, encoding: 'gzip' }), json)
  await assert.rejects(decodeBody({ status: 200, body: Buffer.from('bad gzip'), encoding: 'gzip' }))
  const server = createServer((_req, res) => { res.setHeader('content-encoding', 'gzip'); res.end(compressed) })
  try {
    await new Promise<void>(resolve => server.listen(0, '127.0.0.1', resolve))
    const reply = await rawRequest(new URL(`http://127.0.0.1:${(server.address() as AddressInfo).port}/`), 'GET', {}, undefined, 1000)
    assert.equal(reply.body.length, compressed.length)
    assert.equal((await decodeBody(reply)).length, json.length)
  } finally { agent.destroy(); await new Promise<void>(resolve => server.close(() => resolve())) }
  console.log('LOAD_HARNESS_CHECKS passed: nonnegative histogram; compressed wire versus JSON bytes; bounded raw HTTP decoding')
  process.exit(0)
}

const ready = JSON.parse(await readFile(process.env.LOAD_READY_PATH!, 'utf8')) as Fixture
assert.match(ready.dbName, /^previously_qa_load_[a-f0-9]{32}$/)
const origin = new URL(ready.baseURL)
assert.equal(origin.hostname, '127.0.0.1')
assert.equal(origin.protocol, 'http:')
assert.ok(process.env.LOAD_CONTROL_TOKEN && process.env.LOAD_RESULTS_DIR)
assert.equal(ready.users.length, 500)
const quick = process.env.LOAD_QUICK === '1'
const calibration = process.env.LOAD_CALIBRATE === '1'
const harnessOnly = quick || calibration
const output = process.env.LOAD_RESULTS_DIR!
const token = process.env.LOAD_CONTROL_TOKEN!
interface Counts { offered: number; sent: number; completed: number; dropped: number; requestErrors: number; timeouts: number; serverErrors: number; non2xx: number; incorrectResponses: number; bytes: number; wireBytes: number; jsonBytes: number; gzipResponses: number; errors: string[]; latency: Histogram; sendLag: Histogram; peakInFlight: number; routes: Record<string, { completed: number; errors: number; bytes: number; wireBytes: number; jsonBytes: number; gzipResponses: number; latency: Histogram }> }
const counts = (): Counts => ({ offered: 0, sent: 0, completed: 0, dropped: 0, requestErrors: 0, timeouts: 0, serverErrors: 0, non2xx: 0, incorrectResponses: 0, bytes: 0, wireBytes: 0, jsonBytes: 0, gzipResponses: 0, errors: [], latency: new Histogram(), sendLag: new Histogram(), peakInFlight: 0, routes: {} })
const summarize = (c: Counts, seconds: number) => ({ ...c, errors: c.errors, latency: c.latency.summary(), sendLag: c.sendLag.summary(), achievedRPS: c.completed / seconds, offeredRPS: c.offered / seconds, routes: Object.fromEntries(Object.entries(c.routes).map(([route, r]) => [route, { ...r, throughputRPS: r.completed / seconds, latency: r.latency.summary() }])) })
async function control(path: string, body?: unknown) {
  const response = await rawRequest(new URL(path, ready.baseURL), body === undefined ? 'GET' : 'POST', { 'x-load-token': token }, body, 10_000)
  assert.equal(response.status, 200, `control ${path}`)
  return JSON.parse((await decodeBody(response)).toString('utf8')) as any
}
async function diagnostic(path: string) {
  const response = await rawRequest(new URL(path, ready.baseURL), 'GET', { authorization: `Bearer ${token}` }, undefined, 5000)
  assert.equal(response.status, 200, `diagnostic ${path}`)
  return JSON.parse((await decodeBody(response)).toString('utf8')) as any
}
const readiness = await diagnostic('/ready')
assert.equal(readiness.ok, true)
const expected = new Map<string, { userId: string; mediaId: number; episodes: number; sequence?: number }>()
interface Mutation { operationID: string; writerID: string; sequence: number }
const writers = new Map<string, { id: string; sequence: number }>()
function freshMutation(user: User): Mutation {
  let writer = writers.get(user.id)
  if (!writer) { writer = { id: randomUUID(), sequence: 0 }; writers.set(user.id, writer) }
  assert.ok(writer.sequence < Number.MAX_SAFE_INTEGER)
  return { operationID: randomUUID(), writerID: writer.id, sequence: ++writer.sequence }
}
const pending = new Set<Promise<void>>()
const cap = 300
let sequence = 0
let writeSequence = 0
const timeoutMs = 5000
const extras = counts()
const importResults: any[] = []
const responseShapes: Record<string, unknown> = {}
async function request(c: Counts, user: User, route: string, path: string, method = 'GET', body?: unknown, validate?: (data: any) => boolean, onSuccess?: (data: any, mutation?: Mutation) => void) {
  c.sent++
  const r = c.routes[route] ??= { completed: 0, errors: 0, bytes: 0, wireBytes: 0, jsonBytes: 0, gzipResponses: 0, latency: new Histogram() }
  const start = performance.now()
  try {
    const mutation = method === 'PUT' && path === '/me/progress' ? freshMutation(user) : undefined
    const headers: Record<string, string> = { authorization: `Bearer dev:${user.clerkId}` }
    if (mutation) Object.assign(headers, { 'x-previously-operation-id': mutation.operationID,
      'x-previously-writer-id': mutation.writerID, 'x-previously-writer-seq': String(mutation.sequence) })
    const response = await rawRequest(new URL(path, ready.baseURL), method, headers, body, timeoutMs)
    c.wireBytes += response.body.length; r.wireBytes += response.body.length
    if (response.encoding === 'gzip') { c.gzipResponses++; r.gzipResponses++ }
    const decoded = await decodeBody(response)
    c.bytes += decoded.length; r.bytes += decoded.length
    c.jsonBytes += decoded.length; r.jsonBytes += decoded.length
    const text = decoded.toString('utf8')
    if (response.status < 200 || response.status >= 300) { c.non2xx++; if (response.status >= 500) c.serverErrors++; throw new Error(`HTTP ${response.status}: ${text.slice(0, 150)}`) }
    const data = JSON.parse(text)
    if (validate && !validate(data)) { c.incorrectResponses++; throw new Error('response shape/ownership mismatch') }
    if (!responseShapes[route]) responseShapes[route] = { keys: Object.keys(data), franchises: data.franchises?.length,
      parts: data.parts?.length, posts: data.posts?.length, sessions: data.sessions?.length, items: data.items?.length }
    onSuccess?.(data, mutation)
    c.completed++; r.completed++
    return data
  } catch (error) {
    c.requestErrors++; r.errors++
    if (error instanceof Error && (error.name === 'TimeoutError' || error.name === 'AbortError')) c.timeouts++
    if (c.errors.length < 30) c.errors.push(`${route}: ${String(error)}`)
    return null
  } finally { const ms = performance.now() - start; c.latency.add(ms); r.latency.add(ms) }
}
function dispatch(c: Counts, index: number) {
  // Prime-step account rotation spreads work; imports exclusively use accounts498 and499.
  const user = ready.users[(index * 7) % 498]!
  const kind = index % 100
  let p: Promise<any>
  if (kind < 30) {
    const owned = new Set(user.franchiseIds)
    p = request(c, user, 'library', '/me/library', 'GET', undefined, data => Array.isArray(data.franchises) && data.franchises.length === 50 && new Set(data.franchises.map((f: any) => f.id)).size === 50 && data.franchises.every((f: any) => owned.has(f.id)))
  } else if (kind < 55) {
    const id = user.franchiseIds[(Math.floor(index / 100) * 13) % 50]!
    p = request(c, user, 'detail', `/franchises/${id}`, 'GET', undefined, data => data.id === id && Array.isArray(data.parts))
  } else if (kind < 75) {
    p = request(c, user, 'warm-search', '/search?source=anilist&q=Load%20catalogue&exact=1&limit=10', 'GET', undefined, data => Array.isArray(data.franchises) && data.franchises.length > 0)
  } else if (kind < 85) {
    p = request(c, user, 'feed', '/me/feed', 'GET', undefined, data => data && data.capabilities?.comments === false && Array.isArray(data.posts) && data.posts.length > 0)
  } else if (kind < 90) {
    p = request(c, user, 'notifications', '/me/notifications', 'GET', undefined, data => Array.isArray(data.items))
  } else if (kind < 95) {
    p = request(c, user, 'watch-sessions', '/me/watch-sessions', 'GET', undefined, data => Array.isArray(data.sessions))
  } else {
    const mediaId = user.primaryMediaIds[0]!
    const episodes = (writeSequence++ % 11) + 1
    p = request(c, user, 'progress-write', '/me/progress', 'PUT', { mediaId, episodes }, data => data.ok === true && typeof data.applied === 'boolean', (data, mutation) => {
      assert.ok(mutation)
      const key = `${user.id}:${mediaId}`
      const prior = expected.get(key)
      if (data.applied !== false && (!prior?.sequence || mutation.sequence > prior.sequence))
        expected.set(key, { userId: user.id, mediaId, episodes, sequence: mutation.sequence })
    })
  }
  const task = p.then(() => {}).finally(() => pending.delete(task))
  pending.add(task); c.peakInFlight = Math.max(c.peakInFlight, pending.size)
}
async function runImport(userIndex: number) {
  const user = ready.users[userIndex]!
  const started = performance.now()
  const startedAt = new Date().toISOString()
  extras.offered++
  let job = await request(extras, user, 'import-preview', '/me/import/preview?async=1', 'POST', { source: 'mal', rows: ready.importRows.slice(0, 150) }, data => typeof data.id === 'string')
  const previewDeadline = performance.now() + 60_000
  // Same asynchronous preview/poll protocol as APIClient.importPreview; the real global
  // AniList import pacer intentionally spaces mapping requests by3seconds.
  while (job?.state === 'reading' && performance.now() < previewDeadline) {
    await sleep(2000); extras.offered++
    job = await request(extras, user, 'import-preview-poll', `/me/import/${job.id}/preview`, 'GET')
  }
  const preview = job?.preview
  if (!preview?.id) { importResults.push({ userIndex, ok: false, reason: 'async preview failed', job }); return }
  extras.offered++
  let progress = await request(extras, user, 'import-apply', `/me/import/${preview.id}/apply`, 'POST', {}, data => typeof data.state === 'string')
  const deadline = performance.now() + 30_000
  while (progress && progress.state !== 'done' && performance.now() < deadline) {
    await sleep(200); extras.offered++
    progress = await request(extras, user, 'import-poll', `/me/import/${preview.id}`, 'GET')
  }
  const ok = progress?.state === 'done' && progress.failed === 0 && progress.shows === 50
  if (ok) for (let i = 0; i < 150; i++) expected.set(`${user.id}:${310_000_000 + i}`, { userId: user.id, mediaId: 310_000_000 + i, episodes: i % 2 === 0 ? 12 : 3 })
  importResults.push({ userIndex, startedAt, finishedAt: new Date().toISOString(), durationMs: performance.now() - started, ok, progress })
}
async function backgroundStress() {
  const duration = quick ? 1000 : 10_000
  const count = quick ? 10 : 200
  const start = performance.now()
  const tasks: Promise<unknown>[] = []
  // Additional cold-provider requests are reported separately from the exact95/5 core mix.
  for (let i = 0; i < count; i++) {
    await sleep(start + i * duration / count - performance.now())
    extras.offered++
    const query = `Cold${String(i).padStart(4, '0')}`
    tasks.push(request(extras, ready.users[i % 498]!, 'cold-search', `/search?source=anilist&q=${query}&exact=1&limit=10`, 'GET', undefined, data => Array.isArray(data.franchises) && data.franchises.some((item: any) => item.title === `${query} synthetic`)))
    if (i === 0) { tasks.push(runImport(498)); tasks.push(runImport(499)) }
  }
  await Promise.all(tasks)
}
const plan = [
  { name: 'warmup', rps: 15, seconds: quick ? 2 : 120 },
  { name: 'sustained', rps: 75, seconds: quick ? 5 : calibration ? 180 : 900 },
  { name: 'burst', rps: 150, seconds: quick ? 1 : calibration ? 30 : 60 },
  { name: 'recovery', rps: 15, seconds: quick ? 2 : calibration ? 60 : 300 },
]
const results: any[] = []
let background: Promise<void> | undefined
let backgroundElapsedSeconds = 0
for (const phase of plan) {
  await control('/__load/phase', { phase: phase.name })
  const c = counts()
  const start = performance.now()
  const total = phase.seconds * phase.rps
  if (phase.name === 'sustained') {
    const backgroundStart = performance.now()
    background = backgroundStress().finally(() => { backgroundElapsedSeconds = (performance.now() - backgroundStart) / 1000 })
  }
  console.log(JSON.stringify({ event: 'phase-start', ...phase, plannedRequests: total, at: new Date().toISOString() }))
  let nextProgress = 30_000
  for (let i = 0; i < total; i++) {
    const scheduled = start + i * 1000 / phase.rps
    await sleep(scheduled - performance.now())
    const lag = performance.now() - scheduled
    c.offered++; c.sendLag.add(lag)
    if (pending.size >= cap || lag > 500) c.dropped++
    else dispatch(c, sequence++)
    if (performance.now() - start > nextProgress) {
      console.log(JSON.stringify({ event: 'phase-progress', phase: phase.name, elapsedSeconds: Math.round((performance.now() - start) / 1000), sent: c.sent, completed: c.completed, errors: c.errors.length, dropped: c.dropped }))
      nextProgress += 30_000
    }
  }
  await sleep(start + phase.seconds * 1000 - performance.now())
  const drainStarted = performance.now()
  await Promise.all([...pending])
  if (phase.name === 'sustained') await background
  const actualElapsedMs = performance.now() - start
  const result = { ...phase, ...summarize(c, actualElapsedMs / 1000), scheduledWindowCompletedRPS: c.completed / phase.seconds,
    drainMs: performance.now() - drainStarted, actualElapsedMs, server: await control('/__load/metrics') }
  results.push(result)
  await writeFile(join(output, 'traffic-progress.json'), JSON.stringify({ quickHarnessOnly: harnessOnly, calibrationOnly: calibration, results }, null, 2) + '\n')
  console.log(JSON.stringify({ event: 'phase-end', phase: phase.name, achievedRPS: result.achievedRPS, p95Ms: result.latency.p95Ms, p99Ms: result.latency.p99Ms, errors: result.non2xx, drops: result.dropped }))
}
const oracle = await control('/__load/oracle', { expected: [...expected.values()].map(({ sequence: _sequence, ...entry }) => entry) })
const finalMetrics = await control('/__load/metrics')
const productionObservability = await diagnostic('/internal/metrics')
const productionUsage = await diagnostic('/internal/usage')
const failures: string[] = []
for (const phase of results) {
  if (!quick && phase.achievedRPS < phase.rps * .98) failures.push(`${phase.name}: achieved ${phase.achievedRPS.toFixed(2)} below 98% of ${phase.rps}`)
  if (phase.requestErrors || phase.dropped) failures.push(`${phase.name}: errors/timeouts/incorrect/dropped requests`)
  if (phase.latency.p95Ms >= 1000 || phase.latency.p99Ms >= 2000) failures.push(`${phase.name}: core latency exceeds p95<1000ms or p99<2000ms`)
}
if (!oracle.ok) failures.push(`canonical progress mismatch: ${oracle.mismatchCount}`)
const expectedCounts = { users: 500, franchises: quick ? 1010 : 1200, media: quick ? 3010 : 3200, subscriptions: 25100, progress: 75300 }
for (const [key, value] of Object.entries(expectedCounts)) {
  if (oracle.counts?.[key] !== value) failures.push(`canonical final ${key} count ${oracle.counts?.[key]} differs from ${value}`)
}
if (productionUsage.counts?.registered !== 500 || productionUsage.counts?.library_users !== 500 || productionUsage.deletion?.pending !== 0) failures.push('productionaggregateusagecountsincorrect')
if (extras.requestErrors) failures.push('cold/import stress errors')
if (importResults.length !== 2 || importResults.some(result => !result.ok)) failures.push('two simultaneous imports did not each complete50shows without failed rows')
if (finalMetrics.providerStats.blockedRequests || finalMetrics.providerStats.unsupportedQueries || finalMetrics.socketGuard?.rejectedConnections) failures.push('unexpected outbound destination/unsupportedprovider operation attempted and denied')
const recovery = results.find(result => result.name === 'recovery')!
if (recovery.latency.p95Ms >= 1000 || recovery.latency.p99Ms >= 2000) failures.push('recovery did not return within core latency limits')
const report = {
  quickHarnessOnly: harnessOnly, calibrationOnly: calibration, qualifiedDuration: !harnessOnly, planningPeakRPS: 15, testedSustainedMultiplier: 5,
  averagePlanningRequestsPerDay: 4000, averagePlanningRPS: 4000 / 86400,
  rateModel: 'Fixed absolute dispatch times; open loop; maximum 300 in flight; drops if send lag exceeds 500ms; no retries. Achieved RPS uses actual phase elapsed time including drain.',
  mix: 'Core 95% reads and 5% absolute progress PUTs per deterministic 100 request cycle; additional cold searches and two imports reported separately.',
  byteAccounting: 'wireBytes counts encoded HTTP response bodies, excluding headers and framing; jsonBytes counts decoded response bodies. Legacy bytes is an alias for jsonBytes. Gzip decoding and JSON validation are included in latency.',
  timeoutMs, fixtures: ready.fixtures, responseShapes, results, backgroundStress: { ...summarize(extras, backgroundElapsedSeconds), actualElapsedSeconds: backgroundElapsedSeconds }, importResults,
  canonicalWriteOracle: oracle, finalMetrics, productionObservability, productionUsage, readiness, failures, passedRequestAndLatencyCriteria: failures.length === 0,
  memoryRecoveryRequiresResourceReview: true,
  limitations: ['Loopback HTTP excludes public ISP/tunnel/TLS latency and loss.', 'Deterministic20msAniList stub excludes actual provider variability/rate limits.', 'DEV_AUTH_BYPASS exercises real identity/upsert/ownership paths, not liveApple/Clerk tokenverification.', 'Synthetic cachedanime-onlycatalogue; no productiondata copied.', 'SharedMacMini co-resident services/simulator; no dedicatedcapacityclaim.'],
}
await writeFile(join(output, 'traffic-results.json'), JSON.stringify(report, null, 2) + '\n')
console.log(JSON.stringify({ event: 'finished', passed: failures.length === 0, failures, canonicalWritesChecked: oracle.checked, imports: importResults.map(r => ({ userIndex: r.userIndex, ok: r.ok })) }))
process.exitCode = failures.length ? 1 : 0
agent.destroy()
