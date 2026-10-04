import { randomUUID } from 'node:crypto'
import { previewImport, type ImportPreview, type ImportRequest } from './service.js'
import { ImportSourceError } from './sources.js'

// A large MAL export needs many upstream lookups. Never hold an HTTP request open while
// doing them: both the app's timeout and the public proxy would cut it off. Reading is a
// bounded, user-owned job; no library writes occur until its completed preview is applied.
type PreviewState =
  | { id: string; state: 'reading' }
  | { id: string; state: 'ready'; preview: ImportPreview }
  | { id: string; state: 'failed'; error: string }
const jobs = new Map<string, { userId: string; expires: number; value: PreviewState }>()
const TTL = 30 * 60_000

function prune(): void {
  for (const [id, job] of jobs) {
    if (job.value.state !== 'reading' && job.expires < Date.now()) jobs.delete(id)
  }
}

export function startPreview(userId: string, request: ImportRequest): PreviewState | null {
  prune()
  if (jobs.size >= 200 || [...jobs.values()].some((j) => j.userId === userId && j.value.state === 'reading')) return null
  const id = randomUUID()
  const job = { userId, expires: Date.now() + TTL, value: { id, state: 'reading' } as PreviewState }
  jobs.set(id, job)
  void previewImport(userId, request).then((preview) => {
    job.value = { id, state: 'ready', preview }
  }).catch((error: unknown) => {
    job.value = { id, state: 'failed', error: `import_${error instanceof ImportSourceError ? error.reason : 'unavailable'}` }
  }).finally(() => { job.expires = Date.now() + TTL })
  return job.value
}

export function readPreview(userId: string, id: string): PreviewState | null {
  prune()
  const job = jobs.get(id)
  return job?.userId === userId ? job.value : null
}
