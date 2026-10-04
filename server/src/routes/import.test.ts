import Fastify, { type FastifyRequest } from 'fastify'
import { beforeEach, describe, expect, it, vi } from 'vitest'
const m = vi.hoisted(() => ({ preview: vi.fn(), apply: vi.fn(), progress: vi.fn() }))
vi.mock('../import/service.js', () => ({ previewImport: m.preview, applyImport: m.apply, importProgress: m.progress }))
import { importRoutes } from './import.js'
import { ImportSourceError } from '../import/sources.js'
const id = '11111111-1111-4111-8111-111111111111'
let sequence = 0
async function server() {
  const app = Fastify()
  const user = `user-${sequence++}`
  app.decorate('authenticate', async (req: FastifyRequest) => {
    if (req.headers.authorization === 'denied') throw Object.assign(new Error('unauthorized'), { statusCode: 401 })
    req.user = { id: req.headers.authorization === 'other' ? 'other' : user, clerkId: 'test' }
  })
  await app.register(importRoutes)
  return app
}
beforeEach(() => vi.resetAllMocks())
describe('history import route contract', () => {
  it('rejects bad inputs and requires auth before starting any work', async () => {
    const app = await server()
    for (const payload of [{}, { source: 'anilist', username: ' ' }, { source: 'mal', rows: [] }, { source: 'tvtime', shows: [{ seasons: [{ number: -1, watched: [1] }] }] }]) {
      expect((await app.inject({ method: 'POST', url: '/me/import/preview', payload })).statusCode).toBe(400)
    }
    expect((await app.inject({ method: 'POST', url: '/me/import/preview', headers: { authorization: 'denied' }, payload: { source: 'anilist', username: 'a' } })).statusCode).toBe(401)
    expect(m.preview).not.toHaveBeenCalled()
    await app.close()
  })
  it('polls slow previews and keeps them private to the requesting account', async () => {
    let finish!: (value: unknown) => void
    m.preview.mockImplementation(() => new Promise(resolve => { finish = resolve }))
    const app = await server()
    const res = await app.inject({ method: 'POST', url: '/me/import/preview?async=1', payload: { source: 'anilist', username: 'a' } })
    expect(res.statusCode).toBe(202)
    const path = `/me/import/${res.json().id}/preview`
    expect((await app.inject(path)).json().state).toBe('reading')
    expect((await app.inject({ url: path, headers: { authorization: 'other' } })).statusCode).toBe(410)
    expect((await app.inject({ method: 'POST', url: '/me/import/preview?async=1', payload: { source: 'anilist', username: 'b' } })).statusCode).toBe(409)
    finish({ id, listed: 5 })
    await new Promise(resolve => setImmediate(resolve))
    expect((await app.inject(path)).json()).toMatchObject({ state: 'ready', preview: { id, listed: 5 } })
    expect(m.apply).not.toHaveBeenCalled()
    await app.close()
  })
  it('carries a private-list error through an async preview', async () => {
    m.preview.mockRejectedValue(new ImportSourceError('private'))
    const app = await server()
    const res = await app.inject({ method: 'POST', url: '/me/import/preview?async=1', payload: { source: 'anilist', username: 'private' } })
    await new Promise(resolve => setImmediate(resolve))
    expect((await app.inject(`/me/import/${res.json().id}/preview`)).json()).toMatchObject({ state: 'failed', error: 'import_private' })
    await app.close()
  })
  it('normalises nullable TV fields and strips unrelated account data', async () => {
    m.preview.mockResolvedValue({ id })
    const app = await server()
    await app.inject({ method: 'POST', url: '/me/import/preview', payload: { source: 'tvtime', shows: [{ title: 'Show', seasons: [], followed: true, email: 'ignored@example.test' }] } })
    expect(m.preview.mock.calls[0]?.[1].shows).toEqual([{ title: 'Show', seasons: [], followed: true, forLater: false, archived: false, tvdbId: null, lastWatchedAt: null }])
    await app.close()
  })
  it('returns expiry and validates ids for both apply and progress', async () => {
    m.apply.mockResolvedValue(null); m.progress.mockReturnValue(null)
    const app = await server()
    expect((await app.inject({ method: 'POST', url: `/me/import/${id}/apply` })).statusCode).toBe(410)
    expect((await app.inject(`/me/import/${id}`)).statusCode).toBe(410)
    expect((await app.inject('/me/import/nope')).statusCode).toBe(400)
    await app.close()
  })
})
