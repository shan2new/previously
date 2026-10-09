import { and, asc, desc, eq, inArray, notLike, or, type SQL } from 'drizzle-orm'
import { db } from '../db/index.js'
import {
  announcementEvidence,
  announcementObservations,
  announcements,
  franchise,
  franchiseMember,
  media,
  notifications,
  reminders,
  subscriptions,
} from '../db/schema.js'
import { env } from '../env.js'
import { adoptCatalogueThread } from '../feed/adopt.js'
import { safeHttpsUrl, sanitizeEvidence, verifiedTier } from '../feed/evidence.js'
import { formatSubject } from '../social/subjects.js'
import type { AnnouncementEvidence, AnnouncementObservationView, FranchiseUpcoming } from '../types/api.js'
import { BoundedTaskQueue } from '../util/taskQueue.js'
import { researchFranchiseNews, type NewsResult } from './agent.js'
import { dedupeKey, sameInstallment } from './installment.js'
import { getShow } from '../tmdb/client.js'

// Only forward progress through this ladder produces a notification; the agent re-reporting
// the same news (or waffling back down to a rumor) just bumps lastSeenAt.
const STATUS_RANK: Record<string, number> = {
  rumored: 1,
  announced_no_date: 2,
  announced: 3,
  upcoming_dated: 4,
}

const isNoteworthy = (status: string): boolean => status in STATUS_RANK

// Detail reads may opportunistically warm missing/stale news, but web-research agents are slow and
// expensive work. One worker plus a hard queue cap keeps ordinary API traffic from multiplying it.
const onDemandNews = new BoundedTaskQueue(1, 8, (key, error) => {
  console.warn(`[news] on-demand refresh failed (${key}):`, 'diagnostic details redacted')
})
const onDemandAttemptedAt = new Map<string, number>()

export function newsNeedsRefresh(
  current: Partial<Pick<FranchiseUpcoming, 'checked' | 'source'>> | null | undefined,
  nowMs = Date.now(),
  intervalHours = env.NEWS_CHECK_INTERVAL_HOURS,
): boolean {
  // AniList/TMDB catalogue pages prove the immediate fact, but they are intentionally only a
  // fallback. Enrich them once with an actual announcement/report even when the catalogue row was
  // fetched moments ago.
  if (
    current?.source?.startsWith('https://anilist.co/') ||
    current?.source?.startsWith('https://www.themoviedb.org/')
  ) {
    return true
  }
  if (!current?.checked) return true
  const checkedAt = Date.parse(current.checked)
  return !Number.isFinite(checkedAt) || checkedAt < nowMs - intervalHours * 3_600_000
}

/**
 * Schedule stale-while-revalidate news research without extending detail-request latency.
 * Repeated views single-flight while queued and remain throttled for one normal check interval even
 * if research fails, so a title with no discoverable news cannot spawn an agent on every request.
 */
export function enqueueFranchiseNewsRefresh(
  franchiseId: string,
  current: Partial<Pick<FranchiseUpcoming, 'checked' | 'source'>> | null | undefined,
): boolean {
  if (env.NEWS_AGENT_DISABLED || !newsNeedsRefresh(current)) return false
  const now = Date.now()
  const lastAttempt = onDemandAttemptedAt.get(franchiseId)
  if (lastAttempt != null && lastAttempt >= now - env.NEWS_CHECK_INTERVAL_HOURS * 3_600_000) return false

  const task = onDemandNews.enqueue(`franchise:${franchiseId}`, async () => {
    await refreshFranchiseNews(franchiseId)
  })
  if (!task.accepted) return false
  onDemandAttemptedAt.set(franchiseId, now)
  // This is a bounded process-local throttle (the catalogue is currently small); shed oldest keys
  // if it grows so a long-running server never accumulates an unbounded access history.
  if (onDemandAttemptedAt.size > 500) onDemandAttemptedAt.delete(onDemandAttemptedAt.keys().next().value!)
  return true
}

const isConcreteRelease = (release: string): boolean => {
  const r = release.trim().toLowerCase()
  return r !== '' && r !== 'tba' && r !== 'tbd' && r !== 'unknown'
}

type NewsEvent = 'new' | 'upgraded' | 'dated'

function notificationText(result: NewsResult, event: NewsEvent): { kind: string; body: string } {
  const withRelease = isConcreteRelease(result.release) ? ` — ${result.release}` : ''
  if (event === 'dated') return { kind: 'news_dated', body: `${result.next} — release set for ${result.release}` }
  switch (result.status) {
    case 'rumored':
      return { kind: 'news_rumored', body: `${result.next} rumored${withRelease}` }
    case 'announced_no_date':
      return { kind: 'news_announced', body: `${result.next} announced — date TBA` }
    case 'announced':
      return { kind: 'news_announced', body: `${result.next} announced${withRelease}` }
    default: // upcoming_dated
      return { kind: 'news_dated', body: `${result.next} arrives ${result.release}` }
  }
}

