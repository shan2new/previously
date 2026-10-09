# Previously. The consumer release.

Revised 7 October 2026. Original planning snapshot: main at 19649b3, 5 October. New qualification applies to the changed working tree and the artifacts named in the receipts.

Outcome: a production-ready consumer app and the exact final build actually submitted for App Store review. Code qualification, deployed service, physical-device evidence and store submission are separate states. No provider licensing gate or outreach before market validation.

## 01 · The consumer release.

Ready for people.
Ready for review.

Global iPhone launch.
Zero new recurring spend.
Hosted around the Mac Mini.

OUTCOME: PRODUCTION + REVIEW SUBMISSION

Build 14 submitted 6 Oct; Apple requested more information.
A physical recording and completed review response remain.

## 02 · Three states. One finished release.

Qualification proves a candidate. Production proves the consumer path. App Store status proves submission.

01

Sealed build 13 baseline

42 directed checks / three seeds. Build 14 password proof is separate; backend SQL and 5× pass.

02

Production consumer path

Live Clerk, old users preserved, jobs installed, effective policies and ordinary sign-in.

03

Resolve Apple review

Owner submitted 6 Oct; rejected 7 Oct for additional information. Reply draft saved; recording missing.

Confirmed scope

iPhone only, English-first global reach, free initially, comments and replies off. Keep the backend on the Mini and the landing on existing Vercel Hobby.

No licensing work before validation

The owner deferred permission outreach and commercial reviews. They are not a release workstream. Revisit with real traction or a monetization decision.

## 03 · The core loop is already substantial.

The release is a dependable way to keep your place across anime and TV.

1

Choose

Anime, TV or both; country and services in first run.

2

Bring your library

AniList public list, MAL XML/gzip, TV Time CSV/ZIP.

3

Know what is next

Home, Schedule, franchise detail and an editorial feed.

4

Keep your place

Progress, status, batch actions, Undo and watch sessions.

5

Come back

Local reminders, recommendations and new-season context.

## 04 · Finish the promises people rely on.

Qualification and deployment are separate. Production login, current failure tests and the store packet remain explicit.

PRIORITY

CAPABILITY / REMAINING WORK

CURRENT STATE

P0

Production sign-in and preserving existing users

Four real identities preserved; Build 14 password cycle passed; owner reports both TestFlight SSO logins passed.

P0

Saved progress, account isolation and full deletion

Recorded Retry + server replay proved. First-dispatch persistence and monitor restart proved; live path pending.

P0

Consumer build, privacy and Apple review response

Build 14 rejected: physical recording and completed reply remain. All six answers drafted; unsent.

P1

Imports survive a backend restart

Preview/apply state remains in memory; durable checkpoints are not implemented.

P1

Edit country and services; useful long-absence reminders

Profile edit surface and APNs are future work; keep local-reminder limits clear.

P1

Accessibility, small iPhone and regional finish

Physical VoiceOver, iOS 18, large text and real cellular remain unverified.

P2

Trakt, exact rewatch imports, widgets and richer sharing

Use activation and repeat use to choose the next investment.

## 05 · “Saved” and “deleted” must be true.

Pre-dispatch persistence and recorded Retry are exercised.

Persist intent

Owner + payload + stamp

Send / retry

Order each writer’s intent

Commit + receipt

Canonical state; replay once

Retire safely

Clear only after acceptance

Persisted payload survives the first dispatch boundary.

Journal first

Durable request before TX

Erase app rows

Transaction + hash marker

Clean identity

Retry actual Clerk DELETE

Reconcile status

Pending / complete; no upsert

The uncertain response stays uncertain.

Cold launch preserves a deletion hold. The status route reconciles the independent journal before reporting a result; reconciliation failures stay 5xx. Accepted erasure clears owner-scoped caches, retries and exports. Completed markers prevent account resurrection after restore.

## 06 · Prepare one verifiable release packet.

The requested finish is the exact final build submitted for review, plus a service ready for its first consumers.

Access

Production identity

Matching live keys + expected issuer. Old test JWT key removed or replaced. No silent beta data reset.

Reviewer path

Two fresh build 14 password logins passed without OTP. Saved access passed draft validation on 6 Oct.

Account lifecycle

