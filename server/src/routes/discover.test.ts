import Fastify, { type FastifyReply, type FastifyRequest } from 'fastify'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { encodeGenreCursor } from '../discover/genres.js'
import type { DiscoverGenrePage, DiscoverGenresResponse } from '../types/api.js'

// The contract of GET /discover/genres and GET /discover/genres/:key: validation, status codes,
// cursor passthrough and caller scoping. The SQL lives in services/discover.ts; the vocabulary and the
// cursor's own rules are tested in discover/genres.test.ts.

const mocks = vi.hoisted(() => ({
  getDiscoverGenres: vi.fn(),
  getDiscoverGenrePage: vi.fn(),
}))
/** The caller's stored audience (services/audience.ts reads it for real, from this fake table). */
const viewer = vi.hoisted(() => ({ audience: null as string | null, reads: 0 }))

vi.mock('../db/index.js', () => ({
  db: {
    select: () => ({
      from: () => ({
        where: () => ({
          limit: async () => {
            viewer.reads += 1
            return viewer.audience ? [{ audience: viewer.audience, updatedAt: new Date(0) }] : []
          },
        }),
      }),
    }),
  },
  sql: {},
}))
vi.mock('../services/discover.js', () => mocks)

const { discoverRoutes } = await import('./discover.js')
const CALLER = '11111111-1111-4111-8111-111111111111'

const LIST: DiscoverGenresResponse = {
  source: null,
  genres: [{ key: 'action', name: 'Action', count: 12, posters: ['https://img/a.jpg'] }],
  generatedAt: 1_790_330_400_000,
}
const PAGE: DiscoverGenrePage = {
  genre: { key: 'action', name: 'Action', count: 12, posters: [] },
  franchises: [],
  nextCursor: null,
}

async function app() {
  const instance = Fastify()
  instance.decorate('authenticate', async (req: FastifyRequest, _reply: FastifyReply) => {
    req.user = { id: CALLER, clerkId: 'user_test' }
  })
  await instance.register(discoverRoutes)
  await instance.ready()
  return instance
}

beforeEach(() => {
  viewer.audience = null
  viewer.reads = 0
  mocks.getDiscoverGenres.mockReset().mockImplementation(async (source: string | null) => ({ ...LIST, source }))
  mocks.getDiscoverGenrePage.mockReset().mockResolvedValue(PAGE)
})

describe('the audience is the default catalogue', () => {
  it('browses the viewer\'s own catalogue when the request names none, and says which', async () => {
    const server = await app()
    for (const [audience, source] of [['anime', 'anilist'], ['tv', 'tmdb'], ['both', null], [null, null]] as const) {
      viewer.audience = audience
      mocks.getDiscoverGenres.mockClear()
      mocks.getDiscoverGenrePage.mockClear()
      const list = await server.inject({ method: 'GET', url: '/discover/genres' })
      expect(list.json().source, String(audience)).toBe(source)
      expect(mocks.getDiscoverGenres).toHaveBeenCalledWith(source)
      await server.inject({ method: 'GET', url: '/discover/genres/action' })
      expect(mocks.getDiscoverGenrePage.mock.calls[0]![2], String(audience)).toEqual({ source, limit: 24, offset: 0 })
    }
    await server.close()
  })

  it('lets an explicit source win over the audience, without reading the preference', async () => {
    viewer.audience = 'anime'
    const server = await app()
    expect((await server.inject({ method: 'GET', url: '/discover/genres?source=tmdb' })).json().source).toBe('tmdb')
    await server.inject({ method: 'GET', url: '/discover/genres/action?source=tmdb' })
    expect(mocks.getDiscoverGenres).toHaveBeenCalledWith('tmdb')
    expect(mocks.getDiscoverGenrePage.mock.calls[0]![2].source).toBe('tmdb')
    expect(viewer.reads).toBe(0)
    await server.close()
  })
})

describe('GET /discover/genres', () => {
  it('serves All when the source is absent', async () => {
    const server = await app()
    const res = await server.inject({ method: 'GET', url: '/discover/genres' })
    expect(res.statusCode).toBe(200)
    expect(res.json()).toEqual(LIST)
    expect(mocks.getDiscoverGenres).toHaveBeenCalledWith(null)
    await server.close()
  })

  it('passes a catalogue scope through', async () => {
    const server = await app()
    for (const source of ['anilist', 'tmdb']) {
      const res = await server.inject({ method: 'GET', url: `/discover/genres?source=${source}` })
      expect(res.statusCode).toBe(200)
      expect(res.json().source).toBe(source)
    }
    expect(mocks.getDiscoverGenres.mock.calls).toEqual([['anilist'], ['tmdb']])
    await server.close()
  })

  it('rejects any other source with 400 and no service call', async () => {
    const server = await app()
    for (const query of ['source=all', 'source=ANILIST', 'source=anime', 'source=', 'source=anilist&source=tmdb']) {
      const res = await server.inject({ method: 'GET', url: `/discover/genres?${query}` })
      expect(res.statusCode).toBe(400)
      expect(res.json()).toEqual({ error: 'invalid request' })
    }
    expect(mocks.getDiscoverGenres).not.toHaveBeenCalled()
    await server.close()
  })
})