/**
 * The reminders this announcement's news answers: one on the news post itself (`news:<A>`), and one
 * on ANY of the show's non-news posts — a trailer (`trailer:<fid>:…`, which is never re-keyed) or a
 * catalogue post that adoption could not match to this installment (`catalog:<mediaId>`). The app
 * tells everyone who sets an undated reminder that news about it will show in Activity; only the
 * research job can keep that promise, and it knows the show, not which of its posts was tapped. A
 * reminder on ANOTHER announcement's post (`news:<B>`) is about that installment and waits for its
 * own news.
 */
export function reminderHoldersWhere(franchiseId: string, newsPostId: string): SQL {
  return or(
    eq(reminders.postId, newsPostId),
    and(eq(reminders.franchiseId, franchiseId), notLike(reminders.postId, 'news:%')),
  )!
}

/**
 * Insert one notification per subscriber of the franchise AND per reminder holder the news answers
 * (`reminderHoldersWhere`) — someone who asked to hear when an undated installment firms up hears it
 * whether or not the show is in their library. One row per person. Returns how many.
 */
async function fanOut(
  franchiseId: string,
  franchiseTitle: string,
  announcementId: string,
  kind: string,
  body: string,
): Promise<number> {
  const postId = formatSubject({ kind: 'news', announcementId })
  const [subs, holders] = await Promise.all([
    db
      .select({ userId: subscriptions.userId })
      .from(subscriptions)
      .where(eq(subscriptions.franchiseId, franchiseId)),
    db
      .selectDistinct({ userId: reminders.userId })
      .from(reminders)
      .where(reminderHoldersWhere(franchiseId, postId)),
  ])
  const recipients = [...new Set([...subs, ...holders].map((row) => row.userId))]
  if (recipients.length === 0) return 0
  await db.insert(notifications).values(
    recipients.map((userId) => ({
      userId,
      franchiseId,
      announcementId,
      kind,
      title: franchiseTitle,
      body,
      postId,
    })),
  )
  return recipients.length
}

/**
 * Research one franchise, persist the result on franchise.upcoming, and — when the news is
 * genuinely new (first sighting, status upgrade, or a TBA release becoming a real date) —
 * record an announcement and notify every subscriber.
 */
