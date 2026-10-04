import cors from '@fastify/cors'
import Fastify, { type FastifyInstance } from 'fastify'
import { authenticate } from './auth/clerk.js'
import { env } from './env.js'
import { accountRoutes } from './routes/account.js'
import { discoverRoutes } from './routes/discover.js'
import { feedRoutes } from './routes/feed.js'
import { franchiseRoutes } from './routes/franchises.js'
import { importRoutes } from './routes/import.js'
import { meRoutes } from './routes/me.js'
import { socialRoutes } from './routes/social.js'

export async function buildServer(): Promise<FastifyInstance> {
  const app = Fastify({ logger: true })

  await app.register(cors, {
    origin: env.CORS_ORIGIN === '*' ? true : env.CORS_ORIGIN.split(',').map((s) => s.trim()),
  })

  // Decorate the ROOT instance so the preHandler is visible to all route plugins.
  app.decorate('authenticate', authenticate)

  app.get('/health', async () => ({ ok: true }))

  await app.register(franchiseRoutes)
  await app.register(meRoutes)
  await app.register(feedRoutes)
  await app.register(socialRoutes)
  await app.register(accountRoutes)
  await app.register(discoverRoutes)
  await app.register(importRoutes)

  return app
}
