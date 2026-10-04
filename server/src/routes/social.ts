import type { FastifyPluginAsync, FastifyReply, FastifyRequest } from 'fastify'
import { z } from 'zod'
import { env } from '../env.js'
import {
  countVisibleComments,
  deleteOwnComment,
  episodeRoomStats,
  fileReport,
  findReplay,
  findReplyParent,
  findReportTarget,
  findVisibleComment,
  insertComment,
  likeComment,
  listComments,
  loadCommenterProfile,
  unlikeComment,
  type ReplayOutcome,
} from '../services/comments.js'
import { getEpisodeAccess } from '../services/episodeGate.js'
import {
  blockTargetExists,
  deleteBlock,
  deleteHide,
  deleteLike,
  deleteReminder,
  deleteRating,
  deleteSave,
  listBlocks,
  listHides,
  putBlock,
  putHide,
  putLike,
  putRating,
  putReminder,
  putSave,
} from '../services/socialToggles.js'
import { checkCommentBody, codePointLength, normalizeUserText } from '../social/contentFilter.js'
import { canonicalSubject, resolveFranchise, resolveSubject, type ResolvedSubject } from '../social/resolve.js'
import {
  feedPostIdSchema,
  formatSubject,
  MAX_MEDIA_ID,
  parseSubject,
  postIdSchema,
  threadSubjectSchema,
  type ParsedSubject,
} from '../social/subjects.js'
import type {
  BlockedUsersResponse,
  CommentResponse,
  CommentsPage,
  EpisodeAccess,
  EpisodeRoom,
  HidesResponse,
  SocialError,
} from '../types/api.js'
import { decodeCursor, type KeysetCursor } from '../util/cursor.js'
import { commentAction, rateKeyOf, rateLimiter, sendRateLimited, type RateAction } from '../util/rateLimit.js'

// The social layer (docs/api-contract.md, "Social"): the set-state toggles under /me
// (likes, saves, reminders, hides, ratings, blocks) and the comment threads and episode rooms under
// /social. Every route needs a signed-in user.
//
// Status policy (D13): 400 `invalid request` for anything malformed, and nothing is written;
// 404 for what does not exist or is not visible to the caller; 409/410/422 with a machine code for
// a well-formed request the app refuses (never 403 — iOS reads a 403 as infrastructure); 429
// `rate_limited` with `Retry-After`. Writes answer 204.
//
// The rate limit (util/rateLimit.ts, keyed on the caller's Clerk id) is checked AFTER validation and
// every existence / gate check and BEFORE the write, so a request refused for those reasons never
// spends the caller's budget. The exceptions are deliberate: a 422 content refusal spends the
// `rejected` budget (429 once spent), and a comment page spends `read`. Removing state (the
// DELETEs) is never limited.
//
// SOCIAL_COMMENTS_ENABLED=0 turns every /social/comments* route into 404 `comments disabled`, and
// PUT /me/blocks with them (nothing shows another person while comments are off, so no new block
// is collected) — except DELETE /social/comments/:id: deleting your own comment is never switched
// off. Likes, saves, reminders, hides, ratings, reading and lifting blocks, and the episode room
// keep working.

const EPISODE_MAX = 99_999
const NOTE_MAX_CODE_POINTS = 500
const REPORT_REASONS = ['spam', 'harassment', 'hate', 'sexual', 'violence', 'spoiler', 'other'] as const

/** A uuid in any case, handled lowercase (one spelling per id, as Postgres prints it). */
const uuidSchema = z
  .string()
  .uuid()
  .transform((s) => s.toLowerCase())
const mediaIdSchema = z.number().int().min(1).max(MAX_MEDIA_ID)
const episodeSchema = z.number().int().min(1).max(EPISODE_MAX)
/** A path segment that is a plain positive integer: no sign, no exponent, no leading zero. */
const intParam = (max: number) =>
  z
    .string()
    .regex(/^[1-9][0-9]{0,9}$/)
    .transform(Number)
    .pipe(z.number().int().min(1).max(max))