export async function refreshFranchiseNews(franchiseId: string): Promise<{ checked: boolean; notified: number }> {
  const [f] = await db.select().from(franchise).where(eq(franchise.id, franchiseId)).limit(1)
  if (!f) return { checked: false, notified: 0 }

  // Watch order, as the feed reads them. (Adoption below loads its own index — `loadInstallmentIndex`
  // — so it matches parts exactly as the composer and the write-side canonical subject do.)
  const members = await db
    .select({
      mediaId: media.id,
      label: franchiseMember.label,
      titleEnglish: media.titleEnglish,
      titleRomaji: media.titleRomaji,
      format: media.format,
      status: media.status,
      seasonYear: media.seasonYear,
    })
    .from(franchiseMember)
    .innerJoin(media, eq(franchiseMember.mediaId, media.id))
    .where(eq(franchiseMember.franchiseId, franchiseId))
    .orderBy(asc(franchiseMember.watchOrder), asc(franchiseMember.sequence), asc(media.id))

  const knownParts = members.map((m) => {
    const name = m.label || m.titleEnglish || m.titleRomaji || 'Unknown'
    const providerTitle = m.titleEnglish || m.titleRomaji
    const bits = [m.format, m.status, m.seasonYear].filter(Boolean).join(', ')
    const identity = providerTitle && providerTitle !== name ? `${name} — catalogue title: ${providerTitle}` : name
    return bits ? `${identity} (${bits})` : identity
  })

  const priorRows = await db.select().from(announcements).where(eq(announcements.franchiseId, franchiseId))
  const knownAnnouncements = priorRows.filter((a) => isNoteworthy(a.status)).map((a) => `${a.next} (${a.status})`)

  // "The Traitors" names multiple unrelated national adaptations. A bare title and Season N
  // list made the researcher attach Irish RTÉ news to the Indian Prime Video series.
  let identityContext: string | null = null
  if (f.source === 'tmdb' && f.externalId != null) {
    const identity = await getShow(f.externalId, { maxRetries: 0, timeoutMs: 5_000 })
    if (!identity) return { checked: false, notified: 0 }
    identityContext = `Original title: ${identity.original_name ?? identity.name}. Countries: ${(identity.origin_country ?? []).join(', ')}. Networks: ${(identity.networks ?? []).map(n => n.name).join(', ')}. Premiere: ${identity.first_air_date ?? 'unknown'}. Provider series status: ${identity.status}.`
  }

  const result = await researchFranchiseNews({
    title: f.title,
    catalogueSource: f.source === 'tmdb' ? 'tmdb' : 'anilist',
    catalogueUrl: f.source === 'tmdb' && f.externalId != null
      ? `https://www.themoviedb.org/tv/${f.externalId}`
      : f.primaryMediaId != null ? `https://anilist.co/anime/${f.primaryMediaId}` : null,
    identityContext,
    knownParts,
    current: f.upcoming ?? null,
    knownAnnouncements,
  })
  if (!result) return { checked: false, notified: 0 }

  // The stored state carries the same verified evidence the observation rows do.
  const upcoming: FranchiseUpcoming = { ...result, evidence: storableEvidence(result.evidence), checked: new Date().toISOString() }
  const { event, announcementId } = await db.transaction(async (tx) => {
    await tx.select({ id: franchise.id }).from(franchise).where(eq(franchise.id, franchiseId)).for('update')
    await tx.update(franchise).set({ upcoming }).where(eq(franchise.id, franchiseId))

    const noteworthy = isNoteworthy(result.status) && !!result.next.trim()
    const key = noteworthy ? dedupeKey(result.next) : `__state__:${result.status}`
    const currentRows = await tx.select().from(announcements).where(eq(announcements.franchiseId, franchiseId))
    const existing = noteworthy ? currentRows.find((a) => sameInstallment(dedupeKey(a.next), key)) : undefined
    let event: NewsEvent | null = null
    let announcementId: string | null = null
    if (noteworthy) {
      const newRank = STATUS_RANK[result.status] ?? 0
      const oldRank = existing ? (STATUS_RANK[existing.status] ?? 0) : 0
      if (!existing) event = 'new'
      else if (newRank > oldRank) event = 'upgraded'
      else if (newRank === oldRank && !isConcreteRelease(existing.release) && isConcreteRelease(result.release)) event = 'dated'

      if (!existing) {
        const [row] = await tx
          .insert(announcements)
          .values({
            franchiseId,
            dedupeKey: key,
            status: result.status,
            next: result.next,
            release: result.release,
            note: result.note,
            source: result.source,
          })
          .returning({ id: announcements.id })
        announcementId = row!.id
      } else {
        // The rank controls notifications, not truth. A postponed date or corrected report must
        // update every surface, even when it moves from dated back to TBA.
        await tx
          .update(announcements)
          .set({
            lastSeenAt: new Date(),
            status: result.status, next: result.next, release: result.release, note: result.note, source: result.source,
          })
          .where(eq(announcements.id, existing.id))
        announcementId = existing.id
      }
    }

    const [observation] = await tx
      .insert(announcementObservations)
      .values({
        franchiseId,
        announcementId,
        dedupeKey: key,
        status: result.status,
        next: result.next,
        release: result.release,
        note: result.note,
      })
      .returning({ id: announcementObservations.id })
    const evidence = normalizedEvidence(result)
    if (observation && evidence.length > 0) {
      await tx.insert(announcementEvidence).values(evidence.map((item) => ({
        observationId: observation.id,
        ...item,
      }))).onConflictDoNothing()
    }

    return { event, announcementId }
  })

  // A catalogue-only feed post about this installment (`catalog:<mediaId>`) becomes this
  // announcement's post (`news:<id>`): its likes, saves, reminders and comments move with it. Runs on
  // every noteworthy run (a no-op when there is nothing to move) and BEFORE the fan-out, so the
  // holders of a catalogue post's reminder hear when research first confirms it. A failure here must
  // not lose the research result; the next run retries.
  if (announcementId) {
    try {
      await adoptCatalogueThread(announcementId)
    } catch (err) {
      console.warn(`[news] adopting the catalogue thread failed for "${f.title}":`, 'diagnostic details redacted')
    }
  }


  if (!event || !announcementId) return { checked: true, notified: 0 }

  const { kind, body } = notificationText(result, event)
  const notified = await fanOut(franchiseId, f.title, announcementId, kind, body)
  console.log(`[news] "${f.title}": ${event} → notified ${notified} subscriber(s): ${body}`)
  return { checked: true, notified }
}

