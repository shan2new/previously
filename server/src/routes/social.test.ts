import Fastify, { type FastifyReply, type FastifyRequest } from 'fastify'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { encodeCursor } from '../util/cursor.js'

// The contract of the social routes (docs/api-contract.md, "Social"): validation, status codes,
// the order of the create checks, the rate limit's placement, the comments switch, and that every
// read and write is scoped to the bearer. The services are mocked; the pure rules they rely on
// (content filter, subjects, cursors) run for real.

const mocks = vi.hoisted(() => ({
  // services/comments.ts
  countVisibleComments: vi.fn(),
  deleteOwnComment: vi.fn(),
  episodeRoomStats: vi.fn(),
  fileReport: vi.fn(),
  findReplay: vi.fn(),
  findReplyParent: vi.fn(),
  findReportTarget: vi.fn(),
  findVisibleComment: vi.fn(),
  insertComment: vi.fn(),
  likeComment: vi.fn(),
  listComments: vi.fn(),
  loadCommenterProfile: vi.fn(),
  unlikeComment: vi.fn(),
  // services/socialToggles.ts
  blockTargetExists: vi.fn(),
  deleteBlock: vi.fn(),
  deleteHide: vi.fn(),
  deleteLike: vi.fn(),
  deleteReminder: vi.fn(),
  deleteRating: vi.fn(),
  deleteSave: vi.fn(),
  listBlocks: vi.fn(),
  listHides: vi.fn(),
  putBlock: vi.fn(),
  putHide: vi.fn(),
  putLike: vi.fn(),
  putRating: vi.fn(),
  putReminder: vi.fn(),
  putSave: vi.fn(),
  // social/resolve.ts, services/episodeGate.ts, util/rateLimit.ts
  resolveSubject: vi.fn(),
  resolveFranchise: vi.fn(),
  canonicalSubject: vi.fn(),
  getEpisodeAccess: vi.fn(),
  rateCheck: vi.fn(),
}))
const state = vi.hoisted(() => ({ env: {} as Record<string, unknown>, createdAt: undefined as number | undefined }))

vi.mock('../db/index.js', () => ({ db: {}, sql: {} }))
vi.mock('../env.js', async (importOriginal) => {
  const real = await importOriginal<typeof import('../env.js')>()
  Object.assign(state.env, real.env)
  return { ...real, env: state.env }
})
vi.mock('../services/comments.js', () => ({
  countVisibleComments: mocks.countVisibleComments,
  deleteOwnComment: mocks.deleteOwnComment,
  episodeRoomStats: mocks.episodeRoomStats,
  fileReport: mocks.fileReport,
  findReplay: mocks.findReplay,
  findReplyParent: mocks.findReplyParent,
  findReportTarget: mocks.findReportTarget,
  findVisibleComment: mocks.findVisibleComment,
  insertComment: mocks.insertComment,
  likeComment: mocks.likeComment,
  listComments: mocks.listComments,
  loadCommenterProfile: mocks.loadCommenterProfile,
  unlikeComment: mocks.unlikeComment,
}))
vi.mock('../services/socialToggles.js', () => ({
  blockTargetExists: mocks.blockTargetExists,
  deleteBlock: mocks.deleteBlock,
  deleteHide: mocks.deleteHide,
  deleteLike: mocks.deleteLike,
  deleteReminder: mocks.deleteReminder,
  deleteRating: mocks.deleteRating,
  deleteSave: mocks.deleteSave,
  listBlocks: mocks.listBlocks,
  listHides: mocks.listHides,
  putBlock: mocks.putBlock,
  putHide: mocks.putHide,
  putLike: mocks.putLike,
  putRating: mocks.putRating,
  putReminder: mocks.putReminder,
  putSave: mocks.putSave,
}))
vi.mock('../social/resolve.js', () => ({
  resolveSubject: mocks.resolveSubject,
  resolveFranchise: mocks.resolveFranchise,
  canonicalSubject: mocks.canonicalSubject,
}))
vi.mock('../services/episodeGate.js', () => ({ getEpisodeAccess: mocks.getEpisodeAccess }))
vi.mock('../util/rateLimit.js', async (importOriginal) => {
  const real = await importOriginal<typeof import('../util/rateLimit.js')>()
  return { ...real, rateLimiter: { check: mocks.rateCheck } }
})

const { socialRoutes } = await import('./social.js')

const CALLER = '11111111-1111-4111-8111-111111111111'
const MIRA = '22222222-2222-4222-8222-222222222222'
const FRANCHISE = '33333333-3333-4333-8333-333333333333'
const ANN = '44444444-4444-4444-8444-444444444444'
const COMMENT = '55555555-5555-4555-8555-555555555555'
const PARENT = '66666666-6666-4666-8666-666666666666'
const NEWS = `news:${ANN}`
const EP = 'ep:154587:12'
const TERMS = '2026-09-25'
/** The caller's Clerk id: what every rate limit is keyed on (never users.id). */
const RATE_KEY = 'user_test'

const resolved = { franchiseId: FRANCHISE, franchiseTitle: 'Sakamoto Days' }
const openGate = {
  access: 'open' as const,
  franchiseId: FRANCHISE,
  franchiseTitle: 'Frieren',
  progress: 12,
  aired: { aired: 12, known: true },
}
const profile = { handle: 'dex', displayName: 'Dex', termsVersion: TERMS }
const view = {
  id: COMMENT,
  subject: NEWS,
  author: { id: CALLER, handle: 'dex', displayName: 'Dex' },
  body: 'So good',
  createdAt: 1790330400000,
  parentId: null,
  replyTo: null,
  likeCount: 0,
  liked: false,
  replyCount: 0,
  mine: true,
}

async function app() {
  const instance = Fastify()
  instance.decorate('authenticate', async (req: FastifyRequest, _reply: FastifyReply) => {
    req.user = { id: CALLER, clerkId: RATE_KEY, createdAt: state.createdAt }
  })
  await instance.register(socialRoutes)
  await instance.ready()
  return instance
}

/** Every mocked service that writes. */
const writers = [
  'putLike',
  'deleteLike',
  'putSave',
  'deleteSave',
  'putReminder',
  'deleteReminder',
  'putHide',
  'deleteHide',
  'putRating',
  'deleteRating',
  'putBlock',
  'deleteBlock',
  'insertComment',
  'deleteOwnComment',
  'likeComment',
  'unlikeComment',
  'fileReport',
] as const

function expectNothingWritten() {
  for (const name of writers) expect(mocks[name], name).not.toHaveBeenCalled()
}

