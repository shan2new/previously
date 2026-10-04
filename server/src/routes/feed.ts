import type { FastifyPluginAsync, FastifyReply, FastifyRequest } from 'fastify'
import { z } from 'zod'
import { env } from '../env.js'
import { getFeed, getPostDetail, getReminders, getSaved } from '../feed/service.js'
import { feedPostIdSchema } from '../social/subjects.js'
import { rateKeyOf, rateLimiter, sendRateLimited } from '../util/rateLimit.js'

// The Today feed: GET /me/feed, GET /feed/posts/:id, GET /me/saved, GET /me/reminders
// (docs/api-contract.md, "Today feed" and "Post detail, Saved, Reminders"). Every route is scoped
// to the bearer; nothing here writes.

const feedQuery = z
  .object({
    tab: z.enum(['following', 'foryou']).default('following'),
    // The client's visit anchor, ms epoch (digits only). Used when 0 < since ≤ now, else the stored
    // anchor is (services/visits.ts `clientAnchor`); anything that is not a plain number is a 400.
    since: z
      .string()
      .regex(/^[0-9]{1,15}$/)
      .transform(Number)
      .optional(),
    // Opt-in to Following's "Episode N is out" posts: `1` or `true`. Anything else — and its absence,
    // which is every client that predates the `episode` kind — is off, never a 400.
    episodes: z
      .union([z.string(), z.array(z.string())])
      .optional()
      .transform((value) => value === '1' || value === 'true'),
  })
  .strict()
// Fastify has already percent-decoded the segment, so `news%3A<uuid>` and `news:<uuid>` both arrive
// as `news:<uuid>`. An `ep:<mediaId>:<n>` id is Following's "Episode N is out" post.
const postParams = z.object({ id: feedPostIdSchema }).strict()

const INVALID = { error: 'invalid request' } as const

/** The client's comment switch (brief §9), stated by the route so it always follows the env. */
const capabilities = () => ({ comments: env.SOCIAL_COMMENTS_ENABLED })

/**
 * The heavy reads (a full composition per call) spend the caller's `read` budget, after validation
 * and before any query: null when allowed, else the 429 already sent.
 */
function readLimited(req: FastifyRequest, reply: FastifyReply): FastifyReply | null {
  const rate = rateLimiter.check('read', rateKeyOf(req.user!))
  return rate.allowed ? null : sendRateLimited(reply, rate.retryAfterSec)
}

export const feedRoutes: FastifyPluginAsync = async (app) => {
  app.addHook('preHandler', app.authenticate)

  app.get('/me/feed', async (req, reply) => {
    const query = feedQuery.safeParse(req.query ?? {})
    if (!query.success) return reply.code(400).send(INVALID)
    const limited = readLimited(req, reply)
    if (limited) return limited
    const feed = await getFeed(req.user!.id, query.data.tab, Date.now(), query.data.since ?? null, {
      episodes: query.data.episodes,
    })
    return { ...feed, capabilities: capabilities() }
  })

  app.get('/feed/posts/:id', async (req, reply) => {
    const params = postParams.safeParse(req.params)
    if (!params.success) return reply.code(400).send(INVALID)
    const limited = readLimited(req, reply)
    if (limited) return limited
    const detail = await getPostDetail(req.user!.id, params.data.id)
    if (!detail) return reply.code(404).send({ error: 'post not found' })
    return { ...detail, capabilities: capabilities() }
  })

  app.get('/me/saved', async (req) => getSaved(req.user!.id))

  app.get('/me/reminders', async (req) => getReminders(req.user!.id))
}
