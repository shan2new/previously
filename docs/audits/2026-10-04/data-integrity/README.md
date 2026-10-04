# Data integrity audit — 4 October 2026

The Boys incident exposed a broader failure: the app could turn related-series news, generic catalogue statuses, missing dates, or stale observations into confident current facts. This audit repaired the live records and the shared rules that produced them. It did not publish a new iOS release or push repository changes.

## Coverage and evidence

- Inspected all **1,320 franchises** and their **4,671 original member parts**.
- Requested all **720 TMDB series**: **713 returned**, seven were unavailable. Provider responses and original part state are in `catalogue-audit.json`.
- Refetched all **2,216 materialized AniList entries**, with no missing entries. Paced the requests below 30/minute. Full before/after evidence is `/tmp/previously-anime-integrity.json`.
- Inspected **370 stored upcoming facts**, including **213 inferred renewals** whose only basis was a generic TMDB Returning Series flag.
- Probed all **99 stored non-catalogue primary URLs**. 88 returned HTTP 200; 11 returned another status or redirect. Some 200 responses were generic news indexes. Availability is not semantic verification. `source-audit.json` records each outcome.
- Manually reviewed the suspect identity, status, naming and date claims against catalogue evidence and broadcaster/production sources. The audit does not assert independent semantic verification of every sentence in all 99 research records.

## Live repairs

The main correction transaction updated **303 franchise facts**. Its exact before/after plan is `repair-plan.json`, and its receipt is `repair-result.json`. It included **22 editorial corrections**, temporal retirement of stale claims, and recomputation of catalogue-derived facts without inventing future seasons. A further source correction replaced an invalid Crunchyroll article path with the official production site.

**Nine false announcement records were retracted.** Their observations remain inspectable. Retractions suppress the live feed, saved-post resolution, catalogue-thread adoption and associated news notifications. No notification fan-out, personal progress changes, or deletion of user records was performed by these repair scripts.

A second pass refreshed **eight TV shows**, attaching **ten real provider-listed parts** missing locally. A full read-path audit then caught two duplicate Season 1 labels; provider evidence confirmed Witch Hat Atelier Season 2 and Nippon Sangoku (Zoku-hen), and both labels were corrected. A recent, incomplete Totally Spies! run with a missing next date was corrected from finished to releasing.

Across the main transaction, distinct factual media changes were:

| Provider | Changed records | Changed fields |
| --- | ---: | --- |
| TMDB | 1,715 | 1,665 last-aired timestamps; 64 statuses; 34 episode totals; 24 next slots |
| AniList | 506 | 503 episode metadata lists; 2 statuses; 2 episode totals; 3 next slots |

Field counts overlap. The raw transaction updated 3,720 rows: additional rows only differed in JSON key order or bigint string/number representation and are **not counted as factual corrections** above. `factual-change-counts.json` records the normalized comparison. Follow-up refreshes and the one additional status correction are separate from that table.

The main transaction's rollback snapshot, containing catalogue records and announcements but no user accounts or progress, is `/tmp/previously-integrity-backup-1791104297654/before.json`. Supplementary changes have their own before/after evidence files here. The repair scripts are audit-specific, default to dry-run where applicable, and must not be treated as an unattended recurring job.

## Confirmed examples and sources

