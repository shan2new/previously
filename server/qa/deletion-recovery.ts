// Explicit scratch-only recovery tests: production erasure/reconciliation + real PostgreSQL.
import assert from 'node:assert/strict'
import { writeFile } from 'node:fs/promises'
import { basename } from 'node:path'
import { Socket } from 'node:net'
import { randomUUID } from 'node:crypto'

const target = new URL(process.env.DATABASE_URL ?? '')
assert.equal(target.hostname, '127.0.0.1')
assert.match(target.pathname, /^\/previously_qa_recovery_[a-f0-9]{32}$/)
assert.equal(process.env.DOTENV_CONFIG_PATH, '/dev/null')
assert.equal(process.env.APP_ENV, 'test')
assert.equal(process.env.DEV_AUTH_BYPASS, '1')
assert.match(basename(process.env.PREVIOUSLY_OPS_ROOT ?? ''), /^previously_qa_recovery_ops_/)
for (const key of ['CLERK_SECRET_KEY', 'CLERK_JWT_KEY', 'OPENROUTER_API_KEY', 'CEREBRAS_API_KEY', 'TMDB_ACCESS_TOKEN']) {
  assert.equal(process.env[key], '', `${key} must be empty`)
}
assert.ok(process.env.PREVIOUSLY_QA_RESULTS)
let rejectedOutbound = 0
const originalFetch = globalThis.fetch
globalThis.fetch = async () => { rejectedOutbound++; throw new Error('Recovery QA forbids outbound fetch') }
const originalConnect = Socket.prototype.connect
Socket.prototype.connect = function (this: Socket, ...args: unknown[]) {
  const options = args[0] as { host?: string; port?: number; path?: string } | undefined
  const host = typeof args[0] === 'number' ? args[1] : options?.host
  assert.ok(!options?.path && typeof host === 'string' && ['127.0.0.1', 'localhost', '::1'].includes(host),
    'Recovery QA permits loopback sockets only')
  return Reflect.apply(originalConnect, this, args)
} as typeof Socket.prototype.connect

// Source types only; runtime effects execute the exact compiled release modules.
async function importRuntime<T>(module: string): Promise<T> {
  return import(`../dist/${module}.js`) as Promise<T>
}

const { persistDeletionRecords, readDeletionLedger, recordDeletionCompleted } = await import('../ops/ledger.mjs')
await persistDeletionRecords([])
const { db, sql } = await importRuntime<typeof import('../src/db/index.js')>('db/index')
const { buildServer } = await importRuntime<typeof import('../src/server.js')>('server')
const { eraseOwnedAccount } = await importRuntime<typeof import('../src/services/accountErasurePlan.js')>('services/accountErasurePlan')
const { AccountErasedError, deletionState, enqueueDeletion, finishDeletion, identityHash, lockIdentity,
  reconcileIndependentDeletions, snapshotIndependentDeletions, recordAppleRevocation } = await importRuntime<typeof import('../src/services/deletionLedger.js')>('services/deletionLedger')
const { upsertUser } = await importRuntime<typeof import('../src/services/users.js')>('services/users')
const app = await buildServer() // inject only: no listener or background deletion worker
const MEDIA = 330000001
const cases: { name: string; status: 'passed' | 'failed'; durationMs: number; evidence?: unknown; error?: string }[] = []

