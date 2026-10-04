import { relations, sql } from 'drizzle-orm'
import {
  bigint,
  boolean,
  foreignKey,
  index,
  integer,
  jsonb,
  pgTable,
  primaryKey,
  real,
  text,
  timestamp,
  uniqueIndex,
  uuid,
} from 'drizzle-orm/pg-core'
import type {
  ArtworkGallery,
  ArtworkSet,
  CatalogVideo,
  EpisodeMeta,
  FranchiseEnrichment,
  FranchiseUpcoming,
  RelatedTitle,
  WatchProvider,
} from '../types/api.js'

// ---------- Cached AniList catalogue ----------

// One trackable installment (a single season / movie / OVA / special), cached locally.
// source 'anilist': id = AniList media id, externalId null.
// source 'tmdb': id = TMDB_ID_OFFSET + TMDB season id (see tmdb/mapping.ts), externalId = TMDB season id.
export const media = pgTable(
  'media',
  {
    id: integer('id').primaryKey(),
    source: text('source').notNull().default('anilist'), // anilist | tmdb
    externalId: integer('external_id'), // provider-native id for non-anilist rows
    titleRomaji: text('title_romaji'),
    titleEnglish: text('title_english'),
    titleNative: text('title_native'),
    synonyms: jsonb('synonyms').$type<string[]>().default([]),
    format: text('format'), // TV | TV_SHORT | MOVIE | OVA | ONA | SPECIAL | MUSIC
    status: text('status'), // FINISHED | RELEASING | NOT_YET_RELEASED | CANCELLED | HIATUS
    episodes: integer('episodes'),
    cover: text('cover'),
    banner: text('banner'),
    artwork: jsonb('artwork').$type<ArtworkGallery>(),
    description: text('description'),
    genres: jsonb('genres').$type<string[]>().default([]),
    // Studios (AniList animation studios) or networks (TMDB) — names only, for the detail meta line.
    studios: jsonb('studios').$type<string[]>().default([]),
    // Per-episode metadata. TMDB: full (title/overview/air_date/still/runtime) from the season
    // endpoint. AniList: best-effort titles/thumbnails from streamingEpisodes (no per-ep overview).
    episodesList: jsonb('episodes_list').$type<EpisodeMeta[]>().default([]),
    // Catalogue-curated trailers/teasers for this exact part. Video bytes are never hosted here.
    videos: jsonb('videos').$type<CatalogVideo[]>().default([]),
    // nextAiringEpisode snapshot: { episode, airingAt(seconds) } | null
    nextAiringEpisode: jsonb('next_airing_episode').$type<{ episode: number; airingAt: number } | null>(),
    seasonYear: integer('season_year'),
    season: text('season'),
    popularity: integer('popularity'),
    trending: integer('trending'),
    // Exact last-aired time (ms epoch) from airingSchedules, kept fresh by the sync job.
    lastAiredAt: bigint('last_aired_at', { mode: 'number' }),
    fetchedAt: timestamp('fetched_at', { withTimezone: true }).defaultNow().notNull(),
  },
  (t) => [
    uniqueIndex('media_source_external_uq')
      .on(t.source, t.externalId)
      .where(sql`${t.source} = 'tmdb'`),
    // Search is a local indexed read in the steady state. `simple` keeps romanized titles and
    // proper nouns intact; the query uses prefix lexemes so typeahead remains index-backed.
    index('media_title_search_idx').using(
      'gin',
      sql`to_tsvector('simple', coalesce(${t.titleEnglish}, '') || ' ' || coalesce(${t.titleRomaji}, '') || ' ' || coalesce(${t.titleNative}, '') || ' ' || coalesce(${t.synonyms}::text, ''))`,
    ),
  ],
)

// Directed relation edges between media (PREQUEL, SEQUEL, SIDE_STORY, PARENT, ALTERNATIVE, ...).
export const mediaRelations = pgTable(
  'media_relations',
  {
    mediaId: integer('media_id').notNull(),
    relatedId: integer('related_id').notNull(),
    relationType: text('relation_type').notNull(),
  },
  (t) => [
    primaryKey({ columns: [t.mediaId, t.relatedId, t.relationType] }),
    index('media_relations_media_idx').on(t.mediaId),
  ],
)

// ---------- Canonical franchises ----------

