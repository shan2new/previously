import Fastify, { type FastifyInstance } from 'fastify'
import { beforeEach, describe, expect, it, vi } from 'vitest'

// authenticate's ban check (docs/api-contract.md, "Client failure semantics"): a suspended identity
// gets `403 account_suspended` everywhere but DELETE /me and GET /me/export, and is checked BEFORE
// the user upsert so an erased, banned account is not re-created. Identity, users and the ban list
// are mocked — no network, no database.

const mocks = vi.hoisted(() => ({
  resolveIdentity: vi.fn(),
  upsertUser: vi.fn(),
  getUserByClerkId: vi.fn(),
  isSuspended: vi.fn(),
  deletionState: vi.fn(),
  finishDeletion: vi.fn(),
  reconcileIndependentDeletions: vi.fn(),
}))

vi.mock('./identity.js', () => ({ resolveIdentity: mocks.resolveIdentity }))
vi.mock('../services/users.js', () => ({ upsertUser: mocks.upsertUser, getUserByClerkId: mocks.getUserByClerkId }))
vi.mock('../services/moderation.js', () => ({ isSuspended: mocks.isSuspended }))
vi.mock('../db/index.js', () => ({ db: {}, sql: {} }))
vi.mock('../services/deletionLedger.js', () => ({
  AccountErasedError: class AccountErasedError extends Error {},
  deletionState: mocks.deletionState,
  finishDeletion: mocks.finishDeletion,
  reconcileIndependentDeletions: mocks.reconcileIndependentDeletions,
  deletionResponse: (row: { completedAt: Date | null; appleRevocation?: string }) => ({ deleted: !!row.completedAt, status: row.completedAt ? 'complete' : 'pending', appleRevocation: row.appleRevocation ?? 'manual_required' }),
}))

const { authenticate, suspendedMayCall } = await import('./clerk.js')
const { recordErasure, resetErasures, ERASURE_HOLD_MS } = await import('../services/erasure.js')

const USER = { id: '11111111-1111-4111-8111-111111111111', clerkId: 'user_banned' }
const AUTH = { authorization: 'Bearer token-123' }

async function app(): Promise<FastifyInstance> {
  const instance = Fastify()
  instance.decorate('authenticate', authenticate)
  await instance.register(async (scope) => {
    scope.addHook('preHandler', scope.authenticate)
    const echo = async (req: { user?: unknown }) => ({ user: req.user })
    scope.get('/me/feed', echo)
    scope.delete('/me', echo)
    scope.get('/me/export', echo)
    scope.post('/me/export', echo)
    scope.get('/me/profile', echo)
    scope.get('/me/deletion', echo)
    scope.get('/social/episodes/:mediaId/:episode', echo)
  })
  await instance.ready()
  return instance
}

beforeEach(() => {
  resetErasures()
  mocks.resolveIdentity.mockReset().mockResolvedValue({ clerkId: USER.clerkId, email: 'x@example.com' })
  mocks.upsertUser.mockReset().mockResolvedValue(USER)
  mocks.getUserByClerkId.mockReset().mockResolvedValue(USER)
  mocks.isSuspended.mockReset().mockResolvedValue(false)
  mocks.deletionState.mockReset().mockResolvedValue(undefined)
  mocks.finishDeletion.mockReset().mockResolvedValue(undefined)
  mocks.reconcileIndependentDeletions.mockReset().mockResolvedValue(undefined)
})

