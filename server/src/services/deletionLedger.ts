import { createHash } from 'node:crypto'
import { and, eq, isNull, lte, sql } from 'drizzle-orm'
import type { FastifyBaseLogger } from 'fastify'
import { db } from '../db/index.js'
import { accountDeletions, users } from '../db/schema.js'
import { eraseClerkIdentity, type ClerkUsersApi } from './erasure.js'
import { env } from '../env.js'
import { eraseOwnedAccount } from './accountErasurePlan.js'
import { persistDeletionRecords, readDeletionLedger, recordDeletionCompleted, recordDeletionRequested } from '../../ops/ledger.mjs'
import type { AppleRevocation } from './appleDeletion.js'

type Transaction = Parameters<Parameters<typeof db.transaction>[0]>[0]
export class AccountErasedError extends Error {}
export const identityHash = (id: string): string => createHash('sha256').update(id).digest('hex')

// Every account creation and erasure takes this same transaction-scoped lock. A request that
// authenticated just before deletion cannot upsert the identity again after deletion commits.
export async function lockIdentity(tx: Transaction, id: string): Promise<void> {
  await tx.execute(sql`select pg_advisory_xact_lock(hashtextextended(${id}, 0))`)
}

export async function deletionState(id: string, connection: Pick<typeof db, 'select'> = db) {
  const [row] = await connection.select().from(accountDeletions)
    .where(eq(accountDeletions.identityHash, identityHash(id))).limit(1)
  return row
}

export async function enqueueDeletion(tx: Transaction, id: string, appleRevocation: AppleRevocation = 'manual_required'): Promise<void> {
  // A failed commit is conservatively replayed by the worker. Once the user has requested
  // deletion, restoring an older DB must never bring their account data back.
  if (independentLedgerEnabled()) await recordDeletionRequested(id, new Date(), { appleRevocation })
  await tx.insert(accountDeletions).values({ identityHash: identityHash(id), clerkId: id, appleRevocation })
    .onConflictDoNothing()
}

const independentLedgerEnabled = () => env.APP_ENV === 'production' || Boolean(process.env.PREVIOUSLY_OPS_ROOT)
let reconciledDigest: string | undefined

/** Required before listening in production, and before cleanup after an interrupted transaction. */
export async function reconcileIndependentDeletions(): Promise<void> {
  if (!independentLedgerEnabled()) return
  const ledger = await readDeletionLedger()
  const digest = createHash('sha256').update(JSON.stringify(ledger.payload.records)).digest('hex')
  if (digest === reconciledDigest) return
  for (const row of ledger.payload.records) {
    await db.transaction(async (tx) => {
      const [restored] = await tx.select({ id: users.id, clerkId: users.clerkId }).from(users)
        .where(sql`encode(sha256(convert_to(${users.clerkId}, 'UTF8')), 'hex') = ${row.identityHash}`).limit(1)
      const id = row.clerkId ?? restored?.clerkId
      if (id) await lockIdentity(tx, id)
      await tx.insert(accountDeletions).values({ identityHash: row.identityHash, clerkId: row.clerkId,
        requestedAt: new Date(row.requestedAt), completedAt: row.completedAt ? new Date(row.completedAt) : null,
        attempts: row.attempts, nextAttemptAt: new Date(row.nextAttemptAt), appleRevocation: row.appleRevocation ?? 'manual_required' }).onConflictDoUpdate({
          target: accountDeletions.identityHash, set: {
            completedAt: sql`coalesce(${accountDeletions.completedAt}, excluded.completed_at)`,
            clerkId: sql`case when coalesce(${accountDeletions.completedAt}, excluded.completed_at) is not null then null else coalesce(excluded.clerk_id, ${accountDeletions.clerkId}) end`,
            appleRevocation: sql`case when ${accountDeletions.appleRevocation} = 'revoked' or excluded.apple_revocation = 'revoked' then 'revoked'
              when ${accountDeletions.appleRevocation} = 'not_applicable' or excluded.apple_revocation = 'not_applicable' then 'not_applicable' else 'manual_required' end`,
          },
        })
      // Look up again under the identity lock; a just-authenticated request may have created a row.
      if (id) {
        const [account] = await tx.select({ id: users.id }).from(users).where(eq(users.clerkId, id)).limit(1)
        if (account) await eraseOwnedAccount(tx, account.id)
      }
    })
  }
  reconciledDigest = digest
}

