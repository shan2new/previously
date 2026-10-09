# The show page, 9 October 2026 — diagnosis and direction

Owner: "the Franchise details UX is absolutely shit and disconnected with the rest of the amazing
app experience. Think about it first before we proceed to changes."

Photographed on a fresh iPhone 14 Pro simulator (iOS 27) against the read-only library snapshot of
2 October (`design/artwork-2026-10-02/preview-server.py` on loopback 18789, Debug build with
`API_BASE_URL=http://127.0.0.1:18789`, blank Clerk key, `-previously.devClerkId preview-local
-openDetail <id> -detailTab <tab>`). Captures are in `captures/`. No production data was touched.

## What the page is today

The X profile of 25 September: a 16:9 landscape banner under the floating back and `···`; an 84-pt
rounded-square face over the banner's foot; the status as X's Follow pill; the name in Outfit Bold
22; an identity line; the synopsis as a three-line bio with "Show more"; a facts row ("5 seasons");
X's counts ("84 Watched   85 Episodes"); four tabs — Posts · Episodes · Media · About — that pin
under the bar; Posts opens on a pinned tweet whose action is the mark.

## What is wrong, measured on the captures

1. **It speaks a different language from the screen it was opened from.** Home shows a show as a
   full-bleed portrait with its logo lit, a state badge, the season bar and the ivory mark pill, on
   a ground of the art's hue. The show's own page shows a cropped landscape slice, a thumbnail of a
   different picture, and the name in plain type. The same show, two vocabularies, one tap apart.
   (`captures/home-2026-10-02.jpg` beside any detail capture.)

2. **The one action is below the fold, on every tab.** On the 14 Pro the fold (above the tab bar)
   lands on the tabs row. Re:ZERO, Watching, one episode behind: on Posts the pinned "Episode 19 is
   out" and its mark pill are off screen; on Episodes the first visible row is Episode 16, a
   watched one, because the window's three context rows come first. A person opens a show they
   are watching and sees a biography.

3. **Four pictures of the show before any content**: the banner, the face, the pinned post's
   avatar, the pinned post's picture — which on Tower of God is the banner again, cropped
   differently (`captures/tower-posts.jpg`).

4. **Two thirds of the screen is static across all four tabs.** Everything above the tabs row is
   the same on Posts, Episodes, Media and About, so each tab shows about 250 pt of its own content
   until the reader scrolls. Media is one trailer card; About is a themes line and the start of a
   cast shelf.

5. **The counts contradict the app's own rule.** "84 Watched   85 Episodes" is X's follower
   grammar; the cohesion rules of 2 September say where-you-are is a `ProgressBar`, never a count
   in words. Episodes then draws the bar anyway — the fact twice, two ways.

6. **Posts is the wrong landing.** For most shows it is a pinned tweet over zero to two posts
   months old (Solo Leveling opens on a July announcement). Tracking is the app's job; news is a
   tab's.

7. **The banner crops the key art and puts the chrome on faces.** Tower of God's heads are cut by
   the status bar; the back and `···` capsules sit on characters. Home's billboard is
   portrait-first and chooses its picture by eye (`PosterPick`) for exactly this reason.

8. **Two "Show more" links in one screen** (the bio's and the first post's) on Solo Leveling.

9. **The face floats alone on its row with the status pill at the far right** — 230 pt of nothing
   between them.

## The direction: Home's billboard, continued

The show page is the show's stage, in the grammar Home already taught: tapping Home's billboard
should feel like stepping into the same picture.

**The billboard.** Home's `HomeBillboard`, generalised: the same `PosterPick` picture
(portrait-fill), the same logo-or-name rule, `HeroTopVeil`, `HeroCopyScrim` landing on the hue,
`HomeGround` behind the page (the page's `showGround` already is), the glow, the pull-to-stretch.
Height: measured from the bar as Home's is, with the first section's title peeking under its foot
(Home's rule), so the two pages share one measure. The lockup, centred:
- the state badge — NEW EPISODE · 2 EPISODES BEHIND · CAUGHT UP · WATCHED · PLANNED · TRENDING
  (the `NextUp` eyebrow the pinned post already computes);
- the logo, else the name in type;
- one line — "Season 4 · Episode 19 · Aired yesterday", a caught-up show's "Episode 20 · Friday at
  7:30 PM", a finished show's "Watched once · 85 episodes";
- the season bar where there is one;
- the ACTION ROW: the ivory pill (Mark Episode 19 as watched · Start watching · Add · Start
  rewatch) and, beside it, the status as a quiet outline capsule ("Watching ⌄", the existing
  status menu). Apple TV's Play + Up Next pair, in the app's own materials.

**Under it, one page, one scroll.** An index row that pins under the bar — Episodes · Trailers ·
About · Posts — and scrolls to its section instead of swapping content (App Store, Apple Music),
the current section underlined as it passes. Nothing above it is static chrome; the header scrolls
away like Home's. Sections, for a tracked show:
1. **Episodes** — exactly today's anatomy: the season pill, the bar between its ends, "Mark all
   N…", the anchored `EpisodeList`, then Movies & extras. It opens with the next episode's row in
   view, which is where a push from Home or Schedule lands without a second screen.
2. **Trailers** — the Media tab's cards as a horizontal shelf of 16:9 cards (31 trailers stacked
   full-width made a page of one kind of thing), each playing in place; full screen only when
   asked for.
3. **About** — the identity line, the synopsis (three lines, "Show more"), the themes, where to
   watch, watch history, Cast & crew, More like this, Because you finished.
4. **Posts** — the show's news from the feed as feed rows; an empty section is one grey line.

For an untracked show (Search, Discover, For you): badge TRENDING or none; the pill is Add (the
chooser); the order is Trailers · About · Episodes · Posts — "what is this?" before "where am I?".

**Removed:** the face on the page (shows wear their face in rows and the feed), the counts line,
the pinned tweet (its content IS the lockup now), the Media tab's full-width stack, the tabs as
content switches.

**Kept:** the hue ground and `DetailVeils`, the docked title, the toolbar `···` with the batch
verbs, the status menu, `EpisodeList` and its rings, the batch confirmations, `TrailerPlayback`,
the rewatch sheet, the feed rows.

**Why not Netflix's title page (rejected 25 Sep) or a re-skin of the profile.** Netflix's page is a
poster-in-a-box with buttons under it; this is the app's own billboard, which the owner has
already approved on Home and on Schedule's card. A re-skinned profile (billboard on top, tabs kept,
Episodes default) is the fallback if the one-scroll page proves wrong in the photographs; it keeps
faults 4 and 6.

## How it will be shown before it ships

Built behind `-detailDirection billboard` (DEBUG) and photographed on the three snapshot shows
(Re:ZERO watching, Solo Leveling and Tower of God finished) plus an untracked one, beside today's
page, before the swap. The billboard is extracted from Home into one shared view first; Home,
Detail and Schedule's card then draw the same thing.

## Built — 9 October 2026

Approved by the owner the same day ("Billboard direction yes") and built as the page, not behind a
flag: `ShowBillboard` extracted from Home (verified pixel-identical on Home's billboard), the page's
lockup on it, the pinned index and the four sections. The X profile stays reachable in DEBUG as
`-detailDirection profile` for side-by-side photographs. Captures of the result are in `captures/`
(`stage-*.jpg`); the same stage now carries Schedule's card (`ScheduleStageCard`) and Home's drops
pager. One correction on the way: a `scrollTo` with a `UnitPoint` anchor applies it to the target's
own height, so section jumps now anchor on a 1-pt marker at each section's top.
