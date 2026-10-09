# Effective privacy policy: publication qualification

Updated 6 October 2026 after the owner-approved historical-log retirement. This supersedes the earlier classification that treated all unperformed consumer workflows as prerequisites to making the policy effective. A policy can truthfully describe implemented and qualified practices without claiming that every live workflow has been exercised.

## Implemented practices and evidence

The reviewed checkout and installed immutable artifact `20261006T123751Z/server` have identical SHA256 values for the deletion route, account-erasure plan, provider cleanup, deletion ledger, Apple deletion service and four retention scripts. The comparison is in `docs/qa/2026-10-06/landing-final/effective-publication/implementation-audit.json` from the repository root.

- Authenticated deletion writes a durable independent intent and erases owned app rows transactionally. Accepted responses distinguish completed Clerk cleanup from pending cleanup. The worker retries provider cleanup, and startup/restore reconciliation re-erases restored accounts before ordinary account creation can proceed. Completed markers retain an identity hash; raw identity remains only while provider cleanup is pending. Separate moderation/security restriction records are disclosed.
- Native accepted deletion clears the current account model, local store, profile snapshot and managed temporary exports before relying on provider sign-out. Unknown responses retain a hold and expose status checking. Device cleanup is limited to the device performing deletion, with independently saved copies excluded.
- Apple proof is ephemeral. Automatic revocation requires validated ownership, successful exchange and successful Apple revocation. Missing/interrupted/unavailable revocation produces a manual-settings outcome, while app-data erasure can proceed. The policy describes this process without claiming a real Apple grant was exercised during QA.
- Managed logs are capped daily segments removed by scheduled cleanup seven days after last write; the first records can be about eight days old. Operational/usage snapshots are scheduled for 30 days and database backups for seven days. Periodic cleanup and the same-Mini hardware-loss limit are disclosed.
- Current authentication/device metadata, basic Google identity without Gmail mailbox access, privacy-enhanced YouTube with a temporary web store and possible embedded advertising, disabled paid personal-search/model APIs, Cloudflare delivery and static Vercel hosting are disclosed.

Existing qualification includes six real-PostgreSQL/owned-filesystem deletion recovery cases, deterministic Apple ownership/exchange/revocation/failure cases, native request/receipt/manual-guidance checks, operator retention/recovery tests, actual installed managed capture, backup/restore and restart/public-readiness receipts. Synthetic provider seams remain explicitly distinct from real provider calls.

## Historical-log decision resolved

The earlier inactive stdout/stderr files were regular, mode0600 and had no open writers in this read-only audit. The owner then authorized removal of those exact files. Root completed guarded metadata/hash/unlink/absence verification at 17:06:26UTC, recorded in `docs/qa/2026-10-06/operations/legacy-log-files-retired.json`. This task independently checked both paths absent and read no historical log contents. Active managed logs, configuration and service were untouched. Draft-only retirement-decision text was removed; no new retention intention is invented.

The June manual dump was previously retired with separate approval. Routine backups remain disclosed as same-hardware recovery with scheduled retention. No off-device purchase or backup gate is introduced.

## Separate consumer-release verification

Production Google and Apple configuration is now enabled, verified by root through public UI and Frontend API; the earlier disabled-provider observation is historical. Actual native Google/Apple authentication, real consumer deletion/provider absence/tombstone/restart verification, a real linked Apple grant, and Files import/export completion remain separate release QA. The policy does not claim these workflows passed.

Physical-iPhone/iOS18 coverage and catalogue licensing outreach are not policy-publication conditions. No material unimplemented privacy guarantee was identified. Source and meaningful tests support the described process; outages remain pending/manual outcomes rather than guaranteed immediate completion.

## Exact website candidate

The authorized candidate uses `draft:false` and `effectiveDate:'6 October 2026'`. Only `lib/legal-content.ts` changes from the current qualified deployment. Native artwork, Dynamic Island, product flows, metadata implementation, project settings and deployment protection are unchanged. Lint, strict TypeScript and Next16.3.8 static build passed under Node24.21.0. Upload exclusions and source hashes are recorded before staging.

The existing Hobby project receives a production-environment candidate without canonical assignment. Qualify its eight anonymous routes, five source-copy/link checks, 27 public image/font hashes, 11 retired404s and fresh mobile legal layouts through the existing secondary alias; then promote that exact deployment and verify canonical alias ownership and eight response hashes. Preserve the prior deployment for technical rollback, recognizing that an older draft is not an appropriate enduring policy after effective publication.

Actual publication is recorded in `docs/qa/2026-10-06/landing-final/effective-publication/qualification-receipt.json`. This preparation record alone is not publication or Store-submission evidence. Root owns release-status and dossier updates.

Publication completed and qualified at 2026-10-06T17:16:33.276777+00:00. The receipt above records actual canonical publication and exact response parity; consumer QA remains separate.
