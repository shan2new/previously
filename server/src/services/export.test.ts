import { beforeEach, describe, expect, it, vi } from 'vitest'

// services/export.ts (GET /me/export): the categories an access request must see — the visit
// stamps, the profile's own times, why a comment was hidden, the stored notification text, and the
// one record kept after an erasure (the caller's ban row, read by their Clerk id). The database is
// a fake transaction that answers each query in the order buildAccountExport issues them.

const fake = vi.hoisted(() => {
  /** One answer per query, in order. */
  const answers: unknown[][] = []
  /** A query builder that is awaitable at any step and answers the next queued rows. */
  const chain = () => {
    const c: Record<string, unknown> = {}
    for (const m of ['from', 'innerJoin', 'leftJoin', 'where', 'orderBy', 'limit']) c[m] = () => c
    c.then = (resolve: (v: unknown) => unknown, reject: (e: unknown) => unknown) =>
      Promise.resolve(answers.shift() ?? []).then(resolve, reject)
    return c
  }
  /**
   * The audience is read inside a SAVEPOINT (a nested transaction). `savepointError`, while set, is
   * what that savepoint fails with — "no such table" before migration 0012 has run.
   */
  const state = { savepointError: null as unknown }
  const tx = {
    select: () => chain(),
    transaction: async (fn: (savepoint: unknown) => unknown) => {
      if (state.savepointError) throw state.savepointError
      return fn(tx)
    },
  }
  return { answers, tx, state }
})

vi.mock('../db/index.js', () => ({
  db: { transaction: async (fn: (tx: unknown) => unknown) => fn(fake.tx) },
  sql: {},
}))

const { buildAccountExport, moderationRecord, openedAtOrNull } = await import('./export.js')

const USER = '11111111-1111-4111-8111-111111111111'
const FRANCHISE = '33333333-3333-4333-8333-333333333333'
const COMMENT = '55555555-5555-4555-8555-555555555555'
const SESSION = '66666666-6666-4666-8666-666666666666'
const T = (iso: string) => new Date(iso)

beforeEach(() => {
  fake.answers.length = 0
  fake.state.savepointError = null
})

describe('openedAtOrNull / moderationRecord', () => {
  it('reads a 0 visit stamp as never', () => {
    expect(openedAtOrNull(0)).toBeNull()
    expect(openedAtOrNull(null)).toBeNull()
    expect(openedAtOrNull(Number.NaN)).toBeNull()
    expect(openedAtOrNull(1790330400000)).toBe(1790330400000)
  })

  it('an identity never suspended has no record; an active and a lifted ban both show', () => {
    expect(moderationRecord(undefined)).toBeNull()
    expect(moderationRecord({ reason: 'harassment', createdAt: T('2026-09-20T00:00:00Z'), liftedAt: null })).toEqual({
      suspended: true,
      reason: 'harassment',
      since: Date.parse('2026-09-20T00:00:00Z'),
      liftedAt: null,
    })
    expect(
      moderationRecord({ reason: null, createdAt: T('2026-09-20T00:00:00Z'), liftedAt: T('2026-09-22T00:00:00Z') }),
    ).toEqual({ suspended: false, reason: null, since: Date.parse('2026-09-20T00:00:00Z'), liftedAt: Date.parse('2026-09-22T00:00:00Z') })
  })
})