export const franchise = pgTable(
  'franchise',
  {
    id: uuid('id').primaryKey().defaultRandom(),
    source: text('source').notNull().default('anilist'), // anilist | tmdb
    externalId: integer('external_id'), // TMDB show id for tmdb franchises
    title: text('title').notNull(),
    primaryMediaId: integer('primary_media_id'),
    cover: text('cover'),
    banner: text('banner'),
    artwork: jsonb('artwork').$type<ArtworkGallery>(),
    description: text('description'),
    genres: jsonb('genres').$type<string[]>().default([]),
    groupingSource: text('grouping_source').notNull().default('relations'), // relations | llm | manual | tmdb
    groupingModel: text('grouping_model'),
    confidence: real('confidence'),
    // Web-sourced "what's next" news (announced/airing seasons & films). See FranchiseUpcoming.
    upcoming: jsonb('upcoming').$type<FranchiseUpcoming>(),
    // Deep catalogue metadata kept off the interactive provider search path.
    enrichment: jsonb('enrichment').$type<FranchiseEnrichment>(),
    createdAt: timestamp('created_at', { withTimezone: true }).defaultNow().notNull(),
    updatedAt: timestamp('updated_at', { withTimezone: true }).defaultNow().notNull(),
  },
  (t) => [
    // One TMDB show can never become two franchises.
    uniqueIndex('franchise_source_external_uq')
      .on(t.source, t.externalId)
      .where(sql`${t.source} = 'tmdb'`),
    index('franchise_title_search_idx').using(
      'gin',
      sql`to_tsvector('simple', coalesce(${t.title}, ''))`,
    ),
  ],
)

// A media belongs to exactly one franchise (media_id is the PK).
export const franchiseMember = pgTable(
  'franchise_member',
  {
    mediaId: integer('media_id').primaryKey(),
    franchiseId: uuid('franchise_id')
      .notNull()
      .references(() => franchise.id, { onDelete: 'cascade' }),
    partKind: text('part_kind').notNull(), // season | movie | ova | ona | special | music
    sequence: integer('sequence').notNull().default(0),
    watchOrder: integer('watch_order').notNull().default(0),
    relationship: text('relationship'),
    optional: boolean('optional').notNull().default(false),
    label: text('label'),
    addedAt: timestamp('added_at', { withTimezone: true }).defaultNow().notNull(),
  },
  (t) => [index('franchise_member_franchise_idx').on(t.franchiseId)],
)

// ---------- Users & their library ----------

export const users = pgTable('users', {
  id: uuid('id').primaryKey().defaultRandom(),
  clerkId: text('clerk_id').notNull().unique(),
  email: text('email'),
  lastOpenedAt: bigint('last_opened_at', { mode: 'number' }).default(0).notNull(),
  // The visit BEFORE the current one. POST /me/opened moves last_opened_at here atomically, so every
  // read of "since your last visit" compares against a real previous visit rather than the stamp
  // the same session just wrote (the pre-0010 echo bug). 0 = never shifted (see services/visits.ts).
  prevOpenedAt: bigint('prev_opened_at', { mode: 'number' }).default(0).notNull(),
  createdAt: timestamp('created_at', { withTimezone: true }).defaultNow().notNull(),
})

export const subscriptions = pgTable(
  'subscriptions',
  {
    userId: uuid('user_id')
      .notNull()
      .references(() => users.id, { onDelete: 'cascade' }),
    franchiseId: uuid('franchise_id')
      .notNull()
      .references(() => franchise.id, { onDelete: 'cascade' }),
    // text(), not a pg enum — the status vocabulary can grow without a migration.
    status: text('status').notNull().default('planned'), // watching | completed | planned | paused | dropped
    createdAt: timestamp('created_at', { withTimezone: true }).defaultNow().notNull(),
  },
  (t) => [primaryKey({ columns: [t.userId, t.franchiseId] })],
)

// Per-user, per-part watched-episode count.
export const progress = pgTable(
  'progress',
  {
    userId: uuid('user_id')
      .notNull()
      .references(() => users.id, { onDelete: 'cascade' }),
    mediaId: integer('media_id').notNull(),
    episodesWatched: integer('episodes_watched').notNull().default(0),
    updatedAt: timestamp('updated_at', { withTimezone: true }).defaultNow().notNull(),
  },
  (t) => [primaryKey({ columns: [t.userId, t.mediaId] })],
)

