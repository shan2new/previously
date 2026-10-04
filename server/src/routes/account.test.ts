import Fastify, { type FastifyReply, type FastifyRequest } from 'fastify'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import type { AccountExport, ProfileResponse } from '../types/api.js'

// The contract of the identity and export routes (docs/api-contract.md, "Identity" and "Account
// export"): validation, status codes, machine codes, the order validate → precondition → rate
// limit → write, and that every call is scoped to the bearer. The DB is never reached: the profile
// and export services are mocked, keeping only their pure helpers (the unique-violation reader and
// the filename) real.

const TERMS_VERSION = '2026-09-25-test'

const state = vi.hoisted(() => ({ env: {} as Record<string, unknown> }))
const mocks = vi.hoisted(() => ({
  getProfile: vi.fn(),
  findHandleOwner: vi.fn(),
  saveProfile: vi.fn(),
  acceptTerms: vi.fn(),
  handleAvailability: vi.fn(),
  buildAccountExport: vi.fn(),
  check: vi.fn(),
}))

vi.mock('../db/index.js', () => ({ db: {}, sql: {} }))
vi.mock('../env.js', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../env.js')>()
  Object.assign(state.env, actual.env, { SOCIAL_TERMS_VERSION: '2026-09-25-test' })
  return { ...actual, env: state.env }
})
vi.mock('../services/profile.js', async (importOriginal) => ({
  ...(await importOriginal<typeof import('../services/profile.js')>()),
  getProfile: mocks.getProfile,
  findHandleOwner: mocks.findHandleOwner,
  saveProfile: mocks.saveProfile,
  acceptTerms: mocks.acceptTerms,
  handleAvailability: mocks.handleAvailability,
}))
vi.mock('../services/export.js', async (importOriginal) => ({
  ...(await importOriginal<typeof import('../services/export.js')>()),
  buildAccountExport: mocks.buildAccountExport,
}))
vi.mock('../util/rateLimit.js', async (importOriginal) => ({
  ...(await importOriginal<typeof import('../util/rateLimit.js')>()),
  rateLimiter: { check: mocks.check },
}))

const { accountRoutes } = await import('./account.js')

const CALLER = '11111111-1111-4111-8111-111111111111'
const OTHER = '22222222-2222-4222-8222-222222222222'
/** The caller's Clerk id: what every rate limit is keyed on (never users.id). */
const RATE_KEY = 'user_test'

function profile(over: Partial<ProfileResponse> = {}): ProfileResponse {
  return {
    userId: CALLER,
    handle: null,
    displayName: null,
    termsAcceptedAt: null,
    termsVersion: null,
    currentTermsVersion: TERMS_VERSION,
    canComment: false,
    ...over,
  }
}

async function app() {
  const instance = Fastify()
  instance.decorate('authenticate', async (req: FastifyRequest, _reply: FastifyReply) => {
    req.user = { id: CALLER, clerkId: 'user_test' }
  })
  await instance.register(accountRoutes)
  await instance.ready()
  return instance
}

/** The current community rules, accepted: identity writes need them. */
const accepted = { termsVersion: TERMS_VERSION, termsAcceptedAt: 1_789_000_000_000 }

beforeEach(() => {
  state.env.SOCIAL_COMMENTS_ENABLED = true
  mocks.getProfile.mockReset().mockResolvedValue(profile(accepted))
  mocks.findHandleOwner.mockReset().mockResolvedValue(null)
  mocks.saveProfile
    .mockReset()
    .mockImplementation(async (_id: string, v: { handle: string; displayName: string }) => profile({ ...v }))
  mocks.acceptTerms
    .mockReset()
    .mockImplementation(async (_id: string, version: string) =>
      profile({ termsVersion: version, termsAcceptedAt: 1_790_000_000_000 }),
    )
  mocks.handleAvailability
    .mockReset()
    .mockImplementation(async (_id: string, raw: string) => ({ handle: raw.toLowerCase(), available: true, reason: null }))
  mocks.buildAccountExport.mockReset()
  mocks.check.mockReset().mockReturnValue({ allowed: true })
})

