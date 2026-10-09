# CLAUDE.md

Working notes for agents. **`README.md` covers the architecture, what each top-level dir is, and
how to run the backend + iOS app — read it first; this file does not repeat it.** Below is only the
stuff that isn't obvious from reading the code: conventions, workflows, and gotchas.

## Where things live

- `server/` — Fastify + Drizzle + Postgres backend. The only part with automated tests.
- `ios/` — SwiftUI app (XcodeGen-generated project). `ios/README.md` has the iOS-specific setup.
- `docs/api-contract.md` — the REST contract both sides build against. **Change this whenever a
  route's request/response shape changes**; the iOS models (`ios/Sources/Models/Models.swift`) and
  server view-models (`server/src/services/franchiseView.ts`, `types/api.ts`) must stay in sync with it.
- `legacy-web/` — the retired React/Vite app. Reference only; do not extend it.

## Commands (run from `server/`)

```bash
npm run typecheck      # tsc --noEmit — run after any server edit
npm test               # vitest (grouping logic). Fast, no DB needed.
npm run dev            # tsx watch, http://localhost:8787
npm run db:generate    # regenerate SQL migration after editing src/db/schema.ts
npm run db:migrate     # apply migrations to DATABASE_URL
npm run seed -- 60     # seed N trending franchises (hits AniList + LLM)
npm run group -- 16498 # group one franchise by AniList media id
npm run tv -- 95396    # materialize one TV franchise by TMDB show id (needs TMDB_ACCESS_TOKEN)
npm run moderation -- list   # the report queue; `-- help` for show/hide/restore/dismiss/ban/unban/reset-identity/clerk-delete
```

iOS has no CLI test/build flow here — after editing `project.yml` run `cd ios && xcodegen generate`,
then build in Xcode (or `xcodebuild -scheme Previously` — a shared scheme exists for CLI builds).
**Never hand-edit `Previously.xcodeproj`** (gitignored, regenerated).

## Two sources: AniList (anime) + TMDB (general TV)

Franchises carry `source` (`anilist` | `tmdb`); a franchise never mixes sources.
TV is deterministic — one TMDB show = one franchise, seasons as members (`sequence` =
season_number), **zero LLM**; all mapping lives in `src/tmdb/mapping.ts` (pure, unit-tested).
TMDB media rows share the integer `media.id` keyspace via `id = 1e9 + tmdb season id` — never
change `TMDB_ID_OFFSET`. JP animation belongs to AniList, so its TMDB twin is suppressed — enforced
inside `ensureTvFranchise` (the only thing that creates a TMDB franchise), *not* in its callers, so
`npm run tv` and any future call site inherit the rule. Search/trending pre-filter too, to skip the
`/tv/{id}` fetch.
TMDB air dates are **date-only**; `airingAt` is synthesized at 17:00 UTC, so iOS gates episode
notifications/Live Activities to `source == .anilist`. `TMDB_ACCESS_TOKEN` unset = TV disabled
(anime-only mode; everything still works). Sync jobs must stay source-filtered — never feed
offset ids to AniList (`refreshAiring`/`attachNewSeasons` filter on `source='anilist'`).

## Server conventions

- **ESM with explicit `.js` import extensions.** `verbatimModuleSyntax` + `moduleResolution:
  Bundler` are on, so imports of local `.ts` files must be written `from './foo.js'` and
  type-only imports must use `import type`. Match the existing style or `tsc` fails.
- **Env is validated through Zod** in `src/env.ts` — never read `process.env` directly elsewhere.
  Booleans use the `envBool` helper (`z.coerce.boolean()` is wrong for `"0"`; the comment explains).
  Every key with a default must also appear in `.env.example` (they drifted once — keep them synced).
- **One shared Postgres pool** (`src/db/index.ts`, `postgres(..., { max: 10 })`). Import `db`/`sql`
  from there; don't open new connections. Long-running work (the LLM grouper) runs **outside**
  transactions on purpose so it doesn't pin a pooled connection — see `grouping/service.ts`.
- **Auth**: routes that need a user call `app.addHook('preHandler', app.authenticate)` (see
  `routes/me.ts`). `authenticate` (`auth/clerk.ts`) attaches `req.user`; access it as `req.user!`.
  Locally, `DEV_AUTH_BYPASS=1` accepts `Authorization: Bearer dev:<clerkId>` with no real Clerk JWT.
- **Routes** are Fastify plugins (`FastifyPluginAsync`) registered in `server.ts`. Validate bodies
  with Zod inline (`z.object({...}).parse(req.body)`), as the existing routes do.
- **Schema → migration flow**: edit `src/db/schema.ts`, then `npm run db:generate` (writes a new
  file under `server/drizzle/` + updates `meta/_journal.json`). **Never edit generated SQL or the
  journal by hand.** Apply with `npm run db:migrate`.

## Grouping / LLM cost (the part most likely to confuse)

`grouping/service.ts` builds canonical franchises by expanding AniList relation components, then
grouping. The LLM is only worth spending on when a `SIDE_STORY` might actually be a separate work.

- `groupingTier()` (`grouping/llm.ts`) is the **cost lever**: single-member or no-side-story
  components return `deterministic` (zero LLM tokens); one side-story → `standard` (cheap model);
  ≥2 distinct side-story targets → `escalate` (stronger model).
- `pickGrouper()` (`grouping/service.ts`): the **escalate tier intentionally ignores the
  `modelOverride`** (the bulk-cron model) and always uses `OPENROUTER_MODEL_ESCALATE` — so the
  nightly bulk cron can't downgrade the genuinely ambiguous cases. This is by design (see the
  comment there); don't "simplify" the `||` chain away.
- Provider selection (`makeGrouper`): **Cerebras wins when `CEREBRAS_API_KEY` is set** (cheap/fast,
  the `model` arg then doesn't apply); else OpenRouter; else deterministic. The shared
  OpenAI-compatible Cerebras request lives in `util/cerebras.ts` (`cerebrasChat`) — reused by both
  franchise grouping and zero-result search correction (`services/queryCorrect.ts`).
- `GROUPING_LLM_DISABLED=1` forces deterministic grouping (no key / offline dev).
- **A part's `relationship` is derived in ONE place, `grouping/relationship.ts`** (4 Oct), for all
  three writers (the deterministic grouper, `decoratePartOrder` after the LLM, and `planAttach` in
  `grouping/attach.ts`). An AniList edge `from → to` of type T means "`to` is the T of `from`"; the
  writers used to invert only PREQUEL/SEQUEL, so a side story whose one tie was "my PARENT is the
  series" was stored as PARENT (Re:ZERO's Break Time shorts, taken for the story's spine) and a
  season that HAS a side story as SIDE_STORY + optional (One-Punch Man S2, Noragami Aragoto, JoJo
  Part 4). Now: child first (SIDE_STORY, SPIN_OFF), then SEQUEL, then PREQUEL, never PARENT;
  `optional` = a child, a special or a music video; an attached real season is "Season <next
  number>", an attached side series of season kind wears its title, extras are "OVA N" / "ONA N".
  **Stored rows are NOT rewritten by this**: `npm run relations:backfill` is a dry run that prints
  the plan (4 Oct: 188 of 600 anime franchises, 628 members — incl. 17 series that become SPIN_OFF,
  e.g. the Gundam alternate universes and MHA Vigilantes, which the app then files under extras);
  `-- --apply` writes it and is the owner's call. Until it has run, readers must not trust
  `optional` or a season's SIDE_STORY (the feed's `isMainStory` and the iOS rules do not).
- **The production API runs from an IMMUTABLE RELEASE, not this tree** (since 6 Oct:
  `com.shan.previously` runs `/opt/homebrew/opt/node@24/bin/node ops/run-server.mjs` from
  `~/Infra/previously/releases/<stamp>/server`, which wraps the compiled `dist/index.js`;
  cloudflared → `localhost:8787`; the local Postgres IS production). `server/ops/README.md` is the
  release sequence (`npm run build`, `npm ci --omit=dev`, `prepare-install.mjs`); a fix in this tree
  reaches production only when the owner cuts a release. Keep `server/` compiling and its tests
  green (`.node-version` pins Node 24: use `/opt/homebrew/opt/node@24/bin`), and never run a
  writing script against the database without the owner's go-ahead.

## Scheduled sync

`startCron()` (`sync/cron.ts`) is started in `index.ts` at boot: hourly `refreshAiring` (airing
schedules / "out now"), daily 03:30 `seedTrending` + `attachNewSeasons`. It runs in-process — there
is no separate worker. A restart re-arms the schedules; it does not replay missed runs. The social
layer adds two, each on its own schedule and catch: hourly at :20 `alertStaleReports` (a report
waiting > 12 h nudges the operator's webhook) and daily 03:10 `purgeCommentTombstones` (comments
their authors deleted more than 30 days ago).

## Today feed + social (server, 25 Sep)

The Today tab is a feed composed ON THE SERVER (`GET /me/feed?tab=following|foryou`: pure rules in
`feed/compose.ts`, IO in `feed/service.ts`); the client renders the words from structured facts and
never parses `release`. Post ids are stable: `news:<announcements.id>`, `catalog:<mediaId>` (re-keyed
to `news:` with every social row, in one transaction, when research adopts the part —
`feed/adopt.ts`) and `trailer:<fid>:<site>:<videoId>`; an episode room is `ep:<mediaId>:<n>`
(`social/subjects.ts` is the one grammar).
- **"New" is `discoveredAt > prev_opened_at`, and `POST /me/opened` SHIFTS last → prev atomically**
  (it used to echo the stamp it had just written, so "since your last visit" meant "since now").
  Fresh posts come first, each block by `time.at` desc then id; the server sets `post.fresh`.
- **Episode discussions are spoiler-gated here** (`services/episodeGate.ts`): read or post in
  `ep:m:n` only when the caller's progress for m ≥ n AND episode n has aired by now
  (`services/aired.ts`, anchor-aware) — the same count that clamps `setProgress`, so a RELEASING
  season cannot be marked past what has aired, and an unknown mediaId is refused.
- **Comments sit behind `SOCIAL_COMMENTS_ENABLED`** (default OFF; only `.env.example` says 1, for
  local work). Off, every `/social/comments*` route answers `404 { error: 'comments disabled' }` and
  `/me/feed` says `capabilities.comments: false`; likes, saves, reminders, hides, ratings, blocks and
  the profile keep working. Production stays off until the Terms' UGC clause and the production
  Clerk instance ship (`docs/beta-release.md` has the order).
- **UGC compliance (App Review 1.2)**: terms acceptance (`SOCIAL_TERMS_VERSION` — bump it whenever the
  rules change), a handle + display name chosen at the first reply (never the email), a word-list +
  no-links content filter (`social/contentFilter.ts`), per-user rate limits (`util/rateLimit.ts`, 429
  + `Retry-After`), auto-hide after `SOCIAL_AUTO_HIDE_REPORTS` reports, blocks filtered in both
  directions (counts stay global), the operator CLI (`npm run moderation -- …`) and a ban list keyed
  on `clerk_id` that `authenticate` checks BEFORE the upsert: a banned account gets
  `403 { error: 'account_suspended' }` on everything but `DELETE /me` and `GET /me/export`. That is
  the only app-level 403 — every other refusal is 409/410/422 with a machine code, because the app
  reads a bare 403 as infrastructure (a WAF), never as the account.
- **Every user-owned social table is erased by `DELETE /me`** (in `accountOwnedTableNames` order;
  `me.account.test.ts` catches an FK to `users` under another name) — the ban row is the one
  disclosed exception — and the Clerk identity is deleted after the commit (`services/erasure.ts`;
  needs `CLERK_SECRET_KEY`, else `clerk: skipped`).
- Toggles are idempotent set-state `PUT`/`DELETE`; a comment `POST` carries the client's uuid (a
  retry cannot double-post, and an own delete is a tombstone so a replay cannot resurrect it).
  Comment length is Unicode code points on both sides (≤ 280). Keyset pagination for threads and
  notifications. No push: Activity (`GET /me/notifications`, now with `reply` / `like_comment`) is
  polled by the app.