In-app deletion and returning login. Exercise actual Clerk cleanup and Apple revocation where enabled.

Binary & privacy

Binary receipts

Store build 14: processed/selected. Live Clerk key, iPhone-only, SDK27 / iOS18 minimum.

Data inventory

Four actual archive manifests verified. Device ID is linked, functionality-only/no tracking; 6 ASC categories published.

Login choices

Google/Apple connections enabled; simulator entry checkpoints passed. Owner reports both iPhone/TestFlight logins work. Phone OS/build and sessions were not independently captured.

Storefront

Saved metadata

Canonical URLs saved. Free pricing/global intent; Mac/Vision Pro off. Age 18+; 4 screenshots + header saved.

Public information

Support works. Policy effective 6 October 2026; routine retention disclosures match installed jobs. Consumer erasure/Files proof remain separate.

Current review

Build 14 submitted 6 Oct; rejected 7 Oct under 2.1, Information Needed. Reply draft saved; physical recording and completed response remain.

## 07 · Global intent. Region-aware proof.

Maximise reach through a useful product, clear listing and fast onboarding; do not invent organic demand.

AREA

WHAT MUST WORK

PROOF TO KEEP

Enabled regions

Login, images, catalogue, support URLs and public API

Actual regional checks and physical cellular; the Mac’s network alone is insufficient.

European Union

Truthful trader declaration and applicable verification

Owner non-trader status saved and read back; regional eligibility stays separate.

China mainland

Check filing fields and applicable local requirements

Owner’s actual ASC eligibility; enable only regions that can be truthfully configured.

Time and catalogue

Locale/timezone/DST; date-only TV remains date-only

IN, US, UK and UTC+14 cases; unavailable streaming data stays explicit.

Age and privacy

Saved 18+; Brazil 18+, Korea 19+; legacy OS<26 17+

Numeric UGC and possible YouTube ads declared. No age override.

Accessible iPhones

iOS 18 support, small/older phone and current OS

VoiceOver, largest text, Reduce Motion, poor network and low memory.

## 08 · Zero new recurring spend stays concrete.

Existing Apple membership, hardware, domain and subscriptions are already paid, as requested.

COMPONENT

IMPLEMENTED / CHOSEN

BOUNDARY

Backend + database

Existing Mini, Node 24, Fastify, PostgreSQL, launchd

No new hosting bill. One home site has no failover.

Landing

Existing Vercel Hobby project; static Next export

Promoted and publicly qualified. No Pro trial, new project or paid functions.

Authentication

Production Clerk Hobby; Apple relay SPF verified

Four identities preserved. Build 14 password cycle passed; owner reports both TestFlight SSO logins passed.

Errors + throughput

Private Mini metrics + sanitized capped local logs

No Sentry, Grafana or new monitoring vendor has been chosen.

Product usage

Private aggregate SQL and 30-day ops snapshots

Current app-open/library/progress counts; cohort event ledger is P1.

AI runtime

Production guards reject enabled chargeable features

Installed startup rejects paid grouping/query correction and enabled comments.

Recovery

Private 7-day dumps + isolated restore + current ledger

Same-disk backup is useful recovery, not protection against losing the Mini.

## 09 · Commercial review belongs later.

Owner decision: no licensing outreach, permission chase or provider gate before market validation.

Keep a factual reference

AniList’s terms contain a competing-tracker restriction separate from revenue. Record the fact for the later commercial review without scheduling outreach or changing the validation scope.

Small attribution polish

The native TMDB notice exists; an approved logo is still a P1 polish item. Keep relevant JustWatch credits. Do not assert written provider approval or commercial eligibility that has not been established.

Trailer privacy matches the player

The source now uses youtube-nocookie.com and a non-persistent WebView. Live player proof passed. Contextual ads may still appear. Controls, captions and unavailable-trailer fallback remain P1.

Revisit when traction is real

Use sustained useful weekly use and an actual monetization decision to trigger the later review. There is no imposed user-count threshold. Free initially does not mean future commercial terms are already solved.

## 10 · Previously has its own live address.

Policy effective 6 October 2026. Qualified static legal publication on the existing Vercel Hobby project.

5

Canonical legal layouts

8 fresh candidate layouts; 5 fresh canonical mobile layouts.

8

Routes per public origin

