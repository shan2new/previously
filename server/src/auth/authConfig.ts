import { env } from '../env.js'

export type AppEnv = 'development' | 'test' | 'production'

/**
 * Everything the identity layer is allowed to know about the environment. Snapshotting it into a
 * plain value (instead of reading `env` at each decision site) is what makes the production rule
 * unit-testable without touching `process.env`.
 */
export interface AuthConfig {
  appEnv: AppEnv
  devAuthBypass: boolean
  clerkJwtKey?: string
  clerkSecretKey?: string
  clerkExpectedIssuer?: string
}

/** The subset of `env` this module reads. Declared structurally so tests can pass a literal. */
export interface AuthEnvSource {
  APP_ENV: AppEnv
  DEV_AUTH_BYPASS: boolean
  CLERK_JWT_KEY?: string
  CLERK_SECRET_KEY?: string
  CLERK_EXPECTED_ISSUER?: string
}

export function authConfigFromEnv(e: AuthEnvSource = env): AuthConfig {
  return {
    appEnv: e.APP_ENV,
    devAuthBypass: e.DEV_AUTH_BYPASS,
    clerkJwtKey: e.CLERK_JWT_KEY,
    clerkSecretKey: e.CLERK_SECRET_KEY,
    clerkExpectedIssuer: e.CLERK_EXPECTED_ISSUER,
  }
}

/**
 * The dev bypass is a NON-PRODUCTION ISSUER, not a feature flag: a `dev:` token is not a JWT and
 * never will be, so production must reject it whatever `DEV_AUTH_BYPASS` says. Both halves of the
 * condition matter — the env gate is the security boundary, the flag is the local convenience.
 */
export function devBypassAllowed(c: AuthConfig): boolean {
  return c.appEnv !== 'production' && c.devAuthBypass
}

/**
 * Boot guard — fail closed, loudly, at deploy time rather than silently accepting bad tokens.
 * Throws when a production process is configured in a way that cannot be safe:
 *  (a) it enables the dev issuer (a misconfiguration, not a no-op), or
 *  (b) it has no Clerk key at all, so nothing could verify a real token.
 */
export function assertAuthConfig(c: AuthConfig): void {
  if (c.appEnv !== 'production') return
  if (c.devAuthBypass) {
    throw new Error(
      'Refusing to start: APP_ENV=production with DEV_AUTH_BYPASS enabled. ' +
        'The dev bearer issuer must never be configured on a production host — unset DEV_AUTH_BYPASS (or set it to 0).',
    )
  }
  if (!c.clerkJwtKey && !c.clerkSecretKey) {
    throw new Error(
      'Refusing to start: APP_ENV=production with neither CLERK_JWT_KEY nor CLERK_SECRET_KEY set. ' +
        'Nothing could verify a session token, so every request would be rejected.',
    )
  }
  let issuer: URL
  try { issuer = new URL(c.clerkExpectedIssuer ?? '') }
  catch { throw new Error('Production requires CLERK_EXPECTED_ISSUER from its Clerk instance.') }
  if (issuer.protocol !== 'https:' || issuer.origin !== c.clerkExpectedIssuer
    || issuer.hostname.endsWith('.clerk.accounts.dev')) {
    throw new Error('CLERK_EXPECTED_ISSUER must be the exact production HTTPS origin.')
  }
}
