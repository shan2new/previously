import Fastify, { type FastifyReply, type FastifyRequest } from 'fastify'
import { getTableConfig } from 'drizzle-orm/pg-core'
import { getTableColumns, getTableName, is } from 'drizzle-orm'
import { PgTable } from 'drizzle-orm/pg-core'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import * as schema from '../db/schema.js'

// `DELETE /me` — App Store guideline 5.1.1(v). Two independent things are asserted here, because
// each of them can be true while the other is false:
//
//   1. the ROUTE erases every user-owned table and the user row, in one transaction, scoped to the
//      caller — no DB needed, the transaction is recorded through a fake;
//   2. the SCHEMA still cascades from `users`, and the route's list still covers every table that
//      stores rows for one user — so adding a user-owned table later fails this test instead of
//      quietly surviving a "delete my account".
//
// The `db` module is mocked before `./me.js` is imported, which keeps `src/env.ts` (and therefore a
// DATABASE_URL) out of the test entirely, matching the no-DB, no-network rule the suite follows.

const recorded = vi.hoisted(() => ({
  deletes: [] as { table: string; where: unknown }[],
  transactions: 0,
  /** SAVEPOINTs opened inside the erasure (an optional step runs in one). */
  savepoints: 0,
  /** What a delete inside a savepoint fails with: 'missing' = the table does not exist yet. */
  savepointFailure: null as null | 'missing' | 'other',
  /** 'commit', then the post-commit steps, in the order they ran. */
  events: [] as string[],
  /** Make the erasure transaction fail after its deletes (a rollback). */
  failTx: false,
  clerkOutcome: { outcome: 'deleted' } as { outcome: string; error?: string },
})) as {
  deletes: { table: string; where: unknown }[]
  transactions: number
  savepoints: number
  savepointFailure: null | 'missing' | 'other'
  events: string[]
  failTx: boolean
  clerkOutcome: { outcome: string; error?: string }
}

const apple = vi.hoisted(() => ({ prepare: vi.fn(), finish: vi.fn(), persist: vi.fn(), outcome: 'manual_required' }))
vi.mock('../services/appleDeletion.js', () => ({ prepareAppleDeletion: apple.prepare }))

vi.mock('../db/index.js', () => {
  const tx = {
    delete(table: unknown) {
      const row = { table: getTableName(table as never), where: undefined as unknown }
      recorded.deletes.push(row)
      return {
        where(condition: unknown) {
          row.where = condition
          return Promise.resolve([])
        },
      }
    },
    /** A nested transaction is a SAVEPOINT: a failure inside it undoes only what ran inside it. */
    async transaction<T>(fn: (savepoint: unknown) => Promise<T>): Promise<T> {
      recorded.savepoints += 1
      if (recorded.savepointFailure === 'missing') {
        throw Object.assign(new Error('relation "user_audience" does not exist'), { code: '42P01' })
      }
      if (recorded.savepointFailure === 'other') throw new Error('deadlock detected')
      return fn(tx)
    },
  }
  return {
    db: {
      ...tx,
      async transaction<T>(fn: (t: typeof tx) => Promise<T>): Promise<T> {
        recorded.transactions += 1
        const result = await fn(tx)
        if (recorded.failTx) throw new Error('could not serialize access')
        recorded.events.push('commit')
        return result
      },
      // `GET /me/library` is registered in the same plugin; it is never called here, but the
      // module has to expose enough shape for the import to succeed.
      select: () => ({ from: () => ({ where: () => ({ limit: async () => [] }) }) }),
    },
    sql: {},
    schema,
  }
})

vi.mock('../services/animeVideoFallback.js', () => ({ enqueueAnimeVideoFallback: vi.fn() }))
vi.mock('../services/erasure.js', () => ({
  recordErasure: (clerkId: string) => recorded.events.push(`recordErasure:${clerkId}`),
  eraseClerkIdentity: async (clerkId: string) => {
    recorded.events.push(`clerk:${clerkId}`)
    return recorded.clerkOutcome
  },
}))
vi.mock('../services/deletionLedger.js', () => ({
  lockIdentity: async () => {},
  enqueueDeletion: async () => {},
  finishDeletion: async (clerkId: string) => {
    recorded.events.push(`clerk:${clerkId}`)
    return { completedAt: recorded.clerkOutcome.outcome === 'deleted' ? new Date() : null, appleRevocation: apple.outcome }
  },
  recordAppleRevocation: apple.persist,
  deletionResponse: (row: { completedAt: Date | null; appleRevocation: string }) => ({ deleted: !!row.completedAt, status: row.completedAt ? 'complete' : 'pending', appleRevocation: row.appleRevocation }),
}))

