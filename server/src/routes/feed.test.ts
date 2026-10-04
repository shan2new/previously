import Fastify, { type FastifyReply, type FastifyRequest } from 'fastify'
import { beforeEach, describe, expect, it, vi } from 'vitest'

// The contract of the Today feed routes: validation, status codes, the comment capability and that
// every call is scoped to the bearer. Composition is tested in feed/compose.test.ts.

const mocks = vi.hoisted(() => ({
  getFeed: vi.fn(),
  getPostDetail: vi.fn(),
  getSaved: vi.fn(),
  getReminders: vi.fn(),
  rateCheck: vi.fn(),
  env: { SOCIAL_COMMENTS_ENABLED: true },
}))

vi.mock('../db/index.js', () => ({ db: {}, sql: {} }))
vi.mock('../env.js', () => ({ env: mocks.env }))
vi.mock('../feed/service.js', () => ({
  getFeed: mocks.getFeed,
  getPostDetail: mocks.getPostDetail,
  getSaved: mocks.getSaved,
  getReminders: mocks.getReminders,
}))
vi.mock('../util/rateLimit.js', async (importOriginal) => ({
  ...(await importOriginal<typeof import('../util/rateLimit.js')>()),
  rateLimiter: { check: mocks.rateCheck },
}))

const { feedRoutes } = await import('./feed.js')

const CALLER = '11111111-1111-4111-8111-111111111111'
const ANNOUNCEMENT = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'

function feed(tab: 'following' | 'foryou') {
  return {
    tab,
    generatedAt: 1,
    prevOpenedAt: 0,
    capabilities: { comments: true },
    franchises: [],
    posts: [],
    trending: [],
  }
}

async function app() {
  const instance = Fastify()
  instance.decorate('authenticate', async (req: FastifyRequest, _reply: FastifyReply) => {
    req.user = { id: CALLER, clerkId: 'user_test' }
  })
  await instance.register(feedRoutes)
  await instance.ready()
  return instance
}

beforeEach(() => {
  mocks.env.SOCIAL_COMMENTS_ENABLED = true
  mocks.getFeed.mockReset().mockImplementation(async (_userId: string, tab: 'following' | 'foryou') => feed(tab))
  mocks.getPostDetail.mockReset().mockResolvedValue(null)
  mocks.getSaved.mockReset().mockResolvedValue({ items: [], franchises: [] })
  mocks.getReminders.mockReset().mockResolvedValue({ items: [], franchises: [] })
  mocks.rateCheck.mockReset().mockReturnValue({ allowed: true })
})

