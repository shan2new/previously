import Fastify, { type FastifyReply, type FastifyRequest } from 'fastify'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { encodeCursor } from '../util/cursor.js'

// The contract of the P2 routes in routes/me.ts: PUT /me/progress (404 on an unknown media id,
// 400 — not 500 — on a bad body), GET /me/notifications (keyset cursor, safeParse, the social kinds
// following SOCIAL_COMMENTS_ENABLED), POST /me/notifications/read and GET /me/library's
// prevOpenedAt. The services are mocked; the rules are tested in services/*.test.ts.

const mocks = vi.hoisted(() => ({
  setProgress: vi.fn(),
  listNotifications: vi.fn(),
  markNotificationsRead: vi.fn(),
  readVisitAnchors: vi.fn(),
  getLibrary: vi.fn(),
  resolveUserPreferences: vi.fn(),
  getAvailabilityPreviews: vi.fn(),
}))

vi.mock('../db/index.js', () => ({ db: {}, sql: {} }))
vi.mock('../services/library.js', async (importOriginal) => ({
  ...(await importOriginal<typeof import('../services/library.js')>()),
  setProgress: mocks.setProgress,
}))
vi.mock('../services/notifications.js', () => ({
  listNotifications: mocks.listNotifications,
  markNotificationsRead: mocks.markNotificationsRead,
}))
vi.mock('../services/visits.js', () => ({ readVisitAnchors: mocks.readVisitAnchors }))
vi.mock('../services/franchiseView.js', async (importOriginal) => ({
  ...(await importOriginal<typeof import('../services/franchiseView.js')>()),
  getLibrary: mocks.getLibrary,
}))
vi.mock('../services/preferences.js', async (importOriginal) => ({
  ...(await importOriginal<typeof import('../services/preferences.js')>()),
  resolveUserPreferences: mocks.resolveUserPreferences,
}))
vi.mock('../services/watchAvailability.js', async (importOriginal) => ({
  ...(await importOriginal<typeof import('../services/watchAvailability.js')>()),
  getAvailabilityPreviews: mocks.getAvailabilityPreviews,
}))
vi.mock('../services/animeVideoFallback.js', () => ({ enqueueAnimeVideoFallback: vi.fn() }))
vi.mock('../services/catalogEnrichment.js', () => ({ enqueueRecommendationRefresh: vi.fn() }))

const { env } = await import('../env.js')
const { meRoutes } = await import('./me.js')

const CALLER = '11111111-1111-4111-8111-111111111111'
const NOTIFICATION = '22222222-2222-4222-8222-222222222222'
const EMPTY_PAGE = { items: [], unread: 0, nextCursor: null }

async function app() {
  const instance = Fastify()
  instance.decorate('authenticate', async (req: FastifyRequest, _reply: FastifyReply) => {
    req.user = { id: CALLER, clerkId: 'user_test' }
  })
  await instance.register(meRoutes)
  await instance.ready()
  return instance
}

const socialDefault = env.SOCIAL_COMMENTS_ENABLED

beforeEach(() => {
  mocks.setProgress.mockReset().mockResolvedValue({ ok: true, episodes: 5 })
  mocks.listNotifications.mockReset().mockResolvedValue(EMPTY_PAGE)
  mocks.markNotificationsRead.mockReset().mockResolvedValue(2)
  mocks.readVisitAnchors.mockReset().mockResolvedValue({ prevOpenedAt: 1_790_244_000_000, lastOpenedAt: 1_790_330_400_000 })
  mocks.getLibrary.mockReset().mockResolvedValue([])
  mocks.resolveUserPreferences.mockReset().mockResolvedValue({ country: null, language: 'en', providerIds: [] })
  mocks.getAvailabilityPreviews.mockReset().mockResolvedValue(new Map())
})

afterEach(() => {
  env.SOCIAL_COMMENTS_ENABLED = socialDefault
})

describe('PUT /me/progress', () => {
  it('answers { ok: true } for a known part, writing for the caller', async () => {
    const server = await app()
    const res = await server.inject({ method: 'PUT', url: '/me/progress', payload: { mediaId: 16498, episodes: 12 } })
    expect(res.statusCode).toBe(200)
    expect(res.json()).toEqual({ ok: true })
    expect(mocks.setProgress).toHaveBeenCalledWith(CALLER, 16498, 12, { user: { id: CALLER, clerkId: 'user_test' }, stamp: null })
    await server.close()
  })

  it('answers 404 media not found for an unknown media id (final: the client drops the write)', async () => {
    mocks.setProgress.mockResolvedValue({ ok: false, reason: 'media_not_found' })
    const server = await app()
    const res = await server.inject({ method: 'PUT', url: '/me/progress', payload: { mediaId: 999_999, episodes: 1 } })
    expect(res.statusCode).toBe(404)
    expect(res.json()).toEqual({ error: 'media not found' })
    await server.close()
  })

  it('answers 400 — not 500 — on a bad body, and writes nothing', async () => {
    const server = await app()
    const bad = [
      {},
      { mediaId: 1 },
      { mediaId: 1, episodes: -1 },
      { mediaId: 1, episodes: 2.5 },
      { mediaId: '1', episodes: 2 },
      { mediaId: 2_147_483_648, episodes: 2 },
      { mediaId: 1, episodes: 2_147_483_648 },
      { mediaId: 1, episodes: 2, extra: true },
    ]
    for (const payload of bad) {
      const res = await server.inject({ method: 'PUT', url: '/me/progress', payload })
      expect(res.statusCode, JSON.stringify(payload)).toBe(400)
      expect(res.json()).toEqual({ error: 'invalid request' })
    }
    expect(mocks.setProgress).not.toHaveBeenCalled()
    await server.close()
  })
})

