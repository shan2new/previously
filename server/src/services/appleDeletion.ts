import { createClerkClient } from '@clerk/backend'
import { lstat, readFile } from 'node:fs/promises'
import { createRemoteJWKSet, importPKCS8, jwtVerify, SignJWT, type JWTVerifyGetKey } from 'jose'
import { env } from '../env.js'

export type AppleRevocation = 'revoked' | 'manual_required' | 'not_applicable'
export interface AppleDeletionProof { identityToken?: string; authorizationCode?: string }
export interface AppleLinkedUsers {
  getUser(id: string): Promise<{ externalAccounts?: { provider: string; externalId: string }[] }>
}
export interface AppleDeletionConfig { clientId: string; teamId?: string; keyId?: string; privateKeyPath?: string }
interface Options {
  users?: AppleLinkedUsers | null
  config?: AppleDeletionConfig
  fetch?: typeof globalThis.fetch
  keys?: JWTVerifyGetKey
  now?: () => Date
}
export interface PreparedAppleDeletion {
  initial: AppleRevocation
  /** Ephemeral proof only; the caller invokes this after app-data erasure commits. */
  finish(): Promise<AppleRevocation>
}

const APPLE = 'https://appleid.apple.com'
const TIMEOUT_MS = 1800
const keys = createRemoteJWKSet(new URL(`${APPLE}/auth/keys`), {
  timeoutDuration: TIMEOUT_MS, cooldownDuration: 30_000, cacheMaxAge: 3_600_000,
})
const immediate = (outcome: AppleRevocation): PreparedAppleDeletion => ({ initial: outcome, finish: async () => outcome })

async function bounded<T>(task: Promise<T>): Promise<T> {
  let timer: NodeJS.Timeout | undefined
  try {
    return await Promise.race([task, new Promise<never>((_, reject) => {
      timer = setTimeout(() => reject(new Error('Apple deletion lookup unavailable')), TIMEOUT_MS)
    })])
  } finally { clearTimeout(timer) }
}

async function verifiedSubject(token: string, config: AppleDeletionConfig, options: Options): Promise<{ sub: string; nonce?: unknown }> {
  const result = await jwtVerify(token, options.keys ?? keys, {
    issuer: APPLE, audience: config.clientId, algorithms: ['RS256'],
    requiredClaims: ['sub', 'iat', 'exp'], maxTokenAge: '5m', clockTolerance: 30,
    currentDate: options.now?.() ?? new Date(),
  })
  if (typeof result.payload.sub !== 'string' || !result.payload.sub) throw new Error('Apple proof invalid')
  return { sub: result.payload.sub, nonce: result.payload.nonce }
}

/**
 * Read current linked identity before deleting Clerk. Wrong-owner proof never reaches exchange
 * or revocation. All failures are manual fallback; they must not prevent app-data erasure.
 * Neither request proof nor exchanged tokens is logged, cached, journaled or stored in SQL.
 */
export async function prepareAppleDeletion(clerkId: string, proof?: AppleDeletionProof, options: Options = {}): Promise<PreparedAppleDeletion> {
  const config = options.config ?? { clientId: env.APPLE_CLIENT_ID, teamId: env.APPLE_TEAM_ID,
    keyId: env.APPLE_KEY_ID, privateKeyPath: env.APPLE_PRIVATE_KEY_PATH }
  const users = options.users === undefined
    ? env.CLERK_SECRET_KEY?.trim() ? createClerkClient({ secretKey: env.CLERK_SECRET_KEY }).users : null
    : options.users
  if (!users) return immediate('manual_required')
  try {
    const account = await bounded(users.getUser(clerkId))
    if (!Array.isArray(account.externalAccounts)) return immediate('manual_required')
    const linked = account.externalAccounts.filter((item) => item.provider === 'oauth_apple')
    if (linked.length === 0) return immediate('not_applicable')
    if (!proof?.identityToken || !proof.authorizationCode || !config.teamId || !config.keyId || !config.privateKeyPath) {
      return immediate('manual_required')
    }
    const identity = await verifiedSubject(proof.identityToken, config, options)
    if (!linked.some((item) => item.externalId === identity.sub)) return immediate('manual_required')
    // Capture only a verified owner and this request's short-lived code. No token outbox exists.
    let used = false
    return {
      initial: 'manual_required',
      async finish() {
        if (used) return 'manual_required'
        used = true
        try {
          const file = await lstat(config.privateKeyPath!)
          if (!file.isFile() || file.isSymbolicLink() || (file.mode & 0o077) !== 0 || file.size > 16_384) return 'manual_required'
          const privateKey = await importPKCS8(await readFile(config.privateKeyPath!, 'utf8'), 'ES256')
          const now = Math.floor((options.now?.() ?? new Date()).getTime() / 1000)
          const secret = await new SignJWT({}).setProtectedHeader({ alg: 'ES256', kid: config.keyId! })
            .setIssuer(config.teamId!).setSubject(config.clientId).setAudience(APPLE)
            .setIssuedAt(now).setExpirationTime(now + 300).sign(privateKey)
          const fetcher = options.fetch ?? globalThis.fetch
          const exchange = await fetcher(`${APPLE}/auth/token`, {
            method: 'POST', signal: AbortSignal.timeout(TIMEOUT_MS),
            headers: { 'content-type': 'application/x-www-form-urlencoded' },
            body: new URLSearchParams({ client_id: config.clientId, client_secret: secret,
              code: proof.authorizationCode!, grant_type: 'authorization_code' }),
          })
          if (!exchange.ok) return 'manual_required'
          const text = await exchange.text()
          if (text.length > 65_536) return 'manual_required'
          const value = JSON.parse(text) as { id_token?: unknown; refresh_token?: unknown; access_token?: unknown }
          if (typeof value.id_token !== 'string') return 'manual_required'
          const exchanged = await verifiedSubject(value.id_token, config, options)
          if (exchanged.sub !== identity.sub || (identity.nonce != null && exchanged.nonce !== identity.nonce)) return 'manual_required'
          const token = typeof value.refresh_token === 'string' && value.refresh_token ? value.refresh_token
            : typeof value.access_token === 'string' && value.access_token ? value.access_token : null
          if (!token) return 'manual_required'
          const result = await fetcher(`${APPLE}/auth/revoke`, {
            method: 'POST', signal: AbortSignal.timeout(TIMEOUT_MS),
            headers: { 'content-type': 'application/x-www-form-urlencoded' },
            body: new URLSearchParams({ client_id: config.clientId, client_secret: secret, token,
              token_type_hint: value.refresh_token === token ? 'refresh_token' : 'access_token' }),
          })
          return result.status === 200 ? 'revoked' : 'manual_required'
        } catch { return 'manual_required' }
      },
    }
  } catch { return immediate('manual_required') }
}
