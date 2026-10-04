import type { FastifyPluginAsync } from 'fastify'
import { z } from 'zod'
import { applyImport, importProgress, previewImport } from '../import/service.js'
import { ImportSourceError } from '../import/sources.js'
import { startPreview, readPreview } from '../import/previews.js'

// History import: `POST /me/import/preview` → `POST /me/import/:id/apply` → `GET /me/import/:id`
// (import/service.ts has the why). The app parses an export file ON THE DEVICE and sends only the
// rows that are watch history — a TV Time export also holds the account's email, comments and IP
// history, none of which belongs on this server.

const tvShow = z.object({
  // Absent (a client that omits nil) reads as null: a show known only by its title.
  tvdbId: z.number().int().positive().nullish().transform((v) => v ?? null),
  title: z.string().max(300).default(''),
  seasons: z.array(z.object({
    number: z.number().int().min(0).max(500),
    watched: z.array(z.number().int().min(0).max(100_000)).max(5_000),
  })).max(300),
  followed: z.boolean().default(false),
  forLater: z.boolean().default(false),
  archived: z.boolean().default(false),
  lastWatchedAt: z.number().int().nonnegative().nullish().transform((v) => v ?? null),
})

const previewBody = z.discriminatedUnion('source', [
  z.object({ source: z.literal('anilist'), username: z.string().trim().min(1).max(60) }),
  z.object({
    source: z.literal('mal'),
    rows: z.array(z.object({
      malId: z.number().int().positive(),
      status: z.string().max(40),
      watched: z.number().int().min(0).max(100_000).default(0),
      title: z.string().max(300).nullish(),
    })).min(1).max(6_000),
  }),
  z.object({ source: z.literal('tvtime'), shows: z.array(tvShow).min(1).max(4_000) }),
])

const idParams = z.object({ id: z.string().uuid() })

/** A user's previews per ten minutes: each one reads an upstream list. */
const PREVIEW_LIMIT = 8
const PREVIEW_WINDOW_MS = 10 * 60_000
const previews = new Map<string, number[]>()

function allowPreview(userId: string, nowMs: number): boolean {
  const recent = (previews.get(userId) ?? []).filter((t) => nowMs - t < PREVIEW_WINDOW_MS)
  if (recent.length >= PREVIEW_LIMIT) {
    previews.set(userId, recent)
    return false
  }
  recent.push(nowMs)
  previews.set(userId, recent)
  if (previews.size > 5_000) previews.delete(previews.keys().next().value!)
  return true
}

export const importRoutes: FastifyPluginAsync = async (app) => {
  app.addHook('preHandler', app.authenticate)

  // A TV Time history is thousands of small numbers: above the 1 MB default, far below a file.
  app.post('/me/import/preview', { bodyLimit: 4 * 1024 * 1024 }, async (req, reply) => {
    const body = previewBody.safeParse(req.body)
    if (!body.success) return reply.code(400).send({ error: 'invalid request' })
    if (!allowPreview(req.user!.id, Date.now())) {
      return reply.code(429).header('Retry-After', '600').send({ error: 'rate_limited', retryAfter: 600 })
    }
    try {
      // Opt-in keeps the synchronous preview useful for small API callers. The app always
      // uses a job, so even thousands of entries fit within normal HTTP timeouts.
      if ((req.query as { async?: string }).async === '1') {
        const job = startPreview(req.user!.id, body.data)
        return job ? reply.code(202).send(job) : reply.code(409).send({ error: 'import_busy' })
      }
      return await previewImport(req.user!.id, body.data)
    } catch (error) {
      if (error instanceof ImportSourceError) {
        // 422 with a machine code: the list is the problem, not the request and not the account.
        return reply.code(error.reason === 'unavailable' ? 503 : 422).send({ error: `import_${error.reason}` })
      }
      throw error
    }
  })

  app.get('/me/import/:id/preview', async (req, reply) => {
    const params = idParams.safeParse(req.params)
    if (!params.success) return reply.code(400).send({ error: 'invalid request' })
    const job = readPreview(req.user!.id, params.data.id)
    return job ?? reply.code(410).send({ error: 'import_expired' })
  })

  app.post('/me/import/:id/apply', async (req, reply) => {
    const params = idParams.safeParse(req.params)
    if (!params.success) return reply.code(400).send({ error: 'invalid request' })
    const progress = await applyImport(req.user!.id, params.data.id)
    if (!progress) return reply.code(410).send({ error: 'import_expired' })
    return progress
  })

  app.get('/me/import/:id', async (req, reply) => {
    const params = idParams.safeParse(req.params)
    if (!params.success) return reply.code(400).send({ error: 'invalid request' })
    const progress = importProgress(req.user!.id, params.data.id)
    if (!progress) return reply.code(410).send({ error: 'import_expired' })
    return progress
  })
}
