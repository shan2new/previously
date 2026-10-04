import { z } from 'zod'

// The one id grammar the social layer keys on (docs/api-contract.md, "Post ids and thread subjects").
//
//   news:<announcement uuid>                     a research-backed news post
//   catalog:<media id>                           a catalogue-only upcoming post (NOT_YET_RELEASED part)
//   trailer:<franchise uuid>:<site>:<video id>   a trailer post (site lowercased)
//   ep:<media id>:<episode>                      an episode discussion room (spoiler-gated)
//
// "PostId" is one of the first three; "ThreadSubject" is any of the four. Ids are lowercase only
// (a Postgres uuid always prints lowercase, and one spelling per subject is what keeps one thread),
// and every integer is bounded by the int4 columns it is joined against.
//
// Following's "Episode N is out" post has no id of its own: it IS the episode's `ep:` subject, so
// the post and the room are one thread. A "feed post id" (`feedPostIdSchema`) is therefore any of
// the four — the post page, saves and hides take it; reminders stay PostId-only (an episode that is
// out has nothing to be reminded of).

export type ParsedSubject =
  | { kind: 'news'; announcementId: string }
  | { kind: 'catalog'; mediaId: number }
  | { kind: 'trailer'; franchiseId: string; site: string; videoId: string }
  | { kind: 'episode'; mediaId: number; episode: number }

/** The subjects a feed post can carry (everything but an episode room). */
export type PostSubject = Exclude<ParsedSubject, { kind: 'episode' }>

/** The widest a subject can legally be is ~130 chars (a trailer); 160 leaves headroom. */
export const SUBJECT_MAX_LENGTH = 160
/** `media.id` and `franchise_member.media_id` are int4. */
export const MAX_MEDIA_ID = 2_147_483_647

const UUID = '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
const NEWS_RE = new RegExp(`^news:(${UUID})$`)
const CATALOG_RE = /^catalog:([1-9][0-9]{0,9})$/
const TRAILER_RE = new RegExp(`^trailer:(${UUID}):([a-z0-9]{1,20}):([A-Za-z0-9_-]{1,64})$`)
const EP_RE = /^ep:([1-9][0-9]{0,9}):([1-9][0-9]{0,4})$/

function mediaIdOf(digits: string): number | null {
  const n = Number(digits)
  return Number.isSafeInteger(n) && n >= 1 && n <= MAX_MEDIA_ID ? n : null
}

/** Parse a subject string. Null for anything that is not exactly one of the four grammars. */
export function parseSubject(s: string): ParsedSubject | null {
  if (typeof s !== 'string' || s.length === 0 || s.length > SUBJECT_MAX_LENGTH) return null

  let m = NEWS_RE.exec(s)
  if (m) return { kind: 'news', announcementId: m[1]! }

  m = CATALOG_RE.exec(s)
  if (m) {
    const mediaId = mediaIdOf(m[1]!)
    return mediaId == null ? null : { kind: 'catalog', mediaId }
  }

  m = TRAILER_RE.exec(s)
  if (m) return { kind: 'trailer', franchiseId: m[1]!, site: m[2]!, videoId: m[3]! }

  m = EP_RE.exec(s)
  if (m) {
    const mediaId = mediaIdOf(m[1]!)
    const episode = Number(m[2]!)
    return mediaId == null ? null : { kind: 'episode', mediaId, episode }
  }

  return null
}

/**
 * The canonical string for a parsed subject. Uuids and the trailer site are lowercased; nothing is
 * validated here, so a caller building an id from outside data (a video id from a provider) checks
 * the result with `parseSubject` and skips what does not parse.
 */
export function formatSubject(p: ParsedSubject): string {
  switch (p.kind) {
    case 'news':
      return `news:${p.announcementId.toLowerCase()}`
    case 'catalog':
      return `catalog:${p.mediaId}`
    case 'trailer':
      return `trailer:${p.franchiseId.toLowerCase()}:${p.site.toLowerCase()}:${p.videoId}`
    case 'episode':
      return `ep:${p.mediaId}:${p.episode}`
  }
}

/**
 * True for a feed post's subject (news, catalog, trailer); false for an episode room. A string is
 * parsed first, and a string that does not parse is not a post.
 */
export function isPostSubject(p: ParsedSubject): p is PostSubject
export function isPostSubject(s: string): boolean
export function isPostSubject(p: ParsedSubject | string): boolean {
  const parsed = typeof p === 'string' ? parseSubject(p) : p
  return parsed != null && parsed.kind !== 'episode'
}

/** Any ThreadSubject (all four kinds). Outputs the string unchanged. */
export const threadSubjectSchema = z
  .string()
  .max(SUBJECT_MAX_LENGTH)
  .refine((s) => parseSubject(s) != null, { message: 'invalid subject' })

/** Alias of `threadSubjectSchema`: every subject is a thread subject. */
export const subjectSchema = threadSubjectSchema

/**
 * An id a feed post can carry: a PostId, or an episode's `ep:` subject (the "Episode N is out"
 * post). Every subject is one, so this is `threadSubjectSchema` under the name its callers mean.
 */
export const feedPostIdSchema = threadSubjectSchema

/** A PostId (news, catalog or trailer — never an episode room). Outputs the string unchanged. */
export const postIdSchema = z
  .string()
  .max(SUBJECT_MAX_LENGTH)
  .refine((s) => isPostSubject(s), { message: 'invalid post id' })
