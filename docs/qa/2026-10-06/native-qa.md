# Native QA — 6 October 2026

The frozen candidate passed **42/42 directed cases and all three 300-second seeded UI runs**, with **zero failures or skips**. The three seeds completed **821 driver actions** and **409 driver assertions**; 216 unavailable decisions count as no successful coverage. The owned fixture stopped at **13:28:27 UTC**. [Machine-readable results](native-results.json), [sealed runner ledger](../../../ios/Tools/qa/.runs/20261006T130049100512Z/ledger.json).

## Exact build and environment

| Item | Recorded value |
| --- | --- |
| Source base | `19649b3748eac6ca7508f86ad96be9f533406fcb`, with uncommitted release repairs and QA additions |
| Frozen source fingerprint | `6d235db238214339fa87caa8f392b639adf40873e5a96d3e4dc3e6c39c6c151c`; 200 native/test/project/fixture/privacy files |
| Scheme / configuration | `PreviouslyQA` / `QA` |
| Application sandbox | `com.cognipin.previously.qa` |
| Device / executed OS | Previously QA iPhone 14 Pro simulator / **iOS 27.0** |
| Simulator ID | `F3AD17A6-813D-4C7E-8263-6383F952302C` |
| Minimum deployment | iOS 18.0 compiled; **no iOS 18 runtime proof** |
| Orchestrator | XcodeBuildMCP `2.7.0`; serial tests |
| Owned transport | IPv4 loopback fixture, two synthetic accounts, ephemeral control token |
| Evidence | [20261006T130049100512Z](../../../ios/Tools/qa/.runs/20261006T130049100512Z) |

All four phases retained the same fingerprint. The QA sandbox excludes production data and credentials; default catalogue payloads contain no remote media. Normal Debug/Release identifiers remain separate. The app's Device ID privacy declaration was added **after** runtime qualification with explicit approval: only `ios/Resources/PrivacyInfo.xcprivacy` changed, from SHA `6aa8171a1685b7de8dbec2c78f83601e58f7cf30d68315db934e243bbbb4a89a` to `1dbd4ccfcf2f16699db8750f0a41bcea77ff60d06c1ba082dd175fdf7e4211a0`. The runtime-code hash excluding that manifest remained `4fc959e277db2e3d317505bcf628491e6fc3995b5aaa0929440c40f149b1b984`. The declaration linted; actual Release artifact checks are recorded separately.

## Directed receipts

| Suite | Passed / selected | Meaning |
| --- | --- | --- |
| AccountLocalStoreTests | 4 / 4 | Real cache/export helpers, stale owners, teardown, legacy discard and minimal mutation-clock persistence |
| AccountDeletionRequestTests | 3 / 3 | Real one-attempt request decoder, ephemeral Apple proof body and defined/unknown receipts |
| ImportModelTests | 2 / 2 | Old payload compatibility, distinct adult-policy omissions, persistence and interrupted-job conversion |
| MutationJournalTests | 6 / 6 | Real atomic journal files, cold restoration, original/latest stamps, receipt safety, disk failure and corruption |
| RewatchStoreTests | 3 / 3 | Persisted canonical-read requirement, superseded receipts, newer local intent and owner isolation |
| PreviouslyAccountIsolationTests | 2 / 2 | Delayed/failed A requests cannot use B's token, Retry or cache; restarted monitor delivers a real callback |
| PreviouslyDeletionTests | 7 / 7 | Four ambiguous committed responses through cold recovery, pending cleanup, defined refusal and saved manual Apple notice |
| PreviouslyDirectedTests | 9 / 9 | Progress/Undo, rapid marks, delayed search, lost receipt, latest/obsolete Retry, cold mutation identity and account switching |
| PreviouslyDurabilityTests | 3 / 3 | Actual process kill before catch, after commit before receipt, and with a newer queued intent |
| QAHarnessTests | 3 / 3 | Deterministic seed, bounded budget and explicit safe-host checks; harness coverage |
| **Selected total** | **42 / 42** | **0 failed, 0 skipped** |

The product count is **39**: **21 native UI journeys and 18 tests compiling actual production model/request/storage source**. Three harness checks are separate. Named XCTest receipts, the structured tool result, command exit and source audit agree. An absent or skipped selected case fails qualification.

