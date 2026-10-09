// Explicitly invoked QA only. Real production routes/auth/services/migrations, disposable PostgreSQL.
// Faults live in this loopback proxy and scratch-only DB triggers; no production hooks are added.
import assert from 'node:assert/strict'
import { randomUUID } from 'node:crypto'
import { writeFile } from 'node:fs/promises'
import { createServer, request as httpRequest, type IncomingMessage, type ServerResponse } from 'node:http'
import { Socket, type AddressInfo } from 'node:net'

const target = new URL(process.env.DATABASE_URL ?? '')
assert.equal(target.hostname, '127.0.0.1')
assert.match(target.pathname, /^\/previously_qa_progress_[a-f0-9]{32}$/)
assert.equal(process.env.DOTENV_CONFIG_PATH, '/dev/null')
assert.equal(process.env.APP_ENV, 'test')
assert.equal(process.env.DEV_AUTH_BYPASS, '1')
for (const key of ['CLERK_SECRET_KEY', 'CLERK_JWT_KEY', 'OPENROUTER_API_KEY', 'CEREBRAS_API_KEY', 'TMDB_ACCESS_TOKEN']) {
  assert.equal(process.env[key], '', `${key} must be explicitly empty`)
}
assert.ok(process.env.PREVIOUSLY_QA_RESULTS)

const outbound = { blockedFetches: 0, blockedSockets: 0 }
const originalFetch = globalThis.fetch
globalThis.fetch = async (input, init) => {
  const url = new URL(input instanceof Request ? input.url : String(input))
  if (url.protocol !== 'http:' || url.hostname !== '127.0.0.1') {
    outbound.blockedFetches++
    throw new Error('Progress QA forbids outbound provider fetch')
  }
  return originalFetch(input, init)
}
const originalConnect = Socket.prototype.connect
Socket.prototype.connect = function (this: Socket, ...args: unknown[]) {
  const value = Array.isArray(args[0]) ? args[0][0] : args[0]
  const options = value && typeof value === 'object' ? value as { host?: string; hostname?: string; path?: string } : null
  const host = options ? options.path ? '[unix-socket-denied]' : options.host ?? options.hostname ?? 'localhost'
    : typeof value === 'number' ? typeof args[1] === 'string' ? args[1] : 'localhost' : '[unsupported-address]'
  if (!['127.0.0.1', 'localhost', '::1'].includes(host)) {
    outbound.blockedSockets++
    throw new Error('Progress QA forbids outbound provider sockets')
  }
  return Reflect.apply(originalConnect, this, args)
} as typeof Socket.prototype.connect

// Source types only; runtime effects execute the exact compiled release modules.
async function importRuntime<T>(module: string): Promise<T> {
  return import(`../dist/${module}.js`) as Promise<T>
}

const { buildServer } = await importRuntime<typeof import('../src/server.js')>('server')
const { sql } = await importRuntime<typeof import('../src/db/index.js')>('db/index')
const app = await buildServer()
const cases: { name: string; status: 'passed' | 'failed'; durationMs: number; error?: string; evidence?: unknown }[] = []
const faults: { method: string | undefined; path: string | undefined; upstreamStatus: number | undefined; mode: string }[] = []
let dropNextResponse = false
let upstreamPort = 0

// Fully consume the production HTTP response before dropping the client connection. A failed
// fetch then represents a lost receipt after a route's awaited commit, rather than a timed sleep.
const proxy = createServer((req: IncomingMessage, res: ServerResponse) => {
  const drop = dropNextResponse
  dropNextResponse = false
  const upstream = httpRequest({ hostname: '127.0.0.1', port: upstreamPort, method: req.method,
    path: req.url, headers: { ...req.headers, host: `127.0.0.1:${upstreamPort}` } }, (reply) => {
    const chunks: Buffer[] = []
    reply.on('data', (chunk: Buffer) => chunks.push(chunk))
    reply.on('end', () => {
      if (drop) {
        faults.push({ method: req.method, path: req.url, upstreamStatus: reply.statusCode, mode: 'drop_after_upstream_response' })
        res.socket?.destroy()
      } else {
        res.writeHead(reply.statusCode ?? 502, reply.headers)
        res.end(Buffer.concat(chunks))
      }
    })
  })
  upstream.on('error', (error) => { res.writeHead(502); res.end(error.message) })
  req.pipe(upstream)
})

const A = 'qa-progress-account-a'
const B = 'qa-progress-account-b'
const FRANCHISE = '10000000-0000-4000-8000-000000000001'
const M1 = 310_000_001
const M2 = 310_000_002
const SESSION = '20000000-0000-4000-8000-000000000001'
let userA = ''
let userB = ''
let base = ''

