import { gunzipSync } from 'node:zlib'
import Fastify from 'fastify'
import { describe, expect, it } from 'vitest'
import { z } from 'zod'
import { installRuntimePolicy, privateLogger, safeError } from './runtimePolicy.js'

describe('consumer transport and private diagnostics', () => {
  it('compresses large library-shaped JSON and preserves the decoded response', async () => {
    const app = Fastify()
    await installRuntimePolicy(app)
    const body = { franchises: Array.from({ length: 300 }, (_, id) => ({ id, title: 'A previously watched show', episodes: 12 })) }
    app.get('/library', () => body)
    try {
      const compressed = await app.inject({ url: '/library', headers: { 'accept-encoding': 'gzip' } })
      expect(compressed.statusCode).toBe(200)
      expect(compressed.headers['content-encoding']).toBe('gzip')
      expect(JSON.parse(gunzipSync(compressed.rawPayload).toString())).toEqual(body)
      expect(compressed.rawPayload.byteLength).toBeLessThan(JSON.stringify(body).length / 4)
      const plain = await app.inject('/library')
      expect(plain.json()).toEqual(body)
      expect(plain.headers['content-encoding']).toBeUndefined()
    } finally { await app.close() }
  })

  it('keeps provider/SQL secrets out of error responses and emitted logger records', async () => {
    const chunks: string[] = []
    const secret = 'synthetic-private-token-and-email@example.invalid'
    const app = Fastify({ logger: { ...privateLogger, stream: { write: (chunk: string) => { chunks.push(chunk) } } }, disableRequestLogging: true })
    await installRuntimePolicy(app)
    app.get('/failure', () => { throw new Error(`SQL params: ${secret}`) })
    app.post('/validation', (req) => z.object({ count: z.number() }).parse(req.body))
    try {
      const failed = await app.inject({ url: '/failure?email=' + secret, headers: { authorization: 'Bearer ' + secret } })
      expect(failed.statusCode).toBe(500)
      expect(failed.headers['cache-control']).toBe('private, no-store')
      expect(failed.json()).toEqual({ error: 'internal server error' })
      expect(chunks.join('')).not.toContain(secret)
      expect(chunks.join('')).toContain('http.unhandled_error')
      const invalid = await app.inject({ method: 'POST', url: '/validation', payload: { count: secret } })
      expect(invalid.statusCode).toBe(400)
      expect(invalid.json()).toEqual({ error: 'invalid request' })
      expect(JSON.stringify(safeError(new Error(secret)))).not.toContain(secret)
    } finally { await app.close() }
  })
  it('forbids caching account responses even when authorization is missing', async () => {
    const app = Fastify()
    await installRuntimePolicy(app)
    app.get('/me/library', (_req, reply) => reply.code(401).send({ error: 'missing bearer token' }))
    try {
      const response = await app.inject('/me/library')
      expect(response.headers['cache-control']).toBe('private, no-store')
    } finally { await app.close() }
  })

  it('never emits Apple identity proof or authorization code in request or error diagnostics', async () => {
    const chunks: string[] = []
    const identityToken = 'synthetic-sensitive-apple-identity-token'
    const authorizationCode = 'synthetic-sensitive-one-use-apple-code'
    const app = Fastify({ logger: { ...privateLogger, stream: { write: (chunk: string) => { chunks.push(chunk) } } }, disableRequestLogging: true })
    await installRuntimePolicy(app)
    app.delete('/me', (request) => {
      request.log.info({ req: request, body: request.body, event: 'qa.synthetic_deletion' })
      throw new Error(`provider failure ${identityToken} ${authorizationCode}`)
    })
    try {
      const response = await app.inject({ method: 'DELETE', url: '/me', payload: { apple: { identityToken, authorizationCode } } })
      expect(response.statusCode).toBe(500)
      expect(JSON.stringify(response.json())).not.toContain(identityToken)
      expect(chunks.join('')).not.toContain(identityToken)
      expect(chunks.join('')).not.toContain(authorizationCode)
      expect(chunks.join('')).toContain('http.unhandled_error')
    } finally { await app.close() }
  })
})
