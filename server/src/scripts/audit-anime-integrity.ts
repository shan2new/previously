// Read-only refresh evidence for every materialized AniList entry, paced below 30 requests/minute.
import { writeFile } from 'node:fs/promises'
import { sql } from '../db/index.js'
import { fetchByIds } from '../anilist/client.js'
import { toMediaRow } from '../services/mediaStore.js'

const path = process.argv[2]
if (!path) throw new Error('Pass an output JSON path')
try {
  const before = await sql`select id, status, episodes, episodes_list, next_airing_episode, fetched_at
    from media where source='anilist' order by id`
  const fresh = []
  const missing: number[] = []
  let failures = 0
  for (let offset = 0; offset < before.length; offset += 50) {
    const ids = before.slice(offset, offset + 50).map(r => r.id as number)
    const found = await fetchByIds(ids, { maxRetries: 1, timeoutMs: 10_000 })
    fresh.push(...found.map(m => {
      const row = toMediaRow(m)
      return { id: row.id, status: row.status, episodes: row.episodes, episodesList: row.episodesList,
        nextAiringEpisode: row.nextAiringEpisode, fetchedAt: row.fetchedAt }
    }))
    missing.push(...ids.filter(id => !found.some(m => m.id === id)))
    failures = found.length === 0 ? failures + 1 : 0
    if (failures >= 3) break
    if (offset % 250 === 0) console.log(`Checked ${Math.min(offset + 50, before.length)}/${before.length} anime entries`)
    await new Promise(resolve => setTimeout(resolve, 2300))
  }
  await writeFile(path, JSON.stringify({ checked: new Date().toISOString(), before, fresh, missing }, null, 2))
  console.log(JSON.stringify({ total: before.length, found: fresh.length, missing: missing.length, output: path }))
} finally { await sql.end() }
