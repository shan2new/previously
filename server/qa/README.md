# Isolated server QA

These opt-in checks use existing local dependencies and PostgreSQL. Every launcher accepts an evidence directory, never a target database or API URL. It creates a unique owned scratch database on `127.0.0.1`, applies real migrations, disables dotenv, blanks provider credentials, naturally drains its connections and drops only that database. Results and cleanup ledgers are preserved under `docs/qa/2026-10-06/`.

```sh
python3 server/qa/run-progress-faults.py
python3 server/qa/run-deletion-faults.py
python3 server/qa/run-deletion-recovery.py
python3 server/qa/run-content-policy.py
python3 server/qa/run-load-test.py --quick
python3 server/qa/run-load-test.py --calibrate
python3 server/qa/run-load-test.py
```

The launchers select installed Node24.21.0 LTS. Current progress, recovery and load checks require the prepared `server/dist` production artifact and execute its compiled modules; workspace tsx runs only the QA wrapper. Compiled/ops SHA256 manifests prove those modules stayed unchanged. They do not use the production database, production operational journal or real provider credentials. Current progress, recovery and load harnesses deny outbound fetch/non-loopback sockets; recorded denied-attempt counts must also be zero. The production deletion worker runs idle only in the load harness, against a separate initialized temporary filesystem journal. The index/cron entrypoint is never started.

## Ordered progress and session writes

The [current real-route/SQL receipt](../../docs/qa/2026-10-06/progress-faults/compiled-node24-apple-policy/results.json) passes **31/31**; its [ledger](../../docs/qa/2026-10-06/progress-faults/compiled-node24-apple-policy/run-ledger.json) proves scratch cleanup. The original **11 passes/3 failures** remain preserved, documenting older absolute writes overwriting newer progress, compound status or session completion after a lost receipt. Earlier expanded Node25 runs lacked outbound enforcement at a subscription enrichment hook; they cannot certify zero provider attempts. The final Node24 run closes that boundary and records zero blocked attempts.

The HTTP proxy consumes the complete upstream response before dropping the client connection, proving commit succeeded before the simulated receipt loss. Scratch-only SQL triggers fail writes before commit. Independent SQL reads and a physical-write trigger audit check effects rather than trusting response bodies.

Current mutations accept all three headers together: `X-Previously-Operation-Id` UUID, `X-Previously-Writer-Id` UUID and `X-Previously-Writer-Seq` decimal integer1–9,007,199,254,740,991. Matching retries have no effects; changed operation metadata/payload or sequence reuse returns409. Receipts, resource ordering, effects and the durable account-deletion recheck share one transaction. Rollback retains neither receipt nor cursor. Subscription deletion barriers and permanent watch-session deletion prevent older never-committed intents from resurrecting state. New deliberate Undo/reset actions need new persisted stamps.

Simple writes report `applied`; session204 responses use `X-Previously-Applied`; compound replay/supersession returns current canonical state. Missing all headers retains legacy beta last-arrival behavior. Ordering is per account/device writer, with independent devices retaining arrival ordering. See the [case inventory and protocol limits](../../docs/qa/2026-10-06/progress-faults/README.md).

## Deletion and recovery

The [seven real-route deletion checks](../../docs/qa/2026-10-06/deletion-faults/qualified-node24-current/results.json) cover pending cleanup, lost receipt/status reconciliation, rollback, account isolation and an observed identity-lock waiter. Their rebuild case recreates the server in one process and leaves the independent FS journal disabled.

The [six independent recovery checks](../../docs/qa/2026-10-06/deletion-recovery/compiled-node24-apple-policy/results.json) use real PostgreSQL plus an owned atomic/checksummed FS journal: a precommit DB failure retains requested deletion for reconciliation; a completed hash marker erases a restored account; an injected provider404 completes pending cleanup without retaining the raw identifier. Its [ledger](../../docs/qa/2026-10-06/deletion-recovery/compiled-node24-apple-policy/run-ledger.json) proves both scratch resources were removed. Provider404 is injected at the existing users-API seam, not a live Clerk SDK/network response. Apple outcome cases additionally prove crash defaults, revoked metadata surviving restore, authenticated replay, and non-Apple cleanup. Read [Apple grant boundaries](../../docs/qa/2026-10-06/apple-deletion/README.md) and [27-case consumer content proof](../../docs/qa/2026-10-06/content-policy/README.md).

## Capacity

The full load profile is15RPS for2minutes,75RPS for15minutes,150RPS for1minute and15RPS for5minutes, with95% reads/5% writes,200 cold searches and two simultaneous imports. `--quick` checks harness behavior;390-second `--calibrate` probes resources. Neither short mode qualifies capacity. The full run requires unchanged production/artifact source, declared latency/correctness/memory criteria and cleanup evidence. Read the [load report](../../docs/qa/2026-10-06/load-testing/README.md) for results and measured limits.

These checks prove isolated production route/service/storage behavior. They do not attest production credentials/deployment, actual provider transport, public WAN/tunnel/TLS behavior, physical devices or native persistence. Native UI evidence is recorded separately in the [consolidated QA report](../../docs/qa/2026-10-06/README.md).
