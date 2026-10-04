# History import — 4 October 2026

## Takeover and intent

Codex read Claude Code session `80a0d5ee-e197-476a-b5ca-f27774597b00` and reviewed its uncommitted
changes on `first-run-onboarding` (base `683e78b`). Claude had implemented the import pipeline,
native readers and sheet, and stopped during a simulator walkthrough. Build 9 belonged to the
previous first-run/design-system work. This document records the local verification before
release; see [the release record](../../docs/history-import-release-2026-10-04.md) for deployment
and TestFlight evidence.

The retained flow is source → username/file → preview → explicit Add → result, from the
first-run picker and Profile. Public AniList lists, MAL XML/gzip, and the two TV Time CSV/ZIP
shapes are supported. A series is one library show even when the source lists several seasons.

## Changes completed during takeover

- Async, account-owned preview jobs avoid the app/proxy timeout on large exports. Short polling
  requests use the existing auth and retry transport. Reading can be dismissed without applying.
- Atomic SQL raises prevent concurrent imports lowering progress. Background status corrections
  require the same unchanged import-owned membership. User edits/removals win.
- First-run hand-picked shows skip imported memberships instead of overwriting their status.
- Results persist across app relaunch and reopen through Profile. Polling cancellation/account
  guards keep an old request from replacing a new account's state. Offline polling does not
  falsely claim the server has failed.
- Title fallback rejects ambiguous remakes and respects a supplied year; provider failures are
  shown as failures rather than thousands of unmatched titles.
- Gzip and ZIP CRC/length validation, bounded decompression, complete-XML parsing, and ISO timezone
  handling replace permissive file reads. Input/inflated content is capped at 64 MiB.
- Previewed ready-episode counts use the same aired ceilings as the writes. Temporary timing logs
  are removed; API contract and project notes are updated.

## Verification

All writes below used `previously_onboarding_scratch`, never the production database.

- Baseline before takeover: server typecheck and 1,224 tests passed.
- Final server: typecheck and 1,240 tests across 76 files passed. Import coverage includes planning,
  source identity/error handling and authenticated async route behavior.
- `verify-import.mts`: 10 real Postgres checks passed, including 60 concurrent raises, repeat
  applies, aired caps, status edits, removal, and removal/re-addition. Its generated rows are
  cleaned up in `finally`; it refuses every database except the named scratch database.
- Live MAL API: two rows, one already catalogued and one fetched in the background; finished with
  two shows and zero failures. Repeat apply returned the identical completed result.
- Live TV Time API: Breaking Bad S1E1–3 resolved by TVDB ID; one show, three episodes, zero
  failures. Repeat apply returned the identical completed result.
- Native flow in Device Hub: public AniList preview of 715 entries → 446 grouped shows → Add →
  result → relaunch with saved result → first-run lineup (five rows plus “441 more”) → populated
  Home → Profile with the import row. A private AniList list displayed the specific privacy error.
  Final preview and SQL both held 6,576 watched counts; Profile showed 6,315 because its existing
  counter deliberately excludes films/extras and counts only main-story episodes.
- Final simulator build: Debug, scheme `Previously`, simulator `Previously FirstRun iPhone 14 Pro`
  (`0FDBEC20-0D6F-4351-A703-BCCDCAABC4AD`), iOS 27 runtime, iOS 18 deployment target.
  `API_BASE_URL=http://localhost:8799`, blank Clerk key; production build settings unchanged.
- Native checks: 24 import reader regressions, 59 announcement regressions and copy audit pass.
  Reader fixtures cover all three CSV shapes, XML/gzip/ZIP, independent Python gzip with FEXTRA,
  corruption/truncation, quoted CSV and timezone offsets.

The system file-provider picker has not been driven through an actual iCloud file download.
Readers, transport and server apply were exercised separately for MAL/TV Time. No physical-device
or TestFlight verification is claimed.

## Remaining limits and release state

TV Time numbering is approximate: highest watched episode per TV season, total watched along an
anime's story. The preview discloses this. TV Time movies, original watch timestamps, separate
rewatch events, ratings and comments are not imported. Trakt is out of scope.

Server jobs remain in memory. A server restart loses unfinished work; successful writes survive
and re-import is safe. Previews/completed results expire after 30 minutes; running jobs are kept.

At the end of the implementation pass, no commit, push, production restart, migration, or
TestFlight upload had been performed. The subsequent release is recorded separately above.
The scratch server uses port 8799 with no cron/news agent/LLM; the dedicated simulator uses its
test account.

To repeat the SQL checks from the repository root:

```sh
DATABASE_URL=postgres://localhost:5432/previously_onboarding_scratch \
  server/node_modules/.bin/tsx design/onboarding-2026-10-04/verify-import.mts
```