describe('buildAccountExport', () => {
  it('includes the visit stamps, profile times, the ban record, hidden reasons and notification text', async () => {
    fake.answers.push(
      // account
      [
        {
          id: USER,
          clerkId: 'user_x',
          createdAt: T('2026-09-01T00:00:00Z'),
          email: 'x@example.com',
          lastOpenedAt: 1790330400000,
          prevOpenedAt: 0,
        },
      ],
      // profile
      [
        {
          handle: 'dex',
          displayName: 'Dex',
          termsAcceptedAt: T('2026-09-02T00:00:00Z'),
          termsVersion: '2026-09-25',
          createdAt: T('2026-09-02T00:00:00Z'),
          updatedAt: T('2026-09-03T00:00:00Z'),
        },
      ],
      // moderation ban (by Clerk id)
      [{ reason: 'spam', createdAt: T('2026-09-20T00:00:00Z'), liftedAt: null }],
      [], // subscriptions
      [], // progress
      [], // preferences
      [], // audience (its own table, read in a savepoint)
      [], // recommendation feedback
      // watch sessions — a stopped rewatch, deleted later (a tombstone is still the caller's data)
      [
        {
          id: SESSION,
          userId: USER,
          franchiseId: FRANCHISE,
          scopeMediaId: null,
          ordinal: 2,
          startedAt: 1790000000000,
          completedAt: null,
          cancelledAt: 1790100000000,
          cancelledAtEpisode: 7,
          episodes: 24,
          restoreProgress: null,
          restoreStatus: 'completed',
          createdAt: T('2026-09-21T00:00:00Z'),
          updatedAt: T('2026-09-22T00:00:00Z'),
          deletedAt: T('2026-09-23T00:00:00Z'),
        },
      ],
      // comments
      [
        {
          id: COMMENT,
          subject: 'ep:154587:12',
          parentId: null,
          body: 'So good',
          createdAt: T('2026-09-10T00:00:00Z'),
          deletedAt: null,
          hiddenAt: T('2026-09-11T00:00:00Z'),
          hiddenReason: 'reports',
        },
      ],
      [], // likes
      [], // comment likes
      [], // saves
      [], // reminders
      [], // hides
      [], // ratings
      [], // blocks
      [], // reports
      // notifications
      [
        {
          id: '77777777-7777-4777-8777-777777777777',
          kind: 'comment_hidden',
          franchiseId: FRANCHISE,
          title: 'Frieren',
          body: 'reports',
          subject: null,
          postId: null,
          commentId: null,
          createdAt: T('2026-09-11T00:00:00Z'),
          readAt: null,
        },
      ],
    )

    const doc = await buildAccountExport(USER, 42)
    expect(fake.answers).toHaveLength(0) // every query was answered, in order
    expect(doc?.exportedAt).toBe(42)
    expect(doc?.account).toEqual({
      id: USER,
      createdAt: Date.parse('2026-09-01T00:00:00Z'),
      email: 'x@example.com',
      lastOpenedAt: 1790330400000,
      prevOpenedAt: null,
    })
    expect(doc?.account).not.toHaveProperty('clerkId')
    expect(doc?.profile).toMatchObject({
      createdAt: Date.parse('2026-09-02T00:00:00Z'),
      updatedAt: Date.parse('2026-09-03T00:00:00Z'),
    })
    expect(doc?.moderation).toEqual({
      suspended: true,
      reason: 'spam',
      since: Date.parse('2026-09-20T00:00:00Z'),
      liftedAt: null,
    })
    expect(doc?.library.watchSessions).toEqual([
      {
        id: SESSION,
        franchiseId: FRANCHISE,
        scopeMediaId: null,
        ordinal: 2,
        startedAt: 1790000000000,
        completedAt: null,
        cancelledAt: 1790100000000,
        cancelledAtEpisode: 7,
        episodes: 24,
        restoreProgress: null,
        restoreStatus: 'completed',
        updatedAt: Date.parse('2026-09-22T00:00:00Z'),
        deletedAt: Date.parse('2026-09-23T00:00:00Z'),
      },
    ])
    expect(doc?.social.comments[0]).toMatchObject({ hiddenReason: 'reports', hiddenAt: Date.parse('2026-09-11T00:00:00Z') })
    expect(doc?.social.notifications[0]).toMatchObject({ kind: 'comment_hidden', title: 'Frieren', body: 'reports' })
  })

  it('an identity that was never suspended exports moderation: null', async () => {
    fake.answers.push([{ id: USER, clerkId: 'user_x', createdAt: T('2026-09-01T00:00:00Z'), email: null, lastOpenedAt: 0, prevOpenedAt: 0 }])
    const doc = await buildAccountExport(USER, 1)
    expect(doc?.moderation).toBeNull()
    expect(doc?.profile).toBeNull()
    expect(doc?.account.lastOpenedAt).toBeNull()
  })

  it('no account row → null', async () => {
    expect(await buildAccountExport(USER, 1)).toBeNull()
  })

  describe('the audience preference', () => {
    const account = [{ id: USER, clerkId: 'user_x', createdAt: T('2026-09-01T00:00:00Z'), email: null, lastOpenedAt: 0, prevOpenedAt: 0 }]
    const preferences = { userId: USER, country: 'IN', language: 'en', providerIds: [8], updatedAt: T('2026-09-05T00:00:00Z') }
    const audience = { audience: 'tv', updatedAt: T('2026-10-01T00:00:00Z') }
    /** account, profile, ban, subscriptions, progress — then the two rows under test. */
    const upTo = (prefs: unknown[], chosen: unknown[]) => [account, [], [], [], [], prefs, chosen]

    it('exports the choice with the preferences, stamped with the later of the two writes', async () => {
      fake.answers.push(...upTo([preferences], [audience]))
      const doc = await buildAccountExport(USER, 1)
      expect(doc?.library.preferences).toEqual({
        country: 'IN',
        language: 'en',
        providerIds: [8],
        updatedAt: '2026-10-01T00:00:00.000Z',
        audience: 'tv',
      })
    })

    it('exports a choice made by a viewer who never saved any other preference', async () => {
      fake.answers.push(...upTo([], [audience]))
      const doc = await buildAccountExport(USER, 1)
      expect(doc?.library.preferences).toEqual({
        country: null,
        language: 'en',
        providerIds: [],
        updatedAt: '2026-10-01T00:00:00.000Z',
        audience: 'tv',
      })
    })

    it('says "not chosen" for a viewer with preferences and no audience row, and null with neither', async () => {
      fake.answers.push(...upTo([preferences], []))
      expect((await buildAccountExport(USER, 1))?.library.preferences).toMatchObject({ country: 'IN', audience: null })
      fake.answers.length = 0
      fake.answers.push(...upTo([], []))
      expect((await buildAccountExport(USER, 1))?.library.preferences).toBeNull()
    })

    it('still exports everything else while the audience table does not exist yet', async () => {
      fake.state.savepointError = Object.assign(new Error('relation "user_audience" does not exist'), { code: '42P01' })
      // The savepoint fails before its query, so the answers run on: preferences, then feedback…
      fake.answers.push(account, [], [], [], [], [preferences])
      const doc = await buildAccountExport(USER, 1)
      expect(doc?.library.preferences).toMatchObject({ country: 'IN', audience: null })
      expect(doc?.account.id).toBe(USER)
    })

    it('does not swallow any other failure of that read', async () => {
      fake.state.savepointError = new Error('connection terminated')
      fake.answers.push(account, [], [], [], [], [preferences])
      await expect(buildAccountExport(USER, 1)).rejects.toThrow('connection terminated')
    })
  })
})
