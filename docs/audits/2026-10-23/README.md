# 23 October 2026 — rotating recommendations, and TV at its broadcast times (build 23)

The owner's report: "Details screen - Sometimes after scrolling down, the screen isn't able to
scroll upto the hero"; "Airing date and time needs works… doesn't match the timezone and the actual
airing time well"; "Recommendations are completely static. If the user has seen a recommendation,
they should be rotated to make the app feel lively." Then: "Add TVmaze broadcast times for TV shows
now", and "Commit push and deploy everything."

## What changed (commit `8fff37e`)

- **Recommendations rotate by what was seen.** A tile at least half on screen for a second is
  noted, reported when the visit ends, and the next visit's list lets it give way (×0.6 per visit,
  recovering over ~10 days). Measured on the owner's library: a new front four every visit, 7–8 of
  16 titles turning over.
- **TV shows at their broadcast slot.** Followed shows are matched to TVmaze; a season whose every
  episode TVmaze times is read at real instants, the whole show in one calendar. The Simpsons
  (Sun 8 PM ET) reads Monday 5:30 AM in India, Taskmaster (Thu 9:05 PM UK) Friday 2:35 AM.
  Streaming drops stay dates. The show page's foot credits TVmaze.
- **Anime times** are still the Japanese TV broadcast (AniList); streaming times need the owner's
  AnimeSchedule.net token (`ANIMESCHEDULE_TOKEN`), not wired yet.
- **The show-page scroll bug** did not reproduce in about a dozen scenarios on the simulator; the
  owner's steps or a recording are needed.

## Release

- **Backend:** activated 14:33:20 UTC — see [the backend release record](../../qa/2026-10-23/backend-release/README.md).
- **Dependency patch:** `fastify` 5.12.7 and `ip-address` 10.7.4 (commit `6647665`), production audit 0,
  activated 15:06:23 UTC — see [the dependency release record](../../qa/2026-10-23/dependency-release/README.md).
- **iOS 1.0 (23):** archived with the release Xcode (`APIBaseURL` `https://anime.cognipin.com`,
  the live Clerk key, team YLPZXZS2F4) and **uploaded from the CLI** — `xcodebuild -exportArchive`
  with `ios/ExportOptions-upload.plist` ended "Upload succeeded." / `** EXPORT SUCCEEDED **` at
  14:39 UTC. The Organizer was not used: Xcode was behind a Screen Time limit, and the CLI path,
  which failed for builds 16 and 18, worked this time. Build 22 stays in App Review; build 23 was not
  attached to any submission.

## Evening: streaming drop times, and Home's "Aired today" (build 24)

The owner: "in the Home shows Aired today for Seven Havens but shows correctly that the Episode 7
Airs today. Time is also not provided. Why is there no time man?", then, of a Trakt integration,
"ditch Trakt for now please. Let's have platform specific table."

- **Home agreed with the show page.** Home's airing rule read a date-only drop as out the moment its
  synthesized 17:00 UTC passed — before its day had ended anywhere — while the show page counts a
  date only once the day is over. Home now uses the show page's rule (`AppModel.swift`).
- **A platform table for streaming drops** (`server/src/services/streamingDrops.ts`). TMDB has no
  clock for a streaming release and TVmaze leaves a web channel's airtime blank, so the server now
  reads a season whose first network is Netflix or Prime Video at 12:00 AM Pacific, and Paramount+
  at 3:00 AM Eastern (DST-aware), as `timesExact` with `timesSource: "platform"`. These are each
  platform's reported convention for its originals, not per-episode data: a premiere moved to the
  evening before shows later than the platform, never earlier. Apple TV, Disney+, HBO Max, Hulu and
  Peacock have no single convention and stay dates. Avatar: Seven Havens now reads "Airs 30 Oct at
  12:30 PM" in India; Episodes 7–9 struck at 07:00 UTC on 23 Oct.
- **The server agrees to the minute.** Those instants come before the date-only strike (10:00 UTC),
  so the slot rule takes the season's networks and strikes at the earlier of the two; every
  aired-rule read (the gate, the progress clamp, the import) now selects `media.studios`. Checked on
  the scratch copy: Avatar's count goes from 6 to 9 at exactly 07:00 UTC.
- **Credit.** Only TVmaze's times carry "Air times from TVmaze" (`Franchise.timesFromTVmaze`); a
  build 23 client against this server credits TVmaze for a platform time too (harmless, fixed in 24).
- Verified: server typecheck, 1,365 unit tests (the Clerk-migration file timed out once under a load
  average of 237 and passed alone); scratch server + QA simulator (Home's lead card "Episode 7 ·
  Aired 9h ago"; the show page's rows "Aired today" and "Airs 30 Oct at 12:30 PM").
- **Release.** Backend activated 16:04:57 UTC from `5a66b82` — see [the drop-times release
  record](../../qa/2026-10-23/drops-release/README.md). iOS 1.0 (24) archived with the release
  Xcode (`APIBaseURL` `https://anime.cognipin.com`, the live Clerk key) and uploaded from the CLI
  ("Upload succeeded." / `** EXPORT SUCCEEDED **`, 16:18 UTC). Build 22 stays in App Review; build
  24 was not attached to any submission.