// One watch of a franchise — the implicit first one, or a rewatch — so "Watched twice" and where a
// stopped rewatch puts the show back survive a new phone (device-local until 2 Oct 2026). `id` is
// CLIENT-generated: the upsert key that makes a replayed PUT safe. A deleted session is a TOMBSTONE
// (`deleted_at`), so a late replay from another device cannot bring it back. Times are the client's
// ms epochs; `completed_at = 0` is its "finished, date unknown" (the implicit first watch). User
// data — erased with the account (DELETE /me) and returned by GET /me/export.
export const watchSessions = pgTable(
  'watch_sessions',
  {
    id: uuid('id').primaryKey(),
    userId: uuid('user_id')
      .notNull()
      .references(() => users.id, { onDelete: 'cascade' }),
    franchiseId: uuid('franchise_id')
      .notNull()
      .references(() => franchise.id, { onDelete: 'cascade' }),
    /** null = the whole franchise; else the one part (media id) the session covers. */
    scopeMediaId: integer('scope_media_id'),
    /** 1 = first watch, 2 = second, … */
    ordinal: integer('ordinal').notNull(),
    startedAt: bigint('started_at', { mode: 'number' }),
    completedAt: bigint('completed_at', { mode: 'number' }),
    cancelledAt: bigint('cancelled_at', { mode: 'number' }),
    cancelledAtEpisode: integer('cancelled_at_episode'),
    /** Episodes the session covers; 0 when unknown. */
    episodes: integer('episodes').notNull().default(0),
    /** Where the show stood before the rewatch zeroed it (media id → episodes), for "Stop rewatch". */
    restoreProgress: jsonb('restore_progress').$type<Record<string, number>>(),
    restoreStatus: text('restore_status'),
    createdAt: timestamp('created_at', { withTimezone: true }).defaultNow().notNull(),
    updatedAt: timestamp('updated_at', { withTimezone: true }).defaultNow().notNull(),
    deletedAt: timestamp('deleted_at', { withTimezone: true }),
  },
  (t) => [index('watch_sessions_user_idx').on(t.userId, t.franchiseId)],
)

/** Durable, inspectable identity bridges between one canonical franchise and external catalogues. */
export const catalogLinks = pgTable(
  'catalog_links',
  {
    franchiseId: uuid('franchise_id')
      .notNull()
      .references(() => franchise.id, { onDelete: 'cascade' }),
    provider: text('provider').notNull(),
    mediaType: text('media_type').notNull(),
    externalId: integer('external_id'),
    status: text('status').notNull().default('matched'), // matched | unmatched | rejected
    matchMethod: text('match_method').notNull().default('catalogue'),
    confidence: real('confidence'),
    evidence: jsonb('evidence').$type<Record<string, unknown>>().default({}),
    checkedAt: timestamp('checked_at', { withTimezone: true }).defaultNow().notNull(),
    createdAt: timestamp('created_at', { withTimezone: true }).defaultNow().notNull(),
    updatedAt: timestamp('updated_at', { withTimezone: true }).defaultNow().notNull(),
  },
  (t) => [
    primaryKey({ columns: [t.franchiseId, t.provider] }),
    uniqueIndex('catalog_links_provider_external_uq')
      .on(t.provider, t.mediaType, t.externalId)
      .where(sql`${t.status} = 'matched' and ${t.externalId} is not null`),
    index('catalog_links_external_idx').on(t.provider, t.externalId),
  ],
)

export const userPreferences = pgTable('user_preferences', {
  userId: uuid('user_id')
    .primaryKey()
    .references(() => users.id, { onDelete: 'cascade' }),
  country: text('country'),
  language: text('language').notNull().default('en'),
  providerIds: jsonb('provider_ids').$type<number[]>().notNull().default([]),
  updatedAt: timestamp('updated_at', { withTimezone: true }).defaultNow().notNull(),
})