describe('GET /discover/genres/:key', () => {
  it('serves the first page for the caller: limit 24, offset 0, All', async () => {
    const server = await app()
    const res = await server.inject({ method: 'GET', url: '/discover/genres/action' })
    expect(res.statusCode).toBe(200)
    expect(res.json()).toEqual(PAGE)
    expect(mocks.getDiscoverGenrePage).toHaveBeenCalledTimes(1)
    const [userId, def, options] = mocks.getDiscoverGenrePage.mock.calls[0]!
    expect(userId).toBe(CALLER)
    expect(def).toMatchObject({ key: 'action', name: 'Action' })
    expect(options).toEqual({ source: null, limit: 24, offset: 0 })
    await server.close()
  })

  it('answers 404 genre not found for an unknown key, with no service call', async () => {
    const server = await app()
    for (const key of ['nope', 'Action', 'ecchi', 'constructor', encodeURIComponent('Slice of Life')]) {
      const res = await server.inject({ method: 'GET', url: `/discover/genres/${key}` })
      expect(res.statusCode).toBe(404)
      expect(res.json()).toEqual({ error: 'genre not found' })
    }
    expect(mocks.getDiscoverGenrePage).not.toHaveBeenCalled()
    await server.close()
  })

  it('accepts limit 1…50 and rejects anything else', async () => {
    const server = await app()
    for (const limit of ['1', '50']) {
      expect((await server.inject({ method: 'GET', url: `/discover/genres/drama?limit=${limit}` })).statusCode).toBe(200)
    }
    for (const limit of ['0', '51', '-1', '2.5', 'many', '']) {
      const res = await server.inject({ method: 'GET', url: `/discover/genres/drama?limit=${limit}` })
      expect(res.statusCode).toBe(400)
      expect(res.json()).toEqual({ error: 'invalid request' })
    }
    expect(mocks.getDiscoverGenrePage.mock.calls.map((call) => call[2].limit)).toEqual([1, 50])
    await server.close()
  })

  it('validates the source and passes it through', async () => {
    const server = await app()
    expect((await server.inject({ method: 'GET', url: '/discover/genres/crime?source=tmdb' })).statusCode).toBe(200)
    expect(mocks.getDiscoverGenrePage.mock.calls[0]![2]).toEqual({ source: 'tmdb', limit: 24, offset: 0 })
    for (const source of ['all', 'TMDB', '']) {
      expect((await server.inject({ method: 'GET', url: `/discover/genres/crime?source=${source}` })).statusCode).toBe(400)
    }
    expect(mocks.getDiscoverGenrePage).toHaveBeenCalledTimes(1)
    await server.close()
  })

  it('decodes the cursor into the offset and hands back the next cursor untouched', async () => {
    const next = encodeGenreCursor(72)
    mocks.getDiscoverGenrePage.mockResolvedValue({ ...PAGE, nextCursor: next })
    const server = await app()
    const res = await server.inject({
      method: 'GET',
      url: `/discover/genres/comedy?source=anilist&limit=24&cursor=${encodeGenreCursor(48)}`,
    })
    expect(res.statusCode).toBe(200)
    expect(res.json().nextCursor).toBe(next)
    expect(mocks.getDiscoverGenrePage.mock.calls[0]![2]).toEqual({ source: 'anilist', limit: 24, offset: 48 })
    await server.close()
  })

  it('rejects a malformed cursor with 400 and no service call', async () => {
    const server = await app()
    const forged = Buffer.from(JSON.stringify({ o: -5 }), 'utf8').toString('base64url')
    for (const cursor of ['garbage!', forged, 'x'.repeat(200), '']) {
      const res = await server.inject({
        method: 'GET',
        url: `/discover/genres/comedy?cursor=${encodeURIComponent(cursor)}`,
      })
      expect(res.statusCode).toBe(400)
    }
    expect(mocks.getDiscoverGenrePage).not.toHaveBeenCalled()
    await server.close()
  })
})