describe('authenticate — authoritative deletion receipts', () => {
  it('reconciles a journal-only intent before reading and returning pending without upsert', async () => {
    const order: string[] = []
    let receipt: { completedAt: null } | undefined
    mocks.reconcileIndependentDeletions.mockImplementation(async () => {
      order.push('reconcile')
      receipt = { completedAt: null }
    })
    mocks.deletionState.mockImplementation(async () => {
      order.push('state')
      return receipt
    })
    const server = await app()
    const response = await server.inject({ method: 'GET', url: '/me/deletion', headers: AUTH })
    expect(response.statusCode).toBe(202)
    expect(response.json()).toEqual({ deleted: false, status: 'pending', appleRevocation: 'manual_required' })
    expect(mocks.reconcileIndependentDeletions).toHaveBeenCalledOnce()
    expect(mocks.deletionState).toHaveBeenCalledWith(USER.clerkId)
    expect(order).toEqual(['reconcile', 'state'])
    expect(mocks.upsertUser).not.toHaveBeenCalled()
    await server.close()
  })

  it('cannot report active when journal reconciliation fails', async () => {
    mocks.reconcileIndependentDeletions.mockRejectedValue(new Error('reconciliation unavailable'))
    const server = await app()
    const response = await server.inject({ method: 'GET', url: '/me/deletion', headers: AUTH })
    expect(response.statusCode).toBe(500)
    expect(response.json()).not.toEqual({ deleted: false, status: 'active' })
    expect(mocks.deletionState).not.toHaveBeenCalled()
    expect(mocks.upsertUser).not.toHaveBeenCalled()
    await server.close()
  })

  it('authenticates before reading a private deletion journal', async () => {
    const server = await app()
    expect((await server.inject({ method: 'GET', url: '/me/deletion' })).statusCode).toBe(401)
    mocks.resolveIdentity.mockResolvedValue(null)
    expect((await server.inject({ method: 'GET', url: '/me/deletion', headers: AUTH })).statusCode).toBe(401)
    expect(mocks.reconcileIndependentDeletions).not.toHaveBeenCalled()
    expect(mocks.deletionState).not.toHaveBeenCalled()
    await server.close()
  })

  it('replays a completed deletion receipt without invoking the route or reusing Apple proof', async () => {
    recordErasure(USER.clerkId)
    const receipt = { completedAt: new Date(), appleRevocation: 'revoked' }
    mocks.deletionState.mockResolvedValue(receipt)
    mocks.finishDeletion.mockResolvedValue(receipt)
    const server = await app()
    const response = await server.inject({ method: 'DELETE', url: '/me', headers: AUTH,
      payload: { apple: { identityToken: 'synthetic-replayed-jwt', authorizationCode: 'synthetic-used-code' } } })
    expect(response.json()).toEqual({ deleted: true, status: 'complete', appleRevocation: 'revoked' })
    expect(response.json()).not.toHaveProperty('user')
    expect(mocks.upsertUser).not.toHaveBeenCalled()
    const status = await server.inject({ method: 'GET', url: '/me/deletion', headers: AUTH })
    expect(status.json()).toEqual(response.json())
    await server.close()
  })

  it('accepts a verified Apple identity without an email claim', async () => {
    mocks.resolveIdentity.mockResolvedValue({ clerkId: USER.clerkId })
    const server = await app()
    expect((await server.inject({ method: 'GET', url: '/me/profile', headers: AUTH })).statusCode).toBe(200)
    expect(mocks.upsertUser).toHaveBeenCalledWith(USER.clerkId, undefined)
    await server.close()
  })
})

describe('authenticate — suspended identities', () => {
  it('answers 403 account_suspended on an ordinary route and never upserts the user', async () => {
    mocks.isSuspended.mockResolvedValue(true)
    const server = await app()
    const res = await server.inject({ method: 'GET', url: '/me/feed', headers: AUTH })
    expect(res.statusCode).toBe(403)
    expect(res.headers['content-type']).toMatch(/^application\/json/)
    expect(res.json()).toEqual({ error: 'account_suspended' })
    expect(mocks.isSuspended).toHaveBeenCalledWith(USER.clerkId)
    expect(mocks.upsertUser).not.toHaveBeenCalled()
    await server.close()
  })

  it('refuses every other route too, including parametrised ones and the export under another verb', async () => {
    mocks.isSuspended.mockResolvedValue(true)
    const server = await app()
    for (const [method, url] of [
      ['GET', '/me/profile'],
      ['GET', '/social/episodes/1/2'],
      ['POST', '/me/export'],
    ] as const) {
      const res = await server.inject({ method, url, headers: AUTH })
      expect(res.statusCode, `${method} ${url}`).toBe(403)
    }
    expect(mocks.upsertUser).not.toHaveBeenCalled()
    await server.close()
  })

  it('lets a suspended account delete itself and download its data', async () => {
    mocks.isSuspended.mockResolvedValue(true)
    const server = await app()
    for (const [method, url] of [
      ['DELETE', '/me'],
      ['GET', '/me/export'],
      ['GET', '/me/export?download=1'],
    ] as const) {
      const res = await server.inject({ method, url, headers: AUTH })
      expect(res.statusCode, `${method} ${url}`).toBe(200)
      expect(res.json()).toEqual({ user: USER })
    }
    // The export only LOOKS the account up; the erasure may upsert (it deletes what it finds).
    expect(mocks.upsertUser).toHaveBeenCalledTimes(1)
    expect(mocks.getUserByClerkId).toHaveBeenCalledTimes(2)
    expect(mocks.getUserByClerkId).toHaveBeenCalledWith(USER.clerkId)
    await server.close()
  })

  it('never re-creates an erased, banned account from its export: 404 account not found', async () => {
    mocks.isSuspended.mockResolvedValue(true)
    mocks.getUserByClerkId.mockResolvedValue(undefined)
    const server = await app()
    const res = await server.inject({ method: 'GET', url: '/me/export', headers: AUTH })
    expect(res.statusCode).toBe(404)
    expect(res.json()).toEqual({ error: 'account not found' })
    expect(mocks.upsertUser).not.toHaveBeenCalled()
    await server.close()
  })

  it('upserts a non-suspended identity and attaches it', async () => {
    const server = await app()
    const res = await server.inject({ method: 'GET', url: '/me/feed', headers: AUTH })
    expect(res.statusCode).toBe(200)
    expect(res.json()).toEqual({ user: USER })
    expect(mocks.upsertUser).toHaveBeenCalledWith(USER.clerkId, 'x@example.com')
    await server.close()
  })

  it('checks the ban before the upsert', async () => {
    const order: string[] = []
    mocks.isSuspended.mockImplementation(async () => {
      order.push('ban')
      return false
    })
    mocks.upsertUser.mockImplementation(async () => {
      order.push('upsert')
      return USER
    })
    const server = await app()
    await server.inject({ method: 'GET', url: '/me/feed', headers: AUTH })
    expect(order).toEqual(['ban', 'upsert'])
    await server.close()
  })
})

