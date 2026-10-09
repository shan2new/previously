import compress from '@fastify/compress'
import type { FastifyInstance } from 'fastify'
import { ZodError } from 'zod'

/** Error messages can contain SQL parameters, tokens or provider responses. Log frames only. */
export function safeError(error: unknown) {
  const value = error as { name?: unknown; code?: unknown; stack?: unknown } | null
  const safeLabel = (label: unknown) => typeof label === 'string' && /^[A-Za-z0-9_.-]{1,64}$/.test(label) ? label : undefined
  return { type: safeLabel(value?.name) ?? 'Error', code: safeLabel(value?.code), message: 'error details redacted',
    stack: typeof value?.stack === 'string' ? value.stack.split('\n').slice(1, 9)
      .filter((line) => /^\s+at /.test(line)).map((line) => line.slice(0, 300)).join('\n') : '' }
}

export const privateLogger = {
  redact: { paths: ['authorization', 'token', 'secret', 'email', 'userId', 'clerkId', 'body',
    'req.headers', 'req.body', 'req.query', 'request.headers', 'request.body'], censor: '[redacted]' },
  serializers: {
    err: safeError,
    req: (req: { method?: string; routeOptions?: { url?: string } }) => ({ method: req.method, route: req.routeOptions?.url }),
  },
}

export async function installRuntimePolicy(app: FastifyInstance): Promise<void> {
  app.addHook('onSend', async (req, reply, payload) => {
    const route = req.routeOptions.url ?? ''
    if (req.headers.authorization || /^\/(me|social|account|internal)(?:\/|$)/.test(route)) {
      reply.header('Cache-Control', 'private, no-store')
    }
    return payload
  })
  // gzip level 1 avoids large catalogue/library responses consuming the home uplink. Incoming
  // compressed bodies are unsupported; this also avoids accepting decompression bombs.
  await app.register(compress, { encodings: ['gzip', 'deflate'], threshold: 1024,
    globalDecompression: false, zlibOptions: { level: 1 } })
  app.setErrorHandler((error, req, reply) => {
    const code = (error as { statusCode?: unknown } | null)?.statusCode
    const status = error instanceof ZodError ? 400 : typeof code === 'number' && code >= 400 && code < 500 ? code : 500
    if (status >= 500) req.log.error({ event: 'http.unhandled_error', err: error, route: req.routeOptions.url, requestId: req.id }, 'Request failed')
    return reply.code(status).send({ error: status >= 500 ? 'internal server error' : 'invalid request' })
  })
}