Canonical bytes match the verified candidate; existing aliases retained.

27

Asset hashes per origin

Original image/font bytes match the qualified source assets.

previously.cognipin.com

Eight routes verified. 152px native icon used on site/Clerk; coral period. Visible CSS Dynamic Island; original raster unchanged.

Scope of fresh and prior evidence

Fresh: 8 candidate / 5 canonical legal layouts; 4 navigation / 1 settled anchor. Prior: 19 Home / 3 hero / 4 gallery. Product-tour/image bytes unchanged.

Current public deployment

dpl_EAcNw6zcnWPrMxkg2Nea3AkeNBBM

## 11 · One small service. Clear boundaries.

Stay on the Mini. Promote one compiled artifact and keep private state outside the checkout.

iPhone

Owner-scoped cache
Journal before dispatch

Stable HTTPS ingress

Existing Cloudflare tunnel
Loopback API binding

Compiled API

Node 24 · dist/index.js
256 MiB old-space budget

PostgreSQL

Pool max 10
Versioned migrations

Bounded jobs

Cron overlap guard
Durable erasure retry

Providers

Cached reads
Bounded calls

Vercel landing

Static marketing + support
Independent of Mini uptime

Private operations

Metrics + usage + readiness
Backup + current journal

The migration seam already exists.

Environment configuration, PostgreSQL state, provider adapters and compiled JavaScript travel together. Keep mutable journals, backups and logs private. Durable import checkpoints remain P1; do not depict an implemented general job queue.

## 12 · See errors. See throughput. See freshness.

Private Mini endpoints and the free hourly collector are installed; fresh healthy status and graceful restart pass.

PRIVATE

Route pattern / code / request ID

PRIVATE

Server p50 / p95 / p99

PRIVATE

Requests / useful writes

PRIVATE

Backup / erasure / disk

API

Aggregate errors, latency, rate, in-flight work and runtime memory; diagnostics require a private token.

Jobs

Structured job names, overlap protection, bounded shutdown and durable identity-erasure retry.

Operations

Hourly snapshots: loopback metrics/usage, public readiness, backup freshness and disk.

Failure state

A failed collection writes unhealthy + timestamp; stale snapshots are not displayed as healthy.

Privacy

No raw searches, emails, tokens or account IDs in app logs. Static job names only; no session replay.

## 13 · Use practical limits. Act on failures.

These are initial operational targets, not a public uptime promise or measured month of production service.

SIGNAL

INITIAL TARGET / TRIGGER

ACTION

Availability

99.5% monthly planning target; no home-site failover

Use public /ready and inspect failed snapshots. Regional independent probes remain to be set up.

Core latency

Warm reads p95 ≤500 ms; writes p95 ≤800 ms at server

Compare to the fixed 5× scratch run. Cellular/global RTT is additional.

Errors

Core 5xx <1%; no incorrect writes or lost acknowledged intent

Inspect route/code/request ID. Expected auth/validation 4xx are not server failures.

Freshness

Successful hourly catalogue sync; investigate >2 h stale

Keep last-known content. Inspect bounded job outcome and upstream timeout.

Erasure + backup

Investigate pending cleanup >1 h; backup >26 h old

Retry identity cleanup and repair backup job. Do not promise a cleanup deadline not yet proven live.

Host pressure

Disk <20 GB; memory/pool wait or event-loop lag sustained

Stop nonessential work first. Share the 16 GB Mini deliberately; inspect actual process state.

## 14 · The database backup really restores.

Actual migrated database: isolated restore completed without replacing or restarting the live service.

1. Private dump

Custom pg_dump
Manifest + SHA + TOC

2. Owned scratch

Unique temporary DB
Never restore over live

3. Sweep erasure

Reapply current journal
Verify owned relationships

4. Inspect + clean

Counts / invariants
Drop scratch database

16

Users in post-cutover restore

Four production mappings and exact 20 owned tables match; live database untouched.

7 days

Installed backup policy

At most 7 daily dump/manifest pairs. First daily job exited 0; actual dump hash and size match.

Deletion markers must outlive the restored copy.

Apply the current erasure journal before reopening. A new production-identity backup passed two isolated restore checks; ordinary restore does not translate older development identifiers.

## 15 · Expect a small launch. Qualify the surge.