beforeEach(() => {
  for (const fn of Object.values(mocks)) fn.mockReset()
  state.env.SOCIAL_COMMENTS_ENABLED = true
  state.env.SOCIAL_TERMS_VERSION = TERMS
  state.env.SOCIAL_AUTO_HIDE_REPORTS = 3
  state.env.SOCIAL_REPORTER_MIN_AGE_HOURS = 24
  state.env.SOCIAL_LIKE_NOTIFY_COOLDOWN_MINUTES = 60
  state.createdAt = undefined
  mocks.rateCheck.mockReturnValue({ allowed: true })
  mocks.resolveSubject.mockResolvedValue(resolved)
  mocks.resolveFranchise.mockResolvedValue(resolved)
  // Every subject is its own canonical one unless a test adopts a catalogue post.
  mocks.canonicalSubject.mockImplementation(async (p: unknown) => p)
  mocks.getEpisodeAccess.mockResolvedValue(openGate)
  mocks.blockTargetExists.mockResolvedValue(true)
  mocks.findReplay.mockResolvedValue({ kind: 'none' })
  mocks.loadCommenterProfile.mockResolvedValue(profile)
  mocks.findReplyParent.mockResolvedValue(null)
  mocks.insertComment.mockResolvedValue({ kind: 'created', comment: view })
  mocks.listComments.mockResolvedValue({ total: 0, items: [], nextCursor: null })
  mocks.countVisibleComments.mockResolvedValue(0)
  mocks.deleteOwnComment.mockResolvedValue('deleted')
  mocks.findVisibleComment.mockResolvedValue({
    id: COMMENT,
    authorId: MIRA,
    subject: NEWS,
    franchiseId: FRANCHISE,
    franchiseTitle: 'Sakamoto Days',
  })
  mocks.findReportTarget.mockResolvedValue({ authorId: MIRA, authorClerkId: 'user_mira', subject: NEWS })
  mocks.fileReport.mockResolvedValue({ inserted: true, reportCount: 1, firstOpenReport: true, autoHidden: false })
  mocks.listHides.mockResolvedValue({ items: [] })
  mocks.listBlocks.mockResolvedValue({ items: [] })
  mocks.episodeRoomStats.mockResolvedValue({
    commentCount: 9,
    likeCount: 3,
    liked: true,
    rating: { count: 4, average: 81.5, yours: 90 },
  })
})

let server: Awaited<ReturnType<typeof app>>
beforeEach(async () => {
  server = await app()
})
afterEach(async () => {
  await server.close()
})

function inject(method: 'GET' | 'PUT' | 'POST' | 'DELETE', url: string, payload?: unknown) {
  return server.inject({ method, url, ...(payload === undefined ? {} : { payload: payload as object }) })
}

// ---------- Toggles ----------