// The viewer's audience (Anime / TV / Both — `Audience`, services/audience.ts): which catalogue the
// server suggests titles from. Its OWN table, not a column on user_preferences: the API is served
// from the working tree, so code can run before its migration has, and a missing column would fail
// every read and upsert of user_preferences on every existing route — a missing table fails only
// the audience's own tolerant read. No row = not chosen yet. User data: erased with the account
// (DELETE /me) and returned by GET /me/export.
export const userAudience = pgTable('user_audience', {
  userId: uuid('user_id')
    .primaryKey()
    .references(() => users.id, { onDelete: 'cascade' }),
  /** 'anime' | 'tv' | 'both' */
  audience: text('audience').notNull(),
  updatedAt: timestamp('updated_at', { withTimezone: true }).defaultNow().notNull(),
})

export const watchAvailabilitySnapshots = pgTable(
  'watch_availability_snapshots',
  {
    franchiseId: uuid('franchise_id')
      .notNull()
      .references(() => franchise.id, { onDelete: 'cascade' }),
    country: text('country').notNull(),
    status: text('status').notNull(),
    providers: jsonb('providers').$type<WatchProvider[]>().notNull().default([]),
    link: text('link'),
    checkedAt: timestamp('checked_at', { withTimezone: true }).defaultNow().notNull(),
    expiresAt: timestamp('expires_at', { withTimezone: true }).notNull(),
  },
  (t) => [
    primaryKey({ columns: [t.franchiseId, t.country] }),
    index('watch_availability_country_expiry_idx').on(t.country, t.expiresAt),
  ],
)

// One franchise's source-native "if you liked this" list (AniList community recommendations, TMDB
// /recommendations), replaced atomically on every refresh. The ranker (services/recommendationRank)
// spreads ONE vote per followed franchise over this list, so the list's order and depth matter.
export const recommendationEdges = pgTable(
  'recommendation_edges',
  {
    franchiseId: uuid('franchise_id')
      .notNull()
      .references(() => franchise.id, { onDelete: 'cascade' }),
    source: text('source').notNull(),
    externalId: integer('external_id').notNull(),
    // Write-time resolution only (kept for the index); the ranker resolves ownership LIVE on read.
    targetFranchiseId: uuid('target_franchise_id').references(() => franchise.id, { onDelete: 'set null' }),
    /** Legacy strength (AniList votes). Superseded by `rank` + `votes`. */
    score: real('score'),
    title: text('title').notNull(),
    year: integer('year'),
    images: jsonb('images').$type<RelatedTitle['images']>().notNull(),
    /** 0-based position in the seed's list, strongest first. Null only on rows from before 0009. */
    rank: integer('rank'),
    /** AniList: the community vote count behind the pair. TMDB only ranks, so null there. */
    votes: integer('votes'),
    checkedAt: timestamp('checked_at', { withTimezone: true }).defaultNow().notNull(),
  },
  (t) => [
    primaryKey({ columns: [t.franchiseId, t.source, t.externalId] }),
    index('recommendation_edges_target_idx').on(t.targetFranchiseId),
  ],
)

// One row per recommended title, SHARED by every user and every seed that points at it: the facts
// the ranker filters and scores on, plus the title's series identity. An AniList recommendation
// often names a later season ("My Hero Academia Season 4"); `root_*` is the series it belongs to
// (the first season), which is what a recommendation is keyed, titled and materialised by.
export const recommendationTargets = pgTable(
  'recommendation_targets',
  {
    source: text('source').notNull(), // anilist | tmdb
    externalId: integer('external_id').notNull(), // AniList media id | TMDB show id
    title: text('title').notNull(),
    year: integer('year'),
    images: jsonb('images').$type<ArtworkSet>().notNull(),
    format: text('format'), // AniList format; 'TV' for TMDB
    status: text('status'), // AniList status; null for TMDB (the recommendation payload has none)
    episodes: integer('episodes'),
    /** 0–100 on both sources: AniList averageScore (meanScore fallback), TMDB vote_average × 10. */
    averageScore: real('average_score'),
    /** TMDB vote_count (AniList's sample size is `popularity`). */
    voteCount: integer('vote_count'),
    popularity: real('popularity'),
    genres: jsonb('genres').$type<string[]>().notNull().default([]),
    isAdult: boolean('is_adult').notNull().default(false),
    countryOfOrigin: text('country_of_origin'),
    /** The title or a known part of its series is releasing. */
    airing: boolean('airing').notNull().default(false),
    /** A known part of its series is announced but unreleased (a "new season announced"). */
    announced: boolean('announced').notNull().default(false),
    /** TMDB first_air_date / AniList start date (YYYY-MM-DD) when complete. */
    releaseDate: text('release_date'),
    rootId: integer('root_id').notNull(),
    rootTitle: text('root_title').notNull(),
    rootYear: integer('root_year'),
    rootFormat: text('root_format'),
    rootEpisodes: integer('root_episodes'),
    rootImages: jsonb('root_images').$type<ArtworkSet>().notNull(),
    /** Known ids of the same series (relation component, as far as it was walked). */
    memberIds: jsonb('member_ids').$type<number[]>().notNull().default([]),
    /** Ids related as a separate work of the same universe (spin-off, alternative, …). */
    worldIds: jsonb('world_ids').$type<number[]>().notNull().default([]),
    rootCheckedAt: timestamp('root_checked_at', { withTimezone: true }).defaultNow().notNull(),
    checkedAt: timestamp('checked_at', { withTimezone: true }).defaultNow().notNull(),
  },
  (t) => [
    primaryKey({ columns: [t.source, t.externalId] }),
    index('recommendation_targets_root_idx').on(t.source, t.rootId),
  ],
)