Scenarios: 100 / 500 / 2,000 registered and 20 / 100 / 400 DAU. These are planning envelopes, not demand forecasts.

15

req/s

Expected peak · planning assumption

75

req/s

15 minutes · core routes + 5% writes

150

req/s

1 minute · then 5 minutes recovery

82,800 requests

Errors 0 · dropped 0 · wrong writes 0 · heap delta 30.2 MiB

40 requests per DAU/day → 4,000/day at the working scenario. Global network latency, real providers and live identity are separate consumer checks.

## 16 · Measure the useful loop.

Current private aggregates exist. Retention cohorts and acquisition attribution still need a small event ledger.

Install

ASC download

Start

App open

Activate

Library + sync

Use

Progress saved

Return

Useful next-week action

MEASURE

DEFINITION / CURRENT STATUS

HOW TO USE IT

Current aggregates

App profiles, confirmed app-open stamps, library and positive progress counts

registered counts all DB profiles, including legacy/test/review. No consumer cohort or billing-MAU claim.

Activation · P1

≥3 distinct library titles + one confirmed sync within 24 h

Manual or imported setup counts. Requires event time and defined eligible cohort.

Useful weekly use · P1

Account with confirmed progress save or library change in the week

Use successful server commits; report client-only click counts separately.

Week-1 return · P1

Activated cohort with useful action on days 7–13 / eligible cohort

Show numerator + denominator. Small samples do not establish market validation.

## 17 · A small event ledger is enough.

No paid analytics dependency. Do not present the proposed cohort system as implemented.

Capture useful decisions

first_open, onboarding_complete, import_preview/apply/failure, follow_saved, progress_saved and sync_failed. Avoid noisy taps and impression streams.

Trust successful commits

Record confirmed library/progress/import results after commit. Deduplicate events. Exclude dev, owner, reviewer and erasure QA identities from customer cohorts.

Keep payloads narrow

Event/version, timestamp, build and coarse source only. Account link only when necessary and erased with the account. No email, raw search, title history or advertising ID.

144,000

proposed events / month at 400 DAU

400 × 12 events/day × 30 days

512 bytes/event → about 74 MB payload/month before indexes. Measure actual storage before setting a larger budget.

Current operational snapshots: aggregate counts retained 30 days. This is not a raw product event table or a cohort report.

No session replay. Privacy disclosures must describe the actual implementation and choices.

## 18 · Reach comes from a sharper promise.

Anime and TV, one dependable place to keep your place. Optimize the first successful session before buying reach.

01

Earn the install

Use real screenshots: what aired, where you stopped and one franchise across seasons.

02

Lower switch cost

Show supported AniList, MAL and TV Time imports, preview workflow and honest limits.

03

Earn the next week

Fast first library, trustworthy progress and useful release context. System rating prompt only after a successful moment.

First 30 days

Recruit 20–30 people across anime, TV and mixed use. Publish a concise demo, import guide and build notes in your own channels and communities that permit promotion. No paid ads or purchased reviews.

Expand from observed value

Check install→activation first, then eligible week-1 return. Localize store copy where impressions and conversion justify it. Start with counts and interviews; A/B tests need adequate traffic.

## 19 · Make the first ten minutes obvious.

Landing, onboarding and support should tell one accurate story.

WHEN

WHAT THE PERSON DOES

WHAT WE MUST EXPLAIN

First launch

Sign in → choose Anime/TV/Both → country/services

Why an account helps; optional setup can be skipped safely.

Bring history

AniList public list; MAL XML/gzip; TV Time CSV/ZIP

Preview before Add. TV Time progress is approximate; no exact original rewatch dates.

Add a show

Search → detail → Planned / Start / part-way / caught up

Status differs from progress. A future episode is not an aired one.

Daily use

Home for next action; Schedule for dates; Library for status

Same show detail from each entry point; Undo stays available.

Come back

Feed, recommendations and relevant local reminders

Local notification window is finite; refresh after a long absence. TV dates are date-only.

A failure

Keep cached library → inspect sync status → Retry/discard

Pending is not synced. Separate offline from service unavailable.

Leave

Profile → export / sign out / delete

Imported source account is separate. App erasure and identity cleanup have truthful states.

## 20 · Show the real consumer journey.