The three durability cases synchronized process termination with the independent server oracle, while the failure count was still zero. Cold launch restored the owned journal, the actual Retry control retained the original operation/writer/sequence, and UI/canonical progress converged to 4 or the defended newer value 5. The lost-receipt case produced one logical progress effect. The account-switch case required a newer NWPathMonitor generation and actual callback after sign-out/sign-in. These are now verified paths, rather than inferred from a random run.

The saved failure case `testFailedProgressReplayRetainsMutationIdentityAcrossRelaunch` rejected three precommit PUT attempts, relaunched, tapped the real restored Retry and verified **UI 4 / canonical 4**, one effect and the same stamp. Its runtime summary recorded 12 actions and six driver assertions. The final cumulative metadata audit passed **61 protected attempts / 44 unique operations** across all phases; phase totals are cumulative and are not summed. Durable server ordering/body conflict handling has separate real PostgreSQL evidence.

## Seeded UI execution

A 300-second random decision budget is followed by actual relaunch/oracle checks; deterministic warmup and final checks are outside that budget. Selection uses known hittable controls: 40% navigation, 30% progress/Undo, 20% search, 10% profile. Every unavailable decision is reported separately. Search records requested/observed strings, requires empty after explicit clearing, and verifies each 16-character prefix. Core random actions use identifiers and named scrollers, with no random coordinates.

| Seed | Random budget | Actual elapsed | Completed actions | Unavailable decisions | Driver assertions | Visited states | Receipt |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 20261006 | 300 s | 331.10 s | 249 | 66 | 149 | 6 | Passed |
| 60102620 | 300 s | 331.25 s | 277 | 57 | 135 | 6 | Passed |
| 38654705664 | 300 s | 339.62 s | 295 | 93 | 125 | 6 | Passed |

Each seed visited the recorded states `anime-detail`, `discover`, `feed`, `home`, `library` and `schedule`. Counts include deterministic setup/final checks and can include multiple taps per random decision. Every `.xcresult` contains the ordered action/fault trace, OS, screenshot and accessibility hierarchy. Final checks compare visible progress with the independent HTTP oracle, preserve unselected TV progress and membership, verify the account is not erased, and compare again after process restart. A seed fixes selection; asynchronous reproduction still needs its trace/fault schedule.

## Separate live trailer proof

[Focused live result](../../../ios/Tools/qa/.runs/20261006T125503628555Z/ledger.json): **1/1 passed**, separate from the core count and dependency-free fixture. The actual iframe reported `www.youtube-nocookie.com`, the WKWebView data store was nonpersistent, and provider callbacks/getters acknowledged advancing play, stable pause, mute/unmute and forward seek. Automatic rotation retained the same paused player/clock on return. An explicit inline Full screen tap used a saved screenshot, observed card frame and derived physical control point; it resumed playback and retained the same advancing clock through native exit. This narrowly observed physical-control test is **not full VoiceOver qualification**. Original detail/feed card anatomy and named accessibility actions were preserved. No provider-command/JS playback bypass was used.

The focused trailer source receipt predates the narrow import-model/UI explanation addition; its exact separate fingerprint remains in JSON. The app-store screenshot pipeline must use the production candidate, never these synthetic fixture captures. [Shipping SDK privacy source audit](sdk-privacy-audit.json) records Clerk 1.5.8 IDFV authentication headers and the production-key telemetry guard, without actual identifier/header/credential values.

## Supporting checks and preserved failures

The fixture protocol checks passed **24/24**, and the runner qualification/cleanup/redaction guards passed **12/12**, both with zero skips. These fast checks start no production service and are distinct from native application execution.

Prior evidence is retained without relabelling it as passing:

- [104135171925Z](../../../ios/Tools/qa/.runs/20261006T104135171925Z): 21/22 passed. A test incorrectly expected automatic cold replay; the restored failure row intentionally requires the visible Retry action. The corrected test exercises that actual action.
- [105305254296Z](../../../ios/Tools/qa/.runs/20261006T105305254296Z): interrupted before monkey phases for a confirmed deletion acknowledgement repair. Network 401/403 and an undefined empty 204 now retain uncertainty; only the defined JSON contract resolves it.
- [105836214740Z](../../../ios/Tools/qa/.runs/20261006T105836214740Z): 26/27 passed. The server saved progress 4 after restored Retry while the UI still showed 3. The repair applies the defended latest persisted intent locally before the existing serialized send, preserving its original stamp and account guards. The fresh directed run above now verifies both UI and canonical state.