describe('GET /me/profile', () => {
  it("answers the caller's profile", async () => {
    mocks.getProfile.mockResolvedValue(profile({ handle: 'dex', displayName: 'Dex', canComment: true }))
    const server = await app()
    const res = await server.inject({ method: 'GET', url: '/me/profile' })
    expect(res.statusCode).toBe(200)
    expect(res.json()).toEqual(profile({ handle: 'dex', displayName: 'Dex', canComment: true }))
    expect(mocks.getProfile).toHaveBeenCalledWith(CALLER)
    await server.close()
  })
})

describe('PUT /me/profile', () => {
  it('saves the NORMALISED handle and name for the caller and answers 200 with the profile', async () => {
    const server = await app()
    const res = await server.inject({
      method: 'PUT',
      url: '/me/profile',
      payload: { handle: '  @Mira.K ', displayName: '  Mira​ ' },
    })
    expect(res.statusCode).toBe(200)
    expect(res.json()).toMatchObject({ handle: 'mira.k', displayName: 'Mira' })
    expect(mocks.findHandleOwner).toHaveBeenCalledWith('mira.k')
    expect(mocks.check).toHaveBeenCalledWith('profile', RATE_KEY)
    expect(mocks.saveProfile).toHaveBeenCalledWith(CALLER, { handle: 'mira.k', displayName: 'Mira' })
    await server.close()
  })

  it('409 handle_taken when the unique index refuses the write (a race)', async () => {
    mocks.saveProfile.mockRejectedValue(
      Object.assign(new Error('duplicate key value violates unique constraint "user_profiles_handle_uq"'), {
        code: '23505',
        constraint_name: 'user_profiles_handle_uq',
      }),
    )
    const server = await app()
    const res = await server.inject({ method: 'PUT', url: '/me/profile', payload: { handle: 'dex', displayName: 'Dex' } })
    expect(res.statusCode).toBe(409)
    expect(res.json()).toEqual({ error: 'handle_taken' })
    await server.close()
  })

  it('409 handle_taken before the rate limit when someone else already holds it', async () => {
    mocks.findHandleOwner.mockResolvedValue(OTHER)
    const server = await app()
    const res = await server.inject({ method: 'PUT', url: '/me/profile', payload: { handle: 'dex', displayName: 'Dex' } })
    expect(res.statusCode).toBe(409)
    expect(res.json()).toEqual({ error: 'handle_taken' })
    expect(mocks.check).not.toHaveBeenCalled()
    expect(mocks.saveProfile).not.toHaveBeenCalled()
    await server.close()
  })

  it('lets the caller keep their own handle while changing the name', async () => {
    mocks.getProfile.mockResolvedValue(profile({ ...accepted, handle: 'dex', displayName: 'Dex' }))
    mocks.findHandleOwner.mockResolvedValue(CALLER)
    const server = await app()
    const res = await server.inject({ method: 'PUT', url: '/me/profile', payload: { handle: 'dex', displayName: 'Dexter' } })
    expect(res.statusCode).toBe(200)
    expect(mocks.saveProfile).toHaveBeenCalledWith(CALLER, { handle: 'dex', displayName: 'Dexter' })
    await server.close()
  })

  it('answers a replay of the stored profile without writing or charging the limit', async () => {
    mocks.getProfile.mockResolvedValue(profile({ ...accepted, handle: 'dex', displayName: 'Dex' }))
    const server = await app()
    const res = await server.inject({ method: 'PUT', url: '/me/profile', payload: { handle: '@Dex', displayName: 'Dex' } })
    expect(res.statusCode).toBe(200)
    expect(res.json()).toMatchObject({ handle: 'dex', displayName: 'Dex' })
    expect(mocks.check).not.toHaveBeenCalled()
    expect(mocks.saveProfile).not.toHaveBeenCalled()
    await server.close()
  })

  it.each([
    [{ handle: 'ab', displayName: 'Dex' }, 'invalid_handle', 'length'],
    [{ handle: 'a-b', displayName: 'Dex' }, 'invalid_handle', 'characters'],
    [{ handle: 'd..x', displayName: 'Dex' }, 'invalid_handle', 'dots'],
    [{ handle: '1234', displayName: 'Dex' }, 'invalid_handle', 'no_letter'],
    [{ handle: 'admin', displayName: 'Dex' }, 'invalid_handle', 'reserved'],
    [{ handle: 'dex', displayName: '' }, 'invalid_display_name', 'empty'],
    [{ handle: 'dex', displayName: 'a'.repeat(41) }, 'invalid_display_name', 'too_long'],
    [{ handle: 'dex', displayName: 'Dex\u0007' }, 'invalid_display_name', 'invalid_characters'],
    [{ handle: 'dex', displayName: 'a@b.com' }, 'invalid_display_name', 'at_sign'],
    [{ handle: 'dex', displayName: 'x.com' }, 'invalid_display_name', 'link'],
    [{ handle: 'dex', displayName: '123' }, 'invalid_display_name', 'no_letter'],
    [{ handle: 'dex', displayName: 'Previously Support' }, 'invalid_display_name', 'reserved'],
  ])('422 for %j → %s (%s), writing nothing and spending one refusal', async (payload, error, reason) => {
    const server = await app()
    const res = await server.inject({ method: 'PUT', url: '/me/profile', payload })
    expect(res.statusCode).toBe(422)
    expect(res.json()).toEqual({ error, reason })
    expect(mocks.check.mock.calls).toEqual([['rejected', RATE_KEY]])
    expect(mocks.saveProfile).not.toHaveBeenCalled()
    await server.close()
  })

  it('429 instead of 422 once the hour of refusals is spent — the name filter cannot be probed', async () => {
    mocks.check.mockReturnValue({ allowed: false, retryAfterSec: 600 })
    const server = await app()
    const res = await server.inject({ method: 'PUT', url: '/me/profile', payload: { handle: 'admin', displayName: 'Dex' } })
    expect(res.statusCode).toBe(429)
    expect(res.headers['retry-after']).toBe('600')
    expect(res.json()).toEqual({ error: 'rate_limited', retryAfter: 600 })
    expect(mocks.check).toHaveBeenCalledWith('rejected', RATE_KEY)
    expect(mocks.saveProfile).not.toHaveBeenCalled()
    await server.close()
  })

  it('400 for a body it does not understand, writing nothing', async () => {
    const server = await app()
    for (const payload of [
      {},
      { handle: 'dex' },
      { displayName: 'Dex' },
      { handle: 'dex', displayName: 'Dex', extra: true },
      { handle: 1, displayName: 'Dex' },
      { handle: 'dex', displayName: null },
      { handle: 'x'.repeat(201), displayName: 'Dex' },
    ]) {
      const res = await server.inject({ method: 'PUT', url: '/me/profile', payload })
      expect(res.statusCode, JSON.stringify(payload)).toBe(400)
      expect(res.json()).toEqual({ error: 'invalid request' })
    }
    expect(mocks.saveProfile).not.toHaveBeenCalled()
    await server.close()
  })

  it('429 with Retry-After when the day allowance is spent', async () => {
    mocks.check.mockReturnValue({ allowed: false, retryAfterSec: 3600 })
    const server = await app()
    const res = await server.inject({ method: 'PUT', url: '/me/profile', payload: { handle: 'dex', displayName: 'Dex' } })
    expect(res.statusCode).toBe(429)
    expect(res.headers['retry-after']).toBe('3600')
    expect(res.json()).toEqual({ error: 'rate_limited', retryAfter: 3600 })
    expect(mocks.saveProfile).not.toHaveBeenCalled()
    await server.close()
  })

  it.each([
    ['never accepted', { termsVersion: null, termsAcceptedAt: null }],
    ['accepted an older version', { termsVersion: '2025-01-01', termsAcceptedAt: 1 }],
  ])('409 terms_required (+currentVersion) when the caller has %s, writing nothing', async (_label, terms) => {
    mocks.getProfile.mockResolvedValue(profile(terms))
    const server = await app()
    const res = await server.inject({ method: 'PUT', url: '/me/profile', payload: { handle: 'dex', displayName: 'Dex' } })
    expect(res.statusCode).toBe(409)
    expect(res.json()).toEqual({ error: 'terms_required', currentVersion: TERMS_VERSION })
    expect(mocks.findHandleOwner).not.toHaveBeenCalled()
    expect(mocks.check).not.toHaveBeenCalled()
    expect(mocks.saveProfile).not.toHaveBeenCalled()
    await server.close()
  })

  it('lets a database error that is not a handle conflict surface as a 500', async () => {
    mocks.saveProfile.mockRejectedValue(Object.assign(new Error('connection reset'), { code: '08006' }))
    const server = await app()
    const res = await server.inject({ method: 'PUT', url: '/me/profile', payload: { handle: 'dex', displayName: 'Dex' } })
    expect(res.statusCode).toBe(500)
    await server.close()
  })
})