Owner submitted build 14 on 6 Oct. Apple rejected it on 7 Oct under 2.1, citing limited review history and requesting six information items.

1

Record the physical iPhone flow

Required / missing

Latest OS, submitted 1.0 (14): launch, ordinary use, login, deletion and registration. Use the guarded disposable-account sequence; no actual recording or deletion is verified.

Start here: one show + episode 1 → “QA ready” → baseline check → owner deletion → post-check → fresh registration.

2

Complete the six factual answers

6 answers drafted

Recording; purpose/audience; feature access and samples; external services; regional behavior; relevant authorization if applicable. No separate provider rights document has been supplied.

Reply: 3,584 / 4,000 characters. Prepared Notes: 3,584 / 4,000 UTF-8 bytes. Both include the final newline; 416 remain in each limit.

3

Attach evidence and update Notes

Draft saved / unsent

Replace the recording and sample placeholders. The 594-byte synthetic XML ZIP is validated but unuploaded. Existing 1,996-character Review Notes remain unchanged.

Keep reviewer credentials private. Clips must demonstrate actual outcomes; simulator and owner SSO reports do not replace the video.

4

Reply and retain the review result

Not sent

Send the completed packet only after recording review, and retain Apple’s reply/status. Resubmission is unverified; the current resubmit control is disabled. No replacement build is requested.

Apple identifies no specific crash or login defect. Code/build changes require an actual defect or a new request, not the rejection label.

## 21 · Protect identity and saved progress.

Stable workstream IDs retain the connection to the original plan, with current evidence and remaining consumer proof.

W1 · Production identity

SSO PASS / owner report

Four identities preserved; Clerk/DNS and enabled connections/FAPI verified. Owner reports both iPhone/TestFlight logins passed; phone OS/build/session were not independently captured.

Proof: actual cutover + post-realm restore; Build 14 password cycle passed; owner reports both TestFlight SSO logins passed.

W2 · Account lifecycle

Backend proved; live pending

Fresh owner-bound Apple exchange/revoke and conservative outcomes are implemented. App erasure precedes exchange; unavailable proof/provider keeps erasure available with manual fallback.

Proof: 1,328 units include 21 Apple cryptographic cases; 6 current SQL recovery cases. Real Apple/Clerk and native lifecycle remain pending.

W3 · Saved progress

Boundary proved

Stamped replay and canonical receipts exist. Native now journals owner/payload/stamp before dispatch and recreates the monitor; named tests pass. Rewatch guards newer intent.

Proof: use current native first-dispatch/monitor flags and named tests; prior 31 SQL and cold Retry counts remain scoped to their artifacts.

W4 · Privacy + store

Rejected / reply draft

Website policy effective 6 October. Four archive manifests verified; 6 ASC categories published. Five Store assets remain saved.

Build 14 submitted 6 Oct, rejected 7 Oct. Saved 3,584-character draft is unsent; recording/attachments/Notes remain.

## 22 · Keep operations small and useful.

Free operation and maintainability are implemented without adding monitoring vendors or unrealistic scale.

W5 · Content policy + polish

Backend proved / P1

Explicit adult=true/Hentai filtering and import skips are implemented; 27 current real-PG policy cases pass. Ecchi/mature ratings remain; saved App Store rating is 18+.

Live privacy-enhanced trailer controls and rotation pass. VoiceOver, captions and TMDB logo polish remain P1; no licensing outreach.

W6 · Hard $0 operation

Production guards active

Installed production startup rejects chargeable grouping/query correction and enabled comments. Immutable process uses prepared live config. Clerk/Vercel stay on existing free plans.

Proof: exact artifact/plist hashes, startup/readiness and guarded paths. No trial, paid feature or automatic paid upgrade enabled.

W7 · Recoverable service

Jobs / restart verified

Immutable Node24 artifact 123751 is installed; audit 0 and smoke pass. Daily/hourly jobs and post-identity backup are verified. Old mutable dev plist is unsafe rollback.

Proof: 26 checks; two isolated post-realm restores, exact four mappings/20 tables; SIGTERM exit0/readiness200. Historical logs retired; same-disk only.

W8 · Consumer qualification

Recording / erasure pending

Build 14 password cycle passed; owner reports both TestFlight SSO logins passed. Files sheet shown; selection/import/export proof pending. Earlier QA attempt closed; consumer deletion remains unverified.

