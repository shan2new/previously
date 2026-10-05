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

The reviewed correction is prepared for iOS 1.0 (12). Release evidence is recorded below
once the archive and upload complete.

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