const WRITER = randomUUID()
function stamp(sequence: number, writer = WRITER) {
  return { 'x-previously-operation-id': randomUUID(), 'x-previously-writer-id': writer,
    'x-previously-writer-seq': String(sequence) }
}
async function call(account: string, method: string, path: string, payload?: unknown, headers: Record<string, string> = {}) {
  const response = await fetch(`${base}${path}`, {
    method, headers: { ...headers, authorization: `Bearer dev:${account}`, ...(payload === undefined ? {} : { 'content-type': 'application/json' }) },
    body: payload === undefined ? undefined : JSON.stringify(payload), signal: AbortSignal.timeout(5000),
  })
  const text = await response.text()
  return { status: response.status, body: text ? JSON.parse(text) : null, applied: response.headers.get('x-previously-applied') }
}

async function progressFor(userId: string) {
  return [...await sql`select media_id as "mediaId", episodes_watched as episodes from progress
    where user_id = ${userId} order by media_id`]
}

async function statusFor(userId: string) {
  const [row] = await sql`select status from subscriptions where user_id = ${userId} and franchise_id = ${FRANCHISE}`
  return row?.status ?? null
}

async function reset() {
  dropNextResponse = false
  await sql`delete from qa_progress_fault`
  await sql`delete from qa_watch_fault`
  await sql`delete from client_mutation_operations`
  await sql`delete from client_mutation_resources`
  await sql`delete from watch_sessions`
  await sql`delete from progress`
  await sql`delete from subscriptions`
  await sql`insert into progress (user_id, media_id, episodes_watched) values (${userA}, ${M1}, 2), (${userA}, ${M2}, 3)`
  await sql`insert into subscriptions (user_id, franchise_id, status) values (${userA}, ${FRANCHISE}, 'watching')`
  await sql`delete from qa_progress_audit`
}

async function run(name: string, test: () => Promise<unknown>) {
  await reset()
  const start = performance.now()
  try {
    const evidence = await test()
    cases.push({ name, status: 'passed', durationMs: Math.round(performance.now() - start), evidence })
  } catch (error) {
    cases.push({ name, status: 'failed', durationMs: Math.round(performance.now() - start), error: error instanceof Error ? error.message : String(error) })
  }
  console.log(`${cases.at(-1)!.status.toUpperCase()} ${name}`)
}

