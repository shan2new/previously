// Run from server/: DATABASE_URL=postgres://localhost/previously_onboarding_scratch npx tsx ../design/onboarding-2026-10-04/verify-import.mts
// Real SQL invariants against disposable rows. Never accepts the production database.
import assert from 'node:assert/strict'
import { randomUUID } from 'node:crypto'
if (new URL(process.env.DATABASE_URL ?? 'postgres://localhost/none').pathname !== '/previously_onboarding_scratch') {
  throw new Error('Only previously_onboarding_scratch is allowed')
}
const { db, sql } = await import('../../server/src/db/index.js')
const { eq } = await import('../../server/node_modules/drizzle-orm/index.js')
const { users, franchise, franchiseMember, media, progress, subscriptions } = await import('../../server/src/db/schema.js')
const { applyPlan } = await import('../../server/src/import/service.js')
const userId = randomUUID(), fid = randomUUID(), mid = 900_999_001
assert.equal((await sql`select current_database() as name`)[0]!.name, 'previously_onboarding_scratch')
assert.equal((await db.select().from(media).where(eq(media.id, mid))).length, 0, 'fixture media id must be unused')
let checks = 0
const check = (v: boolean, why: string) => { assert.ok(v, why); checks++ }
try {
  await db.insert(users).values({ id: userId, clerkId: `import-check-${userId}` })
  await db.insert(media).values({ id: mid, source: 'anilist', status: 'FINISHED', episodes: 100 })
  await db.insert(franchise).values({ id: fid, title: 'Import SQL fixture', primaryMediaId: mid })
  await db.insert(franchiseMember).values({ franchiseId: fid, mediaId: mid, partKind: 'season', sequence: 1 })
  const plan = (episodes: number, status = 'watching') => ({ franchiseId: fid, status: status as 'watching' | 'planned' | 'completed', parts: [{ mediaId: mid, episodes }] })
  const createdAt = new Date()
  check(await applyPlan(userId, plan(4), createdAt.getTime()), 'first apply adds membership')
  check(!await applyPlan(userId, plan(2, 'planned')), 'replay does not add membership')
  check((await db.select().from(progress).where(eq(progress.userId, userId)))[0]!.episodesWatched === 4, 'replay never lowers progress')
  check((await db.select().from(subscriptions).where(eq(subscriptions.userId, userId)))[0]!.status === 'watching', 'existing status is preserved')
  await Promise.all(Array.from({ length: 60 }, (_, n) => applyPlan(userId, plan(60 - n))))
  check((await db.select().from(progress).where(eq(progress.userId, userId)))[0]!.episodesWatched === 60, 'concurrent raises retain the maximum')
  await applyPlan(userId, plan(999, 'completed'))
  check((await db.select().from(progress).where(eq(progress.userId, userId)))[0]!.episodesWatched === 100, 'progress is capped to released episodes')
  await db.update(subscriptions).set({ status: 'paused' }).where(eq(subscriptions.userId, userId))
  await applyPlan(userId, plan(100, 'completed'), Date.now(), { status: 'watching', createdAt })
  check((await db.select().from(subscriptions).where(eq(subscriptions.userId, userId)))[0]!.status === 'paused', 'tail cannot overwrite a later user status')
  await db.update(subscriptions).set({ status: 'watching' }).where(eq(subscriptions.userId, userId))
  await applyPlan(userId, plan(100, 'completed'), Date.now(), { status: 'watching', createdAt })
  check((await db.select().from(subscriptions).where(eq(subscriptions.userId, userId)))[0]!.status === 'completed', 'tail can correct its own unchanged membership')
  await db.delete(subscriptions).where(eq(subscriptions.userId, userId))
  await applyPlan(userId, plan(100, 'completed'), Date.now(), { status: 'watching', createdAt })
  check((await db.select().from(subscriptions).where(eq(subscriptions.userId, userId))).length === 0, 'tail does not resurrect a removed show')
  await db.insert(subscriptions).values({ userId, franchiseId: fid, status: 'watching', createdAt: new Date(createdAt.getTime() + 1) })
  await applyPlan(userId, plan(100, 'completed'), Date.now(), { status: 'watching', createdAt })
  check((await db.select().from(subscriptions).where(eq(subscriptions.userId, userId)))[0]!.status === 'watching', 'tail cannot claim a removed and re-added membership')
  console.log(`IMPORT_SQL_PASS ${checks}`)
} finally {
  await db.delete(users).where(eq(users.id, userId))
  await db.delete(franchise).where(eq(franchise.id, fid))
  await db.delete(media).where(eq(media.id, mid))
  await sql.end()
}
