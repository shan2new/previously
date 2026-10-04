import { and, eq, sql } from 'drizzle-orm'
import { db } from '../db/index.js'
import { announcements, comments, feedHides, likes, notifications, reminders, saves } from '../db/schema.js'
import { announcedPart, announcementForPart } from '../news/installment.js'
import { loadInstallmentIndex } from '../social/resolve.js'
import { formatSubject } from '../social/subjects.js'

// Thread adoption (D2). A catalogue-only post is `catalog:<mediaId>`; when research later records
// an announcement for that part, the post becomes `news:<announcementId>` — and its likes, saves,
// reminders, hides, comments and notifications move with it, so the thread survives the promotion.

/**
 * Move every social row keyed on post id `from` to `to`, in one transaction. On the PK-keyed tables
 * a user who already holds a row under `to` keeps that one and the `from` row is dropped (a like is
 * a set, not a counter). Returns the number of rows moved; logs when anything moved.
 */
export async function rekeyPostSubject(from: string, to: string): Promise<number> {
  if (from === to) return 0
  const moved = await db.transaction(async (tx) => {
    let n = 0

    const likedMoved = await tx
      .update(likes)
      .set({ subject: to })
      .where(
        and(
          eq(likes.subject, from),
          sql`not exists (select 1 from ${likes} as t2 where t2.user_id = ${likes.userId} and t2.subject = ${to})`,
        ),
      )
      .returning({ userId: likes.userId })
    n += likedMoved.length
    await tx.delete(likes).where(eq(likes.subject, from))

    const savedMoved = await tx
      .update(saves)
      .set({ postId: to })
      .where(
        and(
          eq(saves.postId, from),
          sql`not exists (select 1 from ${saves} as t2 where t2.user_id = ${saves.userId} and t2.post_id = ${to})`,
        ),
      )
      .returning({ userId: saves.userId })
    n += savedMoved.length
    await tx.delete(saves).where(eq(saves.postId, from))

    const remindedMoved = await tx
      .update(reminders)
      .set({ postId: to })
      .where(
        and(
          eq(reminders.postId, from),
          sql`not exists (select 1 from ${reminders} as t2 where t2.user_id = ${reminders.userId} and t2.post_id = ${to})`,
        ),
      )
      .returning({ userId: reminders.userId })
    n += remindedMoved.length
    await tx.delete(reminders).where(eq(reminders.postId, from))

    const hidesMoved = await tx
      .update(feedHides)
      .set({ target: to })
      .where(
        and(
          eq(feedHides.kind, 'post'),
          eq(feedHides.target, from),
          sql`not exists (select 1 from ${feedHides} as t2 where t2.user_id = ${feedHides.userId} and t2.kind = 'post' and t2.target = ${to})`,
        ),
      )
      .returning({ userId: feedHides.userId })
    n += hidesMoved.length
    await tx.delete(feedHides).where(and(eq(feedHides.kind, 'post'), eq(feedHides.target, from)))

    const commentsMoved = await tx
      .update(comments)
      .set({ subject: to })
      .where(eq(comments.subject, from))
      .returning({ id: comments.id })
    n += commentsMoved.length

    const subjectsMoved = await tx
      .update(notifications)
      .set({ subject: to })
      .where(eq(notifications.subject, from))
      .returning({ id: notifications.id })
    const postsMoved = await tx
      .update(notifications)
      .set({ postId: to })
      .where(eq(notifications.postId, from))
      .returning({ id: notifications.id })
    n += new Set([...subjectsMoved, ...postsMoved].map((row) => row.id)).size

    return n
  })
  if (moved > 0) console.log(`[feed] re-keyed ${moved} social row(s): ${from} → ${to}`)
  return moved
}

/**
 * After research records or advances announcement `announcementId`, adopt the catalogue post of the
 * part it names: `catalog:<M>` → `news:<A>`, where M is the part the announcement's STORED
 * installment names (`announcedPart`) and A is the announcement the feed keys M's post on
 * (`announcementForPart`: this one, unless an older announcement already names the same part). It
 * reads the franchise's parts and announcements exactly as the composer and the write-side
 * canonical subject do (social/resolve.ts `loadInstallmentIndex`), so it moves the rows onto the id
 * the feed shows and every later write keys on. A few indexed statements when nothing moves.
 */
export async function adoptCatalogueThread(announcementId: string): Promise<number> {
  const [row] = await db
    .select({ franchiseId: announcements.franchiseId })
    .from(announcements)
    .where(eq(announcements.id, announcementId))
    .limit(1)
  if (!row) return 0
  const index = await loadInstallmentIndex(row.franchiseId)
  const own = index.announcements.find((a) => a.id === announcementId)
  const part = own ? announcedPart(own.next, index.parts) : null
  if (!own || own.status === 'retracted' || !part) return 0
  const canonical = announcementForPart(part, index.announcements, index.parts) ?? own
  return rekeyPostSubject(
    formatSubject({ kind: 'catalog', mediaId: part.mediaId }),
    formatSubject({ kind: 'news', announcementId: canonical.id }),
  )
}
