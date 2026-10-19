# The calm show page (20 Oct 2026)

> "The details section is heavily crammed. It needs to be beautiful, polished yet easy to use
> everyday and not overloaded." — owner
>
> "The hidden cards feel so utterly ugly, yuck… The details part is just shit as if no attention
> has been paid to it at all!" — owner, the same morning
>
> "Nice but invert it. Also the genres UX is poorly built. Direction isn't totally bad but build it
> abysmal." — owner, of the first figures and the tag capsules

Captured on the iOS 27 simulator (Debug) against the local scratch server (`previously_directions_scratch`,
a 17 Oct copy of production), signed in as the owner's account. Left of each pair is the page as it
shipped in build 21 (`-detailCalm 0` still draws it); right is the calm page.

1. `1-bleach-before-after.jpg` — Bleach, one episode behind: the stage, then Episodes. The episode
   you are up to (9, NEW) sat under eight watched rows and the tab bar, a screen and a half down; it
   now opens under one "Episodes 1–7 watched" row with 8 (the one-tap undo) above it and 10, dated,
   below. The stage loses "Episode 10 airs Monday at 7:30 PM" (the list's row says it), and its
   season row no longer sits half under the floating bar.
2. `2-finished-before-after.jpg` — Re:ZERO and Stranger Things, finished: a season watched through
   is one row ("All 19 episodes watched"); a tap lays it out.
3. `3-airing-backlog-planned.jpg` — Black Clover (airing: the next airing's row, then "Show 8 more
   episodes"), Game of Thrones before/after (the season row's "Mark all 3 episodes as watched…"
   is gone — the `···` menu and a ring further down do it), Percy Jackson (not started: five rows,
   then the door).
4. `4-about-before-after.jpg` — About: the labelled table (Type / Genres / Themes / Seasons / Next
   episode, a hairline under each) becomes the FIGURES — premiered, seasons, episodes, rated; word
   over figure, Profile's counts — and the GENRES as Discover's own tiles (the genre's duotone art in
   the show's flavour), one scrolling line, each opening that genre's page in the viewer's scope.
   Themes and the next airing leave About.
5. `5-hidden-tiles-before-after.jpg` — the spoiler-withheld stills: a flat brown box with an
   `eye.slash` four times down a season, then the episode's own still frosted into a field of its
   colours under its number, each exposed to one lightness so the numeral reads on all of them.

Second pass, the same day ("Not horizontally centered yet… aligned to nothing", "the Genre cards
look poorly built", "more space between the genres and the Cast & Crew", "Mark as Watched CTA and
Watching CTAs don't have the same core dimensions", "it takes a lot of time before the hero image
becomes visible", owner):

6. `6-refined-stage-about.jpg` — The Witcher's About before/after the pass, then the stage's pills
   on The Witcher (watching) and Re:ZERO (finished).
7. `7-figures-genres-detail.jpg` — the figures JUSTIFIED (the first starts on the gutter, the last
   ends on it, the rules midway), the genre cards rebuilt (`ShowGenreCard`: the art held down under
   the canvas, a lit edge, a cast shadow, a 15-pt name), a chapter's air before Cast & crew.
8. `8-stage-pills-detail.jpg` — one pill geometry (`StagePillLabel`, 40 pt): the status a fill of
   the page's light with a lit edge, not an outline beside a fill.

The picture: the probe (`-perfProbe 1`, the new `billboard-art` mark) put 0.5–0.8 s of main-thread
stalls between the push and the picture on BOTH pages — every section was built in the stage's
frames. The sections are now built a beat after the lockup arrives (below the fold at rest; a route
to an episode, an index tap or a capture builds them at once). Warm launches onto The Witcher, Debug,
simulator: the picture at 1.45–1.49 s, from 1.61–1.68 s (build 21's page) and 1.82–1.85 s (the calm
page before this pass). A device is the honest clock.

9. `9-stage-one-action.jpg` — the status pill gone ("Why do we need watching dropdown here?",
   owner): one centred action (The Witcher, Thrones — PAUSED on its badge —, Re:ZERO's Start
   rewatch, Bleach). The status is the `···` menu's first row.

10. `10-show-sheet.jpg` — the `···` rethought ("It feels like a SaaS app from early 2000s not a
    consumer app UX… rethought from the ground up", owner): the show's own sheet, not the system
    menu. Game of Thrones (paused), Re:ZERO (finished), Severance (not in the library).
11. `11-sheet-first-build-vs-rebuilt.jpg` — the first build ("Brilliant direction, absolutely
    trashy implementation", owner: bordered tiles and an amber slab, a 17-pt name on flat brown,
    orphaned red Remove, dead space) beside the rebuild: the show's picture at the crown, five
    discs in one glyph family, one list of actions in round wells, Remove the last row.

12. `12-show-sheet-polished.jpg` — the polish pass ("Polish it further please!", owner): the crown
    lifted so the sheet wears the show (Bleach red, Re:ZERO steel, Severance green — it read as a
    black vignette with a red rim); Start over drawn as skip-to-start (Tabler `player-skip-back`,
    `backward.end`) — the rotate arrow read as a capital G; the play triangle nudged to its optical
    centre; one episode named and marked as the stage marks it (no "Mark 1 episode as watched?"
    alert, its Undo in the lane); a show you do not own says what its discs do.

Where it lives: `FranchiseDetailView.calm` (the switch), `EpisodeList.folds` / `foldWindow`
(DetailSupport.swift), `WithheldStillTile`, `ShowAboutFacts`, `ShowGenres` (Discover's genre keys,
mirrored from `server/src/discover/genres.ts`), `ShowGenreShelf`, `ShowGenreCard`, `StagePillLabel`, `stageBadge`, `DetailPush.genre`, `sectionsLive`, `ShowActionsSheet` (+ `actionsSheet`, `sheetProgress`, `sheetMore`, `sheetUndo`).

Not checked: the accessibility text sizes, VoiceOver, a real device.