export async function snapshotIndependentDeletions(): Promise<void> {
  if (independentLedgerEnabled()) await persistDeletionRecords(await db.select().from(accountDeletions))
}

export function deletionResponse(row: { completedAt: Date | null; appleRevocation?: AppleRevocation }) {
  const appleRevocation = row.appleRevocation ?? 'manual_required'
  return row.completedAt ? { deleted: true, status: 'complete' as const, appleRevocation }
    : { deleted: false, status: 'pending' as const, appleRevocation }
}

/** Persist only the outcome, before SQL, so restored data cannot turn success into guesswork. */
export async function recordAppleRevocation(id: string, appleRevocation: AppleRevocation): Promise<void> {
  const row = await deletionState(id)
  if (!row) return
  if (independentLedgerEnabled()) await persistDeletionRecords([{ ...row, appleRevocation }])
  await db.update(accountDeletions).set({ appleRevocation })
    .where(and(eq(accountDeletions.identityHash, identityHash(id)), sql`${accountDeletions.appleRevocation} <> 'revoked'`))
}

// Retry is safe if the provider committed but lost its response: a subsequent 404 is completion.
// Never downgrade a completed row, including when simultaneous attempts finish out of order.
export async function finishDeletion(id: string, log?: FastifyBaseLogger, options: { users?: ClerkUsersApi | null } = {}) {
  const row = await deletionState(id)
  if (!row || row.completedAt) return row
  const result = await eraseClerkIdentity(id, { suspended: false, ...options })
  const complete = result.outcome === 'deleted'
  await db.update(accountDeletions).set({
    attempts: sql`${accountDeletions.attempts} + 1`,
    nextAttemptAt: new Date(Date.now() + Math.min(3600, 30 * 2 ** Math.min(row.attempts, 7)) * 1000),
    ...(complete ? { completedAt: new Date(), clerkId: null } : {}),
  }).where(and(eq(accountDeletions.identityHash, identityHash(id)), isNull(accountDeletions.completedAt)))
  if (complete && independentLedgerEnabled()) {
    const final = await deletionState(id)
    await recordDeletionCompleted(id, new Date(), { appleRevocation: final?.appleRevocation ?? 'manual_required' })
  }
  log?.[complete ? 'info' : 'warn']({ event: complete ? 'account.deletion_complete' : 'account.deletion_pending',
    reason: result.outcome, attempts: row.attempts + 1 })
  return deletionState(id)
}

export function startDeletionWorker(log: FastifyBaseLogger): () => Promise<void> {
  let stopping = false
  let running: Promise<void> | undefined
  const run = async () => {
    if (running || stopping) return
    running = perform()
    await running
    running = undefined
  }
  const perform = async () => {
    try {
      await reconcileIndependentDeletions()
      const rows = await db.select().from(accountDeletions)
        .where(and(isNull(accountDeletions.completedAt), lte(accountDeletions.nextAttemptAt, new Date())))
        .limit(10)
      for (const row of rows) {
        if (stopping) break
        if (row.clerkId) await finishDeletion(row.clerkId, log)
      }
      await snapshotIndependentDeletions()
    } catch {
      log.error({ event: 'account.deletion_worker_failed' })
    }
  }
  const timer = setInterval(() => { void run() }, 30_000)
  timer.unref()
  void run()
  return async () => { stopping = true; clearInterval(timer); await running }
}