async function seed(label: string) {
  const identity = `qa-recovery-${label}-${randomUUID()}`
  const row = await upsertUser(identity)
  await sql`insert into progress (user_id, media_id, episodes_watched) values (${row.id}, ${MEDIA}, 7)`
  await sql`insert into client_mutation_operations (user_id, operation_id, writer_id, sequence, request_hash, kind)
    values (${row.id}, ${randomUUID()}, ${randomUUID()}, 1, ${'0'.repeat(64)}, 'qa')`
  await sql`insert into client_mutation_resources (user_id, writer_id, resource_key, sequence)
    values (${row.id}, ${randomUUID()}, ${`media:${MEDIA}`}, 1)`
  return { identity, id: row.id }
}
async function state(id: string, identity: string) {
  const [row] = await sql`select (select count(*)::int from users where id=${id}) as users,
    (select count(*)::int from progress where user_id=${id}) as progress,
    (select count(*)::int from client_mutation_operations where user_id=${id}) as receipts,
    (select count(*)::int from client_mutation_resources where user_id=${id}) as cursors`
  return { users: Number(row!.users), progress: Number(row!.progress), receipts: Number(row!.receipts),
    cursors: Number(row!.cursors), deletion: await deletionState(identity) }
}
async function run(name: string, action: () => Promise<unknown>) {
  const start = performance.now()
  try { cases.push({ name, status: 'passed', durationMs: 0, evidence: await action() }) }
  catch (error) { cases.push({ name, status: 'failed', durationMs: 0, error: error instanceof Error ? error.message : String(error) }) }
  cases.at(-1)!.durationMs = Math.round(performance.now() - start)
  console.log(`${cases.at(-1)!.status.toUpperCase()} ${name}`)
}
try {
  assert.equal((await sql`select current_database() as name`)[0]!.name, target.pathname.slice(1))
  await sql`insert into media (id, title_english, format, status, episodes)
    values (${MEDIA}, 'QA recovery synthetic', 'TV', 'FINISHED', 12)`
  await sql`create table qa_recovery_fault (clerk_id text primary key)`
  await sql.unsafe(`create function qa_fail_recovery_delete() returns trigger language plpgsql as $$
    begin
      if exists (select 1 from qa_recovery_fault where clerk_id=OLD.clerk_id) then
        raise exception 'QA deletion failed before commit' using errcode='P0001';
      end if;
      return OLD;
    end; $$`)
  await sql.unsafe('create trigger qa_recovery_before_delete before delete on users for each row execute function qa_fail_recovery_delete()')

  await run('failed database commit preserves requested FS intent and recovery erases account', async () => {
    const account = await seed('failed')
    await sql`insert into qa_recovery_fault values (${account.identity})`
    await assert.rejects(db.transaction(async (tx) => {
      await lockIdentity(tx, account.identity)
      await enqueueDeletion(tx, account.identity)
      await eraseOwnedAccount(tx, account.id)
    }))
    const before = await state(account.id, account.identity)
    assert.equal(before.users, 1); assert.equal(before.progress, 1); assert.equal(before.receipts, 1)
    assert.equal(before.deletion, undefined)
    const journal = await readDeletionLedger()
    assert.ok(journal.payload.records.some((row) => row.identityHash === identityHash(account.identity) && row.clerkId === account.identity))
    await sql`delete from qa_recovery_fault`
    await reconcileIndependentDeletions()
    const after = await state(account.id, account.identity)
    assert.equal(after.users, 0); assert.equal(after.progress, 0); assert.equal(after.receipts, 0); assert.equal(after.cursors, 0)
    assert.ok(after.deletion); assert.equal(after.deletion.completedAt, null)
    assert.equal(after.deletion.appleRevocation, 'manual_required')
    await assert.rejects(upsertUser(account.identity), AccountErasedError)
    const blocked = await app.inject({ method: 'GET', url: '/me/profile', headers: { authorization: `Bearer dev:${account.identity}` } })
    assert.equal(blocked.statusCode, 401)
    return { beforeCommitRollback: true, requestedMarkerSurvived: true, after: { users: 0, progress: 0, receipts: 0, cursors: 0 }, authAfterRecovery: 401 }
  })

  await run('completed hash-only journal erases a restored account and cannot downgrade', async () => {
    const account = await seed('restored')
    await recordDeletionCompleted(account.identity)
    // This live row represents the old backup restored after the independent completed marker.
    await reconcileIndependentDeletions()
    const after = await state(account.id, account.identity)
    assert.equal(after.users, 0); assert.equal(after.progress, 0); assert.equal(after.receipts, 0); assert.equal(after.cursors, 0)
    assert.ok(after.deletion?.completedAt); assert.equal(after.deletion.clerkId, null)
    await snapshotIndependentDeletions()
    const journal = await readDeletionLedger()
    const completed = journal.payload.records.find((row) => row.identityHash === identityHash(account.identity))!
    assert.ok(completed.completedAt); assert.equal(completed.clerkId, null)
    await assert.rejects(upsertUser(account.identity), AccountErasedError)
    return { restoredRowsErased: true, completedHashOnly: true, accountUpsertRejected: true }
  })

  await run('pending provider cleanup404 completes DB and FS ledgers with no external call', async () => {
    const account = await seed('provider')
    await db.transaction(async (tx) => {
      await lockIdentity(tx, account.identity); await enqueueDeletion(tx, account.identity); await eraseOwnedAccount(tx, account.id)
    })
    const skipped = await finishDeletion(account.identity, undefined, { users: null })
    assert.equal(skipped?.completedAt, null)
    let providerCalls = 0
    const completed = await finishDeletion(account.identity, undefined, { users: {
      deleteUser: async (id) => { assert.equal(id, account.identity); providerCalls++; throw { status: 404 } },
      banUser: async () => { throw new Error('Unexpected ban') },
    } })
    assert.ok(completed?.completedAt); assert.equal(completed.clerkId, null); assert.equal(providerCalls, 1)
    const journal = await readDeletionLedger()
    const stored = journal.payload.records.find((row) => row.identityHash === identityHash(account.identity))!
    assert.ok(stored.completedAt); assert.equal(stored.clerkId, null)
    assert.equal((await finishDeletion(account.identity, undefined, { users: null }))?.clerkId, null)
    return { injectedClerkUsers404: true, realFinishDeletion: true, providerCalls, completedDBAndFS: true }
  })

  await run('lost Apple receipt defaults manual and status does not claim revocation after restart recovery', async () => {
    const account = await seed('apple-crash')
    await db.transaction(async (tx) => {
      await lockIdentity(tx, account.identity); await enqueueDeletion(tx, account.identity); await eraseOwnedAccount(tx, account.id)
    })
    // A process can die during exchange/revoke. There is deliberately no reusable token journal.
    await reconcileIndependentDeletions()
    const response = await app.inject({ method: 'GET', url: '/me/deletion', headers: { authorization: `Bearer dev:${account.identity}` } })
    assert.equal(response.statusCode, 202)
    assert.deepEqual(response.json(), { deleted: false, status: 'pending', appleRevocation: 'manual_required' })
    const record = (await readDeletionLedger()).payload.records.find(row => row.identityHash === identityHash(account.identity))!
    assert.equal(record.appleRevocation, 'manual_required')
    assert.deepEqual(Object.keys(record).sort(), ['appleRevocation', 'attempts', 'clerkId', 'completedAt', 'identityHash', 'nextAttemptAt', 'requestedAt'])
    return { appDataErased: true, conservativeInterruptedOutcome: 'manual_required', reusableTokenJournal: false }
  })

  await run('proven Apple outcome survives SQL restore and late fallback without recreating an account', async () => {
    const account = await seed('apple-restore')
    await db.transaction(async (tx) => {
      await lockIdentity(tx, account.identity); await enqueueDeletion(tx, account.identity); await eraseOwnedAccount(tx, account.id)
    })
    await recordAppleRevocation(account.identity, 'revoked')
    await recordAppleRevocation(account.identity, 'manual_required')
    assert.equal((await deletionState(account.identity))?.appleRevocation, 'revoked')
    await sql`delete from account_deletions where identity_hash=${identityHash(account.identity)}`
    await sql`insert into users (id,clerk_id,email) values (${account.id},${account.identity},null)`
    await sql`insert into progress (user_id,media_id,episodes_watched) values (${account.id},${MEDIA},7)`
    // Changing journal metadata makes this a distinct restore event for this running process.
    await recordDeletionCompleted(account.identity, new Date(), { appleRevocation: 'revoked' })
    await reconcileIndependentDeletions()
    const after = await state(account.id, account.identity)
    assert.equal(after.users, 0); assert.equal(after.progress, 0)
    assert.equal(after.deletion?.appleRevocation, 'revoked')
    assert.ok(after.deletion?.completedAt)
    const status = await app.inject({ method: 'GET', url: '/me/deletion', headers: { authorization: `Bearer dev:${account.identity}` } })
    assert.deepEqual(status.json(), { deleted: true, status: 'complete', appleRevocation: 'revoked' })
    const replay = await app.inject({ method: 'DELETE', url: '/me', headers: { authorization: `Bearer dev:${account.identity}` },
      payload: { apple: { identityToken: 'synthetic-already-used-proof', authorizationCode: 'synthetic-used-code' } } })
    assert.equal(replay.statusCode, 200); assert.deepEqual(replay.json(), status.json())
    assert.equal((await state(account.id, account.identity)).users, 0)
    return { restoredRowsErased: true, sqlAndFSOutcome: 'revoked', replayWithoutExchange: true }
  })

  await run('non-Apple account outcome survives provider cleanup404 with outcome-only metadata', async () => {
    const account = await seed('not-apple')
    await db.transaction(async (tx) => {
      await lockIdentity(tx, account.identity); await enqueueDeletion(tx, account.identity, 'not_applicable'); await eraseOwnedAccount(tx, account.id)
    })
    await finishDeletion(account.identity, undefined, { users: { deleteUser: async () => { throw { status: 404 } }, banUser: async () => { throw new Error('unexpected ban') } } })
    const completed = await deletionState(account.identity)
    assert.equal(completed?.appleRevocation, 'not_applicable'); assert.ok(completed?.completedAt)
    const record = (await readDeletionLedger()).payload.records.find(row => row.identityHash === identityHash(account.identity))!
    assert.equal(record.appleRevocation, 'not_applicable'); assert.equal(record.clerkId, null)
    return { provider404Stubbed: true, rawIdentityRemoved: true, outcome: 'not_applicable' }
  })
} finally {
  await app.close()
  await sql.end({ timeout: 5 })
  globalThis.fetch = originalFetch
  Socket.prototype.connect = originalConnect
  const failed = cases.filter((test) => test.status === 'failed').length
  const result = { runAt: new Date().toISOString(), fixtureVersion: 'deletion-recovery-v2', database: target.pathname.slice(1),
    boundary: 'Real production erasure/identity locks/reconciliation/finishDeletion + actual migrated PostgreSQL and owned FS ledger; route auth via Fastify injection;404 injected at existing ClerkUsersApi seam; no actual Clerk SDK/network or production data.',
    rejectedOutbound, cases, summary: { passed: cases.length - failed, failed, total: cases.length } }
  await writeFile(process.env.PREVIOUSLY_QA_RESULTS!, JSON.stringify(result, null, 2) + '\n')
  if (failed || rejectedOutbound) process.exitCode = 1
}
