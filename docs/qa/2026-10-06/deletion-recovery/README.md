# Independent deletion recovery

The final [compiled Node24.21.0 real PostgreSQL run](compiled-node24-apple-policy/results.json) passed **6/6 cases** at12:34:41–12:34:45UTC. Its [ledger](compiled-node24-apple-policy/run-ledger.json) proves removal of both the freshly migrated database and unique temporary operational ledger directory. Outbound fetch/non-loopback sockets were denied with zero blocked attempts. No production database/journal or credentials were used. The initial Node25 receipt and first aborted socket-guard attempt remain preserved separately.

| Case | Independent evidence |
| --- | --- |
| DB transaction fails after deletion was requested | User/progress/operation rows roll back; requested FS marker survives; production reconciliation later erases rows and blocks identity upsert/auth |
| Completed identity appears in an older restored DB | Hash-only independent journal erases restored owned rows, retains completion and blocks upsert |
| Provider already deleted identity but receipt was lost | Existing injectable ClerkUsersApi returns404; real finishDeletion marks both DB and FS complete, clears raw identity and does not downgrade |
| Apple exchange/revoke interrupted before a durable receipt | Outcome defaults manual_required; status confirms app-data erasure without claiming revocation or retaining reusable proof |
| Proven Apple outcome followed by SQL restore and delayed fallback | Revoked metadata survives the independent journal, old account data is erased, status and repeated DELETE return canonical receipt without proof replay |
| No Apple link, followed by provider404 cleanup | not_applicable metadata survives completion; pending raw Clerk identity is cleared |

The suite executes the compiled release modules; its [compiled/ops SHA256 manifest](compiled-node24-apple-policy/compiled-files.json) stayed unchanged. It exercises the production erasure plan, advisory identity locks, reconciliation and finishDeletion against actual PostgreSQL and the real atomic/checksummed FS ledger. Authentication is checked through Fastify injection; no HTTP listener or deletion worker starts. Provider404 is injected at the existing users-API seam, **not an actual Clerk SDK/network response**. Outbound fetch and non-loopback sockets are denied. These are recovery/storage proofs, not production backup or live-provider attestations.

The earlier run used system Node25.9.0. Current evidence uses already installed Node24.21.0 LTS and patched dependencies. Source is dirty base19649b3 plus the qualified Apple/content changes. [Apple proof boundaries](../apple-deletion/README.md) distinguish real cryptography with synthetic keys, mocked provider transport and real SQL recovery. Existing [seven current Node24 real-route deletion cases](../deletion-faults/qualified-node24-current/results.json) remain separate evidence.

```sh
python3 server/qa/run-deletion-recovery.py
```

The runner accepts an output directory, never a target DB or operational journal. It creates and owns unique scratch state, disables dotenv/provider credentials, preserves results and naturally drains owned connections before removal. [Launcher](../../../../server/qa/run-deletion-recovery.py), [suite](../../../../server/qa/deletion-recovery.ts), [ordered-intent checks](../progress-faults/README.md), [consolidated QA](../README.md).
