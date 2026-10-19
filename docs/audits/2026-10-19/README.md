# 19 October 2026 — calm roots, Four tabs, Hanken content type, the show page's hierarchy (build 18)

The owner's brief, in order: "I think we have made a mistake making everything immersive in Home and
Schedule screens. In the Details screen it makes total sense… the color bleed is a bit too
shouting"; "News UI looks like utter shit. Coming back UI is also utterly shitty. In schedule I'd
like to see a top calendar too… which works in sync with the list scroll and vice-versa. We
probably need a different set of fonts for the content"; "Ship Hanken Grotesk as the content font
(Outfit stays display)"; "Let's add slight background gradient… anime mode different"; "The details
screens is too busy due to poor visual hierarchy"; "I think Titles should've kept Outfit"; "the
gradience needs more personality without competing with everything"; and "sometimes the logo
becomes too white that it just appears like a white patch in the Hero… The rest is awesome and
ready to ship."

## What changed

- **Calm roots** (`Experience.fourTabs` now draws the Calm language): no full-bleed billboard, no
  page in a picture's hue and no glow on Home or Schedule; the drops lead as Recently aired's cards.
- **News** is a reader's list: a shelf of `NewsCard`s on Home; the News page leads with the newest
  official announcement, then `NewsRow`s by month; actions are the long-press menu's.
- **Schedule**: `ScheduleWeekStrip` under the title, synced with the list both ways; Coming back is
  a poster shelf.
- **Type**: `Typeface` roles; Hanken Grotesk is the content face, Outfit the display and title
  face. A serif set was photographed and rejected.
- **Ground**: `AppGround` — the audience's light as an aurora with film grain and a horizon.
- **Show page**: ground toned to `GroundSpec.quiet`; sections Episodes, About, Trailers, Posts,
  Similar, each headed in the index's word; About's facts as `ShowInfoList`.
- **Logos**: a dark logo is drawn as its luminance negative instead of a flat white silhouette (the
  white patch — ONE PIECE, DAN DA DAN, Jujutsu Kaisen, Percy Jackson and Parasyte in the owner's
  library); a plate logo falls back to type; white logos stand in a shade halo.
- Server (commit `6249602`): the stale-report scan binds its cutoff through the column.

Captures: `design/calm-2026-10-19/`.

## Verification

- Server: `tsc --noEmit` clean; vitest 81 files, 1340 tests passed (Node 24).
- iOS: Debug simulator builds after every step; photographed on "Previously Calm QA" (iPhone 17
  Pro, iOS 27) against the 2 Oct read-only library snapshot, replayed with its timestamps moved
  forward by its age. `-verifyLogos 1` read every library logo (no plates; five dark).
- Release archive `ios/build/Previously-18.xcarchive` (also in Xcode's Organizer, 2026-10-19):
  1.0 (18), widget 18, `APIBaseURL` https://anime.cognipin.com, a `pk_live_` Clerk key, Hanken
  Grotesk and Outfit bundled and registered.
- **Uploaded** 19 Oct 03:16 IST from Xcode's Organizer (Distribute App → App Store Connect):
  "UPLOAD SUCCEEDED with no errors", delivery UUID `0008fcca-4488-4563-938e-fc19f138f642`,
  "Uploaded package is processing" — logs in `ios/build/organizer-upload-18.xcdistributionlogs`.
  The CLI (`xcodebuild -exportArchive` with `ExportOptions-upload.plist`) still fails with "App
  Store Connect access for YLPZXZS2F4 is required" even after signing in to Xcode → Settings →
  Accounts, as on 15 Oct for build 16; the Organizer, with the same account, uploads. Build 17
  was archived on 15 Oct and copied to the Organizer; whether it was uploaded is not recorded, so
  this build is 18.
- Not yet confirmed: App Store Connect's processing, and the build showing up in TestFlight for
  the testers.
- Not verified: a physical device, VoiceOver and the accessibility text sizes on the new screens,
  the week strip's sync on a long real week, the type sets on a device.

## Build 19 — the same evening

The owner opened build 18 on a caught-up account: "What the actual fuck is this trash UX? All of
it?… this is the first thing a person opens up and is greeted with overwhelm". Rebuilt on the sim
in rounds with the owner (captures 15–25 in `design/calm-2026-10-19/`, decisions in CLAUDE.md):

- **Home, caught up:** today's airing only, as one card (the scene, the logo, the episode, the time
  on a Netflix-style red strip); with nothing today, the caught-up moment instead. News on Home is
  today's latest update or nothing; For you is one shelf of 112-pt posters.
- **The tab bar** floats as a small pill on native Liquid Glass (a black pill was built and
  photographed beside it; the owner chose glass). The search fields are the same glass.
- **Bars** leave on a reader's scroll and return only on a scroll up; the end-of-page spring no
  longer brings them back. Discover's header fades as it slides and has no account control.
- **The header's account** is a glyph: the photo, else an Outfit initial in a ring, else a user
  silhouette (never the "Y" of "Your account").

Commit `f5fd9d4`. Release archive `ios/build/Previously-19.xcarchive`: 1.0 (19), widget 19,
`APIBaseURL` https://anime.cognipin.com, a `pk_live_` Clerk key, Hanken Grotesk and Outfit
registered. **Uploaded** 19 Oct 05:31 IST from Xcode's Organizer (Distribute App → App Store
Connect): "UPLOAD SUCCEEDED with no errors", delivery UUID `336bb83a-81ba-4f9b-a1a1-926242ff0ee7`,
"Uploaded package is processing" — logs in `ios/build/organizer-upload-19.xcdistributionlogs`.
The CLI export still sees no accounts and no distribution certificate, so the Organizer remains
the only upload path. Another session's Kestrel upload had the Organizer's distribution sheet
open first; it finished before this one started.

- Not yet confirmed: App Store Connect's processing, and build 19 in TestFlight for the testers.
- Not verified: a physical device; the Liquid Glass bar and fields on iOS 18 (the material
  fallback) and under Reduce Transparency; an account photo in the header glyph (the sim's
  account has none). Known gap: on a day with no news, the News page has no door.

## Builds 20 and 21 — the late evening

The owner went screen by screen on the simulator (decisions in CLAUDE.md, captures in
`design/schedule-faces-2026-10-19/`, `design/profile-2026-10-19/`, `design/library-2026-10-19/`):

- **Build 20** (commit `95e990f`): Discover (hugging top-pick pills, "Add" not "Add…", chart type
  scale, header fade, a dead-tab pager bug, three-title shelves); Home (a focus carousel of drops
  and today's airing, "Your next binge", a flat red NEW tag); the show page (a three-section index,
  a compact watch line with the JustWatch credit at the foot, flat badges, zoomed cast photos, the
  NOS4A2 plate logo); Schedule (the poster face with three baseline-aligned lines, week eyebrows,
  calmer amber, "in 36 minutes", "All day", title-menu filters); Profile rebuilt with a wall of
  your shows. **Uploaded** from the Organizer: "Previously 1.0 (20) uploaded".
- **Build 21** (commit `9cd643b`): the Library rebuilt as one screen — a Now-watching carousel and
  three fanned stacks of your shelves. Release archive 1.0 (21), widget 21, `APIBaseURL`
  https://anime.cognipin.com, a `pk_live_` Clerk key. **Uploaded** 19 Oct ~20:40 IST from the
  Organizer: "Previously 1.0 (21) uploaded".

- Not yet confirmed: App Store Connect's processing of 20 and 21, and either in TestFlight.
- Not verified: a physical device; both builds were checked on the iOS 27 simulator only.
- Not pushed: `main` is ahead of `origin/main` by these commits.
