// Read-only source accessibility audit. A 403/timeout is UNVERIFIED, never proof a claim is false.
import { writeFile } from 'node:fs/promises'
import { sql } from '../db/index.js'
import { safeHttpsUrl } from '../feed/evidence.js'
import { mapWithConcurrency } from '../util/concurrency.js'

const path = process.argv[2]
if (!path) throw new Error('Pass an output JSON path')
try {
  const rows = await sql`select id,title,upcoming from franchise where upcoming is not null`
  const targets = rows.filter(r => safeHttpsUrl(r.upcoming.source) && !/themoviedb\.org|anilist\.co/.test(r.upcoming.source))
  const results = await mapWithConcurrency(targets, 3, async r => {
    const source = r.upcoming.source as string
    // These are persisted research URLs, not trusted network destinations.
    const host = new URL(source).hostname
    if (/^\[|^\d|localhost|\.local$|\.internal$/.test(host)) return { id: r.id, title: r.title, source, error: 'Non-public destination' }
    try {
      const response = await fetch(source, { signal: AbortSignal.timeout(10_000), redirect: 'manual' })
      // Do not follow arbitrary redirects. The audit records them for inspection instead.
      const reader = response.body?.getReader()
      const decoder = new TextDecoder()
      let html = ''
      if (reader) {
        while (html.length < 250_000) {
          const chunk = await reader.read()
          if (chunk.done) break
          html += decoder.decode(chunk.value, { stream: true })
        }
        await reader.cancel()
      }
      const pageTitle = /<title[^>]*>([\s\S]*?)<\/title>/i.exec(html)?.[1]?.replace(/\s+/g, ' ').trim() ?? null
      return { id: r.id, title: r.title, source, status: response.status, redirect: response.headers.get('location'), pageTitle }
    } catch (error) { return { id: r.id, title: r.title, source, error: String(error) } }
  })
  await writeFile(path, JSON.stringify({ checked: new Date().toISOString(), results }, null, 2))
  console.log(JSON.stringify({ total: results.length, accessible: results.filter(r => 'status' in r && r.status === 200).length, output: path }))
} finally { await sql.end() }