- **The Boys:** concluded May 20, 2026. Vought Rising is a separate prequel. [Amazon](https://www.aboutamazon.com/news/entertainment/the-boys-eric-kripke-season-5-prime-video).
- **Game of Thrones:** the original series ended with Season 8; separate sequel development is not a renewal. Its old research URL returned 404. [Sky's final-series announcement](https://www.skygroup.sky/en-gb/article/eighth-and-final-series-of-game-of-thrones-breaks-records-for-sky-atlantic).
- **The Big Bang Theory:** removed Stuart Fails to Save the Universe from the parent's airing claim; it is a separately titled show. [WBD series page](https://press.wbd.com/us/na/property/stuart-fails-save-universe), [parent catalogue](https://www.themoviedb.org/tv/1418).
- **ted:** removed Ted: The Animated Series from the live-action show's next installment. [Peacock identifies the animated spin-off](https://www.peacocktv.com/blog/meet-the-cast-ted-animated-series), [live-action catalogue](https://www.themoviedb.org/tv/201834).
- **The Traitors India:** Irish RTÉ research was attached to the Indian Prime Video adaptation. Retracted the wrong-country claim. [Amazon India](https://www.aboutamazon.in/news/entertainment/the-traitors-prime-video-reality-show).
- **Hunter x Hunter (2011), Mayday, Tower of God and Overlord:** withdrew renewal claims not substantiated by their stored evidence. A game opening, a spin-off article, or an unrelated catalogue page cannot verify a new season.
- **Hell's Paradise, M, ChäoS;HEAd, Juju Sanpo, Seven Mortal Sins, T-sensei and The Big Boss:** withdrew unsupported conclusions. A season finale, failure to identify a title, or absence of renewal news does not establish that a series has ended.
- **Detective Conan:** withdrew the asserted April 2027 Movie 30 window because the stored supporting trade articles concerned other projects and the specific claim depended on a fan wiki/account. This is a withdrawal of unsupported certainty, not a finding that a 30th movie will not happen.
- **The Witcher:** retained the confirmed final-season renewal but removed an unconfirmed 2027 delay window. [Netflix renewal](https://about.netflix.com/en/news/the-witcher-season-4-begins-production-in-the-uk-and-netflix-announces-fifth).
- **Stuart Fails to Save the Universe:** retained Season 2; replaced a hoped-for fall 2027 premiere with TBA.
- **Mushoku Tensei:** corrected “Season 6” to **Season 3 Part 2**, preserving the reported 2027 window. The old name counted individual cours as seasons.
- **Kaiju No. 8:** uses **Final Chapter**, as announced, without inventing a numbered-season designation. [Official announcement](https://kaiju-no8.net/news/detail_251220_01.html).
- **Though I Am an Inept Villainess:** verified the January 2027 second-cour window and replaced the generic news-index response with its [official production site](https://futsutsuka.net/en/).
- **Witch Hat Atelier / Nippon Sangoku:** corrected duplicate Season 1 labels using live [AniList 213702](https://anilist.co/anime/213702) and [AniList 216346](https://anilist.co/anime/216346) identity evidence.

## Prevention changes

1. **Catalogue facts:** an actual future season row is required; Returning Series never manufactures max-season + 1. Historic undated seasons are not automatically treated as future. A recent incomplete active run is not considered finished merely because its next date is missing.
2. **Claim lifecycle:** shared read-time reconciliation removes elapsed day/month/quarter/year claims and research about already-aired parts. Unmatched old airing claims expire. Expiry yields current catalogue evidence or unknown, never an invented conclusion.
3. **Identity:** research receives the canonical URL, original title, country, network, premiere, provider status and individual part titles. Separate-series findings are rejected. Numeric part identity and token boundaries prevent Season 1/10 and Season 2/Part 2 collisions. Ambiguous duplicate labels do not silently choose the first part.
4. **Evidence and dates:** publication requires a safe source present in the evidence list, supported precision, real calendar dates and a non-expired release window. The prompt requires reading the actual sources and distinguishing no information from explicit conclusion. Official-host checks control the official badge; they do not prove every statement on a page.
5. **Atomic corrections:** current franchise facts, announcement state, observations and evidence commit together. Withdrawn dates can replace old dates; status rank only controls notification events. Retractions remain retracted across feed/detail/adoption paths.
6. **Episode facts:** AniList titles/thumbnails map by explicit episode number rather than list position. Last-aired time comes from actual episode evidence, never the season premiere or next-date-minus-seven-days. A releasing season's planned total is not claimed as aired or available. The native client does not call an unknown aired count caught up.
7. **Refresh coverage:** upcoming, subscribed and stale TV titles rotate oldest-first through a bounded refresh. A revised AniList sweep refreshes pre-fix metadata. Grouping output must cover each real identity exactly once, with valid sequences and no duplicate numbered-season labels.
8. **Research failures:** SDK `is_error` is checked before its misleading `success` subtype. HTTP 429 pauses further research attempts for one hour. Failed research cannot update a checked timestamp or publish a fact.

## Verification and remaining limits

- TypeScript typecheck passed; **71 test files / 1,175 tests passed**, including added lifecycle, calendar, identity, episode-order, retraction, atomic-correction, provider-error and grouping regressions.
- Whole-catalogue read/composition verification passed: **1,320 franchises, 4,681 parts, 422 composed posts, all nine retractions suppressed**, notification queries checked for all four affected recipients, zero summary/detail or expired-current-claim failures. `verification.json` contains selected corrected responses.
- iOS Debug simulator build succeeded for scheme **Previously**, project `ios/Previously.xcodeproj`, generic iOS Simulator destination. XcodeBuildMCP was unavailable in this session; the installed Xcode CLI was used. Native regression assertions were added and compiled; they were not executed on a device. No TestFlight release or device-install claim is made.
- Restarted the live launchd backend. Local and public `/health` returned `{"ok":true}`. Protected catalogue routes still require authentication: anonymous curl returned 401. Public authenticated device UI was not independently checked; shared database-to-response composition was verified directly.
- At the end of the initial audit, the automated researcher was blocked by Claude's **weekly allowance**. Source accessibility and catalogue audits succeeded independently. The subsequent Codex fallback verification below resolves that availability blocker.
- Seven TMDB entries could not be revalidated: Breaking Bad: Original Minisodes; KOllOK; Making of: The Last of Us; Naruto (The Ocean Cut); Naruto Shippuden Cuarta Guerra Mundial Shinobi; STEEL BALL RUN JoJo's Bizarre Adventure; The Traitors: New Blood. They were not destructively removed.
- **The Traitors US / New Blood identity remains a provider disagreement:** NBC describes a civilian version, while TMDB groups it into the existing series' seasons and the separate New Blood entry is unavailable. The stale September future claim was withdrawn; no unsupported merge/split was performed.
- A valid source URL, schema, or green test suite cannot guarantee every upstream editorial claim. Blocked sources and unverified claims are explicitly outside the verified coverage above.

## Codex fallback follow-up — 4 October 2026

The news job now falls back to the installed Codex CLI when Claude is unavailable, including
quota errors, startup errors and timeouts. Both providers use the same prompt, JSON schema and
identity/evidence/date validator. A completed but invalid or unknown Claude response does not
trigger a second opinion. Claude quota errors pause primary attempts for one hour while Codex
continues; Codex quota/auth failures also back off for one hour. If neither succeeds, the service
keeps existing facts and does not mark the research checked.

Codex uses the machine's ChatGPT login, an ephemeral scratch directory, a read-only sandbox,
live web search, disabled shell/file/MCP/app tools and an allowlisted environment with app secrets
excluded. Completed web-search and turn events are required. Malformed output, unexpected
mutation tools and oversized output are rejected. Timeouts terminate the subprocess group;
temporary files are removed. `NEWS_CODEX_*` configuration is documented in `server/.env.example`.

The real availability path was exercised without calling the persistence or notification service:
Claude returned its actual weekly-quota error, Codex completed live research, and the shared
validator accepted **The Boys: concluded**, empty next installment, with Amazon/AP/Variety evidence.
The total call took **50.3 seconds**. Amazon's primary page was independently opened and confirmed
the final season and May 20, 2026 series-finale date. The result and source URLs are recorded in
[`codex-fallback.json`](./codex-fallback.json). This probe wrote no database records or notifications.

Validation: TypeScript typecheck passed; the full server suite passed **72 files / 1,199 tests**.
After adding two additional Codex quota/auth cooldown cases, the targeted provider suites passed
**23 tests**. Coverage includes primary quota/cooldown, stalled primary interruption, disabling
research/fallback, shared identity validation, credential isolation, actual child-process timeout
and cleanup, missing CLI, malformed output, missing web research and unexpected mutation tools.
The live launchd backend was restarted; local and public health returned `{"ok":true}`, and the
unauthenticated protected feed still returned HTTP 401. No native release was needed.