// A user's verdict on a recommendation: "Not interested" (dismissed) or "Mark as watched" (seen).
// Keyed by the recommendation's stable key (`anilist:<root id>` / `tmdb:<show id>`). User data —
// erased with the account (DELETE /me).
export const recommendationFeedback = pgTable(
  'recommendation_feedback',
  {
    userId: uuid('user_id')
      .notNull()
      .references(() => users.id, { onDelete: 'cascade' }),
    key: text('key').notNull(),
    kind: text('kind').notNull(), // dismissed | seen
    createdAt: timestamp('created_at', { withTimezone: true }).defaultNow().notNull(),
  },
  (t) => [primaryKey({ columns: [t.userId, t.key] })],
)

// ---------- Social (the Today feed) ----------
// Every table here is user data. DELETE /me erases it in both directions (routes/me.ts
// `accountErasurePlan`) and GET /me/export returns it. Subjects are the text ids of
// social/subjects.ts: `news:<announcement uuid>`, `catalog:<media id>`,
// `trailer:<franchise uuid>:<site>:<video id>` and `ep:<media id>:<episode>`.

/** Public identity. Never the email, never Clerk's display name as-is. */
export const userProfiles = pgTable(
  'user_profiles',
  {
    userId: uuid('user_id').primaryKey().references(() => users.id, { onDelete: 'cascade' }),
    /** Lowercase `[a-z0-9_.]{3,20}` (social/identity.ts). Null until chosen at first reply. */
    handle: text('handle'),
    /** The first name the user confirmed. 1–40 code points. */
    displayName: text('display_name'),
    termsAcceptedAt: timestamp('terms_accepted_at', { withTimezone: true }),
    /** The community-rules version accepted (env SOCIAL_TERMS_VERSION). */
    termsVersion: text('terms_version'),
    createdAt: timestamp('created_at', { withTimezone: true }).defaultNow().notNull(),
    updatedAt: timestamp('updated_at', { withTimezone: true }).defaultNow().notNull(),
  },
  // Postgres allows many NULLs under a unique index, so profiles without a handle coexist.
  (t) => [uniqueIndex('user_profiles_handle_uq').on(t.handle)],
)

/** One flat thread per subject. `id` is CLIENT-generated: the upsert key that makes a retried POST safe. */
export const comments = pgTable(
  'comments',
  {
    id: uuid('id').primaryKey(),
    /** The author. */
    userId: uuid('user_id').notNull().references(() => users.id, { onDelete: 'cascade' }),
    subject: text('subject').notNull(),
    franchiseId: uuid('franchise_id').notNull().references(() => franchise.id, { onDelete: 'cascade' }),
    /** "Replied to you". Flat thread, one level of reference. */
    parentId: uuid('parent_id'),
    /** NFC-normalised, 1–280 code points. '' once soft-deleted. */
    body: text('body').notNull(),
    createdAt: timestamp('created_at', { withTimezone: true }).defaultNow().notNull(),
    /** Author deleted it. Body is erased; the row stays as a tombstone for idempotency. */
    deletedAt: timestamp('deleted_at', { withTimezone: true }),
    /** Moderation: auto-hidden after N reports, or by the operator. */
    hiddenAt: timestamp('hidden_at', { withTimezone: true }),
    hiddenReason: text('hidden_reason'), // reports | operator
    /** Distinct reporters. Denormalised, incremented in the report transaction, reset on restore. */
    reportCount: integer('report_count').notNull().default(0),
  },
  (t) => [
    // A reply OUTLIVES its parent: when the parent's author erases their account the reply stays,
    // as a top-level comment of the same thread. SET NULL, never CASCADE.
    foreignKey({ name: 'comments_parent_id_fk', columns: [t.parentId], foreignColumns: [t.id] }).onDelete('set null'),
    index('comments_subject_created_idx').on(t.subject, t.createdAt, t.id),
    index('comments_user_created_idx').on(t.userId, t.createdAt),
    index('comments_parent_idx').on(t.parentId),
  ],
)

