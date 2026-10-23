import Fastify, { type FastifyReply, type FastifyRequest } from 'fastify'
import { beforeEach, describe, expect, it, vi } from 'vitest'

// The contract of GET /me/recommendations and its feedback routes: validation, status codes and
// that every call is scoped to the bearer. The ranking itself is tested in recommendations.test.ts.

const mocks = vi.hoisted(() => ({
  getRecommendations: vi.fn(),
  recordRecommendationFeedback: vi.fn(),
  clearRecommendationFeedback: vi.fn(),
  recordRecommendationImpressions: vi.fn(),
}))

vi.mock('../db/index.js', () => ({ db: {}, sql: {} }))
vi.mock('../services/recommendations.js', () => mocks)
vi.mock('../services/animeVideoFallback.js', () => ({ enqueueAnimeVideoFallback: vi.fn() }))
vi.mock('../services/catalogEnrichment.js', () => ({ enqueueRecommendationRefresh: vi.fn() }))

const { meRoutes } = await import('./me.js')
const CALLER = '11111111-1111-1111-1111-111111111111'

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
  mocks.getRecommendations.mockReset().mockResolvedValue({ items: [], generatedAt: 1 })
  mocks.recordRecommendationFeedback.mockReset().mockResolvedValue(undefined)
  mocks.clearRecommendationFeedback.mockReset().mockResolvedValue(undefined)
  mocks.recordRecommendationImpressions.mockReset().mockResolvedValue(undefined)
})

describe('GET /me/recommendations', () => {
  it('serves 12 by default for the caller', async () => {
    const server = await app()
    const res = await server.inject({ method: 'GET', url: '/me/recommendations' })
    expect(res.statusCode).toBe(200)
    expect(res.json()).toEqual({ items: [], generatedAt: 1 })
    expect(mocks.getRecommendations).toHaveBeenCalledWith(CALLER, 12)
    await server.close()
  })

  it('accepts 1–30 and rejects anything else', async () => {
    const server = await app()
    for (const limit of ['1', '30']) {
      expect((await server.inject({ method: 'GET', url: `/me/recommendations?limit=${limit}` })).statusCode).toBe(200)
    }
    for (const limit of ['0', '31', 'many', '2.5']) {
      expect((await server.inject({ method: 'GET', url: `/me/recommendations?limit=${limit}` })).statusCode).toBe(400)
    }
    expect(mocks.getRecommendations.mock.calls.map((call) => call[1])).toEqual([1, 30])
    await server.close()
  })
})

describe('recommendation feedback', () => {
  it('records "not interested" and "mark as watched" with 204', async () => {
    const server = await app()
    for (const kind of ['dismissed', 'seen']) {
      const res = await server.inject({
        method: 'POST',
        url: '/me/recommendations/feedback',
        payload: { key: 'anilist:11061', kind },
      })
      expect(res.statusCode).toBe(204)
      expect(res.body).toBe('')
    }
    expect(mocks.recordRecommendationFeedback.mock.calls).toEqual([
      [CALLER, 'anilist:11061', 'dismissed'],
      [CALLER, 'anilist:11061', 'seen'],
    ])
    await server.close()
  })

  it('undoes a verdict with DELETE and a key', async () => {
    const server = await app()
    const res = await server.inject({ method: 'DELETE', url: '/me/recommendations/feedback', payload: { key: 'tmdb:1399' } })
    expect(res.statusCode).toBe(204)
    expect(mocks.clearRecommendationFeedback).toHaveBeenCalledWith(CALLER, 'tmdb:1399')
    await server.close()
  })

  it('rejects a body it does not understand and writes nothing', async () => {
    const server = await app()
    const bad = [
      { key: 'anilist:1', kind: 'hidden' },
      { key: 'mal:1', kind: 'seen' },
      { key: 'anilist:0', kind: 'seen' },
      { key: 'anilist:12abc', kind: 'seen' },
      { key: 'anilist:1', kind: 'seen', userId: 'someone-else' },
      {},
    ]
    for (const payload of bad) {
      expect((await server.inject({ method: 'POST', url: '/me/recommendations/feedback', payload })).statusCode).toBe(400)
    }
    for (const payload of [{ key: 'anilist:1', kind: 'seen' }, { key: 'x' }, {}]) {
      expect((await server.inject({ method: 'DELETE', url: '/me/recommendations/feedback', payload })).statusCode).toBe(400)
    }
    expect(mocks.recordRecommendationFeedback).not.toHaveBeenCalled()
    expect(mocks.clearRecommendationFeedback).not.toHaveBeenCalled()
    await server.close()
  })
})

describe('recommendation impressions', () => {
  it('records the titles that were on screen for the bearer with 204', async () => {
    const server = await app()
    const res = await server.inject({
      method: 'POST',
      url: '/me/recommendations/impressions',
      payload: { keys: ['anilist:20832', 'tmdb:1399'] },
    })
    expect(res.statusCode).toBe(204)
    expect(res.body).toBe('')
    expect(mocks.recordRecommendationImpressions).toHaveBeenCalledWith(CALLER, ['anilist:20832', 'tmdb:1399'])
    await server.close()
  })

  it('rejects an empty, oversized or malformed batch and writes nothing', async () => {
    const server = await app()
    const bad = [
      { keys: [] },
      { keys: Array.from({ length: 61 }, (_, i) => `anilist:${i + 1}`) },
      { keys: ['mal:1'] },
      { keys: ['anilist:1'], userId: 'someone-else' },
      { key: 'anilist:1' },
      {},
    ]
    for (const payload of bad) {
      expect((await server.inject({ method: 'POST', url: '/me/recommendations/impressions', payload })).statusCode).toBe(400)
    }
    expect(mocks.recordRecommendationImpressions).not.toHaveBeenCalled()
    await server.close()
  })
})
