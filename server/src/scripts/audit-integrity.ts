// Read-only catalogue audit. Writes provider evidence and contradictions; never changes records.
// Run: npx tsx src/scripts/audit-integrity.ts <output.json>
import { writeFile } from 'node:fs/promises'
import { sql } from '../db/index.js'
import { getShow } from '../tmdb/client.js'
import { tmdbShowUpcoming, includedSeasons, tmdbSeasonToMediaRow } from '../tmdb/mapping.js'
import { mapWithConcurrency } from '../util/concurrency.js'

const path = process.argv[2]
if (!path) throw new Error('Pass an output JSON path')
const now = Date.now()
try {
  const franchises = await sql`select id, title, source, external_id, upcoming from franchise order by title`
  const parts = await sql`select fm.franchise_id, fm.label, fm.sequence, fm.part_kind, fm.optional,
    m.id, m.source, m.status, m.episodes, m.next_airing_episode, m.last_aired_at, m.fetched_at
    from franchise_member fm join media m on m.id=fm.media_id`
  let done = 0
  const provider = await mapWithConcurrency(franchises.filter(f => f.source === 'tmdb'), 4, async f => {
    try {
      const show = await getShow(f.external_id, { maxRetries: 1, timeoutMs: 8_000 })
      if (!show) return { id: f.id, title: f.title, error: 'Provider title missing' }
      const expected = includedSeasons(show).map(s => {
        const m = tmdbSeasonToMediaRow(show, s, now)
        return { id: m.id, status: m.status, episodes: m.episodes, next: m.nextAiringEpisode }
      })
      const staleParts = expected.flatMap(e => {
        const p = parts.find(p => p.franchise_id === f.id && p.id === e.id)
        return !p || p.status !== e.status || p.episodes !== e.episodes
          ? [{ id: e.id, before: p ? { status: p.status, episodes: p.episodes } : null, expected: e }] : []
      })
      return {
        id: f.id, title: f.title, externalId: f.external_id,
        status: show.status, countries: show.origin_country, originalName: show.original_name,
        last: show.last_episode_to_air, next: show.next_episode_to_air,
        seasons: show.seasons, upcoming: tmdbShowUpcoming(show, now), staleParts,
      }
    } catch (error) {
      return { id: f.id, title: f.title, error: String(error) }
    } finally {
      done++
      if (done % 100 === 0) console.log(`Checked ${done} TV shows`)
    }
  })
  const data = { checked: new Date(now).toISOString(), franchises, parts, provider }
  await writeFile(path, JSON.stringify(data, null, 2))
  console.log(JSON.stringify({ franchises: franchises.length, parts: parts.length, provider: provider.length,
    failures: provider.filter(p => 'error' in p).length,
    changedShows: provider.filter(p => 'staleParts' in p && p.staleParts?.length).length, output: path }))
} finally {
  await sql.end()
}