describe('toggles: set-state PUT/DELETE, 204, scoped to the caller', () => {
  it('likes a post and an open episode room, and unlikes', async () => {
    expect((await inject('PUT', '/me/likes', { subject: NEWS })).statusCode).toBe(204)
    expect((await inject('PUT', '/me/likes', { subject: EP })).statusCode).toBe(204)
    const del = await inject('DELETE', '/me/likes', { subject: NEWS })
    expect(del.statusCode).toBe(204)
    expect(del.body).toBe('')
    expect(mocks.putLike.mock.calls).toEqual([
      [CALLER, NEWS],
      [CALLER, EP],
    ])
    expect(mocks.deleteLike).toHaveBeenCalledWith(CALLER, NEWS)
    expect(mocks.getEpisodeAccess).toHaveBeenCalledWith(CALLER, 154587, 12)
    expect(mocks.rateCheck.mock.calls).toEqual([
      ['toggle', RATE_KEY],
      ['toggle', RATE_KEY],
    ])
  })

  it('likes an episode that is out before the viewer has watched it, never one that has not aired', async () => {
    // `ep:` is also Following's "Episode N is out" post: a like shows nothing of the room.
    mocks.getEpisodeAccess.mockResolvedValue({ ...openGate, access: 'unwatched', progress: 11 })
    expect((await inject('PUT', '/me/likes', { subject: EP })).statusCode).toBe(204)
    expect(mocks.putLike).toHaveBeenCalledWith(CALLER, EP)

    mocks.putLike.mockClear()
    mocks.getEpisodeAccess.mockResolvedValue({ ...openGate, access: 'unaired' })
    const unaired = await inject('PUT', '/me/likes', { subject: EP })
    expect(unaired.statusCode).toBe(409)
    expect(unaired.json()).toEqual({ error: 'episode_locked', reason: 'unaired' })
    expect(mocks.putLike).not.toHaveBeenCalled()
  })

  it('saves and hides an episode post once the episode is out, watched or not; a reminder on it is 400', async () => {
    mocks.getEpisodeAccess.mockResolvedValue({ ...openGate, access: 'unwatched', progress: 11, franchiseId: FRANCHISE })
    expect((await inject('PUT', '/me/saves', { postId: EP })).statusCode).toBe(204)
    expect((await inject('PUT', '/me/hides', { kind: 'post', target: EP })).statusCode).toBe(204)
    expect((await inject('DELETE', '/me/saves', { postId: EP })).statusCode).toBe(204)
    expect((await inject('DELETE', '/me/hides', { kind: 'post', target: EP })).statusCode).toBe(204)
    expect(mocks.putSave).toHaveBeenCalledWith(CALLER, EP, FRANCHISE)
    expect(mocks.putHide).toHaveBeenCalledWith(CALLER, 'post', EP)
    expect(mocks.deleteSave).toHaveBeenCalledWith(CALLER, EP)
    expect(mocks.deleteHide).toHaveBeenCalledWith(CALLER, 'post', EP)
    // The episode is resolved by its own gate (aired or not), never as a catalogue post.
    expect(mocks.getEpisodeAccess).toHaveBeenCalledWith(CALLER, 154587, 12)
    expect(mocks.resolveSubject).not.toHaveBeenCalled()

    // An episode that is out has nothing left to be reminded of.
    for (const method of ['PUT', 'DELETE'] as const) {
      const res = await inject(method, '/me/reminders', { postId: EP })
      expect(res.statusCode).toBe(400)
      expect(res.json()).toEqual({ error: 'invalid request' })
    }
    expect(mocks.putReminder).not.toHaveBeenCalled()
    expect(mocks.deleteReminder).not.toHaveBeenCalled()
  })

  it('an episode that has not aired, or that the catalogue does not hold, is no post to save or hide', async () => {
    for (const gate of [{ ...openGate, access: 'unaired' as const }, null]) {
      mocks.getEpisodeAccess.mockResolvedValue(gate)
      for (const [url, payload] of [
        ['/me/saves', { postId: EP }],
        ['/me/hides', { kind: 'post', target: EP }],
      ] as const) {
        const res = await inject('PUT', url, payload)
        expect(res.statusCode, url).toBe(404)
        expect(res.json()).toEqual({ error: 'post not found' })
      }
    }
    expectNothingWritten()
    expect(mocks.rateCheck).not.toHaveBeenCalled()
  })

  it('saves and reminds a post with its franchise, and clears both', async () => {
    for (const path of ['/me/saves', '/me/reminders']) {
      expect((await inject('PUT', path, { postId: NEWS })).statusCode).toBe(204)
      expect((await inject('DELETE', path, { postId: NEWS })).statusCode).toBe(204)
    }
    expect(mocks.putSave).toHaveBeenCalledWith(CALLER, NEWS, FRANCHISE)
    expect(mocks.putReminder).toHaveBeenCalledWith(CALLER, NEWS, FRANCHISE)
    expect(mocks.deleteSave).toHaveBeenCalledWith(CALLER, NEWS)
    expect(mocks.deleteReminder).toHaveBeenCalledWith(CALLER, NEWS)
  })

  it('hides a post, mutes a show (lowercased), lists and clears them', async () => {
    expect((await inject('PUT', '/me/hides', { kind: 'post', target: 'catalog:171018' })).statusCode).toBe(204)
    expect((await inject('PUT', '/me/hides', { kind: 'show', target: FRANCHISE.toUpperCase() })).statusCode).toBe(204)
    expect((await inject('DELETE', '/me/hides', { kind: 'show', target: FRANCHISE })).statusCode).toBe(204)
    expect(mocks.putHide.mock.calls).toEqual([
      [CALLER, 'post', 'catalog:171018'],
      [CALLER, 'show', FRANCHISE],
    ])
    expect(mocks.resolveFranchise).toHaveBeenCalledWith(FRANCHISE)
    expect(mocks.deleteHide).toHaveBeenCalledWith(CALLER, 'show', FRANCHISE)
    const list = await inject('GET', '/me/hides')
    expect(list.statusCode).toBe(200)
    expect(list.json()).toEqual({ items: [] })
    expect(mocks.listHides).toHaveBeenCalledWith(CALLER)
  })

  it('rates an open episode and clears the rating', async () => {
    expect((await inject('PUT', '/me/ratings', { mediaId: 154587, episode: 12, score: 88 })).statusCode).toBe(204)
    expect((await inject('DELETE', '/me/ratings', { mediaId: 154587, episode: 12 })).statusCode).toBe(204)
    expect(mocks.putRating).toHaveBeenCalledWith(CALLER, 154587, 12, 88)
    expect(mocks.deleteRating).toHaveBeenCalledWith(CALLER, 154587, 12)
  })

  it('blocks and unblocks someone, and lists blocks', async () => {
    expect((await inject('PUT', '/me/blocks', { userId: MIRA })).statusCode).toBe(204)
    expect((await inject('DELETE', '/me/blocks', { userId: MIRA })).statusCode).toBe(204)
    expect(mocks.putBlock).toHaveBeenCalledWith(CALLER, MIRA)
    expect(mocks.deleteBlock).toHaveBeenCalledWith(CALLER, MIRA)
    expect(mocks.rateCheck).toHaveBeenCalledWith('block', RATE_KEY)
    expect((await inject('GET', '/me/blocks')).statusCode).toBe(200)
    expect(mocks.listBlocks).toHaveBeenCalledWith(CALLER)
  })

  it('a bad or extra field is 400 and writes nothing', async () => {
    const bad: [string, string, unknown][] = [
      ['PUT', '/me/likes', {}],
      ['PUT', '/me/likes', { subject: 'news:not-a-uuid' }],
      ['PUT', '/me/likes', { subject: `NEWS:${ANN}` }],
      ['PUT', '/me/likes', { subject: NEWS, userId: MIRA }],
      ['DELETE', '/me/likes', { subject: 'ep:1:0' }],
      ['PUT', '/me/saves', { postId: 'ep:1:0' }],
      ['PUT', '/me/saves', { postId: NEWS, franchiseId: FRANCHISE }],
      ['DELETE', '/me/saves', { post: NEWS }],
      ['PUT', '/me/reminders', { postId: 'catalog:0' }],
      ['PUT', '/me/reminders', { postId: EP }],
      ['DELETE', '/me/reminders', {}],
      ['PUT', '/me/hides', { kind: 'post', target: FRANCHISE }],
      ['PUT', '/me/hides', { kind: 'show', target: NEWS }],
      ['PUT', '/me/hides', { kind: 'franchise', target: FRANCHISE }],
      ['PUT', '/me/hides', { kind: 'show', target: FRANCHISE, extra: 1 }],
      ['DELETE', '/me/hides', { kind: 'post' }],
      ['PUT', '/me/ratings', { mediaId: 1, episode: 1, score: 101 }],
      ['PUT', '/me/ratings', { mediaId: 1, episode: 0, score: 50 }],
      ['PUT', '/me/ratings', { mediaId: 1, episode: 1, score: 50.5 }],
      ['PUT', '/me/ratings', { mediaId: '1', episode: 1, score: 50 }],
      ['PUT', '/me/ratings', { mediaId: 1, episode: 100000, score: 50 }],
      ['PUT', '/me/ratings', { mediaId: 1, episode: 1, score: 50, note: 'x' }],
      ['DELETE', '/me/ratings', { mediaId: 1, episode: 1, score: 50 }],
      ['PUT', '/me/blocks', { userId: 'mira' }],
      ['PUT', '/me/blocks', { userId: MIRA, reason: 'x' }],
      ['DELETE', '/me/blocks', {}],
    ]
    for (const [method, url, payload] of bad) {
      const res = await inject(method as 'PUT' | 'DELETE', url, payload)
      expect(res.statusCode, `${method} ${url} ${JSON.stringify(payload)}`).toBe(400)
      expect(res.json()).toEqual({ error: 'invalid request' })
    }
    expectNothingWritten()
    expect(mocks.rateCheck).not.toHaveBeenCalled()
  })

  it('an unknown subject, post, franchise, episode or user is 404 and writes nothing', async () => {
    mocks.resolveSubject.mockResolvedValue(null)
    mocks.resolveFranchise.mockResolvedValue(null)
    mocks.getEpisodeAccess.mockResolvedValue(null)
    mocks.blockTargetExists.mockResolvedValue(false)
    const cases: [string, unknown, string][] = [
      ['/me/likes', { subject: NEWS }, 'subject not found'],
      ['/me/likes', { subject: EP }, 'subject not found'],
      ['/me/saves', { postId: NEWS }, 'post not found'],
      ['/me/reminders', { postId: 'catalog:171018' }, 'post not found'],
      ['/me/hides', { kind: 'post', target: NEWS }, 'post not found'],
      ['/me/hides', { kind: 'show', target: FRANCHISE }, 'franchise not found'],
      ['/me/ratings', { mediaId: 154587, episode: 12, score: 50 }, 'episode not found'],
      ['/me/blocks', { userId: MIRA }, 'user not found'],
    ]
    for (const [url, payload, error] of cases) {
      const res = await inject('PUT', url, payload)
      expect(res.statusCode, url).toBe(404)
      expect(res.json()).toEqual({ error })
    }
    expectNothingWritten()
    expect(mocks.rateCheck).not.toHaveBeenCalled()
  })

  it('a rating on a locked episode room is 409 episode_locked with the reason, unwatched or unaired', async () => {
    mocks.getEpisodeAccess.mockResolvedValue({ ...openGate, access: 'unwatched', progress: 11 })
    const unwatched = await inject('PUT', '/me/ratings', { mediaId: 154587, episode: 12, score: 50 })
    expect(unwatched.statusCode).toBe(409)
    expect(unwatched.json()).toEqual({ error: 'episode_locked', reason: 'unwatched' })

    mocks.getEpisodeAccess.mockResolvedValue({ ...openGate, access: 'unaired' })
    const rating = await inject('PUT', '/me/ratings', { mediaId: 154587, episode: 12, score: 50 })
    expect(rating.statusCode).toBe(409)
    expect(rating.json()).toEqual({ error: 'episode_locked', reason: 'unaired' })

    expectNothingWritten()
    expect(mocks.rateCheck).not.toHaveBeenCalled()
  })

  it('a post like never consults the episode gate', async () => {
    await inject('PUT', '/me/likes', { subject: NEWS })
    expect(mocks.getEpisodeAccess).not.toHaveBeenCalled()
    expect(mocks.resolveSubject).toHaveBeenCalledWith({ kind: 'news', announcementId: ANN })
  })

  it('blocking yourself is 400 self_block', async () => {
    const res = await inject('PUT', '/me/blocks', { userId: CALLER.toUpperCase() })
    expect(res.statusCode).toBe(400)
    expect(res.json()).toEqual({ error: 'self_block' })
    expect(mocks.putBlock).not.toHaveBeenCalled()
  })

  it('a rate-limited toggle is 429 with Retry-After and writes nothing', async () => {
    mocks.rateCheck.mockReturnValue({ allowed: false, retryAfterSec: 17 })
    const res = await inject('PUT', '/me/likes', { subject: NEWS })
    expect(res.statusCode).toBe(429)
    expect(res.headers['retry-after']).toBe('17')
    expect(res.json()).toEqual({ error: 'rate_limited', retryAfter: 17 })
    expect(mocks.putLike).not.toHaveBeenCalled()
  })

  it('removing state is never rate limited', async () => {
    mocks.rateCheck.mockReturnValue({ allowed: false, retryAfterSec: 17 })
    expect((await inject('DELETE', '/me/likes', { subject: NEWS })).statusCode).toBe(204)
    expect((await inject('DELETE', '/me/saves', { postId: NEWS })).statusCode).toBe(204)
    expect(mocks.rateCheck).not.toHaveBeenCalled()
  })
})

