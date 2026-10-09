import { createHash, timingSafeEqual } from 'node:crypto'
import { monitorEventLoopDelay } from 'node:perf_hooks'
import type { FastifyInstance, FastifyRequest } from 'fastify'
import { sql } from './db/index.js'
import { env } from './env.js'

const bounds = [25, 50, 100, 250, 500, 1000, 2000, 5000]
type Counter = { requests: number; errors: number; totalMs: number; buckets: number[]; statuses: Record<string, number> }

/** Bounded aggregate telemetry: no tokens, search strings, email, body or user identifiers. */
export function installObservability(app: FastifyInstance): void {
  const routes = new Map<string, Counter>()
  const began = Date.now()
  const loop = monitorEventLoopDelay({ resolution: 20 })
  loop.enable()
  app.addHook('onClose', async () => loop.disable())
  app.addHook('onResponse', async (req, reply) => {
    const pattern = req.routeOptions.url ?? 'unmatched'
    const key = `${req.method} ${pattern}`
    if (!routes.has(key) && routes.size < 200) routes.set(key,
      { requests: 0, errors: 0, totalMs: 0, buckets: bounds.map(() => 0), statuses: {} })
    const row = routes.get(key)
    const elapsed = reply.elapsedTime
    if (row) {
      row.requests++; row.totalMs += elapsed
      if (reply.statusCode >= 500) row.errors++
      const status = String(Math.floor(reply.statusCode / 100)) + 'xx'
      row.statuses[status] = (row.statuses[status] ?? 0) + 1
      bounds.forEach((bound, index) => { if (elapsed <= bound) row.buckets[index] = (row.buckets[index] ?? 0) + 1 })
    }
    if (reply.statusCode >= 500 || elapsed >= 1000) req.log.warn({ event: 'http.request_outcome',
      route: key, status: reply.statusCode, durationMs: Math.round(elapsed), requestId: req.id })
  })

  function authorized(req: FastifyRequest): boolean {
    const expected = env.OBSERVABILITY_TOKEN
    if (!expected || expected.length < 32) return false
    const supplied = req.headers.authorization?.replace(/^Bearer /, '') ?? ''
    const digest = (value: string) => createHash('sha256').update(value).digest()
    return timingSafeEqual(digest(expected), digest(supplied))
  }

  app.get('/internal/metrics', async (req, reply) => {
    if (!authorized(req)) return reply.code(404).send({ error: 'not found' })
    reply.header('Cache-Control', 'no-store')
    return { measuredAt: Date.now(), startedAt: began, uptimeSeconds: process.uptime(),
      memory: process.memoryUsage(), cpu: process.cpuUsage(),
      eventLoopMs: { mean: Number.isFinite(loop.mean) ? loop.mean / 1e6 : 0,
        p95: loop.percentile(95) / 1e6, p99: loop.percentile(99) / 1e6 },
      latencyBucketUpperMs: bounds, routes: Object.fromEntries(routes) }
  })
  app.get('/internal/usage', async (req, reply) => {
    if (!authorized(req)) return reply.code(404).send({ error: 'not found' })
    reply.header('Cache-Control', 'no-store')
    const now = Date.now()
    const [counts] = await sql`select count(*)::int as registered,
      count(*) filter (where last_opened_at >= ${now - 86_400_000})::int as active_24h,
      count(*) filter (where last_opened_at >= ${now - 7 * 86_400_000})::int as active_7d,
      count(*) filter (where created_at >= now() - interval '7 days')::int as registered_7d,
      count(*) filter (where exists (select 1 from subscriptions s where s.user_id = users.id))::int as library_users,
      count(*) filter (where exists (select 1 from progress p where p.user_id = users.id and p.episodes_watched > 0))::int as progress_users
      from users`
    const [deletion] = await sql`select count(*)::int as pending from account_deletions where completed_at is null`
    return { measuredAt: now, counts, deletion,
      definition: 'Activity is the most recent confirmed app-open timestamp; no cross-app tracking or per-user event export.' }
  })
  // Collapse simultaneous probes into one database operation; a blocked pool cannot accumulate
  // unlimited readiness queries. The public response contains no infrastructure details.
  let probe: Promise<boolean> | undefined
  let cached = { at: 0, ok: false }
  app.get('/ready', async (_req, reply) => {
    if (Date.now() - cached.at > 5000 && !probe) {
      probe = sql`select 1`.then(() => true, () => false).then((ok) => {
        cached = { at: Date.now(), ok }; probe = undefined; return ok
      })
    }
    let timer: ReturnType<typeof setTimeout> | undefined
    const ok = probe ? await Promise.race([probe, new Promise<boolean>((resolve) => {
      timer = setTimeout(() => resolve(false), 1000)
    })]) : cached.ok
    clearTimeout(timer)
    return reply.code(ok ? 200 : 503).header('Cache-Control', 'no-store').send({ ok })
  })
}