- **For you is ranked per viewer (4 Oct: "for you is not really recommendation based on user's watch
  history. It's just too random", owner).** It was news about the 150 trending franchises in time
  order, minus owned and muted shows. Now (`feed/forYou.ts`, pure and unit-tested; IO in
  `feed/service.ts`): the candidates are the shared trending snapshot (still one composition per 10
  minutes per process) PLUS posts about the shows the library recommender picks for this viewer
  (`loadRankInput` + `rankRecommendations`, rotation off — never `getRecommendations`, which queues
  show pages), scored `0.5 × affinity + 0.5 × recency` (a pick 0.7–1.0 by its place; any other show
  0.6 × its genres' match with the library's taste profile; news halves every 45 days), with a taste
  floor, an eight-month staleness cut and a PICTURE rule — a post needs a video or art measured
  ≥ 1000 px (AniList-only covers blew up into title cards) — all refilled only to reach the list.
  **For you is 20 posts** ("let's limit total for you to 20", owner), one per show where it can.
  A pick with no post of its own gets a DISCOVERY TRAILER: its best dated official trailer whatever
  its age (a trailer is new to someone who has not seen the show), `evergreen` — exempt from
  staleness, recency held at 0.6 so fresh news still outranks it. Each post says why in `context`
  (`recommended` with the recommender's reason, `taste` with one or two genres from a 0.6 match,
  else null; null on Following, the post page, Saved and Reminders). The viewer's part is cached
  per user for the snapshot's 10 minutes; a failure there serves the trending feed. An empty
  library gets the old time order.
- **"Episode N is out" posts (4 Oct), Following only and OPT-IN: `GET /me/feed?tab=following&
  episodes=1`.** One per main-story part for a week after its newest episode aired (statuses
  watching / completed / paused), kind `episode`, `episode: n`, id = the episode's room
  `ep:<mediaId>:<n>`, `time.basis: 'aired'`, no title and no still (spoilers). Opt-in because a
  build that predates the kind decodes it as `.unknown` and prints the ANNOUNCED sentence — never
  send a new post kind to a client that did not ask for it. A like on an `ep:` post needs the
  episode aired, not watched (comments keep the full gate); reminders refuse `ep:`.
  `/me/feed` never enqueues research (the agent runs on a personal subscription). Discover's
  genres: `GET /discover/genres`, `/discover/genres/:key` (cursor-paginated, owned titles marked).

## iOS conventions

- **Franchise detail actions are independent of entry point (4 Oct, build 11).** Home/Schedule
  episode context chooses a season only when Episodes is opened; every show starts at its header
  with Posts selected. All generic Add buttons (Search, Trending, Feed, Detail) use Detail's same
  library chooser, including Add to Planned. Do not branch the detail action on recommendation
  cache membership or `isReleasing`; an explicit Add to Planned shortcut remains a direct save.
  Keep More actions in the toolbar at every scroll position. Its batch commands and the pinned
  post share `progressChoices`; in Episodes, the toolbar uses the selected season. Batch prompts
  name the show and season. See `docs/audits/2026-10-04/franchise-cta/README.md` for validation.

- **The deployment target is iOS 18.0, and every iOS 26 API is GATED, never removed** (3 Sep).
  iOS 17 and iOS 18 support the identical iPhone set (XR/XS and later, A12+ — Apple kept 17's
  device list for 18), while iOS 26 needs an iPhone 11, so 18 already reaches every phone 26
  excludes and going to 17 would buy nothing while costing the `onGeometryChange` scroll probes
  (18 sites), the `Tab { }` builder and Schedule's `onScrollTargetVisibilityChange`. **Never call
  an iOS 26 symbol directly from a screen** — route it through the gated shim in
  `DesignSystem/GlassHelpers.swift`, which is the one home for "iOS 26 flourish, graceful fallback":
  `glassChrome` (→ `.ultraThinMaterial`), `chromeScrollEdgeHidden(_:)` / `chromeScrollEdgeHard(_:)`
  (no-ops below 26 — there is no system scroll-edge effect to suppress or harden),
  `chromeSharedBackgroundHidden()` (a `ToolbarContent` extension:
  below 26 a toolbar item has no shared glass capsule to drop) and `chromeNavigationSubtitle(_:)`.
  `ToolbarSpacer` is gated inline in Detail's toolbar because it is a `ToolbarContent` *value*, not
  a modifier. The shims take a local `ChromeEdge` enum rather than Apple's edge set: a signature
  that names an iOS 26 type will not compile against an 18 target even when every call is inside
  `if #available`. The Icon Composer `AppIcon.icon` needs no fallback work — actool already emits
  `AppIcon60x60@2x.png` + `CFBundleIcons` for pre-26 alongside the layered asset.
- Presentation is **derived, not stored**: `Models.swift` computes display fields (`displayRelease`,
  `releaseSortKey`, `isFutureInstallment`, sort keys like `nextAiringSortKey`/`lastAiredSortKey`)
  from the raw API status/release fields. Keep this logic in the model layer, not the views, and
  reuse the existing sort-key accessors instead of re-inlining `?? .max` / `?? 0` sentinels.
- **THE AUDIENCE: anime, TV, or both (4 Oct: "TV-first folks don't have any interest in anime. Anime
  folks could echo the same… We need a user flag … that does a clean segregation so that this
  contract is not violated across our application", owner).** `Audience` + `AppModel+Audience.swift`.
  **The contract: everything the app SUGGESTS is of the viewer's kind and nothing else** — For you,
  Suggested, Trending, Discover's shelves and genres, Search and its launchpad. **What they OWN is
  never hidden**: Library, Home, Schedule and Following are their shows whatever kind they are. A
  title is one kind or the other (`source`: `anilist` = anime, `tmdb` = TV), which is what makes the
  wall clean. Any NEW surface that shows titles the viewer does not own must pass through
  `audience.allows(_:)` (or the scope below) — that is the rule this bullet exists for.
  - It is the ACCOUNT's (`GET` / `PUT /me/preferences`, `audience`; null = never answered = both):
    the server composes For you and the recommendations for it and defaults every catalogue route
    without an explicit `source` to it. The app keeps the same wall itself — `visibleRecommendations`,
    `FeedComposer.rows(allows:)` (For you only), the Trending lists — against a response cached
    before the choice, an older server, or an answer that has not caught up. The device keeps the
    choice (`previously.audience`) so the FIRST frame is already the viewer's; a choice the server
    has not confirmed is owed (`previously.audience.pending`) and sent at launch, reconnect and
    foreground (`syncAudience`), which also adopts a change made on another device. Sign-out
    clears it (`clearAudience`).
  - **A single audience FIXES the app's one scope** (`mediaFilter`, Discover and Search's All / Anime
    / TV): it is set from the audience and every control that changes it is gone — Discover's scope
    menu, Search's scope bar, a genre page's chips (`ScopeChips`). A search that finds nothing says
    why and where the door is ("You're seeing anime only. Change it in Profile › What you watch.");
    there is no way to widen from Search.
  - **Asked once** (`AudienceChooser(mode: .firstRun)`, a sheet from `MainTabView` when the account
    has no answer, after the launch, never over a suspension; it cannot be waved away, and the
    library suggests the first answer — all anime, all TV, else both) and kept in Profile ›
    Settings › "What you watch" (`mode: .settings`: a tap IS the change, with the receipt "Showing
    anime only"). Three picture cards, each a picture MADE for its answer (4 Oct, Codex:
    `audience-anime-v1` / `-tv-v1` / `-both-v1`, sources in design/onboarding-2026-10-04 — the
    Discover genre duotones they first borrowed were "shit", owner); the chosen one is held by
    the selection ring (`SelectionRing`, standing off the card in the lit accent) with its badge
    (`SelectedBadge`), and the screen takes that picture's light (`AudienceAmbient`) (STATE).
  - **It is felt, not announced**: Discover's genre art leans the viewer's way (`GenreArt.leaningKey`
    is written by the choice), the field says "Search anime" / "Search TV", the chart is "Trending
    anime" / "Trending TV", and the kind word is DROPPED where the app suggests (`MediaSource.
    kindLead`: "2019", not "Anime · 2019", on a wall that is all anime) — their own shows keep
    `kindWord`, since a library may hold both.
- **FIRST RUN is four questions, then a Home that is already theirs (4 Oct: "a robust onboarding
  experience for new users… Apple-class bar", owner; the research is
  `design/onboarding-2026-10-04/SPIKE.md`).** It was one sheet ("What do you watch?") over an empty
  Home. Now a NEW account — no audience answer AND an empty library — gets `FirstRunFlow`
  (Features/FirstRun) IN PLACE OF the tabs (`SignedInRoot` in RootView; `AppModel+FirstRun.swift`
  has who, why and the writes): **what you watch** (Profile's `AudienceCard`s, saved at once) →
  **pick your shows** (a wall of posters: `GET /franchises/starter`, the catalogue's best-known
  shows, falling back to the chart on a 404; "Airing now"; the genres; a search field) → **where
  are you?** (one screen per picked show on its own colour: Caught up / Part-way — an episode dial,
  `EpisodeDial` — / Just starting / Save for later; the show page's own batches, `FirstRunWrite`)
  → **here's what's next** (their shows on the board: each row's WHEN on a `SplitFlap` that turns
  to its value; the alerts offer) → Home.
  - **Nothing is required and nothing explains the app**: no tutorial, no minimum of picks ("Skip
    for now" with none picked; Skip on the questions leaves the rest unasked), no profile screens.
    The spike's complaints were exactly those (Hobi's forced three, Trakt's re-marking by hand).
  - **Nothing is written until the picks are placed** (Back changes an answer, never undoes a
    write) — except the audience. Then each show is ONE call (`saveProgressBatch`: membership,
    status, progress), drawn into the library first (`insertPending`), four at a time; a failure
    goes to Sync status and its show leaves. No receipt, no Undo; one `.success` as the board
    comes alive.
  - **The system's notification alert follows a tap on "Turn on" and nothing else.** The line
    exists only when permission is unanswered and a Watching anime has a timed airing ahead, and
    it names that show. Go to Home is beside it and works whatever was tapped.
  - **The states never show an empty Home that turns into a questionnaire**: signed in and not yet
    known to be new, the brand HOLDS (`FirstRunHold` — the gate's own picture when they just
    signed in, the launch lockup at a launch; six seconds at most, then the app); when the flow
    reaches its last screen the tabs are built BENEATH it, so Go to Home lifts the flow off a
    composed page. A quit mid-way resumes at the picker (`FirstRun.pending`); an account that
    skipped, or arrives on another device, gets the same picker from the empty Home's button
    ("Pick your shows", `FirstRunFlow(entry: .shows)`, a cover with an ×). An older account with
    shows but no audience answer keeps the one sheet.
  - Art: the empty Home's board and the alerts bell are Codex's (`design/onboarding-2026-10-04`:
    `codex-brief.md`, `source/`, `package-art.py`), in the empty states' graphite split-flap family.
  - **How it is exercised:** the real server against a SCRATCH copy of the database, never
    production — `createdb previously_onboarding_scratch`, `pg_dump previously -Fc | pg_restore -d
    previously_onboarding_scratch`, then from `server/`: `APP_ENV=development PORT=8799
    DEV_AUTH_BYPASS=1 DATABASE_URL=postgres://localhost:5432/previously_onboarding_scratch
    NEWS_AGENT_DISABLED=1 … npx tsx ../design/onboarding-2026-10-04/scratch-entry.mts` (no cron;
    it refuses any other database). Build with `API_BASE_URL=http://localhost:8799` and
    `CLERK_PUBLISHABLE_KEY=` (blank) and launch with `-devSignInId <a new id> -devSignInAuto 1`: a
    new id is a new account. Flags (DEBUG): `-firstRun 1` forces the flow, `-firstRunStep
    audience|shows`, `-firstRunPick N`, `-firstRunAdvance place|lineup` (lineup WRITES; local
    backend only). The pure rules are checked by `-verifyAnnouncements 1`.
  - **History import** (`Features/Import`, `AppModel+Import`, `server/src/import`): the picker's
    "Bring it in" and Profile's "Import your history" share a preview → apply → result sheet.
    AniList by public username, MAL XML/gzip, TV Time ZIP/CSV; files are parsed on-device.
    Preview jobs are polled (`POST /me/import/preview?async=1`, then `GET /me/import/:id/preview`)
    so large lists survive the normal 15-second HTTP timeout. Apply only raises progress, keeps
    existing statuses, and fetches uncatalogued shows in the background with shared AniList pacing.
    Manual first-run picks skip already imported memberships. The app remembers the result across
    relaunches; reopening Profile's import shows it. Server jobs are in memory, so a restart needs
    a safe re-import for unfinished work. See `docs/api-contract.md` for shapes and mapping limits.
    No new schema or production write is needed. `-verifyImport 1` runs file-reader regressions;
    `design/onboarding-2026-10-04/verify-import.mts` verifies real SQL on the scratch DB only.
  - Not built: Trakt import; sign-in AFTER the picker (the catalogue is authenticated and search
    can spend an LLM call).
- **ONE LIGHT, ONE INK (4 Oct: "improve the design system and colours everywhere… utterly polished,
  satisfying and premium", owner).** Every filled or raised CONTROL is lit from above, from one set
  of materials in `ThemeGradient` (ThemeTokens): `accent` (the primary capsule — which also stands
  in a pool of its own light — a selected chip, a committed `MarkRing`, the amber badges and tags),
  `ivory` (the white pills: Mark as watched, Add, Follow), `litEdge` / `litEdgeStrong` (the crown
  of a quiet capsule, a chip, a tile). ARTWORK is exempt: a picture's edge stays `posterEdge`.
  A chosen picture wears `SelectionRing` + `SelectedBadge` (DesignSystem/Selection.swift), never a
  stroke on its own edge. And the feed's INK is the app's own now: `feedText` = `textPrimary`,
  `feedSecondary` #8C8781, `feedSeparator`, `feedCard`, `feedField` in the warm graphite ramp (the
  grid and metrics stay X's); `surfaceFloating` / `surfacePressed` left their cool blue-grey.
- **Home is the landing, the feed is a tab (26 Sep: "the today screen should become Feed… feed should
  not be the home screen for sure", owner).** Tabs: **Home · Schedule · Feed · Library · Discover**
  (`AppTab`: `home`, `schedule`, `today` = the FEED — the case kept its name so every route and flag
  meaning the feed still does; `-openTab schedule|today|feed`). **Schedule is a TAB, in the second
  slot it held before Home arrived** — build 3 folded it into Home (a calendar glyph and "This week ›"
  pushed it) and the owner reversed that the same day: "combining home with Schedule was a bad
  decision… Some people specifically want the schedule view as the muscle memory". Home keeps no
  calendar: no glyph, no "This week" section, no `HomeRoute`; Recently aired's chevron and the
  caught-up state's button SELECT the Schedule tab. Profile opens from Home's disc as well as the
  feed's. `HomeView` + `HomeParts` (Features/Home) — what you can watch now, each show in the FIRST
  place that carries it (`HomeCompose`, memoised on `scheduleFeedKey`):
  - **The billboard, full bleed** ("let's make it like the full bleed art it was earlier", then "make
    the art take more height"): the retired Today billboard's grammar, its height MEASURED FROM THE TAB
    BAR (the next section's title peeks under its foot, none of its cards — see "Home's 4 Oct
    repair") — `ArtHeader` on `billboardArt` (portrait-first, textless, drifting, FILLING the frame;
    a name set in TYPE starts its poster under the bar), `HeroTopVeil` (pinned in the bar), the
    restored `HeroCopyScrim` (Features/Home), then centred:
    `HeroBadge` ("New episode", "2 episodes behind" while airing, "3 episodes LEFT" in a finished
    season), the logo else the name, "Season 4 · Episode 22", the season bar, "Episode 24 aired
    yesterday" under a backlog, and X's white "Mark as watched" pill. **The pick is something you can
    WATCH before anything you can only wait for** ("it shows Mushoku Tensei as the Hero but it is
    upcoming, while I haven't watched Slime that aired yesterday", owner — build 3 put tonight's
    airing above the queue, and a drop counted only on a Watching show): a fresh drop on a Watching
    show (`freshCount` — `outNow`'s test WITHOUT its still-releasing gate: a finale's season stops
    releasing the moment it airs), newest first; else the newest Recently aired episode on a part you
    are FOLLOWING (`dropItem`, `isNews` — whatever shelf the show sits on: Paused and Watched shows
    list there too); else the top of the queue ("Start watching" on one not begun,
    `Copy.Today.startOrContinue`); and only when nothing is out, the next airing (today's, else the
    week's first). It stretches on a pull (`visualEffect`, no body re-run); its copy rises in once.
  - **Home's picture of a show is chosen by EYE** ("choose the best-looking poster, even if it is
    from an earlier season", owner, 26 Sep — Slime's Season 4 key visual, dark and diagonal with its
    faces at the edges, had taken the billboard). `PosterPick` (DesignSystem) grades every portrait
    the catalogue holds for a show, ONCE, on the device, from a 480-px decode: mean OKLab L over the
    band the billboard shows, Hasler–Süsstrunk colourfulness, the subject (`SubjectCrop.subject`),
    LETTERING (Vision text recognition, CJK included — minimum height 3 %, so a billing block does
    not count) and the measured width. Three passes, so a first visit is not kept waiting: TMDB's
    untagged posters (read, since the tag is an uploader's word — Slime's second "textless" Season 4
    poster prints the Japanese title), then TMDB's language-tagged ones (titled by definition: tone
    and subject only), then the seasons' AniList covers (460 px — soft on a billboard). Grades and
    picks persist (`Caches/poster-pick-v2.json`; a pick is keyed on its candidate list's FNV
    signature, so a new upload re-decides). The billboard waits `pickPatience` (2 s) on first sight,
    then SETTLES once and never swaps under the reader (a cold pick measured 1.1 s on the sim). The
    NAME follows the picture (`Choice.billboardName`): the show's logo on a clean picture ("the posters
    used to have Picture Series Logos", owner); nothing where the picture's own lettering is in view
    between the bar and the words (`.embedded` — the lockup draws no title; type at AX sizes); else
    the logo, else type. Up next tiles wear the same pick, the logo on a clean one. Why the server's
    choice was not enough: `rankArtwork` keeps a show's six BIGGEST uploads for the show as a whole,
    and never looks at one. `-homeHero <franchiseId>` (DEBUG) photographs a show on the billboard.
    The LOCAL database carries TMDB galleries for ten of the owner's shows, copied from TMDB's public
    pages (26 Sep) so the picker could be photographed; every other local show is AniList-only.
  - **The billboard GLOWS** ("utterly delightful and an eye candy without going overboard", then
    "Glow is sick, let's do that", owner, 26 Sep — `HomeHeroScene.swift`): light and depth, nothing
    added to the page. The arrival plays as the launch's CURTAIN lifts (`LaunchHandoff.emerging`) —
    at launch it used to finish under the splash — the picture settling into focus from 5 % large
    (`FocusSettle`), the logo resolving out of a blur (`LogoResolve`) with a halo of its own light
    (`LogoImage(halo:)`: the logo, or its white silhouette, blurred ONCE into a cached bitmap), the
    words rising under it; the art moves at 0.42 of the page's speed and leans ±6 pt with the phone
    (`HeroTilt`, CoreMotion, read only by `TiltShift`; 3.5 % oversize so a lean never shows an
    edge, clipped below the frame by `BelowClip`); the lockup sits in a pool of the poster's colour
    (`HeroLight.glow`, `plusLighter`); a mark sends one ring out of the pill (`MarkPulse`). Reduce
    Motion: all of it still. Tried and DELETED the same day: COVER — the logo as a masthead in the
    picture with the poster's subject cut out in front of it (Vision's foreground instance mask, the
    Lock Screen's depth effect): striking on One Punch Man, but it hid "Shadow" behind heads on The
    Eminence in Shadow and had nowhere to go on key visuals whose characters fill the top. The
    simulator cannot run that model ("Could not create inference context").
  - **A dark logo is drawn white** (`LogoImage` + `LogoInk` behind `ArtworkLogo`, so app-wide): the
    app draws logos only on dark grounds (a scrim, a tile's foot gradient, a scene's shade), and a
    logo whose opaque ink is less than a third LEGIBLE there (OKLab L ≥ 0.6, or a saturated colour
    from L 0.45) becomes a white silhouette of itself — The Eminence in Shadow's only English logo
    is black type, Mushoku Tensei's bronze; One Punch Man's red and Slime's blue keep their colour.
  - **The page sits in the show's hue** ("maybe add subtle gradient too", owner): `HomeGround` — the
    scrim lands on `DetailTint.ground(tint, groundTopLightness)` and the page eases to canvas over
    520 pt, one faint pool of the tint; both bars' grounds are WINDOWS onto that ground
    (`HomeGroundWindow`), and the top one turns solid the moment the billboard's COPY reaches it
    (`HomeChrome.trackCopy`), never with words under its glyphs.
  - **Recently aired** ("what about previous week / unmarked episodes?", owner): the last seven days'
    aired, unmarked episodes, newest first, ONE PER SHOW — its newest episode ("Only the most recent
    episode of that series NOT multiple unseen episodes", owner), naming the run still to watch
    ("Episodes 22–24") and marking through it (a batch confirms its count). Since 26 Sep it is a
    shelf of DROPS ("recently air feels really dull and uninteresting. Not delightful at all", owner,
    of the agenda rows it began as — `HomeRecent.swift`): Apple TV's Up Next, a 300-pt 16:9 card of
    the show's own SCENE (`Franchise.sceneArt`: a TMDB backdrop, textless first, never an AniList
    banner; else the picked poster filled from its top), its logo at the foot on a shade, NEW / 3
    NEW, the mark disc in the corner, a soft pool of the scene's colour under it; beneath, "Episodes
    10–12" and "Aired Monday". RINGS — the feed's story tray on Home, a tap opening the story viewer
    — was built beside it and looked sparse (and a season that has just finished has no reel, so its
    finale fell out); `-recentDirection rows|rings` (DEBUG) keeps both for comparison until the
    owner picks. Up next leads with what you are IN THE
    MIDDLE OF (a fresh drop first, then any show with progress), never-begun Watching shows last —
    the shelf's biggest-backlog order had put an unstarted show first; a card without a bar keeps
    the bar's 3 pt so the captions share a baseline, and a card entering from the shelf's edge grows
    from 0.94 (`scrollTransition`, render pass only). **Up next**: the rest of the queue (Library's Continue rule) as the LIBRARY's poster
    card (`HomeUpNextTile` = `ArtworkPoster` 150 pt, 2:3) with the bar under the poster, a NEW tag on
    a fresh drop and the mark as the corner disc (`HomeMarkDisc` — For you's add, with a check). The
    16:9 episode cards it replaced composited covers in boxes for most anime ("utter trash", owner).
  - **A mark is an event**: the control holds its marked state for `commitBeat` (0.55 s), then the
    write lands inside `uiSettle` and what changed ROLLS (`.contentTransition(.numericText())` on the
    badge, the episode, the caption), a finished row or tile leaves, and a caught-up billboard hands
    over (`.handoff`). The launch hands off on the billboard's picture (`HomeView.markArtReady`).
  - **Home's 4 Oct repair** ("the design direction for Home was good but the implementation has gone
    sideways", then, of the sim: "why is Ona being emphasized so damn much? The seam looks ugly. The
    bottom nav looks weird when there is a recently aired item", owner). What it settled:
    **The pick is asked of the RESUME part.** `HomeCompose.freshCount` used `Franchise.freshPart` —
    the first part in catalogue order with a recent drop — which for Re:ZERO was the "Break Time"
    shorts that air beside Season 4, so the finale one episode behind was not fresh and the
    billboard read "19 EPISODES LEFT · Ona 4 · Episode 1". Now: freshness is the resume part's own;
    Recently aired lists the STORY's episodes only (`isMainStory` — the shorts air half an hour
    later, so newest-first they were the one row the show kept); `dropItem` counts by the airing
    that struck, not the catalogue's count (a premiere is out while its season still reads "not yet
    released"); `FranchisePart.isNews` counts `unwatchedOut` (`behind` is 0 on a finished part, so
    every finished run was "news"); an ONA/OVA whose one tie is `PARENT` is an extra and a
    `TV_SHORT` under a `PARENT` is a spin-off (`isSpinOff` — they arrived as "Season 6/7");
    `canonicalLabel` prints "ONA 4", not "Ona 4". The server's relation inversion is the root (see
    the follow-up task); the client rules hold whatever it sends. Checks: `-verifyAnnouncements 1`.
    **No straight line may end a light.** Three seams, one cause each: the lockup's pool was a
    radial wider than its own frame, cut again by the billboard's clip — now an `EllipticalGradient`
    spent at its rim, an OVERLAY free to pass the billboard's foot (only the picture is clipped,
    `BelowClip` on the art); `HomeGround`'s pool began at full strength on the billboard's bottom
    edge — now an ellipse inside the fade; and the poster, fitted to the width of a frame far taller
    than a poster, ended four fifths down on a straight edge behind the logo — `ArtHeader(
    portraitFill:)` fills the frame from its top (its sides give; `PosterPick`'s 14–64 % visible
    band already assumed it). A drop card's glow is its shape's shadow, cast from its lower half
    (a blurred `drawingGroup` ends on its bounds; a card waiting under the bar lit the bar's edge).
    **The bars are windows, not colours.** The page's ground is a gradient with a pool in it, so no
    flat colour is flush with it: the tab bar (painted the hue's top colour since 28 Sep, snapping
    to canvas when the header went solid) sat a shade off the page. `HomeGroundWindow` draws the
    SAME `HomeGround` where the page draws it, cut to the bar, for both bars; it and
    `HomeHeaderGround` are the only readers of `HomeChrome.contentTop`. Home reports
    `TabBarGroundKey` as `.clear` — the root's bar draws no ground there — and never reads
    `chrome.solid` in its body. The top veil is PINNED in `HomeHeader` (on the billboard it scrolled
    away and the slower picture slid bare under the clock).
    **The billboard's height is measured from the bar**, constant: `barTop − x4 − a title's line −
    labelGap + 3`, so the first section's title peeks and its card starts under the bar's edge (at
    0.84 × the window fifteen points of card and half a NEW tag stood on the bar). The same height
    with nothing under it, so a hand-off never resizes the frame and the receipt lane clears the
    mark. **A single drop is not a shelf** (its card runs gutter to gutter) and names its season
    ("Season 2 · Episode 1"). **The next billboard is fetched ahead** (`warmBillboard`: the first
    Recently aired and Up next shows' pictures and colours; picks include Recently aired's shows) —
    a hand-off was an empty frame in the last show's colour for the length of a poster download;
    `heroTint` is kept beside the picture it was read from.
    **How it is photographed:** `design/artwork-2026-10-02/preview-server.py` serves a read-only
    snapshot of the owner's library (`scout/library-snapshot.local.json`, gitignored; `preview-
    mode.txt` = `populated`); build with `API_BASE_URL=http://localhost:<port>` and
    `CLERK_PUBLISHABLE_KEY=` (blank), launch with `-previously.devClerkId <any id>`.
  - The four "directions" (tray / card / both / deck) were photographed on the owner's library on a
    second simulator before this; the full-bleed billboard won. `-homeAnchor recent|upnext` (DEBUG)
    scrolls a capture to a section.
- **Today is the feed (25 Sep — the build brief's decisions are final; ios-spec's iD1–iD21 are the
  ones this build added; since 26 Sep it is the FEED tab, not the landing — see Home above).** `FeedView` (Features/Feed) is the Today root: `FeedHeader` (the leading
  account disc → the Profile sheet, which is the ONLY way into Profile — settings, sign-out and
  account deletion live there; the centred wordmark → scroll to top; the bell → `ActivitySheet`),
  the Following / For you tabs, the stories tray, then the server's posts (`GET /me/feed`) with
  Suggested, `CaughtUpMarker` and Trending inserted by RULE in the memoised composer
  (`FeedComposer`, `AppModel.feedRows` / `feedPhase` / `freshPosts` / `storyReels` — never composed
  in a body). TodayView, `RecapDigest` and the Recap, the billboard hero, the Up next shelf and the
  calm / trending openings are DELETED (git keeps them); `ForYouViews` moved to Discover, now its
  own tab ("Discover", `sparkle.magnifyingglass`: the field, Top pick, Recommended, Browse by
  genre, Trending). What holds it together:
  - **Posts are the server's**; the client renders the words from structured facts (`kind`, the
    installment, `premiere {at, precision}`, `window`, `time` + `dateOnly`, `discoveredAt`) through
    `Copy.Feed` and `TemporalCopy.feedStamp`, never parses `release`, and never fabricates a count, a
    fresh mark or a social row. The gold check only on an OFFICIAL lead source (`isOfficial`); the
    client opens https links only.
  - **"New since your last visit" is the REAL previous visit** (iD3): at launch the feed waits for
    `POST /me/opened` (the server shifts last → prev; `visitStamped`), and no later response moves
    `prevOpenedAt`. "New" = `post.fresh` from a LIVE response; the offline copy
    (`feed-cache.json`) has none (iD2) — no pill and no CaughtUpMarker from a cache.
  - **Stories stay client-derived** (`StoryReel.build`, from the library's `airings` — time-zone
    dependent). Marking in a story is the REAL progress write (`markNext`; further ahead the
    exact-count confirmation, then `markThrough(present: false)`), its receipt IN the viewer
    (`ReceiptHost.story`) and handed to the lane if the viewer closes with it live. `StoryClock`
    never ticks a body: only the segment bar's `TimelineView` reads progress, and advancing is one
    sleeping task per frame. Stories never advance under VoiceOver or Switch Control.
  - **The episode gate is one rule in two places** (iD16): progress ≥ n AND episode n aired by now,
    anchor-aware. The server decides (a room answers `access: open | unwatched | unaired`);
    `clientEpisodeAccess` mirrors it and may only unlock LATER than the server, never earlier. A
    RELEASING part's ceiling is what has aired by now (`progressCeiling(now:anchor:)`, iD17).
  - **Social writes** (`AppModel+Social`): like / save / remind / hide / mute / comment-like / block
    are optimistic, with a persisted newest-word-wins queue (`social-pending.json`, one lane per key,
    `flushSocial()` on reconnect and after every feed load), and fire `.selection` on the way ON only,
    from the model — a view never adds a haptic (iD21). A reply is CONTENT: a pending row plus
    `WriteIntent.comment`, replayed after progress (a reply in a room you just unlocked lands after
    the mark); the composer waits ≤ 1.5 s, then hands off to the pending row (iD5).
  - **`capabilities.comments == false`** — production, until the Terms' UGC clause and the Clerk
    production instance ship: no reply affordance anywhere (action bar, thread page, stories,
    discussions); likes, saves, reminders, hides and ratings stay, and so does Profile's Community
    group (Saved, Name and username, Blocked accounts, Muted shows, Community rules — iD13).
  - **Suspended** (`403 account_suspended`, iD14): `AppModel.accountSuspended` covers the app with
    `AccountSuspendedView` — Sign out and Delete account… are all it offers, because `DELETE /me` and
    `GET /me/export` are the only routes a banned account keeps. Profile → Export library → JSON is
    that export (`LibraryExport`; a server without it gets the device's library file).
  - **A reminder is real before it is promised** (§4.4): on a dated post it is a local notification
    at the premiere (anime at the air minute, TMDB at 9 AM local on the UTC date) armed through
    `EpisodeNotifications.sync` inside its 48-request budget (`reminder-<postId>`, never duplicating
    a `premiere-<mediaId>`); the tap never raises the system prompt — the primer line does. An
    undated post's reminder is the server's. No push: Activity is polled on feed load, foreground,
    the bell and pull-to-refresh (iD19).
  - Routes: a tapped alert is typed (`OpenRoute` in `userInfo["route"]`) — `pendingOpen` (a show)
    or `pendingRoute` (a post, an `ep:` thread); RootView closes every feed cover first
    (`feedDismissals`), then pushes. Feed pages are path VALUES (`FeedRoute`, `DiscoverRoute`) so a
    re-tap of Today and the alert route clear them (iD12); a sheet opens a feed page through
    `\.openFeedRoute` (Profile → Saved → a post).
  - The splash's `LaunchHandoff.artReady` was `FeedView.markArtReady()` while the feed was the
    landing; since 26 Sep it is Home's billboard picture (`HomeView.markArtReady`, `home-ready`) —
    the feed still marks it if a launch opens on it (`-openTab today`). The show page now
    writes the loading frame's remembered tint (`RememberedTint`, Palette.swift — the key stays
    `"today.heroTint"` so the stored value carries over, iD18).
  - Sign-out (`clearFeedAndSocial`) deletes `feed-cache.json`, `social-pending.json`, the persisted
    focal rects (`subject-focus-v1.json`) and the retired recap's two `UserDefaults` keys.
  - Capture flags (DEBUG, read once per screen in `Features/Feed/FeedCapture.swift`): `-feedTab
    foryou`, `-feedAnchor top|stories|suggested|caughtup|trending|<post id prefix>`, `-feedSkeleton 1`,
    `-feedPinHeader 1`, `-feedStory first|<franchiseId>` + `-feedStoryFrame N` (clock frozen),
    `-feedMedia first`, `-feedTrailer inline|full` (the first trailer post, played as a tap does,
    then full screen), `-feedThread first|<postId>` + `-feedThreadAnchor replies|sources`,
    `-feedCompose "<text>"` (never sends), `-feedActivity 1`, `-feedConstrained 1` (the Low Data
    path), `-openProfile 1`, `-openSaved 1`, `-discoverGenre <key>` (with `-openTab discover`),
    `-dumpAlerts 1`, and `-verifyFeed 1` (`FeedRegression`, prints `FEED_VERIFY_PASS`). A flag may
    select, open, anchor or freeze — never fabricate. `-todayDemo` still shapes the library in
    `DemoLibrary` (useful for stories); `-todayAnchor`, `-calmDemo`, `-recapDemo`, `-deckPage`,
    `-forYouStage` and `-toastDemo upnext` went with TodayView. `Tools/perf/flow.py` drives the feed
    (the tray, the scroll, the Suggested anchor, the story viewer at rest).
  - **The X pass (25 Sep, after the owner used the build: "the battle tested UX of X is not
    replicated properly"; X was explored on the owner's iPhone).** Following / For you are PAGES of
    a real pager (a horizontal paging `ScrollView` of two vertical feeds, `.ignoresSafeArea` on the
    pager and `safeAreaPadding` per page): each keeps its place, the tab underline and ink ride
    `FeedChromeState.pageProgress` while the finger drags (`FeedTabsRow`, the only reader), For you
    prefetches 1.2 s after Following has content, and `scrollPosition(id:)` does NOT place a pager
    on its first layout — a launch on For you is scrolled there by hand. Trailers PLAY IN THE POST
    (`InlineTrailer.swift`: `FeedAutoplay` picks the one ≥ 60 % on screen at scroll rest and stops
    it under 25 %; YouTube's IFrame API in a page of our own with the player THREE FRAMES TALL so
    its title bar, logo and "more videos" card fall outside the frame; the still stays up until
    0.4 s of play; muted, X's time chip and sound disc, "Watch again"; never with Auto-Play Video
    Previews off, Low Data, Low Power, a cover, a push or the background; a TAP watches it in place —
    see "A trailer is WATCHED WHERE IT IS"). News that carries its own trailer shows the
    trailer, not the key art. The post page's reply bar OPENS IN PLACE (`InlineReplyComposer`, the
    sheet's gate and send policy — `ReplySend`); a reply to a reply opens it on that person; the
    full composer quotes what you answer with X's thread rule (`ReplyContextBlock`). Post page:
    Add pill for an unowned show (X's Follow), "2:19 PM · 24 Sep 2026 · via …", the bar between
    two rules, "How this story got here ›" on the sort row (X's "View quotes ›"). Two identity
    traps found on the way: an `if` around `content` in a modifier (`SoundAction`,
    `OptionalAction`) rebuilt the media when a trailer started and tore its player down — keep the
    condition inside `accessibilityActions { }`; and a lazy stack DROPS a duplicate `.id` — the
    post page's rule and the thread's sort row were both "replies", so the thread never loaded.
    On the feed the bottom bar scrolls away WITH the header, as X's does (see "The bottom bar is
    the APP'S"); everywhere else it stays. **The feed's bars are
    FLUSH** — the header (`FeedHeaderGround`) and the post page's reply bar are opaque canvas, the
    one exception to "bars are material": a material under canvas at 0.74 read as a lighter band
    over the canvas with nothing under it ("the header area in both X and Instagram is flush",
    owner). The story ring is Instagram's, measured off the owner's screenshot: 92 pt, a 3.4-pt
    stroke, a 2.4-pt gap, an 80-pt photo (`FeedAvatar.ringWidth/ringGap`). **Every rule and
    border in the feed's surfaces is ONE PHYSICAL PIXEL** (`FeedMetrics.hairline` =
    `ThemeMetrics.pixel`; "The separator and borders are thicker than X. Everywhere") — 0.5 pt is a
    pixel and a half on a 3× phone, antialiased across two; the Instagram-styled story pieces keep
    their own. **An X post is ONE body in one style:** the post page sets the sentence and the
    research note as two paragraphs of the same 17-pt text (grey 15-pt under white 17-pt read as
    "two different fonts"). **A poster is a tall picture:** 4:5 around its faces in the feed, whole
    at 2:3 on the post page (`PostMedia.posterAspect`, `PostPoster`); 16:9 is for stills and true
    landscapes — the poster composited small on its blurred ground is gone from the feed. The post
    page's bar is X's (`XPageTitle`: a plain arrow, "Post" beside it) with the system back button
    hidden, so `SwipeBackKeeper` hands both pop gestures (the edge pan, and iOS 26's content swipe —
    the one that actually fired) a delegate while the page is in front. **A story is Instagram's**
    ("The Story experience is utterly trashy!", owner): a 9:16 CARD under the status band
    (`StoryCard`, 10-pt corner), the picture WHOLE on a wash of its own tint (`StoryArt`: fit, no
    zoom, no drift — the old frame zoomed a 460-px cover 1.34× and a banner 1.9× to fill the glass),
    2-pt segments and the header on the card, ONE caption (the episode, when) and ONE sticker at its
    foot — the mark as Instagram's white link tag, then the emoji slider; the next episode's
    countdown sticker with its alert — and the reply row (field, heart once watched, send) under the
    card on black. No badge, no 34-pt title, no amber capsule, no lock sentence, no "Show page" hint
    (the lift still opens the show). The tray's rings carry Instagram's LIVE tag as **NEW / 2 NEW**
    (`StoryRingTag`, `Copy.Stories.ringTag`) while the show has an aired episode you have not
    watched, because a ring alone "doesn't feel like a new episode is out" (owner); never "EP 18"
    (the copy audit bans the abbreviation). **A SEEN reel LEAVES the tray** ("No need to keep the
    story once it has been seen. The whole point of it is being an alert for a new episode. It is
    something to wait for!", owner): the tray draws `AppModel.trayReels` — `storyReels` minus every
    reel viewed to its end (`hasViewed`, persisted in `feed-cache.json`) or with nothing unwatched —
    and a reel comes back only when a newer episode airs (`latestAired` passes the viewed stamp). No
    grey rings at rest; an empty tray (no row at all) is the normal state. While the viewer is up the
    tray HOLDS its snapshot (`FeedView.trayHeld`) so the close flight lands in its own bubble; a beat
    (`trayReleaseBeat`, 0.22 s) after it lands, the seen bubbles sink away and the rest close the gap. **The roots are FLAT like Today** ("remove the header gradient
    from every other screen (except details)", owner): Schedule, Library, All titles, Discover and
    the Profile sheet carry no `ArtBackdrop`/`ProfileWash` any more, and their top chrome is
    `flushTopBar(hold)` — opaque canvas to the bar's bottom, no soft veil, no ramp, no material —
    in place of `scrollEdgeChromeBody(top: true, softTop:…)`. The show page and its own pushes
    (season list, watch history) keep their tinted washes and glass; the `rootWash*` tokens now
    serve only them. **Discover is X's and Instagram's Explore** ("Discover UX needs an overhaul to
    match this new awesome Today UX", owner — `DiscoverExplore.swift`): the system field under the
    title stays; under it X's tabs For you · Trending · Genres (`ExploreTabs`, Today's underline
    numbers, a real pager, `PagerProgress` read only by the row); **For you is NETFLIX's home**
    (`ForYouShelves`, 25 Sep — the Instagram wall that shipped first, an anonymous grid of cropped
    posters with the reason on one tile in six, was "extremely poorly built. I just don't like it at
    all"; three directions were photographed on the owner's own recommendations — a Today-style feed
    of recommendation posts, X's "Who to follow" rows, Netflix shelves — and the owner chose the
    SHELVES): the top pick as one big card (the poster, the show's logo else its name — a name is
    always drawn, `.embedded` notwithstanding — what it is, why, "Add to Planned" + "Details" side
    by side), the notification primer UNDER it (above, it pushed the card's buttons under the bar),
    a shelf per show of yours the rest come from ("Because you're watching …" / "More like …",
    `ForYouGroup`: two titles or more, else "More for you"), then "Trending now"; every tile
    IS the Library's poster card (26 Sep, "should be identical to what is in the Library", owner):
    `ShelfPosterTile` wraps `ArtworkPoster` at the Library shelf's 150 pt (210 AX) — the 2:3 poster, its
    edge and shadow, `PosterCaptionText` with ONE fact (`tileFacts`, "Anime · 2019"; the genres wrapped
    it to a second row) — its add control the card's `cornerMark` (above its open target, never
    inside it), the shelf snapping `.viewAligned` as the Library's does, and the long-press answers
    (`ForYouMenu`); Trending
    is X's list (`TrendRow`: "1 · Anime · Trending", bold title, one fact, a small poster); **Genres
    is Apple Music's Browse grid** (25 Sep, "I wanted something like this. Spotify UX isnt good",
    owner, with Apple Music's Search; it replaced the same day's Spotify tiles, which had replaced a
    collage of four posters under a scrim): `GenreTile` — 16:9, two across (one at the
    accessibility sizes), the picture FULL-BLEED, the name bottom-left in white `genreName`
    (Outfit SemiBold 17 — Bold 18 read chunky, "poorly built", owner 26 Sep) over a soft pool of shade
    at the tile's foot-left (one `EllipticalGradient`, no mask, no text shadow), no count (VoiceOver keeps it). The
    picture is the genre's OWN art, graded into ONE colour by its importer (Apple Music's duotone;
    the hue and depth per genre live in `GENRES` in `icon/genres/import.py`, the only palette) —
    `icon/genres/src/<anime|tv>/<key>.png` → `genre-<key>-<flavour>` (`GenreArt`; the brief is
    `icon/genres/README.md`, which Codex generates from). **Two flavours** (owner: "TV and Anime
    versions of assets separately… a toggle to change personalisation" later): anime art is an
    illustration, TV art a photograph, in the same colour; the Anime scope draws anime, TV draws TV,
    All draws the `genreArt` defaults key (nothing writes it yet — the toggle will; `-genreArt tv`
    for a capture), and a genre one catalogue holds has only that picture. A genre with no art
    leads with a trending poster under a wash of its colour (`GenreTile.vivid`, `leads`). The scope is the bar's menu
    (`scopeMenu`); the explore stays MOUNTED under the search surface (recents / results), which
    only fades it. **At rest Discover's bar is its OWN, and it slides away like Today's** (25 Sep,
    "Discover also needs the scroll treatment like in Today", owner): `DiscoverExplore` draws X's
    Explore header — the search PILL (`surfaceRaised` capsule, the scope's prompt) and the scope
    menu, then the tabs — over pages that run under it (the feed's anatomy: the pager ignores the
    vertical safe area, each page `safeAreaPadding`s the WINDOW's status band and starts with a
    header-tall spacer, its probe feeds `DiscoverChromeState.track`, idle settles it). The system
    navigation bar is HIDDEN at rest and comes up only to search (`.toolbar(searching ? .visible :
    .hidden)`): the pill sets `fieldPresented`, and the system field, recents, results, Cancel and
    scopes are exactly as before. The system bar's EXIT leaves the page in front 59 pt low (stale
    insets, unclamped until the next touch — filmed at 20 fps), so the pages are PARKED when the
    field comes up and put back when it goes (`restorePages`: a half-point `insetNudge` re-lays
    them out on four beats across the bar's exit, then the reader's top anchor or the page's
    `ScrollPosition`); the inset the explore uses is `ThemeMetrics.topSafeInset`, never the
    container's, which the system bar inflates. The billboard top pick, the shelves and the resting scope chips are gone from
    Discover (their views still serve other screens). Search's results are X's account rows
    (`mediaRow`: the show's face in a 48-pt `ShowAvatar`, bold name, one grey `FactLine` with the
    amber airing lead, X's Follow pill as `AddControlPlacement.pill` — "Add" on white, "Added" in
    a one-pixel outline that opens the status menu), recents the same row without the pill; the
    landscape scene card per result is gone. Wall tiles draw the show's LOGO over a textless
    poster (`ExploreTile`, `ArtworkLogo`) — and the LOCAL server has no logos at all: every logo,
    textless poster and backdrop comes from TMDB enrichment, and `TMDB_ACCESS_TOKEN` is unset in
    `server/.env`, so a build pointed at localhost shows every poster bare (production has them).
    **The feed's chrome is OUTFIT, the app's face** ("our app's font is Outfit not whatever X has.
    Don't change the damn identity of the app", owner) — names, handles, stamps, tabs, buttons,
    titles. **A post's and a reply's WORDS are SF Pro** (26 Sep, "I don't think Outfit is the right
    font for reading the tweet text", owner): `feedBody` SF 15, `feedBodyLarge` SF 17, `feedNote` SF
    15, `composeField` SF 17 — Regular, tracking 0, Dynamic Type — held at X's 15-on-20 / 17-on-24
    by `readingLines` (GlassHelpers: iOS 26's `lineHeight`; a Hindi entry in the language list made
    SF's lines 23 pt). Other prose that borrowed those tokens keeps Outfit (`feedSubhead`,
    `feedLight`). The X pass that went with it ("ours feels like a cheap knock-off", owner): the name
    `feedPostName` Outfit SemiBold 15 on the avatar's top edge; the action bar in equal slots with no
    holes (reply when on, like, remind; bookmark and share pinned right) and the server's REAL counts
    beside them, zeros hidden; media at a 16-pt radius inside its one-pixel border; `shortName`
    ("Demon Slayer") where a name is "Title: Subtitle"; a body over 280 characters cut at a word
    with X's "Show more" (the post page always whole). Every post shows its whole body (the sentence
    + the research note) — the timeline showed only the sentence until 26 Sep ("why are we
    unnecessarily clipping text", owner). **Since 9 Oct the timeline draws the SENTENCE whole and the research's NOTE clamped to two
    lines with "Show more"** (`FeedPostModel.note`, `ClampedNote`; the post page still draws the
    whole body) — "the Feed feels utterly cramped unlike X" (owner): every post was a
    280-character two-paragraph essay over a picture. The foot opened with it: `mediaTop` 12,
    `barTop` 6, `rowBottom` 10 (were 9 / 2 / 6). A glyph sized to the text reads `feedMeta.font`.
  - **For you, drawn (4 Oct: "For you visuals look poorly built", owner).** The reason sits over the
    post as X's social-context line (`FeedPostRow.contextLine`, `Copy.Feed.context` → Discover's own
    `Copy.ForYou.reason`, the shows named as the library names them, a name that fits leading: "Like
    Mushoku Tensei and 4 more of yours", "Trending in Fantasy and Action"). A post's picture is a
    CLEAN scene, else the poster, and a lettered backdrop only when there is nothing else
    (`FeedComposer.wideArt` — a language-tagged backdrop is the show's banner, an advertisement
    beside the name line). **Trending is a shelf of posters** (`TrendingModule`, the Library card),
    not X's eight rows of type. A first season announced is "A new series", a film the catalogue
    only numbers "A new film"; an uploader's shorthand ("PV", "CM 2") is never a headline; a
    trailer whose stills are gone falls back to the show's picture. An `.episode` post reads
    "Episode 19 is out." / "Season 2 has started.", carries no reminder bell, and opens the SHOW.
  - **Android has not mirrored the feed yet** (brief §15): no feed, no social layer, no Discover
    genres there. Where the bullets below say "Android mirrors this", they predate the feed.
  The bullets below that describe Today's billboard, its Up next shelf or its recap are the history
  of a retired screen; their rules still bind where the same view lives on (Detail's billboard and
  `HeroLockup`, `HeroBadge` on a story frame, `ProgressBanner` in Library).
- **The bottom bar is the APP'S, and it is X's (25 Sep: "iOS nav is too large and it competes with
  the content too… We need a deep overhaul of this… Use X's not insta's", owner).** `AppTabBar`
  (App/AppTabBar.swift), measured off X on the owner's iPhone: a 49-pt band above the home
  indicator, FLUSH with the page (canvas), one physical pixel of `feedSeparator` on top, five equal
  slots across the full width (X's own count), ICONS ONLY, every glyph in one ink (`feedText`) — the selected tab
  is told apart by its glyph alone, FILLED where the rest are outlines (Discover's magnifier goes
  heavier; nothing to fill). No amber on the bar any more: X draws no colour there, so the old
  "a selected tab is state, so it is amber" rule is retired with the pill. Glyphs are Tabler
  icons (26 Sep — see "Every icon is a Tabler icon"): outline at rest, Tabler's own filled form when
  selected — `home` (Home), `calendar` (Schedule), `device-tv` (the Feed), `library`, `search`
  (`TabHome/Schedule/Today/Library/Discover` + `Fill`), redrawn by icon/tabler/icons.py
  with 1.5 units of air so the ink lands ~21 pt in the 28-pt frame. Drawn at 28 pt: ~20-pt
  ink, centred 24.5 pt under the rule (X: 20.7 / 24.5). What it replaced: iOS 26's floating
  glass pill — ~62 pt of labelled capsule lifted over the content, amber selection.
  **How it is wired, and why:** the `TabView` stays (each tab's stack, state and lifecycle) with
  its bar HIDDEN (`systemTabBarHidden()` on every tab's stack and again in `pushedScreenChrome`);
  the bar is drawn ONCE over the `TabView` in `MainTabView` (it holds still through pushes and tab
  switches), and every page RESERVES its height at its foot (`tabBarReserve()`: on each tab root,
  inside `pushedScreenChrome`, and on Library's All titles, which pushes without it). A
  `safeAreaInset` on the `TabView` or on a tab's `NavigationStack` never reaches the pages — each
  is hosted in the system's own controller — so the bar COVERED the post page's reply bar instead
  of the page making room (measured twice before the reserve). Every scroll view therefore ends
  above the bar by its own safe area: `tabBarClearance` is 12 pt of breathing room now (was 76,
  pill + ramp), `tabBarVisualHeight` is band + home indicator for WINDOW-coordinate maths only
  (the autoplay viewport), and `centredState`'s clearance defaults to 0. There is no bottom
  scroll-edge band anywhere: `ScrollEdgeChrome` is top-only, and `bottomUnderfill`,
  `bottomChromeHeight`, `systemOwnsBottom`, `toastClearance`, the modifier behind
  `scrollEdgeChromeBody` and the iOS 26.1 `tabViewBottomAccessory` lane are gone. **The keyboard
  covers the bar, as on X** (`KeyboardPresence`, read from the keyboard's FRAME with a 120-pt
  floor, so the launch warm-up's zero-height keyboard and a hardware keyboard's shortcut bar never
  blink it): the bar leaves and every reserve folds on the keyboard's own curve, so a reply field
  sits ON the keyboard. **On the FEED and on DISCOVER it scrolls away with the header** ("it
  should vanish… Like X… Only in Feed", owner, same day — X's own frames, captured on the owner's
  phone, show the header AND the bar gone mid-scroll and both back on the way up; then "Discover
  also needs the scroll treatment like in Today"): `MainTabView` owns the feed header's
  `FeedChromeState` and Discover's `DiscoverChromeState` (each screen takes its own as `chrome:`)
  and hands the bar whichever is in front as `scrollAway` (`ScrollAwayChrome.awayFraction`), so the
  bar slides down by the fraction the header has slid up — point for point with the finger,
  settling with it. **Since 4 Oct EVERY ROOT does it** ("In the Schedule, Library the top and bottom
  header and nav are there even when scrolling… not very polished", owner): Schedule and Library
  wore the SYSTEM navigation bar, which cannot move a point at a time, so they have the app's own
  row now (`App/RootChrome.swift`: `RootChromeState`, `RootHeader` / `RootHeaderRow` in the scroll
  view's top safe-area inset, the system bar hidden, `.navigationTitle` kept for VoiceOver and back
  buttons), and Home's `HomeChrome` slides its row and its foot ground (`HomeFootGround`) the same
  way; `MainTabView.rootChrome(_:)` hands the bar the root in front's state. Only a READER's scroll
  moves the bars (`phase(_:)`: interacting or decelerating) — Schedule's landing on today and every
  other programmatic scroll leave them alone — and VoiceOver keeps them. Schedule's month grid
  hangs under the band and opening it reveals the bar. Every page PUSHED from a root keeps
  the bar; arriving on a root from another tab, or popping back to
  it, reveals the header (and so the bar); the hand-off slides (an implicit animation keyed on the
  SOURCE, never on the offset, so a scroll is never animated behind the finger); VoiceOver keeps
  the bar. The page reserves stay put while it is away — the feed draws under them to the edge.
  The receipt lane is always `LaneFallback`, floating 12 pt above the bar on
  the gutter (`ToastHost`'s lift is the bar's height while the bar is up). VoiceOver reads a real
  tab bar (`.isTabBar` on the row, `.isSelected` on the tab); a long press shows the large content
  viewer at the accessibility sizes. Re-tapping the selected tab pops it to its root (Today also
  goes to its top) — and the feed root now SAYS its navigation bar is hidden: popping by path from
  a show page (which shows its bar) left that bar's 54 pt in the feed's top inset. The QA sim on
  this Mac cannot draw a software keyboard (no Simulator.app ships in this Xcode, and idb's
  companion registers a hardware keyboard — `HardwareKeyboardLastSeen`): the keyboard path was
  checked with a synthetic `keyboardWillChangeFrame` in a throwaway build.
- **The show page is HOME'S BILLBOARD, CONTINUED (9 Oct: "the Franchise details UX is absolutely
  shit and disconnected with the rest of the amazing app experience", owner; diagnosis, captures
  and the direction in `design/show-page-2026-10-09/`).** The X profile below is history (it
  stays reachable in DEBUG as `-detailDirection profile` for side-by-side photographs, then goes).
  What the page is now, in `FranchiseDetailView`'s stage extension and `ShowProfileParts.swift`:
  - **The STAGE is one shared view, `ShowBillboard` (DesignSystem/ShowBillboard.swift)** — the
    picture, its `PosterPick`, its arrival, the scrim and the glow, extracted from Home's billboard
    on 9 Oct and verified pixel-identical on Home. `HomeBillboard` is Home's LOCKUP on it, the show
    page's `stageLockup` the page's, Schedule's `ScheduleStageCard` the card's. The lockup closure
    is handed the name the stage settled on and a `BillboardArrival` to ride. `pullStretch: false`
    for a card mid-feed; `visibleBand` for a shorter card's logo rule.
  - The page's lockup: the STATE badge (the `NextUp` eyebrow the pinned post used to compute —
    NEW EPISODE, LAST EPISODE OF THE SEASON, COMPLETE, MOVIE ANNOUNCED…), the logo else the name,
    one line (the moment, then the fact: "Aired yesterday · Season 4 · Episode 19"), the season bar
    only part-way, the support line, and the ACTION ROW — the ivory pill (the mark, Start watching,
    Start rewatch; `pinnedAction`) beside the status capsule (`followPill`); a show you do not own
    gets the Add pill alone, and TRENDING on the badge when it is on the chart. The stage's height
    is Home's measure from the bar less the index row and the first section's title, which peek.
  - **ONE page, one scroll, an INDEX that pins** (`ShowIndexRow` — X's tab anatomy, but a tap
    SCROLLS to the section; the underline follows the section in view, written by the sections'
    geometry probes into `ShowIndexState` on change only, never per frame). **The index is the
    only name: no section carries a title under it** ("Episodes" over "Episodes" — "Are you kidding
    me?", owner, 9 Oct). Sections for a tracked show: Episodes (the season pill, the bar, "Mark
    all N…", the anchored list, Movies & extras) · Trailers (a headerless shelf of 300-pt cards
    playing in place; absent when there are none) · About (identity line, synopsis, themes, facts,
    watch history, Because you finished, where to watch, cast, related) · Posts (the feed's rows,
    else one grey line). An untracked show: Trailers · About · Episodes · Posts. A push from Home
    or Schedule lands with the next episode's row in view under the billboard — no second screen,
    no scroll. **A `scrollTo` with a `UnitPoint` applies it to the TARGET's height too**: the
    section jumps anchor on a 1-pt marker at each section's top (`.background(alignment: .top)`),
    else a tall section landed a fifth of itself above the index.
  - Gone: the banner, the face, the counts line ("84 Watched 85 Episodes" broke the bar rule), the
    pinned tweet, the Media tab's full-width stack, tabs that swap content, `tabMinHeight`.
  - The page is painted from the STAGE's picture (`pageArt`: the settled pick, else the stored
    pick, else the catalogue's billboard), not the banner's. `-detailTab` jumps to a section.
- **Home's billboard is for DROPS only (9 Oct: "only the most recently aired franchise(s) should be
  shown in full bleed hero… upcoming and otherwise… loses the significance", owner).**
  `HomeFeed.heroes` are the week's drops, newest first, up to `billboardLimit` (3): a fresh drop on
  a Watching show and the newest unmarked episode out this week whatever its shelf; two or more
  PAGE (`HomeBillboardPager`: a paging `ScrollView` of `HomeBillboard`s keyed on their SHOWS, dots
  at the foot, only the front page reporting to the bar — `reportsChrome`; the page's ground
  follows the front page). Nothing out: `HomeFeed.quiet` — the top of the queue, else the next
  airing — on the QUIET card (`HomeBillboard(quiet: true)`: 0.56 of the stage's height, the moment
  as a label where the badge was, the logo at 72). `-homeHero` forces a show into whichever it is;
  it selects, never fabricates. The billboard's pull-stretch and parallax read the VERTICAL scroll
  view (`.scrollView(axis: .vertical)`), since inside the pager the nearest one scrolls sideways.
- **Schedule's card is the STAGE, full bleed (9 Oct: "the Schedule screen just feels poorly made and
  not premium enough like the Home screen", owner).** `ScheduleStageCard` (ScheduleLit.swift) is
  `ShowBillboard` at 0.52 of the window across the feed — OUT NOW on the badge, an airing still to
  come as a quiet label, the logo, the episode, the mark once out — and today's block stands in the
  picture's hue (`HomeGround` behind it, Home's own). The month eyebrow is never printed over the
  card. Rows: the face is 56 (was 40), the caption keeps its TIME whatever the name — "Episode 2 ·
  7:30 PM" with the part under it as a `sub` line ("Season 2") only where `namesPart`, and a
  premiere is "Premiere · 7:30 PM" over "Season 2" (the card still says "Season 2 premiere"); the
  caption may wrap to two lines, never truncate. **The landing's SLACK** (`landingSlack`): with a
  short week ahead the card and its few rows were shorter than the screen, so the feed could not
  bring today to the top and the previous row's foot showed under the bar — room is added after
  the last row for the landing day to reach the top, and no more. `ScheduleLitCard` is deleted.
- **The Next up WIDGET (9 Oct, PreviouslyWidgets/NextUpWidget.swift).** The app writes
  `NextUpSnapshot` (Shared/NextUpSnapshot.swift, a member of both targets) into the App Group
  `group.com.cognipin.previously` — up to four shows: Home's drops, the quiet card's show, the
  queue, then the week's airings — with a poster JPEG and a logo PNG per show, debounced 0.8 s
  after a library reload, a mark or a status move (`AppModel+Widget.swift`,
  `scheduleWidgetSnapshot`), then `WidgetCenter.reloadTimelines`. The widget (small: the poster,
  the badge, the logo else the name, the episode; medium: the lead and two more; the Lock Screen's
  rectangle in words) re-times itself at each airing so "Tonight at 7:30 PM" becomes NEW EPISODE
  when it strikes, and a tap opens the show through `previously://show/<id>` (the URL scheme is
  new; `PreviouslyApp.onOpenURL` → `pendingOpen`). The extension carries the Outfit weights
  (`UIAppFonts` in project.yml's widget `info.properties` — XcodeGen writes Widgets/Info.plist
  from them; a key added to the file by hand is lost on generate). **Signing:** both entitlements
  files carry the group; on the simulator the build must be SIGNED (`CODE_SIGNING_ALLOWED=NO` drops
  the entitlement and the container never exists); on a device, automatic signing registers the
  App Group on both App IDs the first time Xcode sees it — the owner's Xcode session may be asked.
  Verified on the QA simulator: the container, the snapshot and the widget on the Home Screen.
- **The show page is the show's X PROFILE (25 Sep — "Details screen.", owner; three directions were
  photographed on the owner's shows — Netflix's title page, the show as an X profile, the billboard
  kept but lighter with tabs — and the owner chose the profile).** `FranchiseDetailView` +
  `ShowProfileParts.swift`: a BANNER (the show's landscape, 16:9 rather than X's 3:1 so the art
  leads; `PullStretch` on a pull, `HeroTopVeil` for the clock and the floating back/`···`), the
  show's FACE (the feed's rounded-square `ShowAvatar`, 84 pt, ringed in the page's ground) over its
  foot, and X's FOLLOW pill as the status (`ShowFollowPillLabel`: "Add" — or "Add to Planned" for a
  recommendation — on white; the status in a one-pixel outline that opens the status menu; the bar
  no longer carries a status capsule). Then the name (`feedProfileName`, Outfit Bold 22), the
  identity line where X prints the handle, the synopsis as the bio (3 lines, X's "Show more"), X's
  meta row (`ShowFactsFlow`: the next airing, the seasons, where to watch as the link), X's counts
  ("96 Watched   99 Episodes" — the story's parts for BOTH numbers, or extras made "115 Watched"
  of 99), and for a recommended show X's "Followed by…" (the seed shows' faces + the reason). X's
  TABS — Posts · Episodes · Media · About (`ShowTabsRow`) — pin under the bar once they reach it (a
  copy in an overlay; `DetailVeils` grows to cover them; a switch while pinned re-pins through
  `anchor-tabs`, whose background reaches `pinTop` above the row; the tab content has a min height
  so a short tab can stay pinned). POSTS = the next episode PINNED (`ShowPinnedPost`, X's "Pinned"
  line, the mark as X's white pill, batch verbs in the post's `···`; a Planned show's "Start with
  Season 1 · Episode 1" + Start watching, a finished one's "You finished all 89 episodes" + Start
  rewatch, a caught-up one's next airing) over the show's own posts from the feed (Following for a
  library show, For you for a trending one — `showPosts`; a post opens its page through
  `DetailPush.post`). A show in neither feed shows only the pin; a per-show posts route on the
  server is the follow-up. EPISODES = the season pill, the bar, "Mark all N…", `EpisodeList`,
  Movies & extras. MEDIA = every trailer full width, each playing in place. ABOUT = themes, watch
  history, "Because you finished", where to watch, cast & crew, more like this. The bar docks the
  name when the page's name passes under it (a Bool geometry flip). DELETED with the billboard:
  `hero`, `heroLockup`, the poster staging on this page, `HeroLockup`, `HeroCopyScrim`,
  `AuthoredHeroArt`, `MarkSplitButton`, `HeroTitle`, `FadesUnderBar`, the hero's spoiler eye, the
  bar's status pill — the notes below about Detail's billboard, its lockup and its capsule are
  history. `-detailTab posts|episodes|media|about` opens a tab; `-detailAnchor` now selects the
  anchor's tab first.
- **Cohesion rules (2026-08-30 pass, header/hero/veil rules revised 2026-09-02):** one ambient-wash
  spec app-wide (`ThemeMetrics.rootWashHeight/rootWashIntensity` — never a private height/intensity
  pair); **one section-header family: `SectionHeaderRow`** — `ThemeType.sectionTitle` (Outfit
  SemiBold 20, mixed case) with the count on its baseline and a trailing chevron when the header
  navigates (the title IS the button; no "See all" word — the Apple TV / Netflix shelf grammar);
  `inlineAction: true` keeps a trailing text link for a command on the section ("Clear"). Small-caps
  `SectionLabel` is an EYEBROW only now (`OverArtLabel` over art, grouped-list headers, sheet
  labels) — never a shelf header. Schedule's day headers ("TODAY · THU 3 SEP") and its Earlier row
  ARE eyebrows (`sectionLabel`, 3 Sep — they were `sectionTitle` while the rows were `MediaRow`s):
  the airing card under a day names its show at `rowTitle` ten points down, and a day set in
  Outfit SemiBold 20 was the same shape in the same ink, so "Tomorrow" and "Mushoku Tensei" read
  as two rows of one list; a label over a title is the hierarchy every grouped list draws. One wide art card (`BannerCard`, radius `ThemeRadius.card`) instead of
  per-screen landscape cards — and the two lead surfaces are landscape too (3 Sep): Library's
  **Continue watching is an Up Next shelf** (`LibraryContinueShelf`/`LibraryContinueCard`: four
  fifths of the content width, `ProgressBanner` — the ONE 16:9 art-with-progress card, the bar
  inset on the art over a short scrim; the season screen's header is the same view — with the
  next episode named beneath; the centred cover-flow spotlight is gone), and **Schedule's rows
  are COMPACT, and since 7 Sep the DATE RIDES THEM** (`ScheduleDateRow`: a 38-pt date column, an
  88×50 tile, the show, "Episode 16 · 6:30 PM" — no day bands. It was `ScheduleAiringRow` from
  6 Sep, a 104×59 tile under a full-width day band: "6:30 PM · Season 4 ·
  Episode 16", the state ladder's slot — five or six per screen). They were gutter-to-gutter 16:9
  `AiringCard`s from 3 to 6 Sep, at which density only two fit on a screen and no two states could
  be compared; the clock was an `OverArtLabel` pill on the art before that, the least legible place
  for the fact a schedule exists to give. The day BANDS went on 7 Sep (the date rides the row), the
  day rail went the way of the calendar strip on 6 Sep — see the Schedule bullet. **Profile is an account
  sheet** in the App Store's order: a leading identity row (56-pt disc, name, provenance, one
  quiet line "635 episodes · 5 watching · 13 watched" — no plate of numerals), the Watching
  shelf, then Settings (Notifications · Haptics · Export), a footnote "Up to date · Checked just
  now" (the Sync plate only exists while a change failed), Account, Sign out, colophon, Delete.
  **Landscape frames never `.fill` a portrait cover**: pass
  `portraitSource:` (`BannerCard`, `LandscapeArt` in the Search tiles) so a show with no banner is
  composited whole on its own blurred ground. One brand lockup (`Wordmark`, period in text ink —
  Profile's colophon uses `Wordmark(colophon: true)`). **One billboard hero grammar** — Detail's (Today's billboard
  went with TodayView, 25 Sep): `ArtHeader(portraitSource:)` on `billboardArt` (portrait-first — see the artwork bullet) at 0.68–0.72 × screen, `HeroTopVeil` over the
  chrome band, `HeroCopyScrim` sized to the measured copy (no fractional `ArtScrim` on a billboard),
  title + one identity line ("Anime · 2018 · Action · Adventure") over the foot; Detail docks the
  title into the bar from a `.principal` toolbar item once `scrolledUnderBar`, and its state block
  carries `Copy.Progress.newEpisode(when:)` ("New episode Friday at 7:30 PM"). **Bars are MATERIAL to
  their bottom edge (3 Sep):** the soft top veil hardens when content passes under the BAR (not the
  clock) via `scrollEdgeChromeBody(topRaised:topHold:)` — `topHold` = `ThemeMetrics.inlineBarBottom`
  (+ `searchDrawerHeight` under a search drawer), then `barEdgeRamp` (28) — and "hardened" means
  `ThemeMetrics.chromeBarOpacity` (0.74) canvas over the full-strength blur, NEVER opaque canvas
  (only Reduce Transparency, which has no blur, gets the opaque bar): at 1.0 the top ~100 pt of
  every scrolled screen was a flat #09090B slab ("pure black", 3 Sep) with the material under it
  painted for nothing. Detail's floating toolbar holds through its own
  band the same way (the feed's header is its own `FeedHeaderGround`: material + canvas at
  `chromeBarOpacity`), and Detail hardens — and docks its title — the moment the hero's COPY reaches
  the toolbar's bottom edge (`copyTop − band` in the scroll probe, not a flat 130 pt: the title
  used to slide half-lit under the glass capsules for ~80 pt before the bar caught it). **Detail's hardened bar is the show's GLASS, not canvas (4 Sep):**
  `DetailVeils` passes `DetailTint.chrome(heroTint ?? tint)` — the art colour kept as a hue, OKLab
  L 0.26–0.32, chroma ≤ 0.085 — into `ScrollEdgeChrome(color:)`, which paints it at
  `ThemeMetrics.chromeBarTintedOpacity` (0.62; canvas veils keep 0.74) over the full-strength
  blur ("the header colour should match the series colour… too blackish, should be glassish",
  user). The first cut came out the ember's warm grey on every show: `PaletteCache` answered a
  second concurrent resolve of the SAME URL with nil — and `resolve` turned nil into the fallback
  for good — and Detail asks for the poster twice (`tint` and `heroTint`, the billboard being
  portrait-first); `resolveIfAvailable` keeps a `Task` per in-flight URL and the second caller
  awaits it. **A trailer is WATCHED WHERE IT IS (25 Sep: "It should not open full screen by a mere
  click, player should be inline. The full screen experience is utter trash", owner).** One
  player per trailer (`TrailerPlayback`, Features/Trailer): YouTube's IFrame API in a page of our
  own (a neutral origin — a bare embed URL gets "Video player configuration error", a youtube.com
  base "unavailable · 152-4"), THREE frames tall behind an exact 16:9 window so YouTube's title
  bar, logo and "more videos" card fall outside it, driven by our own controls
  (`TrailerInlineControls`: the play/pause disc, "0:42 / 2:31", the sound, full screen, and a
  scrubber whose drag wins over the feed's scroll and the pager). A TAP on a trailer — a post (the
  feed, a post page) or a show page's `TrailerCard` — plays it THERE with its sound and the
  controls; another tap shows or hides them; they leave after 2.6 s of play. **Full screen only
  when asked for** (`TrailerFullScreen`): the controls' switch, or the phone turned on its side
  while a trailer is being watched (YouTube's way — turning it upright closes a full screen it
  opened), and it is the SAME player: the one web view is re-parented from the post's surface into
  the full screen's (`TrailerSurface`, `presenting`), so there is no reload, no rebuffer and no gap
  in the sound, in or out. Black, the picture at 16:9; close · the show and the video's name · open
  on YouTube along the top; back 10 · play/pause · forward 10 in the middle; the scrubber, the
  time, the sound and the way out along the foot; the status bar and the home indicator leave with
  the controls; it turns with the phone; a drag down carries it home, still playing (the picture
  viewer's drag — the zoom transition's own dismiss never fired). The list's director
  (`FeedAutoplay`: the feed and the post page preview by themselves, a show page's waits for a
  tap) owns the player and is FROZEN while the full screen holds it — a cover's disappearance, a
  suspension or a frame reported meanwhile would otherwise tear the player down under the full
  screen. The buttons ride ABOVE the post's own taps (`InlineTrailerControlsLayer`, the card's
  overlay): nested inside them, the post's double-tap-to-like took every button's tap (the
  full-screen switch only hid the controls). A video the provider refuses to embed, once tapped,
  opens where it can be (`watchURL`). Retired with the stage: `VideoSheet` (blurred ambient art, a
  lockup and a glow, then the SYSTEM's full-screen player via `allowsInlineMediaPlayback = false`
  — two full-screen transitions and a reload for one tap), `VideoEmbed` and `embedURL`. **The app
  is portrait; only the trailer's full screen turns:** `project.yml` lists the landscape
  orientations and `App/OrientationGate.swift` (an `AppDelegate` reached through
  `@UIApplicationDelegateAdaptor`, one delegate method) answers `.portrait` everywhere except while
  `TrailerFullScreen` is up — it opens the gate on appear and closes it on disappear, the gate asks
  every controller in the window (the presented ones too) to re-evaluate, and `follow(_:)` turns
  the interface with a phone that opened it sideways. The local feed rarely carries a trailer post
  (they need a video published in the last 200 days): the post page opens any DATED trailer by id
  (`-feedThread trailer:<franchiseId>:youtube:<videoId>`); locally Delicious in Dungeon's
  (`91c825c7…:youtube:qRrXciq7-88`) has a date. The sim cannot turn (no rotate tool here), so the
  sideways path is the phone's to check.
  After `xcodegen generate`, pass BOTH `API_BASE_URL=` and `CLERK_PUBLISHABLE_KEY=` on the
  `xcodebuild` line for a production capture build and check the built `Info.plist`
  (`PlistBuddy -c "Print :APIBaseURL" -c "Print :ClerkPublishableKey"`) — a build came out with
  `localhost:8787` + `REPLACE_ME` on 5 Sep and the sim quietly opened a developer session. Scroll probes are
  `Color.clear.onGeometryChange` on the scroll content, because `onScrollGeometryChange` never fires
  on the iOS 27 sim (the feed, Detail, Library, Search all use the probe). **Prose is rationed
  (2026-09-02):** a hero says the state (eyebrow), the episode (fact) and at most one more thing;
  where-you-are is a `ProgressBar` (`MediaRow(progress:)`, the season header), never "11 of 24
  watched" in words; a finished thing is a tick, not "Watched". **Episodes are ON the show page** (Apple TV / Netflix), in the streaming apps'
  grammar (4 Sep, "the seasons section is utterly confusing" — the user picked "Episodes + season
  pill" over season chips and a repaired title-as-picker): the section title is "Episodes"
  (`episodesHeader`), the season is a trailing `SeasonPill` capsule menu ("Season 4 ⌄", the bar's
  status-menu family on the canvas) that lists `Franchise.seasonPartsInOrder` — `.season` parts
  that are not spin-offs (`FranchisePart.isSpinOff`, from the server's `relationship`) — NEVER the
  whole episodic catalogue (Slime's picker listed nine entries with OVAs and specials interleaved);
  a `ProgressBar` under the header is where-you-are (the old "18 of 24" numerals beside a window
  that began at Episode 18 read as "showing 18 of 24"). **The list OPENS WHERE YOU ARE (6 Sep, two rounds):** `EpisodeList`
  (DetailSupport — the ONE episode row anatomy, shared with `SeasonEpisodesView`, which now exists
  only for the run an extra opens) draws a season of `wholeBelow` (12) rows or fewer WHOLE; a
  longer one opens on the NEXT episode with `windowBefore` (3) watched rows above it for context
  and `windowAfter` (8) ahead, and everything earlier is one in-place tap up ("Show earlier
  episodes" / "Show more episodes", `InlineLinkButtonStyle` centred, `growBy` 12 a tap — Mail's
  "Load Earlier Messages"; the section header holds its place and the revealed rows fill in under
  it). The first cut of the rebuild drew every season whole and put the row you came for 1,842 pt
  down on Slime S4 (21 of 24 watched — 2.2 screens of watched rows, 3.1 from the top of the page):
  "what about the most recent episode? … otherwise it's a bigger scroll" (user). Three directions
  were built behind `-episodeDirection` and photographed on Slime and Mushoku; the user chose
  ANCHORED, and anchored on the NEXT episode rather than the newest aired. Rejected with reasons
  in `EpisodeList`'s doc: a whole season from Episode 1 with an in-page "Jump to episode 22" link
  (NN/g's in-page link — but the season's first twenty rows are still what the screen opens on),
  and newest-first (Apple Podcasts' EPISODIC order, while Apple itself puts the first episode at
  the top for SERIAL shows — the numbers counted down as you read). Plex users file the same thing
  as a bug when a long season fails to advance to the on-deck episode (plex-media-player #914).
  A finished season anchors at Episode 1: nothing to continue, so it is a browse.
  **The newest AIRED episode you have not watched wears an amber `NEW` tag** on its eyebrow
  (`Copy.Label.newTag`, `onAccent` on `accent`, beside the episode number) — the streaming apps'
  NEW on a tile, and the answer to "how should we highlight the most recent episode": the ring and
  "Next up" stay on the episode you resume from, the tag says which one is news. Amber is STATE
  here, never an action. The 4–6 Sep six-row window with an "All 24 episodes ›" door to a second
  screen was "a complete tangent… a broken experience" (user); it and the overflow's "View
  episodes" are gone, and a Schedule card lands on its row through
  `FranchiseDetailView.landOnFocus` (ONE push; `proxy.scrollTo("ep-n")` at 0.45 s and 1.2 s —
  the list is an eager `VStack` so the row exists to scroll to) instead of the root appending the
  season screen (`DetailRoute.focusPushed` is gone). **The row opens, the ring marks (6 Sep):**
  tapping a row never writes progress — Apple TV's tile plays and its description opens the
  episode, Podcasts keeps "Mark as Played" off the row, Reminders completes on the circle alone
  ("people sometimes are curious to see what the episode details are and unintentionally might
  mark it as completed", user); a row with an overview (or a withheld title) expands in place on
  `uiSnappy` to "55 min · 14 Apr 2019" (`Copy.minutes`; the date only on a watched row, whose
  second line is empty by rule) and the overview under the title column, clear of the ring; a
  bare "Episode 12" row is inert (a tap that does nothing is honest; a tap that marks is a trap).
  **The control is the receipt:** `MarkRing(style: .settled, fill:, committing:)` — history is a
  DISC in the show's quiet colour (`DetailTint.quiet(heroTint ?? tint)` — the BILLBOARD's
  palette, the page's; Reminders fills the circle with the list's colour) with a `textPrimary`
  check, the next episode the ONE accent ring with "Next up" in accent beneath its title, the
  rest idle rings, and NO numeral in the list (the row states the episode 14 pt away — "why does
  it need to show the episode number on the CTA?"; Schedule's and Today's rings keep theirs). A
  mark fills its own ring accent with the check drawing and one pulse (`uiMilestone`, 0.84 → 1),
  holds 0.55 s (`beginCommit`), then settles into the disc on `uiSettle` while the accent ring and
  "Next up" move to the next row; there is NO `ReceiptLine` under a row ("it shows an inline
  response again showing Episode 7 … what is this trashy UX?") — the last watched disc toggles
  back with one tap (its undo), a later ring confirms a batch with its exact count and plays a
  CASCADE (`cascade(from:through:)`: a disc every ~42 ms, ≤ 14 beats, the accent beat travelling
  down the column), an earlier disc confirms a batch unmark, and batch undos ride the LANE
  (`presentUndo` without `.placed`; the lane's fact is `Copy.Toast.batchWatched`, "4 episodes
  watched" — the long form truncated beside the poster). The one single-mark receipt left is
  the series-finishing "Series finished · Moved to Watched", in the lane. The bare tertiary
  check ("the tick mark feels cheap") and `ReceiptHost.episodes` are retired. **The show page
  sits in the show's colour (6 Sep):** `showGround` behind the scroll view —
  `DetailTint.ground(heroTint ?? tint, lightness:)` from `groundTopLightness` 0.19 (about
  `surfaceFlat`'s depth) under the hero to `groundFootLightness` 0.155 at the foot (canvas is
  ≈ 0.14 in OKLab, so the bottom chrome's canvas veil lands on it without a step), chroma ≤ 0.06,
  plus one `plusLighter` pool of the tint at 0.14 — two gradients, no image, nothing per frame;
  `HeroCopyScrim(landing:)` lands on `groundTop`, so the hero has no seam ("the details screen
  should have the theme color veil over the entire screen to make the experience more
  immersive", user; a blurred wash behind the header was tried on 30 Aug and stepped 14 levels at
  the seam because the scrim landed on canvas over it). **Android mirrors this** (6 Sep):
  `WHOLE_BELOW`/`WINDOW_BEFORE`/`WINDOW_AFTER`/`GROW_BY`, `episodeAnchor`, `episodeWindow`,
  `freshEpisode`, the controller's `expanded`/`committing`/`cascadeThrough`/`shown`, `NewTag`,
  `EpisodeDetails`, the expanders, `MarkRingStyle.Settled` with `fill` + `committing`, and the
  "All N episodes ›" door deleted. **`EpisodeRow`'s container had to become a `Column`** — left a
  `Row`, the details laid out BESIDE the row and the list collapsed to a single row on the first
  tap (caught on the emulator, invisible in the source). The remaining iOS-only work is Today's
  6 Sep pass and the iOS-specific keyboard warm-up. Detail's toolbar Add is a bare `plus` glyph (17 semibold,
  `interactive`, 44 pt) — no word in the bar. EVERY episode row carries a 120×68 tile
  (`EpisodeArtwork.slot`): the still, else a TRUE 16:9 landscape (the season's, else the show's —
  `FranchisePart.stillLandscape(within:)`, which skips `ultraWide` AniList banners: a 4.75:1
  banner's middle third in a 120×68 tile was a pair of eyes eighteen times down the list on
  production, 4 Sep), else the season cover under the episode's number
  (`EpisodeStill(landscape:poster:number:)`) — never a bare text row, never a glyph. Profile = disc + name + provenance, a plate of EPISODES (Σ progress) ·
  WATCHING · WATCHED, then a Watching `ShelfCard` shelf that dismisses and opens the show
  (`ProfileView(onOpenDetail:)`), then the grouped settings. **Search has one browse anatomy:** a 3-column `ShelfCard` poster grid at
  rest AND focused (recents rows above it once focused), scopes appear `.onTextEntry`, results
  are `MediaRow`s only (no top-match card, no headers, `.row` slot everywhere); the hardened bar
  hold follows focus (`searchChromeBottom` — the title collapses when the field has focus, so the
  hold shrinks to the drawer; All titles does the same). Profile is disc + name + provenance and
  verb-only settings rows (no poster fan, no subtitles). **States are consumer, not SaaS
  (2026-09-02):** `EmptyState` is `ContentUnavailableView`'s anatomy on the canvas — a 44-pt
  tertiary symbol, a title, one sentence, ONE hugging button (a recovery like "Try again" is the
  quiet capsule; a next step like "Add a show" is the amber one) — no plate, no glyph tile, no
  bloom, no `ambient:`; `InlineNotice` is a footnote line (glyph + metadata + "Retry" link), never
  an alert box; `SyncBanner` wears the toast's glass capsule. State copy says "Couldn't load your
  library" / "You're offline" / "Something went wrong", never "server". **The library has an
  offline copy** (`AppModel.start()` loads `library-cache.json` from Application Support, stamped
  with its real `savedAt` so `StaleStrip`/`InlineNotice` tell the truth; written after every
  successful `reload()`, removed on `teardown()`), so a launch without a network opens on the
  shows, not on an error. To photograph the non-happy states, build with
  `API_BASE_URL=http://localhost:8799` and run the scratchpad `proxy.py` (mode file: pass / down /
  refuse / slow / empty / searcherr / detailfail / writefail); never capture while xcodebuild is
  running — a CPU-starved sim shows a black launch screen for 10 s and it looks like a hang (the
  same happens on the first launch after a reinstall at an accessibility text size; wait 12 s).
  (Until 25 Sep Today's hero carried ONE action — the mark capsule; the block itself opened the
  show. The story viewer's mark is home's one-tap mark now.) **The
  hero is a billboard LOCKUP (4 Sep — the 2–3 Sep "slate" with its capsule pill and 34-pt amber
  clock read "like a 3rd grade app" on the device):** state → show → moment → episode, top to
  bottom, in THREE rows (direction B of three photographed side by side, picked 4 Sep after the
  four-row eyebrow/title/moment/episode lockup read "text heavy and cognitively overloaded").
  The BADGE is `HeroBadge` — a filled amber tag, `heroBadge` (SF 11 bold +0.6) in `onAccent`, a
  4-pt corner, the streaming apps' "NEW EPISODE" (Prime Video overlays one on cover art, Disney+
  tags tiles "Season Finale") — and says the STATE only: "NEW EPISODE", "4 EPISODES BEHIND",
  "13 EPISODES LEFT", "CAUGHT UP", "TRENDING", "WHILE YOU WERE AWAY" (Detail's state block and
  the recap wear the same badge; `OverArtLabel` is only the pill for a moment or an episode on
  CARD art). The TITLE is `displayTitle` at `displayXL`, two lines with a 0.82 scale floor — a
  short name gets the full 34, a long one lands on Detail's 28. Then ONE LINE (`heroMeta`,
  secondary): the moment in the app's one temporal ladder, then the episode — "Today at 7:30 PM ·
  Season 4 · Episode 21", "Aired 29 min ago · Season 4 · Episode 12", a backlog's "Season 2 ·
  Episode 7" alone (`momentText`); no countdown, no dot, no fourth line. The bar under it is
  where-you-are; the capsule reads "Mark as watched". `HeroCopyScrim` is lighter and
  longer (lead 132: 0.56 at the copy's top, 0.72 at the title, full canvas 40 pt above the frame's
  bottom) so the copy sits ON the picture and the frame still lands on canvas. Never let the
  reason someone opened the app be the smallest text on it, and never say in words what a
  numeral beside them already says. **Under the hero is ONE shelf, not two lists (4 Sep):** the
  Up next shelf (`upNextShelf` / `upNextCard` — the rest of the queue with its rings, then the
  upcoming airings) in the Library Continue card's geometry (`ProgressBanner`, 4/5 of the content
  width, `.viewAligned`), headed `nextUp` while a card can be marked and `upcoming` when nothing
  has aired; rows only at accessibility sizes. **Today's Up next card wears ONE pill, the
  episode:** `ProgressBanner` draws an "EPISODE 21" `OverArtLabel` bottom-leading, above the bar
  when there is one (top-leading covered faces, which live in the upper part of a crop), and the caption
  beneath is the rows' two-colour grammar (`upNextCaption`): a forward-looking TIME in amber
  ("Sunday at 8:30 PM", today's "Aired 2h ago"), else a count in grey ("9 episodes behind" — Today
  is the urgency room), else the season. A second pill for the moment on the art over a caption
  saying only "Season 5" put the fact that matters in the least readable place ("the Upcoming
  card just feels wrong", user, 4 Sep). **Schedule keeps its own anatomy** — the day in the
  header, the clock leading the caption, "Season 4 · Episode 21" after it; an episode pill on the
  art was tried and reverted the same day, and the art itself went to a 104×59 tile on 6 Sep. **AniList banners decode at their
  native 1900 px** (`WideArt.ultraWide`, decided by the URL `/anime/banner/`, never by `source`
  — an enriched anime franchise may carry a TMDB backdrop, and that IS 16:9; read by
  `LandscapeArt`): a 16:9 frame shows the middle ~37 % of a 4.75:1 banner, so a decode budgeted
  for the frame's edge was drawn at 2.5× and every anime card was soft. The crop itself is fine
  (user, 4 Sep — compositing the cover on the blurred banner was tried and reverted). The anime
  BILLBOARD stays soft because AniList's `/cover/large/` is 460×639 px (measured 4 Sep) drawn at
  1179 px wide; TMDB posters are 2000×3000 — the fix is server-side art enrichment from the TMDB
  twin, not the client.
  **The scroll offset is never screen state.** Detail and Profile hold a `ScrollOffset`
  (`@Observable`, Primitives.swift) in `@State` and only their small views (`DetailVeils`,
  `ProfileWashTravel`) read `.y` in a body; the feed's `FeedChromeState` is the same rule (the
  probe writes it, only `FeedHeader` and `FeedPillSlot` read it) — so a scroll frame invalidates those
  views, never the screen. `set` clamps through `ThemeMetrics.scrollSample` and de-duplicates.
  Bool probes (`raisedTop`, `scrolledUnderBar`) are guarded with `if new != old`. Today has NO
  mask on its scroll view any more (an offscreen pass per frame); the opaque bar covers what
  passes under the wordmark band. Veils are mounted only while on, never held at opacity 0. The
  raw offset as `@State` re-ran Today's entire body at 60–120 Hz on the first swipe ("Today lags",
  2 Sep, twice). Amber selection is legal
  STATE except where amber already means something else in the same control (Schedule's ticker —
  see `ThemeColor.interactive` docs).
- **Every icon is a TABLER icon (26 Sep: "Replace ALL ICONS (SF/HugeIcons/etc) -> Tablar", owner).**
  Nothing calls `Image(systemName:)`: every icon is `AppGlyph(systemName:)` / `AppGlyphLabel`
  (ios/Shared — also compiled into the Live Activity), whose SF-style name is only a KEY into
  `AppGlyphCatalog` for a `Glyph-…` asset in ios/Shared/AppSymbols.xcassets. icon/tabler/icons.py maps
  every key to a Tabler icon (`GLYPHS`) and redraws those assets as template VECTOR PDFs, so a new icon
  is: add the key to the catalog, map it in `GLYPHS`, rerun (it refuses a key without a mapping). The
  vendored SVGs are icon/tabler/svg; the full set is the npm package @tabler/icons (3.48.0), not in the
  repo. The hand-drawn set (icon/glyphs, 25 Sep) is retired — its generate.py refuses to run without
  `--force`. Tabler is MIT (icon/tabler/LICENSE): the app still owes it an acknowledgement (the owner's call
  where). The share icon is `share-2` (iOS's box-and-arrow); Library's tab is `library` (`playlist` read as music).
- **A numbered glyph's numeral is CUT OUT of its disc** (`AppGlyph`'s `N.circle.fill`: the numeral
  `.destinationOut` in a `.compositingGroup()`): the Tabler disc is a template in the caller's ink,
  and a numeral in that same ink was a blank grey disc (the Community rules' bullets, 26 Sep). The
  verified mark is the same idea — `ConfirmedMark` is the rosette in `accent` alone, its check a
  hole; a template asset takes ONE style, so `.symbolRenderingMode(.palette)` on an `AppGlyph`
  paints the whole glyph in the first colour (it hid the check on black).
- **A navigation bar's title is `.brandNavigationTitle(_:)`, never a bare `.navigationTitle`** (26 Sep:
  "Why does Library and Schedule still have SF font in the title?", owner). SwiftUI draws its own bars'
  titles in SF whatever UIKit's appearance proxies say — `titleTextAttributes` and the default
  `UINavigationBarAppearance`s were both tried and photographed, and neither reached a bar with
  `.toolbarBackground(.hidden)` — so the modifier draws the title as the PRINCIPAL item in Outfit
  (`bodyEmphasis`, iOS 26's glass capsule dropped) and keeps `.navigationTitle` for VoiceOver and back
  buttons. Detail and the post page fill the principal slot themselves. The tab items still get
  Outfit through `PreviouslyApp.applyBrandFont` (UIKit's proxy works there).
- Shared design system lives in `Sources/DesignSystem/` — reuse it, never re-invent:
  `ThemeTokens.swift` (`ThemeColor` / `ThemeSpace` / `ThemeRadius` / `ThemeType` + `.type(_:)` /
  `ThemeMotion` + `pick(_:reduceMotion:)` / `FeedbackCoordinator` — **every haptic goes through it,
  at most one per transaction**), `Copy.swift` (the only place a user-facing string lives — statuses,
  "Episode N" never "E19", confirmations, toasts), `Primitives.swift` + `Primitives+States.swift`
  (`PosterSlot`, button styles, `GroupedList`/`GroupedRow`, `EmptyState`, `InlineNotice`,
  `StaleStrip`, `SyncBanner`, skeletons behind `SkeletonGate`), `Palette.swift` (art-adaptive
  ground), `Util/TemporalCopy.swift` (one temporal expression per item; TMDB date-only never shows
  a clock). No literal colours/sizes in screens. `Thumb`/`RemoteImageView` for cover art (pass a
  `maxPixel` sized to the display); `ImageLoader`/`CachedAsyncImage` is the single image pipeline.
- **Amber is not an action colour.** `ThemeColor.accent` is rationed to MEANING (a real next step —
  "Returns Oct 2", a future air time) and STATE (today, owned, selected, an active filter, a
  committed mark), plus brand and GROUNDS (`PrimaryButtonStyle2`'s capsule, `MarkRing`'s fill,
  `accentSoft` discs — there the ink on top is `onAccent`, so no amber *word* is drawn). Every bare
  tappable word or glyph — "See all", "Read more", "Clear", "Sync now", "Details", "Add", "Done" —
  uses **`ThemeColor.interactive`**, and carries its affordance by position, semibold weight, a
  44-pt target and a chevron where the row has one. One hue cannot mean "this is what's coming" and
  "press this": Detail drew an amber "+ Add" directly above an amber "Episode 14 next", and Library
  put an amber "See all" over amber "Returns Oct 2" captions. This diverges from iOS deliberately —
  Apple tints "See All"; here amber is spent on the fact. Settled 2 Sep (polish pass): the root is
  `.tint(ThemeColor.interactive)` and every tab's `NavigationStack` re-tints `.interactive` (the
  bar itself is the app's and draws no amber since 25 Sep) — so back chevrons, alert buttons,
  the search field's Cancel and caret are ink, and only toggles/pickers that mean state carry an
  explicit `.tint(ThemeColor.accent)`.
- **A mark moves the status, on BOTH sides (9 Oct).** A forward mark on a Planned show moves it to
  Watching; a write that leaves the story watched through moves a Planned or Watching show to
  Watched. The server derives it on every progress write (`statusAfterWrites`, `services/library.ts`
  — conservative: non-spin-off seasons plus non-optional OVA/ONA/films that are not side stories,
  nothing releasing or announced; where it and the app's finer `isWatchedThrough` disagree it stays
  silent) and the app mirrors it (`resume` → Watching or Watched with the move on the receipt;
  `settleCompletion` and the launch sweep take Planned as well as Watching). Watched, Paused and
  Dropped are never moved by the server. Before this, a Planned show finished in ONE write (Seven
  Dials, "Mark all 3") stayed Planned for good. `npm run status:backfill` prints the rows the rule
  would have moved; `-- --apply` writes them (owner's call).
- **Write rules** (`AppModel`, `AppModel+Writes.swift`): a progress mark never rolls back — a failure
  goes to `SyncCenter.record` and the SyncBanner; membership/status writes roll back. Remove is
  immediate with Undo (`removeWithUndo`), batch marks and season resets confirm with the exact
  count; single marks present their Undo toast when the card's handoff settles (`presentUndo`).
  **Every progress write goes through `AppModel.sendProgress`** (2 Sep polish pass): one PUT in
  flight per part, the newest target waits behind it and superseded targets are dropped, so the
  server always ends on the user's last word (two bare `Task`s could settle it on the older mark).
  `setProgress`/`markCaughtUp`/`performUndo` share that policy — no red "couldn't save" toast, no
  rollback. A failed change carries a `WriteIntent` (progress/status/subscribe/unsubscribe), so a
  row restored from a previous launch retries the write itself (`SyncCenter.replay`, installed in
  `start()`); `teardown()` calls `SyncCenter.teardown()` so the next account inherits nothing.
  `setStatus` presents "Moved to Watching · Undo" (`present: false` inside a transaction such as a
  rewatch); a status write on a pending add records its failure like any other. A neutral receipt
  with no action is `showNotice` (`ToastView(message:)`), e.g. "Episode alerts on".
- Navigation: Detail is a PLAIN PUSH on the active tab's `NavigationPath` (`DetailRoute`,
  `RootView`) — the `.zoom` transition was tried (2 Sep) and retired (3 Sep): it scales the whole
  page into the tapped poster, so the show page opened as a miniature of itself inflating; the
  `zoomSource` registrations stay but nothing consumes them (see `detailDestinations`);
  re-selecting the active tab pops to root — Library also drops its All-titles item destination
  (`LibraryView.popSignal`). A tapped episode alert opens its show: `EpisodeNotifications.onOpen`
  → `AppModel.pendingOpen` → `MainTabView` selects Home and pushes `DetailRoute` (verified with
  `xcrun simctl push` + a banner tap); a reply or reminder alert carries a typed route
  (`pendingRoute` → `FeedRoute`, see "Today is the feed"). Alerts: three per watching anime show from `part.airings`,
  round-robin so every show keeps its soonest before any gets its second, armed the moment the
  primer's Allow lands (`alertsWereAllowed`). A Schedule-routed `focus` pushes the season list
  once (`focusConsumed`) — it used to re-push on every pop and trap the user. **The tab bar is
  the app's own since 25 Sep** (see "The bottom bar is the APP'S"): static everywhere but the feed,
  where it scrolls away with the header like X's (the 8 Sep "I don't want the floating nav to
  collapse while scrolling" was about the system pill's minimise); the pill's minimise behaviour,
  its 180-pt underfill and the bottom band that landed below the screen on iOS 26 went with it. Docked bar titles (Detail,
  Season, History) use `displayTitle`. Watch sessions live in `RewatchStore` (JSON on the device) and, since 2 Oct, on the server
  (`/me/watch-sessions`): every change queues one word per session (newest wins, versioned) in
  `sessions-sync.json`, and `AppModel+Rewatch` sends the queue on each change, reload and
  reconnect, then folds `GET` in (`merge`: the server wins for sessions with no unsent word; one it
  once acknowledged and no longer lists was deleted elsewhere; one it never saw is uploaded). A
  delete is a server tombstone, so a replay cannot resurrect it (`410`). Android still keeps them
  device-local.
- **Auth hand-off:** `AuthManager.bootstrap()` waits (≤3 s) for `Clerk.shared.isLoaded`, then
  follows `Clerk.shared.auth.events` for session changes; the splash leaves only when both its
  timeline and `auth.bootstrapped` are done (`RootView.handOffIfReady`) — never sign-in for a
  signed-in user. `signOut()` returns whether the session actually ended; Profile alerts if not.
- **A cancelled request is not a failure** (`Error.isCancellation`, APIClient.swift): `reload()`
  and Detail's `load()` ignore it, and `loadError` flips inside `withAnimation(uiGentle)` so every
  "couldn't refresh" footnote fades in instead of shoving the content under it.
- `API_BASE_URL` is a build setting in `project.yml` → `Info.plist` → `AppConfig.apiBaseURL`.
- **Schedule is LIT (26 Sep: "Schedule UI/UX needs to feel more beautiful and delightful", owner —
  two directions filmed on the owner's calendar; they chose POLISH, "but the horizontal timeline is
  distracting and irritating").** `ScheduleLit.swift`: the Tonight card is Home's billboard at card
  scale (`ScheduleLitCard`, square — the show's `PosterPick` poster as a PICTURE, `HeroCopyScrim`
  only under the words scaled by `HeroProtection` and landing on the art's hue at depth, the logo on
  clean art, an OUT NOW tag, a glow of the art's colour drawn by the card's shape); each row's face
  sits in a breath of its show's colour (`ScheduleRowDecor.hueURL`, a canvas-filled shape whose
  shadow is the colour); today's next airing reads "Episode 14 · in 2h 14m" with the countdown in
  accent (`countdownRow`; `-scheduleDemoCountdown 1` puts it on the next airing of any day for a
  capture); the card's words and the rows rise in once per VISIT (`active` from `RootView`, the
  launch's curtain respected) in under 0.3 s; and the feed LANDS on today from its first frame and
  holds there until the reader touches it (`landingProbe` + `reland`, ≤ 8 re-lands) — it used to draw
  the past days first and jump ~130 ms later. REJECTED and deleted: the NOW line (Apple Calendar's
  amber hairline with a time capsule — "distracting and irritating"), BOARD (each date's numeral on
  split-flap tiles turning from blank, a countdown on flaps) and the clock tinted in the show's hue
  (every time came out salmon on this library's warm posters). The old `ScheduleTonightCard` is gone.
- **Schedule is TONIGHT over an agenda (25 Sep rebuild — "We need to Overhaul the Schedule Screen
  completely for this new awesome UX", owner; three directions were spiked on the real calendar —
  X timeline posts, X's compact agenda, a card over the agenda — the owner chose the card, then
  "tonight still feels cluttered").** Day 0 opens with ONE card (`ScheduleTonightCard`,
  `pickHero`): the newest unwatched drop of today's, then yesterday's ("OUT NOW" + X's white "Mark
  as watched" pill; a card you marked holds its place until you leave the screen — `heldHero`),
  else today's next airing, else the next day's first. Its eyebrow is the app's one ladder
  (`TemporalCopy.airs`: "Airs in 9 min", "Sunday at 4:30 PM"), an evening airing today said as
  "Tonight at 7:30 PM" (`Copy.Schedule.tonightAt`, `Formatting.isEvening`); its row leaves the
  agenda (a day whose only airing is on the card is a 1-pt anchor, and a grid tap on it lands on
  the card). The agenda is `ScheduleAgendaRow` (ScheduleRows.swift): the 38-pt date column on a
  day's FIRST row only (amber only on today), a 40-pt `FeedAvatar`, the name in `feedName`,
  "Episode 14 · 4:30 PM" in grey `feedMeta` (the season only where `namesPart`), the ladder's slot
  — no day banners and no rules; a day's break is 12 pt of space (the spike's 20-pt day headings
  were the 7 Sep 40 %-banner fault again, and its amber lines and an empty "Today" heading under a
  card that already said tonight were the rest of the clutter). A month is named
  (`ScheduleEyebrow`) only where the feed crosses into one; Later rows put the MONTH in the date
  column ("OCT" over "19"); an empty today, or a day picked on the grid, is `ScheduleEmptyDayRow`
  beside its date. The landing no longer steps back to yesterday — an unwatched yesterday drop is
  ON the card. **A watched row's disc UNDOES** (in the library): one tap marks it unwatched, the
  exact count confirmed first when later episodes would go with it (`toggleWatched`) — the first
  cut drew it inert ("a schedule is a record") and a mistaken mark had no way back ("Unable to
  mark as unwatched… in the Schedule", owner, 25 Sep). **Every word on the screen is Outfit** (`feedEyebrow`, `feedDate` — the month
  grid's weekday letters and numerals too): SF caps and digits beside Outfit names read as a second
  font, the feed's own lesson. At the accessibility sizes the row unfolds (face beside the date,
  words full width beneath) and the card's name gets a third line. `ScheduleDateRow`, the week
  rail, the artwork cards (`ScheduleAiringCard`, `ScheduleDayHeading`, `ScheduleWatchToggle`,
  `WatchedArtworkButton`) and the spike's directions are deleted. Android has not mirrored this.
  The bullet below is the history that still binds (the window, the grid, the ladder, the
  landing); where it describes the tile row, it is superseded.
- **Schedule is an agenda** (reworked 2026-08-24, unfolded 2026-09-04, rebuilt 2026-09-06): a plain
  sectioned `LazyVStack`, one section per day that carries something, empty days omitted, the aired
  days simply ABOVE today (the "Earlier" fold and its "3 to watch" row are gone; the feed lands on
  today via `land(proxy)`, twice, because the first pass can run before the lazy sections above
  today have laid out). **Today is the exception — its section is always drawn, empty or not** (it
  prints "Nothing scheduled" as a ROW under its header, at every size), and "today" in this screen always means day 0, never "the first day that
  carries something": with the empty section skipped the feed opened on a future day, the "Today"
  button hid itself (`selectedDay == landing` — by its own test you were already there), and a
  row's bare clock read as tonight.
  **AT REST THE SCREEN HAS NO DATE CHROME (6 Sep, second rebuild — "the calendar part is utterly
  confusing and poorly executed", user).** The feed's day headers ARE the calendar; the bar's
  "Today" button is the way back once you have scrolled away. Four headers × three densities were
  built behind launch arguments and photographed on the real account, and the user chose the MONTH
  GRID on COMPACT rows. What the photographs settled, and must not be re-litigated:
  the DAY RAIL that shipped that morning (capsules for the days that carry something, plus today)
  was **pointing at days the reader was not looking at** — in the capture the feed sat on Wednesday
  2 Sep and Friday 4 Sep and neither day was on the rail, both having scrolled off its left edge
  while the selected capsule said "TODAY" (NN/g's eye-tracking puts ~1 % of attention past the edge
  of a horizontal strip); it named every day twice ("WED 9" in the rail, "WEDNESDAY · 9 SEP" in the
  feed a hundred points below — the same defect that killed the eight-day strip before it); it wore
  the app's own filter-chip shape in the band where filter chips appear; and its jump saved ONE
  flick on a six-airing feed. **A list of only the non-empty days cannot show a month's SHAPE by
  construction** — which weeks are busy, which are spent, which are empty — and that is the one
  thing a calendar is for. Both rejected directions and the rail are deleted, not flagged off.
  **The calendar is `ScheduleMonthGrid`, behind the bar's `calendar` glyph**, and it OVERLAYS the
  feed (Google Calendar's month dropdown) rather than pushing it: 500 pt of grid inserted above a
  lazy stack threw the reader's place three screens down and back on every toggle. ONE glyph in
  both states, tinted accent while the grid is down (a control that changes its symbol on press
  reads as a different control). A tap anywhere off the grid closes it; a tap ON a day closes it
  and scrolls the feed there — leaving it down over the day it just took you to hides the answer
  behind the question. Sunday-first, stated by the app.
  **Its anatomy is Apple Calendar's, because that is the one every reader already knows** (rebuilt
  6 Sep — "Calendar view is utter trash", user, of the first cut): the month NAMED in
  `bodyEmphasis` primary ink ("September 2026", not an 11-pt grey "SEP 2026" eyebrow — the month is
  the one fact a calendar panel exists to state); every numeral at `ThemeType.time`, ONE weight and
  size, with TONE carrying the hierarchy (accent for today, primary for a day that carries
  something, secondary for an empty one, 0.4 outside the window) because a grid of mixed weights
  reads as a grid of mistakes; the SELECTED day a filled `surfaceFloating` circle behind its
  numeral; the day's content a 6-pt dot beneath it, amber while something on it is still to come or
  to watch and quiet once it is spent. **A hairline rule above every week row but the first**
  (`ThemeColor.hairline`, white at 0.055) — the user's ask, and the fault it fixes is real: five
  rows of loose numerals in one field have nothing telling the eye where a week ends, so a date and
  the date below it read as neighbours. The panel is GLASS (`glassChrome` over a `canvas` veil at
  0.62), not a `surfaceRaised` slab: it is chrome that floats, like every other floating surface in
  the app, and #242428 filling a third of the screen read as a debug view.
  **`discSize` is capped at 44** — seven columns share ~353 pt, so a cell is ~50 wide, and uncapped
  the disc reached ~78 at the accessibility sizes and forced the panel 180 pt wider than the
  screen, arrows and both weekend columns off the edges. A grid's cell cannot be wider than a
  seventh of its grid, whatever the text size says. **The grid only
  answers for days the feed actually holds** (`AppModel.scheduleBack…scheduleAhead`, 22 days): days
  outside the window are drawn at 0.3 and are `.disabled`, and the month arrows stop at the window's
  own months — an out-of-window cell used to be an ordinary target that landed on "Nothing
  scheduled", which is a lie, since the truth is that nothing is KNOWN about 25 September
  (`Copy.Schedule.beyondHorizon`). Its weeks are a `ScrollView` at a STATED height —
  `min(naturalWeeksH, weeksBudget)`, the budget measured from the panel's own header — because a
  scroll view is greedy and both `maxHeight` forms padded the panel out to the cap and centred
  September inside a hand's width of nothing, while an uncapped six-row month at the accessibility
  sizes ran under the tab bar.
  **THE DATE RIDES THE ROW; there are no day bands (7 Sep — "ultra dense and extremely
  confusing", user).** `ScheduleDateRow` is the feed's only anatomy: a 38-pt DATE COLUMN
  (`ScheduleDateColumn` — "WED" as `sectionLabel` over the numeral at `ThemeType.time`, both accent
  on today, blank on the second and later airings of one day, as every agenda prints a date once),
  an 88×50 tile, the show, "Episode 16 · 6:30 PM", the state ladder's slot. What the measurement
  showed on the production account (5 airings, 2 shows, 22 days): SIX full-width bands for FIVE
  rows, a band ~48 pt (24 `dayGap` + label + 10 `labelGap`) against a 59–80 pt row — **~40 % of the
  feed's height was a banner introducing one row**; and of "7:30 PM · Season 4 · Episode 22" TWO
  facts are constant for that show across the window (a weekly show cannot leave Season 4 in 22
  days, and it airs at the same minute every week), so only the episode varied — and it sat LAST on
  the line. Fifteen middot-joined fragments on one screen, ~five of them news. **The season is
  dropped here** (`episodeText`, not `watchContext`) and the EPISODE leads the caption. Three shapes
  were built behind `-scheduleShape` and photographed side by side; the user picked this one. The
  losers are deleted, not flagged off: **B** kept the bands and only fixed the caption (left the
  40 %); **C** grouped by show, which killed every repetition but took today off the screen entirely
  and ran the dates 2, 9, 16, 4, 11, 18 down the page.
  **THE WIDTH BUDGET is what every question about this row comes back to** (`RowMetrics`). On a
  393-pt screen: 16 gutter + date + tile + lane + 44 ladder + 16 gutter, 8–12 between.
  "Reincarnated as a Slime" measures **184 pt** in Outfit SemiBold 17 (measured against the bundled
  face, not guessed), so the title needs a ≥184-pt lane to hold a two-line break — which leaves
  ~95 pt for the date column AND the tile together. Hence 38 + 88, not the 104×59 the band-and-row
  shape carried, and hence three title lines for the longest names. A PORTRAIT poster was built and
  photographed against it and lost ("A is good but without image it looks too bland" → landscape,
  portrait and no-art frames): at 48×72 an AniList cover is its own logotype shrunk to mush twelve
  points from the title that already says it, and the landscape frame also fits the whole window on
  one screen where the portrait one does not. An art-free row is lighter still (~70 pt an event) and
  is what the shape spike photographed; it was rejected as bland.
  **At ACCESSIBILITY sizes the row UNFOLDS** (`stacked`): the date, the tile and the ladder keep one
  line and the words take the full width beneath them. Four columns cannot survive that type —
  measured at AX-XL the words were left a ~112-pt lane against a ~28-pt face, and the row printed
  "Re:ZER / O" broken inside the word, truncated "That Time I Got Reinc…" (a row may grow at these
  sizes; it may not lie about which show it is) and pushed the ladder off the screen. Same fault,
  same answer, as the clock column this row replaced.
  Days are `ThemeSpace.x5` (20) apart — the break belongs to the day's FIRST row, and the feed's
  first day drops it to x3. An empty today keeps its date column and says "Nothing scheduled" beside
  it (`emptyDateRow`), so the one day with no body has the same shape as every day that has one.
  The scroll targets did not move: a day's first row (or its empty row) carries `AgendaID.day(id)`,
  so `land`, the "Today" button and the month grid's day-tap are unchanged.
  The band-and-row shape this replaced — `ScheduleAiringRow`, `dayHeader`, `daySection`, `metaLine`,
  and with them the 6 Sep "nothing in the feed is right-aligned" rule about the header's inline
  count — is deleted. It had been gutter-to-gutter 16:9 `AiringCard`s from 3 to 6 Sep before that,
  at which density an airing plus its day header was ~305 pt and exactly two fit between the chrome
  and the tab bar ("the quick scanability is terrible", user). The caption is still ONE concatenated
  `Text`, never an `HStack` of two runs: as a stack one run holds `layoutPriority` and the other
  carries `lineLimit(1)`, so at the accessibility sizes the row printed a bare clock and never said
  which episode.
  **The state ladder (`AiringState`, `AiringStateControl`) — the second complaint, and it is
  independent of every direction above:** "there is no instant visual distinction between an
  episode that has been marked as completed, not seen, and upcoming. Everything feels of the same
  weight" (user). The card put the three signals in three corners — the clock's colour at the
  leading edge, the ring's presence at the trailing edge, a 26-pt check on the art's top-right —
  and drew "watched" as `opacity(0.72)` over a photograph on black, which is not a state, it is a
  haze; and the trailing slot could not tell watched from upcoming, since both drew nothing there.
  Jellyfin's #706 is the same bug with better contrast. Now ONE column at a fixed x, which every
  row reserves whether or not it has a control: `upcoming` an empty slot with the clock in accent;
  `toWatch` the accent `MarkRing(style: .quiet, lead: true)`, the only lit thing in the column — with
  NO numeral since 26 Sep ("episode number for watch toggle is useless duplication", owner; the row
  says "Episode 14" beside it); `watched` a settled disc with the check, the title a step quieter and the
  tile under a flat `canvas` veil (a veil, never `.saturation`/`.blur` — those are per-frame passes
  on a scrolling list). The urgency stops being inverted: the accent buys the RING on an aired row,
  not the clock on one you can do nothing about.
  The chrome band survives as a 1-pt sentinel whose only job is the ground behind the navigation
  bar (this screen hides the system's). **Its ground is drawn at a STATED height, bottom-aligned to
  the band** — with the band's intrinsic height doing the work, a band with nothing in it drew a
  zero-height ground and the feed printed through the status bar and the word "Schedule". That was
  blamed on the header-less direction on 6 Sep and killed it; it was never that direction's bug, it
  was this background's. Nothing in the band changes size any more, so the load path is five
  identical frames — the collapsing-band faults of 6 Sep (a `0 ↔ nil` height animation slicing the
  cells, a fold mid-refresh, a follow firing during layout) cannot recur.
  Section headers must NOT paint a ground — an opaque plate cuts a hard step across the root wash.
  There is no timeline rail, no pinned header and no hand-rolled scroll tracking:
  `onScrollTargetVisibilityChange` records the top day and the calendar's selection catches up at
  `onScrollPhaseChange == .idle` — never live, because every automatic movement of a date control
  while the feed was moving was read as "bouncing" (five rounds of it, 6 Sep, and the axis turned
  out to be VERTICAL: a horizontal `ScrollView` whose content is a hair taller than its frame
  becomes vertically scrollable). The feed walks `FranchisePart.airings` (every dated episode in the
  window) via `AppModel.scheduleDays`; `scheduleAirings` falls back to the next/last slots against a
  server that predates the field, which shows each weekly show once.
  **Android mirrors all of it** (6 Sep, and the 7 Sep date row with it): `ui/schedule/ScheduleParts.kt`
  (`AiringState`, `AiringStateControl`, `ScheduleDateColumn`, `ScheduleDateRow`, `ScheduleMonthGrid`;
  `ScheduleAiringRow` and the `DayHeader` composable deleted, `FeedItem.DayHeader` gone and a day's
  FIRST card carrying the `day:` scroll key), the ticker and `AiringCard.kt`
  deleted, `MarkRingStyle.Settled` moved to the disc-with-`fill` form, `receiptIsLive` added beside
  `ReceiptLine` (which self-hides there, so a caller that must SWAP its own line has to ask), the
  overlay mounted inside the feed's box rather than the screen root (as a root child it drew over
  the word "Schedule"), and `JvmDateTimePatterns.best` given an `"MMMMy"` entry — it treats an
  unknown skeleton AS a pattern, so the header read "September2026". Both platforms pass the same
  skeleton now so they cannot drift.
  DEBUG launch arguments: `-scheduleFilter anime|tv`, `-scheduleHideWatched 1`, `-scheduleMonthOpen 1`
  (open with the calendar down) and `-scheduleDemoStates 1` (draw the most recent aired airing as
  unwatched — the test account has no aired-and-unwatched slot, so the ladder cannot otherwise be
  photographed with all three rungs). `-scheduleDemoCounts` and `-scheduleEarlier` are gone with the
  rail and the fold.
- **`planned` shows are not on the calendar.** `Franchise.tracksAirings` gates both Schedule
  (`buildScheduleDays`) and Today (`airingFranchises` → Out now / Airing soon / Now Bar); episode
  notifications and the Live Activity gate harder (`watching` only). A shelved mid-broadcast show
  otherwise arrived as "20 episodes behind" with a "Mark 20 episodes as watched" ring — an
  obligation invented out of a bookmark. Every other status keeps its airings.
- **Freshness is derived from `airings`, never from the catalogue's counts.** `airedEpisodes`,
  `lastAiredAt` and `nextAiringAt` are the server's hourly-cron fields; a slot in the part's own
  `airings` list that has struck IS an aired episode. Every "is it out / when is the next one"
  question reads `FranchisePart.airedByNow` / `behind` / `lastAired` / `upcomingAiring` (anchor-aware:
  a timed slot counts once `at <= now`, a date-only slot the day after) or `Franchise.lastAired(now:)`
  / `nextAiring(now:)` — `outNow`, `soon`, `nextUp`, the Now Bar, `shelfState`, Today's `kind(of:)`
  and stack order, Detail's next-up block and `provenAiredCount` (the mark target). Reading the raw
  fields made the one show that had just aired (Re:ZERO, 6:30 PM, 2 Sep) the one show Today could
  not see for an hour, and `lastAiredSortKey` (still the raw field — fine for the Library's calm
  shelves) handed the hero to a days-old drop. Hero pill: a drop that struck today leads with its
  recency ("AIRED 29 MIN AGO") whatever the count, the count moves to the support line, and the
  pill's dot belongs only to today's drop or a later-today airing. The hero's fact line is
  `heroMeta` in `textSecondary`, so the title and "Season 4 · Episode 12" never read as one line.
  The curated `FranchiseUpcoming` note goes stale the same way (its `checked` date is weeks old):
  a day-dated release that has passed (`hasArrived(now:)`) no longer files a show under the
  Library's Returning shelf — Mushoku Tensei read "Returns today" two months into its season.
- **First contact (2 Sep, evening pass; Today's half retired 25 Sep — an empty account now opens
  on the feed's `EmptyState(.emptyToday)` over the Trending module, and the drift lives on in
  Detail's billboard and the story art).** The hero names the show by `displayTitle` ("Re:ZERO"),
  as every row and shelf does; the full title is Detail's. Where-you-are on the hero is the one
  `ProgressBar` under the fact (watched ÷ aired-by-now for a fresh drop, ÷ available for a
  backlog; VoiceOver reads the count) — "4 episodes behind" in words only when nothing is watched
  yet and the pill spent itself on the recency. Queue rows draw amber only for TODAY's drop; an
  older one is a plain row. The billboard art BREATHES: `ArtHeader(drift: true)` scales the sharp
  layer ~7 % over 24 s, eased and reversing, off under Reduce Motion, one transform on one layer
  (Today and Detail both; nothing else drifts). **An empty account opens on television:** when the
  chart has loaded, Today's top block is the chart's #1 show on the same billboard — pill
  "TRENDING", `shelfShortened` title, "Anime · 1999", one capsule "Add to Library"
  (`addToLibrary`'s optimistic path; the real hero takes over when the library lands) — with the
  rest of the chart on a `.todayShelf` `ShelfCard` shelf whose header walks to Search; the
  skeleton holds while the chart loads (`trendingLoading`), and `EmptyState(.emptyToday)` is only
  the offline / no-chart fallback.
- **Catalogue enrichment (3 Sep, the backend's `feat: enrich catalog discovery` hand-off).**
  `Models+Enrichment.swift` holds the contract's deep metadata — `ArtworkSet`, `FranchiseVideo`,
  `AudienceInfo`, `FranchisePeople`/`CatalogPerson`, `RelatedTitle`, `ContinueWatching`,
  `WatchAvailability` — every one decoding LENIENTLY (an older server or a row the server's
  stale-while-revalidate pass has not reached reads as EMPTY, never as a decode failure), and the
  screens hide an empty section. **Art is read through `portraitArt` / `landscapeArt` / `wideArt`
  / `billboardArt` (`WideArt` = url + `portraitSource` + `ultraWide`), never `cover`/`banner` in a
  view**: `images.landscape` is honest (nil = composite the cover), and the legacy `banner` is
  trusted only when it differs from the cover (older writers copied the poster into it). **The
  server selects artwork (4 Sep, server 518430b):** `images.portrait`/`images.landscape` are its
  best per orientation, `artwork.portraits/landscapes/logos` (`ArtworkGallery` of `ArtworkImage` —
  url, source, width, height, language, score) are its ranked alternatives, and `cover`/`banner`
  mirror the selection. The order is authoritative: a view reads `images.*`, then the gallery's
  FIRST entry, then the legacy field — never re-sorted by score, size or provider, and a URL is used
  as sent. Both galleries decode leniently (a malformed entry drops itself, a missing list is
  empty) and ride through every optimistic copy (`Franchise(copying:)`, `withProgress`, `with(…)`,
  `grafting`). **Heroes are PORTRAIT-first** (`billboardArt` = `WideArt.billboard(portrait:
  landscape:)`, Today's billboard, Detail's, the trending billboard): the selected poster,
  composited whole through `ArtHeader(portraitSource:)`, and the landscape only when the
  catalogue has no poster. The billboard frame is ~0.64 w/h — within 4 % of a 2:3 poster — so a
  16:9 backdrop filled into it shows its middle ~36 %. The artwork hand-off's "heroes use
  images.landscape first" was implemented for a few hours on 4 Sep; on production every show had
  a TMDB backdrop and every billboard was a zoomed slice ("supposed to be portrait", "everything
  so zoomed", user) — the rule is wrong for a tall frame, and Android had never left cover-first.
  Landscape stays the choice of every 16:9 surface (`ProgressBanner`, `BannerCard`,
  the Up next cards, episode tiles). Grids, rows and shelves stay `portraitArt`-first. **The
  billboard's NAME is the show's LOGO, and the lockup is CENTRED (5 Sep, settled by a placement
  spike):** `HeroTitle` draws `billboardLogo` (`artwork.logos.first`, the server's rank) inside a
  box of ≤ 88 % of the copy run × ≤ 120 pt — EVERY logo, circular emblems (Slime, Demon Slayer)
  and stacked marks (Solo Leveling) included — with an 8-pt optical gap beneath its ink
  (`HeroTitle.logoBox`, `ThemeMetrics.billboardCopyWidth`); the name in type only where a show has
  no logo. A "headline-mass" rule that dropped emblems for type lasted a few hours on 5 Sep: the
  user liked the show's own logotype as the headline ("I really liked the previous series based
  font image") and disliked only its placement — "you could've done a /spike instead of sloppy
  replacement". Three placements were then photographed on Slime, Thrones and Solo Leveling
  (foot-left, centred, on the art — the last landed on a face on every show) and the user chose
  CENTRED: `HeroLockup` puts the badge, the name, the one line (with the reveal glyph riding beside
  it as part of the group), the bar and the support lines on the billboard's axis, the capsule
  full width beneath; `TrendingFocus` and the not-in-library name follow; the identity line, the
  synopsis and every row keep the page's left axis. `billboardArt` prefers `textlessPortrait` — the
  first ranked poster with no `language`, trusted ONLY when the gallery is tagged at all
  (`ArtworkGallery.textlessPortrait`: at least one portrait carries a language; the older untagged
  shape passed Bleach's titled poster as textless) — and asks TMDB for the `original`
  (`WideArt.billboardResolution`; the server's `w780` was drawn 1179 px wide, a 1.5× upscale;
  cards keep the size they were sent). **A name is ALWAYS drawn.** `BillboardName` is `.logo` or
  `.type` — the 4 Sep "art carries the name" case is gone: it assumed the poster's logotype sits
  where the copy does, Re:ZERO's sits in the top band under the back button and the status
  capsule, and on Today the wordmark band covers the same zone. Where the selected poster is
  titled and no textless one exists the name is set in TYPE, never as a logo (the user's pick);
  the real fix for those four shows and for Bleach is textless posters from the server's
  enrichment (fetch `include_image_language=null`, tag galleries) — a server ticket. Accessibility
  sizes always set the name in type. **Both billboards are ONE view, `HeroLockup`
  (DesignSystem/HeroLockup.swift, 5 Sep):** badge → name → one line (moment · fact, with an
  optional trailing ACCESSORY — Detail's reveal-title eye glyph in a 44-pt target that shares the
  row without growing it; the labelled toggle used to take half the fact's row and "Season 3 ·
  Episode 8" wrapped mid-phrase) → season bar → support → third line → actions. Today's
  `HeroFocus` is a thin adapter; Detail's `heroLockup(_:state:)` feeds it from `NextUp` (which
  gained `moment` — Today's grammar verbatim: a drop that struck today is "NEW EPISODE" on the
  badge with "Aired 2h ago" leading the line; a caught-up show's next airing leads the line).
  **The show page's state block is GONE:** the badge, the fact, the capsule and "Start rewatch"
  live in the billboard's lockup over the art's foot (`heroFraction` 0.72, Today's), and the
  identity line ("Anime · 2018 · TV-14 · Action · Adventure") heads the synopsis at `metadata`
  size, `ThemeSpace.x5` under the hero; the watch-history row follows the synopsis. `HeroCopyScrim`
  now LANDS for any copy height (its ramp marks are bounded by shares of `h − 40`; clamped only to
  `h`, a one-line copy put 0.72 at 92 % and never reached canvas — Re:ZERO's copyright line printed
  through and the hero ended on a hard step, luminance 45 → 27 in one row). The bar docks the title
  when the NAME reaches it (`badgeToName` = 20 + x3 above the copy's top). Android mirrors all of it
  (5 Sep): `ArtworkImage`/`ArtworkGallery` (lenient, `SafeListSerializer` drops url-less
  entries), `artwork` on the three classes, `textlessPortrait`/`billboardLogo`/`billboardName`,
  `ui/hero/HeroTitle.kt` (`HeroLogo.box`), `ui/hero/HeroLockup.kt` (`HeroLockupDefaults`, centred),
  `DetailHeroCopy`, `billboardResolution`, `Billboard.detail` 0.72; verified on the emulator
  against production as the Clerk test user (build with
  `-PapiBaseUrl=https://anime.cognipin.com` and NO `-PclerkKey=`; the FIRST screenshot after an
  `am start` needs ~15 s — at 8 s the emulator still shows the ident).
- **The world-class loop (5 Sep, five iterations of adversarial review → fix, all pages).** The
  reviewer is a subagent fed the full capture set (`scratchpad/loop/capture_ios.sh`: Today ×5
  states, Schedule, Library, All titles, Search, Profile, four show pages, three Detail anchors,
  the trailer stage, both receipts) plus frame sheets of a cold launch, a push and a receipt
  (`record_motion.sh`, 8 fps), the iOS-conventions section of this file and the code; it verifies
  the previous iteration's findings first. Rules that came out of iteration 1: the in-place
  receipt is an OVERLAY hanging under the capsule (`HeroLockup(receiptHost:)` → `ReceiptLine`
  offset by its own 28-pt height; a layout child pushed the lockup 48 pt a second after the tap;
  Today's recap mask extends 44 pt below the hero for it); the band under a billboard is x4 on
  both screens (capsule → next header ≈ 38 pt, was 66); a `.fresh` hero shows the drop's recency
  as the MOMENT only when `behind == 1` — with a backlog "Aired yesterday · Season 4 · Episode 19"
  bound episode 21's drop to episode 19, so the line is the episode alone and the support line
  says "Episode 21 aired yesterday"; the recap strip carries no numeral under a badge that has
  one; Today's bar docks the show's title only while the lockup PASSES under the wordmark band
  (`heroCopyUnderBand` = the copy's frame straddles the band + 12) and gives the wordmark back
  once it has left; Detail's docked title scales to 0.85 before it ellipsizes; a 3-column GRID
  reserves two title lines (`ShelfCard(reserveTitleLines: true)` on Search's grid and More like
  this) so captions share a baseline — shelves keep the unreserved form; `PersonCard` roles are
  one line; `FranchisePeople.ordered` is CAST first (10), then creators, then only real directors
  (the server files camera and AD crew under `directors`), capped at 16; the finished show's
  lockup is "Watched once · 95 episodes" + ONE more line; `Copy.Library.rumored` strips a curated
  "(rumored)" then says it once; All titles states "Watched · Returns 3 Oct" on ONE line with the
  date in accent (`MediaRow(metaLead:)`, `LibraryRowFacts.metaLead`); Profile's identity line is
  three numerals on one line, no "Signed in" when it names nothing, and its Watching captions
  carry the badge's count ("3 episodes behind"); a shelf of ONE runs gutter to gutter (span 5);
  the ident holds 0.82 s and exits in 0.28; NO haptic on a tab switch, the Haptics toggle or
  Schedule's toggles — a haptic is a signature for a write. The trailer stage: ambient lit (0.22,
  stops 0/0.08, 720 px, blur 44), the lockup + x8 + picture floated to the centre, a glass play
  disc that becomes a spinner at 0.9 s, the video's title without the show's name
  (`FranchiseVideo.title(cleanedFor:)`). **Iteration 2:** Today's bar stays hard once the lockup has passed the ramp
  (`heroUnderBand`), the ident waits for the first billboard's art (`LaunchHandoff.artReady`,
  `artPatience` 1.6 s) and has a 2.4-s WALL ceiling from its first frame (`wallCeiling` — live
  seconds cut stalls out, so a starved sim held it for six), `onFinished` also sets `emerged`
  (the app must never rest at 0.96); docked names go through `FranchiseDetailView.dockedName`
  (budget 19 in Detail's bar, 28 in Today's band — fit, shortened, or the WORDMARK stays, never
  the full name); the hero bloom is centred under the lockup (0.5, 0.26, r 88); the drop line
  under a backlog badge is `Copy.Progress.dropAired` ("Episode 21 aired yesterday"). **Iteration
  3:** a name set in TYPE starts its cover under the wordmark band (`ArtHeader(topInset:)`,
  blended over 56 pt — the mask exists ONLY on that branch, see the lag rule below); a logo keeps
  the full bleed; `HeroTopVeil` 0.72/0.66/0.52, ramp 100; the receipt hangs 24 pt; shelf titles
  are budgeted (`shelfShortened(fitting:)` 24 free / 26 reserved / 30 lane) and a reserved card
  runs 2…3 lines (a floor, never a cap — `lineLimit(2...3)`); Today's Watching shelf excludes
  the Up next shows; the stage's exposure follows the art's OKLab L (dark art lit, bright art
  veiled); the certificate is an outlined TAG after the year with air on both sides and no
  middot against it; the add disc sits on the POSTER's foot (an overlay anchored at the card's
  top, offset by the poster height, outside the card's button). **Iteration 4:** copy has one
  voice — "In Library" (capitalised only in a destination phrase), "rumoured" (UK, as
  "catalogue"), one offline line ("Showing what was saved on this device. Changes sync when you
  reconnect."), "Mark as caught up", "Your schedule couldn’t refresh", "Removed from Library ·
  Watch history kept", Library's shelf is "Next up" (Today's name; `airingSoon` is gone);
  Schedule's filtered-out state is its own (`noScheduleMatches`); a behind count on a Watching
  shelf is amber only while the drop struck inside `nowBarLiveWindow`; "Read more" is drawn only
  when a hidden full-height measure exceeds the clamped paragraph; **a finished series moves to
  Watched on its last mark** (`AppModel.settleCompletion` in `applyLocalProgress`, keyed on
  `Franchise.isWatchedThrough` — every episodic part complete and nothing releasing or upcoming; a
  curated RUMOUR does not hold a show in Watching — undone with the mark, and
  `settleCompletedSeries` once per session for rows the server still files under Watching); the
  "30 titles ›" door is `interactive` with a chevron; trailer captions drop the kind when the name
  says it and print the provider as written (`FranchiseVideo.providerName`), names lose a
  trailing "(Provider)" and straight quotes; Schedule's clock column runs the whole feed (a
  date-only airing keeps an empty column). **The lag rule (5 Sep, "unusable", then "halts
  halfway"):** nothing on the billboard's sharp layer may be an offscreen pass — `.mask { … }` is
  one even when its body is `Color.black`, and under the 24-s drift it ran once per frame on a
  2048-px layer; the blurred ground decodes at 1024; and scroll-driven facts
  (`heroCopyUnderBand`, `heroUnderBand`) live on `ScrollOffset` (`setCopyUnderBand`), read only
  by `TodayHeaderBar` and `TodayVeils` — as `@State` on TodayView each flip re-ran the whole
  screen at the moment the veils were also swapping; the veils keep ONE `ScrollEdgeChrome`
  mounted and switch its height/hold/opacity. **Iteration 5 (the last):** no scale on the app tree at launch (the ident's ground IS the
  reveal; `IdentClock` cuts stalls only while holding, the ground lags the composition by
  0.05 s); the recap row names the EPISODES ("Season 4 · Episodes 19–21") under a headline that
  carries the count; shelves are unreserved, grids reserved (for good this time); cast names one
  size, two lines, cards top-aligned; the stage's ambient has a FLOOR (dark art lifted, a pool of
  the show's hue with light); the synopsis clamps at a word; "Stop this rewatch" is the one verb;
  `plural` groups thousands; a themes line needs two themes; outside the 60-day horizon a
  Returning caption is the window alone in grey; both skeletons are the centred lockup the page
  arrives with; `markNext` signs the series-finishing mark `.success` itself and its receipt
  says "Series finished · Moved to Watched"; the lane's title is one line; **"today" is the
  calendar day the temporal ladder uses** (`FranchisePart.airedToday`), never a 24-hour window —
  a badge, a moment or an amber lead may not call "yesterday" today. Not done: centring Detail's
  docked title (the editor role leading-aligns it; the iOS-18-safe alternatives cost the roots'
  titles or the swipe-back gesture). The five-item backlog after the loop is server/device work:
  textless posters + logos for AniList-only shows, `contentRating`/`partCounts` on the list
  payload, anime billboard art from the TMDB twin, cold-start measured on a device, a motion
  harness (`-motionDemo`) that reaches the push and the mark. **The interactive pass (5 Sep, "let the UX reviewer use the app… like a real user"):** the
  reviewer drove the QA sim through fb-idb (`DEVELOPER_DIR=/Applications/Xcode.app` — the
  simulator MCP had died) and the rules that came out of real use: every scrolling root adds
  bottom clearance while a receipt lane is up (`laneClearance`, `ReceiptLane.height`) — a lane
  over a row's disc turned its Undo spot into a "+" six seconds later; a Schedule card opens the
  show page and the episode list in ONE push (`DetailRoute.focusPushed`) and the list's focus
  scroll retries after layout; "Most left to watch" sorts Watching/Paused by backlog first;
  the capsule's range item exists only as a strict subset of "all"; the hero's receipt lands at
  the TAP and list receipts take the row's OWN second line (`ReceiptLine(inline:)`,
  `ReceiptLine.isLive`) (retired 6 Sep: the list's ring is its own receipt) — a receipt is never a layout child that moves the page; a zero-hit search
  is an empty state, not an error; the alerts primer sits below the results; Schedule confirms a
  batch with an alert that has Cancel and lands on yesterday's unwatched drop when today is
  empty; "Next up ›" opens the queue sorted as one; removing a show keeps its face
  (`Franchise.keepingArt(of:)`); Profile's Notifications row always shows its state and asks
  in-app before it ever sends anyone to Settings; a Planned show's lockup waits (no capsule).
  Still open: the same-picture slide from Today's hero into Detail, the Clerk dev instance's
  name and password-first step on the sign-in sheet, the share sheet's placeholder icon. Per-iteration notes: `scratchpad/loop/log.md`.
- **Receipts, not toasts (5 Sep, "the toasts are archaic according to 2026 standards" → a spike of
  four directions photographed on the sim, B + C chosen).** A transient confirmation is drawn in
  ONE of two places, decided at the WRITE (`UndoState.placement`, `ReceiptPlacement`, `Receipts.swift`):
  **IN PLACE** — `ReceiptLine`, one quiet line "✓ Episode 19 watched · Undo" under the control that
  was pressed, when that control stays on screen: the story viewer's mark (`ReceiptHost.story`,
  which hands a live Undo to the lane when the viewer closes) and Schedule's rows (`schedule(mediaId,
  episode)`, under the caption) — Today's hero and Up next hosts went with TodayView (25 Sep), and a
  hero capsule's own drawn check is its receipt — the write site calls `.placed(at:)` (`presentUndo(_:host:)` on
  Android); a season reset stays on the lane (every ring clears, no row can hold it). The episode LIST has had no receipt since 6 Sep — its ring is the receipt (see the Episodes bullet). **THE LANE**
  — `ReceiptLane` (poster or glyph, the fact, the show, Undo/none) in `LaneFallback`'s glass,
  floating just above the app's bar (it was the system bar's iOS 26.1 accessory until 25 Sep) / on
  Android (`LaneHost` in `Toast.kt`): a removal, a move, an add from Search, a caught-up
  from a context menu, the two-second notices ("Episode alerts on") and the write failures — one
  `LaneItem` at a time (`AppModel.laneItem`: error, else a lane-placed undo, else the notice). The
  fact is `UndoState.receipt` ("Episode 19 watched", "Removed from Library" — `Copy.Toast.removedShort`;
  the full sentence stays in `message` for VoiceOver), never the show's name in the fact when the
  poster or the line beneath already says it. `ErrorToast`/`UndoToast` are retired; `ToastHost`
  keeps the persistent `SyncBanner` and the lane. Capture with `-toastDemo mark|lane|notice`
  (`-toastDemoFranchise <id>`): a receipt that writes nothing. The shipped toast was one grey capsule
  for all of these, fading in with a 4-pt rise, 330 pt below the capsule it confirmed and over the
  shelf, spending two lines on the show's full name under a hero that already said it. Detail fetches `?country=AppRegion.current`
  (the device region, "US" fallback), reads `/watch-providers` separately (a failure is a missing
  section, never an error), grafts the detail read onto the live library copy field by field
  (`Franchise.grafting` — the library payload was read at launch, before enrichment may have run)
  and re-reads once after 6 s when the row `looksUnenriched`. Its sections, after Movies & extras,
  in Apple TV's order: **Trailers** (`TrailerCard`, played in the card — see "A trailer is
  WATCHED WHERE IT IS"), **Cast & crew** (`PersonCard`: 72-pt disc, name, role — not a control),
  **More like this** (`ShelfCard`s; `franchiseId` → `push(.detail)`, else an exact-title search
  materialises it or `Copy.Notice.notInCatalogue`), **Where to watch** (drawn only for
  `status == .available`: provider marks, the header opens `link`, the JustWatch attribution as a
  footnote — a section that says "not here" is not a section). All four share `DetailShelf`. The
  market's rating sits in the identity line after the year ("Anime · 2016 · U/A 16+ · Action");
  themes the genres do not already say run under the synopsis in `metadata`; a rumour is labelled
  one everywhere the curated fact appears ("Season 3 rumored" — `ReturnFact` / `Copy.Library.rumored`,
  never a date, never amber) and Detail's COMPLETE block carries the curated next installment
  ("Season 3 · Returns Oct 2026") so the show page cannot contradict the Library shelf. The Continue
  card names the next episode from `continueWatching` ("Season 4 · Episode 12 · The Lion and the
  Sea"); `EpisodeStill` falls back still → landscape art → cover under the number. Every optimistic
  progress copy goes through `FranchisePart.withProgress` — the hand-built copy it replaced dropped
  `airings`, so one local mark took a show off the calendar until the next reload.
- **The identity is the SPLIT-FLAP mark (26 Sep): "P." on a departures board — what arrives
  next.** Chosen after five rounds (a folded-ribbon P "not easily recognizable"; the five gels as a
  gradient icon "just blatant Instagram copied"; twelve flat directions "2026 standards"; then as
  Liquid Glass objects), and A (dark) + D (light) refined through three rounds before it shipped.
  ONE geometry: `DesignSystem/FlapGeometry.swift` (design units, the board 708 × 620: two flap
  modules split by a hinge seam, round axle pins, a P DRAWN FOR THE BOARD — its bowl ends 3 units
  above the seam, so the top flap carries the bowl and the bottom flap the stem — and the coral
  stop on its own flap). Every drawing reads it: the app icon (`Resources/AppIcon.icon` = icon A,
  generated by `design/app-icon-splitflap/src` and rendered by Icon Composer), `PreviouslyMark`
  (`.board` — the gate, the launch's landing, the colophon; `.glyph` — the cut P with the stop
  kerned under its bowl, where the mark is ~20 pt: the feed header, the account disc) and the
  launch film. **An iOS 26 icon has at most FOUR glass groups** — actool refuses more ("Too many
  visible groups") although Icon Composer's own renderer draws six happily; the flaps and their
  pins share one. **The pairing (D in light mode) is not wired:** this Mac's ictool ignores every
  appearance specialisation (fill, image, hidden), so it cannot be rendered or verified here — do
  it in Icon Composer's editor. D's letter is printed ink (not glass), and D still washes out in
  TINTED light — tinted must come from A. The feed header draws the glyph where the name was (X's
  logo in the middle of the bar). The ribbon (`RibbonShape`, `RibbonFill`, `MarkGeometry`) is the
  retired mark, kept only for the films behind `-splashDirection` and the old ident.
- **The launch is the board FLIPPING to "P." (26 Sep — `SplashFlapFilm`, App/Splash/SplashFlap.swift; the
  default `SplashDirection.flap`).** Pure Core Animation, every move a keyframe track built once in
  `build` (the render server plays it; nothing per frame on the main thread): the blank board fades up
  (0–0.18 s), the letter module flips blank → L → N → P like a real board — the old top half falling
  toward the viewer about the seam, the new bottom half swinging down on the flap's back with one
  damped bounce, shade as a flap turns edge-on, a soft shadow on the lower flap while one passes — the
  flips slowing into the P (lands 0.61 s); the stop's module turns 80 ms later; the gate's light comes up
  and the name rises in (0.88–1.28); the film crossfades onto the gate's own board picture
  (`LaunchLockup`) and lands at 1.44 s. L and N, not A: an Outfit Bold A is as wide as it is tall and
  runs to the flap's edges. The exit fades the lockup (0.16 s) and lifts the canvas only after it
  (0.14–0.42 s) — overlapping, the name and the arriving feed showed as a double exposure. On the sim a
  warm launch plays at 60 fps; the first launch after an install stalls ~0.45 s (the sim, not the film).
  The paragraphs below describe Align, the film it replaced (still behind `-splashDirection align`); its
  hand-off rules (landing seen, auth, art, ceiling, Reduce Motion's still lockup) still bind.
- **The launch is a short film, "Align" (25 Sep).** The launch screen is the bare canvas
  (`UILaunchScreen` = `LaunchBackground` = `ThemeColor.canvas`, no image). `SplashView`
  (App/Splash/SplashStage.swift) mounts `SplashStageView` over the app from the first frame; the film
  is `SplashAlignScript` + `SplashAlign.metal`, drawn by `SplashGlassRenderer` on a thread of its own
  from a plain `CADisplayLink` — NOT `CAMetalDisplayLink`, which only fires while the window is being
  composited for some other reason: on a signed-out launch (the app idle under the film) it fell
  silent 0.4 s in, and the film froze and then jumped to its end. The film: five layers of coloured
  glass in the mark's shape (gold, amber, coral, rose, violet) fanned in depth; one slow camera move
  brings them into register, each gel's colour sliding into the icon's ramp; the registered sheet IS
  the mark and crossfades into the sign-in gate's own lit mark; the gate's light comes up and
  "Previously." (`ThemeType.brandDisplay`, SemiBold) surfaces. Lands at 1.90 s, the finished lockup
  still from ~1.62 s. The only motion is the camera's. Rejected on the way, in the user's words: films
  built on show art ("heavily centered on hero which we will not have most of the time"), a glossy
  bead ("feels like something from 2004"), a soft glow ("utter trash"), random spectral bands (Silk:
  "way too random… transitions to what?"), one silk ribbon on an S ("feels like a Snake"); brand
  films "gimmicky and overboard"; Lens/Glass "boring". The rejected films are still in the tree
  (`-splashDirection`) for comparison.
  **One lockup for the launch and the gate (`LaunchLockup`):** the lit 56-pt mark, the name under it,
  the bloom. The film lands on PICTURES rendered from the gate's own SwiftUI views
  (`LaunchLockup.images`, redrawn as 8-bit premultiplied sRGB — `ImageRenderer` can hand back a
  half-float picture Metal's texture loader refuses — and cached on disk per scale, text size and
  build, so from the second launch they are in the first frame; bump `design` in the cache key when
  any of those views changes) at `markFrame` (centre 0.36 × height signed out, where the gate draws
  it; 0.42 signed in). A signed-out launch hands the mark to the gate with no seam — only the tagline
  and the button arrive — at every text size (the gate uses the same geometry; the film's name is
  capped at AX2 like the app). Shaders that imitate a SwiftUI `LinearGradient(.topLeading →
  .bottomTrailing)` must lay it out in the shape's UNIT square, not in points (on the tall ribbon the
  two differ by a third of the ramp).
  **The hand-off:** the stage leaves only when the landing has been SEEN (on a device the renderer's
  clock follows each drawable's presented handler and rewinds past a display stall; the simulator SDK
  has no presented handler, so there GPU completion stands in and the rewind is off), never before
  auth answers, at most 0.35 s past the landing for the feed's first art (`markArtReady`), ceiling 3.2 s. A tap skips once auth
  has answered; a launch FOR a show (`LaunchHandoff.intent`, set on the pending-open route) gives way
  at once. The exit is two-stage: inside the film the lockup goes to plain canvas (0.18 s), then the
  canvas layer lifts off the app (0.08–0.38 s) — never scaled (scaled, its edges uncovered a
  flickering rim of the app) and never printed over Today. The stage keeps its own canvas until the
  film's first frame is on screen (clearing it at build flashed the gate for a frame). The app is
  `accessibilityHidden` until it emerges; `finish()` posts `.screenChanged`. Under Reduce Motion,
  with VoiceOver running, on a hot phone or without Metal, `SplashLockup` fades the cached lockup up,
  holds 0.6 s and dissolves; Low Power Mode holds the film at 60 Hz. Every value is a pure function of
  film time (live time from the link's target timestamps, stalls > 0.25 s cut out, 0.4 s in all).
  **Full-height art on a root sizes itself from `ThemeMetrics.windowHeight`**, never the tab
  content's height: that shrank when the tab bar arrived at the end of the launch, and Today's 0.72
  billboard (retired 25 Sep) slid ~41 pt under the dissolve. Films are explored in a macOS Metal harness (scratchpad) that renders the same shader
  and script in seconds; the review rig films three simulators (SE / 14 Pro / Pro Max, signed in and
  out) frame-exact with `-splashFilm 1` and live with `simctl io recordVideo`.
- Debug-only launch args: `-splashTrace 1` (milestones since process start, one line per frame),
  `-splashFreeze <s>`, `-splashFilm 1` (the film frame-exact at 30 fps to Documents/splash-film/),
  `-splashReduceMotion 1` / `-splashVoiceOver 1` (force those paths), `-splashDumpPictures 1`
  (the lockup's pictures to Documents/splash-pictures/) and `-splashDirection <name>`; `-openDetail <franchiseId>` lands on a show page (the alert-tap route);
  on it, `-detailAnchor trailers|people|related|watch` scrolls to a catalogue shelf,
  `-detailTrailer inline|full` plays the first trailer in its card (then full screen) and `-detailOpenRelated N` opens the Nth
  related title — the way to photograph the show page when the simulator cannot be touched (on
  3 Sep System Events saw no Simulator window and `screencapture` was refused, so cliclick had
  nothing to hit; `xcrun simctl io screenshot` still works). The feed's capture flags (`-feedTab`, `-feedAnchor`,
  `-feedStory`, `-feedThread`, …) are listed under "Today is the feed" — they are how the feed is
  photographed and scrolled when the input MCP is dead (`simctl` cannot scroll); `-recapDemo`,
  `-calmDemo` and `-todayAnchor` went with TodayView (25 Sep);
  `-scheduleFilter anime|tv`, `-scheduleHideWatched 1`, `-scheduleMonthOpen 1` (open with the
  calendar down) and `-scheduleDemoStates 1` (draw the most recent aired airing as unwatched — the
  test account has no aired-and-unwatched slot, so the state ladder cannot otherwise be
  photographed with all three rungs) open Schedule in those states (`-scheduleEarlier` went with
  the Earlier fold on 4 Sep, `-scheduleDemoCounts` with the day rail on 6 Sep); `-openTab
  today|schedule|library|discover`, `-openAllTitles 1` (one-shot) and
  `-openProfile 1` land on a screen for a capture. When the simulator MCP tool is dead, the sim can
  be driven from the desktop: open it with `open -a Simulator --args -CurrentDeviceUDID <udid>`,
  read the device frame from the window's `AXGroup` via System Events, and click with `cliclick`
  (a plain click hits rings, rows and the tab bar; SwiftUI buttons outside the scroll view — the
  avatar, a toast's Undo, a system alert's Allow — need a ~150 ms press; a 1 s press opens context
  menus). Never type unless a capture proves the field has focus.

- **Smoothness is measured, not felt (5 Sep, "butter smooth… lags are not acceptable").**
  Instruments cannot attach to the iOS 27 QA sim (xctrace records an empty trace from either
  Xcode; Animation Hitches refuses simulators), so the app carries its own instruments:
  `App/PerfProbe.swift` (DEBUG, or `-D PERFPROBE`; launched with `-perfProbe 1`) is a
  `CADisplayLink` hitch logger (every frame gap ≥ 34 ms → `Documents/perf.jsonl`, with the screen
  from the `.perfScreen("…")` hooks in `RootView`) and a watchdog thread that samples the MAIN
  THREAD'S STACK while it is stalled (suspend, copy the frame-pointer chain into a preallocated
  buffer, resume, then `dladdr` — the app's code lives in `Previously.debug.dylib`). The scripted
  flow, the scorer, the stack aggregator and the A/B switches (`-perfNoShelfMask 1`,
  `-perfNoMaterial 1`, `-perfNoDrift 1`) live in `ios/Tools/perf/` (README
  there). Rules that came out of the pass, each one measured:
  **a blur is a property of the image, never of a layer** — `BlurredArt` renders the blur once,
  off-main, from the SAME decode the sharp layer draws (one fetch), into a 160-px bitmap cached
  beside the decodes (`ImageCache.derived`); the billboard ground, every root wash
  (`ArtBackdrop`), every composited card ground (`LandscapeArt`) and the trailer stage (its
  saturation and lift baked in) use it, because `.blur(radius:)` on a composited layer is a
  Gaussian pass over that layer on EVERY frame it is on screen — every scroll frame, every frame
  of the drift, every frame of the stage's breath; a static blurred SHAPE gets `.drawingGroup()`
  (the ident's cast shadow, the sign-in bloom, the recap fan).
  **A card's shadow is drawn by its ground shape** (`cardShadow(_:shape:)` — `fill.shadow(.drop)`
  rasterised with the shape) — never `.shadow` on the composited card, which renders the card
  offscreen to find its silhouette on every frame; a fitted poster's contact shadow is a shape
  the size of the fitted picture (`CachedAsyncImage(fitShadow:)`). `.shadow(_:)` remains for
  things that are not cards (a toast, the brand mark).
  **Derived collections are memoised** (`AppModel.memo`: `outNow`, `soon`, `nextUp`,
  `keepWatching`, `watchingShelf`, `libraryShelves`, keyed on library version + minute +
  celebration, like `scheduleDays`; the memo reads `library` once so a body that only reads a
  derived collection still observes it) — they were filtered and sorted on every read, and
  Today read them ten times per body. **The clock ticks ON the minute** (`startClock`), not every
  20 s: every fact it feeds is minute-grained, and each tick re-evaluates every body that reads
  `now`. **The scroll offset is never screen state** — Profile joined Today (then) and Detail
  (`ScrollOffset`, `ProfileWashTravel`); as `@State` every sample re-ran the sheet's body with
  its library counts. **The library's offline copy decodes off the main actor**
  (`AppModel.start()`); it was the first thing sampled under the ident.
  **The show page's shelves are LAZY** (`DetailShelf`, the extras row — `LazyHStack`): a page
  carries up to 13 trailers, 16 people and 12 related titles, and an eager row built every one
  of them on the push, for cards three screens off to the right. **A billboard's protection
  follows the art's lightness** (`HeroProtection`, the same 5 Sep: "the overlay on hero is too
  dark as the new images are themselves dark"): `PaletteCache` now also remembers each
  picture's mean OKLab L (`lightness(for:)`, filled by the tint's own extraction), and
  `HeroTopVeil(strength:)`, `HeroCopyScrim(strength:)` and `ArtHeader(groundDim:)` scale with it
  — full over a bright cover, 0.35 over a dark one (L 0.30 → 0.35, L 0.60 → full; OKLab
  compresses the darks, Thrones measures ≈ 0.28, Wednesday ≈ 0.35, a bright poster ≥ 0.6). The
  copy scrim's ramp scales above per-stop FLOORS so the frame still eases onto canvas; the
  landing never scales. **Search's rows are EQUATABLE** (`SearchResultsList` + `SearchRow`, 5 Sep, "the search bar
  experience is lagging AF"): typed at human speed with the stall sampler on, every keystroke
  re-ran the screen's body, and a row's closures (its action, its trailing control) mean SwiftUI
  cannot prove a row unchanged — so every result row was rebuilt on every letter, button style,
  context menu and all (300 ms per key on the sim, most of it in the rows' `makeBody`). The list
  compares its data (ids, ownership, statuses, the minute) and each row compares what it shows
  (`SearchRowKey`), so typing costs the field and the keyboard only, and an answer landing builds
  only the rows that are new — and only the rows ON SCREEN (`LazyVStack`: "o" and "on" answer
  with thirty rows, all of which a plain stack built under the next keystroke); the
  duplicate-title scan (a regex per row) is memoised on the result ids. The add control's
  erased `AnyButtonStyle` is gone (a concrete style per placement): the `AnyView` it boxed every
  `makeBody` in was the leaf of the typing stalls; and an UNOWNED add control is a plain
  `Button`, a `Menu` only once owned — one `Menu` per result row was 40 % of an answer landing
  (a UIKit menu interaction per row that would never open), so the ownership flip crossfades the
  control instead of morphing the glyph. `Tools/perf/typing_test.py` +
  `typing_report.py` are the measurement (an answer landing: 340 → ~160 ms on the sim in Debug
  after the list changes; the rest is the keyboard's). **Search's launchpad stays MOUNTED under the results** (5 Sep, "it lags when I click
  on the Search bar… it lags to revert back to the original state"): the browse grid and the
  recents used to be one tree swapped for the results tree through `.id(query.isEmpty)`, so the
  first letter tore down fifteen cards (poster, palette, add control each) and Cancel rebuilt
  them from nothing — under the system's own field and keyboard animations. The grid is an
  eager `Grid` built once per chart; the query fades the launchpad and folds its height to zero
  (`frame(maxHeight: 0)` + `clipped`), Cancel unfolds it; the recents are mounted whenever there
  are any and folded until the field has focus. `Tools/perf/focus_test.py` measures the three
  moments. The FIRST focus of a process is the text-input stack coming in — dyld, `read`,
  `open`, class loading, 1.7 s on the sim in one stall, 80 ms for the second focus — so
  `App/KeyboardWarmup.swift` takes and drops focus on a zero-size field once, 1.8 s after the
  app has emerged, only while the app is still at rest on the tab it launched on (a tab
  switched or a page pushed means the moment has passed). The recents rows and the chart's cards are equatable like
  the results (`SearchRow`): the focus flips `fieldPresented`, the launchpad's body re-runs, and
  they were rebuilt under the field's own animation — each card asking `AppModel.franchise(id:)`
  twice, which was a linear scan with a struct copy and is now an index lookup
  (`libraryIndex`). What is left of the first focus (~400 ms on the sim, ~80 ms for every
  later one) is the text-input session starting: `liblangid`, `TIInputModeController`, the
  keyboard's image cache, IPC to the keyboard process — none of it ours (superseded 6 Sep by the unseen real-keyboard warm-up in "The search field's focus", above). **Search's busy flag stays at the KEYSTROKE** (`AppModel.scheduleSearch`):
  raising it only when the request goes out was tried and filmed (5 Sep) — the 300 ms between
  the last letter and the request drew "No results for …" over the trending grid, then the
  skeleton, then the answer. The "extremely glitchy" Search the user saw was two intermediate
  builds' one-frame deferral re-fading the trending grid on every return to the launchpad (gone
  with the deferral) plus the keyboard's first-use freeze (~0.7 s on the sim, the system's). The
  film of a query (`Tools/perf/hero_check.sh`: `simctl io recordVideo` + `idb ui text`, frames
  at 12 fps) is how a "glitch" is diagnosed.
  **The search field's focus (6 Sep, "the search bar click, keyboard are so unreliably
  glitching"; filmed at 60 fps with every tap verified on screen and every latency read from the
  app's own clock — `Tools/perf/focus_film.py`, `touch-down` / `search-presented` /
  `keyboard-will-show` marks in `PerfProbe`).** What the films showed: in the steady state the
  field presents ~50 ms after the finger lands and the keyboard's own animation (0.38 s on iOS 26,
  reported by its notification) starts ~175 ms after it — UIKit's presentation work, none of it
  ours; the FIRST focus of a process added 300–750 ms of freeze before anything moved (the text
  input session, the search keyboard's layout and key images, the search controller's view), and
  under that freeze one tap rendered as three beats: the field jumped to the top, then the
  keyboard rose, then the recents popped in. Rules that came out of it. **A keyboard cannot be
  warmed unseen on iOS 26+:** the keyboard is composited from outside the app — the only window
  a presentation adds to our scene is `UITextEffectsWindow` at level 10 — so a warm-up that lets
  a real keyboard present SHOWS it (filmed over Today for 0.7 s; `Tools/perf/warmup_check.py
  --film` scans every frame of a launch and is the gate for any change to `App/KeyboardWarmup.swift`).
  What the warm-up does instead is start the text-input SESSION: a `UISearchTextField` with the
  searchable field's traits and an EMPTY input view takes first responder (the session starts,
  the frameworks load, `keyboardWillShow` reports a zero height), holds 0.5 s, resigns — a beat
  after emergence, only at rest on the launch tab, only after 0.8 s without a touch
  (`KeyboardWarmup.install()` timestamps touches), never over a banner or lane, never in Low
  Power Mode, `-perfNoWarm 1` off. **What moves with the keyboard moves ON the keyboard's
  clock** (`ThemeMotion.keyboard`, duration from `KeyboardMotion`, the keyboard's curve): the
  launchpad's recents unfolding and the grid making room were on `uiGentle` (0.22 s) and had
  settled while the keyboard was still rising. **Never score the simulator's keyboard without
  seeing it:** the sim drops into a hardware-keyboard mode on its own — after `idb ui text`, and
  after typing on the Mac while the Simulator window has focus — and then every focus shows a
  caret and NO keyboard, across relaunches, until `simctl shutdown` + `boot` (or ⌘K in
  Simulator.app). That is what a person watching the QA sim sees after typing into it; it is not
  the app. Left where it is: the keyboard's own first build (`TextInputUI`, `CoreUI`) and the
  search controller's first presentation are the system's, and device numbers were never taken.
  `/Applications/Xcode.app` left the machine mid-session; `Tools/perf/simkit_shadow.sh` builds
  the shadow bundle idb needs.
  Measured and REJECTED (all on the sim, Debug): pre-rendering the other roots and the hero's
  show page off-screen after launch (a "warm-up") made no tab faster — a first render's cost is
  per-instance SwiftUI construction, not one-time metadata — and cost ~700 ms of stalls after
  every launch, and worse wherever it landed if the person had already moved on; a keyboard
  pre-warm run at the END of a warm-up sequence cost 440–870 ms wherever it landed and made no
  keystroke faster — but see `KeyboardWarmup`, below, for the form that stayed; a one-frame
  DEFERRAL of a root's content (chrome first, content on the next frame with a crossfade) was
  filmed at 60 fps with and without: the tab bar's highlight and the new screen's chrome landed
  in the same frame either way and the content followed ~130 ms later either way — it bought
  nothing and added a second commit; the shelf fade mask and the bars' masked material measured
  within noise — both stay. Two things the
  numbers are NOT: `idb ui describe-all` switches accessibility on in the process until the sim
  reboots (AX bundles load, every layout is taxed) — a measured run never asks the tree; and a
  Debug build's first render of a root is 250–400 ms of SwiftUI/AttributeGraph/Swift-runtime
  work under `$main`, and an optimised build (`Tools/perf/build.sh <tag> opt`: the Debug
  configuration at `-O` whole-module) is NOT much faster on the sim — the work is the
  framework's, not ours; a device is the only honest clock for those. Say which build a number
  came from. Where the pass ended (Debug, sim, the scripted flow): hitches 119 → 83, dropped frames
  1255 → 409, the worst gap in the whole app 2.1 s → 0.41 s (the launch, under the ident),
  stalls over 100 ms 49 → 20; typing into Search 975 → 336 ms of gaps for a nine-letter query;
  every vertical scroll's worst gap under 70 ms (Today 46, Schedule 66, Library 67, Detail 39);
  horizontal shelves and the stage's idle at zero. Search's moments (`focus_test`): the first
  focus 1.67 s → 0.33 s, every later focus 55–70 ms, Cancel 0 ms, the first letter 736 → 313 ms.
  What is left is first renders (a tab's first visit 230–370 ms, a push ~350 ms, the Profile
  sheet ~330 ms on the sim) and the text-input session's own start.

## Don't commit

- `ios/build/` (Xcode DerivedData + SwiftPM checkouts — gitignored via `ios/.gitignore`).
- `server/.env` and any **DB dump** (`*.dump` / `*.sql` snapshots contain user emails + Clerk ids).

## Moving the backend (DB migration)

Code moves via git. The data does not — take a dump and restore it on the new host (e.g. Mac mini):

```bash
# On the current machine (Postgres 16, db name `previously`):
pg_dump previously -Fc --no-owner --no-privileges -f previously.dump   # custom format (recommended)
# or plain SQL: pg_dump previously --no-owner --no-privileges -f previously.sql

# On the Mac mini (after installing Postgres + cloning the repo):
createdb previously
pg_restore --no-owner --no-privileges -d previously previously.dump    # or: psql previously < previously.sql
```

The dump includes the `drizzle.__drizzle_migrations` bookkeeping table, so a restored DB is already
at the current migration — `npm run db:migrate` against it is a no-op (don't `createdb` + migrate
*instead* of restoring, or you'll get an empty schema with none of the data).
Then set `server/.env` (`DATABASE_URL`, Clerk + OpenRouter/Cerebras keys) and `npm run dev`.
A plain-SQL dump taken on 2026-06-24 lives at the repo root as `previously-2026-06-24.sql` (gitignored).
