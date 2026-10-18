# 15 October technical closeout - draft evidence appendix

This is a dated preparation snapshot, **not a completed release**. The owner handles Apple review closeout; root handles technical production and build 17 distribution. The table preserves the initial pre-16:50 handoff. The actual capacity/activation update below supersedes its pending rows; no result is inferred merely from a schedule.

| Work | Observed evidence | Scope and remaining proof |
| --- | --- | --- |
| Backend candidate | Immutable `20261015T152739Z/server`, Node 24.21.0, source SHA256 `1c93625ad9d87eb48a5fcc300781d0cb8235f7f1bea86ae35ec72b5a198eaeb4`; 1,340 units across 81 files, 39 real SQL progress/status/cron cases, six recovery, 27 content-policy and 26 operator checks; zero production advisories | Prepared and isolated-fixture qualified. No production activation claim. The source includes the progress-derived status rule and encoded-timestamp cron correction. |
| Production installation | 16:22 precheck still points all three Previously jobs to the 6 October artifact | Fresh capacity pass and guarded activation/backup/collector receipts are still required. Prepared activation transaction fixtures are not an actual rollback drill. |
| First 15 October 5x run | Failed: 294 client timeouts at the unchanged 5,000 ms threshold; 82,506/82,800 core completions and two canonical mismatches among 798 checked rows | Preserve the failure. Kestrel activity and swap growth correlate with slowdown; definitive sole causation is unproven. A later run must meet unchanged thresholds. |
| Second 15 October 5x run | Quiet preflight passed at 16:26; final receipt absent when inspected | Pending. Profile: two minutes at 15 RPS, fifteen at 75, one at 150, five at 15; 200 cold searches and two 50-show imports. Local deterministic fixtures do not prove live-provider or worldwide latency. |
| Add + Continue | All seven `PreviouslyAdmissionTests` cases passed in `.runs/20261015T161326526097Z` | Overall focused run **failed**: 17 passed, three Files failures. The seven cases prove their selection/retry/cancellation scope, not the entire release. |
| Widget privacy | Ten named storage cases and four actual QA app lifecycle cases passed on build 17/iOS 27 | Enclosing earlier run failed unrelated admission/Files cases. Injected QA storage does not establish real App Group or physical WidgetKit refresh. Do not double-count repeated storage cases across runs. |
| Files | The focused run failed three system Files journeys. Coordinator observed CSV offered under a JSON name and eight account-export requests against a three/hour production default | Separate export types and guarded coalescing are source corrections. Four new helper tests expand the intended directed suite to 75; no helper/full-runtime pass is claimed before execution. |
| Full native qualification | 75 current directed cases and three fixed 300-second seeds planned | Pending exact-source completion. Historical build 13's 42 checks/three seeds do not qualify changed source. |
| Distribution | Build 16 has an actual successful Organizer upload receipt dated 15 October; build 17 archive template remains `awaiting_actual_archive` | Build 16 upload does not qualify current source. Actual 17 archive, compiler/source/signature, upload and processing proof remain separate and pending. Minimum OS remains iOS 18; “17” names the app build. |
| Consumer lifecycle | Dedicated ordinary-account erasure is planned; no deletion has started in this handoff | Real production sign-in, account deletion and independent provider/SQL/journal readback remain unverified. A QA fixture or Release simulator is not a physical device or Apple grant proof. |
| Apple closeout | Last independently read portal result remains the dated 7 October information request | Current portal state is unverified here. Owner handles recording, factual packet, Notes/reply and review follow-up. No Apple actions or permissions are inferred. |

Private errors, request throughput/latency and timestamped operational snapshots remain the useful free observability surface. Raw profile totals include QA/reviewer identities and do not establish adoption or retention. Backups remain on the same Mac; hardware-loss recovery is not established. No paid monitoring, new recurring spend, licensing gate, cloud migration or repository push is introduced.

The final companion should replace each pending state only from its exact dated receipt, preserving failed/interrupted runs and the historical dossier. This draft has not been promoted to a production readiness assertion.

## Actual update after capacity

The unchanged final capacity run finished **16:50:07 UTC**: 82,800/82,800 core requests, 200 cold searches, two successful 50-show imports and 798 matched canonical rows. Errors, timeouts, drops, HTTP 5xx, incorrect responses and write mismatches were zero. Sustained p95/p99 were 62/91 ms; burst 104/129 ms. Sources/artifact remained frozen and owned scratch resources were removed. This qualifies the controlled local fixture workload, not live-provider quotas, worldwide latency or home uptime.

