# Home navigation and seam review — 5 October 2026

The user reported that the improved Home navigation and seams appeared reverted on the
TestFlight iPhone app. After reviewing the before-and-after captures, they authorized the
commit, push and TestFlight release on 5 October 2026.

## Finding

The CTA release did not revert Home or its shared chrome. Nine relevant source files are
byte-identical between build 10's `53e4ab7` and build 11's `9d15b1b`; see
`source-comparison.json`. The 4 October Home, artwork, gradient, and scroll-away changes
remain in both. RootView's only CTA-release change was a routing comment.

A remaining seam is reproducible in both builds: the background under the bottom navigation
repeated `HomeGround`, but omitted the title's additional glow extending beyond the billboard.
It therefore met a brighter page with a darker horizontal edge. This was an incomplete earlier
repair, rather than a source rollback in the CTA release.

## Approved correction

`HomeLockupGlow` now draws the same glow for the billboard and both bar backgrounds. Its measured
title height and arrival state are shared through `HomeChrome`. The existing layout, navigation
geometry, scroll-away logic and Reduce Motion handling are retained.

The reviewed correction is included in iOS 1.0 (12). Release evidence is recorded below.

## Visual evidence

Open `comparison.html` for the current-versus-proposed comparison and the build 10 reference.
All PNGs are unedited native simulator captures at 1179 × 2556 pixels. Images named build10
and build11 are Debug simulator rebuilds of those releases' source, not captures from the
physical TestFlight app. The proposal uses build 11 source with the local Home correction.

Both releases were rendered on the same QA iPhone 14 Pro, iOS 27, with the same existing read-only
library snapshot, cached artwork, Black Clover hero and 9:41 status bar. Artwork has an existing
idle drift, so image position can vary slightly between captures. Recently aired was reached
with the existing `homeAnchor` launch argument; this is not proof of a finger-driven scroll.

At the center of the navigation's upper edge, native pixel (590,2360) was RGB (40,15,7)
immediately above RGB (31,10,4) in both build 10 and build 11. In the local correction the
two pixels are both RGB (40,15,7), including after opening details and reselecting Home.
Full measurements are in `seam-measurements.json`.

## Checks and limitations

- Exact pre-CTA source and local proposal both built successfully for the simulator.
- Home at rest, Recently aired, and details → Home return were inspected.
- `git diff --check` passed.
- Native Mac TestFlight now shows 1.0 (11) available with Install enabled.
- Physical iPhone Mirroring timed out. The user's installed iPhone build and its rendering
  were not directly inspected. Native simulator scroll injection also failed, so physical
  scroll-away behavior remains unverified; its implementation is unchanged by this proposal.
- Preview API on loopback 18791 serves the existing snapshot and refuses application writes.
  No production library data was changed.

Local build logs and extra return-navigation capture are in ignored `ios/build/home-nav-review/`.

## Release — 1.0 (12)

- Implementation commit `57ae71f3257e21b48d44b5ff8813a2e7c7f0f2cd` pushed to `origin/main`.
- Signed Release archive succeeded at `ios/build/Previously-12.xcarchive`.
- App `com.cognipin.previously` and widget `com.cognipin.previously.widgets` both report 1.0 (12),
  minimum iOS 18. Strict deep code-signature verification passed.
- Archived API is `https://anime.cognipin.com`; the configured Clerk key is present and snapshot
  overrides are absent. No backend deployment was required.
- Archived app executable SHA-256:
  `d94696b72f65ad3314402bc7e3a7e2244ce9e01753e0060416e1a69c07ccfe84`.
- Existing Xcode account and `ExportOptions-upload.plist` uploaded the archive. At **10:25:43 IST
  on 5 October 2026**, Apple reported `Upload succeeded.` and `EXPORT SUCCEEDED`, with the package
  processing. Logs: `ios/build/archive-12.log` and `ios/build/upload-12.log`.
- The signed-in native TestFlight app subsequently showed **Previously. → Version 1.0 (12)**
  with an enabled **Install** button, size **27.5 MB**, release date **5 October 2026**, expiring
  **3 January 2027 at 10:27 AM**. This confirms processing completed and the build is available
  to the existing tester account. Installation on the physical iPhone is not claimed.