/** Likes on a post or an episode (subject). Likes on comments live in comment_likes. */
export const likes = pgTable(
  'likes',
  {
    userId: uuid('user_id').notNull().references(() => users.id, { onDelete: 'cascade' }),
    subject: text('subject').notNull(),
    createdAt: timestamp('created_at', { withTimezone: true }).defaultNow().notNull(),
  },
  (t) => [primaryKey({ columns: [t.userId, t.subject] }), index('likes_subject_idx').on(t.subject)],
)

export const commentLikes = pgTable(
  'comment_likes',
  {
    userId: uuid('user_id').notNull().references(() => users.id, { onDelete: 'cascade' }),
    commentId: uuid('comment_id').notNull().references(() => comments.id, { onDelete: 'cascade' }),
    createdAt: timestamp('created_at', { withTimezone: true }).defaultNow().notNull(),
  },
  (t) => [primaryKey({ columns: [t.userId, t.commentId] }), index('comment_likes_comment_idx').on(t.commentId)],
)

export const saves = pgTable(
  'saves',
  {
    userId: uuid('user_id').notNull().references(() => users.id, { onDelete: 'cascade' }),
    postId: text('post_id').notNull(),
    franchiseId: uuid('franchise_id').notNull().references(() => franchise.id, { onDelete: 'cascade' }),
    createdAt: timestamp('created_at', { withTimezone: true }).defaultNow().notNull(),
  },
  (t) => [
    primaryKey({ columns: [t.userId, t.postId] }),
    index('saves_user_created_idx').on(t.userId, t.createdAt),
    index('saves_post_idx').on(t.postId),
  ],
)

/** Reminders. The client schedules dated ones locally; research fans undated ones out (news/service.ts fanOut). */
export const reminders = pgTable(
  'reminders',
  {
    userId: uuid('user_id').notNull().references(() => users.id, { onDelete: 'cascade' }),
    postId: text('post_id').notNull(),
    franchiseId: uuid('franchise_id').notNull().references(() => franchise.id, { onDelete: 'cascade' }),
    createdAt: timestamp('created_at', { withTimezone: true }).defaultNow().notNull(),
  },
  (t) => [primaryKey({ columns: [t.userId, t.postId] }), index('reminders_post_idx').on(t.postId)],
)

/** "Not interested" (kind post, target = post id) and "Mute <show>" (kind show, target = franchise uuid). */
export const feedHides = pgTable(
  'feed_hides',
  {
    userId: uuid('user_id').notNull().references(() => users.id, { onDelete: 'cascade' }),
    kind: text('kind').notNull(), // post | show
    target: text('target').notNull(),
    createdAt: timestamp('created_at', { withTimezone: true }).defaultNow().notNull(),
  },
  (t) => [primaryKey({ columns: [t.userId, t.kind, t.target] }), index('feed_hides_target_idx').on(t.kind, t.target)],
)

/** The emoji slider. score 0–100. The average is real: AVG over raters. */
export const episodeRatings = pgTable(
  'episode_ratings',
  {
    userId: uuid('user_id').notNull().references(() => users.id, { onDelete: 'cascade' }),
    mediaId: integer('media_id').notNull(),
    episode: integer('episode').notNull(),
    score: integer('score').notNull(),
    createdAt: timestamp('created_at', { withTimezone: true }).defaultNow().notNull(),
    updatedAt: timestamp('updated_at', { withTimezone: true }).defaultNow().notNull(),
  },
  (t) => [
    primaryKey({ columns: [t.userId, t.mediaId, t.episode] }),
    index('episode_ratings_episode_idx').on(t.mediaId, t.episode),
  ],
)