describe('GET /me/feed', () => {
  it('serves the Following tab by default, for the caller', async () => {
    const server = await app()
    const res = await server.inject({ method: 'GET', url: '/me/feed' })
    expect(res.statusCode).toBe(200)
    expect(res.json().tab).toBe('following')
    // No `episodes` parameter — every client that predates the kind — means no episode posts.
    expect(mocks.getFeed).toHaveBeenCalledWith(CALLER, 'following', expect.any(Number), null, { episodes: false })
    await server.close()
  })

  it('asks for "Episode N is out" posts only when episodes is 1 or true', async () => {
    const server = await app()
    const asked = async (query: string) => {
      mocks.getFeed.mockClear()
      const res = await server.inject({ method: 'GET', url: `/me/feed?${query}` })
      expect(res.statusCode, query).toBe(200)
      return mocks.getFeed.mock.calls[0]![4]
    }
    expect(await asked('tab=following&episodes=1')).toEqual({ episodes: true })
    expect(await asked('episodes=true')).toEqual({ episodes: true })
    expect(await asked('since=1790000000000&episodes=1')).toEqual({ episodes: true })
    // Anything else is off, never a 400.
    for (const query of ['tab=following', 'episodes=0', 'episodes=false', 'episodes=', 'episodes=yes', 'episodes=TRUE', 'episodes=11', 'episodes=1&episodes=1']) {
      expect(await asked(query), query).toEqual({ episodes: false })
    }
    await server.close()
  })

  it('passes tab=foryou through', async () => {
    const server = await app()
    const res = await server.inject({ method: 'GET', url: '/me/feed?tab=foryou' })
    expect(res.statusCode).toBe(200)
    expect(res.json().tab).toBe('foryou')
    expect(mocks.getFeed).toHaveBeenCalledWith(CALLER, 'foryou', expect.any(Number), null, { episodes: false })
    await server.close()
  })

  it('rejects an unknown tab or an extra parameter with 400 and never composes', async () => {
    const server = await app()
    for (const url of ['/me/feed?tab=x', '/me/feed?tab=', '/me/feed?tab=following&user=someone-else']) {
      const res = await server.inject({ method: 'GET', url })
      expect(res.statusCode).toBe(400)
      expect(res.json()).toEqual({ error: 'invalid request' })
    }
    expect(mocks.getFeed).not.toHaveBeenCalled()
    await server.close()
  })

  it("passes the client's since= anchor through as a number, with the request's clock", async () => {
    const server = await app()
    const before = Date.now()
    const res = await server.inject({ method: 'GET', url: '/me/feed?tab=following&since=1790000000000' })
    expect(res.statusCode).toBe(200)
    const [userId, tab, nowMs, since] = mocks.getFeed.mock.calls[0]!
    expect([userId, tab, since]).toEqual([CALLER, 'following', 1_790_000_000_000])
    expect(nowMs).toBeGreaterThanOrEqual(before)
    // since=0 is well-formed: the service then reads the stored anchor (services/visits.ts clientAnchor).
    expect((await server.inject({ method: 'GET', url: '/me/feed?since=0' })).statusCode).toBe(200)
    expect(mocks.getFeed.mock.calls[1]![3]).toBe(0)
    await server.close()
  })

  it('rejects a since= that is not a plain whole number with 400 and never composes', async () => {
    const server = await app()
    const bad = ['', '-1', '1.5', '1e12', 'abc', '9'.repeat(16)]
    for (const value of bad) {
      const res = await server.inject({ method: 'GET', url: `/me/feed?since=${value}` })
      expect(res.statusCode, value).toBe(400)
    }
    expect(mocks.getFeed).not.toHaveBeenCalled()
    await server.close()
  })

  it('reports the comment capability from the environment', async () => {
    const server = await app()
    expect((await server.inject({ method: 'GET', url: '/me/feed' })).json().capabilities).toEqual({ comments: true })
    mocks.env.SOCIAL_COMMENTS_ENABLED = false
    expect((await server.inject({ method: 'GET', url: '/me/feed' })).json().capabilities).toEqual({ comments: false })
    await server.close()
  })
})

describe('GET /feed/posts/:id', () => {
  const detail = (id: string) => ({
    post: { id },
    franchise: { id: CALLER },
    live: true,
    storyline: [],
    threadSources: [],
    capabilities: { comments: true },
  })

  it('serves a news post for the caller', async () => {
    const id = `news:${ANNOUNCEMENT}`
    mocks.getPostDetail.mockResolvedValue(detail(id))
    const server = await app()
    const res = await server.inject({ method: 'GET', url: `/feed/posts/${id}` })
    expect(res.statusCode).toBe(200)
    expect(res.json().post.id).toBe(id)
    expect(mocks.getPostDetail).toHaveBeenCalledWith(CALLER, id)
    await server.close()
  })

  it('accepts a percent-encoded id', async () => {
    const id = `trailer:${CALLER}:youtube:Ab_c-123`
    mocks.getPostDetail.mockResolvedValue(detail(id))
    const server = await app()
    const res = await server.inject({ method: 'GET', url: `/feed/posts/${encodeURIComponent(id)}` })
    expect(res.statusCode).toBe(200)
    expect(mocks.getPostDetail).toHaveBeenCalledWith(CALLER, id)
    await server.close()
  })

  it('serves an "Episode N is out" post by its ep: id', async () => {
    const id = 'ep:21:3'
    mocks.getPostDetail.mockResolvedValue(detail(id))
    const server = await app()
    const res = await server.inject({ method: 'GET', url: `/feed/posts/${id}` })
    expect(res.statusCode).toBe(200)
    expect(res.json().post.id).toBe(id)
    expect(mocks.getPostDetail).toHaveBeenCalledWith(CALLER, id)
    await server.close()
  })

  it('rejects an id that is not a post with 400', async () => {
    const server = await app()
    for (const id of ['bad', 'ep:21:0', 'ep:21', `news:${ANNOUNCEMENT.toUpperCase()}`, 'catalog:0', `news:${ANNOUNCEMENT}x`]) {
      const res = await server.inject({ method: 'GET', url: `/feed/posts/${encodeURIComponent(id)}` })
      expect(res.statusCode).toBe(400)
      expect(res.json()).toEqual({ error: 'invalid request' })
    }
    expect(mocks.getPostDetail).not.toHaveBeenCalled()
    await server.close()
  })

  it('answers 404 when the post cannot be composed', async () => {
    const server = await app()
    const res = await server.inject({ method: 'GET', url: '/feed/posts/catalog:21' })
    expect(res.statusCode).toBe(404)
    expect(res.json()).toEqual({ error: 'post not found' })
    await server.close()
  })

  it('reports the comment capability from the environment', async () => {
    mocks.env.SOCIAL_COMMENTS_ENABLED = false
    mocks.getPostDetail.mockResolvedValue(detail('catalog:21'))
    const server = await app()
    expect((await server.inject({ method: 'GET', url: '/feed/posts/catalog:21' })).json().capabilities).toEqual({ comments: false })
    await server.close()
  })
})