Apple now requires a physical latest-OS recording of launch/use/registration/login/deletion. iOS 18, VoiceOver and WAN checks remain recommended and unverified.

## 23 · Test the mess, then replay it.

Seeded actions discover paths. Directed assertions and real data checks decide whether the app kept its promises.

01

Choose valid actions

Seeded taps, swipes, back, sheets, search, progress, Undo and dismissals.

02

Check the result

Check responsive controls, canonical progress, pending sync and account ownership.

03

Keep the evidence

Record build/fixture/seed, actions, faults and the first failing state.

3 / 3 completed passing seeds

Sealed build 13 run

Three fixed seeds × 300 seconds on one iPhone 14 Pro simulator. These receipts do not qualify the changed build 14 auth code.

What it does not prove

The QA app uses synthetic identities and a controlled backend. Physical production TestFlight, real Files, VoiceOver, old OS and real provider timing remain separate.

## 24 · Break the flow. Verify the data.

Adverse interleavings are exercised through production source and actual migrated scratch PostgreSQL.

JOURNEY

FAULT / EDGE

PROVEN IN THIS SCOPE

Progress + Undo

Lost receipt, duplicate retry, older uncommitted intent, compound rollback

One logical commit; new reset/Undo wins; canonical values and receipt/cursor rollback.

Account boundary

Owner A→B with delayed failure/response; cold launch; stale writer

Native owner isolation and independent SQL ownership; no old retry under new token.

Delete + restart

Provider pending, lost response, failed TX with precommit journal

App rows erased on reconciliation; durable pending or complete marker; no resurrection.

Status uncertainty

GET status during failed rollback reconciliation, then retry

5xx stays unknown; GET alone recovers and erases before pending; later write denied.

Operation recovery

Scratch restore with completed hash marker; injected provider 404

Restored deleted identity swept; completion cannot downgrade. No real Clerk network used.

Remaining consumer paths

Live erasure, Files, accessibility and older iOS

Password cycle passed on 14; owner SSO report separate. Files sheet shown; full import/export and consumer erasure remain.

## 25 · Proof, with its boundaries.

Native counts belong to sealed build 13. Build 14 password-cycle proof, fixture, SQL and operations receipts stay separate.

39 / 39

Build 13 product checks

21 UI journeys + 18 actual model regressions.

24 / 24

Fixture checks

Controlled faults, reset races and protocol/account isolation.

31 / 31

Real SQL progress

Ordered writes, stale replay, Undo, ownership and canonical data.

6 / 6

SQL Apple recovery

Current independent journal and Apple outcome restore/replay cases.

SUPPORTING CHECK

CURRENT RECEIPT

BOUNDARY

Build 13 selected suite

42 / 42 · 3 harness checks

Sealed baseline: product total above; harness checks are not customer journeys.

Runner + fixed seeds

12 / 12 guards · 3 / 3 seeds

Count only completed passing seeds; 300 s budget each.

Server units

1,328 / 1,328 · 81 files

Current non-load backend proof; includes 21 Apple cryptographic service cases.

Operational scripts

26 / 26 · Node24 compiled entry

Current dump/restore and pre0015 restore cases; no job installation claim.

## 26 · Portability is a boundary, not a rewrite.

Promote a reproducible compiled artifact now. Move hosting only when measured needs justify a new budget.

Current runtime is reproducible

Node 24.21.0, compiled dist/index.js, npm ci --omit=dev and immutable working directory. Actual compiled JavaScript is fingerprinted. Private environment and mutable ops state live outside the artifact.

Quality remains cheap

Strict types, meaningful unit tests, actual PostgreSQL transaction/replay checks and native account/storage regressions run on the owned Mini. Keep source and final load artifact frozen during qualification.

Migrate on a measured trigger

Repeated power/ISP incidents, inadequate recovery, sustained CPU/pool saturation after tuning, or network latency hurting activation. User count alone is not a migration threshold. Import persistence remains P1.

Future AWS / GCP / Azure

The same compiled service, PostgreSQL, provider adapters and worker boundaries can move. Rehearse restore, cut over one hostname, validate writes and preserve rollback. Cloud egress/DB/backup costs require a fresh decision.

