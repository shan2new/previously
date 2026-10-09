import { assertAuthConfig, authConfigFromEnv } from './auth/authConfig.js'
import { env } from './env.js'
import { buildServer } from './server.js'
import { assertSocialConfig, socialConfigSummary } from './socialConfig.js'
import { startCron } from './sync/cron.js'
import { sql } from './db/index.js'
import { reconcileIndependentDeletions, snapshotIndependentDeletions } from './services/deletionLedger.js'
import { assertReleaseConfig } from './releaseConfig.js'

// Fail closed BEFORE anything is built: a production process that enables the dev bearer issuer,
// or that has no way to verify a real Clerk token, or that switches the social rate limits off,
// must not open a pool or a socket. Runs ahead of buildServer() so the reason is the first thing
// printed rather than the second failure in a chain.
try {
  assertAuthConfig(authConfigFromEnv())
  assertSocialConfig()
  assertReleaseConfig(env)
} catch (err) {
  console.error(err instanceof Error ? err.message : err)
  process.exit(1)
}

const app = await buildServer()
let stopCron: (() => Promise<void>) | undefined
let shuttingDown = false
const shutdown = async () => {
  if (shuttingDown) return
  shuttingDown = true
  app.log.info({ event: 'runtime.shutdown_started' })
  // Stop accepting new work, drain HTTP/deletion jobs, then release this process's pool. Never
  // restart the machine's shared PostgreSQL or tunnel as part of an app release.
  const deadline = setTimeout(() => {
    app.log.error({ event: 'runtime.shutdown_deadline' })
    process.exit(1)
  }, 30_000)
  try {
    await Promise.all([stopCron?.(), app.close()])
    await sql.end({ timeout: 5 })
    clearTimeout(deadline)
    process.exit(0)
  } catch (err) {
    app.log.error({ event: 'runtime.shutdown_failed', err }, 'Shutdown failed')
    clearTimeout(deadline)
    process.exit(1)
  }
}
process.once('SIGTERM', () => { void shutdown() })
process.once('SIGINT', () => { void shutdown() })

try {
  await reconcileIndependentDeletions()
  await snapshotIndependentDeletions()
  await app.listen({ port: env.PORT, host: env.HOST })
  stopCron = startCron()
  app.log.info(`Previously server listening on :${env.PORT} (APP_ENV=${env.APP_ENV})`)
  // Which side of the comments launch switch this deploy is on (off unless the host's .env says 1).
  app.log.info(socialConfigSummary())
} catch (err) {
  app.log.error({ event: 'runtime.start_failed', err }, 'Startup failed')
  process.exit(1)
}
