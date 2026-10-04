# History import release — 4 October 2026

The user authorized production deployment and TestFlight distribution after the
[implementation verification](../design/onboarding-2026-10-04/IMPORT-VERIFICATION.md).

## Source and production

- Release commit: `b3a5391` (`feat: import watch history from AniList, MAL and TV Time`).
- Pushed `main` and `first-run-onboarding` to `shan2new/previously`; `main` was fast-forwarded.
- Restarted `com.shan.previously` on the Mac mini. The new server logged
  `Previously server listening on :8787 (APP_ENV=production)` at 20:00:59 IST.
- No new schema or dependency changes required a migration or install. A read-only check
  confirmed production already has the latest migration (`0012_special_mimic`) and both
  `watch_sessions` and `user_audience` tables.
- Twelve read-only smoke probes passed across `http://127.0.0.1:8787` and
  `https://anime.cognipin.com`: health returned 200; anonymous async preview, preview polling,
  apply and progress requests returned 401; the development bearer was rejected with 401.
- No production library records were created by release verification. Full import writes and
  concurrency checks were run against the dedicated scratch database before release.

## iOS 1.0 (10)

- Generated the Xcode project from `ios/project.yml`, with `CURRENT_PROJECT_VERSION: "10"`.
- Release archive succeeded at `ios/build/Previously-10.xcarchive`.
- App `com.cognipin.previously` and widget `com.cognipin.previously.widgets` both report 1.0 (10)
  and passed strict code-signature verification.
- Archive app configuration points to `https://anime.cognipin.com` and contains the configured
  Clerk publishable key. Scratch API and auth overrides are absent.
- Upload uses the existing Xcode Apple account and `ios/ExportOptions-upload.plist`, targeting
  team `YLPZXZS2F4` and the **Previously.** App Store Connect record `6818452741`.
- Upload completed at 20:05:56 IST with `Upload succeeded.` and `EXPORT SUCCEEDED`.
  Apple accepted the package and reported that processing had started.
- At 20:09 IST, the signed-in native TestFlight app showed **Previously. → Version 1.0 (10)**
  with an enabled **Install** button, size **27.5 MB**, expiring **2 January 2027 at 20:07**.
  This verifies that Apple finished processing and the build is available to the existing
  tester account. It does not claim a physical-iPhone installation or external beta review.

Build and upload logs are local ignored artifacts at `ios/build/archive-10.log` and
`ios/build/upload-10.log`.

## Verification scope

Pre-release checks passed: 1,240 server tests, server typecheck, 10 scratch Postgres invariants,
24 native import-reader regressions, 59 announcement regressions, copy audit, simulator build,
and live scratch import flows. See the linked verification record for fixtures and limits.

An actual iCloud file download and installation on a physical iPhone have not been exercised.
Server import jobs remain in memory; a server restart loses unfinished jobs while preserving
already-applied progress. TV Time's season-numbering approximation is disclosed in the preview.
