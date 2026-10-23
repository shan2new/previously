// One-off: write media.origin_countries for every TMDB season from TMDB's show record, using the
// LIVE release's compiled modules and production config. Touches only that column. Dry by default.
const root = process.argv[2]
const apply = process.argv.includes('--apply')
const limitArg = process.argv.find((a) => a.startsWith('--limit='))
const limit = limitArg ? Number(limitArg.slice(8)) : Infinity
const { config } = await import(root + '/ops/common.mjs')
Object.assign(process.env, await config())
const { env } = await import(root + '/dist/env.js')
const { sql } = await import(root + '/dist/db/index.js')
if (env.APP_ENV !== 'production' || !env.TMDB_ACCESS_TOKEN) throw new Error('not the production config')
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
async function show(id) {
  for (let attempt = 0; attempt < 4; attempt++) {
    const res = await fetch(`https://api.themoviedb.org/3/tv/${id}`, {
      headers: { Authorization: `Bearer ${env.TMDB_ACCESS_TOKEN}`, accept: 'application/json' },
      signal: AbortSignal.timeout(15000),
    })
    if (res.status === 429) { await sleep(2000 * (attempt + 1)); continue }
    if (res.status === 404) return null
    if (!res.ok) throw new Error(`TMDB ${res.status}`)
    return res.json()
  }
  throw new Error('TMDB rate limited')
}
const started = Date.now()
const result = { apply, shows: 0, updatedRows: 0, notFound: 0, failed: 0, empty: 0, byCountry: {} }
try {
  const shows = (await sql`select f.id, f.external_id as tmdb from franchise f where f.source = 'tmdb' and f.external_id is not null order by f.updated_at desc`).slice(0, limit)
  let next = 0
  async function worker() {
    while (next < shows.length) {
      const s = shows[next++]
      try {
        const tv = await show(s.tmdb)
        if (!tv) { result.notFound++; continue }
        const countries = (tv.origin_country ?? []).map((c) => String(c).toUpperCase())
        if (countries.length === 0) result.empty++
        const key = countries.join(',') || '(none)'
        result.byCountry[key] = (result.byCountry[key] ?? 0) + 1
        if (apply) {
          const rows = await sql`update media set origin_countries = ${JSON.stringify(countries)}::jsonb
            where source = 'tmdb' and id in (select media_id from franchise_member where franchise_id = ${s.id})`
          result.updatedRows += rows.count
        } else if (result.shows < 5) {
          console.error(JSON.stringify({ tmdb: s.tmdb, name: tv.name, networks: (tv.networks ?? []).map((n) => n.name).slice(0, 2), countries }))
        }
        result.shows++
      } catch (error) {
        result.failed++
        if (result.failed <= 3) console.error('failed:', error?.name, String(error?.message).slice(0, 160))
      }
      await sleep(120)
    }
  }
  await Promise.all(Array.from({ length: 4 }, worker))
  const [c] = await sql`select count(*) filter (where origin_countries is not null)::int as known, count(*)::int as tv from media where source = 'tmdb'`
  result.byCountry = Object.fromEntries(Object.entries(result.byCountry).sort((a, b) => b[1] - a[1]).slice(0, 12))
  console.log(JSON.stringify({ ...result, mediaWithCountries: c, seconds: (Date.now() - started) / 1000, finishedAt: new Date().toISOString() }))
} finally {
  await sql.end({ timeout: 5 })
}