## 27 · Know the artifact. Know the limit.

5 Oct source, 6 Oct qualification and 7 Oct review evidence remain separate; no green test is silently promoted to a live claim.

CLASS

LATEST EVIDENCE

LIMIT

5 Oct snapshot

19649b3; original 1,240-unit log, inventory and build12 archive

Historical baseline; old auth/config/audit findings were superseded in changed source.

6 Oct native

42 selected / 39 product; 3 / 3 seeds

Sealed build 13 passes; build 14 password cycle has separate proof.

6 Oct SQL

Current 31 progress, 6 Apple recovery, 27 content-policy cases

Actual migrated scratch PostgreSQL; synthetic provider transport; no live grant revocation.

Production database

Additive schema plus four real identities mapped to live Clerk

Four identities preserved. Restart/readiness pass; candidate14 production password path passes.

Actual recovery

Post-cutover dump restored 16 users; both scratch DBs removed

Four exact production mappings/20 tables match. June dump retired; historical logs retired; same-disk only.

Public landing

Effective 6 Oct; 5 canonical / 8 candidate legal layouts; 8 routes / 27 assets

4 navigation / 1 anchor; prior 19 Home / 3 hero / 4 gallery. Public copy/bytes do not qualify consumer workflows.

Current Apple review

Build 1.0 (14) owner-submitted 6 Oct; rejected 7 Oct, 2.1 Information Needed

Physical recording missing; 3,584-character reply draft saved, unsent. Notes/samples not updated.

## 28 · A reviewable path back to the work.

Repository-relative references; the companion evidence file links source and receipts without copying private user data.

E01

ios/project.yml; releaseConfig; clerk-cutover.md

Final Release keys, issuer, binary and migration

E02

server/src/auth/{clerk,authConfig,identity}.ts

Identity verification and expected issuer

E03

server/src/services/{erasure,deletionLedger}.ts; server/ops/ledger.mjs

Durable deletion + independent journal

E04

ios/.../Profile/AccountDeletion.swift; App/RootView.swift

Cold uncertainty hold and truthful notices

E05

ios/Sources/App/{AppModel,AccountLocalStore,RewatchStore}.swift

Owner scope and stale local-writer rejection

E06

ios/Sources/App/{MutationJournal,SyncCenter}.swift; clientMutations.ts

Pre-dispatch payload + replay; fresh qualification

E07

design/onboarding-2026-10-04/IMPORT-VERIFICATION.md

Historical supported imports and limitations

E08

docs/history-import-release-2026-10-04.md; franchise-cta/

Historical builds10/11 interaction proof

E09

landing/lib/legal-content.ts; landing/docs/vercel-release-2026-10-06.md

Effective disclosures / qualified publication

E10

ios/.../Trailer/TrailerPlayback.swift; server/qa/content-policy.ts

Trailer privacy + consumer content filtering

E11

server/src/{env,runtimePolicy,releaseConfig}.ts

Free-runtime production guards

E12

server/src/{server,index,observability}.ts; sync/cron.ts

Metrics, bounded cron and graceful lifecycle

E13

server/src/import/{previews,service}.ts

In-memory import state remains P1

E14

server/ops/; docs/qa/2026-10-06/operations/

26 checks, actual 0015 and backup/restore

E15

docs/qa/2026-10-06/{native-results.json,load-testing/}

Current native + final compiled capacity receipts

## 29 · Primary references. 1 / 2

References reviewed 5-6 Oct; Apple revocation and YouTube embed guidance reviewed 6 Oct. Recheck at submission.

S01

Apple App Review Guidelines

Completeness, account access, login, UGC and privacy.

[Apple App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)

S02

Apple upcoming requirements

Recheck upload SDK and age-rating requirements at submission.

