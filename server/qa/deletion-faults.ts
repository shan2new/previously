// Opt-in real-route deletion regressions. The runner owns a fresh disposable PostgreSQL DB.
// No provider credentials, production hooks, public listeners or external calls are used.
import assert from 'node:assert/strict'
import { writeFile } from 'node:fs/promises'
import { createServer, request as httpRequest, type IncomingMessage, type ServerResponse } from 'node:http'
import type { AddressInfo } from 'node:net'
import { eq } from 'drizzle-orm'

const database = new URL(process.env.DATABASE_URL ?? '')
assert.equal(database.hostname, '127.0.0.1')
assert.match(database.pathname, /^\/previously_qa_deletion_[a-f0-9]{32}$/)
assert.equal(process.env.DOTENV_CONFIG_PATH, '/dev/null')
assert.equal(process.env.APP_ENV, 'test')
assert.equal(process.env.DEV_AUTH_BYPASS, '1')
for (const key of ['CLERK_SECRET_KEY', 'CLERK_JWT_KEY', 'OPENROUTER_API_KEY', 'CEREBRAS_API_KEY', 'TMDB_ACCESS_TOKEN']) {
  assert.equal(process.env[key], '', `${key} must be explicitly empty`)
}
assert.ok(process.env.PREVIOUSLY_QA_RESULTS)

const { buildServer } = await import('../src/server.js')
const { db, sql } = await import('../src/db/index.js')
const { users } = await import('../src/db/schema.js')
const { AccountErasedError, deletionState, enqueueDeletion, identityHash, lockIdentity } = await import('../src/services/deletionLedger.js')
const { upsertUser } = await import('../src/services/users.js')
const { resetErasures } = await import('../src/services/erasure.js')
let app = await buildServer()
let upstreamPort = 0
let dropNextDeleteResponse = false
const faults: { path?: string; upstreamStatus?: number; mode: string }[] = []
const cases: { name: string; status: 'passed' | 'failed'; durationMs: number; evidence?: unknown; error?: string }[] = []

const proxy = createServer((req: IncomingMessage, res: ServerResponse) => {
  const drop = dropNextDeleteResponse && req.method === 'DELETE' && req.url === '/me'
  if (drop) dropNextDeleteResponse = false
  const upstream = httpRequest({ hostname: '127.0.0.1', port: upstreamPort, method: req.method,
    path: req.url, headers: { ...req.headers, host: `127.0.0.1:${upstreamPort}` } }, (reply) => {
    const chunks: Buffer[] = []
    reply.on('data', (chunk: Buffer) => chunks.push(chunk))
    reply.on('end', () => {
      if (drop) {
        faults.push({ path: req.url, upstreamStatus: reply.statusCode, mode: 'drop_after_complete_upstream_response' })
        res.socket?.destroy()
      } else { res.writeHead(reply.statusCode ?? 502, reply.headers); res.end(Buffer.concat(chunks)) }
    })
  })
  upstream.on('error', () => { res.writeHead(502); res.end('{"error":"scratch upstream unavailable"}') })
  req.pipe(upstream)
})

const A = 'qa-deletion-account-a'
const B = 'qa-deletion-account-b'
const MEDIA = 320_000_001
let userA = ''
let userB = ''
let base = ''

async function call(account: string, method: string, path: string, body?: unknown) {
  const response = await fetch(`${base}${path}`, { method,
    headers: { authorization: `Bearer dev:${account}`, ...(body === undefined ? {} : { 'content-type': 'application/json' }) },
    body: body === undefined ? undefined : JSON.stringify(body), signal: AbortSignal.timeout(7000) })
  const text = await response.text()
  return { status: response.status, body: text ? JSON.parse(text) : null }
}

async function stored(account = A) {
  const rows = await sql`select id from users where clerk_id = ${account}`
  const ledger = await sql`select identity_hash, clerk_id, completed_at, attempts from account_deletions
    where identity_hash = ${identityHash(account)}`
  const progress = await sql`select episodes_watched from progress where user_id = ${account === A ? userA : userB}`
  return { users: rows.length, ledger: [...ledger], progress: [...progress] }
}

