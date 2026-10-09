# Apple deletion grant evidence

The changed backend is locally qualified on Node24.21.0. Production deployment and a live Apple-user grant revocation are separate proofs owned by the release owner. No real Apple/Clerk credentials, authorization codes, signing keys or user grants were used in these tests.

| Proof | Result | Evidence |
| --- | --- | --- |
| Full backend units | 1,328/1,328 | [Machine-readable result](unit-qualified.json) |
| Apple cryptographic service cases | 21/21, included above | `server/src/services/appleDeletion.test.ts` |
| Focused Apple/routes/auth/private logs | 73/73 | Included in the full unit receipt |
| Compiled ordered-mutation routes + PostgreSQL | 31/31 | [Result](../progress-faults/compiled-node24-apple-policy/results.json), [cleanup](../progress-faults/compiled-node24-apple-policy/run-ledger.json) |
| Compiled erasure/recovery + PostgreSQL + owned FS ledger | 6/6 | [Result](../deletion-recovery/compiled-node24-apple-policy/results.json), [cleanup](../deletion-recovery/compiled-node24-apple-policy/run-ledger.json) |
| Compiled consumer content policy + PostgreSQL | 27/27 | [Result](../content-policy/compiled-node24-apple-policy/results.json), [cleanup](../content-policy/compiled-node24-apple-policy/run-ledger.json) |
| Operator tests, including real dump/restore and pre0015 backup | 26/26 | [Log](ops-final-qualified.log) |
| Production-only immutable artifact | Audit0; isolated compiled smoke passed; three plists linted, uninstalled | [Manifest](../operations/apple-policy-artifact/artifact-manifest.json), [smoke](../operations/apple-policy-artifact/compiled-smoke.json), [audit](../operations/apple-policy-artifact/production-audit.json) |

The request accepts optional fresh `{apple:{identityToken,authorizationCode}}`. The verified Clerk identity selects the account. Apple RSA signature, issuer, native audience, expiry/freshness and current linked Apple subject are checked before exchange. The exchanged token must retain the same subject and nonce before its refresh/access grant is revoked. The client secret uses an injected synthetic private ES256 key in tests. Wrong-owner, bad signature/audience/issuer/time, replayed code, changed exchange binding and provider errors cannot revoke another grant.

App-data erasure commits before token exchange/revocation and before Clerk identity deletion. Missing proof, unavailable linkage, provider outage, lost revoke receipt or interruption leaves `appleRevocation:"manual_required"`; app-data erasure proceeds. A proven Apple200 receipt yields `"revoked"`; a current linked-account lookup proving no Apple provider yields `"not_applicable"`. Only this enum enters SQL/journal. Logger tests exercise nested request bodies and secret-bearing errors and prove synthetic token/code strings are absent. Repeated DELETE/status returns stored metadata and does not re-exchange the proof. A verified identity with no email claim remains valid.

The independent filesystem intent precedes SQL commit. Hash-only outcome markers preserve late revocation success even if an older completed snapshot is restored. Real PostgreSQL cases prove conservative crash outcome, revoked metadata surviving SQL restore, no late downgrade, authenticated status/DELETE replay without account resurrection, and injected Clerk404 cleanup retaining the outcome. These recovery cases model interruption at the durable boundary in one harness process; they do not kill a production process during a live Apple exchange. Real cryptography runs at the service seam; route lifecycle tests inject the prepared Apple service, while the real SQL replay/status tests use blank provider credentials.

Generated additive migration `0015_exotic_ezekiel.sql` adds only `account_deletions.apple_revocation`, default `manual_required`; it changes no existing owned records. The release owner must apply it before the new listener/collector/ledger initializer. The restore checker adds the same column only to its self-owned scratch restore when qualifying older dumps. Tokens/codes are never retained for later jobs.

Failures remain available: [initial full-unit result](unit-initial.json) contains12 composition mock failures from a newly added policy query; the corrected mock preserves visible fixtures, and real SQL separately verifies the policy. `ops-initial.log` records a fixture missing the new additive column. `ops-final.log` preserves a synthetic child readiness race; readiness now publishes after its SIGTERM handler. No product threshold was relaxed.

The previous23-minute capacity pass predates content/Apple changes. [Current capacity status](../load-testing/final-results.json) remains pending until the frozen candidate completes fresh load qualification. Live Clerk/Apple configuration, Apple network transport, native confirmation/cancellation, physical iPhone and production WAN behavior are outside this local backend receipt.

Identity cutover recovery requires a new production-realm baseline backup and scratch restore. A later production deletion hash cannot mechanically sweep an old development-ID row from a pre-cutover dump. Earlier pre-cutover restore proofs retain their original boundary; the captured old development plist is forensic evidence, not an approved post-cutover rollback. The release owner records migration and post-cutover backup separately.