/** user_id blocked blocked_user_id. Reads filter BOTH directions. */
export const blocks = pgTable(
  'blocks',
  {
    userId: uuid('user_id').notNull().references(() => users.id, { onDelete: 'cascade' }),
    blockedUserId: uuid('blocked_user_id').notNull().references(() => users.id, { onDelete: 'cascade' }),
    createdAt: timestamp('created_at', { withTimezone: true }).defaultNow().notNull(),
  },
  (t) => [primaryKey({ columns: [t.userId, t.blockedUserId] }), index('blocks_blocked_idx').on(t.blockedUserId)],
)

/** One report per (reporter, comment). */
export const reports = pgTable(
  'reports',
  {
    id: uuid('id').primaryKey().defaultRandom(),
    /** The reporter. */
    userId: uuid('user_id').notNull().references(() => users.id, { onDelete: 'cascade' }),
    commentId: uuid('comment_id').notNull().references(() => comments.id, { onDelete: 'cascade' }),
    reason: text('reason').notNull(), // spam | harassment | hate | sexual | violence | spoiler | other
    note: text('note'),
    createdAt: timestamp('created_at', { withTimezone: true }).defaultNow().notNull(),
    resolvedAt: timestamp('resolved_at', { withTimezone: true }),
    resolution: text('resolution'), // hidden | dismissed
  },
  (t) => [
    uniqueIndex('reports_user_comment_uq').on(t.userId, t.commentId),
    index('reports_comment_idx').on(t.commentId),
    index('reports_open_idx').on(t.resolvedAt, t.createdAt),
  ],
)

// Keyed on the Clerk identity, NOT users.id, and with NO foreign key. A ban must survive DELETE /me
// (the account's one disclosed retention) or deleting and signing back in would lift it.
export const moderationBans = pgTable('moderation_bans', {
  clerkId: text('clerk_id').primaryKey(),
  reason: text('reason'),
  createdAt: timestamp('created_at', { withTimezone: true }).defaultNow().notNull(),
  liftedAt: timestamp('lifted_at', { withTimezone: true }),
})

// ---------- Announcements & notifications ----------

// One row per distinct piece of upcoming-installment news for a franchise ("Season 4",
// "Infinity Castle Part 2"), written by the news agent. Re-observations of the same news
// bump lastSeenAt; a status upgrade (rumored → announced → dated) or a release window
// materially changing is what triggers notifications, not the row's existence.
export const announcements = pgTable(
  'announcements',
  {
    id: uuid('id').primaryKey().defaultRandom(),
    franchiseId: uuid('franchise_id')
      .notNull()
      .references(() => franchise.id, { onDelete: 'cascade' }),
    // Normalized form of `next` ("season 4") so the same installment reported with varying
    // wording across runs maps to one row. Unique per franchise.
    dedupeKey: text('dedupe_key').notNull(),
    status: text('status').notNull(), // rumored | announced_no_date | announced | upcoming_dated | airing | recently_aired | concluded
    next: text('next').notNull(), // e.g. "Season 4", "Infinity Castle - Part 2 (movie)"
    release: text('release').notNull(), // human-readable window: "2026-10", "January 2027", "TBA"
    note: text('note'),
    source: text('source'),
    firstSeenAt: timestamp('first_seen_at', { withTimezone: true }).defaultNow().notNull(),
    lastSeenAt: timestamp('last_seen_at', { withTimezone: true }).defaultNow().notNull(),
  },
  (t) => [uniqueIndex('announcements_franchise_dedupe_idx').on(t.franchiseId, t.dedupeKey)],
)

/** Immutable research snapshots. `announcements` remains the latest state for fast reads. */
export const announcementObservations = pgTable(
  'announcement_observations',
  {
    id: uuid('id').primaryKey().defaultRandom(),
    franchiseId: uuid('franchise_id')
      .notNull()
      .references(() => franchise.id, { onDelete: 'cascade' }),
    announcementId: uuid('announcement_id').references(() => announcements.id, { onDelete: 'set null' }),
    dedupeKey: text('dedupe_key').notNull(),
    status: text('status').notNull(),
    next: text('next').notNull(),
    release: text('release').notNull(),
    note: text('note'),
    observedAt: timestamp('observed_at', { withTimezone: true }).defaultNow().notNull(),
  },
  (t) => [index('announcement_observations_franchise_idx').on(t.franchiseId, t.observedAt)],
)

