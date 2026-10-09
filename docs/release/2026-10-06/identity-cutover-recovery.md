# Recovery across the Clerk identity cutover

Prepared 6 October 2026. The four-user identity migration and live service cutover have not yet run. This is an operator recovery boundary, not a claim that a post-cutover backup already exists.

The migration preserves internal app UUIDs and owned data but changes `users.clerk_id` from development to production identifiers. Independent account-deletion markers hash the authenticated identifier at the time of erasure. Consequently a dump made before the identity cutover and a deletion marker made afterward belong to different identity realms. The ordinary deletion sweep does not translate identifiers between realms. A passing pre-cutover scratch restore is therefore not sufficient evidence for restoring the consumer production realm.

Before reopening the production listener:

1. Complete the verified four-user mapping and preserve the private resumable migration state while pre-cutover recovery material is retained. Verify unchanged app UUIDs and full owned-data hashes.
2. Take a new backup using the qualified immutable operator and production configuration. Label the receipt **post-Clerk-cutover** and record its exact manifest path, timestamp, artifact fingerprint, database migration level and owned-data verification.
3. Restore that exact new backup into an isolated scratch database. Apply the authoritative current deletion ledger before evaluating the restored accounts. Verify the production mappings and non-deleted libraries, then remove the scratch database.
4. Treat this verified post-cutover dump, and subsequent verified dumps from the production realm, as the supported consumer recovery baseline. Keep its exact receipt available to the operator.

Earlier retained dumps remain private historical recovery material subject to the existing seven-day expiry. Do not reopen one as production merely because its checksum and schema restore pass. Recovering from such a dump requires a separate stopped-service operation that revalidates the trusted internal-UUID identity mapping, translates the surviving account identifiers to the production realm, and then applies the current deletion ledger. That cross-realm recovery has not been implemented or qualified by the current ordinary restore tool. Do not improvise an email-based merge or claim it is safe.

The captured old launchd plist runs mutable development source through `npx tsx`. Reinstalling it after the identity cutover is not a qualified rollback: it can load current working-tree code with an old issuer/configuration. A service recovery must retain the production issuer, current internal UUID mappings and authoritative deletion ledger, and use a verified immutable artifact/configuration. Database recovery remains a separate stopped-service operation. No shared Postgres or Cloudflare service restart is required.

The source development identities are not copied sessions or OAuth grants, and the migration does not purge that instance. Existing-user access must be verified in production before deciding how to retire development-only material. No permanent identity or backup purge is authorized by this document.

No source, runtime, backup, identity, launchd job or production data is changed by this record.