const { meRoutes, accountErasurePlan, accountOwnedTableNames } = await import('./me.js')

const CALLER = '11111111-1111-1111-1111-111111111111'

/** The plugin under test, with `authenticate` stubbed to attach one known user. */
async function appWithUser(userId: string | null = CALLER) {
  const app = Fastify()
  app.decorate('authenticate', async (req: FastifyRequest, reply: FastifyReply) => {
    if (!userId) return reply.code(401).send({ error: 'unauthorized' })
    req.user = { id: userId, clerkId: 'user_test' }
  })
  await app.register(meRoutes)
  await app.ready()
  return app
}

beforeEach(() => {
  recorded.deletes.length = 0
  recorded.transactions = 0
  recorded.savepoints = 0
  recorded.savepointFailure = null
  recorded.events.length = 0
  recorded.failTx = false
  recorded.clerkOutcome = { outcome: 'deleted' }
  apple.outcome = 'manual_required'
  apple.finish.mockReset().mockResolvedValue('manual_required')
  apple.prepare.mockReset().mockResolvedValue({ initial: 'manual_required', finish: apple.finish })
  apple.persist.mockReset().mockImplementation(async (_id, outcome) => { apple.outcome = outcome })
})

describe('DELETE /me — the account is erased, not deactivated', () => {
  it('deletes every user-owned table and the user row, inside one transaction', async () => {
    const app = await appWithUser()
    const res = await app.inject({ method: 'DELETE', url: '/me' })

    expect(res.statusCode).toBe(200)
    expect(res.json()).toEqual({ deleted: true, status: 'complete', appleRevocation: 'manual_required' })
    expect(recorded.transactions).toBe(1)
    // Exactly the plan, in the plan's order, then the user row.
    expect(recorded.deletes.map((d) => d.table)).toEqual([
      ...accountErasurePlan.map((s) => getTableName(s.table)),
      'users',
    ])
    // Every delete is scoped — a missing `where` would erase the table for every account.
    expect(recorded.deletes.every((d) => d.where !== undefined)).toBe(true)
    await app.close()
  })

  it('erases a table whose migration has not run yet without failing: that step alone is skipped', async () => {
    // `user_audience` arrives with migration 0012; the API is served from the working tree, so
    // this code can run before the table exists. Its step runs in a savepoint and is the only one.
    const optional = accountErasurePlan.filter((s) => s.optional).map((s) => getTableName(s.table))
    expect(optional).toEqual(['user_audience'])

    recorded.savepointFailure = 'missing'
    const app = await appWithUser()
    const res = await app.inject({ method: 'DELETE', url: '/me' })

    expect(res.statusCode).toBe(200)
    expect(res.json()).toEqual({ deleted: true, status: 'complete', appleRevocation: 'manual_required' })
    expect(recorded.savepoints).toBe(1)
    // Every other table, in order, then the user row — and the erasure committed.
    expect(recorded.deletes.map((d) => d.table)).toEqual([
      ...accountErasurePlan.filter((s) => !s.optional).map((s) => getTableName(s.table)),
      'users',
    ])
    expect(recorded.events).toEqual(['commit', 'recordErasure:user_test', 'clerk:user_test'])
    await app.close()
  })

  it('any other failure of an optional step still fails the whole erasure', async () => {
    recorded.savepointFailure = 'other'
    const app = await appWithUser()
    const res = await app.inject({ method: 'DELETE', url: '/me' })
    expect(res.statusCode).toBe(500)
    expect(recorded.deletes.map((d) => d.table)).not.toContain('users')
    expect(recorded.events).toEqual([])
    await app.close()
  })

  it('deletes the user row LAST, so it never depends on a cascade to succeed', async () => {
    const app = await appWithUser()
    await app.inject({ method: 'DELETE', url: '/me' })
    expect(recorded.deletes.at(-1)?.table).toBe('users')
    await app.close()
  })

  it('holds the Clerk id and erases the Clerk identity only AFTER the transaction commits', async () => {
    const app = await appWithUser()
    const res = await app.inject({ method: 'DELETE', url: '/me' })
    expect(res.statusCode).toBe(200)
    expect(recorded.events).toEqual(['commit', 'recordErasure:user_test', 'clerk:user_test'])
    await app.close()
  })

  it('a rolled-back erasure holds nothing and never calls Clerk', async () => {
    recorded.failTx = true
    const app = await appWithUser()
    const res = await app.inject({ method: 'DELETE', url: '/me' })
    expect(res.statusCode).toBe(500)
    expect(recorded.events).toEqual([])
    await app.close()
  })

  it('a Clerk failure reports pending cleanup rather than completed deletion', async () => {
    recorded.clerkOutcome = { outcome: 'failed', error: 'timed out' }
    const app = await appWithUser()
    const res = await app.inject({ method: 'DELETE', url: '/me' })
    expect(res.statusCode).toBe(202)
    expect(res.json()).toEqual({ deleted: false, status: 'pending', appleRevocation: 'manual_required' })
    expect(recorded.events).toEqual(['commit', 'recordErasure:user_test', 'clerk:user_test'])
    await app.close()
  })

  it('refuses an unauthenticated caller and touches nothing', async () => {
    const app = await appWithUser(null)
    const res = await app.inject({ method: 'DELETE', url: '/me' })
    expect(res.statusCode).toBe(401)
    expect(recorded.deletes).toEqual([])
    await app.close()
  })

  it('rejects a body it does not understand rather than deleting anyway', async () => {
    const app = await appWithUser()
    const res = await app.inject({ method: 'DELETE', url: '/me', payload: { userId: 'someone-else' } })
    expect(res.statusCode).toBe(400)
    expect(recorded.deletes).toEqual([])
    await app.close()
  })

  it('finishes Apple only after erasure commits, before deleting the linked Clerk identity', async () => {
    const proof = { identityToken: 'synthetic-request-jwt', authorizationCode: 'synthetic-request-code' }
    apple.finish.mockImplementation(async () => {
      expect(recorded.events).toEqual(['commit', 'recordErasure:user_test'])
      return 'revoked'
    })
    const app = await appWithUser()
    const response = await app.inject({ method: 'DELETE', url: '/me', payload: { apple: proof } })
    expect(apple.prepare).toHaveBeenCalledWith('user_test', proof)
    expect(apple.persist).toHaveBeenCalledWith('user_test', 'revoked')
    expect(response.json()).toEqual({ deleted: true, status: 'complete', appleRevocation: 'revoked' })
    expect(recorded.events.at(-1)).toBe('clerk:user_test')
    await app.close()
  })

  it('never exchanges or revokes Apple proof after a rolled-back erasure', async () => {
    recorded.failTx = true
    const app = await appWithUser()
    expect((await app.inject({ method: 'DELETE', url: '/me', payload: { apple: { identityToken: 'synthetic-jwt', authorizationCode: 'synthetic-code' } } })).statusCode).toBe(500)
    expect(apple.finish).not.toHaveBeenCalled()
    expect(apple.persist).not.toHaveBeenCalled()
    await app.close()
  })

  it('still erases app data after Apple provider failure and reports manual fallback', async () => {
    apple.finish.mockResolvedValue('manual_required')
    const app = await appWithUser()
    const response = await app.inject({ method: 'DELETE', url: '/me', payload: { apple: {} } })
    expect(response.statusCode).toBe(200)
    expect(response.json().appleRevocation).toBe('manual_required')
    expect(recorded.deletes.at(-1)?.table).toBe('users')
    await app.close()
  })

  it('keeps conservative manual outcome if durable outcome persistence fails after erasure', async () => {
    apple.finish.mockResolvedValue('revoked')
    apple.persist.mockRejectedValue(new Error('synthetic outcome storage failure'))
    const app = await appWithUser()
    const response = await app.inject({ method: 'DELETE', url: '/me' })
    expect(response.statusCode).toBe(200)
    expect(response.json().appleRevocation).toBe('manual_required')
    expect(recorded.deletes.at(-1)?.table).toBe('users')
    await app.close()
  })

  it.each([{ apple: { authorizationCode: 1 } }, { apple: { identityToken: 'x'.repeat(16385) } }, { apple: { subject: 'other-owner' } }])('rejects malformed Apple proof without beginning erasure', async (payload) => {
    const app = await appWithUser()
    expect((await app.inject({ method: 'DELETE', url: '/me', payload })).statusCode).toBe(400)
    expect(recorded.deletes).toEqual([])
    expect(apple.prepare).not.toHaveBeenCalled()
    await app.close()
  })
})