export const announcementEvidence = pgTable(
  'announcement_evidence',
  {
    id: uuid('id').primaryKey().defaultRandom(),
    observationId: uuid('observation_id')
      .notNull()
      .references(() => announcementObservations.id, { onDelete: 'cascade' }),
    url: text('url').notNull(),
    publisher: text('publisher'),
    publishedAt: text('published_at'),
    tier: text('tier').notNull().default('unknown'),
    primary: boolean('primary').notNull().default(false),
  },
  (t) => [
    uniqueIndex('announcement_evidence_observation_url_uq').on(t.observationId, t.url),
    index('announcement_evidence_observation_idx').on(t.observationId),
  ],
)

// Per-user notification inbox. News rows are fanned out from announcements to subscribers (and
// reminder holders) at detection time; social rows (reply, like_comment) are written by the comment
// transaction. Reads are a single indexed scan; readAt is null until the client acknowledges.
export const notifications = pgTable(
  'notifications',
  {
    id: uuid('id').primaryKey().defaultRandom(),
    userId: uuid('user_id')
      .notNull()
      .references(() => users.id, { onDelete: 'cascade' }),
    franchiseId: uuid('franchise_id')
      .notNull()
      .references(() => franchise.id, { onDelete: 'cascade' }),
    announcementId: uuid('announcement_id').references(() => announcements.id, { onDelete: 'cascade' }),
    kind: text('kind').notNull(), // news_rumored | news_announced | news_dated | reply | like_comment
    title: text('title').notNull(), // franchise title, e.g. "Jujutsu Kaisen"
    body: text('body').notNull(), // news: server text, e.g. "Season 4 announced — release TBA"; social kinds: '' (the excerpt is read live)
    createdAt: timestamp('created_at', { withTimezone: true }).defaultNow().notNull(),
    readAt: timestamp('read_at', { withTimezone: true }),
    /** Who did it (reply, like_comment). Their account's erasure removes the row. */
    actorUserId: uuid('actor_user_id').references(() => users.id, { onDelete: 'cascade' }),
    /** Distinct actors folded into this row (like_comment aggregation). 0 for news kinds. */
    actorCount: integer('actor_count').notNull().default(0),
    /** The social thread (ThreadSubject) for reply / like_comment. */
    subject: text('subject'),
    /** The feed post the row opens (PostId): news kinds → `news:<announcementId>`; social kinds on a post thread → the subject. */
    postId: text('post_id'),
    /** reply: the reply itself. like_comment: YOUR comment that was liked. */
    commentId: uuid('comment_id').references(() => comments.id, { onDelete: 'cascade' }),
  },
  (t) => [
    index('notifications_user_created_idx').on(t.userId, t.createdAt),
    index('notifications_actor_idx').on(t.actorUserId),
    index('notifications_subject_idx').on(t.subject),
    index('notifications_post_idx').on(t.postId),
    // At most ONE unread like_comment row per (recipient, comment): the aggregation target.
    uniqueIndex('notifications_like_unread_uq')
      .on(t.userId, t.commentId)
      .where(sql`${t.kind} = 'like_comment' and ${t.readAt} is null`),
  ],
)

// Cron / sync bookkeeping (single-row keyed values).
export const syncState = pgTable('sync_state', {
  key: text('key').primaryKey(),
  value: jsonb('value').$type<Record<string, unknown>>(),
  updatedAt: timestamp('updated_at', { withTimezone: true }).defaultNow().notNull(),
})

// ---------- ORM relations (for query convenience) ----------

export const franchiseRel = relations(franchise, ({ many }) => ({
  members: many(franchiseMember),
}))

export const franchiseMemberRel = relations(franchiseMember, ({ one }) => ({
  franchise: one(franchise, { fields: [franchiseMember.franchiseId], references: [franchise.id] }),
  media: one(media, { fields: [franchiseMember.mediaId], references: [media.id] }),
}))
