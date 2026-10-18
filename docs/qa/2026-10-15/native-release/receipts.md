# Final native receipt contract

Current attempt `20261015T175438622566Z` finished with 75 directed passes and two passed monkey seeds. The third seed reached the runner's 1,800-second limit (exit 124) after repeated XCTest animation-idle waits; its final oracle/relaunch checks did not complete. Fixture cleanup completed and the source fingerprint stayed unchanged. This is a failed full run, not qualified release evidence. Its earlier phase passes remain useful, scoped observations.

`native-results.json` and `files-results.json` do not exist until one actual completed full run qualifies. The summarizer never combines earlier focused results into a green release receipt.

After root completes the final run and its fixture cleanup, use the actual run directory:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 docs/qa/2026-10-15/native-release/summarize-native.py \
  --run-dir ios/Tools/qa/.runs/ACTUAL_COMPLETED_ALL_RUN
```

`--verify-only` performs the same evidence checks without publishing either JSON file. Existing outputs are never overwritten. A refusal exits1 and writes no success receipts. This script does not build, install, launch, drive a simulator, start a fixture or access production. It does use the installed Apple `xcresulttool get test-results tests` to read each existing result bundle. Preserve the actual raw MCP log paths until this readback finishes.

Required evidence is deliberately specific:

- Explicit ledger invocation `requestedSuite: all`, no focused classes, source build17, QA scheme/configuration/bundle, exact fixed seeds20261006/60102620/38654705664 and requested300s budget. The four phases must belong to the same completed ledger, in order, with fixture cleanup confirmed.
- Exactly75 selected named directed tests, including all10 Swift Testing storage cases, four export preparation cases and three Files UI cases. Every name must pass in the primary Apple result, saved named-case JSON and runner ledger. MCP counts must agree; its known flattened omission may cover only Swift Testing cases. No missing, extra, duplicate, failed or skipped case is accepted.
- All three monkey phases pass their named case, have nonzero actual actions/assertions, observe all five roots plus anime detail, and record at least300s total driver session. The requested random budget is300s; observed session time also includes setup and final oracle/relaunch. The source has a separate action cap, so the summary does not invent a measured duration for the random subinterval.
- The actual raw `QA_SUMMARY` lines must equal each phase's ledger coverage. The final protected-write audit is independently recomputed from that run's fixture log, checking stable operation/writer/sequence identity. Each seed must add actual protected operations. Counts are cumulative; only the last audit is the full-run total.
- Every recorded phase fingerprint must equal the initial fingerprint and the current source. Build17 is validated from the project source and captured invocation. Raw receipts, primary named tree, xcresult Info, logs, fixture and summarizer/runner are hashed for provenance. A source hash does not independently reconstruct compiler inputs from an archive binary.

`native-results.json` contains `qualified`, `build`, `originalLedgerPath`, `evidencePath`, `sourceFingerprint`, `directed`, `monkey`, `mutationAudit`, `provenance` and explicit boundaries. `files-results.json` uses the same ledger/provenance plus all seven passed Files/export-helper cases and the three actual driver coverage summaries. Its descriptions state what the frozen named UI tests asserted; they do not invent separate byte measurements or request counters absent from the recorded summaries. Primary artifacts and the frozen test source remain the detailed proof.

These are fixture-based QA simulator results. Production Release archiving, minimum-iOS18/physical-device runtime, real Clerk erasure/sign-in, TestFlight processing and Apple review each require separate receipts. The dossier may consume the final JSON only after it exists and its source still matches.

The pure guard tests use synthetic ledgers solely to test rejection behavior; they cannot publish a native result:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 docs/qa/2026-10-15/native-release/test_summarize_native.py
```
