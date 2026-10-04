// The real server, from the working tree, against the SCRATCH copy of the database only.
// No cron, no news agent, no LLM: a loopback API for exercising first run on the simulator.
// Run from server/ (so `.env` supplies the TMDB token), with the overrides on the command line.
const wanted = 'previously_onboarding_scratch'
const url = process.env.DATABASE_URL ?? ''
if (!new RegExp(`/${wanted}(\\?|$)`).test(url)) {
  console.error(`Refusing to start: DATABASE_URL must name ${wanted}`)
  process.exit(1)
}
const root = new URL('../../server/src', import.meta.url).pathname
const { env } = await import(`${root}/env.js`)
if (!env.DATABASE_URL.includes(wanted) || env.APP_ENV === 'production' || !env.NEWS_AGENT_DISABLED) {
  console.error('Refusing to start: not the scratch configuration')
  process.exit(1)
}
const { buildServer } = await import(`${root}/server.js`)
const app = await buildServer()
await app.listen({ port: env.PORT, host: '127.0.0.1' })
console.log(`scratch server on 127.0.0.1:${env.PORT} → ${wanted}`)
