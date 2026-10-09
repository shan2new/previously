import { verifyToken } from '@clerk/backend'
import type { AuthConfig } from './authConfig.js'
import { devBypassAllowed } from './authConfig.js'

export interface Identity {
  clerkId: string
  email?: string | null
}

/** Injectable so the unit tests never reach the network — production passes Clerk's own. */
export type VerifyFn = (
  token: string,
  opts: { jwtKey?: string; secretKey?: string },
) => Promise<{ sub?: string } & Record<string, unknown>>

const clerkVerify: VerifyFn = (token, opts) => verifyToken(token, opts)

/**
 * Resolve a bearer token to an identity, or `null` when it cannot be trusted.
 *
 * Two issuers, deliberately separate:
 *  • `dev:<clerkId>` — the NON-PRODUCTION issuer. Short-circuits before any Clerk call, because a
 *    dev id is not a JWT and must never be sent to Clerk. Only honoured when `devBypassAllowed`.
 *  • anything else — a Clerk session JWT, verified networklessly with `jwtKey` when present.
 *
 * A rejected token always returns `null`: the caller answers 401 without leaking which issuer
 * failed or why.
 */
export async function resolveIdentity(
  token: string,
  cfg: AuthConfig,
  verify: VerifyFn = clerkVerify,
): Promise<Identity | null> {
  if (token.startsWith('dev:')) {
    if (!devBypassAllowed(cfg)) return null
    const clerkId = token.slice('dev:'.length)
    return clerkId ? { clerkId } : null
  }
  // Signature verification with a local PEM alone cannot distinguish a accidentally retained
  // development-instance key. Bind verified claims to the explicit production issuer as well.
  if (cfg.appEnv === 'production' && !cfg.clerkExpectedIssuer) return null
  try {
    const claims = await verify(token, { jwtKey: cfg.clerkJwtKey, secretKey: cfg.clerkSecretKey })
    if (typeof claims.sub !== 'string' || !claims.sub) return null
    if (cfg.clerkExpectedIssuer && claims.iss !== cfg.clerkExpectedIssuer) return null
    const email = (claims as Record<string, unknown>).email as string | undefined
    return { clerkId: claims.sub, email }
  } catch {
    return null
  }
}
