# 20 October 2026 — the calm show page, and the show's own sheet (build 22)

The owner's brief, in order: "the details section is heavily crammed. It's needs to be beautiful,
polished yet easy to use everyday and not overloaded"; "The hidden cards feel so utterly ugly…
The details part is just shit as if no attention has been paid to it at all!"; "Nice but invert
it. Also the genres UX is poorly built"; "Not horizontally centered yet… the Genre cards look
poorly built… more space between the genres and the Cast & Crew… Mark as Watched CTA and Watching
CTAs don't have the same core dimensions… it takes a lot of time before the hero image becomes
visible"; "Why do we need watching dropdown here?"; "We need to rethink the top right dots
experience man… It feels like a SaaS app from early 2000s"; "Brilliant direction, absolutely trashy
implementation"; "Polish it further please!"; and "This is brilliant. Let's ship this!"

## What changed (commit `90794f6`)

- **Episodes fold** on the show page: the watched run is one row, then the last watched episode,
  the one you are up to and up to four after it (one dated airing at most), then "Show N more
  episodes". The next unaired row dates itself from what has aired by now.
- **The stage**: one centred action; the status pill is gone (Paused and Dropped say so on the
  badge); one pill geometry; no cadence line; a height that clears the floating bar. The sections
  under it are built a beat after its picture (the picture lands ~0.2 s sooner than build 21's).
- **About**: figures (premiered · seasons · episodes · rated), justified, word over figure; the
  genres as Discover's art on cards that open each genre's page; air before Cast & crew.
- **Withheld stills**: the episode's own still frosted under its number, at one exposure.
- **`···`** opens `ShowActionsSheet`: the show's picture at the crown, five status discs, worded
  actions with what each changes, the undo rows and Remove from Library last.

Captures and the before/after boards: `design/show-page-2026-10-20/`. Rules: CLAUDE.md, "The show
page is CALM".

## Release

Release archive `ios/build/Previously-22.xcarchive`: 1.0 (22), widget 22, `APIBaseURL`
https://anime.cognipin.com, a `pk_live_` Clerk key, minos 18.0, iOS 27.0 SDK. **Uploaded** 20 Oct
~04:57 IST from the Organizer: "Previously 1.0 (22) uploaded" (`ContentDelivery.log`: UPLOAD
SUCCEEDED with no errors, delivery `3222b1c8-93a3-4c0f-b39c-a6e2af329876`). Not yet confirmed:
App Store Connect's processing, and the build in TestFlight.

## Checks

- `-verifyAnnouncements` (59), `-verifyCopy`, `-verifyDetailProgress` (43), `-verifyFeed`: pass on
  the iOS 27 simulator (Debug).
- `-verifyArtworkIdentity` FAILS at "English logo outranks larger untagged and foreign wordmarks"
  (`Networking/DemoLibrary.swift`). The code it checks (`ArtworkGallery.preferredLogo`, 19 Oct) is
  not touched by this build; not re-run against build 21 to prove it predates this one.
- Not verified: a physical device, the accessibility text sizes, VoiceOver.
