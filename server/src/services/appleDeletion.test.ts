import { afterAll, beforeAll, describe, expect, it, vi } from 'vitest'
import { mkdtemp, writeFile, chmod, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { createLocalJWKSet, exportJWK, exportPKCS8, generateKeyPair, jwtVerify, SignJWT } from 'jose'
import { prepareAppleDeletion, type AppleDeletionConfig } from './appleDeletion.js'

const APPLE = 'https://appleid.apple.com'
const SUBJECT = 'synthetic-apple-owner'
const NOW = new Date('2026-10-06T12:00:00Z')
let directory: string
let config: AppleDeletionConfig
let apple: Awaited<ReturnType<typeof generateKeyPair>>
let client: Awaited<ReturnType<typeof generateKeyPair>>
let keys: ReturnType<typeof createLocalJWKSet>
const users = { getUser: async () => ({ externalAccounts: [{ provider: 'oauth_apple', externalId: SUBJECT }] }) }
const payload = () => ({ identityToken: '', authorizationCode: 'synthetic-one-use-code' })
async function token(overrides: Record<string, unknown> = {}) {
  return new SignJWT({ sub: SUBJECT, iss: APPLE, aud: 'com.cognipin.previously',
    iat: NOW.getTime() / 1000, exp: NOW.getTime() / 1000 + 300, nonce: 'synthetic-nonce', ...overrides })
    .setProtectedHeader({ alg: 'RS256', kid: 'synthetic-apple-key' }).sign(apple.privateKey)
}
function options(fetcher: typeof fetch) { return { users, config, keys, fetch: fetcher, now: () => NOW } }
beforeAll(async () => {
  directory = await mkdtemp(join(tmpdir(), 'previously_qa_apple_keys_'))
  apple = await generateKeyPair('RS256', { extractable: true })
  client = await generateKeyPair('ES256', { extractable: true })
  keys = createLocalJWKSet({ keys: [{ ...await exportJWK(apple.publicKey), kid: 'synthetic-apple-key', alg: 'RS256', use: 'sig' }] })
  const path = join(directory, 'synthetic.p8')
  await writeFile(path, await exportPKCS8(client.privateKey), { mode: 0o600 })
  config = { clientId: 'com.cognipin.previously', teamId: 'SYNTHETIC1', keyId: 'SYNTHETIC2', privateKeyPath: path }
})
afterAll(async () => { await rm(directory, { recursive: true, force: true }) })

describe('fresh Apple grant revocation for account deletion', () => {
  it('reports not_applicable only after a current linked-account lookup proves no Apple connection', async () => {
    const fetcher = vi.fn<typeof fetch>()
    const prepared = await prepareAppleDeletion('clerk-owner', undefined,
      { ...options(fetcher), users: { getUser: async () => ({ externalAccounts: [{ provider: 'oauth_google', externalId: 'google-owner' }] }) } })
    expect(prepared.initial).toBe('not_applicable')
    expect(await prepared.finish()).toBe('not_applicable')
    expect(fetcher).not.toHaveBeenCalled()
  })
  it.each([undefined, { identityToken: 'unused-token' }, { identityToken: '', authorizationCode: '' }])('missing fresh code is manual fallback and makes no Apple request', async (proof) => {
    const fetcher = vi.fn<typeof fetch>()
    const prepared = await prepareAppleDeletion('clerk-owner', proof, options(fetcher))
    expect(await prepared.finish()).toBe('manual_required')
    expect(fetcher).not.toHaveBeenCalled()
  })
  it('keeps manual fallback when current Clerk linkage is unavailable', async () => {
    const fetcher = vi.fn<typeof fetch>()
    const prepared = await prepareAppleDeletion('clerk-owner', payload(), { ...options(fetcher), users: {
      getUser: async () => { throw new Error('synthetic provider outage') },
    } })
    expect(await prepared.finish()).toBe('manual_required')
    expect(fetcher).not.toHaveBeenCalled()
  })
  it('never exchanges or revokes a correctly signed proof owned by another linked Apple account', async () => {
    const fetcher = vi.fn<typeof fetch>()
    const prepared = await prepareAppleDeletion('clerk-owner', { ...payload(), identityToken: await token({ sub: 'other-owner' }) }, options(fetcher))
    expect(await prepared.finish()).toBe('manual_required')
    expect(fetcher).not.toHaveBeenCalled()
  })
  it.each([{ aud: 'other-app' }, { iss: 'https://untrusted.invalid' }, { exp: NOW.getTime() / 1000 - 60 },
    { iat: NOW.getTime() / 1000 - 600 }, { iat: NOW.getTime() / 1000 + 60 }])('rejects invalid audience/issuer/freshness before exchange', async (claims) => {
    const fetcher = vi.fn<typeof fetch>()
    const prepared = await prepareAppleDeletion('clerk-owner', { ...payload(), identityToken: await token(claims) }, options(fetcher))
    expect(await prepared.finish()).toBe('manual_required')
    expect(fetcher).not.toHaveBeenCalled()
  })
  it('rejects a tampered signature without calling token endpoints', async () => {
    const original = await token()
    const pieces = original.split('.')
    pieces[2] = `${pieces[2]!.startsWith('A') ? 'B' : 'A'}${pieces[2]!.slice(1)}`
    const fetcher = vi.fn<typeof fetch>()
    const prepared = await prepareAppleDeletion('clerk-owner', { ...payload(), identityToken: pieces.join('.') }, options(fetcher))
    expect(await prepared.finish()).toBe('manual_required')
    expect(fetcher).not.toHaveBeenCalled()
  })
  it('exchanges only after commit-stage finish, verifies owner again, then revokes the refresh grant', async () => {
    const proof = { ...payload(), identityToken: await token() }
    const fetcher = vi.fn<typeof fetch>().mockImplementation(async (input, init) => {
      const form = init!.body as URLSearchParams
      const secret = await jwtVerify(form.get('client_secret')!, client.publicKey,
        { issuer: 'SYNTHETIC1', audience: APPLE, currentDate: NOW, algorithms: ['ES256'] })
      expect(secret.payload.sub).toBe(config.clientId)
      expect(secret.payload.exp! - secret.payload.iat!).toBe(300)
      expect(form.get('client_id')).toBe(config.clientId)
      expect(init!.signal).toBeInstanceOf(AbortSignal)
      if (String(input).endsWith('/auth/token')) {
        expect(form.get('code')).toBe(proof.authorizationCode)
        expect(form.get('grant_type')).toBe('authorization_code')
        return new Response(JSON.stringify({ id_token: await token(), refresh_token: 'synthetic-refresh', access_token: 'synthetic-access' }))
      }
      expect(String(input)).toBe(`${APPLE}/auth/revoke`)
      expect(form.get('token')).toBe('synthetic-refresh')
      expect(form.get('token_type_hint')).toBe('refresh_token')
      return new Response(null, { status: 200 })
    })
    const prepared = await prepareAppleDeletion('clerk-owner', proof, options(fetcher))
    expect(prepared.initial).toBe('manual_required')
    expect(fetcher).not.toHaveBeenCalled()
    expect(await prepared.finish()).toBe('revoked')
    expect(await prepared.finish()).toBe('manual_required')
    expect(fetcher).toHaveBeenCalledTimes(2)
  })
  it.each([{ sub: 'other-owner' }, { nonce: 'other-nonce' }, { aud: 'other-app' }])('does not revoke when exchanged proof changes identity or binding', async (claims) => {
    const fetcher = vi.fn<typeof fetch>().mockResolvedValue(new Response(JSON.stringify({ id_token: await token(claims), refresh_token: 'do-not-revoke' })))
    const prepared = await prepareAppleDeletion('clerk-owner', { ...payload(), identityToken: await token() }, options(fetcher))
    expect(await prepared.finish()).toBe('manual_required')
    expect(fetcher).toHaveBeenCalledTimes(1)
  })
  it.each([400, 503])('treats exchanged code replay or provider outage as manual fallback', async (status) => {
    const fetcher = vi.fn<typeof fetch>().mockResolvedValue(new Response('{"error":"invalid_grant"}', { status }))
    const prepared = await prepareAppleDeletion('clerk-owner', { ...payload(), identityToken: await token() }, options(fetcher))
    expect(await prepared.finish()).toBe('manual_required')
    expect(fetcher).toHaveBeenCalledTimes(1)
  })
  it('keeps manual outcome if the revoke receipt fails after a successful exchange', async () => {
    const fetcher = vi.fn<typeof fetch>().mockResolvedValueOnce(new Response(JSON.stringify({ id_token: await token(), refresh_token: 'synthetic-refresh' })))
      .mockRejectedValueOnce(new Error('synthetic lost revocation response'))
    const prepared = await prepareAppleDeletion('clerk-owner', { ...payload(), identityToken: await token() }, options(fetcher))
    expect(await prepared.finish()).toBe('manual_required')
    expect(fetcher).toHaveBeenCalledTimes(2)
  })
  it('can revoke the access token when Apple provides no refresh token', async () => {
    const fetcher = vi.fn<typeof fetch>().mockResolvedValueOnce(new Response(JSON.stringify({ id_token: await token(), access_token: 'synthetic-access' })))
      .mockImplementationOnce(async (_url, init) => {
        expect((init!.body as URLSearchParams).get('token_type_hint')).toBe('access_token')
        return new Response(null, { status: 200 })
      })
    const prepared = await prepareAppleDeletion('clerk-owner', { ...payload(), identityToken: await token() }, options(fetcher))
    expect(await prepared.finish()).toBe('revoked')
  })
  it('rejects a nonprivate signing key file without provider exchange', async () => {
    const path = join(directory, 'unsafe.p8')
    await writeFile(path, await exportPKCS8(client.privateKey), { mode: 0o644 }); await chmod(path, 0o644)
    const fetcher = vi.fn<typeof fetch>()
    const prepared = await prepareAppleDeletion('clerk-owner', { ...payload(), identityToken: await token() },
      { ...options(fetcher), config: { ...config, privateKeyPath: path } })
    expect(await prepared.finish()).toBe('manual_required')
    expect(fetcher).not.toHaveBeenCalled()
  })
})