// ---------- POST /social/comments ----------

describe('POST /social/comments', () => {
  const draft = { id: COMMENT, subject: NEWS, body: '  So   good\r\n' }

  it('creates: 201 with the view, the normalised body, and one charge of the comment limit', async () => {
    const res = await inject('POST', '/social/comments', draft)
    expect(res.statusCode).toBe(201)
    expect(res.json()).toEqual({ comment: view })
    expect(mocks.findReplay).toHaveBeenCalledWith(COMMENT, CALLER)
    expect(mocks.loadCommenterProfile).toHaveBeenCalledWith(CALLER)
    expect(mocks.rateCheck.mock.calls).toEqual([['comment', RATE_KEY]])
    expect(mocks.insertComment).toHaveBeenCalledWith({
      id: COMMENT,
      userId: CALLER,
      subject: NEWS,
      franchiseId: FRANCHISE,
      franchiseTitle: 'Sakamoto Days',
      body: 'So   good',
      author: { handle: 'dex', displayName: 'Dex' },
      parent: null,
    })
  })

  it('a client uuid in upper case is the same comment', async () => {
    await inject('POST', '/social/comments', { ...draft, id: COMMENT.toUpperCase() })
    expect(mocks.findReplay).toHaveBeenCalledWith(COMMENT, CALLER)
    expect(mocks.insertComment.mock.calls[0]![0].id).toBe(COMMENT)
  })

  it('a replay is 200 with the stored comment, checked first and never charged', async () => {
    mocks.findReplay.mockResolvedValue({ kind: 'replay', comment: view })
    // Even with the profile gone and the limiter shut, a replay answers as it stands.
    mocks.loadCommenterProfile.mockResolvedValue(null)
    mocks.rateCheck.mockReturnValue({ allowed: false, retryAfterSec: 60 })
    const res = await inject('POST', '/social/comments', draft)
    expect(res.statusCode).toBe(200)
    expect(res.json()).toEqual({ comment: view })
    expect(mocks.rateCheck).not.toHaveBeenCalled()
    expect(mocks.loadCommenterProfile).not.toHaveBeenCalled()
    expectNothingWritten()
  })

  it('a replay of a deleted comment is 410, and someone else’s uuid is 409 id_conflict', async () => {
    mocks.findReplay.mockResolvedValue({ kind: 'deleted' })
    const gone = await inject('POST', '/social/comments', draft)
    expect(gone.statusCode).toBe(410)
    expect(gone.json()).toEqual({ error: 'comment deleted' })

    mocks.findReplay.mockResolvedValue({ kind: 'id_conflict' })
    const taken = await inject('POST', '/social/comments', draft)
    expect(taken.statusCode).toBe(409)
    expect(taken.json()).toEqual({ error: 'id_conflict' })
    expectNothingWritten()
  })

  it('a concurrent replay caught at insert is answered like a replay', async () => {
    mocks.insertComment.mockResolvedValue({ kind: 'replay', comment: view })
    const res = await inject('POST', '/social/comments', draft)
    expect(res.statusCode).toBe(200)
    expect(res.json()).toEqual({ comment: view })
  })

  it('no handle (or no display name) is 409 handle_required', async () => {
    for (const p of [null, { ...profile, handle: null }, { ...profile, displayName: null }]) {
      mocks.loadCommenterProfile.mockResolvedValue(p)
      const res = await inject('POST', '/social/comments', draft)
      expect(res.statusCode).toBe(409)
      expect(res.json()).toEqual({ error: 'handle_required' })
    }
    expectNothingWritten()
  })

  it('rules not accepted, or an older version, is 409 terms_required with the current version', async () => {
    for (const termsVersion of [null, '2026-01-01']) {
      mocks.loadCommenterProfile.mockResolvedValue({ ...profile, termsVersion })
      const res = await inject('POST', '/social/comments', draft)
      expect(res.statusCode).toBe(409)
      expect(res.json()).toEqual({ error: 'terms_required', currentVersion: TERMS })
    }
    expectNothingWritten()
  })

  it('an unknown subject is 404', async () => {
    mocks.resolveSubject.mockResolvedValue(null)
    const res = await inject('POST', '/social/comments', draft)
    expect(res.statusCode).toBe(404)
    expect(res.json()).toEqual({ error: 'subject not found' })
    expectNothingWritten()
  })

  it('a locked episode room is 409 episode_locked with the reason', async () => {
    mocks.getEpisodeAccess.mockResolvedValue({ ...openGate, access: 'unwatched' })
    const res = await inject('POST', '/social/comments', { ...draft, subject: EP })
    expect(res.statusCode).toBe(409)
    expect(res.json()).toEqual({ error: 'episode_locked', reason: 'unwatched' })
    expectNothingWritten()
  })

  it('an open episode room posts under the gate’s franchise', async () => {
    const res = await inject('POST', '/social/comments', { ...draft, subject: EP })
    expect(res.statusCode).toBe(201)
    expect(mocks.resolveSubject).not.toHaveBeenCalled()
    expect(mocks.insertComment.mock.calls[0]![0]).toMatchObject({ subject: EP, franchiseTitle: 'Frieren' })
  })

  it('refused content is 422 content_rejected with the reason, spending one refusal and no comment', async () => {
    const cases: [string, string][] = [
      ['   \n\n  ', 'empty'],
      ['x'.repeat(281), 'too_long'],
      ['join us at discord.gg/abc', 'link'],
      ['bad\u0007bell', 'invalid_characters'],
    ]
    for (const [body, reason] of cases) {
      const res = await inject('POST', '/social/comments', { ...draft, body })
      expect(res.statusCode, reason).toBe(422)
      expect(res.json()).toEqual({ error: 'content_rejected', reason })
    }
    expect(mocks.rateCheck.mock.calls).toEqual(cases.map(() => ['rejected', RATE_KEY]))
    expectNothingWritten()
  })

  it('once the hour of refusals is spent, refused content is 429 — the filter cannot be probed', async () => {
    mocks.rateCheck.mockImplementation((action: string) =>
      action === 'rejected' ? { allowed: false, retryAfterSec: 900 } : { allowed: true },
    )
    const res = await inject('POST', '/social/comments', { ...draft, body: 'join us at discord.gg/abc' })
    expect(res.statusCode).toBe(429)
    expect(res.headers['retry-after']).toBe('900')
    expect(res.json()).toEqual({ error: 'rate_limited', retryAfter: 900 })
    // Good content is still judged on its own budget.
    expect((await inject('POST', '/social/comments', draft)).statusCode).toBe(201)
    expect(mocks.insertComment).toHaveBeenCalledTimes(1)
  })

  it('an account younger than a day spends the new-account comment budget', async () => {
    state.createdAt = Date.now() - 60 * 60_000
    expect((await inject('POST', '/social/comments', draft)).statusCode).toBe(201)
    state.createdAt = Date.now() - 25 * 60 * 60_000
    const later = { ...draft, id: PARENT }
    expect((await inject('POST', '/social/comments', later)).statusCode).toBe(201)
    expect(mocks.rateCheck.mock.calls).toEqual([
      ['commentNew', RATE_KEY],
      ['comment', RATE_KEY],
    ])
  })

  it('280 code points of emoji are refused only past 280 code points', async () => {
    const ok = await inject('POST', '/social/comments', { ...draft, body: '🔥'.repeat(280) })
    expect(ok.statusCode).toBe(201)
    const long = await inject('POST', '/social/comments', { ...draft, body: '👍🏽'.repeat(141) })
    expect(long.statusCode).toBe(422)
  })

  it('a parent in another thread (or invisible) is 404 parent not found', async () => {
    mocks.findReplyParent.mockResolvedValue(null)
    const res = await inject('POST', '/social/comments', { ...draft, parentId: PARENT })
    expect(res.statusCode).toBe(404)
    expect(res.json()).toEqual({ error: 'parent not found' })
    expect(mocks.findReplyParent).toHaveBeenCalledWith(PARENT, NEWS, CALLER)
    expectNothingWritten()
  })

  it('a reply carries its parent to the insert', async () => {
    const parent = { id: PARENT, authorId: MIRA, authorHandle: 'mira.k', authorDisplayName: 'Mira' }
    mocks.findReplyParent.mockResolvedValue(parent)
    const res = await inject('POST', '/social/comments', { ...draft, parentId: PARENT })
    expect(res.statusCode).toBe(201)
    expect(mocks.insertComment.mock.calls[0]![0].parent).toEqual(parent)
  })

  it('a null parentId is a top-level comment', async () => {
    expect((await inject('POST', '/social/comments', { ...draft, parentId: null })).statusCode).toBe(201)
    expect(mocks.findReplyParent).not.toHaveBeenCalled()
  })

  it('rate limited: 429 with Retry-After, after every check, and nothing inserted', async () => {
    mocks.rateCheck.mockReturnValue({ allowed: false, retryAfterSec: 42 })
    const res = await inject('POST', '/social/comments', draft)
    expect(res.statusCode).toBe(429)
    expect(res.headers['retry-after']).toBe('42')
    expect(res.json()).toEqual({ error: 'rate_limited', retryAfter: 42 })
    expect(mocks.rateCheck).toHaveBeenCalledWith('comment', RATE_KEY)
    expect(mocks.insertComment).not.toHaveBeenCalled()
  })

  it('a malformed body is 400 and touches nothing', async () => {
    const bad = [
      {},
      { ...draft, id: 'draft-1' },
      { ...draft, subject: 'post:1' },
      { ...draft, body: 5 },
      { ...draft, body: 'x'.repeat(4001) },
      { ...draft, parentId: 'nope' },
      { ...draft, userId: MIRA },
    ]
    for (const payload of bad) {
      const res = await inject('POST', '/social/comments', payload)
      expect(res.statusCode, JSON.stringify(payload).slice(0, 80)).toBe(400)
    }
    expect(mocks.findReplay).not.toHaveBeenCalled()
    expectNothingWritten()
  })
})