The first activation failed. All three prior plist byte sequences were restored, but automatic bootstrap/restart failed. Manual bootstrap of the exact old jobs restored local/public 200 readiness at **16:51:59 UTC**, an **85.96-second observed recovery window**; no production database restore occurred. Original CLI diagnostic detail was lost by generic wrapping. A later sanitized idle-backup bootstrap also succeeded, so environment alone is not a proven cause. Missing wait for captured PID/registration shutdown exposed the unload/drain race.

The repaired helper recorded **17 scoped fixture checks** and two Node snippet syntax checks. Its separate corrected supervised activation finished **16:56:12 UTC** with local/public readiness, a verified new 13,850,011-byte/0600/owned backup and healthy operational snapshot. Preserve initial failure, manual recovery and corrected activation as three distinct facts. Native 75/seeds, new Files runtime proof, archive/upload 17, actual erasure and owner Apple closeout remain separate pending states in the initial PDF draft.

## Focused Files update at 17:15 UTC

The separate focused run `.runs/20261015T171234663216Z` completed **3/3 real Files UI cases**, zero failures/skips, and stopped its owned fixture. Its frozen test assertions cover actual picker selection and partial apply with exact canonical state/protected account B, all-skipped omissions/no Apply/cancel, actual saved JSON/CSV contents with one account-export fetch, and equality of saved copies after sign-out/cold relaunch. The QA Files domain and synthetic account samples remain explicit; this is not physical-device or real-provider proof.

The full 75 directed plus three fixed seeds began afterward and remains pending. The final native and seven-case Files/helper summaries must come from that one completed all-run, with primary ledger hash, same source, named cases, raw coverage and fixture cleanup. Earlier four-helper and three-UI focus results cannot be combined into that final receipt. Archive/upload 17 and actual ordinary production erasure remain separate pending facts.

Only lightweight source/document preparation followed this focused update. The six-page temporary PDF remains its earlier inspected DRAFT snapshot; no new render or native/device action occurred during the active full run. Existing admission attachments do not contain a settled alert frame, so the 9 October native visual remains explicitly historical context.

## Failed full run and fresh-source update at 17:35 UTC

The first full run `.runs/20261015T171508872199Z` ended with **64/75 directed passes and 11 failures**, no skips and no monkey phase started. Its preserved [failure receipt](../native-release/failed-full-run-1715.json) is not replaced by focused successes. All seven admission, three Files, 14 widget and four export-helper cases passed only their selected scopes inside that failed full run.

A separate billboard finding showed that missing artwork delayed the fallback readiness callback while hidden arrival copy still exposed its controls to accessibility/hit testing. The narrowly changed `ShowBillboard.swift` subsequently passed two focused real account-isolation UI cases in `.runs/20261015T173147527864Z`. This supports those two regression paths; it neither proves all 11 failures share one cause nor measures presentation-layer animation completion. The full 75/three-seed run begun at 17:35 was pending at this snapshot; its later failed outcome is preserved below.

The 17:35:27 archive-input capture lists 596 files, manifest SHA256 `9e34e611541b137b1c90d692158b7ed747ed1578c03ff1a20539e26317db4cd3`, and native QA fingerprint `3ad6f80e294c418dca7a81abb969a4bc2eb3976fe514c304b8b781a38cb1c4c0`. That snapshot predates qualification and proves neither an actual archive nor an upload. Actual archive 17, upload 17 and ordinary production erasure remain pending. No PDF render occurred during this fresh native run.

## Current progress after the second failed full run

The second full run `.runs/20261015T173458816048Z` ended **74 passed / one failed / zero skipped**, with no monkey phase. The remaining Files export case asserted saved JSON/CSV contents and one account-export fetch before an immediate post-Save navigation lookup failed. A named export-screen Back wait in the harness then preceded a separate **3/3 focused Files UI pass**, completed **17:54:20 UTC** in `.runs/20261015T175132730759Z`. That focus does not relabel either full run passed.

The fresh **17:54:38 UTC** all-run has completed its **75/75 directed phase**, zero failures/skips. All three fixed requested 300-second monkey phases and final cleanup/strict summary remain separate requirements before native qualification. The current frozen QA source fingerprint is `649ce5a703b568c40e7bc7baa3fd0857c88e92bc3b0c8a60761aae5408d68fd6`. The old 17:35 source snapshot is preserved as `consumer-release/native-source-manifest-1735.json`. At this earlier checkpoint, no fresh pre-archive capture, actual archive or upload was claimed; the later archive evidence is recorded below.

