import type { FastifyReply, FastifyRequest } from 'fastify'
import { wasErased } from '../services/erasure.js'
import { isSuspended } from '../services/moderation.js'
import { getUserByClerkId, upsertUser, type AppUser } from '../services/users.js'
import { authConfigFromEnv } from './authConfig.js'
import { resolveIdentity } from './identity.js'
import { AccountErasedError, deletionResponse, deletionState, finishDeletion, reconcileIndependentDeletions } from '../services/deletionLedger.js'

declare module 'fastify' {
  interface FastifyRequest {
    user?: AppUser
  }
  interface FastifyInstance {
    authenticate: (req: FastifyRequest, reply: FastifyReply) => Promise<void>
  }
}

function bearer(req: FastifyRequest): string | null {
  const h = req.headers.authorization
  if (!h || !h.startsWith('Bearer ')) return null
  return h.slice('Bearer '.length).trim()
}

/**
 * The routes a suspended account may still call: erasing the account and downloading its data
 * (docs/api-contract.md, "Client failure semantics"). `url` is the ROUTE pattern
 * (`req.routeOptions.url`), never the raw request URL, so a query string cannot widen it.
 */
export function suspendedMayCall(method: string, url: string | undefined): boolean {
  return (method === 'DELETE' && url === '/me') || (method === 'GET' && url === '/me/export')
}

/**
 * Fastify preHandler that authenticates the request and attaches `req.user`.
 *
 * All issuer policy lives in `identity.ts` / `authConfig.ts` — this file is glue only, so
 * `DEV_AUTH_BYPASS` is never read at a decision site.
 *
 * A suspended identity (services/moderation.ts, keyed on the Clerk id) answers
 * `403 { error: 'account_suspended' }` everywhere but `suspendedMayCall` — the one 403 the client
 * reads as app state rather than infrastructure. The check runs BEFORE `upsertUser`, so a banned
 * identity whose account was erased does not get a fresh one back by calling the API.
 *
 * An identity whose account was just erased (`DELETE /me`, services/erasure.ts) answers
 * `401 { error: 'account deleted' }`, also before the upsert: its session JWT is still valid for a
 * while, and the app's in-flight and retried writes must not re-create the account.
 *
 * A suspended identity's READ (GET /me/export) never creates a users row either — the erasure hold
 * lasts minutes, a ban forever: it is looked up, and with no row it answers the route's own
 * `404 { error: 'account not found' }` rather than storing the email of an erased, banned person
 * again. DELETE /me still upserts: erasing a row it has just created answers `deleted`, the truth.
 */
export async function authenticate(req: FastifyRequest, reply: FastifyReply): Promise<void> {
  const token = bearer(req)
  if (!token) return reply.code(401).send({ error: 'missing bearer token' })
  const id = await resolveIdentity(token, authConfigFromEnv())
  if (!id) return reply.code(401).send({ error: 'invalid token' })
  const statusRequest = req.method === 'GET' && req.routeOptions.url === '/me/deletion'
  const deleteRequest = req.method === 'DELETE' && req.routeOptions.url === '/me'
  async function erasedResponse() {
    let row = await deletionState(id!.clerkId)
    if (row && deleteRequest) row = await finishDeletion(id!.clerkId, req.log) ?? row
    if (row && (statusRequest || deleteRequest)) {
      return reply.code(row.completedAt ? 200 : 202).send(deletionResponse(row))
    }
    return reply.code(401).send({ error: 'account deleted' })
  }
  if (statusRequest) {
    // A durable intent can outlive an erasure transaction that rolled back. Reconcile it before
    // claiming the account is active; failure remains an unknown outcome for the client's hold.
    await reconcileIndependentDeletions()
    const row = await deletionState(id.clerkId)
    return row ? reply.code(row.completedAt ? 200 : 202).send(deletionResponse(row))
      : reply.send({ deleted: false, status: 'active' })
  }
  const suspended = await isSuspended(id.clerkId)
  if (suspended && !suspendedMayCall(req.method, req.routeOptions.url)) {
    return reply.code(403).send({ error: 'account_suspended' })
  }
  if (wasErased(id.clerkId)) return erasedResponse()
  if (suspended && req.method === 'GET') {
    const existing = await getUserByClerkId(id.clerkId)
    if (!existing) return reply.code(404).send({ error: 'account not found' })
    req.user = existing
    return
  }
  try { req.user = await upsertUser(id.clerkId, id.email) }
  catch (error) {
    if (error instanceof AccountErasedError) return erasedResponse()
    throw error
  }
}