describe('authenticate — a just-erased identity', () => {
  it('answers 401 account deleted and never re-creates the account', async () => {
    recordErasure(USER.clerkId)
    const server = await app()
    for (const [method, url] of [
      ['GET', '/me/feed'],
      ['DELETE', '/me'],
      ['GET', '/me/export'],
    ] as const) {
      const res = await server.inject({ method, url, headers: AUTH })
      expect(res.statusCode, `${method} ${url}`).toBe(401)
      expect(res.json()).toEqual({ error: 'account deleted' })
    }
    expect(mocks.upsertUser).not.toHaveBeenCalled()
    await server.close()
  })

  it('refuses a suspended, erased identity the same way, even on the routes a suspension allows', async () => {
    recordErasure(USER.clerkId)
    mocks.isSuspended.mockResolvedValue(true)
    const server = await app()
    const res = await server.inject({ method: 'DELETE', url: '/me', headers: AUTH })
    expect(res.statusCode).toBe(401)
    expect(res.json()).toEqual({ error: 'account deleted' })
    expect(mocks.upsertUser).not.toHaveBeenCalled()
    await server.close()
  })

  it('leaves every other identity alone', async () => {
    recordErasure('user_someone_else')
    const server = await app()
    const res = await server.inject({ method: 'GET', url: '/me/feed', headers: AUTH })
    expect(res.statusCode).toBe(200)
    expect(mocks.upsertUser).toHaveBeenCalledOnce()
    await server.close()
  })

  it('the hold outlives any session JWT (15 minutes)', () => {
    expect(ERASURE_HOLD_MS).toBe(15 * 60_000)
  })
})

describe('authenticate — the ban list could not be loaded', () => {
  it('fails open: the request proceeds and the user is upserted', async () => {
    const { createBanCache } = await vi.importActual<typeof import('../services/moderation.js')>('../services/moderation.js')
    const warn = vi.spyOn(console, 'warn').mockImplementation(() => {})
    const cold = createBanCache(async () => Promise.reject(new Error('relation "moderation_bans" does not exist')), 60_000)
    mocks.isSuspended.mockImplementation((clerkId: string) => cold.has(clerkId))
    const server = await app()
    const feed = await server.inject({ method: 'GET', url: '/me/feed', headers: AUTH })
    expect(feed.statusCode).toBe(200)
    expect(feed.json()).toEqual({ user: USER })
    expect(mocks.upsertUser).toHaveBeenCalledWith(USER.clerkId, 'x@example.com')
    expect(warn).toHaveBeenCalledWith(expect.objectContaining({ event: 'moderation.ban_cache_unavailable' }))
    warn.mockRestore()
    await server.close()
  })
})

describe('authenticate — the 401 paths are unchanged', () => {
  it('401 missing bearer token, without resolving or checking anything', async () => {
    const server = await app()
    for (const headers of [{}, { authorization: 'Basic abc' }]) {
      const res = await server.inject({ method: 'GET', url: '/me/feed', headers })
      expect(res.statusCode).toBe(401)
      expect(res.json()).toEqual({ error: 'missing bearer token' })
    }
    expect(mocks.resolveIdentity).not.toHaveBeenCalled()
    expect(mocks.isSuspended).not.toHaveBeenCalled()
    expect(mocks.upsertUser).not.toHaveBeenCalled()
    await server.close()
  })

  it('401 invalid token, before the ban check (a ban never leaks to an unauthenticated caller)', async () => {
    mocks.resolveIdentity.mockResolvedValue(null)
    mocks.isSuspended.mockResolvedValue(true)
    const server = await app()
    for (const [method, url] of [
      ['GET', '/me/feed'],
      ['DELETE', '/me'],
    ] as const) {
      const res = await server.inject({ method, url, headers: AUTH })
      expect(res.statusCode).toBe(401)
      expect(res.json()).toEqual({ error: 'invalid token' })
    }
    expect(mocks.resolveIdentity).toHaveBeenCalledWith('token-123', expect.any(Object))
    expect(mocks.isSuspended).not.toHaveBeenCalled()
    expect(mocks.upsertUser).not.toHaveBeenCalled()
    await server.close()
  })
})