describe('GET /me/profile/handle', () => {
  it('answers availability for the caller, charged to the lookup limit', async () => {
    mocks.handleAvailability.mockResolvedValue({ handle: 'dex', available: false, reason: 'taken' })
    const server = await app()
    const res = await server.inject({ method: 'GET', url: '/me/profile/handle?handle=%40Dex' })
    expect(res.statusCode).toBe(200)
    expect(res.json()).toEqual({ handle: 'dex', available: false, reason: 'taken' })
    expect(mocks.handleAvailability).toHaveBeenCalledWith(CALLER, '@Dex')
    expect(mocks.check).toHaveBeenCalledWith('lookup', RATE_KEY)
    await server.close()
  })

  it('reports a rule failure with its reason (the real service helper decides)', async () => {
    const { handleAvailability } = await vi.importActual<typeof import('../services/profile.js')>('../services/profile.js')
    mocks.handleAvailability.mockImplementation(handleAvailability)
    const server = await app()
    const res = await server.inject({ method: 'GET', url: '/me/profile/handle?handle=ab' })
    expect(res.statusCode).toBe(200)
    expect(res.json()).toEqual({ handle: 'ab', available: false, reason: 'length' })
    await server.close()
  })

  it('400 without a single handle parameter, before the limiter', async () => {
    const server = await app()
    for (const url of ['/me/profile/handle', '/me/profile/handle?handle=a&handle=b', `/me/profile/handle?handle=${'x'.repeat(201)}`]) {
      const res = await server.inject({ method: 'GET', url })
      expect(res.statusCode, url).toBe(400)
    }
    expect(mocks.check).not.toHaveBeenCalled()
    expect(mocks.handleAvailability).not.toHaveBeenCalled()
    await server.close()
  })

  it('409 terms_required before the limiter when the current rules are not accepted', async () => {
    mocks.getProfile.mockResolvedValue(profile())
    const server = await app()
    const res = await server.inject({ method: 'GET', url: '/me/profile/handle?handle=dex' })
    expect(res.statusCode).toBe(409)
    expect(res.json()).toEqual({ error: 'terms_required', currentVersion: TERMS_VERSION })
    expect(mocks.check).not.toHaveBeenCalled()
    expect(mocks.handleAvailability).not.toHaveBeenCalled()
    await server.close()
  })

  it('429 when the lookup limit is spent', async () => {
    mocks.check.mockReturnValue({ allowed: false, retryAfterSec: 12 })
    const server = await app()
    const res = await server.inject({ method: 'GET', url: '/me/profile/handle?handle=dex' })
    expect(res.statusCode).toBe(429)
    expect(res.headers['retry-after']).toBe('12')
    expect(mocks.handleAvailability).not.toHaveBeenCalled()
    await server.close()
  })
})

