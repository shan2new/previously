import Fastify, { type FastifyReply, type FastifyRequest } from 'fastify'
import { beforeEach, describe, expect, it, vi } from 'vitest'

// The contract of /me/watch-sessions: validation, status codes, null defaults for omitted fields
// and that every call is scoped to the bearer. The SQL lives in services/watchSessions.ts.

const mocks = vi.hoisted(() => ({
  listWatchSessions: vi.fn(),
  putWatchSession: vi.fn(),
  deleteWatchSession: vi.fn(),
}))

vi.mock('../db/index.js', () => ({ db: {}, sql: {} }))
vi.mock('../services/watchSessions.js', () => mocks)
vi.mock('../services/animeVideoFallback.js', () => ({ enqueueAnimeVideoFallback: vi.fn() }))
vi.mock('../services/catalogEnrichment.js', () => ({ enqueueRecommendationRefresh: vi.fn() }))

const { meRoutes } = await import('./me.js')
const CALLER = '11111111-1111-1111-1111-111111111111'
const SESSION = '22222222-2222-4222-8222-222222222222'
const FRANCHISE = '33333333-3333-4333-8333-333333333333'

async function app() {
  const instance = Fastify()
  instance.decorate('authenticate', async (req: FastifyRequest, _reply: FastifyReply) => {
    req.user = { id: CALLER, clerkId: 'user_test' }
  })
  await instance.register(meRoutes)
  await instance.ready()
  return instance
}

const rewatch = {
  franchiseId: FRANCHISE,
  scopeMediaId: null,
  ordinal: 2,
  startedAt: 1790000000000,
  completedAt: null,
  cancelledAt: null,
  cancelledAtEpisode: null,
  episodes: 24,
  restoreProgress: { '21': 24, '1000012345': 10 },
  restoreStatus: 'completed',
}

beforeEach(() => {
  mocks.listWatchSessions.mockReset().mockResolvedValue([])
  mocks.putWatchSession.mockReset().mockResolvedValue('saved')
  mocks.deleteWatchSession.mockReset().mockResolvedValue(undefined)
})

describe('GET /me/watch-sessions', () => {
  it("lists the caller's sessions", async () => {
    const server = await app()
    const session = { id: SESSION, ...rewatch, updatedAt: 1 }
    mocks.listWatchSessions.mockResolvedValue([session])
    const res = await server.inject({ method: 'GET', url: '/me/watch-sessions' })
    expect(res.statusCode).toBe(200)
    expect(res.json()).toEqual({ sessions: [session] })
    expect(mocks.listWatchSessions).toHaveBeenCalledWith(CALLER)
    await server.close()
  })
})

describe('PUT /me/watch-sessions/:id', () => {
  it('saves the whole session for the caller', async () => {
    const server = await app()
    const res = await server.inject({ method: 'PUT', url: `/me/watch-sessions/${SESSION}`, payload: rewatch })
    expect(res.statusCode).toBe(204)
    expect(mocks.putWatchSession).toHaveBeenCalledWith(CALLER, SESSION, rewatch, { user: { id: CALLER, clerkId: 'user_test' }, stamp: null })
    await server.close()
  })

  it('reads omitted optional fields as null (the implicit first watch: completed, date unknown)', async () => {
    const server = await app()
    const first = { franchiseId: FRANCHISE, ordinal: 1, completedAt: 0, episodes: 24 }
    const res = await server.inject({ method: 'PUT', url: `/me/watch-sessions/${SESSION}`, payload: first })
    expect(res.statusCode).toBe(204)
    expect(mocks.putWatchSession).toHaveBeenCalledWith(CALLER, SESSION, {
      franchiseId: FRANCHISE,
      scopeMediaId: null,
      ordinal: 1,
      startedAt: null,
      completedAt: 0,
      cancelledAt: null,
      cancelledAtEpisode: null,
      episodes: 24,
      restoreProgress: null,
      restoreStatus: null,
    }, { user: { id: CALLER, clerkId: 'user_test' }, stamp: null })
    await server.close()
  })

  it('maps each outcome to its status', async () => {
    const server = await app()
    const put = () => server.inject({ method: 'PUT', url: `/me/watch-sessions/${SESSION}`, payload: rewatch })
    mocks.putWatchSession.mockResolvedValueOnce('deleted')
    expect((await put()).statusCode).toBe(410)
    mocks.putWatchSession.mockResolvedValueOnce('franchise_not_found')
    expect((await put()).json()).toEqual({ error: 'franchise not found' })
    mocks.putWatchSession.mockResolvedValueOnce('not_found')
    const other = await put()
    expect(other.statusCode).toBe(404)
    expect(other.json()).toEqual({ error: 'session not found' })
    await server.close()
  })

  it('rejects malformed ids and bodies without writing', async () => {
    const server = await app()
    const bad = [
      { url: '/me/watch-sessions/not-a-uuid', payload: rewatch },
      { url: `/me/watch-sessions/${SESSION}`, payload: { ...rewatch, franchiseId: 'nope' } },
      { url: `/me/watch-sessions/${SESSION}`, payload: { ...rewatch, ordinal: 0 } },
      { url: `/me/watch-sessions/${SESSION}`, payload: { ...rewatch, episodes: -1 } },
      { url: `/me/watch-sessions/${SESSION}`, payload: { ...rewatch, startedAt: 1.5 } },
      { url: `/me/watch-sessions/${SESSION}`, payload: { ...rewatch, restoreStatus: 'binged' } },
      { url: `/me/watch-sessions/${SESSION}`, payload: { ...rewatch, restoreProgress: { abc: 1 } } },
      { url: `/me/watch-sessions/${SESSION}`, payload: { ...rewatch, userId: CALLER } },
    ]
    for (const { url, payload } of bad) {
      expect((await server.inject({ method: 'PUT', url, payload })).statusCode).toBe(400)
    }
    expect(mocks.putWatchSession).not.toHaveBeenCalled()
    await server.close()
  })
})

describe('DELETE /me/watch-sessions/:id', () => {
  it('tombstones the session for the caller, idempotently', async () => {
    const server = await app()
    for (let i = 0; i < 2; i++) {
      const res = await server.inject({ method: 'DELETE', url: `/me/watch-sessions/${SESSION}` })
      expect(res.statusCode).toBe(204)
    }
    expect(mocks.deleteWatchSession).toHaveBeenCalledTimes(2)
    expect(mocks.deleteWatchSession).toHaveBeenCalledWith(CALLER, SESSION, { user: { id: CALLER, clerkId: 'user_test' }, stamp: null })
    expect((await server.inject({ method: 'DELETE', url: '/me/watch-sessions/42' })).statusCode).toBe(400)
    await server.close()
  })
})