No Undo receipt or haptic was added by that cold Retry repair. Other fixes qualified in this working tree include account-scoped persistence and export cleanup, late token/session isolation, canonical watch-history reconciliation after a superseded receipt, and disabling shared HTTP cache/cookie/credential storage for the bearer API session.

- [110834245008Z](../../../ios/Tools/qa/.runs/20261006T110834245008Z): 27/27 directed passed, then seed 20261006 failed after 86.37 seconds with 56 completed actions, 12 unavailable decisions and 19 driver assertions. Every prefix of the first 120-character query passed. The next bulk Delete operation left six old characters, so the next 16-character prefix truthfully failed with 22 characters observed. The harness now uses the actual Clear text button or explicit Select All/Delete and asserts empty before typing. [Focused regression](../../../ios/Tools/qa/.runs/input-check-20261006T112038283224Z): 1/1 passed, zero skips; 120 characters entered twice and explicitly cleared for the next query. No product input code changed.

## Independent deletion storage evidence

The production deletion route/auth/storage suite passed **7/7** using Node `v24.21.0` and a freshly migrated owned PostgreSQL database. [Results](deletion-faults/qualified-node24-current/results.json), [cleanup ledger](deletion-faults/qualified-node24-current/run-ledger.json), [log](deletion-faults/qualified-node24-current/run.log).

That database was drained and removed. The run disabled dotenv, external provider credentials and the independent filesystem ledger. It verified pending/complete route contracts, repeated deletion, lost upstream receipts, persistent SQL tombstones after in-memory reset/server reconstruction, an advisory-lock upsert race, rollback before acceptance and account B preservation. It does **not** claim real provider cleanup, independent filesystem recovery or a separate process restart. Those boundaries are handled by other evidence.

## Limits

This run uses one simulator and a synthetic issuer. It does not establish production Clerk authentication, physical TestFlight behavior, iOS 18 compatibility, actual Files imports, arbitrary OS/provider dialogs, VoiceOver or largest-text behavior. No universal coverage percentage follows from three short random runs. The actual Release archive and any physical-device check need their own recorded receipts.

## Production archive and upload

Official Xcode 27.0 created iPhoneOS arm64 archive 1.0 (13), then confirmed “App upload complete: Previously 1.0 (13) uploaded.” Organizer retains “Uploaded to Apple”, Uploaded Today 7:09 PM (Asia/Kolkata), Build Number 13. [The recorded upload receipt](archive13/upload-receipt.json) preserves these observed texts; separate App Store processing and production sign-in verification remain pending. No review submission was performed.

The archived app is `com.cognipin.previously`, iPhone-only `UIDeviceFamily=[1]`, minimum 18.0, with the prepared live Clerk public key, `https://anime.cognipin.com` API and canonical legal URLs. App and widget are build 13; signature verification passed, and native Apple sign-in entitlement is present only on the app. Known QA fixture markers are absent from the shipping executable. The archive initially has development signing; Organizer performed the App Store distribution/upload path successfully.

All four actual bundled privacy manifests were inspected; the app manifest matches approved shipping SHA256 `1dbd4ccfcf2f16699db8750f0a41bcea77ff60d06c1ba082dd175fdf7e4211a0`. [The SDK audit](sdk-privacy-audit.json) includes the exact inventory and pinned SDK source evidence. Organizer exposes Generate Privacy Report, but its Save panel disabled Export/New Folder across destinations; no exported PDF or local IPA is claimed. These optional UI exports do not alter the verified archive or successful upload.

The canonical existing native icon is proved directly from the archive: [152px render](archive13/native-icon-152.png), split-flap P with red dot. Asset-catalog metadata verifies 1024px Any/Dark/Tintable shipping renditions; no full 1024px PNG export is claimed. No icon redesign occurred.

Native compiler/UI work stopped before the final backend capacity window; [quiet receipt](archive13/cpu-quiet-receipt.json) records 13:44:13 UTC, stopped fixture and no active Xcode/compiler/Simulator UI workers. Dormant CoreSimulator services remained at 0% CPU.

Remaining consumer proof is explicit: real production Clerk Google/Apple sign-in and linked-Apple deletion/revocation; rendered partial/all-adult import omissions; actual Files import/export pickers; VoiceOver and physical-device behavior; actual iOS 18 runtime. Fixture journeys, model decoding tests, and the successful archive/upload do not establish these. Production screenshots must use actual normal API/auth state, not the synthetic QA library.