describe('POST /me/terms', () => {
  it('stamps the current version for the caller', async () => {
    const server = await app()
    const res = await server.inject({ method: 'POST', url: '/me/terms', payload: { version: TERMS_VERSION } })
    expect(res.statusCode).toBe(200)
    expect(res.json()).toMatchObject({ termsVersion: TERMS_VERSION, termsAcceptedAt: 1_790_000_000_000 })
    expect(mocks.acceptTerms).toHaveBeenCalledWith(CALLER, TERMS_VERSION)
    expect(mocks.check).toHaveBeenCalledWith('profile', RATE_KEY)
    await server.close()
  })

  it('409 terms_version_mismatch with currentVersion for a stale version, writing nothing', async () => {
    const server = await app()
    const res = await server.inject({ method: 'POST', url: '/me/terms', payload: { version: '2025-01-01' } })
    expect(res.statusCode).toBe(409)
    expect(res.json()).toEqual({ error: 'terms_version_mismatch', currentVersion: TERMS_VERSION })
    expect(mocks.acceptTerms).not.toHaveBeenCalled()
    expect(mocks.check).not.toHaveBeenCalled()
    await server.close()
  })

  it('400 for a bad body', async () => {
    const server = await app()
    for (const payload of [{}, { version: '' }, { version: 1 }, { version: TERMS_VERSION, accepted: true }]) {
      const res = await server.inject({ method: 'POST', url: '/me/terms', payload })
      expect(res.statusCode, JSON.stringify(payload)).toBe(400)
    }
    expect(mocks.acceptTerms).not.toHaveBeenCalled()
    await server.close()
  })

  it('429 when the profile allowance is spent', async () => {
    mocks.check.mockReturnValue({ allowed: false, retryAfterSec: 90 })
    const server = await app()
    const res = await server.inject({ method: 'POST', url: '/me/terms', payload: { version: TERMS_VERSION } })
    expect(res.statusCode).toBe(429)
    expect(mocks.acceptTerms).not.toHaveBeenCalled()
    await server.close()
  })
})

