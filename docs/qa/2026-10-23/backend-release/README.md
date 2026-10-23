# Previously backend release — 23 October 2026

**Activated at 14:33:20 UTC.** All three supervised Previously jobs point to the 23 October immutable
artifact built from `8fff37e` (recommendation rotation by impressions; TV at TVmaze broadcast
times). Migrations 0016 and 0017 were applied first, after a verified backup. The first TVmaze sync
ran on production after activation.

| State | Evidence |
| --- | --- |
| Current production artifact | `/Users/shan2new/Infra/previously/releases/20261023T141047Z/server` |
| Retained prior production artifact | `/Users/shan2new/Infra/previously/releases/20261015T152739Z/server` |
| Artifact source SHA256 (486 files) | `ab5f57939a0c878fd0442a4b7e9a9070928315e82ce970bf62a5c56e154ae32f` ([manifest](artifact/artifact-manifest.json)) |
| Activation | [activation-receipt.json](activation-receipt.json): stop → verified in 8.98 s, no bootstrap retries, no rollback |
| Candidate jobs | [candidate-manifest.json](candidate-manifest.json): each differs from the live plist only in the release path; rollback copies equal the live files |

## Sequence

1. **Qualification.** Server unit suite 1,356/1,356 across 83 files; typecheck; compiled build. The
   artifact's own `dist` served against a scratch copy of production (`previously_fixes_scratch`,
   development auth): health 200, two TVmaze-exact TV shows, impressions `204`, recommendations
   served, no errors. In-app regressions on the QA simulator: `FEED_VERIFY_PASS`,
   `ANNOUNCEMENT_REGRESSIONS_PASS 59`. **No 5× load qualification was run** for this release (the
   15 Oct one did; it is not part of the documented production sequence and needs a quiet host).
2. **Artifact.** `dist`, non-test `src`, `drizzle`, `ops`, the package files; `npm ci --omit=dev
   --ignore-scripts`; write permissions removed. Production audit: **2 advisories** — `fastify`
   (low, header validation bypass; fix 5.12.7) and `ip-address` (moderate, transitive). The lockfile
   has not changed since 19 Oct, so the prior production artifact very likely carries them too;
   dependencies were not changed in this release.
3. **Backup before schema change.** With the prior artifact's ops:
   `previously-20261023T143111487Z-3ec61e826513.dump`, 15,398,479 bytes, restored to an owned
   scratch database in 1.45 s (18 users before and after the deletion-ledger sweep, 0 erased
   identities remaining), scratch dropped ([receipt](premigration-backup-restore.json)).
4. **Migrations.** From the new artifact (`dist/db/migrate.js`, production config): `0016`
   (`recommendation_impressions`) and `0017` (`media_broadcast_times`) — two new tables, nothing
   altered; the running 15 Oct backend never reads them. 18 migrations recorded afterwards.
5. **Activation.** `activate-reviewed.py` here: the 15 Oct helper with this release's paths and
   pinned hashes; its capacity gate removed (see 1). It took its own pre-stop backup and restore
   check (15,401,965 bytes, 1.26 s), stopped the three jobs, swapped the plists, bootstrapped,
   waited for local and public readiness, ran the backup and collector jobs (new backup
   `previously-20261023T143315550Z-45de507d6e6a.dump`, verified), and proved private metrics,
   anonymous 404s, comments disabled and the stale-report SELECT (count 0).
6. **TVmaze sync** (new artifact, production config): 53 followed TV shows checked, 53 matched
   (all through TheTVDB ids), 140 seasons written, 0 failed ([result](broadcast-sync-result.json)).
   Read back through the compiled `getFranchise`: 16 shows are `timesExact`; of the 4 airing now,
   3 are exact — The Simpsons (next 00:00 UTC Mon), Taskmaster (21:05 UTC Thu), Georgie & Mandy's
   First Marriage (00:00 UTC Fri) — and Avatar: Seven Havens (Paramount+) stays on dates.
7. **After.** Public `/ready` 200; `com.shan.previously` running; backup and ops jobs loaded and
   exited 0. The new log segment starts as the 15 Oct one did (two redacted unstructured lines,
   then `social.config`); the old process drained and logged `runtime.shutdown_started`.

No manual account or report writes, credential or configuration changes, DNS or provider changes,
or live-database restore. The cron now also runs `broadcast-times` every six hours at :50.
