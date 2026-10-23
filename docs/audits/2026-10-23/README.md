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
