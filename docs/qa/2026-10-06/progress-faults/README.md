# Progress fault run — 6 October 2026

**Initial reproduction:11 passed,3 failed,0 skipped** across14 cases using real production HTTP routes and PostgreSQL. Source revision: `19649b3748eac6ca7508f86ad96be9f533406fcb`, with the new QA harness in the working tree. The disposable database was created, migrated and removed successfully; no production app database was read or written and dotenv was disabled.

Passed evidence includes:

- A committed write survives a dropped response; two identical retries do not add effects or duplicate rows.
- A failed single-part write leaves progress unchanged; a later retry succeeds.
- A second-part failure rolls back the whole franchise transaction, including its subscription status; retry succeeds.
- Invalid compound parts cannot partially change valid parts or status.
- Two authenticated synthetic accounts retain independent progress/status; foreign identity fields are rejected.
- Replaying a session id preserves one row; another account cannot read, replace or delete it.
- A committed deletion with a dropped receipt leaves a tombstone; retry is harmless and a delayed session PUT returns 410.

The three failed assertions deliberately send an old request again after a newer acknowledged request:

| Sequence | Desired state | Observed storage |
| --- | --- | --- |
| Progress 6 commits, receipt lost; save 7; replay 6 | 7 remains | 6 |
| Compound 8/9 + completed commits, receipt lost; reset + planned; replay old command | 0/0 + planned remains | 8/9 + completed |
| Open session commits, receipt lost; complete session; replay old open session | Completion remains | `completed_at = null` |

The initial protocol lacked operation identities/versions. Native review also found a retry path that bypassed its serialized lane; the client repair and directed UI tests are recorded separately. The original SQL failure evidence remains preserved above.

Reproduce the current suite with `python3 server/qa/run-progress-faults.py --output <new-evidence-directory>`. [Results](results.json) contain every case and fault, [run ledger](run-ledger.json) proves scratch database cleanup, and [run log](run.log) contains the real-route trace and injected PostgreSQL error. [Harness boundaries](../../../../server/qa/README.md) describe what this run proves and excludes.


## Ordered intent repair

The final [compiled Node24.21.0 run on patched dependencies](compiled-node24-final/results.json) passed **31/31 real HTTP/PostgreSQL cases** at11:19:16–11:19:18UTC; its [ledger](compiled-node24-final/run-ledger.json) confirms created/migrated/drained/removed scratch state. Outbound fetch and non-loopback sockets were denied, with zero blocked attempts. The release artifact’s `dist/server.js`, shared SQL client and services executed; [compiled/ops SHA256 manifest](compiled-node24-final/compiled-files.json) stayed unchanged. Source is dirty base19649b3. The first v2 attempt preserved newer session completion but failed a numeric-versus-bigint-string test comparison; that harness oracle was corrected in the separately qualified run. The current backend mocked suite separately passed1,280 tests across79files on Node24 with an explicitly invalid database URL and dotenv disabled.

**Historical boundary correction:** earlier expanded Node25 runs exercised subscription enrichment without enforcing an outbound-network deny rule. AniList permits unauthenticated requests, so blank credentials alone did not establish zero provider attempts. Those receipts cannot certify that claim; they captured no attempt counter. The final run seeds fresh synthetic enrichment and enforces/records the closed network boundary. No production data or credentials were used in either version.

Migration0014 stores operation receipts and per-writer resource cursors. All three headers must be supplied together: `X-Previously-Operation-Id` UUID, `X-Previously-Writer-Id` UUID, and `X-Previously-Writer-Seq` decimal integer1–9,007,199,254,740,991. The client persists the stamp when creating an intent, before sending, and keeps it for every retry. New deliberate Undo/reset actions receive new stamps.

The identity advisory lock, durable deletion recheck, effects, receipt and cursors share one database transaction. Matching replays have no effects. Reusing an operation with different payload/writer/sequence returns409`operation_conflict`; reusing a writer sequence for a distinct operation returns409`operation_sequence_conflict`. Failed transactions retain neither receipt nor cursor, so retry can apply. Simple200 responses include `applied`; watch-session204 responses expose `X-Previously-Applied`. Replayed/superseded compound commands return the **current canonical** progress/status with `applied:false`, never an old receipt body.

Resource ordering covers progress, compound progress/status, subscription create/status/delete and whole watch sessions. A newer media write supersedes an older command touching that part; an older write to an independent part can still apply. A separate unsubscribe barrier survives explicit re-subscribe, preventing a never-committed pre-delete progress intent from returning later. A separately stamped Undo unsubscribe must still be sent after a compound replay. Deleting a never-created session consumes that session id, as deletion of an existing session does. Every account retains separate receipt/cursor ownership; deletion erases both tables.

The31 cases include the original3 stale replay sequences, precommit failure and rollback, never-committed stale intents, concurrent replay, intentional decreases, compound atomic supersession/current canonical response, distinct parts, malformed headers, hash/sequence conflicts, membership barriers/rejoin, unseen-session deletion, foreign ownership, an independent physical-write trigger audit, failed session rollback/order, not-found requests retaining no accepted receipt, final410 after deletion, and a mutation using an already authenticated identity after durable erasure.

**Limits:** fully missing headers retain legacy beta last-arrival semantics. Native upgrade and persistent stamp wiring are separate evidence. Ordering is per account/device writer; independent devices retain arrival ordering, not global offline causality. Provider transport, physical devices, authentication issuance and production deployment are outside this runner.