async function reset() {
  dropNextDeleteResponse = false
  resetErasures()
  await sql`delete from qa_deletion_fault`
  await sql`delete from account_deletions`
  await sql`delete from users`
  for (const account of [A, B]) assert.equal((await call(account, 'GET', '/me/profile')).status, 200)
  const rows = await sql`select id, clerk_id from users`
  userA = rows.find((row) => row.clerk_id === A)!.id
  userB = rows.find((row) => row.clerk_id === B)!.id
  await sql`insert into progress (user_id, media_id, episodes_watched) values (${userA}, ${MEDIA}, 3), (${userB}, ${MEDIA}, 8)`
}

async function run(name: string, test: () => Promise<unknown>) {
  await reset()
  const begin = performance.now()
  try {
    const evidence = await test()
    cases.push({ name, status: 'passed', durationMs: Math.round(performance.now() - begin), evidence })
  }
  catch (error) { cases.push({ name, status: 'failed', durationMs: Math.round(performance.now() - begin), error: error instanceof Error ? error.message : String(error) }) }
  console.log(`${cases.at(-1)!.status.toUpperCase()} ${name}`)
}

try {
  assert.equal((await sql`select current_database() as name`)[0]!.name, database.pathname.slice(1))
  await app.listen({ host: '127.0.0.1', port: 0 })
  upstreamPort = (app.server.address() as AddressInfo).port
  await new Promise<void>((resolve) => proxy.listen(0, '127.0.0.1', resolve))
  base = `http://127.0.0.1:${(proxy.address() as AddressInfo).port}`
  await sql`insert into media (id, title_english, format, status, episodes) values (${MEDIA}, 'QA deletion synthetic', 'TV', 'FINISHED', 12)`
  await sql`create table qa_deletion_fault (clerk_id text primary key)`
  await sql.unsafe(`create function qa_fail_user_delete() returns trigger language plpgsql as $$
    begin
      if exists (select 1 from qa_deletion_fault where clerk_id = OLD.clerk_id) then
        raise exception 'QA failure before user deletion commit' using errcode = 'P0001';
      end if;
      return OLD;
    end; $$`)
  await sql.unsafe('create trigger qa_before_user_delete before delete on users for each row execute function qa_fail_user_delete()')

  await run('missing provider credentials returns truthful 202 and removes account data', async () => {
    const response = await call(A, 'DELETE', '/me')
    assert.equal(response.status, 202)
    assert.deepEqual(response.body, { deleted: false, status: 'pending' })
    const state = await stored()
    assert.equal(state.users, 0); assert.deepEqual(state.progress, []); assert.equal(state.ledger.length, 1)
    assert.equal(state.ledger[0]!.completed_at, null)
    assert.equal((await call(A, 'GET', '/me/deletion')).status, 202)
    return { response, usersRemaining: state.users, progressRemaining: state.progress.length, ledgerRows: state.ledger.length }
  })

  await run('repeated DELETE remains pending without recreating an account or ledger', async () => {
    for (let count = 0; count < 3; count++) assert.equal((await call(A, 'DELETE', '/me')).status, 202)
    const state = await stored()
    assert.equal(state.users, 0); assert.equal(state.ledger.length, 1); assert.deepEqual(state.progress, [])
    return { repeatedRequests: 3, ledgerRows: 1, usersRemaining: 0 }
  })

  await run('lost receipt after deletion commit reconciles using status without upsert', async () => {
    dropNextDeleteResponse = true
    await assert.rejects(call(A, 'DELETE', '/me'), /fetch failed/)
    const committed = await stored()
    assert.equal(committed.users, 0); assert.equal(committed.ledger.length, 1)
    const status = await call(A, 'GET', '/me/deletion')
    assert.equal(status.status, 202); assert.deepEqual(status.body, { deleted: false, status: 'pending' })
    assert.equal((await stored()).users, 0)
    return { lostResponse: true, upstreamStatus: faults.at(-1)!.upstreamStatus, statusReceipt: status }
  })

  await run('persistent tombstone works after memory hold clear and server reconstruction', async () => {
    assert.equal((await call(A, 'DELETE', '/me')).status, 202)
    resetErasures()
    await app.close()
    app = await buildServer()
    await app.listen({ host: '127.0.0.1', port: 0 })
    upstreamPort = (app.server.address() as AddressInfo).port
    assert.equal((await call(A, 'GET', '/me/profile')).status, 401)
    assert.equal((await call(A, 'PUT', '/me/progress', { mediaId: MEDIA, episodes: 9 })).status, 401)
    assert.equal((await call(A, 'GET', '/me/deletion')).status, 202)
    assert.equal((await stored()).users, 0)
    return { processLocalHoldCleared: true, fastifyReconstructed: true, separateProcessRestartTested: false }
  })

  await run('upsert waiting on deletion identity lock cannot resurrect the account', async () => {
    let release!: () => void; let entered!: () => void
    const held = new Promise<void>((resolve) => { release = resolve })
    const locked = new Promise<void>((resolve) => { entered = resolve })
    const deleting = db.transaction(async (tx) => {
      await lockIdentity(tx, A); entered(); await held
      await enqueueDeletion(tx, A)
      await tx.delete(users).where(eq(users.clerkId, A))
    })
    await locked
    const inserting = upsertUser(A).then(() => new Error('upsert unexpectedly succeeded'), (error: unknown) => error)
    const deadline = Date.now() + 4000
    let waiters = 0
    try {
      while (!waiters && Date.now() < deadline) {
        const [row] = await sql`select count(*)::int as count from pg_stat_activity
          where datname = current_database() and wait_event_type = 'Lock' and query like '%pg_advisory_xact_lock%'`
        waiters = row!.count
        if (!waiters) await new Promise((resolve) => setTimeout(resolve, 25))
      }
      assert.ok(waiters > 0, 'did not establish an upsert waiting on the deletion lock')
    } finally {
      release()
      // Even a failed synchronization assertion must release and drain the owned transaction
      // before the next case resets its database state.
      await deleting
      await inserting
    }
    const error = await inserting
    assert.ok(error instanceof AccountErasedError)
    assert.equal((await stored()).users, 0)
    assert.ok(await deletionState(A))
    return { advisoryLockWaitersObserved: waiters, upsertRejected: true }
  })

  await run('pre-commit failure rolls back deletion ledger and all data changes', async () => {
    await sql`insert into qa_deletion_fault (clerk_id) values (${A})`
    assert.equal((await call(A, 'DELETE', '/me')).status, 500)
    const state = await stored()
    assert.equal(state.users, 1); assert.equal(state.ledger.length, 0)
    assert.equal(state.progress[0]!.episodes_watched, 3)
    assert.deepEqual((await call(A, 'GET', '/me/deletion')).body, { deleted: false, status: 'active' })
    await sql`delete from qa_deletion_fault`
    assert.equal((await call(A, 'PUT', '/me/progress', { mediaId: MEDIA, episodes: 4 })).status, 200)
    return { failureStatus: 500, userPreserved: true, ledgerRolledBack: true, trackingResumed: true }
  })

  await run('account B survives A deletion with its progress unchanged', async () => {
    const before = await stored(B)
    assert.equal((await call(A, 'DELETE', '/me')).status, 202)
    assert.deepEqual(await stored(B), before)
    assert.equal((await call(B, 'GET', '/me/profile')).status, 200)
    return { bUserPreserved: true, bEpisodes: before.progress[0]!.episodes_watched }
  })
} finally {
  proxy.closeAllConnections()
  await new Promise<void>((resolve) => proxy.close(() => resolve()))
  await app.close()
  await sql.end({ timeout: 5 })
  const failed = cases.filter((item) => item.status === 'failed').length
  const result = { runAt: new Date().toISOString(), fixtureVersion: 'deletion-faults-v1',
    boundary: 'Real production routes/auth/identity locking/deletion ledger and SQL; dev test issuer; owned fresh DB; loopback-only lost-receipt proxy; provider keys absent; no native or actual Clerk deletion proof.',
    database: database.pathname.slice(1), cases, faults, summary: { passed: cases.length - failed, failed, total: cases.length } }
  await writeFile(process.env.PREVIOUSLY_QA_RESULTS!, JSON.stringify(result, null, 2) + '\n')
  console.log('QA_RESULTS', JSON.stringify(result.summary))
  if (failed) process.exitCode = 1
}