describe('GET /me/notifications', () => {
  it('serves the first page of 50 for the caller, social kinds following the env', async () => {
    env.SOCIAL_COMMENTS_ENABLED = true
    const server = await app()
    const res = await server.inject({ method: 'GET', url: '/me/notifications' })
    expect(res.statusCode).toBe(200)
    expect(res.json()).toEqual(EMPTY_PAGE)
    expect(mocks.listNotifications).toHaveBeenCalledWith(CALLER, { limit: 50, cursor: null, includeSocial: true })
    await server.close()
  })

  it('leaves the social kinds out while comments are switched off', async () => {
    env.SOCIAL_COMMENTS_ENABLED = false
    const server = await app()
    await server.inject({ method: 'GET', url: '/me/notifications?limit=10' })
    expect(mocks.listNotifications).toHaveBeenCalledWith(CALLER, { limit: 10, cursor: null, includeSocial: false })
    await server.close()
  })

  it('answers 400 — not 500 — on a limit outside 1–200 or an unknown parameter', async () => {
    const server = await app()
    for (const query of ['limit=0', 'limit=201', 'limit=many', 'limit=2.5', 'offset=10']) {
      const res = await server.inject({ method: 'GET', url: `/me/notifications?${query}` })
      expect(res.statusCode, query).toBe(400)
      expect(res.json()).toEqual({ error: 'invalid request' })
    }
    expect(mocks.listNotifications).not.toHaveBeenCalled()
    await server.close()
  })

  it('decodes a cursor it wrote and passes it on', async () => {
    const cursor = { at: '2026-09-25T10:00:00.123456Z', id: NOTIFICATION }
    const server = await app()
    const res = await server.inject({ method: 'GET', url: `/me/notifications?limit=20&cursor=${encodeCursor(cursor)}` })
    expect(res.statusCode).toBe(200)
    expect(mocks.listNotifications).toHaveBeenCalledWith(CALLER, expect.objectContaining({ limit: 20, cursor }))
    await server.close()
  })

  it('answers 400 on a cursor it did not write', async () => {
    const server = await app()
    const forged = Buffer.from(JSON.stringify({ at: '2026-09-25', id: 'x' })).toString('base64url')
    for (const cursor of ['not-a-cursor!', forged, 'x'.repeat(401)]) {
      const res = await server.inject({ method: 'GET', url: `/me/notifications?cursor=${cursor}` })
      expect(res.statusCode, cursor).toBe(400)
    }
    expect(mocks.listNotifications).not.toHaveBeenCalled()
    await server.close()
  })

  it('reads an empty cursor as the first page', async () => {
    const server = await app()
    const res = await server.inject({ method: 'GET', url: '/me/notifications?limit=50&cursor=' })
    expect(res.statusCode).toBe(200)
    expect(mocks.listNotifications).toHaveBeenCalledWith(CALLER, expect.objectContaining({ cursor: null }))
    await server.close()
  })
})

describe('POST /me/notifications/read', () => {
  it('marks the given ids, or everything when ids is omitted', async () => {
    const server = await app()
    const some = await server.inject({ method: 'POST', url: '/me/notifications/read', payload: { ids: [NOTIFICATION] } })
    expect(some.statusCode).toBe(200)
    expect(some.json()).toEqual({ marked: 2 })
    const all = await server.inject({ method: 'POST', url: '/me/notifications/read' })
    expect(all.statusCode).toBe(200)
    expect(mocks.markNotificationsRead.mock.calls).toEqual([
      [CALLER, [NOTIFICATION]],
      [CALLER, undefined],
    ])
    await server.close()
  })

  it('answers 400 — not 500 — on a bad body', async () => {
    const server = await app()
    const bad = [
      { ids: ['not-a-uuid'] },
      { ids: NOTIFICATION },
      { ids: [NOTIFICATION], all: true },
      { ids: Array.from({ length: 501 }, () => NOTIFICATION) },
    ]
    for (const payload of bad) {
      const res = await server.inject({ method: 'POST', url: '/me/notifications/read', payload })
      expect(res.statusCode).toBe(400)
      expect(res.json()).toEqual({ error: 'invalid request' })
    }
    expect(mocks.markNotificationsRead).not.toHaveBeenCalled()
    await server.close()
  })
})

describe('GET /me/library', () => {
  it('returns the previous visit from readVisitAnchors and computes "new" against it', async () => {
    const server = await app()
    const res = await server.inject({ method: 'GET', url: '/me/library' })
    expect(res.statusCode).toBe(200)
    expect(res.json()).toEqual({ franchises: [], prevOpenedAt: 1_790_244_000_000 })
    expect(mocks.readVisitAnchors).toHaveBeenCalledWith(CALLER)
    // Never the last stamp (1_790_330_400_000): that is the echo bug.
    expect(mocks.getLibrary).toHaveBeenCalledWith(CALLER, 1_790_244_000_000)
    await server.close()
  })

  it('answers 400 — not 500 — on a malformed country', async () => {
    const server = await app()
    const res = await server.inject({ method: 'GET', url: '/me/library?country=india' })
    expect(res.statusCode).toBe(400)
    expect(mocks.getLibrary).not.toHaveBeenCalled()
    await server.close()
  })
})