try {
  const [database] = await sql`select current_database() as name`
  assert.ok(database)
  assert.equal(database.name, target.pathname.slice(1))
  await app.listen({ host: '127.0.0.1', port: 0 })
  upstreamPort = (app.server.address() as AddressInfo).port
  await new Promise<void>((resolve) => proxy.listen(0, '127.0.0.1', resolve))
  base = `http://127.0.0.1:${(proxy.address() as AddressInfo).port}`
  for (const account of [A, B]) assert.equal((await call(account, 'GET', '/me/profile')).status, 200)
  const identities = await sql`select id, clerk_id from users order by clerk_id`
  userA = identities.find((row) => row.clerk_id === A)!.id
  userB = identities.find((row) => row.clerk_id === B)!.id
  assert.notEqual(userA, userB)
  await sql`insert into media (id, title_english, format, status, episodes) values
    (${M1}, 'QA synthetic season one', 'TV', 'FINISHED', 12),
    (${M2}, 'QA synthetic season two', 'TV', 'FINISHED', 10)`
  // Subscribe's genuine stale-while-revalidate hooks see cached metadata and need no provider.
  await sql`insert into franchise (id, title, primary_media_id, enrichment) values
    (${FRANCHISE}, 'QA synthetic franchise', ${M1}, ${JSON.stringify({ level: 'full', related: [], checkedAt: new Date().toISOString() })}::jsonb)`
  await sql`insert into franchise_member (media_id, franchise_id, part_kind, sequence, watch_order) values
    (${M1}, ${FRANCHISE}, 'season', 1, 1), (${M2}, ${FRANCHISE}, 'season', 2, 2)`

  // Fault control exists only inside the fresh disposable DB. On M2 it can fail after M1 was
  // written in the same transaction; reading the DB afterwards proves rollback, independently.
  await sql`create table qa_progress_fault (media_id integer primary key)`
  await sql.unsafe(`create function qa_fail_progress() returns trigger language plpgsql as $$
    begin
      if exists (select 1 from qa_progress_fault where media_id = NEW.media_id) then
        raise exception 'QA injected failure before progress commit' using errcode = 'P0001';
      end if;
      return NEW;
    end; $$`)
  await sql.unsafe('create trigger qa_progress_before_write before insert or update on progress for each row execute function qa_fail_progress()')
  await sql`create table qa_progress_audit (user_id uuid, media_id integer, episodes integer)`
  await sql.unsafe(`create function qa_audit_progress() returns trigger language plpgsql as $$
    begin insert into qa_progress_audit values (NEW.user_id, NEW.media_id, NEW.episodes_watched); return NEW; end; $$`)
  await sql.unsafe('create trigger qa_progress_after_write after insert or update on progress for each row execute function qa_audit_progress()')
  await sql`create table qa_watch_fault (id uuid primary key)`
  await sql.unsafe(`create function qa_fail_watch_session() returns trigger language plpgsql as $$
    begin
      if exists (select 1 from qa_watch_fault where id = NEW.id) then
        raise exception 'QA injected failure before watch session commit' using errcode = 'P0001';
      end if;
      return NEW;
    end; $$`)
  await sql.unsafe('create trigger qa_watch_before_write before insert or update on watch_sessions for each row execute function qa_fail_watch_session()')

  await run('normal absolute PUT is bounded by canonical media count', async () => {
    const response = await call(A, 'PUT', '/me/progress', { mediaId: M1, episodes: 99 })
    assert.equal(response.status, 200)
    assert.deepEqual(await progressFor(userA), [{ mediaId: M1, episodes: 12 }, { mediaId: M2, episodes: 3 }])
    return { response: response.body, canonicalEpisodes: 12, note: 'Legacy route returns ok only; client cannot infer the clamp from its receipt.' }
  })

  await run('same absolute progress PUT replayed twice has one final state', async () => {
    for (let i = 0; i < 3; i++) assert.equal((await call(A, 'PUT', '/me/progress', { mediaId: M1, episodes: 5 })).status, 200)
    assert.deepEqual(await progressFor(userA), [{ mediaId: M1, episodes: 5 }, { mediaId: M2, episodes: 3 }])
    return { mediaId: M1, episodes: 5, requests: 3, persistedRowsForMedia: 1 }
  })

  await run('lost single-part receipt after commit followed by two retries', async () => {
    dropNextResponse = true
    await assert.rejects(call(A, 'PUT', '/me/progress', { mediaId: M1, episodes: 6 }), /fetch failed/)
    assert.deepEqual(await progressFor(userA), [{ mediaId: M1, episodes: 6 }, { mediaId: M2, episodes: 3 }])
    for (let i = 0; i < 2; i++) assert.equal((await call(A, 'PUT', '/me/progress', { mediaId: M1, episodes: 6 })).status, 200)
    assert.deepEqual(await progressFor(userA), [{ mediaId: M1, episodes: 6 }, { mediaId: M2, episodes: 3 }])
    return { lostReceipt: true, upstreamStatus: faults.at(-1)!.upstreamStatus, canonicalEpisodesAfterLoss: 6, retries: 2 }
  })

  await run('single-part failure before commit changes nothing and retry succeeds', async () => {
    await sql`insert into qa_progress_fault values (${M1})`
    assert.equal((await call(A, 'PUT', '/me/progress', { mediaId: M1, episodes: 7 })).status, 500)
    assert.deepEqual(await progressFor(userA), [{ mediaId: M1, episodes: 2 }, { mediaId: M2, episodes: 3 }])
    await sql`delete from qa_progress_fault`
    assert.equal((await call(A, 'PUT', '/me/progress', { mediaId: M1, episodes: 7 })).status, 200)
    assert.deepEqual(await progressFor(userA), [{ mediaId: M1, episodes: 7 }, { mediaId: M2, episodes: 3 }])
    return { failureStatus: 500, beforeCommitEpisodes: 2, retryEpisodes: 7 }
  })

  const command = { parts: [{ mediaId: M1, episodes: 8 }, { mediaId: M2, episodes: 9 }], status: 'completed' }
  const compoundPath = `/me/franchises/${FRANCHISE}/progress`
  await run('compound second-part failure rolls back progress and subscription then retries', async () => {
    await sql`insert into qa_progress_fault values (${M2})`
    assert.equal((await call(A, 'PUT', compoundPath, command)).status, 500)
    assert.deepEqual(await progressFor(userA), [{ mediaId: M1, episodes: 2 }, { mediaId: M2, episodes: 3 }])
    assert.equal(await statusFor(userA), 'watching')
    await sql`delete from qa_progress_fault`
    const response = await call(A, 'PUT', compoundPath, command)
    assert.equal(response.status, 200)
    assert.deepEqual(await progressFor(userA), [{ mediaId: M1, episodes: 8 }, { mediaId: M2, episodes: 9 }])
    assert.equal(await statusFor(userA), 'completed')
    return { rollbackVerified: true, retryResponse: response.body }
  })

  await run('lost compound receipt after commit followed by two retries', async () => {
    dropNextResponse = true
    await assert.rejects(call(A, 'PUT', compoundPath, command), /fetch failed/)
    assert.deepEqual(await progressFor(userA), [{ mediaId: M1, episodes: 8 }, { mediaId: M2, episodes: 9 }])
    assert.equal(await statusFor(userA), 'completed')
    for (let i = 0; i < 2; i++) assert.equal((await call(A, 'PUT', compoundPath, command)).status, 200)
    assert.deepEqual(await progressFor(userA), [{ mediaId: M1, episodes: 8 }, { mediaId: M2, episodes: 9 }])
    const [counts] = await sql`select (select count(*)::int from progress) as progress,
      (select count(*)::int from subscriptions) as subscriptions`
    assert.deepEqual(counts, { progress: 2, subscriptions: 1 })
    return { lostReceipt: true, upstreamStatus: faults.at(-1)!.upstreamStatus, counts }
  })

  await run('invalid compound part cannot partially commit valid part or status', async () => {
    const response = await call(A, 'PUT', compoundPath, { parts: [{ mediaId: M1, episodes: 8 }, { mediaId: 310000099, episodes: 9 }], status: 'completed' })
    assert.equal(response.status, 400)
    assert.deepEqual(await progressFor(userA), [{ mediaId: M1, episodes: 2 }, { mediaId: M2, episodes: 3 }])
    assert.equal(await statusFor(userA), 'watching')
    return { response: response.body, unchanged: true }
  })

  await run('two authenticated accounts write independent progress and status', async () => {
    assert.equal((await call(B, 'PUT', compoundPath, { parts: [{ mediaId: M1, episodes: 10 }], status: 'paused' })).status, 200)
    assert.deepEqual(await progressFor(userA), [{ mediaId: M1, episodes: 2 }, { mediaId: M2, episodes: 3 }])
    assert.deepEqual(await progressFor(userB), [{ mediaId: M1, episodes: 10 }])
    assert.equal(await statusFor(userA), 'watching')
    assert.equal(await statusFor(userB), 'paused')
    assert.equal((await call(B, 'PUT', '/me/progress', { userId: userA, mediaId: M1, episodes: 12 })).status, 400)
    return { accountA: await progressFor(userA), accountB: await progressFor(userB), foreignUserFieldRejected: true }
  })

  const sessionBody = { franchiseId: FRANCHISE, ordinal: 2, startedAt: 1790000000000, episodes: 22,
    restoreProgress: { [M1]: 12, [M2]: 10 }, restoreStatus: 'completed' }
  const sessionPath = `/me/watch-sessions/${SESSION}`
  await run('lost watch-session receipt and replay preserve one client-generated id', async () => {
    dropNextResponse = true
    await assert.rejects(call(A, 'PUT', sessionPath, sessionBody), /fetch failed/)
    assert.equal(faults.at(-1)!.upstreamStatus, 204)
    for (let i = 0; i < 2; i++) assert.equal((await call(A, 'PUT', sessionPath, sessionBody)).status, 204)
    const rows = await sql`select id, user_id as "userId", episodes from watch_sessions`
    assert.equal(rows.length, 1)
    assert.equal(rows[0]!.id, SESSION)
    assert.equal(rows[0]!.userId, userA)
    assert.equal(rows[0]!.episodes, 22)
    return { requests: 3, persistedRows: rows.length, sessionId: SESSION }
  })

  await run('another account cannot read replace or delete a watch-session id', async () => {
    assert.equal((await call(A, 'PUT', sessionPath, sessionBody)).status, 204)
    assert.equal((await call(B, 'PUT', sessionPath, { ...sessionBody, episodes: 1 })).status, 404)
    assert.equal((await call(B, 'DELETE', sessionPath)).status, 204)
    assert.deepEqual((await call(B, 'GET', '/me/watch-sessions')).body, { sessions: [] })
    const [row] = await sql`select user_id as "userId", episodes, deleted_at as "deletedAt" from watch_sessions where id = ${SESSION}`
    assert.deepEqual(row, { userId: userA, episodes: 22, deletedAt: null })
    return { foreignWriteStatus: 404, foreignDeleteNoop: true, foreignReadEmpty: true }
  })

  await run('lost deletion receipt leaves a tombstone that rejects delayed session replay', async () => {
    assert.equal((await call(A, 'PUT', sessionPath, sessionBody)).status, 204)
    dropNextResponse = true
    await assert.rejects(call(A, 'DELETE', sessionPath), /fetch failed/)
    assert.equal(faults.at(-1)!.upstreamStatus, 204)
    assert.equal((await call(A, 'DELETE', sessionPath)).status, 204)
    assert.equal((await call(A, 'PUT', sessionPath, sessionBody)).status, 410)
    assert.deepEqual((await call(A, 'GET', '/me/watch-sessions')).body, { sessions: [] })
    const [row] = await sql`select deleted_at, restore_progress from watch_sessions where id = ${SESSION}`
    assert.ok(row!.deleted_at)
    assert.equal(row!.restore_progress, null)
    return { deletedSessionReplay: 410, liveSessions: 0, tombstonePreserved: true }
  })

  // The original three failures remain preserved in v1 evidence. Stamped v2 retries must
  // preserve newer intents while fresh stamps still allow deliberate Undo/reset decreases.
  await run('stale single-part retry must not overwrite a newer acknowledged intent', async () => {
    const old = stamp(1), newer = stamp(2)
    dropNextResponse = true
    await assert.rejects(call(A, 'PUT', '/me/progress', { mediaId: M1, episodes: 6 }, old), /fetch failed/)
    assert.equal((await call(A, 'PUT', '/me/progress', { mediaId: M1, episodes: 7 }, newer)).status, 200)
    assert.equal((await call(A, 'PUT', '/me/progress', { mediaId: M1, episodes: 6 }, old)).status, 200)
    const actual = await progressFor(userA)
    assert.equal(actual.find((row) => row.mediaId === M1)!.episodes, 7,
      `new acknowledged intent 7 was overwritten by replay 6; actual=${JSON.stringify(actual)}`)
    return { canonicalEpisodes: 7 }
  })

  await run('stale compound retry must not overwrite newer progress and status', async () => {
    const old = stamp(1), newer = stamp(2)
    dropNextResponse = true
    await assert.rejects(call(A, 'PUT', compoundPath, command, old), /fetch failed/)
    assert.equal((await call(A, 'PUT', compoundPath, { mode: 'reset', status: 'planned' }, newer)).status, 200)
    assert.equal((await call(A, 'PUT', compoundPath, command, old)).status, 200)
    const actual = await progressFor(userA)
    assert.deepEqual(actual, [{ mediaId: M1, episodes: 0 }, { mediaId: M2, episodes: 0 }],
      `new acknowledged reset was overwritten by replay; actual=${JSON.stringify(actual)}, status=${await statusFor(userA)}`)
    assert.equal(await statusFor(userA), 'planned')
    return { progress: actual, status: 'planned' }
  })

  await run('stale watch-session retry must not overwrite a newer completed session', async () => {
    const old = stamp(1), newer = stamp(2)
    dropNextResponse = true
    await assert.rejects(call(A, 'PUT', sessionPath, sessionBody, old), /fetch failed/)
    const completedAt = 1790100000000
    assert.equal((await call(A, 'PUT', sessionPath, { ...sessionBody, completedAt }, newer)).status, 204)
    assert.equal((await call(A, 'PUT', sessionPath, sessionBody, old)).status, 204)
    const [row] = await sql`select completed_at from watch_sessions where id = ${SESSION}`
    assert.equal(Number(row!.completed_at), completedAt, `new acknowledged completion was overwritten by replay; actual=${row!.completed_at}`)
    return { completedAt }
  })

  await run('stamped failed transaction rolls back receipt and cursor then same intent retries', async () => {
    const original = stamp(1)
    await sql`insert into qa_progress_fault values (${M2})`
    assert.equal((await call(A, 'PUT', compoundPath, command, original)).status, 500)
    const [before] = await sql`select (select count(*)::int from client_mutation_operations) as operations,
      (select count(*)::int from client_mutation_resources) as cursors`
    assert.deepEqual(before, { operations: 0, cursors: 0 })
    await sql`delete from qa_progress_fault`
    const retry = await call(A, 'PUT', compoundPath, command, original)
    assert.equal(retry.body.applied, true)
    assert.deepEqual(await progressFor(userA), [{ mediaId: M1, episodes: 8 }, { mediaId: M2, episodes: 9 }])
    return { rollback: before, retry: retry.body }
  })

  await run('never committed older part intent cannot overwrite newer commit', async () => {
    const old = stamp(1)
    await sql`insert into qa_progress_fault values (${M1})`
    assert.equal((await call(A, 'PUT', '/me/progress', { mediaId: M1, episodes: 6 }, old)).status, 500)
    await sql`delete from qa_progress_fault`
    assert.equal((await call(A, 'PUT', '/me/progress', { mediaId: M1, episodes: 7 }, stamp(2))).body.applied, true)
    assert.equal((await call(A, 'PUT', '/me/progress', { mediaId: M1, episodes: 6 }, old)).body.applied, false)
    assert.equal((await progressFor(userA))[0]!.episodes, 7)
  })

  await run('replayed compound returns current canonical state and preserves new reset', async () => {
    const old = stamp(1)
    assert.equal((await call(A, 'PUT', compoundPath, command, old)).body.applied, true)
    const reset = await call(A, 'PUT', compoundPath, { mode: 'reset', status: 'planned' }, stamp(2))
    const replay = await call(A, 'PUT', compoundPath, command, old)
    assert.deepEqual(replay.body, { ...reset.body, applied: false })
    return replay.body
  })

  await run('older compound supersedes atomically after one newer part, but independent older part applies', async () => {
    assert.equal((await call(A, 'PUT', '/me/progress', { mediaId: M1, episodes: 7 }, stamp(3))).body.applied, true)
    const compound = await call(A, 'PUT', compoundPath, command, stamp(2))
    assert.equal(compound.body.applied, false)
    assert.deepEqual(await progressFor(userA), [{ mediaId: M1, episodes: 7 }, { mediaId: M2, episodes: 3 }])
    assert.equal(await statusFor(userA), 'watching')
    assert.equal((await call(A, 'PUT', '/me/progress', { mediaId: M2, episodes: 5 }, stamp(1))).body.applied, true)
    assert.deepEqual(await progressFor(userA), [{ mediaId: M1, episodes: 7 }, { mediaId: M2, episodes: 5 }])
  })

  await run('concurrent replay applies exactly once and intentional newer decrease still applies', async () => {
    const intent = stamp(1)
    const responses = await Promise.all(Array.from({ length: 6 }, () => call(A, 'PUT', '/me/progress', { mediaId: M1, episodes: 8 }, intent)))
    assert.equal(responses.filter((r) => r.body.applied === true).length, 1)
    assert.equal(responses.filter((r) => r.body.applied === false).length, 5)
    const [count] = await sql`select count(*)::int as count from client_mutation_operations`
    assert.equal(count!.count, 1)
    const [effects] = await sql`select count(*)::int as count from qa_progress_audit`
    assert.equal(effects!.count, 1, 'Independent SQL trigger audit must observe exactly one physical write')
    assert.equal((await call(A, 'PUT', '/me/progress', { mediaId: M1, episodes: 1 }, stamp(2))).body.applied, true)
    assert.equal((await progressFor(userA))[0]!.episodes, 1)
    return { appliedOnce: true, replayCount: 5, intentionalDecrease: 1 }
  })

  await run('operation payload or writer changes conflict and sequence reuse conflicts', async () => {
    const original = stamp(1)
    assert.equal((await call(A, 'PUT', '/me/progress', { mediaId: M1, episodes: 5 }, original)).status, 200)
    for (const headers of [original, { ...original, 'x-previously-writer-id': randomUUID() }]) {
      const conflict = await call(A, 'PUT', '/me/progress', { mediaId: M1, episodes: 6 }, headers)
      assert.equal(conflict.status, 409)
      assert.equal(conflict.body.error, 'operation_conflict')
    }
    const reused = await call(A, 'PUT', '/me/progress', { mediaId: M2, episodes: 5 }, stamp(1))
    assert.equal(reused.status, 409)
    assert.equal(reused.body.error, 'operation_sequence_conflict')
    assert.deepEqual(await progressFor(userA), [{ mediaId: M1, episodes: 5 }, { mediaId: M2, episodes: 3 }])
  })

  await run('partial malformed and unsafe stamps reject without effects', async () => {
    const valid = stamp(1)
    for (const headers of [{ 'x-previously-operation-id': randomUUID() },
      { ...valid, 'x-previously-writer-id': 'bad' }, { ...valid, 'x-previously-writer-seq': '9007199254740992' },
      { ...valid, 'x-previously-writer-seq': '0' }, { ...valid, 'x-previously-writer-seq': '1.5' }]) {
      assert.equal((await call(A, 'PUT', '/me/progress', { mediaId: M1, episodes: 6 }, headers)).status, 400)
    }
    assert.deepEqual(await progressFor(userA), [{ mediaId: M1, episodes: 2 }, { mediaId: M2, episodes: 3 }])
  })

  const membershipPath = `/me/subscriptions/${FRANCHISE}`
  await run('unsubscribe blocks old subscribe status and progress even after explicit fresh rejoin', async () => {
    assert.equal((await call(A, 'DELETE', membershipPath, undefined, stamp(3))).body.applied, true)
    assert.equal((await call(A, 'POST', '/me/subscriptions', { franchiseId: FRANCHISE, status: 'completed' }, stamp(1))).body.applied, false)
    assert.equal((await call(A, 'PATCH', membershipPath, { status: 'paused' }, stamp(2))).body.applied, false)
    assert.equal(await statusFor(userA), null)
    assert.equal((await call(A, 'POST', '/me/subscriptions', { franchiseId: FRANCHISE, status: 'watching' }, stamp(5))).body.applied, true)
    assert.equal((await call(A, 'PUT', '/me/progress', { mediaId: M1, episodes: 7 }, stamp(4))).body.applied, true)
    assert.equal((await call(A, 'PUT', '/me/progress', { mediaId: M2, episodes: 9 }, stamp(2))).status, 409) // sequence already consumed by old status
    assert.equal((await call(A, 'PUT', '/me/progress', { mediaId: M2, episodes: 9 }, stamp(1, randomUUID()))).body.applied, true) // distinct writer arrival ordering
    return { persistentUnsubscribeBarrier: true, independentWriterArrivalOrdering: true }
  })

  await run('never committed old progress remains blocked after newer unsubscribe and re-subscribe', async () => {
    const old = stamp(1)
    await sql`insert into qa_progress_fault values (${M2})`
    assert.equal((await call(A, 'PUT', '/me/progress', { mediaId: M2, episodes: 8 }, old)).status, 500)
    await sql`delete from qa_progress_fault`
    assert.equal((await call(A, 'DELETE', membershipPath, undefined, stamp(2))).body.applied, true)
    assert.equal((await call(A, 'POST', '/me/subscriptions', { franchiseId: FRANCHISE, status: 'planned' }, stamp(3))).body.applied, true)
    assert.equal((await call(A, 'PUT', '/me/progress', { mediaId: M2, episodes: 8 }, old)).body.applied, false)
    assert.deepEqual(await progressFor(userA), [{ mediaId: M1, episodes: 2 }, { mediaId: M2, episodes: 3 }])
    assert.equal(await statusFor(userA), 'planned')
  })

  await run('delete never-created session consumes id before delayed PUT, across writer ids', async () => {
    assert.equal((await call(A, 'DELETE', sessionPath, undefined, stamp(2))).applied, 'true')
    for (const writer of [WRITER, randomUUID()]) {
      assert.equal((await call(A, 'PUT', sessionPath, sessionBody, stamp(1, writer))).status, 410)
    }
    assert.equal((await call(A, 'GET', '/me/watch-sessions')).body.sessions.length, 0)
    const [rows] = await sql`select count(*)::int as count from watch_sessions`
    assert.equal(rows!.count, 0)
  })

  await run('operation identities are scoped to account and session ownership cannot be bypassed', async () => {
    const same = stamp(1)
    assert.equal((await call(A, 'PUT', sessionPath, sessionBody, same)).status, 204)
    assert.equal((await call(B, 'PUT', '/me/progress', { mediaId: M1, episodes: 4 }, same)).body.applied, true)
    assert.equal((await call(B, 'PUT', sessionPath, { ...sessionBody, episodes: 1 }, stamp(2))).status, 404)
    assert.equal((await call(B, 'DELETE', sessionPath, undefined, stamp(3))).applied, 'false')
    const [session] = await sql`select user_id, episodes, deleted_at from watch_sessions where id = ${SESSION}`
    assert.deepEqual(session, { user_id: userA, episodes: 22, deleted_at: null })
  })

  await run('never committed old compound cannot overwrite new reset or status', async () => {
    const old = stamp(1)
    await sql`insert into qa_progress_fault values (${M2})`
    assert.equal((await call(A, 'PUT', compoundPath, command, old)).status, 500)
    await sql`delete from qa_progress_fault`
    const reset = await call(A, 'PUT', compoundPath, { mode: 'reset', status: 'planned' }, stamp(2))
    const retry = await call(A, 'PUT', compoundPath, command, old)
    assert.deepEqual(retry.body, { ...reset.body, applied: false })
  })

  await run('lost compound receipt does not suppress its separately ordered Undo unsubscribe', async () => {
    const original = stamp(1), followup = stamp(2)
    dropNextResponse = true
    await assert.rejects(call(A, 'PUT', compoundPath, { mode: 'reset', status: 'planned' }, original), /fetch failed/)
    assert.equal((await call(A, 'PUT', compoundPath, { mode: 'reset', status: 'planned' }, original)).body.applied, false)
    assert.equal((await call(A, 'DELETE', membershipPath, undefined, followup)).body.applied, true)
    assert.equal(await statusFor(userA), null)
    assert.equal((await call(A, 'DELETE', membershipPath, undefined, followup)).body.applied, false)
  })


  await run('never committed failed watch-session intent cannot replace newer completion', async () => {
    const old = stamp(1), completedAt = 1790100000000
    await sql`insert into qa_watch_fault values (${SESSION})`
    assert.equal((await call(A, 'PUT', sessionPath, sessionBody, old)).status, 500)
    const [before] = await sql`select (select count(*)::int from watch_sessions) as sessions,
      (select count(*)::int from client_mutation_operations) as operations,
      (select count(*)::int from client_mutation_resources) as cursors`
    assert.deepEqual(before, { sessions: 0, operations: 0, cursors: 0 })
    await sql`delete from qa_watch_fault`
    assert.equal((await call(A, 'PUT', sessionPath, { ...sessionBody, completedAt }, stamp(2))).applied, 'true')
    assert.equal((await call(A, 'PUT', sessionPath, sessionBody, old)).applied, 'false')
    const [saved] = await sql`select completed_at from watch_sessions where id = ${SESSION}`
    assert.equal(Number(saved!.completed_at), completedAt)
    return { rollback: before, completedAt, suppressedUncommittedOldIntent: true }
  })

  await run('matching committed session replay after later deletion still returns final410', async () => {
    const original = stamp(1)
    assert.equal((await call(A, 'PUT', sessionPath, sessionBody, original)).applied, 'true')
    assert.equal((await call(A, 'DELETE', sessionPath, undefined, stamp(2))).applied, 'true')
    assert.equal((await call(A, 'PUT', sessionPath, sessionBody, original)).status, 410)
    const [stored] = await sql`select deleted_at, restore_progress from watch_sessions where id = ${SESSION}`
    assert.ok(stored!.deleted_at)
    assert.equal(stored!.restore_progress, null)
  })


  await run('not-found stamped request records no accepted receipt or ordering cursor', async () => {
    assert.equal((await call(A, 'PUT', '/me/progress', { mediaId: 310000099, episodes: 5 }, stamp(1))).status, 404)
    assert.equal((await call(A, 'PUT', sessionPath, { ...sessionBody, franchiseId: randomUUID() }, stamp(2))).status, 404)
    const [stored] = await sql`select (select count(*)::int from client_mutation_operations) as receipts,
      (select count(*)::int from client_mutation_resources) as cursors`
    assert.deepEqual(stored, { receipts: 0, cursors: 0 })
  })

  await run('mutation transaction rechecks durable erasure after earlier authentication', async () => {
    const { setProgress } = await importRuntime<typeof import('../src/services/library.js')>('services/library')
    const { identityHash } = await importRuntime<typeof import('../src/services/deletionLedger.js')>('services/deletionLedger')
    const { ClientMutationError } = await importRuntime<typeof import('../src/services/clientMutations.js')>('services/clientMutations')
    await sql`insert into account_deletions (identity_hash, clerk_id) values (${identityHash(A)}, ${A})`
    await sql`delete from users where id = ${userA}`
    await assert.rejects(setProgress(userA, M1, 9, { user: { id: userA, clerkId: A },
      stamp: { operationId: randomUUID(), writerId: WRITER, sequence: 1 } }),
      (error: unknown) => error instanceof ClientMutationError && error.statusCode === 401)
    const [remaining] = await sql`select (select count(*)::int from progress where user_id = ${userA}) as progress,
      (select count(*)::int from client_mutation_operations where user_id = ${userA}) as receipts,
      (select count(*)::int from client_mutation_resources where user_id = ${userA}) as cursors`
    assert.deepEqual(remaining, { progress: 0, receipts: 0, cursors: 0 })
    return { simulatedPreviouslyAuthenticatedUser: true, durableDeletionRecheck: 401, remaining }
  })
} finally {
  proxy.closeAllConnections()
  await new Promise<void>((resolve) => proxy.close(() => resolve()))
  await app.close()
  await sql.end({ timeout: 5 })
  const failed = cases.filter((test) => test.status === 'failed').length
  const result = {
    runAt: new Date().toISOString(), fixtureVersion: 'progress-faults-v2-ordered-intents',
    boundary: 'Real production HTTP routes/dev issuer/auth/services + real PostgreSQL migrations; synthetic accounts; loopback-only proxy; fresh scratch database; no provider calls or native-client execution.',
    database: target.pathname.slice(1), cases, faults, outbound,
    summary: { passed: cases.length - failed, failed, skipped: 0, total: cases.length },
  }
  await writeFile(process.env.PREVIOUSLY_QA_RESULTS!, JSON.stringify(result, null, 2) + '\n')
  console.log('QA_RESULTS', JSON.stringify(result.summary))
  if (failed > 0 || outbound.blockedFetches || outbound.blockedSockets) process.exitCode = 1
}