/**
 * Evidence as it is stored (write-side hygiene — the agent's output is untrusted): https links only
 * (a `javascript:` or `http:` link must never be served back), an `official` tier only on a reviewed
 * official host (`verifiedTier`, feed/officialHosts.ts — the agent reads arbitrary pages, so its
 * tier is a claim; the feed's read side applies the same rule, so stored rows agree with it), one
 * entry per URL, at most five.
 */
export function storableEvidence(list: readonly AnnouncementEvidence[]): AnnouncementEvidence[] {
  const byUrl = new Map<string, AnnouncementEvidence>()
  for (const item of list) {
    if (safeHttpsUrl(item.url) == null || byUrl.has(item.url)) continue
    byUrl.set(item.url, { ...item, tier: verifiedTier(item.url, item.tier) })
  }
  return [...byUrl.values()].slice(0, 5)
}

/** The evidence rows to store for a result: `storableEvidence`, the bare `source` standing in when the agent returned no list. */
export function normalizedEvidence(result: Pick<NewsResult, 'evidence' | 'source'>): AnnouncementEvidence[] {
  return storableEvidence(
    result.evidence.length > 0
      ? result.evidence
      : result.source
        ? [{ url: result.source, publisher: null, publishedAt: null, tier: 'unknown', primary: false }]
        : [],
  )
}

/** Inspectable evidence history behind the latest one-line `upcoming` state. */
export async function listAnnouncementObservations(
  franchiseId: string,
  limit = 20,
): Promise<AnnouncementObservationView[]> {
  const rows = await db
    .select()
    .from(announcementObservations)
    .where(eq(announcementObservations.franchiseId, franchiseId))
    .orderBy(desc(announcementObservations.observedAt))
    .limit(limit)
  if (rows.length === 0) return []
  const evidence = await db
    .select()
    .from(announcementEvidence)
    .where(inArray(announcementEvidence.observationId, rows.map((row) => row.id)))
  const byObservation = new Map<string, AnnouncementEvidence[]>()
  for (const item of evidence) {
    const list = byObservation.get(item.observationId) ?? []
    list.push({
      url: item.url,
      publisher: item.publisher,
      publishedAt: item.publishedAt,
      tier: item.tier as AnnouncementEvidence['tier'],
      primary: item.primary,
    })
    byObservation.set(item.observationId, list)
  }
  return rows.map((row) => ({
    id: row.id,
    announcementId: row.announcementId,
    status: row.status,
    next: row.next,
    release: row.release,
    note: row.note,
    observedAt: row.observedAt.toISOString(),
    // Rows written before the write-side https rule may still hold other schemes; this route is
    // public, so they are filtered on the way out too.
    evidence: sanitizeEvidence(byObservation.get(row.id) ?? []),
  }))
}

/**
 * Daily pass over every franchise anyone is subscribed to. Franchises checked within the last
 * NEWS_CHECK_INTERVAL_HOURS are skipped; the rest are processed oldest-check-first, capped at
 * NEWS_MAX_FRANCHISES_PER_RUN, so a large backlog rotates through over successive runs.
 */
export async function refreshSubscribedNews(): Promise<{ checked: number; notified: number; skipped: number }> {
  const subbed = await db.selectDistinct({ franchiseId: subscriptions.franchiseId }).from(subscriptions)
  if (subbed.length === 0) return { checked: 0, notified: 0, skipped: 0 }

  const ids = subbed.map((s) => s.franchiseId)
  const rows = await db
    .select({ id: franchise.id, upcoming: franchise.upcoming })
    .from(franchise)
    .where(inArray(franchise.id, ids))

  const cutoff = Date.now() - env.NEWS_CHECK_INTERVAL_HOURS * 3_600_000
  const due = rows
    .map((r) => ({ id: r.id, checkedAt: r.upcoming?.checked ? Date.parse(r.upcoming.checked) || 0 : 0 }))
    .filter((r) => r.checkedAt < cutoff)
    .sort((a, b) => a.checkedAt - b.checkedAt)
    .slice(0, env.NEWS_MAX_FRANCHISES_PER_RUN)

  let checked = 0
  let notified = 0
  // Sequential on purpose: each check spawns an agent subprocess doing multi-turn web research.
  for (const { id } of due) {
    try {
      const r = await refreshFranchiseNews(id)
      if (r.checked) checked++
      notified += r.notified
    } catch (err) {
      console.warn(`[news] refresh failed for franchise ${id}:`, 'diagnostic details redacted')
    }
  }
  return { checked, notified, skipped: rows.length - due.length }
}
