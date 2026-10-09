import { eq } from 'drizzle-orm'
import { db } from '../db/index.js'
import { users } from '../db/schema.js'
import { AccountErasedError, deletionState, lockIdentity } from './deletionLedger.js'

export interface AppUser {
  id: string
  clerkId: string
  /**
   * ms epoch of the users row's creation. A day-old account gets a smaller comment budget
   * (util/rateLimit.ts `commentAction`). Always set by `upsertUser`/`getUserByClerkId`; optional only
   * so a hand-built user (tests) reads as an established account.
   */
  createdAt?: number
}

/** Look up (or create) the internal user row for a Clerk user id. */
export async function upsertUser(clerkId: string, email?: string | null): Promise<AppUser> {
  return db.transaction(async (tx) => {
  await lockIdentity(tx, clerkId)
  if (await deletionState(clerkId, tx)) throw new AccountErasedError('account deleted')
  const [row] = await tx
    .insert(users)
    .values({ clerkId, email: email ?? null })
    .onConflictDoUpdate({ target: users.clerkId, set: { email: email ?? null } })
    .returning({ id: users.id, clerkId: users.clerkId, createdAt: users.createdAt })
  return { id: row!.id, clerkId: row!.clerkId, createdAt: row!.createdAt.getTime() }
  })
}

export async function getUserByClerkId(clerkId: string): Promise<AppUser | undefined> {
  const [row] = await db
    .select({ id: users.id, clerkId: users.clerkId, createdAt: users.createdAt })
    .from(users)
    .where(eq(users.clerkId, clerkId))
    .limit(1)
  return row ? { id: row.id, clerkId: row.clerkId, createdAt: row.createdAt.getTime() } : undefined
}
