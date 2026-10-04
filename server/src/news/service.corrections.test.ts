import { beforeEach, describe, expect, it, vi } from 'vitest'
const mock = vi.hoisted(() => ({ result: null as any, writes: [] as any[], committed: [] as any[], failEvidence: false, read: 0 }))
vi.mock('./agent.js', () => ({ researchFranchiseNews: vi.fn(async () => mock.result) }))
vi.mock('../feed/adopt.js', () => ({ adoptCatalogueThread: vi.fn() }))
vi.mock('../db/index.js', async () => {
  const { franchise, announcementEvidence } = await import('../db/schema.js')
  const f = { id: 'f', title: 'Show', source: 'anilist', primaryMediaId: 1, upcoming: null }
  const a = { id: 'a', next: 'Season 2', dedupeKey: 'season 2', release: '2027-01-01', status: 'upcoming_dated' }
  const db: any = {
    select: () => {
      const result = [ [f], [], [a], [f], [a] ][mock.read++] ?? []
      const chain: any = { then: (ok: any, bad: any) => Promise.resolve(result).then(ok,bad) }
      for(const key of ['from','where','limit','innerJoin','orderBy','for'])chain[key]=()=>chain
      return chain
    },
    update: (table: any) => ({ set: (value: any) => ({ where: async () => { mock.writes.push({table:table===franchise?'franchise':'announcement',value}) } }) }),
    insert: (table: any) => ({ values: () => ({ returning: async () => [{id:'ob'}], onConflictDoNothing: async () => { if(table===announcementEvidence&&mock.failEvidence)throw new Error('evidence failed') } }) }),
    transaction: async (fn: any) => { const result=await fn(db); mock.committed=[...mock.writes];return result },
  }
  return {db,sql:{}}
})
const { refreshFranchiseNews } = await import('./service.js')
beforeEach(() => {
 mock.read=0;mock.writes=[];mock.committed=[];mock.failEvidence=false
 mock.result={status:'announced_no_date',next:'Season 2',release:'TBA',note:'Date withdrawn',source:'https://www.netflix.com/news/show',evidence:[{url:'https://www.netflix.com/news/show',tier:'official',primary:true,publisher:'Netflix',publishedAt:null}]}
})
describe('accepted research corrections', () => {
 it('withdraws a date consistently without notifying it as new news', async () => {
  expect(await refreshFranchiseNews('f')).toEqual({checked:true,notified:0})
  expect(mock.committed.find(x=>x.table==='franchise').value.upcoming.release).toBe('TBA')
  expect(mock.committed.find(x=>x.table==='announcement').value).toMatchObject({status:'announced_no_date',release:'TBA'})
 })
 it('does not commit partial current facts when evidence persistence fails', async () => {
  mock.failEvidence=true
  await expect(refreshFranchiseNews('f')).rejects.toThrow('evidence failed')
  expect(mock.committed).toEqual([])
 })
})