const subjectBody = z.object({ subject: threadSubjectSchema }).strict()
/** A reminder: PostIds only — an "Episode N is out" post has nothing left to be reminded of. */
const postBody = z.object({ postId: postIdSchema }).strict()
/** A save or a hide: any post the feed carries, the `ep:` episode post included. */
const feedPostBody = z.object({ postId: feedPostIdSchema }).strict()
const hideBody = z.discriminatedUnion('kind', [
  z.object({ kind: z.literal('post'), target: feedPostIdSchema }).strict(),
  z.object({ kind: z.literal('show'), target: uuidSchema }).strict(),
])
const ratingBody = z
  .object({ mediaId: mediaIdSchema, episode: episodeSchema, score: z.number().int().min(0).max(100) })
  .strict()
const ratingKeyBody = z.object({ mediaId: mediaIdSchema, episode: episodeSchema }).strict()
const blockBody = z.object({ userId: uuidSchema }).strict()

const commentsQuery = z
  .object({
    subject: threadSubjectSchema,
    sort: z.enum(['top', 'latest']).default('top'),
    cursor: z.string().max(400).optional(),
    limit: z.coerce.number().int().min(1).max(50).default(20),
  })
  .strict()
const createCommentBody = z
  .object({
    id: uuidSchema,
    subject: threadSubjectSchema,
    body: z.string().max(4000),
    parentId: uuidSchema.nullable().optional(),
  })
  .strict()
const commentParams = z.object({ id: uuidSchema }).strict()
const reportBody = z
  .object({
    reason: z.enum(REPORT_REASONS),
    note: z
      .string()
      .refine((s) => codePointLength(s) <= NOTE_MAX_CODE_POINTS)
      .nullable()
      .optional(),
  })
  .strict()
const episodeParams = z.object({ mediaId: intParam(MAX_MEDIA_ID), episode: intParam(EPISODE_MAX) }).strict()

// ---------- Replies ----------

function invalid(reply: FastifyReply): FastifyReply {
  return reply.code(400).send({ error: 'invalid request' } satisfies SocialError)
}

function notFound(reply: FastifyReply, noun: string): FastifyReply {
  return reply.code(404).send({ error: `${noun} not found` } satisfies SocialError)
}

function commentsDisabled(reply: FastifyReply): FastifyReply {
  return reply.code(404).send({ error: 'comments disabled' } satisfies SocialError)
}

function episodeLocked(reply: FastifyReply, access: Exclude<EpisodeAccess, 'open'>): FastifyReply {
  return reply.code(409).send({ error: 'episode_locked', reason: access } satisfies SocialError)
}

function noContent(reply: FastifyReply): FastifyReply {
  return reply.code(204).send()
}

/**
 * Spend one hit of `action` for the caller (keyed on the Clerk id, `rateKeyOf`); null when allowed,
 * else the 429 already sent.
 */
function spend(req: FastifyRequest, reply: FastifyReply, action: RateAction): FastifyReply | null {
  const decision = rateLimiter.check(action, rateKeyOf(req.user!))
  return decision.allowed ? null : sendRateLimited(reply, decision.retryAfterSec)
}

/**
 * A 422 refusal costs one `rejected` hit, and once the hour's refusals are spent the answer is 429
 * instead — the content filter cannot be probed for evasions at full speed.
 */
function refuse(req: FastifyRequest, reply: FastifyReply, body: SocialError): FastifyReply {
  return spend(req, reply, 'rejected') ?? reply.code(422).send(body)
}

/** A replayed POST's answer (step 1 of the create flow, and a concurrent insert's fallback). */
function sendReplay(reply: FastifyReply, outcome: Exclude<ReplayOutcome, { kind: 'none' }>): FastifyReply {
  switch (outcome.kind) {
    case 'replay':
      return reply.code(200).send({ comment: outcome.comment } satisfies CommentResponse)
    case 'deleted':
      return reply.code(410).send({ error: 'comment deleted' } satisfies SocialError)
    case 'id_conflict':
      return reply.code(409).send({ error: 'id_conflict' } satisfies SocialError)
  }
}

// ---------- Subjects ----------

interface Thread {
  franchiseId: string
  franchiseTitle: string
  /** The spoiler gate for `ep:` rooms; null for a post. */
  access: EpisodeAccess | null
}

/**
 * The franchise a thread belongs to, and for an episode room the caller's access. An `ep:` room is
 * resolved by the gate itself (`getEpisodeAccess` joins the part to its franchise, and is null
 * exactly when `resolveSubject` would be), so a room costs one query, not two.
 */
