import { asc, eq } from 'drizzle-orm'
import { db } from '../db/index.js'
import { announcements, franchise, franchiseMember, media } from '../db/schema.js'
import type { PartKind } from '../grouping/partKind.js'
import { announcementForPart, type MatchablePart } from '../news/installment.js'
import { comparePartOrder } from '../services/franchiseView.js'
import type { CatalogVideo } from '../types/api.js'
import type { ParsedSubject } from './subjects.js'

// Subject resolution (docs/api-contract.md, "Post ids and thread subjects"): which franchise a
// thread belongs to, and whether the thing it names exists at all. Nobody can open a thread — or
// like, save, remind or hide a post — on an id the catalogue does not know.
//
// The spoiler gate for `ep:` rooms is separate (services/episodeGate.ts).
//
// Writes and thread reads key on the CANONICAL subject (`canonicalSubject`): once an announcement
// names a catalogue part, `catalog:<mediaId>` IS `news:<announcementId>` — the id the feed shows and
// the id adoption (feed/adopt.ts) moved the thread to — so a queued toggle, a replayed comment or a
// hide sent against the old id lands on the thread everyone reads instead of being stranded.

export interface ResolvedSubject {
  franchiseId: string
  franchiseTitle: string
}

/**
 * True when `site:videoId` is one of `videos`. The site compares lowercased (subjects carry it
 * lowercased); the video id compares exactly, because provider ids are case-sensitive.
 */
export function videoListed(videos: readonly CatalogVideo[] | null | undefined, site: string, videoId: string): boolean {
  if (!Array.isArray(videos)) return false
  const wanted = site.toLowerCase()
  return videos.some(
    (v) => v != null && typeof v.site === 'string' && typeof v.id === 'string' && v.site.toLowerCase() === wanted && v.id === videoId,
  )
}

async function byMember(mediaId: number): Promise<ResolvedSubject | null> {
  const [row] = await db
    .select({ franchiseId: franchiseMember.franchiseId, franchiseTitle: franchise.title })
    .from(franchiseMember)
    .innerJoin(franchise, eq(franchise.id, franchiseMember.franchiseId))
    .where(eq(franchiseMember.mediaId, mediaId))
    .limit(1)
  return row ?? null
}

/** A franchise by id (a "Mute <show>" target). */
export async function resolveFranchise(franchiseId: string): Promise<ResolvedSubject | null> {
  const [row] = await db
    .select({ franchiseId: franchise.id, franchiseTitle: franchise.title })
    .from(franchise)
    .where(eq(franchise.id, franchiseId))
    .limit(1)
  return row ?? null
}

/**
 * - `news:<id>`: the announcement's franchise.
 * - `catalog:<mediaId>` and `ep:<mediaId>:<n>`: the franchise the part belongs to.
 * - `trailer:<fid>:<site>:<videoId>`: the franchise, and ONLY when that video is listed on it —
 *   in the franchise's enrichment videos or on any of its parts — so a thread cannot be opened on
 *   an arbitrary video id.
 */
export async function resolveSubject(p: ParsedSubject): Promise<ResolvedSubject | null> {
  switch (p.kind) {
    case 'news': {
      const [row] = await db
        .select({ franchiseId: announcements.franchiseId, franchiseTitle: franchise.title })
        .from(announcements)
        .innerJoin(franchise, eq(franchise.id, announcements.franchiseId))
        .where(eq(announcements.id, p.announcementId))
        .limit(1)
      return row ?? null
    }
    case 'catalog':
    case 'episode':
      return byMember(p.mediaId)
    case 'trailer': {
      const [f] = await db
        .select({ franchiseId: franchise.id, franchiseTitle: franchise.title, enrichment: franchise.enrichment })
        .from(franchise)
        .where(eq(franchise.id, p.franchiseId))
        .limit(1)
      if (!f) return null
      const found = { franchiseId: f.franchiseId, franchiseTitle: f.franchiseTitle }
      if (videoListed(f.enrichment?.videos, p.site, p.videoId)) return found
      const parts = await db
        .select({ videos: media.videos })
        .from(franchiseMember)
        .innerJoin(media, eq(media.id, franchiseMember.mediaId))
        .where(eq(franchiseMember.franchiseId, p.franchiseId))
      return parts.some((m) => videoListed(m.videos, p.site, p.videoId)) ? found : null
    }
  }
}

// ---------- The canonical subject (catalogue → news) ----------

/** What the one announcement ↔ part rule (`announcementForPart`) reads for a franchise. */
export interface InstallmentIndex {
  /** Parts in watch order (`comparePartOrder`), labelled and titled as `FranchisePart` is. */
  parts: MatchablePart[]
  /** Announcements oldest first (`first_seen_at`, then id): the order the feed's composer reads. */
  announcements: { id: string; next: string; status?: string }[]
}

/** Two indexed reads; the same parts and announcements, in the same order, as the feed composes from. */
export async function loadInstallmentIndex(franchiseId: string): Promise<InstallmentIndex> {
  const [members, rows] = await Promise.all([
    db
      .select({
        mediaId: franchiseMember.mediaId,
        label: franchiseMember.label,
        sequence: franchiseMember.sequence,
        watchOrder: franchiseMember.watchOrder,
        partKind: franchiseMember.partKind,
        titleEnglish: media.titleEnglish,
        titleRomaji: media.titleRomaji,
        status: media.status,
      })
      .from(franchiseMember)
      .innerJoin(media, eq(media.id, franchiseMember.mediaId))
      .where(eq(franchiseMember.franchiseId, franchiseId)),
    db
      .select({ id: announcements.id, next: announcements.next, status: announcements.status })
      .from(announcements)
      .where(eq(announcements.franchiseId, franchiseId))
      .orderBy(asc(announcements.firstSeenAt), asc(announcements.id)),
  ])
  const parts = members
    .map((m) => {
      // `FranchisePart`'s own fallbacks (services/franchiseView.ts `toPart`).
      const title = m.titleEnglish || m.titleRomaji || `Anime #${m.mediaId}`
      return {
        mediaId: m.mediaId,
        label: m.label ?? title,
        title,
        status: m.status,
        watchOrder: m.watchOrder || m.sequence,
        kind: m.partKind as PartKind,
        sequence: m.sequence,
      }
    })
    .sort(comparePartOrder)
  return { parts, announcements: rows }
}

/**
 * The subject a write or a thread read keys on. `catalog:<mediaId>` becomes `news:<id>` when an
 * announcement of the part's franchise names that part (`announcementForPart` — the rule the feed's
 * catalogue post id, the post-detail alias and adoption share); every other subject, and a catalogue
 * part no announcement names (or one no franchise holds), is returned unchanged.
 */
export async function canonicalSubject(p: ParsedSubject): Promise<ParsedSubject> {
  if (p.kind !== 'catalog') return p
  const [member] = await db
    .select({ franchiseId: franchiseMember.franchiseId })
    .from(franchiseMember)
    .where(eq(franchiseMember.mediaId, p.mediaId))
    .limit(1)
  if (!member) return p
  const index = await loadInstallmentIndex(member.franchiseId)
  const adopted = announcementForPart({ mediaId: p.mediaId }, index.announcements, index.parts)
  return adopted ? { kind: 'news', announcementId: adopted.id } : p
}
