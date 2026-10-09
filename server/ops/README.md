# Previously Mac Mini operations

Local, zero-cost scripts. They do not install jobs, send notifications, replace the live database, or configure a cloud service. Node 24 LTS and the existing Homebrew PostgreSQL tools are used.

## Files and retention

Default private root: `/Users/shan2new/Infra/previously`; override with `PREVIOUSLY_OPS_ROOT`. Directory mode0700, data mode0600. `PREVIOUSLY_ENV_FILE` points to a real private environment file (no group/other permissions). Secrets remain in environment, never command arguments or generated plists.

| Script | Behavior |
| --- | --- |
| `initialize-ledger.mjs` | Reconciles current `account_deletions` into the independent durable current ledger. Required once before the production listener starts. Existing markers are never erased. |
| `ledger.mjs` | Fsynced current pending identities plus immutable hash-only requested/completed markers. Request intent is recorded before erasure commit. Completed identities never regain a raw ID. |
| `backup.mjs` | Custom pg_dump, private from its first byte; SHA256, restore TOC, source fingerprint and ledger digest manifest; retains at most seven completed dumps and maximum seven-day age. |
| `restore-check.mjs` | Verifies manifest/SHA, restores only to a unique owned scratch database, checks cascading ownership, merges the independent ledger, sweeps every erased hash, verifies absence, and drops the scratch database even after failure. |
| `collect.mjs` | Hourly private aggregate metrics/usage, public HTTPS readiness, backup freshness, disk space and deletion counts. No individual events/raw IDs in historical snapshots. Maximum 30-day snapshots. It prunes expired backups/logs/snapshots before endpoint calls, so a stopped app does not suspend retention. |
| `run-server.mjs` | Direct Node compiled `dist/index.js` child with production environment and `--max-old-space-size=256 --max-semi-space-size=8`. Sanitizes both output streams into 8MiB segments, at most16 (128MiB), maximum seven-day age. Forwards shutdown and allows35seconds of drain (backend30seconds, launchd40seconds). |
| `prepare-install.mjs` | Writes three private candidate plists plus hashes and a forensic copy of the old backend plist. Does not install or launch them. |

`status.json` is the current private snapshot. A healthy snapshot requires public readiness, a verified backup no older than26hours, at least2GiB available disk, and no pending deletion missing its retry identity. Snapshot freshness itself must also be checked by the operator/heartbeat. Raw metrics reset when the backend restarts; use the included start/measurement timestamps when calculating throughput.

## Production sequence for the release owner

1. Compile the qualified backend with `npm run build` and capture its `dist/`, migration files and ops scripts into an immutable server directory. Install production dependencies with `npm ci --omit=dev`; the runtime does not require tsx. Include compiled JavaScript hashes in the backup fingerprint. Use `/opt/homebrew/opt/node@24/bin/node` throughout. Keep the previous artifact/config for rollback. Do not run the service from the mutable checkout.
2. Save production keys/config in a mode0600 file outside the artifact. Apply the account-deletion migration, configure the Clerk production key and observability token, and disable paid API features/comments. Confirm the independent ops root is the intended permanent path.
3. With `PREVIOUSLY_ENV_FILE` and `PREVIOUSLY_OPS_ROOT` set, run `node ops/initialize-ledger.mjs`, then `node ops/backup.mjs`. Existing ledgers merge conservatively; initialization is not a reset. Save the successful private manifest path.
4. Run `node ops/restore-check.mjs /private/path/previously-….manifest.json`. This always drops its test restore. It does not provide a production database replacement command. A real recovery keeps the app stopped until the live independent ledger is applied and erased identities are absent.
5. Prepare candidate plists: `node ops/prepare-install.mjs /absolute/immutable/server /absolute/private/production.env /absolute/private/ops-root /absolute/private/install-candidate`. Review the manifest and `plutil -lint` each plist. The default backend label remains `com.shan.previously`; new job labels are `com.shan.previously.backup` and `com.shan.previously.ops`. Backup schedule is03:15 in the Mac’s local timezone; collection runs hourly and at load.
6. After review, the release owner replaces/bootstraps only those Previously LaunchAgents. Candidate standard streams target `/dev/null`; backend diagnostics are in the owned rotated files, and launchd still reports process/exit state. Shared PostgreSQL and Cloudflare jobs are not restarted.
7. Verify live public readiness/auth, collector, first daily job result, log rotation and graceful restart. Record labels/artifact fingerprint/evidence before making the public policy effective.

For service recovery, stop only the affected Previously jobs and use a verified immutable artifact/config that retains the current production issuer and account mappings. After Clerk identity cutover, do not restore the captured mutable development plist: it can run changed checkout code with the old issuer. Follow [the identity-cutover recovery guide](../../docs/release/2026-10-06/identity-cutover-recovery.md), then verify readiness. Schema/data recovery is separate: never load an older dump without the current independent deletion ledger. Never delete the ledger as part of retention or recovery. Same-disk backups do not cover total Mac/storage loss.

## Verification

`/opt/homebrew/opt/node@24/bin/node --test ops/*.test.mjs`

The suite uses temporary private directories and uniquely named PostgreSQL fixture/scratch databases. It verifies durability/order/concurrency, stable read digests, privacy, age/count caps, real dump/restore and deletion sweep, negative restore gates, public-token isolation, wrapper heap/shutdown behavior and uninstalled plist validity. It does not mutate production app data or LaunchAgents. All owned temporary databases and files are cleaned.
