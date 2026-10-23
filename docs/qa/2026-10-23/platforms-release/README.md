# Previously platforms release — 23 October 2026, night

**Activated at 16:40:43 UTC.** The artifact built from `6aea0ec` (every streaming platform with one
release time, split by the show's origin) replaces the evening's 20261023T160259Z. Migration 0018
(`media.origin_countries`, one nullable column) was applied first, after a verified backup.

| State | Evidence |
| --- | --- |
| Current production artifact | `/Users/shan2new/Infra/previously/releases/20261023T163910Z/server` |
| Retained prior production artifact | `/Users/shan2new/Infra/previously/releases/20261023T160259Z/server` |
| Artifact source SHA256 (491 files) | `7418cf2909cb1a54179bc8c05d59579c6a286bc070cf4d1588cda07a98d34c12` ([manifest](artifact/artifact-manifest.json)) |
| Production audit | 0 advisories |
| Activation | [activation-receipt.json](activation-receipt.json): stop → verified in 9.8 s, no bootstrap retries, no rollback |
| Candidate jobs | [candidate-manifest.json](candidate-manifest.json): each differs from the live plist only in the release path; rollback copies equal the live files |

## Sequence (the evening's, [drops-release](../drops-release/README.md), plus a migration)

1. **Qualification.** Typecheck; 1,372 unit tests (the Clerk-migration file, which runs against a
   real Postgres, timed out once at a load average of 337 and passed alone, 14/14). On the scratch
   copy: migration 0018, then ten shows refreshed from TMDB to write their countries — Deadly Tag
   and Made in Korea (Disney+, KR) at 4 PM in Seoul, Paolo (HBO Max, FR) at 9 AM in Paris, The Pitt
   and Hacks at 9 PM Eastern, Dark Matter at midnight Eastern after TMDB's Pacific date, Slow Horses
   (GB) at midnight Eastern on its own date, Crystal Lake (Peacock) at 3 AM Eastern. The artifact's
   own `dist` against scratch: health 200, library, feed and recommendations served, no error lines.
2. **Artifact.** Same file selection; `npm ci --omit=dev --ignore-scripts`; write permissions removed.
3. **Backup before schema change.** With the running release's ops:
   `previously-20261023T163952007Z-73c591a70826.dump`, 15,404,685 bytes, restored to an owned
   scratch database in 1.28 s (18 users before and after, 0 erased identities remaining), scratch
   dropped ([receipt](premigration-backup-restore.json)).
4. **Migration 0018** from the new artifact (`dist/db/migrate.js`, production config): 19 recorded
   afterwards; `media.origin_countries` jsonb, nullable. The running release never reads it.
5. **Activation** with [activate-reviewed.py](activate-reviewed.py) (the evening's helper with this
   release's paths and pinned hashes): pre-stop backup and restore check, stop, swap, bootstrap,
   local and public readiness, backup job (`previously-20261023T164036850Z-47612a8f1f72.dump`,
   verified), collector (healthy), private metrics, anonymous 404s, comments disabled, stale
   reports 0.
6. **After.** Local and public `/ready` 200. Read back through the compiled `getFranchise`
   ([readback](readback.json)): of the 53 followed TV shows, 31 are timed by their platform (25
   before — Daredevil: Born Again, Peacemaker, Percy Jackson, Silo, Stuart Fails to Save the
   Universe and Ted Lasso joined), 16 by TVmaze, 6 stay dates. No row had a country yet (0 of
   3,232): the hourly TV refresh writes them, oldest first; until then the US time applies, which
   is right for every followed Disney+, HBO Max and Apple show (all US originals).

No account, report, configuration, credential, DNS or provider change; no live-database restore.
