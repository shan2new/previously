# Previously dependency release — 23 October 2026, evening

**Activated at 15:06:23 UTC.** The artifact built from `6647665` (`fastify` 5.12.7, `ip-address`
10.7.4) replaces the afternoon's 20261023T141047Z, which carried two production advisories:
`fastify` (low, header validation bypass via case-sensitive propertyNames) and `ip-address`
(moderate, transitive, Address6 zone-identifier quadratic time). No source or schema change.

| State | Evidence |
| --- | --- |
| Current production artifact | `/Users/shan2new/Infra/previously/releases/20261023T150446Z/server` |
| Retained prior production artifact | `/Users/shan2new/Infra/previously/releases/20261023T141047Z/server` |
| Artifact source SHA256 (486 files) | `b0aed856735255e612b81e7c365332effe11410f1c163f88a4c909f0ca77220c` ([manifest](artifact/artifact-manifest.json)) |
| Production audit | 0 advisories |
| Activation | [activation-receipt.json](activation-receipt.json): stop → verified in 8.7 s, no bootstrap retries, no rollback |
| Candidate jobs | [candidate-manifest.json](candidate-manifest.json): each differs from the live plist only in the release path; rollback copies equal the live files |

## Sequence (the afternoon's, [backend-release](../backend-release/README.md))

1. **Qualification.** `npm ci` from the new lockfile, typecheck, 1,356/1,356 unit tests, build (286
   files, as before). The artifact's own `dist` against the scratch copy: health 200, library with
   both TVmaze-exact TV shows, impressions `204`, recommendations served, no error lines.
2. **Artifact.** Same file selection; `npm ci --omit=dev --ignore-scripts`; write permissions removed.
3. **Backup.** With the running release's ops: `previously-20261023T150538869Z-833230903f4f.dump`,
   15,419,116 bytes, restored to an owned scratch database in 1.50 s (18 users before and after,
   0 erased identities remaining), scratch dropped ([receipt](prerelease-backup-restore.json)).
4. **No migrations**: production and the journal both have 18.
5. **Activation** with [activate-reviewed.py](activate-reviewed.py) (the afternoon's helper with this
   release's paths and pinned hashes): pre-stop backup and restore check, stop, swap, bootstrap, local
   and public readiness, backup job (`previously-20261023T150618613Z-2ea28070d398.dump`, verified),
   collector (healthy), private metrics, anonymous 404s, comments disabled, stale reports 0.
6. **After.** Public `/ready` 200. The new log segment starts as the last two did (two redacted
   unstructured lines, then `social.config`); the afternoon process drained and logged
   `runtime.shutdown_started`, with no error lines in its segment.

No account, report, configuration, credential, DNS or provider change; no live-database restore.
