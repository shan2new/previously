import { createHash } from 'node:crypto'
import { and, eq, inArray } from 'drizzle-orm'
import type { FastifyRequest } from 'fastify'
import { z } from 'zod'
import { db } from '../db/index.js'
import { clientMutationOperations, clientMutationResources, users } from '../db/schema.js'
import { deletionState, lockIdentity } from './deletionLedger.js'

export type MutationTransaction = Parameters<Parameters<typeof db.transaction>[0]>[0]
export type MutationConnection = Pick<typeof db, 'select' | 'insert' | 'update' | 'delete' | 'execute'>
export interface MutationStamp { operationId: string; writerId: string; sequence: number }
export interface ClientMutationContext { user: { id: string; clerkId: string }; stamp: MutationStamp | null }

export class ClientMutationError extends Error {
  constructor(public readonly statusCode: 400 | 401 | 409, message: string) { super(message) }
}

// Missing stamps preserve the old beta API. Partially supplied stamps never silently downgrade.
export function clientMutationContext(req: FastifyRequest): ClientMutationContext {
  const operation = req.headers['x-previously-operation-id']
  const writer = req.headers['x-previously-writer-id']
  const sequence = req.headers['x-previously-writer-seq']
  const supplied = [operation, writer, sequence].filter((value) => value !== undefined).length
  if (!supplied) return { user: req.user!, stamp: null }
  if (supplied !== 3 || typeof operation !== 'string' || typeof writer !== 'string' ||
      typeof sequence !== 'string' || !/^[1-9][0-9]{0,15}$/.test(sequence) ||
      !z.string().uuid().safeParse(operation).success || !z.string().uuid().safeParse(writer).success ||
      !Number.isSafeInteger(Number(sequence))) throw new ClientMutationError(400, 'invalid mutation stamp')
  return { user: req.user!, stamp: { operationId: operation.toLowerCase(), writerId: writer.toLowerCase(), sequence: Number(sequence) } }
}

function canonical(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(canonical)
  if (value && typeof value === 'object') return Object.fromEntries(Object.entries(value)
    .filter(([, item]) => item !== undefined).sort(([a], [b]) => a.localeCompare(b))
    .map(([key, item]) => [key, canonical(item)]))
  return value
}

export interface MutationScope {
  /** Advance only resources actually changed. Unsubscribe barriers survive later re-subscribe. */
  apply(resources: string[], options?: { barriers?: string[]; deleted?: string[] }): Promise<boolean>
}

/**
 * Persist an intent and its effects together. The identity lock also serializes account erasure.
 * Ordering is per account/device writer and resource; independent devices retain arrival order.
 * Receipts contain no cached state: callers read current canonical state after replay/supersession.
 */
export async function withClientMutation<T>(
  context: ClientMutationContext, kind: string, payload: unknown,
  action: (tx: MutationTransaction, scope: MutationScope) => Promise<T>,
): Promise<T> {
  return db.transaction(async (tx) => {
    await lockIdentity(tx, context.user.clerkId)
    const [present] = await tx.select({ id: users.id }).from(users).where(eq(users.id, context.user.id)).limit(1)
    if (!present || await deletionState(context.user.clerkId, tx)) throw new ClientMutationError(401, 'account deleted')
    const stamp = context.stamp
    if (!stamp) return action(tx, { apply: async () => true })
    const hash = createHash('sha256').update(JSON.stringify(canonical({ kind, payload }))).digest('hex')
    const [existing] = await tx.select().from(clientMutationOperations).where(and(
      eq(clientMutationOperations.userId, context.user.id), eq(clientMutationOperations.operationId, stamp.operationId))).limit(1)
    if (existing && (existing.requestHash !== hash || existing.writerId !== stamp.writerId || existing.sequence !== stamp.sequence)) {
      throw new ClientMutationError(409, 'operation_conflict')
    }
    if (!existing) {
      const [occupied] = await tx.select({ operationId: clientMutationOperations.operationId }).from(clientMutationOperations).where(and(
        eq(clientMutationOperations.userId, context.user.id), eq(clientMutationOperations.writerId, stamp.writerId),
        eq(clientMutationOperations.sequence, stamp.sequence))).limit(1)
      if (occupied) throw new ClientMutationError(409, 'operation_sequence_conflict')
    }
    let evaluated = false
    const result = await action(tx, {
      apply: async (resources, options = {}) => {
        evaluated = true
        if (existing) return false
        const keys = [...new Set([...resources, ...(options.barriers ?? [])])]
        const cursors = keys.length ? await tx.select().from(clientMutationResources).where(and(
          eq(clientMutationResources.userId, context.user.id), eq(clientMutationResources.writerId, stamp.writerId),
          inArray(clientMutationResources.resourceKey, keys))) : []
        if (cursors.some((row) => resources.includes(row.resourceKey) && row.sequence >= stamp.sequence ||
            options.barriers?.includes(row.resourceKey) && row.deletedSequence >= stamp.sequence)) return false
        for (const resourceKey of [...new Set(resources)]) {
          const deletedSequence = options.deleted?.includes(resourceKey) ? stamp.sequence
            : cursors.find((row) => row.resourceKey === resourceKey)?.deletedSequence ?? 0
          await tx.insert(clientMutationResources).values({ userId: context.user.id, writerId: stamp.writerId,
            resourceKey, sequence: stamp.sequence, deletedSequence }).onConflictDoUpdate({
            target: [clientMutationResources.userId, clientMutationResources.writerId, clientMutationResources.resourceKey],
            set: { sequence: stamp.sequence, deletedSequence },
          })
        }
        return true
      },
    })
    // Not-found/validation outcomes returned before apply are not committed intent receipts.
    if (!existing && evaluated) await tx.insert(clientMutationOperations).values({ userId: context.user.id,
      operationId: stamp.operationId, writerId: stamp.writerId, sequence: stamp.sequence, requestHash: hash, kind })
    return result
  })
}