// ---------- GET /social/comments ----------

describe('GET /social/comments', () => {
  it('pages a post thread for the caller (top by default, 20)', async () => {
    const page = { total: 1, items: [view], nextCursor: 'abc' }
    mocks.listComments.mockResolvedValue(page)
    const res = await inject('GET', `/social/comments?subject=${encodeURIComponent(NEWS)}`)
    expect(res.statusCode).toBe(200)
    expect(res.json()).toEqual({
      subject: NEWS,
      locked: false,
      access: null,
      total: 1,
      items: [view],
      nextCursor: 'abc',
    })
    expect(mocks.listComments).toHaveBeenCalledWith(CALLER, { subject: NEWS, sort: 'top', cursor: null, limit: 20 })
    expect(mocks.rateCheck.mock.calls).toEqual([['read', RATE_KEY]])
  })

  it('a spent read budget is 429 before any query; a 400 spends nothing', async () => {
    expect((await inject('GET', '/social/comments?subject=nope')).statusCode).toBe(400)
    expect(mocks.rateCheck).not.toHaveBeenCalled()
    mocks.rateCheck.mockReturnValue({ allowed: false, retryAfterSec: 20 })
    const res = await inject('GET', `/social/comments?subject=${encodeURIComponent(NEWS)}`)
    expect(res.statusCode).toBe(429)
    expect(res.headers['retry-after']).toBe('20')
    expect(mocks.rateCheck).toHaveBeenCalledWith('read', RATE_KEY)
    expect(mocks.resolveSubject).not.toHaveBeenCalled()
    expect(mocks.listComments).not.toHaveBeenCalled()
  })

  it('passes a decoded cursor for its own sort', async () => {
    const at = '2026-09-25T10:00:00.123456Z'
    const latest = encodeCursor({ at, id: COMMENT })
    const top = encodeCursor({ at, id: COMMENT, rank: 4 })
    const q = (sort: string, cursor: string) =>
      `/social/comments?subject=${encodeURIComponent(NEWS)}&sort=${sort}&limit=5&cursor=${cursor}`
    expect((await inject('GET', q('latest', latest))).statusCode).toBe(200)
    expect((await inject('GET', q('top', top))).statusCode).toBe(200)
    expect(mocks.listComments.mock.calls).toEqual([
      [CALLER, { subject: NEWS, sort: 'latest', cursor: { at, id: COMMENT }, limit: 5 }],
      [CALLER, { subject: NEWS, sort: 'top', cursor: { at, id: COMMENT, rank: 4 }, limit: 5 }],
    ])
  })

  it('a bad cursor, sort, limit or subject is 400', async () => {
    const s = encodeURIComponent(NEWS)
    const at = '2026-09-25T10:00:00.123456Z'
    const urls = [
      `/social/comments?subject=${s}&cursor=not-a-cursor`,
      `/social/comments?subject=${s}&cursor=${encodeCursor({ at: '2026-09-25T10:00:00Z', id: COMMENT })}`,
      // A cursor from the other sort.
      `/social/comments?subject=${s}&sort=top&cursor=${encodeCursor({ at, id: COMMENT })}`,
      `/social/comments?subject=${s}&sort=latest&cursor=${encodeCursor({ at, id: COMMENT, rank: 2 })}`,
      `/social/comments?subject=${s}&sort=hot`,
      `/social/comments?subject=${s}&limit=0`,
      `/social/comments?subject=${s}&limit=51`,
      `/social/comments?subject=${s}&page=2`,
      '/social/comments?subject=ep%3A1%3A0',
      '/social/comments',
    ]
    for (const url of urls) expect((await inject('GET', url)).statusCode, url).toBe(400)
    expect(mocks.listComments).not.toHaveBeenCalled()
  })

  it('a locked episode room returns no comments, only the global count', async () => {
    mocks.getEpisodeAccess.mockResolvedValue({ ...openGate, access: 'unwatched' })
    mocks.countVisibleComments.mockResolvedValue(37)
    const res = await inject('GET', `/social/comments?subject=${encodeURIComponent(EP)}`)
    expect(res.statusCode).toBe(200)
    expect(res.json()).toEqual({
      subject: EP,
      locked: true,
      access: 'unwatched',
      total: 37,
      items: [],
      nextCursor: null,
    })
    expect(mocks.countVisibleComments).toHaveBeenCalledWith(EP)
    expect(mocks.listComments).not.toHaveBeenCalled()
  })

  it('an open episode room lists with access open', async () => {
    const res = await inject('GET', `/social/comments?subject=${encodeURIComponent(EP)}&sort=latest`)
    expect(res.statusCode).toBe(200)
    expect(res.json()).toMatchObject({ subject: EP, locked: false, access: 'open' })
  })

  it('an unknown subject is 404', async () => {
    mocks.resolveSubject.mockResolvedValue(null)
    const res = await inject('GET', `/social/comments?subject=${encodeURIComponent(NEWS)}`)
    expect(res.statusCode).toBe(404)
    expect(res.json()).toEqual({ error: 'subject not found' })
  })
})

