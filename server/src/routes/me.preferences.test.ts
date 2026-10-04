import Fastify, { type FastifyReply, type FastifyRequest } from 'fastify'
import { beforeEach, describe, expect, it, vi } from 'vitest'

// The contract of GET and PUT /me/preferences around the audience (docs/api-contract.md,
// "Audience"): the field on the wire, the three values a PUT accepts, and the 503 a client gets
// while the audience cannot be stored. What is stored and how is services/preferences.test.ts.

const mocks = vi.hoisted(() => ({
  getUserPreferences: vi.fn(),
  updateUserPreferences: vi.fn(),
}))

vi.mock('../db/index.js', () => ({ db: {}, sql: {} }))
vi.mock('../services/preferences.js', async (importOriginal) => ({
  ...(await importOriginal<typeof import('../services/preferences.js')>()),
  getUserPreferences: mocks.getUserPreferences,
  updateUserPreferences: mocks.updateUserPreferences,
}))
vi.mock('../services/animeVideoFallback.js', () => ({ enqueueAnimeVideoFallback: vi.fn() }))
vi.mock('../services/catalogEnrichment.js', () => ({ enqueueRecommendationRefresh: vi.fn() }))

const { meRoutes } = await import('./me.js')
const CALLER = '11111111-1111-4111-8111-111111111111'
const PREFERENCES = { country: 'IN', language: 'en', providerIds: [8], updatedAt: '2026-10-01T00:00:00.000Z', audience: 'anime' }

async function app() {
  const instance = Fastify()
  instance.decorate('authenticate', async (req: FastifyRequest, _reply: FastifyReply) => {
    req.user = { id: CALLER, clerkId: 'user_test' }
  })
  await instance.register(meRoutes)
  await instance.ready()
  return instance
}

beforeEach(() => {
  mocks.getUserPreferences.mockReset().mockResolvedValue(PREFERENCES)
  mocks.updateUserPreferences.mockReset().mockResolvedValue({ ok: true, preferences: PREFERENCES })
})

describe('GET /me/preferences', () => {
  it('carries the audience for the caller, null while they have not chosen', async () => {
    const server = await app()
    expect((await server.inject({ method: 'GET', url: '/me/preferences' })).json()).toEqual(PREFERENCES)
    expect(mocks.getUserPreferences).toHaveBeenCalledWith(CALLER)
    mocks.getUserPreferences.mockResolvedValue({ ...PREFERENCES, audience: null })
    expect((await server.inject({ method: 'GET', url: '/me/preferences' })).json().audience).toBeNull()
    await server.close()
  })
})

describe('PUT /me/preferences', () => {
  it('accepts anime, tv and both, alone or with the other fields', async () => {
    const server = await app()
    for (const audience of ['anime', 'tv', 'both']) {
      const res = await server.inject({ method: 'PUT', url: '/me/preferences', payload: { audience } })
      expect(res.statusCode, audience).toBe(200)
      expect(res.json()).toEqual(PREFERENCES)
    }
    await server.inject({ method: 'PUT', url: '/me/preferences', payload: { country: 'in', audience: 'tv' } })
    expect(mocks.updateUserPreferences.mock.calls).toEqual([
      [CALLER, { audience: 'anime' }],
      [CALLER, { audience: 'tv' }],
      [CALLER, { audience: 'both' }],
      [CALLER, { country: 'IN', audience: 'tv' }],
    ])
    await server.close()
  })

  it('leaves the audience out of the update when the body omits it', async () => {
    const server = await app()
    const res = await server.inject({ method: 'PUT', url: '/me/preferences', payload: { language: 'hi' } })
    expect(res.statusCode).toBe(200)
    expect(mocks.updateUserPreferences).toHaveBeenCalledWith(CALLER, { language: 'hi' })
    await server.close()
  })

  it('refuses any other audience and writes nothing', async () => {
    const server = await app()
    for (const audience of ['all', 'Anime', '', null, 1, ['tv']]) {
      const res = await server.inject({ method: 'PUT', url: '/me/preferences', payload: { audience } })
      expect(res.statusCode, JSON.stringify(audience)).toBeGreaterThanOrEqual(400)
    }
    expect(mocks.updateUserPreferences).not.toHaveBeenCalled()
    await server.close()
  })

  it('answers 503 audience_unavailable when the choice could not be stored', async () => {
    mocks.updateUserPreferences.mockResolvedValue({ ok: false, error: 'audience_unavailable' })
    const server = await app()
    const res = await server.inject({ method: 'PUT', url: '/me/preferences', payload: { country: 'IN', audience: 'tv' } })
    expect(res.statusCode).toBe(503)
    expect(res.json()).toEqual({ error: 'audience_unavailable' })
    await server.close()
  })
})
