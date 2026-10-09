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
import { startDeletionWorker } from './services/deletionLedger.js'
import { installObservability } from './observability.js'
import { installRuntimePolicy, privateLogger } from './runtimePolicy.js'

export async function buildServer(): Promise<FastifyInstance> {
  // Default access logs include raw URLs/query strings. Aggregate route-pattern telemetry keeps
  // search terms and imported usernames out of logs and avoids unbounded logs at launch.
  const app = Fastify({ logger: privateLogger, disableRequestLogging: true })
  await installRuntimePolicy(app)
  installObservability(app)

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
  let stopDeletionWorker: (() => Promise<void>) | undefined
  app.addHook('onListen', async () => { stopDeletionWorker = startDeletionWorker(app.log) })
  app.addHook('onClose', async () => stopDeletionWorker?.())

  return app
}