describe('SOCIAL_COMMENTS_ENABLED=0', () => {
  it.each([
    ['PUT', '/me/profile', { handle: 'dex', displayName: 'Dex' }],
    ['GET', '/me/profile/handle?handle=dex', undefined],
    ['POST', '/me/terms', { version: TERMS_VERSION }],
  ] as const)('%s %s answers 404 comments disabled, collecting nothing', async (method, url, payload) => {
    state.env.SOCIAL_COMMENTS_ENABLED = false
    const server = await app()
    const res = await server.inject({ method, url, ...(payload ? { payload } : {}) })
    expect(res.statusCode).toBe(404)
    expect(res.json()).toEqual({ error: 'comments disabled' })
    expect(mocks.saveProfile).not.toHaveBeenCalled()
    expect(mocks.acceptTerms).not.toHaveBeenCalled()
    expect(mocks.handleAvailability).not.toHaveBeenCalled()
    expect(mocks.check).not.toHaveBeenCalled()
    await server.close()
  })

  it('keeps GET /me/profile and GET /me/export working', async () => {
    state.env.SOCIAL_COMMENTS_ENABLED = false
    mocks.buildAccountExport.mockResolvedValue({ exportedAt: 1 })
    const server = await app()
    expect((await server.inject({ method: 'GET', url: '/me/profile' })).statusCode).toBe(200)
    expect((await server.inject({ method: 'GET', url: '/me/export' })).statusCode).toBe(200)
    await server.close()
  })
})