describe('GET /me/saved and /me/reminders', () => {
  it('serves the caller their own saved posts', async () => {
    const saved = { items: [{ postId: 'catalog:21', savedAt: 5, post: null }], franchises: [] }
    mocks.getSaved.mockResolvedValue(saved)
    const server = await app()
    const res = await server.inject({ method: 'GET', url: '/me/saved' })
    expect(res.statusCode).toBe(200)
    expect(res.json()).toEqual(saved)
    expect(mocks.getSaved).toHaveBeenCalledWith(CALLER)
    await server.close()
  })

  it('serves the caller their own reminders', async () => {
    const reminded = { items: [{ postId: 'catalog:21', remindedAt: 5, post: null }], franchises: [] }
    mocks.getReminders.mockResolvedValue(reminded)
    const server = await app()
    const res = await server.inject({ method: 'GET', url: '/me/reminders' })
    expect(res.statusCode).toBe(200)
    expect(res.json()).toEqual(reminded)
    expect(mocks.getReminders).toHaveBeenCalledWith(CALLER)
    await server.close()
  })
})

describe('authentication', () => {
  it('runs authenticate before every route', async () => {
    const instance = Fastify()
    instance.decorate('authenticate', async (_req: FastifyRequest, reply: FastifyReply) => {
      await reply.code(401).send({ error: 'missing bearer token' })
    })
    await instance.register(feedRoutes)
    await instance.ready()
    for (const url of ['/me/feed', `/feed/posts/news:${ANNOUNCEMENT}`, '/me/saved', '/me/reminders']) {
      expect((await instance.inject({ method: 'GET', url })).statusCode).toBe(401)
    }
    expect(mocks.getFeed).not.toHaveBeenCalled()
    expect(mocks.getPostDetail).not.toHaveBeenCalled()
    expect(mocks.getSaved).not.toHaveBeenCalled()
    expect(mocks.getReminders).not.toHaveBeenCalled()
    await instance.close()
  })
})

describe('the heavy-read budget', () => {
  it('charges /me/feed and /feed/posts/:id to the caller\'s Clerk id, after validation', async () => {
    const server = await app()
    await server.inject({ method: 'GET', url: '/me/feed' })
    await server.inject({ method: 'GET', url: `/feed/posts/news:${ANNOUNCEMENT}` })
    await server.inject({ method: 'GET', url: '/me/feed?tab=x' })
    await server.inject({ method: 'GET', url: '/feed/posts/bad' })
    await server.inject({ method: 'GET', url: '/me/saved' })
    expect(mocks.rateCheck.mock.calls).toEqual([
      ['read', 'user_test'],
      ['read', 'user_test'],
    ])
    await server.close()
  })

  it('answers 429 with Retry-After and composes nothing once it is spent', async () => {
    mocks.rateCheck.mockReturnValue({ allowed: false, retryAfterSec: 30 })
    const server = await app()
    for (const url of ['/me/feed', `/feed/posts/news:${ANNOUNCEMENT}`]) {
      const res = await server.inject({ method: 'GET', url })
      expect(res.statusCode).toBe(429)
      expect(res.headers['retry-after']).toBe('30')
      expect(res.json()).toEqual({ error: 'rate_limited', retryAfter: 30 })
    }
    expect(mocks.getFeed).not.toHaveBeenCalled()
    expect(mocks.getPostDetail).not.toHaveBeenCalled()
    await server.close()
  })
})
