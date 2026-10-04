# First run — the spike (4 Oct 2026)

How TV, anime and film trackers (and the streaming apps) onboard a new user in 2025–26, what users
complain about, and what Previously.'s first run takes from it. Every claim carries its source;
vendor benchmarks were dropped; "could not verify" is a finding.

## Key findings

1. **TV Time is gone, and importing its export became 2026's first-run feature.** The shutdown was
   announced in-app around 3 Jul 2026 and the service ended 15 Jul 2026 with data deleted; it had
   26.4M lifetime installs, and a GDPR zip was the only way out
   ([TechCrunch](https://techcrunch.com/2026/07/02/popular-tv-tracking-app-tv-time-is-shutting-down-as-company-focuses-on-ai/),
   [AlternativeTo](https://alternativeto.net/news/2026/7/tv-time-is-shutting-down-its-service-on-july-15-2026-here-are-some-great-replacements/)).
2. **Importers buckled.** Forum users reported Serializd taking 20k+ users overnight and Simkl
   temporarily limiting zip import to premium
   ([ResetEra](https://www.resetera.com/threads/tv-time-is-shutting-down-july-15th.1566721/)).
3. **Fidelity is the complaint, not availability.** Trakt users report missing episodes, no
   rewatches, and finished series left half-marked
   ([Trakt forum](https://forums.trakt.tv/t/tv-time-import-missing-episodes-rewatches-questions-about-the-recommended-export/114469)).
4. **Most trackers put the account wall first.** Exceptions: Sequel needs no account and syncs by
   iCloud ([App Store](https://apps.apple.com/us/app/sequel-media-tracker/id1630746993)); JustWatch
   browses without one ([Cloudwards, Feb 2026](https://www.cloudwards.net/how-to-use-justwatch/)).
5. **Taste pickers are rare and small in trackers.** Letterboxd asks for four favourites
   ([guide, Mar 2026](https://www.themycenaean.org/2026/03/a-guide-to-using-letterboxd/)). Hobi
   forces three shows and then several profile screens, which a reviewer resented
   ([JustUseApp](https://justuseapp.com/en/app/1387915223/hobi-tv-shows-tracker-trakt/reviews)).
6. **Netflix's picker is optional and decays**: skipping gives a popular, diverse set, and later
   viewing supersedes the picks ([Netflix Help](https://help.netflix.com/en/node/100639)).
7. **Spotify is the only picker with first-party numbers.** Removing onboarding signals cut
   nDCG@50 by 13.8% on onboarding-aligned clusters; cold-start accuracy rose 5% in the first four
   hours ([Spotify Research, Sep 2025](https://research.atspotify.com/2025/9/generalized-user-representations-for-large-scale-recommendations)).
   No credible completion or retention data exists for any other picker.
8. **Importing a graph can hurt.** Threads dropped its follow-everyone-from-Instagram step after a
   multi-country holdout used Threads more without it
   ([Mosseri, 13 Nov 2024](https://www.threads.com/@mosseri/post/DCVpqaKJ4-A)).
9. **Apple HIG on onboarding:** "design a flow that's fast, fun, and optional." Postpone
   non-essential setup behind sensible defaults, teach by doing, prefer tips in context, never
   re-show a skipped tutorial ([HIG Onboarding](https://developer.apple.com/design/human-interface-guidelines/onboarding)).
10. **Apple HIG on permissions:** avoid asking at launch unless the app cannot function without
    it; a custom pre-alert screen gets exactly one button that opens the system alert
    ([HIG Privacy](https://developer.apple.com/design/human-interface-guidelines/privacy),
    [HIG Managing notifications](https://developer.apple.com/design/human-interface-guidelines/managing-notifications)).
11. **Independent evidence favours asking after a user action.** Android's guidance: trigger from
    an action such as an alert bell or a follow
    ([Android](https://developer.android.com/develop/ui/compose/notifications/notification-permission)).
    Mozilla telemetry (2019, web, older): ~99% of unsolicited prompts went unaccepted; with a
    required gesture, new users accepted 56%
    ([Mozilla](https://blog.mozilla.org/futurereleases/2019/11/04/restricting-notification-permission-prompts-in-firefox/)).
    CHI 2014 (iOS, n=772, older): explanations raise approval
    ([ACM](https://dl.acm.org/doi/abs/10.1145/2556288.2557400)). No independent iOS dataset on
    primers was found.
12. **Tutorials do not help** (NN/g, 2020, older): tutorial readers rated tasks harder with no
    success gain ([NN/g](https://www.nngroup.com/articles/mobile-tutorials/)); content
    customisation is the one justified onboarding type
    ([NN/g](https://www.nngroup.com/articles/mobile-app-onboarding/)).
13. **Deferred sign-up:** Duolingo moved sign-up behind the first lesson for about +20% DAU
    (first-party via [First Round](https://review.firstround.com/the-tenets-of-a-b-testing-from-duolingos-master-growth-hacker/), 2017, older).

## Per-app first run

| App | Account wall | Steps | Taste picker | Import | Source |
|---|---|---|---|---|---|
| Trakt | First | v3 screens unverified | Genres + a few watched titles (2018, older) | TV Time zip, IMDb, Letterboxd, Plex | [forum](https://forums.trakt.tv/t/how-to-import-your-tv-time-data-into-trakt/114178) |
| Letterboxd | First | Account, four favourites, avatar and bio | 4 films, search | Web only: IMDb or CSV | [import](https://letterboxd.com/about/importing-data/) |
| Simkl | First | Sign up, profile and timezone, search, add | None found | 20+ sources, post-sign-up | [docs](https://docs.simkl.org/how-to-use-simkl/getting-started-with-simkl/quick-start-guide) |
| Hobi | First | Pick shows, then profile screens | Minimum 3 shows | TV Time file; Trakt two-way | [reviews](https://justuseapp.com/en/app/1387915223/hobi-tv-shows-tracker-trakt/reviews) |
| Sequel | None | Unverified | None found | TV Time, Letterboxd, IMDb, Simkl | [App Store](https://apps.apple.com/us/app/sequel-media-tracker/id1630746993) |
| Bingers | Unverified | Unverified | n/a | TV Time archive on the web, before the app | [TechCrunch](https://techcrunch.com/2026/07/13/as-tv-tracking-app-tv-time-shuts-down-its-founder-builds-bingers-a-new-home-for-fans/) |
| Netflix | First, with payment | Email, plan, picker | A few titles, optional | n/a | [Help](https://help.netflix.com/en/node/100639) |
| JustWatch | Optional | Pick services, Done, browse | Service picker | n/a | [Cloudwards](https://www.cloudwards.net/how-to-use-justwatch/) |
| Spotify | First | 21 screens, ~2 min 11 s (2022, older) | Artists, min 3 | n/a | [Pageflows](https://pageflows.com/post/ios/onboarding/spotify/) |

Not verifiable from a primary source: Apple TV (iOS 26), Disney+, Plex, Crunchyroll, MyAnimeList,
Serializd, Showly, the Trakt v3 app. Reddit was closed to the crawler; forums, App Store reviews,
Trustpilot and ResetEra stand in.

## What users complain about

- **Hobi:** forced to pick three shows, then profile screens.
- **Trakt import:** rewatches not imported; episodes re-marked by hand; imported data not counted
  as history. **Trakt paywall:** $60 a year, free caps of 250 watchlist items and 5 lists
  ([Trakt](https://forums.trakt.tv/t/updating-trakt-limits-for-2026/101592)).
- **Serializd:** no calendar or upcoming episodes; stats wrong after bulk-marking.
- **Migration generally:** people did not know where or how to switch.

## What Previously.'s first run takes from it

| Finding | Decision |
|---|---|
| Tutorials do not help; customisation is the one justified onboarding (12) | No explainer screens. Four questions; each one changes what the app shows next. |
| A forced minimum is resented (5); Netflix's picker is optional (6) | Nothing is required: the picker says "Skip for now" with none picked, the questions about each show have Skip, and the empty Home offers the picker again. |
| Recognition seeds taste (7) | The picker leads with the catalogue's best-known shows (`GET /franchises/starter`, ranked by popularity), not the season's chart. |
| Hand re-marking and half-marked histories are the migration complaint (3) | "Where are you?" — one tap per show: caught up (every released episode and the story's films), part-way (an episode dial; earlier seasons marked), just starting, or later. |
| Ask for notifications after an action that shows why (10, 11) | Alerts are OFFERED on the last screen, naming the show whose next episode they would announce; the system alert follows a tap on "Turn on" and nothing else. |
| "First open is already populated" is the delight (Bingers, Flighty) | The flow ends on the viewer's own lineup, then lifts off a Home that already holds their shows. |
| Fast, fun, optional (9) | A run with five shows is about fifteen taps. |

## Open, and why

- **Import (implemented 4 Oct):** AniList public username, MAL XML/gzip and TV Time ZIP/CSV now
  share an on-device file reader, async preview, explicit apply and background catalogue fetch.
  First-run and Profile entry points are present. Trakt remains out of scope. TV Time episode
  numbering is approximate and disclosed; rewatch events and TV Time movies are not imported.
  See [the import verification](IMPORT-VERIFICATION.md) and the API contract for the limits.
- **Account wall last (Duolingo, Sequel).** The catalogue routes are authenticated, and search can
  spend an LLM call (the spell-corrector), so a picker before sign-in would need a public,
  rate-limited, search-less catalogue route — a weaker picker for the promise of trying first.
  Sign-in stays first; the question is the owner's.
- **TV's popularity signal.** `media.popularity` for TMDB is the day's popularity (it put "The
  Scandal" above "The Office"); storing `vote_count` would steady the TV picker's order.