// ---------- Delete, like, report ----------

describe('DELETE /social/comments/:id', () => {
  it('deletes your own comment, and a repeat is still 204', async () => {
    expect((await inject('DELETE', `/social/comments/${COMMENT}`)).statusCode).toBe(204)
    mocks.deleteOwnComment.mockResolvedValue('already_deleted')
    expect((await inject('DELETE', `/social/comments/${COMMENT}`)).statusCode).toBe(204)
    expect(mocks.deleteOwnComment).toHaveBeenCalledWith(COMMENT, CALLER)
  })

  it('someone else’s (or a missing) comment is 404', async () => {
    mocks.deleteOwnComment.mockResolvedValue('not_found')
    const res = await inject('DELETE', `/social/comments/${COMMENT}`)
    expect(res.statusCode).toBe(404)
    expect(res.json()).toEqual({ error: 'comment not found' })
  })

  it('a non-uuid id is 400', async () => {
    expect((await inject('DELETE', '/social/comments/42')).statusCode).toBe(400)
    expect(mocks.deleteOwnComment).not.toHaveBeenCalled()
  })
})

describe('comment likes', () => {
  it('likes a visible comment with the cooldown from env, and unlikes', async () => {
    expect((await inject('PUT', `/social/comments/${COMMENT}/like`)).statusCode).toBe(204)
    expect(mocks.findVisibleComment).toHaveBeenCalledWith(COMMENT, CALLER)
    expect(mocks.rateCheck).toHaveBeenCalledWith('toggle', RATE_KEY)
    const [who, target, opts] = mocks.likeComment.mock.calls[0]!
    expect(who).toBe(CALLER)
    expect(target.id).toBe(COMMENT)
    expect(opts.cooldownMs).toBe(60 * 60_000)
    expect(typeof opts.nowMs).toBe('number')

    expect((await inject('DELETE', `/social/comments/${COMMENT}/like`)).statusCode).toBe(204)
    expect(mocks.unlikeComment).toHaveBeenCalledWith(CALLER, COMMENT)
  })

  it('an invisible comment (missing, deleted, hidden, blocked) is 404', async () => {
    mocks.findVisibleComment.mockResolvedValue(null)
    const res = await inject('PUT', `/social/comments/${COMMENT}/like`)
    expect(res.statusCode).toBe(404)
    expect(res.json()).toEqual({ error: 'comment not found' })
    expect(mocks.likeComment).not.toHaveBeenCalled()
  })

  it('a comment in a locked episode room is 409 episode_locked', async () => {
    mocks.findVisibleComment.mockResolvedValue({
      id: COMMENT,
      authorId: MIRA,
      subject: EP,
      franchiseId: FRANCHISE,
      franchiseTitle: 'Frieren',
    })
    mocks.getEpisodeAccess.mockResolvedValue({ ...openGate, access: 'unwatched' })
    const res = await inject('PUT', `/social/comments/${COMMENT}/like`)
    expect(res.statusCode).toBe(409)
    expect(res.json()).toEqual({ error: 'episode_locked', reason: 'unwatched' })
    expect(mocks.getEpisodeAccess).toHaveBeenCalledWith(CALLER, 154587, 12)
    expect(mocks.likeComment).not.toHaveBeenCalled()
  })

  it('an unlike of a vanished comment is still 204', async () => {
    mocks.unlikeComment.mockResolvedValue(undefined)
    expect((await inject('DELETE', `/social/comments/${PARENT}/like`)).statusCode).toBe(204)
  })
})