[Apple upcoming requirements](https://developer.apple.com/news/upcoming-requirements/)

S03

Apple account deletion

Account deletion initiated in app; full lifecycle matters.

[Apple account deletion](https://developer.apple.com/support/offering-account-deletion-in-your-app/)

S04

Apple App Privacy details

Disclose actual identity, usage and diagnostics behavior.

[Apple App Privacy details](https://developer.apple.com/app-store/app-privacy-details/)

S05

Apple SDK requirements

Applicable privacy manifests and signatures.

[Apple SDK requirements](https://developer.apple.com/support/third-party-SDK-requirements/)

S06

Apple Developer Program

Existing membership is paid; no new recurring spend assumed.

[Apple Developer Program](https://developer.apple.com/programs/)

S07

Apple screenshot specifications

Use current iPhone screenshot slots and shipping behavior.

[Apple screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/)

S08

Apple EU trader requirements

Owner supplies truthful status and applicable verification.

[Apple EU trader requirements](https://developer.apple.com/help/app-store-connect/manage-compliance-information/manage-european-union-digital-services-act-trader-requirements/)

S09

Apple regional ratings / RCN

Broader Korea RCN criteria; actual availability remains unverified.

[Apple regional ratings / RCN](https://developer.apple.com/help/app-store-connect/reference/app-information/app-information/)

S10

Vercel Hobby

Existing free personal/non-commercial hosting; review before commercial change.

[Vercel Hobby](https://vercel.com/docs/plans/hobby)

S11

Clerk pricing

Verify actual production plan and quota; no trial or paid add-on.

[Clerk pricing](https://clerk.com/pricing)

S12

Next.js static exports

Official Next static HTML/CSS/JS export used for landing.

[Next.js static exports](https://nextjs.org/docs/app/guides/static-exports)

## 30 · Primary references. 2 / 2

References reviewed 5-6 Oct; Apple revocation and YouTube embed guidance reviewed 6 Oct. Recheck at submission.

S13

Next.js on Vercel

Framework output detection; avoid explicit out override.

[Next.js on Vercel](https://vercel.com/docs/frameworks/full-stack/nextjs)

S14

Apple XCUIAutomation

Local free native UI automation framework.

[Apple XCUIAutomation](https://developer.apple.com/documentation/xcuiautomation)

S15

AniList API terms

Record for later commercial review; no outreach in validation.

[AniList API terms](https://docs.anilist.co/guide/terms-of-use)

S16

TMDB API FAQ

Non-commercial API use and attribution reference.

[TMDB API FAQ](https://developer.themoviedb.org/docs/faq)

S17

YouTube privacy-enhanced embeds

Non-personalized embed behavior; ads may still appear.

[YouTube privacy-enhanced embeds](https://support.google.com/youtube/answer/171780)

S18

Apple sign-in deletion / TN3194

Revoke tokens; manual fallback when credentials are absent.

[Apple sign-in deletion / TN3194](https://developer.apple.com/documentation/technotes/tn3194-handling-account-deletions-and-revoking-tokens-for-sign-in-with-apple)

S19

Apple usage analytics

Opt-in usage data and active-device definitions.

[Apple usage analytics](https://developer.apple.com/help/app-store-connect-analytics/engagement/app-usage)

S20

Apple privacy and tracking

Actual tracking behavior determines ATT disclosures.

[Apple privacy and tracking](https://developer.apple.com/app-store/user-privacy-and-data-use/)

S21

Apple custom product pages

Audience-specific store pages and acquisition measurement.

[Apple custom product pages](https://developer.apple.com/app-store/custom-product-pages/)

S22

Apple product page optimization

Experiment only when counts support an inference.

[Apple product page optimization](https://developer.apple.com/help/app-store-connect/create-product-page-optimization-tests/overview-of-product-page-optimization/)

S23

Clerk migration overview

Development identities need a safe production migration.

[Clerk migration overview](https://clerk.com/docs/guides/development/migrating/overview)

S24

Clerk production environments

Live production configuration differs from development.

[Clerk production environments](https://clerk.com/docs/guides/development/managing-environments)

## 31 · Build trust. Reach people.

Protect their progress.
Make the first session easy.
Resolve the App Store review.

Production consumer proof pending

Build 14: Rejected 2.1; saved reply remains unsent

Four users preserved, installed operations and frozen 5× capacity pass. Build 14 password proof and owner-reported SSO remain scoped. Apple now needs the physical latest-OS recording and six answers; live erasure and Files proof remain.

## 32 · One brand. Four first impressions.

Four corrected screenshots and header are saved in App Store Connect. Marketing representations remain separate from actual production proof.

Home / resume

Library / progress

Schedule / next

Discover / catalogue

Canonical native icon · approved creative assets are fingerprinted with this render.
