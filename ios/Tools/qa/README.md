# Run isolated native QA

This directory contains a free local fixture and a runner for the `PreviouslyQA` scheme. The QA app uses `com.cognipin.previously.qa`, a separate application sandbox, and synthetic `fixture-a` / `fixture-b` identities. Normal Debug and Release builds exclude the endpoint/reset controls. Read [fixture-contract.md](fixture-contract.md) for the HTTP oracle and fault semantics, and [../../UITests/README.md](../../UITests/README.md) for native coverage and evidence limitations.

The runner owns its fixture process and an explicit IPv4 loopback port. It fails if that port is occupied, verifies the service using a fresh control token, and stops only process groups it created. SIGINT, SIGTERM, command failure and bounded test timeout run cleanup. It never reuses a running fixture, resets another app bundle, or changes production services.

```sh
python3 ios/Tools/qa/run-native-qa.py --simulator-id '<QA simulator UDID>' --suite smoke
python3 ios/Tools/qa/run-native-qa.py --simulator-id '<QA simulator UDID>' --suite directed
python3 ios/Tools/qa/run-native-qa.py --simulator-id '<QA simulator UDID>' --suite monkey --seed 20261006 --duration 300
python3 ios/Tools/qa/run-native-qa.py --simulator-id '<QA simulator UDID>' --suite all
```

Run from the repository root. `--port` defaults to `18787`; an alternate explicit unused port is permitted. `--duration` is bounded to 10–300 seconds and describes the random phase's budget, excluding setup and deterministic checks. `--max-actions` is bounded to 5–1000 decisions. Smoke selects the monkey suite with a 10-second random phase; `all` runs the directed suite and three default seeds. Supplying repeated `--seed` values selects an explicit seed list.

The directed selection includes all methods in `QAHarnessTests`, `AccountLocalStoreTests`, `AccountDeletionRequestTests`, `ImportModelTests`, `MutationJournalTests`, `RewatchStoreTests`, `PreviouslyDirectedTests`, `PreviouslyDeletionTests`, `PreviouslyAccountIsolationTests`, and `PreviouslyDurabilityTests`. This currently requires 42 individually named passes, including export staging cleanup, stale-owner rejection, persistent mutation identity across failed-write relaunch, canonical watch-history reconciliation after a superseded receipt and deletion holds across ambiguous gateway responses. Counts are discovered from those source files, so adding a test also expands the required qualification receipt.

The verified CLI dependency is pinned to `xcodebuildmcp@2.7.0`; `npx` can download that free package if not cached. Xcode, XcodeGen and Node must already be available. This script does not install simulators or pay for services.

Each run writes `.runs/<UTC timestamp>/ledger.json`, redacted structured tool JSON, a fixture request log and `.xcresult` bundles. `.runs` is ignored by Git and the run directory is private. A pass requires command success, a successful structured summary, zero failures/skips, and an individually named passed receipt for **every test method discovered from the explicitly selected suite source files**. Harness checks alone cannot qualify the directed UI suite. A missing/renamed test, malformed result or timeout is a failure; interrupted runs are marked interrupted.

The ledger records a SHA-256 fingerprint of the native/test/fixture source and the privacy manifest and fails qualification if those files change during the run. Compact `QA_SUMMARY` lines are read from the XcodeBuildMCP log into the ledger, recording actual completed/unavailable actions, assertions and states. A monkey pass also requires its matching seed's coverage log; raw log contents and unrelated fields are not copied into the report.

All authenticated progress, subscription and watch-session writes in the owned fixture log must contain valid mutation stamps. The runner rejects an operation whose writer/sequence changes between attempts and a writer sequence reused by another operation. This audit proves client metadata stability; body conflict detection and durable server ordering require the separate real SQL suite.

The fixture control token is newly generated for each run and redacted from saved CLI output and ledger errors. The synthetic token is passed in the local CLI's JSON arguments, so other processes on this same Mac can observe it in process arguments while the run is active. It authorizes only this temporary loopback fixture; it is never a production credential. Fixture logs exclude tokens, request bodies and queries. Preserve `.xcresult` locally as diagnostic material.

These fast regressions need no simulator and start no production service:

```sh
node --test ios/Tools/qa/fixture-server.test.mjs
python3 ios/Tools/qa/run-native-qa.test.py
```

The runner tests mock native commands and check qualification of selected test receipts, timeout redaction and process cleanup. They do not count as native application QA. The fixture tests run temporary loopback servers on automatically assigned test ports.

Focused repair qualification can use `--suite directed --only-suite MutationJournalTests --only-suite PreviouslyDurabilityTests --only-suite PreviouslyAccountIsolationTests`. Full qualification remains `--suite all --duration 300 --max-actions 500`, which selects every core directed class plus all three fixed seeds. `--only-suite PreviouslyTrailerTests` is an explicit separate live external-video check and never joins the core fixture qualification implicitly.