describe('POST /social/comments/:id/report', () => {
  it('files a report with the auto-hide threshold and the reporter minimum age from env', async () => {
    const res = await inject('POST', `/social/comments/${COMMENT}/report`, { reason: 'spoiler', note: '  ends  the arc \n' })
    expect(res.statusCode).toBe(204)
    expect(mocks.findReportTarget).toHaveBeenCalledWith(COMMENT, CALLER)
    expect(mocks.rateCheck).toHaveBeenCalledWith('report', RATE_KEY)
    expect(mocks.fileReport).toHaveBeenCalledWith(CALLER, COMMENT, {
      reason: 'spoiler',
      note: 'ends  the arc',
      threshold: 3,
      reporterMinAgeHours: 24,
    })
    // A report on a post thread never consults the episode gate.
    expect(mocks.getEpisodeAccess).not.toHaveBeenCalled()
  })

  it('an empty note is stored as none', async () => {
    await inject('POST', `/social/comments/${COMMENT}/report`, { reason: 'spam', note: '   ' })
    await inject('POST', `/social/comments/${COMMENT}/report`, { reason: 'spam' })
    expect(mocks.fileReport.mock.calls.map((c) => c[2].note)).toEqual([null, null])
  })

  it('reporting your own comment is 409 own_comment', async () => {
    mocks.findReportTarget.mockResolvedValue({ authorId: CALLER, authorClerkId: RATE_KEY, subject: NEWS })
    const res = await inject('POST', `/social/comments/${COMMENT}/report`, { reason: 'spam' })
    expect(res.statusCode).toBe(409)
    expect(res.json()).toEqual({ error: 'own_comment' })
    expect(mocks.fileReport).not.toHaveBeenCalled()
  })

  it('a missing, deleted or blocked-either-way comment is 404, and nothing is spent', async () => {
    // findReportTarget applies the visibility rule: a reporter the author blocked (or who blocked
    // the author) finds nothing, even for a comment id they saw before the block.
    mocks.findReportTarget.mockResolvedValue(null)
    const res = await inject('POST', `/social/comments/${COMMENT}/report`, { reason: 'spam' })
    expect(res.statusCode).toBe(404)
    expect(res.json()).toEqual({ error: 'comment not found' })
    expect(mocks.rateCheck).not.toHaveBeenCalled()
    expect(mocks.fileReport).not.toHaveBeenCalled()
  })

  it('a comment in an episode room that is not open to the reporter is 404 (locked or gone)', async () => {
    mocks.findReportTarget.mockResolvedValue({ authorId: MIRA, authorClerkId: 'user_mira', subject: EP })
    for (const gate of [{ ...openGate, access: 'unwatched' }, { ...openGate, access: 'unaired' }, null]) {
      mocks.getEpisodeAccess.mockResolvedValue(gate)
      const res = await inject('POST', `/social/comments/${COMMENT}/report`, { reason: 'spoiler' })
      expect(res.statusCode).toBe(404)
      expect(res.json()).toEqual({ error: 'comment not found' })
    }
    expect(mocks.getEpisodeAccess).toHaveBeenCalledWith(CALLER, 154587, 12)
    expect(mocks.rateCheck).not.toHaveBeenCalled()
    expect(mocks.fileReport).not.toHaveBeenCalled()
  })

  it('a comment in an OPEN episode room can be reported', async () => {
    mocks.findReportTarget.mockResolvedValue({ authorId: MIRA, authorClerkId: 'user_mira', subject: EP })
    const res = await inject('POST', `/social/comments/${COMMENT}/report`, { reason: 'spoiler' })
    expect(res.statusCode).toBe(204)
    expect(mocks.fileReport).toHaveBeenCalledOnce()
  })

  it('a bad reason or an over-long note is 400', async () => {
    for (const payload of [{ reason: 'boring' }, { reason: 'spam', note: 'x'.repeat(501) }, { reason: 'spam', extra: true }, {}]) {
      expect((await inject('POST', `/social/comments/${COMMENT}/report`, payload)).statusCode).toBe(400)
    }
    expect(mocks.fileReport).not.toHaveBeenCalled()
  })

  it('rate limited: 429 and nothing filed', async () => {
    mocks.rateCheck.mockReturnValue({ allowed: false, retryAfterSec: 3600 })
    const res = await inject('POST', `/social/comments/${COMMENT}/report`, { reason: 'spam' })
    expect(res.statusCode).toBe(429)
    expect(res.headers['retry-after']).toBe('3600')
    expect(mocks.fileReport).not.toHaveBeenCalled()
  })
})

// ---------- The comments switch ----------

describe('SOCIAL_COMMENTS_ENABLED=false', () => {
  it('every /social/comments* route but the own delete, and PUT /me/blocks, are 404 comments disabled; likes and rooms keep working', async () => {
    state.env.SOCIAL_COMMENTS_ENABLED = false
    const routes: [string, string, unknown?][] = [
      ['GET', `/social/comments?subject=${encodeURIComponent(NEWS)}`],
      ['POST', '/social/comments', { id: COMMENT, subject: NEWS, body: 'hi' }],
      ['PUT', `/social/comments/${COMMENT}/like`],
      ['DELETE', `/social/comments/${COMMENT}/like`],
      ['POST', `/social/comments/${COMMENT}/report`, { reason: 'spam' }],
      ['PUT', '/me/blocks', { userId: MIRA }],
    ]
    for (const [method, url, payload] of routes) {
      const res = await inject(method as 'GET', url, payload)
      expect(res.statusCode, `${method} ${url}`).toBe(404)
      expect(res.json()).toEqual({ error: 'comments disabled' })
    }
    expectNothingWritten()

    expect((await inject('PUT', '/me/likes', { subject: NEWS })).statusCode).toBe(204)
    expect((await inject('PUT', '/me/saves', { postId: NEWS })).statusCode).toBe(204)
    expect((await inject('GET', '/social/episodes/154587/12')).statusCode).toBe(200)
  })

  it('still lets the author delete their own comment, and lets anyone read and lift their blocks', async () => {
    state.env.SOCIAL_COMMENTS_ENABLED = false
    const deleted = await inject('DELETE', `/social/comments/${COMMENT}`)
    expect(deleted.statusCode).toBe(204)
    expect(mocks.deleteOwnComment).toHaveBeenCalledWith(COMMENT, CALLER)
    expect((await inject('GET', '/me/blocks')).statusCode).toBe(200)
    expect((await inject('DELETE', '/me/blocks', { userId: MIRA })).statusCode).toBe(204)
    expect(mocks.deleteBlock).toHaveBeenCalledWith(CALLER, MIRA)
  })
})

