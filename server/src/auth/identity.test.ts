import { describe, expect, it, vi } from 'vitest'
import type { AuthConfig, AuthEnvSource } from './authConfig.js'
import { assertAuthConfig, authConfigFromEnv, devBypassAllowed } from './authConfig.js'
import { resolveIdentity, type VerifyFn } from './identity.js'

// Every case builds its config as a literal — no ambient process.env, no network, no DB.
function cfg(over: Partial<AuthConfig> = {}): AuthConfig {
  return { appEnv: 'development', devAuthBypass: false, ...over }
}

/** A verify spy that resolves to the given claims and records how it was called. */
function verifySpy(claims: Record<string, unknown> = { sub: 'user_real' }) {
  return vi.fn<VerifyFn>(async () => claims)
}

describe('resolveIdentity — the dev issuer is non-production', () => {
  it('rejects a dev token in production with the bypass off, without calling Clerk', async () => {
    const verify = verifySpy()
    const id = await resolveIdentity('dev:user_123', cfg({ appEnv: 'production', clerkJwtKey: 'pem' }), verify)
    expect(id).toBeNull()
    expect(verify).not.toHaveBeenCalled()
  })

  it('rejects a dev token in production even when DEV_AUTH_BYPASS is on (defence in depth)', async () => {
    const verify = verifySpy()
    const id = await resolveIdentity(
      'dev:user_123',
      cfg({ appEnv: 'production', devAuthBypass: true, clerkJwtKey: 'pem' }),
      verify,
    )
    expect(id).toBeNull()
    expect(verify).not.toHaveBeenCalled()
  })

  it('accepts a dev token in development when the bypass is on', async () => {
    const id = await resolveIdentity('dev:user_123', cfg({ devAuthBypass: true }), verifySpy())
    expect(id).toEqual({ clerkId: 'user_123' })
  })

  it('rejects an empty dev id', async () => {
    const id = await resolveIdentity('dev:', cfg({ devAuthBypass: true }), verifySpy())
    expect(id).toBeNull()
  })

  it('rejects a dev token in development when the bypass is off, without calling Clerk', async () => {
    const verify = verifySpy()
    const id = await resolveIdentity('dev:user_123', cfg(), verify)
    expect(id).toBeNull()
    expect(verify).not.toHaveBeenCalled()
  })
})

describe('resolveIdentity — real tokens', () => {
  it('returns the claims subject and email, and passes both Clerk keys through', async () => {
    const verify = verifySpy({ sub: 'user_real', email: 'a@b.c', iss: 'https://clerk.example.com' })
    const config = cfg({ appEnv: 'production', clerkJwtKey: 'pem', clerkSecretKey: 'sk', clerkExpectedIssuer: 'https://clerk.example.com' })
    const id = await resolveIdentity('eyJhbGciOi.real.jwt', config, verify)
    expect(id).toEqual({ clerkId: 'user_real', email: 'a@b.c' })
    expect(verify).toHaveBeenCalledWith('eyJhbGciOi.real.jwt', { jwtKey: 'pem', secretKey: 'sk' })
  })

  it.each(['https://test.clerk.accounts.dev', 'https://other.example.com', undefined])(
    'rejects a signature-verified token from another or missing issuer: %s', async (iss) => {
      const verify = verifySpy({ sub: 'user_wrong_instance', iss })
      const config = cfg({ appEnv: 'production', clerkJwtKey: 'leftover-test-pem',
        clerkSecretKey: 'sk_live_configured', clerkExpectedIssuer: 'https://clerk.example.com' })
      await expect(resolveIdentity('signature-verified-token', config, verify)).resolves.toBeNull()
      expect(verify).toHaveBeenCalledOnce()
    },
  )

  it('refuses real production tokens without an explicit instance binding', async () => {
    const verify = verifySpy({ sub: 'user_real', iss: 'https://clerk.example.com' })
    await expect(resolveIdentity('token', cfg({ appEnv: 'production', clerkSecretKey: 'sk' }), verify)).resolves.toBeNull()
    expect(verify).not.toHaveBeenCalled()
  })

  it('returns null when the claims carry no subject', async () => {
    const id = await resolveIdentity('token', cfg(), verifySpy({ email: 'a@b.c' }))
    expect(id).toBeNull()
  })

  it('returns null when verification throws, leaking nothing', async () => {
    const verify = vi.fn<VerifyFn>(async () => {
      throw new Error('jwt expired')
    })
    await expect(resolveIdentity('token', cfg(), verify)).resolves.toBeNull()
  })
})

describe('devBypassAllowed', () => {
  it('is true only outside production, and only when the flag is set', () => {
    expect(devBypassAllowed(cfg({ devAuthBypass: true }))).toBe(true)
    expect(devBypassAllowed(cfg({ appEnv: 'test', devAuthBypass: true }))).toBe(true)
    expect(devBypassAllowed(cfg({ devAuthBypass: false }))).toBe(false)
    expect(devBypassAllowed(cfg({ appEnv: 'production', devAuthBypass: true }))).toBe(false)
  })
})

describe('assertAuthConfig — the boot guard', () => {
  it('throws when production enables the dev issuer', () => {
    expect(() => assertAuthConfig(cfg({ appEnv: 'production', devAuthBypass: true, clerkJwtKey: 'x' }))).toThrow(
      /DEV_AUTH_BYPASS/,
    )
  })

  it('throws when production has no Clerk key at all', () => {
    expect(() => assertAuthConfig(cfg({ appEnv: 'production' }))).toThrow(/CLERK_JWT_KEY/)
  })

  it('passes for a correctly configured production process', () => {
    expect(() => assertAuthConfig(cfg({ appEnv: 'production', clerkJwtKey: 'pem', clerkExpectedIssuer: 'https://clerk.example.com' }))).not.toThrow()
    expect(() => assertAuthConfig(cfg({ appEnv: 'production', clerkSecretKey: 'sk', clerkExpectedIssuer: 'https://clerk.example.com' }))).not.toThrow()
  })

  it.each([undefined, 'http://clerk.example.com', 'https://clerk.example.com/path',
    'https://test.clerk.accounts.dev', 'https://clerk.example.com/']) (
    'rejects an absent or incorrectly configured production issuer: %s', (clerkExpectedIssuer) => {
      expect(() => assertAuthConfig(cfg({ appEnv: 'production', clerkSecretKey: 'sk', clerkExpectedIssuer })))
        .toThrow(/CLERK_EXPECTED_ISSUER/)
    },
  )

  it('never blocks a development process, however it is configured', () => {
    expect(() => assertAuthConfig(cfg({ devAuthBypass: true }))).not.toThrow()
    expect(() => assertAuthConfig(cfg({ appEnv: 'test', devAuthBypass: true }))).not.toThrow()
  })
})

describe('authConfigFromEnv', () => {
  it('maps every field it is allowed to read', () => {
    const source: AuthEnvSource = {
      APP_ENV: 'production',
      DEV_AUTH_BYPASS: true,
      CLERK_JWT_KEY: 'pem',
      CLERK_SECRET_KEY: 'sk',
      CLERK_EXPECTED_ISSUER: 'https://clerk.example.com',
    }
    expect(authConfigFromEnv(source)).toEqual({
      appEnv: 'production',
      devAuthBypass: true,
      clerkJwtKey: 'pem',
      clerkSecretKey: 'sk',
      clerkExpectedIssuer: 'https://clerk.example.com',
    })
  })
})
