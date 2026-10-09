# 9 October 2026 — status rule, drops-only Home, two-line notes, the show page on the stage, Schedule's card, the Next up widget

The owner's brief: "The Schedule screen just feels poorly made and not premium enough like the Home
screen"; "only the most recently aired franchise(s) should be shown in full bleed hero"; "The Feed
feels utterly cramped unlike X"; "Parth had already watched and marked all episodes [of] Seven
Dials, WTF is it showing in Planned?"; and, before changes, "the Franchise details UX is absolutely
shit and disconnected with the rest of the amazing app experience. Think about it first."

## What changed

- **Status rule, both sides.** The server derives a show's status from every progress write
  (`statusAfterWrites`, services/library.ts); the app's resume rule no longer bails when a batch
  finishes a Planned show, and the settle and sweep take Planned. Root cause and evidence are in
  the commit message of `62d694f` and CLAUDE.md's write rules. `npm run status:backfill --apply`
  was run by the owner on production the same day: 8 rows moved (2 to Watched, Seven Dials among
  them; 6 to Watching); a second dry run plans nothing.
- **Home**: the billboard is drops only, paging when several; a quiet card otherwise.
- **Feed**: sentence whole, note clamped to two lines, the foot opened.
- **Show page**: Home's billboard, continued — one shared `ShowBillboard`, the state lockup with the
  action row, a pinned index that scrolls to sections and is the only name a section has. The
  direction, diagnosis and captures: `design/show-page-2026-10-09/`.
- **Schedule**: the card is the same stage, full bleed, the page in its hue; rows with a 56-pt face
  and captions that keep their time; a landing slack for short weeks.
- **Next up widget**: small, medium and Lock Screen sizes from an App Group snapshot the app
  writes; a tap deep-links to the show.

## Verification

- Server: `tsc --noEmit` clean; vitest 81 files, 1339 tests passed (Node 24).
- iOS: Debug simulator builds succeeded after every step (generic iOS Simulator destination).
  Photographed on a fresh "Previously QA 14 Pro" (iOS 27) against the 2 Oct read-only library
  snapshot served on loopback 18789 (`design/artwork-2026-10-02/preview-server.py`): Home's drop
  billboard and quiet card, the Feed, the show page at rest and scrolled to Episodes, About and
  Trailers (three shows), Schedule landed on today and on a plain day, and the widget on the
  simulator's Home Screen with real snapshot data. The extracted stage was compared numerically
  with the pre-extraction Home capture (identical layout; the art's drift phase accounts for the
  residual).
- Not verified: a physical device, VoiceOver, the accessibility text sizes on the new page, the
  medium widget and the Lock Screen rectangle at rest, the widget's deep link end to end.

## Release — 1.0 (15)

Builds 13 and 14 were cut from this tree on 6 Oct without the version bump being committed;
Apple holds 14 under a 2.1 information request. 15 follows.

- Commits `cd5d353` (the 5–7 Oct release tree), `62d694f` (server status rule), `e70f817` (feed),
  `0da1e6b` (shared billboard, Home, show page, Schedule), `820cad2` (widget + client status rule,
  build 15), `407a99c` (docs) pushed to `origin/main`.
- Signed Release archive succeeded at `ios/build/Previously-15.xcarchive`
  (`xcodebuild … -configuration Release -destination generic/platform=iOS
  CLERK_PUBLISHABLE_KEY=<live> -allowProvisioningUpdates archive`; log `ios/build/archive-15.log`).
  The archived app reports 1.0 (15), `APIBaseURL` https://anime.cognipin.com, the live Clerk key
  and the `previously` URL scheme; app and widget both carry
  `com.apple.security.application-groups` = `group.com.cognipin.previously`; the widget bundle
  registers the Outfit weights.
- `ExportOptions-upload.plist` (app-store-connect, upload, automatic signing) exported and
  uploaded the archive: **18:46:03 IST, 9 October 2026 — `Upload succeeded`, `EXPORT SUCCEEDED`**,
  package processing (log `ios/build/upload-15.log`).
- Not yet verified: TestFlight processing and tester availability of 15 (check the TestFlight
  app or App Store Connect), the App Group on a physical device (automatic signing registered it
  for the archive's profiles), and whether 15 should replace 14 in the open review submission —
  Apple's 2.1 request asked for information, not a build, and that reply is still the owner's.
- The server's status rule reaches production only with a server release through
  `server/ops` (`npm run build`, immutable directory, `prepare-install.mjs`); not done here.
  The one-off heal was applied to production by the owner on 9 Oct.

