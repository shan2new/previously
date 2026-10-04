# Franchise detail CTA consistency — 4 October 2026

## Behavior

Every show opens at its profile header with Posts selected. Home and Schedule retain episode
context for the Episodes tab without automatically scrolling past the header or pushing a second
screen. Library, Search, recommendations, feed posts, related titles and genre results reuse the
same detail view.

Generic Add actions in Search, Trending and Feed open the same chooser as Add to Library on the
show page. The answers are Add to Planned, Start/Continue watching, part-way through (when there
are episodes to choose), and a counted caught-up action (when marks remain). Unreleased shows
can be saved to Planned. Recommendation-cache membership does not choose the action or change
the header's label. Explicitly labelled Add to Planned recommendation shortcuts still do exactly
that. Pending subscription writes show Adding rather than an inferred status.

More actions stays in the toolbar at every scroll position. Its season commands and the pinned
post use one builder. On Episodes, the toolbar targets the selected season; batch confirmations
name the show, season and count. Planned shows expose the same batch controls as other tracked
shows. Untracked extras cannot write through their season overflow menu. Status changes remain
separate from marking episode progress; batch confirmations and Undo are preserved.

An Add requested from another screen survives a failed detail read so Retry can present it.
Leaving the detail page cancels that pending request.

## Verification

- Final Debug simulator build succeeded: Previously scheme, iOS 18 deployment target, Previously
  QA iPhone 14 Pro (`F3AD17A6-813D-4C7E-8263-6383F952302C`), iOS 27 runtime.
- Native regression harness: 43 progress checks, 59 announcement checks, feed regression suite,
  and copy audit passed. Progress and copy checks were rerun on the final source.
- Device Hub walkthrough against `fixture-server.py`, with API `http://127.0.0.1:8809` and blank
  Clerk key. Fixtures use in-memory state only, no database or upstream calls.
- Home and Library opened the same Watching show with the same header, status, Posts selection
  and next-episode sentence. Schedule's future-episode link likewise stayed at the common header.
- An ordinary finished show and a recommended show both displayed the same four Add choices.
  Cancel issued no write. Add to Planned issued one subscription with `status: planned`, with
  both seasons still at zero.
- Search's Add on a finished show opened the chooser. Start watching issued `status: watching`
  and left both seasons at zero.
- Part-way through → Season 2 wrote Season 1's 12 episodes only, retained Season 2 at zero,
  and selected Season 2. A fixture response initially omitted required response fields; correcting
  the harness and using the app's Retry cleared the failure and confirmed the persisted state.
- An unreleased show offered only Add to Planned and Cancel, with no progress-writing option.
- Caught up on an airing 12-episode show wrote only the eight released episodes, status Watching.
- A Planned show's Episodes tab exposed the batch action. Selecting Season 2 changed its count
  from 12 to 8. The final confirmation read `CTA Finished · Season 1. Your progress will move
  from episode 0 to episode 12.` Cancel preserved progress.

The shared toolbar and Feed wiring were also source-reviewed. The simulator automation did not
expose the navigation bar's controls for direct AX activation; this is not a claim that every
menu item was tapped. No physical-iPhone installation or VoiceOver walkthrough is claimed.
The compiler still emits existing concurrency warnings outside the changed behavior.

Local ignored evidence: `ios/build/cta-simulator-final.log`, `cta-runtime.log`,
`cta-runtime-final.log`, `cta-fixture.log`, and `cta-state.json`.

## Release — 1.0 (11)

- Implementation commit `d1951411a0cc4236cb71e22fac9aa5946b53a065` pushed to `origin/main`.
- Signed Release archive succeeded at `ios/build/Previously-11.xcarchive`.
- App `com.cognipin.previously` and widget `com.cognipin.previously.widgets` both report 1.0 (11),
  minimum iOS 18. Strict deep code-signature verification passed.
- Archived API is `https://anime.cognipin.com`; the configured Clerk key is present and fixture
  overrides are absent. No backend deployment was needed.
- Existing `ExportOptions-upload.plist` and Xcode account uploaded the archive. At **21:25:47 IST
  on 4 October 2026**, Apple reported `Upload succeeded.` and `EXPORT SUCCEEDED`, with the package
  processing. Logs: `ios/build/archive-11.log` and `ios/build/upload-11.log`.
- The native TestFlight app showed 1.0 (10) before upload. The post-upload availability check was
  blocked when the Mac locked and automatic unlock failed; build 11's tester availability is
  not yet verified. The user was asked to unlock the Mac for this final check.
- The isolated fixture server was stopped. The QA simulator was restored to the final build 11
  Debug app with production API/auth configuration, verified from its installed build source.