The **18:08:27 UTC** provider preflight completed three GETs and zero mutations/app sessions. Production instance and ordinary password-factor availability were read, but disposable-account existence/password were not verified; there was no fresh database read, ready baseline or deletion start. It provides read-only access evidence, not erasure proof. Source/document updates only; no render, native operation or production mutation was performed here.

The later **18:13:17 UTC** exact QA readback verified the dedicated provider identity/password and read-only SQL: no app account, zero library/progress/episodes, no ready baseline. It made one provider GET, zero mutations and zero app requests/sessions; deletion has not started. Dedicated-account setup and actual ordinary production erasure remain pending. This narrows the earlier identity uncertainty without converting a readback into a deletion pass.

## Bounded production observations at 18:23 UTC

Local/public `/health` and `/ready` returned 200; all three loaded jobs matched the activated artifact. `/health/ready` is an unimplemented alias and returned 404, which is not a readiness result. The collector's healthy sample was measured at 17:56, 27 minutes before this readback. Existing backup metadata, size and 0600 mode matched; no new backup, checksum computation, restart or scheduled tick was triggered or proved.

Sanitized aggregate telemetry returned 200 with 104 requests/zero server errors since cutover: 101 responses in 2xx, three in 4xx. Counters reset on backend restart. Usage was 17 raw app profiles, last open in 24 hours for two profiles and in 7 days for three, library profiles 9 and progress profiles 7. Legacy/QA/reviewer profiles are included. This is operational volume and last-open state, not consumer adoption, MAU, retention or an uptime guarantee. Native all-run completion, archive 17 and ordinary erasure remain separate pending proof.

## Actual archive evidence after 18:47 UTC

The fresh 596-file pre-archive input snapshot was captured **18:41:57 UTC**, while the third native seed was still running, with manifest digest `5b60d21950be1f92c7ba6b909c5734f43a370402089279de5e06032b80fe57c2` and native QA fingerprint `649ce5a703b568c40e7bc7baa3fd0857c88e92bc3b0c8a60761aae5408d68fd6`. It is not a post-qualification snapshot. It can be linked to final native qualification only after the same full run/cleanup completes and its fingerprint still matches.

The actual 17 archive was created **18:44:40 UTC**; inspection at 18:47 records **56/56 artifact checks passed**, observed Release compiler/source continuity and the actual successful archive marker. The single-worker tool invocation completed exit 0 with `didError: false` and `SUCCEEDED`. Development archive signatures and App Group/privacy/configuration checks do not constitute App Store distribution signing, upload, native qualification or launch proof.

The Organizer clone compared 73 regular files without mismatch at the local 16 October archive path. The native 75 directed phase and first two seeds passed, while the third seed and strict final summary remain pending. A separate production-configured Release simulator build-only is in progress; no install, ordinary password cycle or deletion is claimed. Upload 17 has not occurred. No final PDF render or native action was performed by this document task.

## Separate Release simulator compile proof at 18:54 UTC

The actual Release simulator inspection passed **25/25 build/preparation checks**: separate platform 7 app/widget binaries, arm64 and x86_64, minimum iOS 18, production API/live key/canonical policy configuration, strict signatures, no file sharing, actual Release compiler commands without DEBUG/QA and all 596 captured inputs unchanged. The real tool invocation completed exit 0 and reported no error/SUCCEEDED.

No app install, launch, sandbox reset, production request/session, ordinary password cycle or deletion occurred. Compilation remains separate from runtime, minimum-iOS 18/physical testing, account lifecycle and the device archive executable. The companion source records compile success while ordinary production sign-in/erasure and full native qualification remain pending; no render or native action was performed here.

## Final native all-run outcome at 18:57 UTC

The all-run `.runs/20261015T175438622566Z` finished **failed at 18:57:39 UTC**, with owned fixture cleanup confirmed. All **75 directed cases** passed, including seven Files/export-helper cases; seeds `20261006` and `60102620` also passed. Seed `38654705664` exited 124 after exceeding the **1,800-second external runner budget**, following repeated XCTest idle waits during long search input. Its final oracle/relaunch/assertions did not complete or produce verified primary test results.

The third seed is not a pass. A product assertion defect is not established by this timeout, and the two earlier seed passes do not qualify a three-seed selection. No full native/Files success receipt is published. The companion records **NOT QUALIFIED** for full native release qualification while preserving the genuine directed/Files phase passes and the separate archive 56/compile 25 checks. Upload 17, ordinary production login and erasure remain pending. No render or native action was performed by this document task.
