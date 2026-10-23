# Previously drop-times release — 23 October 2026, night

**Activated at 16:04:57 UTC.** The artifact built from `5a66b82` (streaming platforms' release times
for TV drops; the slot rule reads a season's networks) replaces the evening's 20261023T150446Z.
No schema change, no dependency change.

| State | Evidence |
| --- | --- |
| Current production artifact | `/Users/shan2new/Infra/previously/releases/20261023T160259Z/server` |
| Retained prior production artifact | `/Users/shan2new/Infra/previously/releases/20261023T150446Z/server` |
| Artifact source SHA256 (489 files) | `a239003a977bcfd851e25ab1e34daceed25368df93c1713709a17198729ff2f2` ([manifest](artifact/artifact-manifest.json)) |
| Production audit | 0 advisories |
| Activation | [activation-receipt.json](activation-receipt.json): stop → verified in 9.9 s, no bootstrap retries, no rollback |
| Candidate jobs | [candidate-manifest.json](candidate-manifest.json): each differs from the live plist only in the release path; rollback copies equal the live files |

## Sequence (the afternoon's, [backend-release](../backend-release/README.md))

1. **Qualification.** Typecheck, 1,365 unit tests (the Clerk-migration file timed out once with the
   host at a load average of 237 and passed alone), build. The artifact's own `dist` against the
   scratch copy: health 200; Avatar: Seven Havens `timesExact` with `timesSource: "platform"`, its
   next slot at 07:00 UTC; TVmaze still wins where it has times (Taskmaster, Georgie & Mandy); feed
   and recommendations served; no error lines.
2. **Artifact.** Same file selection; `npm ci --omit=dev --ignore-scripts`; write permissions removed.
3. **Backup.** With the running release's ops: `previously-20261023T160408015Z-b77b383e08cb.dump`,
   15,418,018 bytes, restored to an owned scratch database in 1.28 s (18 users before and after,
   0 erased identities remaining), scratch dropped ([receipt](prerelease-backup-restore.json)).
4. **No migrations**: production and the journal both have 18.
5. **Activation** with [activate-reviewed.py](activate-reviewed.py) (the dependency release's helper
   with this release's paths and pinned hashes): pre-stop backup and restore check, stop, swap,
   bootstrap, local and public readiness, backup job
   (`previously-20261023T160451085Z-6d32797ef2b4.dump`, verified), collector (healthy), private
   metrics, anonymous 404s, comments disabled, stale reports 0.
6. **After.** Read back through the compiled `getFranchise` on production
   ([readback.json](readback.json)): of 53 followed TV shows, 16 at TVmaze times, 25 at platform
   times, 12 on dates; Avatar: Seven Havens is the one airing platform show, Episodes 7–9 at
   07:00 UTC on 23 Oct and 10–13 on 30 Oct. The new log segment starts as the last three did (two
   redacted unstructured lines, then `social.config`), no error lines.

## Two things the logs show

- **One public `/ready` 503 just after activation**: the readiness probe (`select 1`, 1 s budget)
  took 2.9 s with the host overloaded; every probe since has been 200, local and public.
- **Three `http.unhandled_error` lines in the PREVIOUS process** (20261023T150446Z), at 15:33:19 UTC,
  inside one burst of an app opening (library ×5, notifications, preferences at 2.4–7.7 s) during
  the same overload, beside a `detail.availability_refresh_failed`. The sanitized log keeps no
  message; they predate this release's code. Nothing like them since.

No account, report, configuration, credential, DNS or provider change; no live-database restore.