describe('the schema keeps the deletion complete', () => {
  // `Object.values` over the schema module yields tables AND `relations()` helpers; the `unknown[]`
  // step is what lets the `is(v, PgTable)` guard narrow that heterogeneous union.
  const tables = (Object.values(schema) as unknown[]).filter((v): v is PgTable => is(v, PgTable))
  /** Every declared table that stores rows belonging to one user. */
  const userOwned = tables.filter((t) => 'userId' in getTableColumns(t))

  /** Every foreign key in the schema: its table and first column, and what it points at. */
  const allForeignKeys = tables.flatMap((table) =>
    getTableConfig(table)
      .foreignKeys.map((fk) => ({ fk, ref: fk.reference() }))
      .map(({ fk, ref }) => ({
        table: getTableName(table),
        column: ref.columns[0]!.name,
        foreignTable: getTableName(ref.foreignTable),
        foreignColumn: ref.foreignColumns[0]!.name,
        onDelete: fk.onDelete,
      })),
  )

  /** Every foreign key in the schema pointing at `target`. */
  const foreignKeysTo = (target: string) => allForeignKeys.filter((fk) => fk.foreignTable === target)

  /** The plan step deleting `table` by `column` — an owner step, or with `via`, one read through that parent table. */
  const planIndex = (table: string, column: string, via?: string) =>
    accountErasurePlan.findIndex(
      (s) =>
        getTableName(s.table) === table &&
        s.column.name === column &&
        (s.via ? getTableName(s.via.table) : undefined) === via,
    )

  /** `users` and every table the plan deletes from: a row in any of them is (about) the user. */
  const userTables = new Set(['users', ...accountOwnedTableNames])

  /**
   * Tables that keep a user-identifying column on purpose, disclosed in the privacy policy. The ban
   * list is keyed on the Clerk id with no foreign key, so it survives DELETE /me.
   */
  const RETAINED_BY_DESIGN = ['moderation_bans', 'account_deletions']

  it('lists every user-owned table in the route, so a new one cannot be forgotten', () => {
    expect(new Set(userOwned.map((t) => getTableName(t)))).toEqual(new Set(accountOwnedTableNames))
  })

  it('cascades from users on every user-owned table, so no row can outlive the account', () => {
    for (const table of userOwned) {
      const fk = getTableConfig(table)
        .foreignKeys.map((f) => f.reference())
        .find((r) => getTableName(r.foreignTable) === 'users')
      expect(fk, `${getTableName(table)} has no foreign key to users`).toBeDefined()
      expect(getTableConfig(table).foreignKeys.some((f) => f.onDelete === 'cascade')).toBe(true)
    }
  })

  it('erases every foreign key to users, whatever the column is called', () => {
    const fks = foreignKeysTo('users')
    // Sanity: the renamed columns this exists to catch are really in the schema.
    expect(fks.map((f) => `${f.table}.${f.column}`)).toEqual(
      expect.arrayContaining(['notifications.actor_user_id', 'blocks.blocked_user_id']),
    )
    for (const fk of fks) {
      expect(planIndex(fk.table, fk.column), `no erasure step for ${fk.table}.${fk.column}`).toBeGreaterThanOrEqual(0)
      expect(fk.onDelete, `${fk.table}.${fk.column} must cascade from users`).toBe('cascade')
    }
  })

  it("erases rows that hang off the user's comments, and keeps other people's replies", () => {
    const fks = foreignKeysTo('comments')
    const commentsOwner = planIndex('comments', 'user_id')
    expect(commentsOwner).toBeGreaterThanOrEqual(0)
    // Sanity: the reply self-reference is among them.
    expect(fks.some((f) => f.table === 'comments' && f.column === 'parent_id')).toBe(true)
    for (const fk of fks) {
      if (fk.table === 'comments' && fk.column === 'parent_id') {
        // A reply OUTLIVES its parent: it becomes a top-level comment of the same thread.
        expect(fk.onDelete).toBe('set null')
        expect(accountErasurePlan.some((s) => getTableName(s.table) === 'comments' && s.column.name === 'parent_id')).toBe(false)
        continue
      }
      const step = planIndex(fk.table, fk.column, 'comments')
      expect(step, `no via-comments erasure step for ${fk.table}.${fk.column}`).toBeGreaterThanOrEqual(0)
      expect(step, `${fk.table}.${fk.column} must be erased before the comments`).toBeLessThan(commentsOwner)
    }
  })

  // The general form of the two tests above, so a table keyed on ANOTHER user-owned table (a
  // `mentions.profile_user_id → user_profiles`, a `report_notes → reports`) or a second-level child
  // of any plan table cannot slip past them.
  it('erases every foreign key into users or any plan table, at any depth', () => {
    const fks = allForeignKeys.filter((fk) => userTables.has(fk.foreignTable))
    // Sanity: second-level children are really among them.
    expect(fks.map((f) => `${f.table}.${f.column}`)).toEqual(
      expect.arrayContaining(['comment_likes.comment_id', 'reports.comment_id', 'notifications.comment_id']),
    )
    for (const fk of fks) {
      const label = `${fk.table}.${fk.column} → ${fk.foreignTable}.${fk.foreignColumn}`
      // A row that outlives its parent (a reply becomes a top-level comment) needs no step.
      if (fk.onDelete === 'set null') continue
      // A parent removed by ANY step (the reports ABOUT the user's comments go with the comments)
      // must take this row with it, or the erasure fails on the foreign key.
      expect(fk.onDelete, `${label} must cascade`).toBe('cascade')
      // The column holds a user id (it points at users, or at the column a plan table's owner step
      // deletes by): an owner step erases it directly.
      const holdsUserId = fk.foreignTable === 'users' || planIndex(fk.foreignTable, fk.foreignColumn) >= 0
      if (holdsUserId && planIndex(fk.table, fk.column) >= 0) continue
      // Otherwise it is read through its parent, BEFORE any step deletes the parent's rows (after,
      // the subquery finds nothing).
      const via = planIndex(fk.table, fk.column, fk.foreignTable)
      expect(via, `no erasure step for ${label}`).toBeGreaterThanOrEqual(0)
      expect(accountErasurePlan[via]!.via!.key.name, `${label}: the step reads another column`).toBe(fk.foreignColumn)
      accountErasurePlan.forEach((s, i) => {
        if (getTableName(s.table) === fk.foreignTable) {
          expect(via, `${label} must be erased before ${fk.foreignTable} (step ${i})`).toBeLessThan(i)
        }
      })
    }
  })

  it("reads every second-level step through the parent's own owner step", () => {
    const viaSteps = accountErasurePlan.filter((s) => s.via)
    expect(viaSteps.length).toBeGreaterThan(0)
    for (const step of viaSteps) {
      const parent = getTableName(step.via!.table)
      expect(getTableName(step.via!.key.table)).toBe(parent)
      expect(getTableName(step.via!.owner.table)).toBe(parent)
      expect(planIndex(parent, step.via!.owner.name), `${parent}.${step.via!.owner.name} has no owner step`).toBeGreaterThanOrEqual(0)
    }
  })

  it('erases every column named like a user id, foreign key or not, unless it is a disclosed retention', () => {
    // A user id kept in a plain text/uuid column has no foreign key for the tests above to follow.
    // (One inside a jsonb value is out of reach of any schema scan: never store one there.)
    const looksLikeUser = /(^|_)user_id$|clerk_id/
    const found: string[] = []
    for (const table of tables) {
      const name = getTableName(table)
      if (name === 'users') continue
      for (const column of Object.values(getTableColumns(table))) {
        if (!looksLikeUser.test(column.name)) continue
        found.push(`${name}.${column.name}`)
        if (RETAINED_BY_DESIGN.includes(name)) continue
        expect(planIndex(name, column.name), `${name}.${column.name} names a user but no erasure step deletes by it`).toBeGreaterThanOrEqual(0)
      }
    }
    // Sanity: the scan sees the renamed columns and the retained one.
    expect(found).toEqual(
      expect.arrayContaining(['notifications.actor_user_id', 'blocks.blocked_user_id', 'moderation_bans.clerk_id']),
    )
    for (const retained of RETAINED_BY_DESIGN) expect(accountOwnedTableNames).not.toContain(retained)
  })

  it('moderation bans and the deletion ledger are explicit retention exceptions', () => {
    const withClerkId = tables
      .filter((t) => getTableName(t) !== 'users')
      .filter((t) => Object.values(getTableColumns(t)).some((c) => c.name === 'clerk_id'))
      .map((t) => getTableName(t))
    expect(withClerkId.sort()).toEqual(['account_deletions', 'moderation_bans'])
    const bans = tables.find((t) => getTableName(t) === 'moderation_bans')!
    expect(
      getTableConfig(bans).foreignKeys.some((fk) => getTableName(fk.reference().foreignTable) === 'users'),
    ).toBe(false)
    expect(accountOwnedTableNames).not.toContain('moderation_bans')
  })
})
