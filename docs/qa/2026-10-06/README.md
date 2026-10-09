# Previously QA — 6 October 2026

Implemented free local native QA and independent real-PostgreSQL fault checks. Source base: `19649b3748eac6ca7508f86ad96be9f533406fcb` (`19649b3`), plus the current uncommitted QA and progress-retry repairs. Results apply to that working tree, not an uploaded TestFlight candidate.

## What was added

- A separate `PreviouslyQA` app/sandbox (`com.cognipin.previously.qa`), native XCTest target, bounded seeded UI actions, directed failure cases, and stable accessibility selectors. Endpoint/reset controls compile only with `PREVIOUSLY_QA`.
- A dependency-free loopback fixture with two synthetic accounts, an independent canonical-state oracle and deterministic delay, precommit failure and lost-response controls. It loads no production data, credentials, provider APIs or remote artwork.
- A local runner that owns its fixture/processes, preserves traces/screenshots/hierarchies in `.xcresult`, redacts its control token, and requires passed receipts for every selected test. No paid device farm or subscription is required.
- A separate real HTTP/PostgreSQL runner exercising production routes/auth/services against a freshly migrated disposable database. Dotenv/provider credentials are disabled, workers never start, and cleanup is recorded.

See the [native harness](../../../ios/UITests/README.md), [fixture contract](../../../ios/Tools/qa/fixture-contract.md), [runner](../../../ios/Tools/qa/README.md) and [real PostgreSQL checks](../../../server/qa/README.md).

## Evidence so far

| Check | Recorded result | What it proves |
| --- | --- | --- |
| Fixture tests | 20/20 passed | Controlled protocol/oracle/fault behavior; not production backend equivalence |
| Runner tests | 12/12 passed | Qualification, cleanup, metadata audit and redaction regressions with native commands mocked |
| Native harness checks | 3/3 passed; initial QA build compiled | Seed determinism, bounds and unsafe-host rejection; not product journeys |
| Initial directed UI attempt | 0 passed / 4 failed / 0 skipped | Detail/search setup selectors were not found; core scenario assertions were not reached |
| Historical frozen native run | 27/27 passed, 0 failed / 0 skipped; first seed 263 actions | Stopped at a test boundary for confirmed journal/monitor defects; does not qualify repaired source |
| Initial real HTTP/PostgreSQL |11 passed /3 failed /0 skipped,14 total | Preserved stale replay reproduction before operation ordering |
| Ordered-intent HTTP/PostgreSQL |28/28 passed | Actual transactional replay/order/ownership/deletion boundaries; native wiring separate |
| Initial5× capacity profile |82,800/82,800 requests clean; memory budget failed | Shared-Mini local cached throughput before final protocol/compression qualification |
| Local Swift syntax check | Passed for `AppModel.swift` and `SyncCenter.swift` | Parse validity; full candidate build and native assertions remain separate |

The initial UI failures are preserved in [directed-smoke.json](../../../ios/Tools/qa/.runs/directed-smoke.json) and [directed-smoke.xcresult](../../../ios/Tools/qa/.runs/directed-smoke.xcresult). Initial harness evidence is [harness.xcresult](../../../ios/Tools/qa/.runs/harness.xcresult). Native run artifacts are local/ignored; they are not public links. [Current native report](native-qa.md) and [machine-readable receipts](native-results.json) distinguish verified directed checks from pending monkey runs.

| Final native evidence | Status / receipt |
| --- | --- |
| Build and simulator/OS | QA build compiled; Previously QA iPhone 14 Pro / iOS 27.0 |
| Directed cases, including cold Retry and pre-dispatch journal repairs | Pending fresh 36-case qualification; historical 27-case receipt preserved |
| Monkey seed, duration, actions, visited states and assertions | Pending final run |
| Result bundles and extracted action traces | [Historical run directory](../../../ios/Tools/qa/.runs/20261006T112209258256Z); directed and first seed complete, interrupted for confirmed new repairs |

Real SQL evidence: [results](progress-faults/results.json), [run log](progress-faults/run.log), [migration log](progress-faults/migrations.log), and [cleanup ledger](progress-faults/run-ledger.json). The owned scratch database was removed successfully; no production app database was read or written.

## Finding and local repair

Native source review found an old failed progress Retry could bypass the serialized write lane and survive a newer successful write. Updating a failure changed its encoded intent but retained its original closure. The repair refreshes the closure, retires only unchanged failures captured by successful writes, routes current/restored Retry through the normal lane, and defends the newest failed part intent across Mark/Undo rows. Progress failures remain persisted during Retry, duplicate Retry is suppressed, and teardown cancels/guards those tasks. A subsequent real cold Retry run exposed canonical progress 4 with UI progress 3; the narrow repair applies the defended persisted value locally before sending its original stamped intent. The fresh directed run passed all 27 checks, including UI and canonical progress 4 after that Retry. [Review and boundaries](progress-faults/native-replay-review.md), [exact native evidence](native-qa.md).

The SQL runner preserved three failures replaying older single-part, compound and whole-session writes. The backend now persists operation identity and per-writer resource ordering atomically with effects; the expanded qualified28/28 SQL cases preserve newer state, deliberate decreases, independent parts and membership deletion barriers. Fully unstamped legacy clients and independent-device arrival ordering remain explicit limits. [Protocol and exact sequences](progress-faults/README.md). The initial full5× load passed request/latency/correctness checks but failed its peak heap-growth criterion; final protocol/compression/resource-budget qualification is pending. [Load evidence and limits](load-testing/README.md).

## Coverage limits

The native fixture proves client behavior against controlled synthetic transport. The real SQL run independently proves selected production route/service/storage behavior using the test issuer. Neither establishes production Clerk authentication, provider behavior, deployed resilience or complete UI coverage.

Physical iPhone/TestFlight and iOS 18 checks have not run; the iOS 18 runtime is not installed. Imports through Files, durable offline intent across a long process interruption, real provider cleanup, full VoiceOver/largest-text behavior and external sign-in dialogs remain outside this UI evidence. Durable uncertain deletion through cold relaunch and canonical status recovery is covered by six directed client scenarios, including four ambiguous postcommit responses. A seed fixes action selection, while the exact action/fault trace is also required to reproduce asynchronous failures.

The broader plan remains in [monkey-qa.md](../../release/2026-10-05/monkey-qa.md) and the [release-plan companion](../../release/2026-10-05/release-plan.md). This report records implementation and proof boundaries without turning short runs into a release certification.