describe('suspendedMayCall', () => {
  it('is true only for DELETE /me and GET /me/export (route patterns)', () => {
    expect(suspendedMayCall('DELETE', '/me')).toBe(true)
    expect(suspendedMayCall('GET', '/me/export')).toBe(true)
    for (const [method, url] of [
      ['GET', '/me'],
      ['POST', '/me'],
      ['HEAD', '/me/export'],
      ['DELETE', '/me/export'],
      ['GET', '/me/export/'],
      ['GET', '/me/feed'],
      ['DELETE', '/social/comments/:id'],
      ['GET', undefined],
    ] as const) {
      expect(suspendedMayCall(method, url), `${method} ${url}`).toBe(false)
    }
  })
})

// The ban list's process cache (services/moderation.ts `createBanCache`), with an injected loader.
describe('ban cache', async () => {
  const { createBanCache } = await vi.importActual<typeof import('../services/moderation.js')>('../services/moderation.js')

  it('loads once per TTL and reloads when it is older', async () => {
    const load = vi.fn(async () => ['user_a'])
    const cache = createBanCache(load, 60_000)
    expect(await cache.has('user_a', 1_000)).toBe(true)
    expect(await cache.has('user_b', 30_000)).toBe(false)
    expect(load).toHaveBeenCalledTimes(1)
    load.mockResolvedValue([])
    expect(await cache.has('user_a', 61_000)).toBe(false)
    expect(load).toHaveBeenCalledTimes(2)
  })

  it('is single-flight: concurrent stale checks share one query', async () => {
    let release!: (ids: string[]) => void
    const load = vi.fn(() => new Promise<string[]>((resolve) => (release = resolve)))
    const cache = createBanCache(load, 60_000)
    const checks = [cache.has('user_a', 1), cache.has('user_b', 2), cache.has('user_c', 3)]
    release(['user_b'])
    expect(await Promise.all(checks)).toEqual([false, true, false])
    expect(load).toHaveBeenCalledTimes(1)
  })

  it('with a TTL of 0 reads the list on every check', async () => {
    const load = vi.fn(async () => ['user_a'])
    const cache = createBanCache(load, 0)
    await cache.has('user_a', 5)
    await cache.has('user_a', 5)
    expect(load).toHaveBeenCalledTimes(2)
  })

  it('keeps answering from the previous list when a refresh fails, and fails OPEN when it never loaded', async () => {
    const warn = vi.spyOn(console, 'warn').mockImplementation(() => {})
    const load = vi.fn(async (): Promise<string[]> => ['user_a'])
    const cache = createBanCache(load, 1_000)
    expect(await cache.has('user_a', 0)).toBe(true)
    load.mockRejectedValue(new Error('db down'))
    expect(await cache.has('user_a', 5_000)).toBe(true)
    // It retries on the next check rather than trusting the stale list for a whole TTL.
    load.mockResolvedValue([])
    expect(await cache.has('user_a', 5_001)).toBe(false)

    // Never loaded: "not banned", logged, nothing cached — the next check retries the load.
    const coldLoad = vi.fn(async (): Promise<string[]> => Promise.reject(new Error('db down')))
    const cold = createBanCache(coldLoad, 1_000)
    expect(await cold.has('user_a', 0)).toBe(false)
    expect(warn).toHaveBeenCalledWith({ event: 'moderation.ban_cache_unavailable', error: 'diagnostic details redacted' })
    coldLoad.mockResolvedValue(['user_a'])
    expect(await cold.has('user_a', 1)).toBe(true)
    expect(coldLoad).toHaveBeenCalledTimes(2)
    warn.mockRestore()
  })

  it('invalidate() forces a reload, and a load that was in flight is not kept', async () => {
    const load = vi.fn(async () => ['user_a'])
    const cache = createBanCache(load, 60_000)
    await cache.has('user_a', 0)
    cache.invalidate()
    load.mockResolvedValue([])
    expect(await cache.has('user_a', 1)).toBe(false)
    expect(load).toHaveBeenCalledTimes(2)

    let release!: (ids: string[]) => void
    load.mockImplementation(() => new Promise<string[]>((resolve) => (release = resolve)))
    cache.invalidate()
    const pending = cache.has('user_a', 2)
    cache.invalidate()
    release(['user_a'])
    expect(await pending).toBe(true)
    load.mockResolvedValue([])
    expect(await cache.has('user_a', 3)).toBe(false)
  })
})
