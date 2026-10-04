import type { FastifyPluginAsync } from 'fastify'
import { z } from 'zod'
import { decodeGenreCursor, genreByKey } from '../discover/genres.js'
import { suggestionSource } from '../services/audience.js'
import { getDiscoverGenrePage, getDiscoverGenres } from '../services/discover.js'
import type { DiscoverGenrePage, DiscoverGenresResponse } from '../types/api.js'

// Discover's genre browse: GET /discover/genres, GET /discover/genres/:key
// (docs/api-contract.md, "Discover: genres"; server spec §10.2).
//
// Every input is safeParse'd: a bad source, limit or cursor answers 400 and reaches no service (a
// thrown ZodError would be a 500 — there is no error handler). Unknown query keys are ignored, as on
// the other list routes (/franchises/trending, /me/recommendations); their VALUES are validated.
//
// With no `source` the viewer's AUDIENCE is the catalogue browsed (services/audience.ts) — All only
// for a viewer whose audience is both; an explicit one wins. The response's `source` says which was used.

const sourceSchema = z.enum(['anilist', 'tmdb'])

const listQuery = z.object({ source: sourceSchema.optional() })

const pageParams = z.object({ key: z.string().min(1).max(64) })
const pageQuery = z.object({
  source: sourceSchema.optional(),
  limit: z.coerce.number().int().min(1).max(50).default(24),
  cursor: z.string().min(1).max(128).optional(),
})

export const discoverRoutes: FastifyPluginAsync = async (app) => {
  app.addHook('preHandler', app.authenticate)

  app.get('/discover/genres', async (req, reply) => {
    const query = listQuery.safeParse(req.query)
    if (!query.success) return reply.code(400).send({ error: 'invalid request' })
    const body: DiscoverGenresResponse = await getDiscoverGenres(await suggestionSource(req.user!.id, query.data.source))
    return body
  })

  app.get('/discover/genres/:key', async (req, reply) => {
    const params = pageParams.safeParse(req.params)
    const query = pageQuery.safeParse(req.query)
    if (!params.success || !query.success) return reply.code(400).send({ error: 'invalid request' })

    const def = genreByKey(params.data.key)
    if (!def) return reply.code(404).send({ error: 'genre not found' })

    let offset = 0
    if (query.data.cursor !== undefined) {
      const decoded = decodeGenreCursor(query.data.cursor)
      if (decoded === null) return reply.code(400).send({ error: 'invalid request' })
      offset = decoded
    }

    const body: DiscoverGenrePage = await getDiscoverGenrePage(req.user!.id, def, {
      source: await suggestionSource(req.user!.id, query.data.source),
      limit: query.data.limit,
      offset,
    })
    return body
  })
}