// ---------- Episode rooms ----------

describe('GET /social/episodes/:mediaId/:episode', () => {
  it('an open room shows its counts, the caller’s like and rating, and the average', async () => {
    const res = await inject('GET', '/social/episodes/154587/12')
    expect(res.statusCode).toBe(200)
    expect(res.json()).toEqual({
      subject: EP,
      franchiseId: FRANCHISE,
      mediaId: 154587,
      episode: 12,
      access: 'open',
      commentCount: 9,
      likeCount: 3,
      liked: true,
      rating: { count: 4, average: 81.5, yours: 90 },
    })
    expect(mocks.getEpisodeAccess).toHaveBeenCalledWith(CALLER, 154587, 12)
    expect(mocks.episodeRoomStats).toHaveBeenCalledWith(CALLER, 154587, 12, EP)
  })

  it('a locked room withholds the average but keeps the count behind "join N comments"', async () => {
    mocks.getEpisodeAccess.mockResolvedValue({ ...openGate, access: 'unaired' })
    const res = await inject('GET', '/social/episodes/154587/12')
    expect(res.statusCode).toBe(200)
    expect(res.json()).toMatchObject({ access: 'unaired', commentCount: 9, rating: { count: 4, average: null, yours: 90 } })
  })

  it('an unknown episode is 404; a malformed one is 400', async () => {
    mocks.getEpisodeAccess.mockResolvedValue(null)
    const missing = await inject('GET', '/social/episodes/154587/12')
    expect(missing.statusCode).toBe(404)
    expect(missing.json()).toEqual({ error: 'episode not found' })
    for (const url of [
      '/social/episodes/0/1',
      '/social/episodes/1/0',
      '/social/episodes/1/100000',
      '/social/episodes/2147483648/1',
      '/social/episodes/01/1',
      '/social/episodes/1e3/1',
      '/social/episodes/abc/1',
    ]) {
      expect((await inject('GET', url)).statusCode, url).toBe(400)
    }
  })
})

// ---------- Adopted catalogue posts: every write and thread read keys on the canonical subject ----------

describe('a catalogue post adopted into a news post', () => {
  const CATALOG = 'catalog:154587'
  const adopt = () =>
    mocks.canonicalSubject.mockImplementation(async (p: { kind: string }) =>
      p.kind === 'catalog' ? { kind: 'news', announcementId: ANN } : p,
    )

  it('likes, saves, reminds and hides under news:<A>, never the stranded catalog:<M>', async () => {
    adopt()
    expect((await inject('PUT', '/me/likes', { subject: CATALOG })).statusCode).toBe(204)
    expect(mocks.canonicalSubject).toHaveBeenCalledWith({ kind: 'catalog', mediaId: 154587 })
    expect(mocks.resolveSubject).toHaveBeenCalledWith({ kind: 'news', announcementId: ANN })
    expect(mocks.putLike).toHaveBeenCalledWith(CALLER, NEWS)

    expect((await inject('PUT', '/me/saves', { postId: CATALOG })).statusCode).toBe(204)
    expect(mocks.putSave).toHaveBeenCalledWith(CALLER, NEWS, FRANCHISE)
    expect((await inject('PUT', '/me/reminders', { postId: CATALOG })).statusCode).toBe(204)
    expect(mocks.putReminder).toHaveBeenCalledWith(CALLER, NEWS, FRANCHISE)
    expect((await inject('PUT', '/me/hides', { kind: 'post', target: CATALOG })).statusCode).toBe(204)
    expect(mocks.putHide).toHaveBeenCalledWith(CALLER, 'post', NEWS)
  })

  it('a DELETE against the old id clears the canonical row and the id as sent', async () => {
    adopt()
    expect((await inject('DELETE', '/me/likes', { subject: CATALOG })).statusCode).toBe(204)
    expect(mocks.deleteLike.mock.calls).toEqual([
      [CALLER, NEWS],
      [CALLER, CATALOG],
    ])
    expect((await inject('DELETE', '/me/saves', { postId: CATALOG })).statusCode).toBe(204)
    expect(mocks.deleteSave.mock.calls).toEqual([
      [CALLER, NEWS],
      [CALLER, CATALOG],
    ])
    expect((await inject('DELETE', '/me/reminders', { postId: CATALOG })).statusCode).toBe(204)
    expect(mocks.deleteReminder.mock.calls).toEqual([
      [CALLER, NEWS],
      [CALLER, CATALOG],
    ])
    expect((await inject('DELETE', '/me/hides', { kind: 'post', target: CATALOG })).statusCode).toBe(204)
    expect(mocks.deleteHide.mock.calls).toEqual([
      [CALLER, 'post', NEWS],
      [CALLER, 'post', CATALOG],
    ])
  })

  it('reads the news thread and names it on the page', async () => {
    adopt()
    const res = await inject('GET', `/social/comments?subject=${encodeURIComponent(CATALOG)}`)
    expect(res.statusCode).toBe(200)
    expect(res.json()).toMatchObject({ subject: NEWS, locked: false })
    expect(mocks.listComments).toHaveBeenCalledWith(CALLER, { subject: NEWS, sort: 'top', cursor: null, limit: 20 })
  })

  it('stores a comment (and checks its parent) under the news thread, answering that subject', async () => {
    adopt()
    const parent = { id: PARENT, authorId: MIRA, authorHandle: 'mira', authorDisplayName: 'Mira' }
    mocks.findReplyParent.mockResolvedValue(parent)
    const res = await inject('POST', '/social/comments', { id: COMMENT, subject: CATALOG, body: 'So good', parentId: PARENT })
    expect(res.statusCode).toBe(201)
    expect(res.json()).toEqual({ comment: view })
    expect(mocks.findReplyParent).toHaveBeenCalledWith(PARENT, NEWS, CALLER)
    expect(mocks.insertComment.mock.calls[0]![0]).toMatchObject({ subject: NEWS, franchiseId: FRANCHISE })
  })

  it('a catalogue post nobody announced keeps its own id, and a DELETE clears it once', async () => {
    expect((await inject('PUT', '/me/likes', { subject: CATALOG })).statusCode).toBe(204)
    expect(mocks.putLike).toHaveBeenCalledWith(CALLER, CATALOG)
    expect((await inject('DELETE', '/me/likes', { subject: CATALOG })).statusCode).toBe(204)
    expect(mocks.deleteLike.mock.calls).toEqual([[CALLER, CATALOG]])
  })
})