async function resolveThread(userId: string, p: ParsedSubject): Promise<Thread | null> {
  if (p.kind === 'episode') {
    const gate = await getEpisodeAccess(userId, p.mediaId, p.episode)
    return gate ? { franchiseId: gate.franchiseId, franchiseTitle: gate.franchiseTitle, access: gate.access } : null
  }
  const resolved = await resolveSubject(p)
  return resolved ? { ...resolved, access: null } : null
}

/**
 * The franchise a post belongs to, for a save or a hide; null when there is no such post. A PostId
 * resolves as ever (`resolveSubject`). An `ep:` id is Following's "Episode N is out" post, which
 * exists once that episode has aired — watched or not: saving or hiding the post shows nothing of
 * the room, whose comments stay behind the gate.
 */
async function resolvePost(userId: string, p: ParsedSubject): Promise<ResolvedSubject | null> {
  if (p.kind !== 'episode') return resolveSubject(p)
  const gate = await getEpisodeAccess(userId, p.mediaId, p.episode)
  return gate && gate.access !== 'unaired' ? { franchiseId: gate.franchiseId, franchiseTitle: gate.franchiseTitle } : null
}

/**
 * The subject a write or a thread read keys on (social/resolve.ts `canonicalSubject`): once an
 * announcement names a catalogue part, `catalog:<mediaId>` is that announcement's `news:<id>`
 * thread, so a toggle queued, a comment replayed or a hide sent against the old id lands where the
 * feed and adoption put the thread. Every other subject is itself.
 */
async function canonical(p: ParsedSubject): Promise<{ parsed: ParsedSubject; subject: string }> {
  const parsed = await canonicalSubject(p)
  return { parsed, subject: formatSubject(parsed) }
}

/**
 * The keys a DELETE clears: the canonical one and, when it differs, the id as sent — an undo against
 * an old `catalog:` id clears the row adoption moved, and a row a failed adoption left behind (the
 * next research run retries it) is cleared too.
 */
async function deletionKeys(raw: string): Promise<string[]> {
  const parsed = parseSubject(raw)
  if (!parsed) return [raw]
  const { subject } = await canonical(parsed)
  return subject === raw ? [raw] : [subject, raw]
}