describe('GET /me/export', () => {
  const body: AccountExport = {
    exportedAt: Date.UTC(2026, 8, 25, 12),
    account: { id: CALLER, createdAt: 1, email: null, lastOpenedAt: null, prevOpenedAt: null },
    profile: null,
    moderation: null,
    library: { subscriptions: [], progress: [], preferences: null, recommendationFeedback: [], watchSessions: [] },
    social: {
      comments: [],
      likes: [],
      commentLikes: [],
      saves: [],
      reminders: [],
      hides: [],
      ratings: [],
      blocks: [],
      reports: [],
      notifications: [],
    },
  }

  it("answers the caller's export as a no-store JSON attachment named for the day", async () => {
    vi.useFakeTimers({ toFake: ['Date'] })
    vi.setSystemTime(new Date('2026-09-25T23:30:00Z'))
    mocks.buildAccountExport.mockResolvedValue(body)
    const server = await app()
    const res = await server.inject({ method: 'GET', url: '/me/export' })
    vi.useRealTimers()
    expect(res.statusCode).toBe(200)
    expect(res.headers['content-type']).toBe('application/json; charset=utf-8')
    expect(res.headers['content-disposition']).toBe('attachment; filename="previously-export-2026-09-25.json"')
    expect(res.headers['cache-control']).toBe('no-store')
    expect(res.json()).toEqual(body)
    expect(mocks.buildAccountExport).toHaveBeenCalledWith(CALLER, Date.parse('2026-09-25T23:30:00Z'))
    expect(mocks.check).toHaveBeenCalledWith('export', RATE_KEY)
    await server.close()
  })

  it('429 with Retry-After when the hourly allowance is spent, building nothing', async () => {
    mocks.check.mockReturnValue({ allowed: false, retryAfterSec: 1200 })
    const server = await app()
    const res = await server.inject({ method: 'GET', url: '/me/export' })
    expect(res.statusCode).toBe(429)
    expect(res.headers['retry-after']).toBe('1200')
    expect(mocks.buildAccountExport).not.toHaveBeenCalled()
    await server.close()
  })

  it('404 when the account row is gone', async () => {
    mocks.buildAccountExport.mockResolvedValue(null)
    const server = await app()
    const res = await server.inject({ method: 'GET', url: '/me/export' })
    expect(res.statusCode).toBe(404)
    expect(res.json()).toEqual({ error: 'account not found' })
    await server.close()
  })
})

describe('the pure helpers the routes lean on', async () => {
  const { isHandleTakenError, toProfileResponse } = await vi.importActual<typeof import('../services/profile.js')>(
    '../services/profile.js',
  )
  const { exportFilename } = await vi.importActual<typeof import('../services/export.js')>('../services/export.js')

  it('isHandleTakenError reads a 23505 on the handle index, directly or as a cause', () => {
    expect(isHandleTakenError({ code: '23505', constraint_name: 'user_profiles_handle_uq' })).toBe(true)
    expect(isHandleTakenError({ code: '23505' })).toBe(true)
    expect(isHandleTakenError(new Error('wrapped', { cause: { code: '23505', constraint_name: 'user_profiles_handle_uq' } }))).toBe(true)
    expect(isHandleTakenError({ code: '23505', constraint_name: 'some_other_uq' })).toBe(false)
    expect(isHandleTakenError({ code: '23503' })).toBe(false)
    expect(isHandleTakenError(new Error('nope'))).toBe(false)
    expect(isHandleTakenError(null)).toBe(false)
  })

  it('toProfileResponse: canComment needs a handle, a name, the CURRENT rules and comments on', () => {
    const policy = { currentTermsVersion: 'v2', commentsEnabled: true }
    const full = { handle: 'dex', displayName: 'Dex', termsAcceptedAt: new Date(5), termsVersion: 'v2' }
    expect(toProfileResponse(CALLER, full, policy)).toEqual({
      userId: CALLER,
      handle: 'dex',
      displayName: 'Dex',
      termsAcceptedAt: 5,
      termsVersion: 'v2',
      currentTermsVersion: 'v2',
      canComment: true,
    })
    expect(toProfileResponse(CALLER, { ...full, termsVersion: 'v1' }, policy).canComment).toBe(false)
    expect(toProfileResponse(CALLER, { ...full, handle: null }, policy).canComment).toBe(false)
    expect(toProfileResponse(CALLER, { ...full, displayName: null }, policy).canComment).toBe(false)
    expect(toProfileResponse(CALLER, full, { ...policy, commentsEnabled: false }).canComment).toBe(false)
    expect(toProfileResponse(CALLER, null, policy)).toEqual({
      userId: CALLER,
      handle: null,
      displayName: null,
      termsAcceptedAt: null,
      termsVersion: null,
      currentTermsVersion: 'v2',
      canComment: false,
    })
  })

  it('exportFilename is the UTC day', () => {
    expect(exportFilename(Date.parse('2026-09-25T23:59:59Z'))).toBe('previously-export-2026-09-25.json')
    expect(exportFilename(Date.parse('2026-01-01T00:00:00Z'))).toBe('previously-export-2026-01-01.json')
  })
})