export const socialRoutes: FastifyPluginAsync = async (app) => {
  app.addHook('preHandler', app.authenticate)

  // ---------- Likes on a post or an episode room ----------

  app.put('/me/likes', async (req, reply) => {
    const body = subjectBody.safeParse(req.body)
    const parsed = body.success ? parseSubject(body.data.subject) : null
    if (!body.success || !parsed) return invalid(reply)
    const me = req.user!.id
    const target = await canonical(parsed)
    const thread = await resolveThread(me, target.parsed)
    if (!thread) return notFound(reply, 'subject')
    // An episode can be liked once it is OUT, watched or not: its `ep:` subject is also Following's
    // "Episode N is out" post, and a like shows nothing of the room. Reading and writing its
    // comments, their likes and the rating stay behind the full gate (aired AND watched).
    if (thread.access === 'unaired') return episodeLocked(reply, thread.access)
    const limited = spend(req, reply, 'toggle')
    if (limited) return limited
    await putLike(me, target.subject)
    return noContent(reply)
  })

  app.delete('/me/likes', async (req, reply) => {
    const body = subjectBody.safeParse(req.body)
    if (!body.success) return invalid(reply)
    for (const key of await deletionKeys(body.data.subject)) await deleteLike(req.user!.id, key)
    return noContent(reply)
  })

  // ---------- Saves (any feed post) and reminders (PostIds only) ----------

  for (const [path, schema, put, del] of [
    ['/me/saves', feedPostBody, putSave, deleteSave],
    ['/me/reminders', postBody, putReminder, deleteReminder],
  ] as const) {
    app.put(path, async (req, reply) => {
      const body = schema.safeParse(req.body)
      const parsed = body.success ? parseSubject(body.data.postId) : null
      if (!body.success || !parsed) return invalid(reply)
      const me = req.user!.id
      const target = await canonical(parsed)
      const post = await resolvePost(me, target.parsed)
      if (!post) return notFound(reply, 'post')
      const limited = spend(req, reply, 'toggle')
      if (limited) return limited
      await put(me, target.subject, post.franchiseId)
      return noContent(reply)
    })

    app.delete(path, async (req, reply) => {
      const body = schema.safeParse(req.body)
      if (!body.success) return invalid(reply)
      for (const key of await deletionKeys(body.data.postId)) await del(req.user!.id, key)
      return noContent(reply)
    })
  }

  // ---------- Hides: "Not interested" (a post) and "Mute <show>" (a franchise) ----------

  app.get('/me/hides', async (req) => {
    const body: HidesResponse = await listHides(req.user!.id)
    return body
  })

  app.put('/me/hides', async (req, reply) => {
    const body = hideBody.safeParse(req.body)
    if (!body.success) return invalid(reply)
    const me = req.user!.id
    let target = body.data.target
    if (body.data.kind === 'post') {
      const parsed = parseSubject(body.data.target)
      if (!parsed) return invalid(reply)
      const post = await canonical(parsed)
      if (!(await resolvePost(me, post.parsed))) return notFound(reply, 'post')
      target = post.subject
    } else if (!(await resolveFranchise(body.data.target))) {
      return notFound(reply, 'franchise')
    }
    const limited = spend(req, reply, 'toggle')
    if (limited) return limited
    await putHide(me, body.data.kind, target)
    return noContent(reply)
  })

  app.delete('/me/hides', async (req, reply) => {
    const body = hideBody.safeParse(req.body)
    if (!body.success) return invalid(reply)
    const keys = body.data.kind === 'post' ? await deletionKeys(body.data.target) : [body.data.target]
    for (const key of keys) await deleteHide(req.user!.id, body.data.kind, key)
    return noContent(reply)
  })

  // ---------- Episode ratings (spoiler-gated like the room they belong to) ----------

  app.put('/me/ratings', async (req, reply) => {
    const body = ratingBody.safeParse(req.body)
    if (!body.success) return invalid(reply)
    const me = req.user!.id
    const { mediaId, episode, score } = body.data
    const gate = await getEpisodeAccess(me, mediaId, episode)
    if (!gate) return notFound(reply, 'episode')
    if (gate.access !== 'open') return episodeLocked(reply, gate.access)
    const limited = spend(req, reply, 'toggle')
    if (limited) return limited
    await putRating(me, mediaId, episode, score)
    return noContent(reply)
  })

  app.delete('/me/ratings', async (req, reply) => {
    const body = ratingKeyBody.safeParse(req.body)
    if (!body.success) return invalid(reply)
    await deleteRating(req.user!.id, body.data.mediaId, body.data.episode)
    return noContent(reply)
  })

  // ---------- Blocks (both directions are filtered on every read) ----------

  app.get('/me/blocks', async (req) => {
    const body: BlockedUsersResponse = await listBlocks(req.user!.id)
    return body
  })

  app.put('/me/blocks', async (req, reply) => {
    if (!env.SOCIAL_COMMENTS_ENABLED) return commentsDisabled(reply)
    const body = blockBody.safeParse(req.body)
    if (!body.success) return invalid(reply)
    const me = req.user!.id
    if (body.data.userId === me.toLowerCase()) return reply.code(400).send({ error: 'self_block' } satisfies SocialError)
    if (!(await blockTargetExists(body.data.userId))) return notFound(reply, 'user')
    const limited = spend(req, reply, 'block')
    if (limited) return limited
    await putBlock(me, body.data.userId)
    return noContent(reply)
  })

  app.delete('/me/blocks', async (req, reply) => {
    const body = blockBody.safeParse(req.body)
    if (!body.success) return invalid(reply)
    await deleteBlock(req.user!.id, body.data.userId)
    return noContent(reply)
  })

  // ---------- Comment threads ----------

  app.get('/social/comments', async (req, reply) => {
    if (!env.SOCIAL_COMMENTS_ENABLED) return commentsDisabled(reply)
    const query = commentsQuery.safeParse(req.query)
    const parsed = query.success ? parseSubject(query.data.subject) : null
    if (!query.success || !parsed) return invalid(reply)
    const { sort, limit } = query.data

    // `?cursor=` with nothing after it is the first page; anything else must be a cursor we wrote,
    // for this sort (a `top` cursor carries the like count it stopped at, a `latest` one does not).
    let cursor: KeysetCursor | null = null
    if (query.data.cursor) {
      cursor = decodeCursor(query.data.cursor)
      if (!cursor || (sort === 'top') !== (cursor.rank !== undefined)) return invalid(reply)
    }

    // A page is a correlated like count per row: the heavy-read budget, before any query.
    const readLimited = spend(req, reply, 'read')
    if (readLimited) return readLimited

    const me = req.user!.id
    // The thread as everyone reads it; the page names that subject, so a client asking by an old
    // `catalog:` id learns the `news:` id it was adopted into.
    const { parsed: threadSubject, subject } = await canonical(parsed)
    const thread = await resolveThread(me, threadSubject)
    if (!thread) return notFound(reply, 'subject')
    if (thread.access != null && thread.access !== 'open') {
      // Locked: no comment reaches the client, only the global count behind "join N comments".
      const locked: CommentsPage = {
        subject,
        locked: true,
        access: thread.access,
        total: await countVisibleComments(subject),
        items: [],
        nextCursor: null,
      }
      return locked
    }

    const slice = await listComments(me, { subject, sort, cursor, limit })
    const page: CommentsPage = {
      subject,
      locked: false,
      access: thread.access,
      total: slice.total,
      items: slice.items,
      nextCursor: slice.nextCursor,
    }
    return page
  })

  // Create, keyed on the CLIENT's uuid: a retried POST can never double-post. The checks run in
  // the contract's order — replay, profile, subject, gate, content, parent, rate limit, write.
  app.post('/social/comments', async (req, reply) => {
    if (!env.SOCIAL_COMMENTS_ENABLED) return commentsDisabled(reply)
    const body = createCommentBody.safeParse(req.body)
    const parsed = body.success ? parseSubject(body.data.subject) : null
    if (!body.success || !parsed) return invalid(reply)
    const me = req.user!.id
    const { id } = body.data

    // 1. A replay is answered as it stands, before any other check and without spending the limit.
    const replay = await findReplay(id, me)
    if (replay.kind !== 'none') return sendReplay(reply, replay)

    // 2. A public identity, and the current community rules accepted.
    const profile = await loadCommenterProfile(me)
    if (!profile?.handle || !profile.displayName) {
      return reply.code(409).send({ error: 'handle_required' } satisfies SocialError)
    }
    if (profile.termsVersion !== env.SOCIAL_TERMS_VERSION) {
      return reply
        .code(409)
        .send({ error: 'terms_required', currentVersion: env.SOCIAL_TERMS_VERSION } satisfies SocialError)
    }

    // 3–4. The thread exists (keyed on the CANONICAL subject: a comment sent to an adopted
    //      `catalog:` id is stored under the `news:` thread, and the view it answers names it);
    //      an episode room is open to this viewer.
    const { parsed: threadSubject, subject } = await canonical(parsed)
    const thread = await resolveThread(me, threadSubject)
    if (!thread) return notFound(reply, 'subject')
    if (thread.access != null && thread.access !== 'open') return episodeLocked(reply, thread.access)

    // 5. The content filter; the NORMALISED text is what is stored.
    const checked = checkCommentBody(body.data.body)
    if (!checked.ok) return refuse(req, reply, { error: 'content_rejected', reason: checked.reason })

    // 6. A reply's parent: same thread, still visible, nobody blocked.
    const parent = body.data.parentId ? await findReplyParent(body.data.parentId, subject, me) : null
    if (body.data.parentId && !parent) return notFound(reply, 'parent')

    // 7. Only a genuinely new comment spends the limit — a smaller hourly one while the account is
    //    less than a day old.
    const limited = spend(req, reply, commentAction(req.user!))
    if (limited) return limited

    // 8. Insert (+ the reply notification, in the same transaction).
    const created = await insertComment({
      id,
      userId: me,
      subject,
      franchiseId: thread.franchiseId,
      franchiseTitle: thread.franchiseTitle,
      body: checked.text,
      author: { handle: profile.handle, displayName: profile.displayName },
      parent,
    })
    if (created.kind !== 'created') return sendReplay(reply, created)
    return reply.code(201).send({ comment: created.comment } satisfies CommentResponse)
  })

  // The author's own delete (a soft delete; a repeat is 204). Anyone else's comment is 404. Works
  // with comments switched off too: deleting your own content is never switched off.
  app.delete('/social/comments/:id', async (req, reply) => {
    const params = commentParams.safeParse(req.params)
    if (!params.success) return invalid(reply)
    const outcome = await deleteOwnComment(params.data.id, req.user!.id)
    if (outcome === 'not_found') return notFound(reply, 'comment')
    return noContent(reply)
  })

  app.put('/social/comments/:id/like', async (req, reply) => {
    if (!env.SOCIAL_COMMENTS_ENABLED) return commentsDisabled(reply)
    const params = commentParams.safeParse(req.params)
    if (!params.success) return invalid(reply)
    const me = req.user!.id
    const target = await findVisibleComment(params.data.id, me)
    if (!target) return notFound(reply, 'comment')
    const room = parseSubject(target.subject)
    if (room?.kind === 'episode') {
      const gate = await getEpisodeAccess(me, room.mediaId, room.episode)
      if (!gate) return notFound(reply, 'comment')
      if (gate.access !== 'open') return episodeLocked(reply, gate.access)
    }
    const limited = spend(req, reply, 'toggle')
    if (limited) return limited
    await likeComment(me, target, {
      nowMs: Date.now(),
      cooldownMs: env.SOCIAL_LIKE_NOTIFY_COOLDOWN_MINUTES * 60_000,
    })
    return noContent(reply)
  })

  // Always 204, even when the comment is gone: the state the caller asked for holds.
  app.delete('/social/comments/:id/like', async (req, reply) => {
    if (!env.SOCIAL_COMMENTS_ENABLED) return commentsDisabled(reply)
    const params = commentParams.safeParse(req.params)
    if (!params.success) return invalid(reply)
    await unlikeComment(req.user!.id, params.data.id)
    return noContent(reply)
  })

  app.post('/social/comments/:id/report', async (req, reply) => {
    if (!env.SOCIAL_COMMENTS_ENABLED) return commentsDisabled(reply)
    const params = commentParams.safeParse(req.params)
    const body = reportBody.safeParse(req.body)
    if (!params.success || !body.success) return invalid(reply)
    const me = req.user!.id
    const commentId = params.data.id
    // Only a comment the caller can see: not deleted, nobody blocked either way (a hidden one can
    // still be reported), and in an episode room only while that room is OPEN to the caller.
    const target = await findReportTarget(commentId, me)
    if (!target) return notFound(reply, 'comment')
    if (target.authorId === me) return reply.code(409).send({ error: 'own_comment' } satisfies SocialError)
    const room = parseSubject(target.subject)
    if (room?.kind === 'episode') {
      const gate = await getEpisodeAccess(me, room.mediaId, room.episode)
      if (!gate || gate.access !== 'open') return notFound(reply, 'comment')
    }
    const limited = spend(req, reply, 'report')
    if (limited) return limited

    const note = body.data.note == null ? null : normalizeUserText(body.data.note, { multiline: true }) || null
    const { reason } = body.data
    const result = await fileReport(me, commentId, {
      reason,
      note,
      threshold: env.SOCIAL_AUTO_HIDE_REPORTS,
      reporterMinAgeHours: env.SOCIAL_REPORTER_MIN_AGE_HOURS,
    })
    // Reports surface in the operator's server log as well as `npm run moderation -- list` (and the
    // alert webhook, services/moderationAlert.ts). The author's Clerk id is logged HERE only — never
    // in a response or the webhook — so a ban stays possible after the author erases the account
    // (which deletes the reports about their comments).
    const authorClerkId = target.authorClerkId
    if (result.inserted) req.log.warn({ event: 'moderation.report', commentId, reason, authorClerkId })
    if (result.autoHidden) {
      req.log.warn({ event: 'moderation.auto_hidden', commentId, reportCount: result.reportCount, authorClerkId })
    }
    return noContent(reply)
  })

  // ---------- Episode rooms ----------

  app.get('/social/episodes/:mediaId/:episode', async (req, reply) => {
    const params = episodeParams.safeParse(req.params)
    if (!params.success) return invalid(reply)
    const me = req.user!.id
    const { mediaId, episode } = params.data
    const gate = await getEpisodeAccess(me, mediaId, episode)
    if (!gate) return notFound(reply, 'episode')
    const subject = `ep:${mediaId}:${episode}`
    const stats = await episodeRoomStats(me, mediaId, episode, subject)
    const room: EpisodeRoom = {
      subject,
      franchiseId: gate.franchiseId,
      mediaId,
      episode,
      access: gate.access,
      commentCount: stats.commentCount,
      likeCount: stats.likeCount,
      liked: stats.liked,
      rating: {
        count: stats.rating.count,
        // The room's verdict is itself a spoiler: withheld until the room is open.
        average: gate.access === 'open' ? stats.rating.average : null,
        yours: stats.rating.yours,
      },
    }
    return room
  })
}
