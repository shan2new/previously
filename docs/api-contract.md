# Previously API contract (v1)

The Node backend (`server/`) and the iOS app (`ios/`) both build against this. Base URL is
configurable; default dev `http://localhost:8787`. All times are **ms since epoch** (Int64).
All endpoints except `GET /health` require `Authorization: Bearer <Clerk session JWT>`.

## Sources

Franchises come from one of two catalogues, tagged by `source` on `Franchise`/`FranchiseSummary`
(a franchise never mixes sources; the field defaults to `"anilist"` when absent, so old clients
keep decoding):

- `"anilist"` — anime. Parts are AniList Media entries; grouping via the relation graph (+LLM).
  A conservatively matched TMDB title may enrich artwork, videos, episode context, ratings, people,
  recommendations and regional availability, but it never changes this identity or creates a
  second TMDB franchise for the same anime. The highest-resolution available portrait and landscape
  become the response's best `cover`/`banner` and `images.portrait`/`images.landscape` pair; when
  both orientations exist, both are returned. AniList art remains in `artwork` as an alternative.
- `"tmdb"` — general TV. One TMDB **show** = one franchise; each TMDB **season** is a part
  (`kind: "season"`, `sequence` = TMDB season_number; season 0 → `kind: "special"`, label
  "Specials"). `mediaId` = `1_000_000_000 + TMDB season id`. Grouping is deterministic (no LLM).
  **Date precision caveat**: TMDB publishes air *dates* only, so `nextAiringAt`/`lastAiredAt`
  for tmdb parts are synthesized at **17:00 UTC** of the air date. Clients must not show
  minute-level countdowns or schedule time-of-day notifications for `source: "tmdb"`.
  **Announced seasons**: a season with a known future air date ships that premiere as its next
  slot (`nextEpisodeNumber: 1`, `nextAiringAt` = premiere at 17:00 UTC), matching how AniList
  announces a season — so clients read the premiere date off `nextAiringAt` for either source.
  A season with no air date yet has `nextAiringAt: null` and is genuinely undated.
  **Attribution**: any client surface using this data must show the TMDB logo and the line
  "This product uses the TMDB API but is not endorsed or certified by TMDB."

## Core JSON shapes

### ArtworkSet

Artwork orientation is explicit everywhere it is useful: franchise, summary, part and related
title. A missing landscape asset is `null`; the backend never puts a portrait poster into the
landscape slot. The legacy `cover`/`banner` strings remain for older clients.

```jsonc
{
  "portrait": "https://…" | null,
  "landscape": "https://…" | null
}
```

### ArtworkGallery

`artwork` sits beside the best-pair `images` field on franchises, summaries and parts. It exposes
ranked alternatives so iOS can choose portrait artwork for lists/share sheets and landscape art for
hero, episode and horizontal-share layouts without URL guessing. Arrays are de-duplicated and
capped at six; `logos` is populated when the linked catalogue has one. Portrait and landscape
galleries retain their highest-ranked textless candidate even when six higher-resolution titled
images would otherwise crowd it out. A TMDB candidate with positive dimensions and a null
language is textless key art; a URL-only legacy entry with missing dimensions/language is unknown,
not a clean-art signal. Clients must not overlay another title onto an unclassified poster.

```jsonc
{
  "portraits": [{
    "url": "https://…", "source": "tmdb", "width": 2000, "height": 3000,
    "language": "en", "score": 5.31
  }],
  "landscapes": [{
    "url": "https://…", "source": "tmdb", "width": 3840, "height": 2160,
    "language": null, "score": 5.02
  }],
  "logos": []
}
```

### FranchiseVideo

Catalogue-curated external video metadata. Previously does not proxy or host video bytes. `url` may
be opened directly when the provider is supported; `site` + `id` are the durable fallback. A video
can belong to the whole franchise or one exact season/movie. `featuredVideo` is selected by the
backend, preferring an upcoming/current part before video type, then official status and recency.

```jsonc
{
  "id": "ldfEtPf3CfQ",
  "site": "youtube",
  "kind": "announcement", // trailer | teaser | announcement | featurette | clip | other
  "title": "Season 6 Announcement" | null,
  "url": "https://www.youtube.com/watch?v=ldfEtPf3CfQ" | null,
  "thumbnail": "https://…" | null,
  "official": true | false | null,
  "language": "en" | null,
  "country": "US" | null,
  "publishedAt": "2026-01-05T00:00:00.000Z" | null,
  "scope": { "type": "franchise" }
           | { "type": "part", "mediaId": 1000123456, "label": "Season 6" }
}
```

AniList currently supplies at most one trailer id/thumbnail and does not state its official flag
or publish date. TMDB supplies show- and season-level trailers, teasers, clips and featurettes; an
official renewal/return announcement is normalized to `kind: "announcement"`. Empty means the
catalogue has no usable external video, not that playback failed.

For an AniList franchise, source-native videos remain part-scoped. The backend also uses the same
title/year/Japanese-animation match as WatchAvailability to add TMDB videos with franchise scope.
That fallback is refreshed on exact Search, Detail, Subscribe, and a daily catalogue-wide sweep
that prioritizes followed anime.
The public shape is unchanged: clients consume `featuredVideo` and `videos` without branching on
which catalogue supplied the record. An upcoming/current part-scoped video wins featured selection;
a franchise campaign wins over trailers tied only to finished parts, so old Season 1 art does not
hide a newly published fallback trailer.

### EpisodeMeta
Per-episode metadata. TMDB gives title/overview/still/runtime/date from the season endpoint. AniList
gives exact airing instants plus best-effort streaming titles/thumbnails; when a conservative
title/year/episode-count match identifies a TMDB season, the backend fills missing descriptive
fields and horizontal stills while preserving AniList's exact airing instant. Any field may be null.
```jsonc
{
  "number": 1,
  "title": "The North Remembers" | null,
  "airDate": 1333472400000 | null,   // ms epoch (TMDB 17:00 UTC); null for AniList
  "overview": "…" | null,            // null for AniList
  "still": "https://…" | null,       // thumbnail
  "runtime": 51 | null               // minutes
}
```

### FranchisePart
A single installment (one season/movie/OVA/etc.) inside a franchise, merged with the
authenticated user's progress.
```jsonc
{
  "mediaId": 16498,
  "kind": "season",          // season | movie | ova | ona | special | music
  "sequence": 1,              // order within its kind
  "watchOrder": 1,            // one global chronology across seasons, movies and specials
  "relationship": "SEQUEL", // what THIS part is to the work (see below); null for a root / unknown
  "optional": false,          // a side story, a spin-off, a special or a music video
  "label": "Season 1",       // human label the LLM/grouping assigned
  "title": "Attack on Titan",
  "cover": "https://…",
  "banner": "https://…",
  "images": { "portrait": "https://…", "landscape": "https://…" },
  "artwork": ArtworkGallery,
  "format": "TV",            // raw AniList format
  "status": "FINISHED",      // raw AniList status
  "isReleasing": false,
  "totalEpisodes": 25,
  "airedEpisodes": 25,        // latest aired ep number; always 0 while status is NOT_YET_RELEASED
                              // (an announced part has aired nothing, whatever `totalEpisodes` says)
                              // Derived from catalogue airing data ONLY — never from `progress`:
                              // `nextEpisodeNumber - 1` when a next slot exists; for a RELEASING
                              // part with no next slot (the window between a finale airing and the
                              // source flipping status) the latest episode in `episodes` whose
                              // `airDate` has passed, or `totalEpisodes` when the list is undated.
  "nextEpisodeNumber": null,  // 1 on a dated NOT_YET_RELEASED part — the premiere is the next slot
  "nextAiringAt": null,       // ms epoch or null. DERIVED compatibility field: always == release.at
  "release": {                // how precisely the next release is known — state it, never infer it
    "precision": "exact",     // exact | date_only | unknown
    "at": 1700000000000,      // ms epoch; authoritative only when precision is "exact"
    "date": null              // "YYYY-MM-DD" (UTC); authoritative only when precision is "date_only"
  },
  "lastAiredAt": 1372000000000, // ms epoch or null
  "synopsis": "…",
  "genres": ["Action","Drama"],
  "progress": 25,             // user's watched count for THIS part (0 if not subscribed/unwatched)
  "year": 2013,               // premiere/season year, or null
  "studios": ["Wit Studio"],  // studios (anime) or networks (TV) — names only
  "nextAiringCount": 1,       // episodes sharing the next airing date; >1 ⇒ a full-season "drop"
  "episodes": [ EpisodeMeta, … ], // FULL list on GET /franchises/:id ONLY; [] on list/library payloads
  "airings": [ Airing, … ],    // dated episodes inside Schedule's window, oldest first — on EVERY payload
  "videos": [ FranchiseVideo, … ] // trailers/teasers scoped to this exact part
}
```

**`relationship` is the part's own role** (`server/src/grouping/relationship.ts`), derived from the
catalogue's relation edges, where an edge `from → to` of type T means "`to` is the T of `from`": the
edge states `to`'s role as written and `from`'s only through T's inverse. In priority order:
`SIDE_STORY`, `SPIN_OFF` (a child of the story — it stays one even when it has a sequel of its
own), `SEQUEL` (any part that follows another), `PREQUEL` (only the part that opens the chain), then
any other catalogue relation, else `null`. **`PARENT` is never sent for a correctly derived part**:
"this part has children" is not a role. Rows written before 4 Oct 2026 may still carry it — there it
marks either a first season its side stories point at or a child whose own "my parent is…" edge was
passed through uninverted — and may carry `SIDE_STORY` / `optional: true` on a season that merely
*has* a side story. `npm run relations:backfill` (dry run; `-- --apply` to write) re-derives them
from `media_relations`; clients must read both shapes until it has run. Mechanical labels are
`Season N` (the next season NUMBER, not the kind's sequence), `OVA N`, `ONA N`, `Movie N`,
`Special N`; a side series of season kind attached later is labelled with its own title.


### Airing
One dated episode of a part, for the Schedule calendar. `airings` covers the window **8 days back
… 15 days ahead** of the request (`SCHEDULE_WINDOW` in `franchiseView.ts` — a day wider than the
client's own −7…+14 so no timezone sees an edge day undated; clients window precisely). Merged from
the dated episode list (TMDB always; AniList after `backfill-episodes`), the catalogue's next slot
and `lastAiredAt`, de-duplicated by episode number — the list wins. Present on list, library **and**
detail payloads; a weekly show therefore appears on every air date in the window, not once on its
next. Empty when nothing in the window is dated.
```jsonc
{
  "episode": 14,
  "at": 1756226400000    // ms epoch; TMDB's is date-only (17:00 UTC) — read it in the source's calendar
}
```

### Franchise (full detail — `GET /franchises/:id`)
```jsonc
{
  "id": "uuid",
  "source": "anilist",             // anilist | tmdb (default anilist)
  "title": "Attack on Titan",
  "cover": "https://…",
  "banner": "https://…",
  "images": { "portrait": "https://…", "landscape": "https://…" },
  "artwork": ArtworkGallery,
  "synopsis": "…",
  "genres": ["Action","Drama"],
  "isReleasing": true,             // any part currently releasing
  "partCounts": { "season": 4, "movie": 2, "ova": 3, "special": 1 },
  "parts": [ FranchisePart, … ],   // ordered by global watchOrder; each part carries its `episodes`
  "subscription": { "status": "watching", "addedAt": 1700000000000 } | null,  // addedAt = ms epoch the user subscribed
  "upcoming": FranchiseUpcoming | null,  // confirmed/rumored "what's next" — see below
  "year": 2013,                    // premiere year (earliest dated part), or null
  "studios": ["Wit Studio"],       // primary installment's studios (anime) / networks (TV)
  "themes": ["Survival", "Military"], // spoiler-screened; see Catalogue enrichment below
  "featuredVideo": FranchiseVideo | null,
  "videos": [ FranchiseVideo, … ],
  "audience": {
    "isAdult": false | null,
    "contentRating": { "country": "IN", "rating": "U/A 16+" } | null,
    "availableRatings": [{ "country": "US", "rating": "TV-MA" }, …]
  },
  "people": {
    "creators": [ CatalogPerson, … ],
    "directors": [ CatalogPerson, … ],
    "cast": [ CatalogPerson, … ]
  },
  "related": [ RelatedTitle, … ],
  "continueWatching": {
    "mediaId": 16498,
    "partLabel": "Season 1",
    "episode": EpisodeMeta
  } | null,
  "availability": WatchAvailability, // optional; present when country was requested/saved
  "metadata": {
    "completeness": {
      "artwork": true, "episodes": true, "people": true,
      "ratings": true, "related": true, "videos": true
    },
    "sources": [{
      "provider": "tmdb", "mediaType": "tv", "externalId": 82596,
      "matchMethod": "catalogue_owner", "confidence": 1,
      "checkedAt": "2026-09-03T…"
    }]
  }
}
```

### FranchiseSummary (lists: trending, search, library)
```jsonc
{
  "id": "uuid",
  "source": "anilist",             // anilist | tmdb (default anilist)
  "title": "Attack on Titan",
  "cover": "https://…",
  "banner": "https://…",
  "images": { "portrait": "https://…", "landscape": "https://…" },
  "artwork": ArtworkGallery,
  "isReleasing": true,
  "partCount": 10,
  "nextAiringAt": 1700000000000,   // soonest upcoming across parts, or null
  "upcoming": FranchiseUpcoming | null,  // confirmed/rumored "what's next" — see below
  "year": 2013,                    // premiere year (for "Anime · 2023" / "TV · 2024"), or null
  "themes": ["Survival", "Military"],
  "featuredVideo": FranchiseVideo | null,
  "availability": WatchAvailability, // optional; cached preview when country was requested/saved
  // present only in /me/library:
  "status": "watching",            // watching | completed | planned | paused | dropped
  "behind": 2,                      // unwatched aired eps across releasing parts
  "newParts": 1                     // parts added since user last opened (badge)
}
```

### Catalogue enrichment

The detail/library payload includes spoiler-safe themes, audience metadata, people, related titles,
videos and the next already-aired episode the authenticated user has not watched. Search/trending
stay compact but include the fields needed for rich cards: both image orientations, themes and the
single backend-selected `featuredVideo`. Detail/Search use stale-while-revalidate; a slow daily
pass repairs deep AniList metadata, while a separate TMDB pass refreshes anime trailers even when
AniList cannot be reached.

```jsonc
// CatalogPerson
{
  "source": "anilist" | "tmdb",
  "externalId": 123,
  "name": "Lily Collins",
  "role": "Emily Cooper" | "Creator" | "Director" | null,
  "image": "https://…" | null
}

// RelatedTitle
{
  "source": "anilist" | "tmdb",
  "externalId": 456,
  "franchiseId": "uuid" | null, // filled only when already materialized locally
  "title": "The Bold Type",
  "year": 2017 | null,
  "images": { "portrait": "https://…" | null, "landscape": "https://…" | null },
  "score": 100 | null              // source-native recommendation strength when available
}
```

A show page lists ten related titles ("More like this"). A `RelatedTitle` with `franchiseId: null`
resolves through `POST /franchises/resolve` only after the user selects it. TMDB never lists
Japanese animation there: AniList owns it, so its TMDB twin would be a second copy of an anime.

### Recommended for you — `GET /me/recommendations`

Personal, second-degree recommendations: the titles the catalogues' own "if you liked X" lists
(AniList community recommendations, TMDB `/recommendations`) point at from the user's library,
ranked on the server. Every show in the library casts one vote spread over its list, weighted by how
engaged the user is with it (status, episodes watched, recency); several of the user's shows agreeing
counts for more, then a Bayesian quality score, genre fit, a popularity damper and freshness apply.
Ownership, progress and feedback are read live on every request. Only titles of the viewer's
**Audience** are served (`both` / not chosen = every catalogue, as below): the other catalogue's
titles are dropped before the list is cut to `limit`, so an anime or a TV viewer still gets a full
list, with no TV quota.

```jsonc
// GET /me/recommendations?limit=12   (1–30, default 12; anything else is a 400)
{
  "items": [RecommendationItem],        // in shelf order — show them in this order
  "generatedAt": 1790202494394          // ms epoch
}

// RecommendationItem
{
  "key": "anilist:20832",               // stable per series: `${source}:${externalId}`
  "franchiseId": "uuid" | null,         // the show page when it exists (a tap opens it); see below
  "source": "anilist" | "tmdb",
  "externalId": 20832,                  // AniList: the series root (first season) media id · TMDB: show id
  "title": "Overlord",                  // the series' name, never a "Season 4" title; shorten it like any title
  "year": 2015 | null,
  "images": { "portrait": "https://…" | null, "landscape": "https://…" | null },
  "artwork": ArtworkGallery | null,     // the show page's gallery (logos, textless posters) when franchiseId != null
  "format": "TV" | "ONA",               // series only: films, OVAs, specials, music and TV shorts are never served
  "episodes": 95 | null,                // every main season once the show page exists, else the first season's
  "airing": false,                      // a season is airing now
  "genres": ["Action", "Fantasy"],      // up to four, catalogue-native names
  "reason": {
    "kind": "consensus" | "finished" | "watching" | "watched" | "planned" | "world",
    "seeds": [{ "franchiseId": "uuid", "title": "That Time I Got Reincarnated as a Slime" }],
    "count": 5                          // how many of the user's shows point at this title (>= seeds.length)
  },
  "score": 0.5747                       // relevance before diversification (debugging only; do not re-sort)
}
```

- **Deterministic for (user, UTC calendar day).** The shelf rotates daily: a ±12% jitter reorders
  near-ties, and the first four (visible) tiles are a seeded draw from the top eight in which
  yesterday's four count ×0.6. The same user on the same UTC day always gets the same list.
- **Never served:** anything the user owns — including other seasons of an owned franchise and
  normalised-title twins across sources (the anime of a live-action show they have) — anything they
  gave feedback on (matched by the key or by any id of the same series), films / OVAs / specials /
  music / TV shorts, reality / talk / news / soap TV, unreleased or adult titles, and Japanese
  animation from TMDB (AniList owns it).
- **Shape of the shelf:** at most two titles whose main reason is the same show; at most one title
  from the same universe as a show the user has (`world`); when the library has TV shows, a TV quota
  (the library's TV share, clamped to 20–50%) with at least one TV title in the first four.
- **Reasons.** `seeds` are the user's shows behind the title — display titles (the short form the
  apps print: "Re:ZERO", never "Re:ZERO -Starting Life in Another World-") — strongest vote first.
  A single-show reason (and `world`) carries one; a `consensus` (`count` ≥ 2) carries up to three,
  so the client can choose which to name by Today's state (a Watching show on a new-episode day, a
  finished one when caught up). A Planned show with no progress never comes first while another
  show qualifies. The client writes the sentence:

  | kind | copy |
  |---|---|
  | `consensus`, count ≥ 3 | "Like {A} and {count − 1} more of yours" |
  | `consensus`, count 2 | "Like {A} and {B}" |
  | `finished` | "Because you finished {A}" (the show is Watched) |
  | `watching` | "Because you're watching {A}" (Watching, or Planned with real progress) |
  | `watched` | "Because you watched {A}" (Paused/Planned, fully watched, not airing) |
  | `planned` | "Like {A}, on your list" |
  | `world` | "From the world of {A}" |
- **`franchiseId: null`** means the show page is being built: every served title without one is
  queued in the background, and a nightly job builds every user's top 12. A tap on such a tile may
  call `POST /franchises/resolve { source, externalId }`, which returns an existing page at once and
  otherwise groups it (3–15 s).
- **Empty** `items` means there is nothing to recommend yet (an empty library, or lists still being
  fetched for newly added shows). A `404` from an older server means the feature is absent: hide the
  shelf.

```jsonc
// POST /me/recommendations/feedback   → 204   ("Not interested" / "Mark as watched")
{ "key": "anilist:20832", "kind": "dismissed" | "seen" }
// DELETE /me/recommendations/feedback → 204   (undo either)
{ "key": "anilist:20832" }
```

Both verdicts hide the title (by its key or any id of its series) until undone. `seen` only hides
it: to record the show as watched, also add it to the library. Three dismissals whose main reason is
the same show halve that show's weight. The key must be `anilist:<id>` or `tmdb:<id>`; an unknown
field, kind or key shape is a `400`. Feedback is user data and is erased by `DELETE /me`.

- AniList tags marked as general spoilers, media spoilers, or adult are excluded. TMDB has no
  spoiler bit, so only genres and a conservative allow-list of broad keywords become themes.
- `audience.contentRating` is the exact match for the optional `country` query on Detail. No market
  match is `null`; the backend does not substitute a US rating. TMDB provides regional ratings;
  AniList currently provides `isAdult` only.
- Anime cast entries are Japanese voice actors with the character name in `role`. General-TV cast
  entries are top-billed aggregate cast; creators and directors are separate.
- `continueWatching` prefers a part the user already started, then the first unfinished part. It
  never points to an unaired episode. Missing episode metadata produces an honest Episode-N shell
  with nullable context rather than suppressing the next episode.

### FranchiseUpcoming
"What's next" for a franchise (announced/airing seasons, films). A future part already present in
AniList/TMDB is returned immediately as a confirmed fallback; web research adds richer context,
the primary announcement URL, and credible rumors. Detail reads enqueue missing or stale research
without delaying the response, while the daily job proactively refreshes subscribed franchises.
`release` is prose because that is what gets announced — a window as often as a date.

Search is a first-class consumer of this field. A newly materialized TMDB title persists the
immediate catalogue fact in the same write as the franchise, while AniList future parts derive the
same field on read. An exact search hit whose TMDB fact or catalogue-video record is still missing
gets one bounded show-summary refresh before the response returns. The summary is rebuilt after
that write, so an available trailer appears in that same Search response. The same guarantee now
applies to an exact AniList result with no trailer: a bounded metadata-only TMDB match runs and the
summary is rebuilt before return. Richer web research is then queued from Search itself; opening
Detail is not required to start it.
```jsonc
{
  "status": "announced",       // airing | upcoming_dated | announced | announced_no_date | rumored | recently_aired | concluded
  "next": "Season 2",          // shortest stable name for the installment
  "release": "October 2026",   // human-readable date OR window ("2026-11-20", "Summer 2027", "TBA")
  "note": "Announced at AnimeJapan.",
  "source": "https://…",       // primary announcement or provider-catalogue URL, or null
  "checked": "2026-08-24T…",   // ISO date the info was last verified
  "evidence": [{
    "url": "https://…",
    "publisher": "Netflix Tudum" | null,
    "publishedAt": "2026-08-20" | null,
    "tier": "official",        // official | trade | reputable | catalogue | unknown
    "primary": true             // original announcement, not merely coverage
  }],
  "releaseWindow": {           // `release` resolved into something orderable — DERIVED on read
    "date": "2026-10",         // "YYYY-MM-DD" | "YYYY-MM" | "YYYY", at the precision actually known, or null
    "precision": "month",      // day | month | quarter | year | unknown
    "sortKey": 20261001        // yyyymmdd of the EARLIEST instant the window can mean, or null
  }
}
```

`status` is the classification, not a confidence guess: `rumored` is never presented as
`announced`. `evidence` makes the reason inspectable on the critical Search/Detail surface.
Catalogue-derived facts carry a `catalogue` evidence row immediately; agent research can add the
official primary announcement and independent trade/reputable reporting. The immutable history is
available at `GET /franchises/:id/announcements`.

Current facts are reconciled on every read: elapsed release windows and news about an installment
already airing/finished yield to current catalogue data or `null`. Expiry means unverified, not
concluded. A generic provider “Returning Series” flag does not establish another season: a real
future part or supported announcement is required. Spin-offs and national adaptations must match
the canonical series identity before research may publish. Research with missing evidence, invalid
calendar dates, inconsistent date precision, or provider failures cannot replace a stored fact.
Corrections update the franchise, announcement and evidence observation atomically, including
date withdrawals. Retracted announcements remain in the audit history but are suppressed from
live/saved posts and notification counts.

**`release` is the only field a client prints; `sortKey` is the only field it sorts by.** Clients
must not parse `release` themselves — an ISO-only reading of a corpus full of `October 2026` and
`Summer 2027` silently files every one of them under January of its year, which is how a "returning
soonest first" list ended up putting October 2026 ahead of an August 2026 date.

- `precision: "quarter"` means a broadcast season or `Qn`, and `date` is that quarter's **first**
  month — safe to order by, never to print as a month (`Summer 2027` is not "July 2027").
- `precision: "year"` may print only the year: `Late 2026` keeps `date: "2026"` while `sortKey`
  places it in September, so it lands after spring and before the next January.
- `sortKey: null` (TBA, prose with no date, **and every rumor** — an unconfirmed report is not a
  schedule) sorts **last**. Never treat it as 0.

### WatchAvailability
Country-specific **streaming** availability for a franchise. The caller can supply an ISO 3166-1
alpha-2 region or save it once in `/me/preferences`; purchase and rental stores are intentionally excluded. Subscription
services come first, followed by free and ad-supported services.

For TMDB-owned TV franchises the lookup uses the stored TMDB show id. AniList does not expose a
regional catalogue or TMDB id, so anime is conservatively matched to a Japanese-animation TMDB
title by normalized title and premiere year. No safe match is represented by an empty list, never
by a guessed provider.

Consumers must branch on `status`, not on `providers.isEmpty`: `not_available` means a title was
matched but has no subscription/free/ad-supported option in that country; `unmatched` means the
AniList→TMDB bridge could not establish identity safely; and `disabled` means this deployment has
no TMDB token. An upstream failure is an HTTP error rather than any of those catalogue states.

This data comes from TMDB's JustWatch partnership. TMDB returns a regional watch-page link rather
than reliable provider deep links, so the client opens `link` for the actual options and must show
the supplied JustWatch attribution. Search, trending, Library and Detail embed `availability` when
a region resolves. List responses use persisted stale-while-revalidate snapshots; exact Search and
Detail do a current bounded lookup. Use the batch endpoint to warm a visible shelf in one request.
```jsonc
{
  "country": "IN",
  "status": "available",  // available | not_available | unmatched | disabled
  "providers": [
    {
      "id": 8,
      "name": "Netflix",
      "logo": "https://image.tmdb.org/t/p/w92/…" | null,
      "access": "subscription", // subscription | free | ads
      "preferred": true          // optional; saved services sort first
    }
  ],
  "link": "https://www.themoviedb.org/tv/30984-bleach/watch?locale=IN" | null,
  "attribution": "JustWatch",
  "checkedAt": "2026-09-03T12:00:00.000Z"
}
```

## Endpoints

| Method | Path | Body | Returns |
|--------|------|------|---------|
| GET | `/health` | — | `{ ok: true }` |
| GET | `/franchises/trending?limit=30&country=IN` | — | `FranchiseListResponse`; supports the same `source`, `year`, `status`, `theme`, `providerId` filters as Search. No `source` = the viewer's **Audience** |
| GET | `/franchises/starter?limit=60&source=anilist` | — | `{ franchises: FranchiseSummary[] }` — first run's picker (4 Oct): the catalogue's BEST-KNOWN shows, most popular first (`media.popularity`: AniList's member count, TMDB's popularity), non-adult, with a cover. `limit` 1–120 (default 60). No `source` = the viewer's **Audience**; for `both` the two catalogues are ranked separately and alternate, anime first (their popularity scales cannot be compared). Not trending: a chart of this season's titles is the wrong list for someone who has not picked anything yet. A client must fall back to `/franchises/trending` on a 404 (a server that predates the route) |
| GET | `/search?q=&exact=1&source=anilist&year=2026&status=RELEASING&theme=Drama&providerId=8&country=IN` | — | `FranchiseListResponse` — empty `q` = trending. Indexed aliases include English, Romaji, native titles and synonyms. One- or two-character typeahead is local-only. A genuine miss gets one short AniList + TMDB fan-out and bounded materialization. Exact-title hits synchronously refresh immediate `upcoming`, trailer and regional facts, then queue richer research. `exact=1` disables spell correction. All filters are optional; `providerId` requires a query/saved country. With no `source`, the viewer's **Audience** is the catalogue searched (trending and typed queries alike) |
| POST | `/franchises/resolve` | `{ source: "anilist" \| "tmdb", externalId }` | Returns the `FranchiseSummary` of a `RelatedTitle` / `RecommendationItem` the user selected: the existing show page at once when the title is already materialised (no provider call), else it materialises it; `422` when identity/source policy rejects it |
| GET | `/franchises/:id?country=IN` | — | `Franchise`; `country` is optional/case-insensitive, falls back to saved preference, selects `audience.contentRating`, and attaches current `availability` |
| GET | `/franchises/:id/announcements?limit=20` | — | `{ observations: AnnouncementObservation[] }` newest-first, with immutable evidence snapshots |
| GET | `/franchises/:id/watch-providers?country=IN` | — | `WatchAvailability`; `country` is case-insensitive and may be omitted after saving a preference |
| POST | `/franchises/watch-providers/batch` | `{ franchiseIds: [uuid], country? }` | `{ country, availability: [{ franchiseId, ...WatchAvailability }] }`; max 100, four bounded workers |
| GET | `/me/preferences` | — | `{ country, language, providerIds, updatedAt, audience }` — `audience` is `"anime" \| "tv" \| "both" \| null` (see **Audience**) |
| PUT | `/me/preferences` | `{ country?: "IN" \| null, language?, providerIds?, audience?: "anime" \| "tv" \| "both" }` | Saved preference object; omitted fields are preserved. `503 {"error":"audience_unavailable"}` when `audience` was sent and could not be stored — the other fields in the body ARE saved (see **Audience**) |
| GET | `/me/library?country=IN` | — | `{ franchises: LibraryFranchise[], prevOpenedAt: Int }`; country falls back to preferences and adds cached availability. `prevOpenedAt` is the **previous visit** (the value `POST /me/opened` shifted away; the last stamp for an account not yet shifted since migration 0010), never the stamp this session just wrote; `newParts` counts against it |
| GET | `/me/recommendations?limit=12` | — | `{ items: RecommendationItem[], generatedAt }` — see **Recommended for you**; `limit` 1–30 |
| POST | `/me/recommendations/feedback` | `{ key, kind: "dismissed" \| "seen" }` | `204` |
| DELETE | `/me/recommendations/feedback` | `{ key }` | `204` (undo) |
| GET | `/me/watch-sessions` | — | `{ sessions: WatchSession[] }` — live sessions only, by franchise then ordinal — see **Watch sessions** |
| PUT | `/me/watch-sessions/:id` | `WatchSessionBody` (`:id` a client-generated uuid) | `204`; `410 {"error":"session deleted"}`, `404 {"error":"franchise not found"}`, `404 {"error":"session not found"}` (the id is someone else's), `400` on a bad id or body. All final |
| DELETE | `/me/watch-sessions/:id` | — | `204`, always (idempotent; a repeat, an unknown id or someone else's id changes nothing) |
| POST | `/me/subscriptions` | `{ franchiseId, status? }` | `{ ok: true }` (status defaults: `watching` if releasing else `planned`) |
| PATCH | `/me/subscriptions/:franchiseId` | `{ status }` | `{ ok: true }` |
| DELETE | `/me/subscriptions/:franchiseId` | — | `{ ok: true }` |
| PUT | `/me/progress` | `{ mediaId, episodes }` | `{ ok: true }`. The count is clamped: a NOT_YET_RELEASED part to 0, a **RELEASING part to its aired-by-now count** (see **Episode discussions**; with no evidence of a count at all — no slot, no dated episode — to its size, or unbounded when unsized), anything else to `max(episodes, aired)`. The ceiling bounds only an **increase**: the value already stored stays reachable, so a mark written before the ceiling existed (12 of a season with 5 aired) is never pulled down — writing 11 stores 11, not 5. `404 {"error":"media not found"}` for an unknown `mediaId` — nothing is written, and it is final (discard the pending write, never retry). `400` on a bad body |
| PUT | `/me/franchises/:franchiseId/progress` | `{ mode: "caught_up" \| "completed" \| "reset", status? }` **or** `{ parts: [{ mediaId, episodes }], status? }` | Atomic canonical `{ ok, franchiseId, status, progress[] }`; rejects foreign/duplicate media IDs before writing; `completed` also upserts completed subscription status; with no `status` asked for, the writes may still move the show's status by the rule below, and the response's `status` is canonical |
| POST | `/me/opened` | — | `{ prevOpenedAt: Int }` — ONE statement moves the last visit into `prevOpenedAt` and stamps now, atomically; returns the value *before* this call. Not idempotent: call it once per new-visit foreground, **before** loading the feed, and use its answer as the session's anchor |
| GET | `/me/notifications?limit=50&cursor=` | — | `NotificationsPage` `{ items: NotificationItem[], unread: Int, nextCursor }` newest-first — see **NotificationItem**; `limit` 1–200, `400` outside it or on a bad cursor |
| POST | `/me/notifications/read` | `{ ids?: [uuid] }` (≤ 500) | `{ marked: Int }` — omit `ids` to mark all unread as read; `400` on a bad body |
| DELETE | `/me` | — (an unknown field is a `400`) | `{ deleted: true }` — see **Account deletion**. Answers a suspended account too |
| GET | `/me/feed?tab=following` | — | `FeedResponse` — see **Today feed**; `tab` is `following` (default) or `foryou`, `400` otherwise; `episodes=1` opts in to Following's "Episode N is out" posts; `429` (the read budget — see **Rate limits**) |
| GET | `/feed/posts/:id` | — | `FeedPostDetailResponse` — see **Post detail, Saved, Reminders**; `:id` a PostId or an episode post's `ep:<mediaId>:<n>`; `400` bad id, `404 {"error":"post not found"}`, `429` (the read budget) |
| GET | `/me/saved` | — | `SavedResponse`, newest first |
| GET | `/me/reminders` | — | `RemindersResponse`, newest first |
| PUT / DELETE | `/me/likes` | `{ subject }` (a ThreadSubject) | `204`; PUT: `404 subject not found`, `409 episode_locked` (an `ep:` episode that has NOT AIRED; one that is out can be liked, watched or not), `429` — see **Social** |
| PUT / DELETE | `/me/saves` | `{ postId }` (a PostId, or an episode post's `ep:` id) | `204`; PUT: `404` (an `ep:` episode that has not aired included), `429` |
| PUT / DELETE | `/me/reminders` | `{ postId }` (a PostId — an `ep:` id is `400`) | `204`; PUT: `404`, `429` |
| PUT / DELETE | `/me/hides` | `{ kind: "post", target: postId }` \| `{ kind: "show", target: franchiseId }` | `204`; PUT: `404` unknown post or franchise, `429` |
| GET | `/me/hides` | — | `HidesResponse` `{ items: [{ kind, target, createdAt, franchise: { id, title } \| null }] }`, newest first |
| PUT | `/me/ratings` | `{ mediaId, episode: 1…99999, score: 0…100 }` | `204`; `404 episode not found`, `409 episode_locked`, `429` |
| DELETE | `/me/ratings` | `{ mediaId, episode }` | `204` |
| PUT / DELETE | `/me/blocks` | `{ userId }` | `204`; PUT: `400 {"error":"self_block"}`, `404 user not found`, `429` |
| GET | `/me/blocks` | — | `BlockedUsersResponse` `{ items: [{ user: PublicUser, blockedAt }] }`, newest first |
| GET | `/social/comments?subject=&sort=top&cursor=&limit=20` | — | `CommentsPage`; `sort` top \| latest, `limit` 1–50; `400`, `404 subject not found`, `404 comments disabled`, `429` (the read budget) |
| POST | `/social/comments` | `{ id: uuid, subject, body, parentId?: uuid \| null }` | `201` new / `200` replay, `{ comment: CommentView }`; `404` subject/parent/`comments disabled`, `409` `handle_required` \| `terms_required` \| `episode_locked` \| `id_conflict`, `410 comment deleted`, `422 content_rejected`, `429` |
| DELETE | `/social/comments/:id` | — | `204` (a repeat is `204`); `404` not found or not yours |
| PUT / DELETE | `/social/comments/:id/like` | — | `204`; PUT: `404` (missing, deleted, hidden, blocked either way), `409 episode_locked`, `429` |
| POST | `/social/comments/:id/report` | `{ reason, note? }` | `204` (a repeat is `204`); `404`, `409 own_comment`, `429` |
| GET | `/social/episodes/:mediaId/:episode` | — | `EpisodeRoom`; `400`, `404 episode not found` |
| GET | `/me/profile` | — | `ProfileResponse` — see **Identity** |
| PUT | `/me/profile` | `{ handle, displayName }` | `200 ProfileResponse`; `409 handle_taken`, `422 invalid_handle` \| `invalid_display_name` (+`reason`), `429` |
| GET | `/me/profile/handle?handle=` | — | `HandleAvailability`; `400`, `429` |
| POST | `/me/terms` | `{ version }` | `200 ProfileResponse`; `409 terms_version_mismatch` (+`currentVersion`), `429` |
| GET | `/me/export` | — | `AccountExport` as a JSON attachment — see **Account export**; `429`. Answers a suspended account too |
| GET | `/discover/genres?source=` | — | `DiscoverGenresResponse` — see **Discover: genres**; no `source` = the viewer's **Audience**; `400` on a bad source |
| GET | `/discover/genres/:key?source=&limit=24&cursor=` | — | `DiscoverGenrePage`; `limit` 1–50; no `source` = the viewer's **Audience**; `400`, `404 genre not found` |

### Audience

One preference per account decides which catalogue the server SUGGESTS titles from: `anime`
(AniList), `tv` (TMDB) or `both`. A franchise is one or the other, never mixed (`source`), so the
rule is a clean cut: an anime viewer is never suggested a TV show, a TV viewer never an anime.

```ts
type Audience = 'anime' | 'tv' | 'both'
interface UserPreferences {
  country: string | null
  language: string
  providerIds: number[]
  updatedAt: string | null      // the later of the last preferences write and the last audience write
  audience: Audience | null     // null = the viewer has not chosen yet; the server treats null as 'both'
}
```

- **Reading and writing it.** `GET /me/preferences` returns it. `PUT /me/preferences` takes an
  optional `audience` (`"anime" | "tv" | "both"`; omitted = unchanged, like every other field; it
  cannot be set back to `null`). A change applies to the **next request** on every route below —
  nothing is cached across it, For you included.
- **`503 {"error":"audience_unavailable"}`** on a `PUT` that carried `audience` means the choice
  could not be stored (the server's audience table is not there yet, or the write failed). Any
  OTHER field in the same body has been saved. Keep the previous value on screen and retry later;
  reads never fail for this reason — until the choice can be stored every viewer reads
  `audience: null` and is treated as `both`.
- **`both` and `null` are exactly the behaviour before this preference existed**, on every route.

**The default-source rule.** The routes that take a `source` (`anilist` | `tmdb`) and suggest titles
use the viewer's audience as the DEFAULT: with no `source` in the request, an `anime` viewer is
answered as if they had sent `source=anilist`, a `tv` viewer `source=tmdb`, a `both` viewer both
catalogues (as before). **An explicit `source` always wins** — that is how a client lets someone
deliberately look at the other catalogue. There is no value for "both catalogues regardless of my
audience": a viewer who wants both sets their audience to `both`.

**What it governs** — everything the viewer did not ask for by name:

| Route | Effect for an `anime` or `tv` viewer |
|---|---|
| `GET /me/feed?tab=foryou` | Only shows of the audience: the trending pool (that catalogue's OWN top 150), the recommended shows and their posts and discovery trailers, and the `trending` module. No `source` parameter exists here: the audience is always applied |
| `GET /me/recommendations` | Only titles of the audience, filtered BEFORE the limit, so the list is as full as the library allows (an anime viewer's 12 are 12 anime, not the mixed 12 with the TV removed). No TV quota applies to a one-catalogue list |
| `GET /franchises/trending` | Default `source` = the audience |
| `GET /franchises/starter` | Default `source` = the audience (`both`: the catalogues alternate) |
| `GET /search` | Default `source` = the audience, for an empty `q` (trending) AND a typed query: an anime viewer typing a TV show's name finds nothing unless the request sends `source=tmdb` |
| `GET /discover/genres`, `GET /discover/genres/:key` | Default `source` = the audience; the response's `source` says which catalogue was used |

**What it never touches** — anything that is the viewer's own, or that names a title:
`GET /me/feed?tab=following`, `/me/library`, `/me/notifications`, `/me/saved`, `/me/reminders` and
the watch sessions (the viewer's library, whatever it holds); `GET /franchises/:id` (a show page
opens for anyone, and its `related` titles are part of that show), `POST /franchises/resolve`,
`GET /feed/posts/:id`, the watch-provider routes and every social route.

**One catalogue's trending is ranked within that catalogue.** Only AniList carries a trend score
(TMDB shows rank by popularity), so in the mixed ranking every anime sorts above every TV show.
`source=tmdb` — explicit or by audience — therefore ranks TV on its own rather than filtering the
mixed list (which used to answer an empty list for TV).

### Watch sessions: `/me/watch-sessions`

One watch of a franchise: the implicit first watch, or a rewatch. The app owns the history (it starts,
completes, stops, re-dates and deletes sessions) and the server keeps a copy, so a new phone, a
reinstall or a new app id gets it back. Device-local until 2 Oct 2026.

```ts
interface WatchSessionBody {
  franchiseId: string
  scopeMediaId: number | null      // null = the whole franchise; else the one part rewatched
  ordinal: number                  // 1 = first watch, 2 = second, … (1–999)
  startedAt: number | null         // ms epochs; completedAt 0 = "finished, date unknown"
  completedAt: number | null       //   (the implicit first watch)
  cancelledAt: number | null
  cancelledAtEpisode: number | null
  episodes: number                 // episodes the session covers; 0 when unknown
  restoreProgress: Record<string, number> | null  // media id → episodes before the rewatch, so
  restoreStatus: WatchStatus | null                //   stopping it can put the show back
}
interface WatchSession extends WatchSessionBody { id: string; updatedAt: number }
```

- **The client generates `id` and sends the whole session.** `PUT` creates or replaces it, so a
  replay is harmless. Optional fields may be omitted and read as `null`; an unknown field is a `400`.
- **Newest word wins, per session.** The app queues one word per session (save or delete) and sends
  the newest; an acknowledgement for an older word does not clear a newer one.
- **A delete is a tombstone.** `DELETE` marks the row deleted and `GET` stops listing it; a later
  `PUT` of that id answers `410` and changes nothing, so a replay from another device cannot bring
  it back. `GET /me/export` lists tombstones with their `deletedAt`.
- **The app folds `GET` in** after each library reload: the server's copy wins for every session
  with no unsent word; a session the server once acknowledged and no longer lists was deleted on
  another device; one it never saw (made before sync existed, or offline) is uploaded.
- `410`, `404` and `400` are final: the app drops the word (on `410` it drops the session too).

### Account deletion

`DELETE /me` erases the account. It is required by App Store guideline 5.1.1(v) and it is the one
route in this API that cannot be undone, so its semantics are exact:

- **Erased, not deactivated.** In one transaction, in an order the foreign keys allow, the server
  deletes every row that is the user's AND every row that is about the user, then the `users` row
  itself, last:
  - the likes, reports and notifications hanging off the user's own comments (other people's likes
    on them, reports about them, "replied to you" rows pointing at them);
  - the user's comment likes, reports, notification inbox, and every notification in someone else's
    inbox that names the user as the actor;
  - the user's comments — hard-deleted; **other people's replies to them survive as top-level
    comments** of the same thread (the parent link is cleared, never cascaded);
  - the user's likes, saves, reminders, hides, episode ratings, blocks in both directions (whom they
    blocked and who blocked them), and public profile (which **frees the handle**);
  - the user's `subscriptions`, `progress`, `watch_sessions` (tombstones too), `user_preferences`,
    `user_audience` (the audience choice) and `recommendation_feedback`.

  Every user-owned table is deleted explicitly rather than left to the `ON DELETE CASCADE` each
  foreign key declares — the cascade is real and `me.account.test.ts` asserts it (for every foreign
  key to `users`, whatever the column is called), but a database restored from a dump, or a table
  added later without one, must not be able to turn "delete my account" into "orphan my rows".
- **Scoped to the bearer.** The user id comes from the verified token. The optional body is
  `{ "apple": { "identityToken": "…", "authorizationCode": "…" } }`; the Apple token is capped at
  16 KiB and the code at 8 KiB. Omitted, empty or incomplete proof still permits app-data erasure.
  Unknown fields or wrong types are `400` before deletion. Proof never selects another app account.
- **Nothing else is touched.** The catalogue (`media`, `franchise`, `announcements`) is shared and
  survives; only the rows that belong to or are about this user are removed. The user's reports go
  with the account, and a comment's report count is RECOUNTED from the reports that remain the next
  time it is reported (see **Comments** → report), so an erased reporter's report stops counting.
- **Retained safety records.** The deletion tombstone stores an identity hash, deletion/retry timestamps,
  and Apple outcome; a pending Clerk cleanup retains its raw retry identity until completion. The
  independent journal retains the intent and hash-only immutable outcome markers. Tokens/codes are
  never part of these records. The ban list is also retained. If the account was suspended, its `moderation_bans`
  row — the Clerk identity and the operator's reason — is kept after deletion. It is keyed on the
  Clerk id and has no link to the erased account; without it, deleting and signing back in would
  lift a ban.
- A suspended account can still call `DELETE /me` (and `GET /me/export`). A suspended identity's
  export only LOOKS its account up — it never re-creates an erased one (nor stores its email
  again): with no account it answers `404 {"error":"account not found"}`.
- **Durable deletion and identity cleanup.** A private independent journal records the deletion
  intent before the SQL commit. Production startup, the cleanup worker and authenticated
  `GET /me/deletion` reconcile it under the same identity lock used by account creation, so a
  rolled-back commit or an older restored database cannot silently resurrect the account. The
  server deletes the Clerk user after app-data erasure; failed Clerk cleanup retries in the worker.
  `DELETE /me` returns `200 { deleted: true, status: "complete", appleRevocation }` when identity
  cleanup has completed, or `202 { deleted: false, status: "pending", appleRevocation }` when it
  remains pending. Both mean app-data erasure has committed. `GET /me/deletion` returns the same
  durable receipt, or `200 { deleted: false, status: "active" }` when no deletion intent exists.
- **Apple grant outcome.** `appleRevocation` is `"revoked"`, `"manual_required"` or
  `"not_applicable"`. A fresh Apple ID token must verify against Apple's public keys, issuer,
  native app audience and freshness; its subject must match a current linked Apple account on
  the authenticated Clerk user. Only then, after app-data erasure commits, the server exchanges
  the one-use code, verifies the exchanged token belongs to the same subject/nonce, and revokes
  that refresh/access grant. Only an Apple `200` revocation receipt establishes `"revoked"`.
  Current Clerk linkage proving no Apple account establishes `"not_applicable"`. Missing proof,
  invalid/wrong-owner proof, unavailable linkage, provider failure, lost receipt or interruption
  stays `"manual_required"`; the client directs the user to revoke Previously in Apple Settings.
  These failures never prevent app-data erasure. A native cancellation happens before DELETE and
  erases nothing. Tokens/codes remain ephemeral and never enter logs, SQL or the filesystem journal;
  only the outcome is retained. A hash-only immutable outcome marker protects a proven revocation
  when restoring an older deletion snapshot.
- **Replays and queued writes.** The deletion tombstone survives sign-out, restarts and database
  restores. Authentication answers same-identity writes with `401 { error: "account deleted" }`
  before account creation. A repeated DELETE returns the stored receipt (and can retry Clerk cleanup),
  without reusing its Apple proof. The client holds writes before DELETE, reconciles unknown transport
  outcomes through `/me/deletion`, clears account-owned local state on accepted erasure, and signs out.
  A genuinely new Clerk identity can create a new empty account; the old identity remains erased.

### Account export: `GET /me/export`

Everything the server holds for the caller, as one JSON document, answered with
`Content-Type: application/json; charset=utf-8`,
`Content-Disposition: attachment; filename="previously-export-<YYYY-MM-DD>.json"` and
`Cache-Control: no-store`. Rate limited to 3 an hour. It works while suspended.

```ts
interface AccountExport {
  exportedAt: number
  account: { id: string; createdAt: number; email: string | null; lastOpenedAt: number | null; prevOpenedAt: number | null }  // visit stamps: null = never
  profile: { handle: string | null; displayName: string | null; termsAcceptedAt: number | null; termsVersion: string | null; createdAt: number; updatedAt: number } | null
  // The caller's ban record, read by their Clerk id — the one row kept after DELETE /me. null when the
  // identity was never suspended; a lifted ban reads suspended: false with liftedAt set.
  moderation: { suspended: boolean; reason: string | null; since: number | null; liftedAt: number | null } | null
  library: {
    subscriptions: { franchiseId: string; title: string; status: WatchStatus; addedAt: number }[]
    progress: { mediaId: number; episodes: number; updatedAt: number }[]
    preferences: UserPreferences | null  // incl. `audience` (see Audience); null = neither a
                                         // preferences row nor an audience choice is stored
    recommendationFeedback: { key: string; kind: string; createdAt: number }[]
    watchSessions: (WatchSession & { deletedAt: number | null })[]  // tombstones included
  }
  social: {
    comments: { id: string; subject: string; parentId: string | null; body: string; createdAt: number; deletedAt: number | null; hiddenAt: number | null; hiddenReason: string | null }[]  // hiddenReason: 'reports' | 'operator'
    likes: { subject: string; createdAt: number }[]
    commentLikes: { commentId: string; createdAt: number }[]
    saves: { postId: string; createdAt: number }[]
    reminders: { postId: string; createdAt: number }[]
    hides: { kind: string; target: string; createdAt: number }[]
    ratings: { mediaId: number; episode: number; score: number; updatedAt: number }[]
    blocks: { userId: string; handle: string | null; createdAt: number }[]
    reports: { commentId: string; reason: string; note: string | null; createdAt: number; resolvedAt: number | null; resolution: string | null }[]
    notifications: { id: string; kind: string; franchiseId: string; title: string; body: string; subject: string | null; postId: string | null; commentId: string | null; createdAt: number; readAt: number | null }[]  // title/body as stored
  }
}
```

### FranchiseListResponse
The envelope every franchise-list route returns. `franchises` is the only guaranteed field; the
other three are **optional — present only on `/search`**, the one route that may fall back across
catalogues. `/franchises/trending` returns `{ franchises }` alone. They exist so the client can be
honest rather than silently plausible:
```jsonc
{
  "franchises": [ FranchiseSummary, … ],
  "correctedQuery": "Mushoku Tensei",  // optional — /search only; present only when the query was
                                       // spell-corrected AND the rewrite actually found something
  "originalQuery": "Mushuko Tensei",   // optional — /search only; echoed alongside correctedQuery
  "sources": {                          // optional — /search only. Per-catalogue outcome: a
    "anilist": "ok",                    // catalogue that FAILED is not a catalogue with no
    "tmdb": "disabled"                  // matches. ok | failed | disabled; "disabled" =
  }                                     // TMDB_ACCESS_TOKEN unset (anime-only mode)
}
```
A client must treat an absent `sources` as "nothing to report", never as a failure.

### NotificationItem

`GET /me/notifications?limit=50&cursor=…` answers a `NotificationsPage`:

```jsonc
{
  "items": [NotificationItem, …],   // newest first: (createdAt desc, id desc)
  "unread": 3,                       // same filters, readAt null (the bell's badge)
  "nextCursor": "eyJhdCI6…" | null   // opaque; pass back as ?cursor= for the next page
}
```

```jsonc
{
  "id": "uuid",
  "franchiseId": "uuid",
  "kind": "news_rumored" | "news_announced" | "news_dated" | "reply" | "like_comment"
        | "comment_hidden" | "report_resolved",
                          // decode LENIENTLY: an unknown kind renders as a plain row
  "title": "Sakamoto Days",   // franchise title
  "body": "Season 2 announced — release TBA",  // news: server English, the FALLBACK only (when
                              // `news` is null) — never parse it; social kinds: "";
                              // moderation notices: a CATEGORY (see **Moderation notices**)
  "createdAt": 1790330400000, // ms epoch (for an aggregated like: the newest like)
  "readAt": null,             // ms epoch, null while unread
  "actor": PublicUser | null, // reply / like_comment: who did it (the newest liker); null for news,
                              // AND null when that person has no public profile (liking needs no
                              // handle, and a reset name has none) — word the row without a name:
                              // "Someone liked your reply" / "3 people liked your reply" from actorCount
  "actorCount": 0,            // like_comment: distinct likers folded into this row (≥ 1); 0 otherwise
  "subject": "news:…" | null, // the thread to open (social kinds): a ThreadSubject
  "postId": "news:…" | null,  // the feed post to open: news kinds → "news:<announcementId>";
                              // social kinds on a post thread → that post; null for an episode room
  "commentId": "uuid" | null, // reply: the reply itself; like_comment: YOUR comment that was liked
  "excerpt": "…" | null,      // read LIVE: the first 140 code points of that comment; null once it is
                              // gone, and null for a comment in an episode room that is not OPEN to
                              // you now (a reset re-locks it: the spoiler gate applies here too)
  "news": NotificationNews | null  // news kinds: the fact to word the row from; null for social
                                   // kinds and for a news row whose announcement is gone
}
```

**Moderation notices.** Both sides of a moderation decision are told, as rows in the same inbox (DSA
Art. 17's statement of reasons to the author; Art. 16(5)'s decision to the notifier). They carry no
actor, `subject`, `postId`, `commentId`, `excerpt` or `news` — a hidden comment is nobody's to open,
so the row **opens nothing**; `title` is the show and `body` is a machine category the client words
(with the support contact), never English:

| `kind` | To | `body` |
|---|---|---|
| `comment_hidden` | the comment's author | `reports` — hidden automatically after reports; `operator` — hidden by a moderator (a `hide`, or a ban that hides the account's comments) |
| `report_resolved` | each reporter whose open report was decided | `hidden` — the comment was removed; `dismissed` — it stays up (a `restore` or `dismiss`) |

They are listed whether or not comments are switched on, and count toward `unread`.

```jsonc
// NotificationNews — read LIVE from the announcement (like `excerpt`): an older row shows the
// installment's CURRENT state, and `kind` says which event created the row.
{
  "status": "upcoming_dated",   // rumored | announced_no_date | announced | upcoming_dated (decode leniently)
  "installment": "Season 2",    // as FeedPost.installment: never contains "(movie)"
  "isMovie": false,
  "release": "2026-11-20",      // research's prose, printed as-is only where the feed prints
                                // FeedWindow.release — never parsed
  "releaseWindow": ReleaseWindow  // what the client formats and sorts by; a rumour's is always unknown
}
```

**Wording a news row.** Render it with the feed's headline grammar (dated / window / announced /
rumour) from `news` — the time text is the client's, from `releaseWindow`, like every other time in
the app. `body` is server English with the raw `release` in it ("Season 2 arrives 2026-11-20") and
is only the fallback for a row whose `news` is null.

Research's words reach Activity on the feed composer's terms (brief §14): `installment` and
`release` are normalised and capped like `FeedPost.installment` / `FeedWindow.release`, and text
carrying a link or a blocked term is never sent. A news row whose installment name cannot be printed
has `news: null`; a `release` that cannot be printed is `""` and its `releaseWindow` is `unknown`
(word the row as announced) — except a day-precise date, which is a structured fact and is kept. A
news row's `body` that carries a link or a blocked term is sent as `""`: render the title alone.

**Deep link.** `commentId` set → open the thread `subject` scrolled to that comment. Else `postId`
set → open `GET /feed/posts/:postId`. Else → open the franchise.

**Aggregation.** Likes on one of your comments fold into ONE unread `like_comment` row per comment:
each new liker bumps `actorCount`, becomes `actor` and moves `createdAt` to now. Once you have read
it, the next like starts a new row, but not within `SOCIAL_LIKE_NOTIFY_COOLDOWN_MINUTES` (60) of the
last one. Unliking never decrements. Render "Mira and 41 others liked your reply" from `actor` and
`actorCount − 1`. Nobody is notified about their own actions, and a block (either way) silences both
kinds.

**Filtering.** A row whose actor is blocked either way, or whose comment has since been deleted or
hidden, is not listed and does not count as unread. While `SOCIAL_COMMENTS_ENABLED` is off, the
social kinds are not listed at all.

**News rows** are produced by the daily research job (Claude Agent SDK web research over each
subscribed franchise, with Codex live web research when Claude is unavailable). Both providers use
the same identity, evidence and release-date validation. A completed but unsupported result does
not trigger fallback; if neither provider returns verified information, existing facts remain.
A notification is created only when news is genuinely new: first sighting of
an upcoming installment (including credible rumors), a status upgrade (rumored → announced → dated),
or a TBA release gaining a concrete date. It goes to the franchise's subscribers **and to the
reminder holders it answers** (`PUT /me/reminders`), once each: everyone with a reminder on that
news post (`news:<announcementId>`), **and everyone with a reminder on any of the show's non-news
posts** — a trailer (`trailer:…`, never re-keyed) or a catalogue post that adoption could not match
(`catalog:…`). That is what keeps the app's "News about it will show in Activity" true for every
undated reminder. A reminder on ANOTHER announcement's post (`news:<B>`) is about that installment
and waits for its own news. The same job keeps `franchise.upcoming` fresh, so the existing upcoming
badges/callouts update automatically.

There is no push in this build: the Activity sheet polls. Opening it marks read
(`POST /me/notifications/read`).

## Post ids and thread subjects

Every social row (likes, comments, saves, reminders, "not interested") keys on one text id. There
are four kinds; the first three are **PostIds** (a post in the feed), and all four are
**ThreadSubjects** (something with a discussion). The fourth is ALSO the id of one kind of feed
post — Following's "Episode N is out" (`kind: 'episode'`) — so that post and the episode's room are
one subject:

| Subject | Grammar (whole string) | What it is |
|---|---|---|
| `news:<uuid>` | `news:` + lowercase uuid | A research-backed news post. The uuid is the announcement's id. |
| `catalog:<mediaId>` | `catalog:` + 1…2147483647, no leading zero | A catalogue-only upcoming post: an announced (NOT_YET_RELEASED) part that research has no row for |
| `trailer:<franchiseId>:<site>:<videoId>` | lowercase uuid, `[a-z0-9]{1,20}` (lowercased), `[A-Za-z0-9_-]{1,64}` | A trailer post |
| `ep:<mediaId>:<n>` | 1…2147483647, episode 1…99999 | An episode discussion room (spoiler-gated — see **Episode discussions**), and the id of that episode's "Episode N is out" post |

- **A news post is its announcement**, not its wording: `news:<announcement id>`. Research that
  rewords the same installment ("Season 2" / "2nd Season") lands on the same announcement row, so
  the post and its thread stay one.
- **A catalogue post becomes a news post when research catches up.** When research first creates or
  advances an announcement that matches a `catalog:<mediaId>` post's part, every social row is
  re-keyed from `catalog:<mediaId>` to `news:<announcementId>` in one transaction (likes, saves,
  reminders, hides, comments, notification links). A catalogue post also composes as `news:<id>` as
  soon as a matching announcement exists.
- **"Matches" is ONE rule everywhere.** An announcement names the part its installment (`next`)
  resolves to with the feed's part matcher, the parts scanned in watch order (the same match that
  sets a research post's `part`); when several announcements name one part, the oldest
  (`first_seen_at`, then id) is the one. The catalogue post's id, the post-detail alias, adoption
  and the write-side canonical subject below all read this rule, so a thread is never keyed on one
  id while the feed shows another.
- **Writes and thread reads key on the CANONICAL subject.** Once an announcement names its part,
  `catalog:<mediaId>` IS `news:<announcementId>` on the server: `PUT /me/likes`, `/me/saves`,
  `/me/reminders` and `/me/hides` (`kind: "post"`) store the `news:` id, and their `DELETE`s clear
  both the `news:` id and the id as sent; `GET /social/comments` reads the `news:` thread and names
  it in `CommentsPage.subject`; `POST /social/comments` stores the comment (and checks its
  `parentId`) under the `news:` thread and answers a `CommentView` whose `subject` is that id. So a
  toggle queued, a comment replayed or a hide sent against the old id is never stranded. A client
  that sent `catalog:<mediaId>` and reads back a different `subject` re-files its state under the
  answered id. A `catalog:` id no announcement names is its own canonical subject.
- **An episode post has no id of its own: it is `ep:<mediaId>:<n>`.** `GET /feed/posts/:id`,
  `/me/saves` and `/me/hides` (`kind: "post"`) take it beside the three PostIds; `/me/reminders`
  does not (`400` — an episode that is out has nothing to be reminded of). As a POST it exists once
  the episode has aired, watched or not: it can be liked, saved and hidden then (`404 post not
  found` / `409 episode_locked` + `reason: "unaired"` before). As a ROOM it is unchanged: reading
  and writing its comments, liking them and rating the episode still need the episode aired AND
  watched. The post's `counts` are the room's (its likes, its visible comments).
- **A trailer id carries its franchise**, so one YouTube id attached to two shows cannot collide.
- Clients treat every id as **opaque**. Use `post.id` from `GET /feed/posts/:id` as the canonical
  thread subject (it can differ from the id you asked for — see the alias rule there). An old
  `catalog:` link can answer `404` after adoption; fall back to the franchise.
- The server rejects anything off-grammar with `400`, including uppercase uuids and ids longer than
  160 characters. A trailer subject is accepted only for a video the franchise actually carries, so
  nobody can open a thread on an arbitrary video id.

## Today feed: `GET /me/feed`

`GET /me/feed?tab=following|foryou&since=<ms>&episodes=1` (`tab` defaults to `following`; `since`
and `episodes` are optional).
Posts are assembled ON THE SERVER by one composer with stable ids; the client renders every WORD
(headline, stamp, premiere line, window) from the structured facts below, in the viewer's locale and
time zone.

| Query | Meaning |
|---|---|
| `tab` | `following` \| `foryou` |
| `episodes` | **Opt-in** to Following's "Episode N is out" posts (`kind: "episode"` — see **Episode posts**): `1` or `true` includes them. Absent, or any other value, they are left out and the response is exactly what it was before the kind existed (never a `400`). A client sends it only once it renders `kind: "episode"`: an older build decodes an unknown kind as an announcement and would print false news. No effect on For you. |
| `since` | The client's visit anchor, ms epoch, digits only (anything else is `400`): the `prevOpenedAt` its own `POST /me/opened` answered this session. When `0 < since ≤ now` it is THE anchor — `fresh`, the order and the echoed `prevOpenedAt` all use it. Otherwise (absent, `0`, in the future) the server reads its stored anchor. Pass it once this session's stamp has landed: the stored anchor is the visit before last while that stamp is missing (it failed; it is never retried), and another device's stamp moves it mid-session. |

```ts
type FeedTab = 'following' | 'foryou'
type FeedPostKind = 'dated' | 'window' | 'announced' | 'rumour' | 'trailer'
                  | 'episode'   // "Episode N is out": Following only
type FeedPostOrigin = 'research' | 'catalogue' | 'video'

interface FeedTime {            // when the news happened
  at: number                    // ms; a date-only fact is carried at 12:00 UTC of its day
  dateOnly: boolean
  basis: 'primary'              // the original announcement's own date
       | 'first_report'         // earliest report in the 120-day cluster (no usable primary)
       | 'observed'             // when research first saw this state (no dated report)
       | 'catalogue'            // when the catalogue attached the part
       | 'published'            // the video's publish instant
       | 'aired'                // kind 'episode': the episode's air instant (TMDB: date-only)
}
interface FeedPremiere { at: number; precision: 'exact' | 'date_only' }
interface FeedWindow { release: string; releaseWindow: ReleaseWindow }   // see FranchiseUpcoming
interface FeedSource {
  publisher: string
  tier: 'official' | 'trade' | 'reputable' | 'catalogue' | 'unknown'
  url: string | null            // https only; null = no https link (catalogue fallback only)
  publishedAt: number | null
  dateOnly: boolean
  primary: boolean
}
interface FeedPartRef {         // the part a post is about: art inputs only
  mediaId: number; label: string; kind: PartKind; status: string | null
  cover: string; banner: string; images: ArtworkSet; artwork: ArtworkGallery
}
interface FeedFranchise {       // the post's author row ("the show"), shipped once per response
  id: string; source: 'anilist' | 'tmdb'; title: string
  cover: string; banner: string; images: ArtworkSet; artwork: ArtworkGallery
  year: number | null; isReleasing: boolean
  status: WatchStatus | null    // the viewer's library status; null = not in their library
  upcoming: FranchiseUpcoming | null
}
interface FeedPost {
  id: string                    // PostId; for kind 'episode' the episode's subject `ep:<mediaId>:<n>`
  kind: FeedPostKind
  origin: FeedPostOrigin
  franchiseId: string
  installment: string           // "Season 2", "Infinity Castle Part 2"; never "(movie)"; '' for a franchise-wide
                                // trailer (and for a delisted trailer composed by id — see Post detail)
  isMovie: boolean
  part: FeedPartRef | null
  episode: number | null        // kind 'episode': the episode number; null for every other kind
  time: FeedTime                // never after the response's generatedAt
  discoveredAt: number          // when the app first knew this post in its current state; 0 = never "new"
  fresh: boolean                // discoveredAt > the response's prevOpenedAt
  premiere: FeedPremiere | null // kind 'dated' (and a trailer whose installment has a slot STILL TO COME)
  window: FeedWindow | null     // kind 'window'
  note: string | null           // the research note, tidied; research posts only
  video: FranchiseVideo | null  // a trailer's own video; null only on a delisted trailer composed by id
  sources: FeedSource[]         // ranked; sources[0] is the lead
  isOfficial: boolean           // sources[0].tier === 'official'
  context: FeedPostContext | null // For you only: why the post is in THIS viewer's feed (see For you)
  viewer: { liked: boolean; saved: boolean; reminded: boolean }
  counts: { likes: number; comments: number }
}
type FeedPostContext =
  | { kind: 'recommended'; reason: RecommendationReason }  // the reason of GET /me/recommendations
  | { kind: 'taste'; genres: string[] }                    // 1–2 taxonomy genres, the viewer's strongest first
interface FeedResponse {
  tab: FeedTab
  generatedAt: number
  prevOpenedAt: number          // the anchor the server ordered against: `since` when it was used,
                                // else the stored previous visit. Label "caught up since …" from THIS.
  capabilities: { comments: boolean }
  franchises: FeedFranchise[]   // exactly the franchises the posts reference
  posts: FeedPost[]
  trending: FranchiseSummary[]  // For you only (the Trending module); [] on following
}
```

```jsonc
{
  "tab": "following", "generatedAt": 1790330400000, "prevOpenedAt": 1790244000000,
  "capabilities": { "comments": true },
  "franchises": [{ "id": "…", "source": "anilist", "title": "Sakamoto Days", "status": "watching", "…": "…" }],
  "posts": [{
    "id": "news:0b6c…", "kind": "window", "origin": "research", "franchiseId": "…",
    "installment": "Season 2", "isMovie": false, "part": null, "episode": null,
    "time": { "at": 1789819200000, "dateOnly": true, "basis": "primary" },
    "discoveredAt": 1790300000000, "fresh": true,
    "premiere": null,
    "window": { "release": "January 2027", "releaseWindow": { "date": "2027-01", "precision": "month", "sortKey": 20270101 } },
    "note": "Announced at …", "video": null,
    "sources": [{ "publisher": "Netflix Tudum", "tier": "official", "url": "https://…", "publishedAt": 1789819200000, "dateOnly": true, "primary": true }],
    "isOfficial": true,
    "context": null,
    "viewer": { "liked": false, "saved": false, "reminded": true },
    "counts": { "likes": 0, "comments": 0 }
  }],
  "trending": []
}
```

Rules a client builds on:

- **Kinds.** `dated` has a `premiere`; `window` has a `window`; `announced` is confirmed with no
  date; `rumour` is unconfirmed (it keeps its Community Note); `trailer` has a `video`; `episode`
  has an `episode` number (see **Episode posts**, below). The post's
  state is the newest research observation resolved against the catalogue exactly as Detail's
  `upcoming` is, so the feed can never say "rumoured" while the show page says "dated". A research
  result whose release is DAY-precise is `dated` (a `date_only` premiere) whatever its status called
  it — an `announced` "November 20, 2026" is never a window "in Nov 20, 2026".
- **News leaves the feed when its installment arrives.** A research post is not in the feed once
  the part it names has left `NOT_YET_RELEASED`, or once its `premiere` is more than 24 h past (it
  still composes by id, `live: false`); the show page and the story tray own an airing installment.
  A trailer's `premiere` is only ever still to come. A post's `premiere` can still be in the past
  within that day and within the ≤1 h before the hourly sync flips the part, so a client that prints
  "premieres …" must word a past premiere in the past tense (or drop the line).
- **Time facts.** `time` is when the NEWS happened (`basis` says which evidence dated it; `dateOnly`
  facts sit at 12:00 UTC of their day and must never print a clock). `time.at` is never after
  `generatedAt`: a report dated up to a day ahead (a JST publisher's "tomorrow") is clamped to now,
  keeping its `dateOnly`. `discoveredAt` is when the app first knew the post in its current state.
  **"New" compares `discoveredAt`, never `time`**: a week-old announcement research found this
  morning is new; the news date is still a week ago. A catalogue post's `time` is when the catalogue
  attached the part; its `discoveredAt` is that instant only when the part was attached AFTER the
  show was grouped (the daily pass found a new season). A part that came with the show's grouping —
  a newly materialised show, or one a re-grouping re-stamped — has `discoveredAt: 0` and is never
  `fresh`: its attach instant says nothing about when it was announced.
- **The client renders all words** — the headline, the stamp, the premiere line and the window —
  from these facts. `window.releaseWindow` is the only thing sorted or formatted by; `release` is
  printed as-is and **never parsed** (the FranchiseUpcoming rule).
- **`isOfficial` is the only condition for the gold check mark**: the lead source is a studio,
  network or streamer. A trade-press lead (`trade`, `reputable`) has no mark. A trailer is official
  only when its catalogue record says `official: true`. The research agent's own tier is a CLAIM
  (it reads arbitrary pages): evidence is `official` only when its URL is on a reviewed official
  host (`server/src/feed/officialHosts.ts`, suffix-matched); every other `official` claim is served —
  and stored — as `reputable`.
- **Sources are https-only.** The server drops every non-https evidence URL before any rule runs
  (and ignores evidence dated more than 24 h in the future). Clients open only `https` URLs anyway.
- **Research-agent words are filtered before they are printed.** `installment`, a source's
  `publisher`, `window.release` and `note` come from the agent: each is normalised (the first three
  to one line with invisible and control characters removed; the note keeps its line breaks), capped (60 / 60 / 60 / 600 code points,
  cut on a word with "…"), and refused when it carries a link or a blocked term. A refused
  installment falls back to the matched part's catalogue label, else there is no post; a refused
  publisher reads as the page's host; a refused release makes the post `announced`; a refused note
  is `null`. A storyline `headline` whose words carry a blocked term is `null`.
- **`fresh` and the order (Following; For you has its own order, below).**
  `fresh = prevOpenedAt > 0 && discoveredAt > prevOpenedAt`. Fresh posts
  come first, then everything else; each block is ordered by `time.at` desc, then `id` asc (so equal
  times never flicker). The "new posts" pill counts the fresh posts, and "You're all caught up" sits
  above the first post with `fresh: false` when at least one fresh post precedes it.
  `prevOpenedAt` is the previous visit (see `POST /me/opened`), never the stamp this session wrote —
  or the client's own `since` when it sent one. Its "since …" label reads the RESPONSE's
  `prevOpenedAt`, so the words and the fresh block always name the same boundary.
- **Following** is every show in the viewer's library (every status), minus muted shows and posts
  marked "Not interested", capped at 200 posts. Every post has `context: null`.
- **Episode posts ("Episode N is out") — Following only, and only for a request that sends
  `episodes=1`** (see the query table: every other request gets no `episode` post at all). For each
  library show whose status is
  `watching`, `completed` or `paused` (never `planned` or `dropped`), each MAIN-STORY episodic part
  posts its newest episode that has **aired by now**, for **7 days** after it aired — one post per
  part, whether or not the viewer has watched it. Main-story parts are the `season` parts that are
  not a short (`format: TV_SHORT`), not `optional`, and not a `SPIN_OFF` or `SIDE_STORY`; a show
  with no such season posts for its main-story `ona` parts instead. "Aired by now" is the rule of
  **Episode discussions** (a timed slot at its instant, even before the hourly sync moves the
  catalogue on; a date-only TMDB episode from 10:00 UTC of its date), read from the part's dated
  `airings`; a part still `NOT_YET_RELEASED` posts nothing; a same-day drop posts its highest
  episode number. The post:
  `id: "ep:<mediaId>:<n>"`, `kind: "episode"`, `origin: "catalogue"`, `episode: n`,
  `installment` = the part's label, `part` = its `FeedPartRef`, `time` = the air instant with
  `basis: "aired"` (a TMDB episode is `dateOnly: true`, carried at 12:00 UTC of its date and never
  after `generatedAt`), `discoveredAt` = the instant it counted as aired (so it is `fresh` for a
  viewer whose previous visit was before it), and `premiere`, `window`, `note`, `video` null,
  `sources: []`, `isOfficial: false`. **No episode title, still or synopsis is sent** (spoilers):
  the client writes "Episode 7 is out" from `episode` and `installment`. It is ordered like every
  Following post (fresh block first, then `time.at`), and muted shows and hidden posts drop it like
  any other. Its id is the episode's room, so its `counts` are that room's; see **Post ids and
  thread subjects** for what a viewer who has not watched the episode may do with it.
- **For you** is news about shows the viewer does not track, RANKED FOR THE VIEWER from their
  library, and **only about shows of the viewer's Audience** (see **Audience**): for an `anime` or a
  `tv` viewer the trending pool is that catalogue's own top 150, the recommended shows are of that
  catalogue, and so is the `trending` module; `both` (or not chosen) is everything below unchanged.
  The audience is read on every request, so a change shows in the next response.
  The candidates are two sets of posts: the top 150 trending franchises, composed once per
  10 minutes per process (independent of the viewer, one composition per catalogue scope), and the viewer's recommended shows — the
  ranker behind `GET /me/recommendations`, asked for 40 in its reference order (no daily rotation),
  keeping the titles that have a show page (`franchiseId != null`) and composing the ones the
  trending set does not already carry. The viewer's part (their library and those posts) is kept
  per user for the same 10 minutes, so a library change can take that long to move the order;
  ownership, mutes and hides are still read on every request. Per request the candidates lose the
  viewer's library shows, muted shows and posts marked "Not interested", then:
  - **Discovery trailers.** Most recommended shows have no news, and a trailer is new to someone
    who has not seen the show: each recommended show (wherever its posts come from) gets ONE
    trailer post whatever the video's age, unless its feed already carries a trailer post (a cut
    from the last 200 days keeps its place and its real recency). The video is the catalogue's own
    — the franchise's featured video when it is a postable trailer, else an official cut before an
    unmarked one, a trailer before a teaser before an announcement, the newest first; never a
    disowned cut or a re-cut, never the live news post's own video (or one published within ten
    days of it), and only a DATED one (an AniList-only trailer carries no publish date, so such a
    show gets none). It is an ordinary trailer post — `kind: "trailer"`, the usual
    `trailer:<franchiseId>:<site>:<videoId>` id (so its page, likes and saves work), `time` = the
    video's real publish instant (`basis: "published"`), `context: { kind: "recommended", … }` —
    and nothing on the wire marks it. In the ranking it is **evergreen**: never stale, and its
    recency is held at 0.6 (never less than its real age would give).
  - **Score** = `0.5 × affinity + 0.5 × recency`, highest first; ties by `time.at` desc, then
    `id` asc. `recency` is `0.5 ^ (age in days / 45)` from `time.at`. `affinity` of a recommended
    show is `0.7 + 0.3 × (1 − place / max(1, n − 1))`, its 0-based place among the `n` recommended
    shows that have a post in the candidates (the ranker's first is 1, its last 0.7); of any other
    show it is `0.6 × tasteMatch`. The weights are even on purpose: this week's news about a show in
    the viewer's genres outranks a recommended show's year-old post. An evergreen trailer's recency
    is `max(0.6, recency)`: news about the same show from the last ~33 days outranks its trailer.
  - **`tasteMatch`** (0–1) reads the library's genres in the shared taxonomy (TMDB's compound
    genres split, as the recommender does). Each library show adds a weight to its genres —
    Watching or Watched: how much of it was watched (one cour = 1), never under 0.3; Paused 0.5;
    Planned 0.4; Dropped 0 — and the strongest genre is scaled to 1. A show's match is the mean of
    its (up to three) best-matching genres; a show with no genres matches 0.
  - **Floor.** Three things leave a post out. **Stale:** `time.at` is more than 240 days before
    `generatedAt` — a recommended show's post included (exactly 240 days is still in); an evergreen
    trailer is exempt. **Nothing to look at:** the post has no `video`, and neither its part nor
    its show has a sharp picture — a portrait or landscape in `artwork` that the catalogue measured
    at 1000 px wide or more. An image with no measured width counts only when its `source` is
    `tmdb` (the poster and backdrop a TV show is stored with before its gallery is measured); an
    AniList cover or banner is never measured, so a show with only those needs a video. A
    recommended show's post is held to this too. **Not to the viewer's taste:** the show is not
    recommended and its `tasteMatch` is under 0.15 (skipped when the library's shows carry no
    genres at all — every match is 0 then and measures nothing; the other two still apply). When
    fewer than 20 posts fit, the best-scoring of everything left out — stale, pictureless and taste
    misses alike — fill the feed back up to 20, so a small candidate set can still carry any of them.
  - **Diversity.** Never two consecutive posts about the same show while a post about another
    remains; ONE post per show within the first 20 — the whole feed, so it is 20 different shows
    where it can be, and a recommended show appears as its news or its trailer, whichever scores
    higher (when fewer shows than slots remain, the cap gives way before the no-repeat rule).
  - **`context`** says why: `{ kind: 'recommended', reason }` on a recommended show's posts — the
    same `RecommendationReason` as `GET /me/recommendations`, worded by the same table;
    `{ kind: 'taste', genres }` on any other post whose `tasteMatch` ≥ 0.6 — the one or two of the
    show's genres the viewer has, their strongest first (taxonomy names: "Sci-Fi", "Action");
    `null` otherwise. The bar is high so the line means something: a show needs to sit squarely in
    the viewer's genres (one matching genre out of two is 0.5 at best, and carries no context). A
    post the refill brought back keeps whatever context it earned (a stale recommended post still
    says `recommended`). A client that predates the field ignores it.
  - **A library that says nothing** (empty, only dropped shows, or the viewer's part failed to
    load — the route never fails for it) gets the feed as it was before it was personal: every
    remaining post by `time.at` desc, then `id` asc, `context: null`, no floor (no age limit and
    no picture test either), no diversity pass, no discovery trailers.

  In every case there is **no fresh block and every post is `fresh: false`** (nothing in For you is
  "new since your visit"; the response still echoes `prevOpenedAt`); the list is capped at **20
  posts**; there are no episode posts (a For you show is not in the library); then the viewer's
  likes/saves/reminders and the global counts are attached, and every
  author row has `status: null`. `trending` is the Trending module — the first 8 untracked, unmuted
  trending shows as `FranchiseSummary`, ranked (unchanged, and not personal).
- **The feed never triggers research — nor a show page.** For you reads the recommender through
  its loader and ranker only: a recommended title with no show page yet is not queued for one (that
  is `GET /me/recommendations`' job) and simply has no posts. A trending or recommended show nobody
  follows may have only catalogue and trailer posts, or none (most recommended shows have no news at
  all). A show researched before research kept observations (before 3 Sep) posts
  from its stored `upcoming` when an announcement row names the same installment — the same
  `news:<announcement id>` post, dated at that announcement's first sighting until research sees it
  again.
- **`capabilities.comments`** mirrors `SOCIAL_COMMENTS_ENABLED`. When `false`, hide every reply and
  discussion affordance (comment counts included); likes, saves, reminders, hides and ratings stay.

## Post detail, Saved, Reminders

`GET /feed/posts/:id` (`:id` a PostId or an episode post's `ep:<mediaId>:<n>`; colons are fine in a
path segment, and percent-encoding is accepted):

```ts
interface FeedPostDetailResponse {
  post: FeedPost                // post.id is CANONICAL: use it as the thread subject
  franchise: FeedFranchise
  live: boolean                 // false = the feed no longer carries this post; the thread stays open
  storyline: StoryBeat[]        // the story so far, oldest → newest (at most 6 beats)
  threadSources: FeedSource[]   // every https source across the thread, deduped by URL
  capabilities: { comments: boolean }
}
interface StoryBeat {
  id: string                    // yyyymmdd (UTC) of the beat's day
  day: number                   // ms of the lead report
  publishers: string[]
  official: boolean
  primary: boolean
  headline: string | null       // a headline recovered from the lead URL's slug, or null
  url: string | null            // https only
}
```

- A `news:` post composes from its own announcement thread **even after it leaves the feed** (the
  season premiered and research now says "airing"): `live: false`, and its comments stay reachable
  from notifications and Saved. A trailer past the feed's 200-day horizon still composes.
- A `catalog:<mediaId>` post composes **whatever the part's status now**, as long as the part is
  still in the franchise: after the part premieres it is `live: false`, kind `dated` with the first
  episode's airing as its `premiere` when the catalogue still carries it, else `announced`.
- A `trailer:` post whose video the catalogue no longer lists (an enrichment refresh delisted it, or
  it stopped being an official, dated trailer) composes only while someone holds a like, a live
  comment, a save or a reminder on it: a bare post — `video: null`, `installment: ''`,
  `part: null`, `sources: []`, `isOfficial: false`, `discoveredAt: 0`, `time` = the thread's first
  activity (`basis: 'observed'`), `live: false`. Nobody holding a row on it → `404`.
- An `ep:<mediaId>:<n>` post composes for ANY part of a franchise and any episode that has aired
  (`404` before it airs, or when no franchise holds the part) — with no opt-in: only a client that
  knows the kind asks for one. While the part's dated `airings`
  still carry the episode (about 8 days back) it is the feed's post, dated `basis: "aired"`; `live`
  is true exactly while the caller's Following (asked with `episodes=1`) carries it (their status
  posts episodes, the part is main-story, the episode is its newest and aired within 7 days). An
  older episode's air instant is
  no longer in the payload: like a delisted trailer it composes only while someone holds a like, a
  live comment or a save on it, dated at the thread's first activity (`basis: "observed"`),
  `discoveredAt: 0`, `live: false`; nobody holding a row → `404`. `storyline` and `threadSources`
  are `[]`. The thread under it is the episode's room, gated as ever.
- **Alias:** asking for `catalog:<mediaId>` when an announcement already matches that part answers
  the `news:<id>` post. Always adopt `post.id` from the response.
- `post.context` is always `null` here, and in Saved and Reminders: the reason a post was in For
  you belongs to that feed's response.
- A post the viewer hid is still served (they followed a link to it). `404 {"error":"post not found"}`
  when the post cannot be composed (an unknown id, a part or show the catalogue no longer has, a
  delisted trailer nobody holds a row on, an episode that has not aired); `400` for an id that is
  none of the four grammars.

`GET /me/saved` and `GET /me/reminders` list the viewer's saves and reminders newest first:

```ts
interface SavedResponse    { items: { postId: string; savedAt: number;    post: FeedPost | null }[]; franchises: FeedFranchise[] }
interface RemindersResponse { items: { postId: string; remindedAt: number; post: FeedPost | null }[]; franchises: FeedFranchise[] }
```

`post: null` means the post can no longer be composed (for example a catalogue post whose part the
catalogue no longer lists). Show a quiet "no longer available" row, or drop it. A saved or reminded
post whose installment has since premiered, a saved trailer since delisted, or a saved episode post
from weeks ago, is still composed (`FeedPost` as above) — the viewer's own row keeps it reachable.

**Reminders.** A post with a `premiere` is scheduled LOCALLY by the client (anime at the air
minute, a TMDB date-only premiere at 9 AM local on its date). An undated post (`window`,
`announced`, `rumour`) is remembered by the server: when research upgrades that installment, a
notification goes to every reminder holder alongside the subscribers (see **NotificationItem**).

## Social

Every route here requires auth. Timestamps are ms epoch; writes answer `204` unless stated.

**Toggles are idempotent set-state**: `PUT` sets, `DELETE` clears, both with a JSON body, both
`204` whether or not anything changed — so clients mark them `idempotent: true` and keep one
newest-word-wins pending write per target. `DELETE` never checks that the target still exists.
A `catalog:` post's toggles key on its **canonical subject** (see **Post ids and thread subjects**):
once an announcement names the part they are stored under `news:<id>`, and a `DELETE` clears both.

| Toggle | Body | Notes |
|---|---|---|
| `/me/likes` | `{ subject: ThreadSubject }` | A post or an episode. An `ep:` like needs the episode to have AIRED (`409 episode_locked`, `reason: "unaired"`) — not watched: the subject is also the "Episode N is out" post, and a like shows nothing of the room. |
| `/me/saves` | `{ postId: PostId \| "ep:<mediaId>:<n>" }` | Listed by `GET /me/saved`. An episode post can be saved once the episode has aired (`404 post not found` before). |
| `/me/reminders` | `{ postId: PostId }` | Listed by `GET /me/reminders`. A dated post's reminder is also a LOCAL notification the app schedules. The server notifies on research news: a reminder on `news:<A>` hears that announcement, and a reminder on any `trailer:`/`catalog:` post hears every announcement for its show (see **News rows**). |
| `/me/hides` | `{ kind: "post", target: PostId \| "ep:<mediaId>:<n>" }` or `{ kind: "show", target: franchiseId }` | "Not interested" / "Mute <show>". `GET /me/hides` lists them newest first (`franchise` set for `show`). An episode post can be hidden once the episode has aired. |
| `/me/ratings` | `PUT { mediaId, episode, score: 0…100 }`, `DELETE { mediaId, episode }` | The emoji slider; one rating per (user, episode), re-rating replaces it. Needs the room open. |
| `/me/blocks` | `{ userId }` | `400 {"error":"self_block"}` for yourself; `404 user not found` for an account with no handle. `GET /me/blocks` lists them newest first. While comments are off, `PUT` answers `404 comments disabled` (nobody is shown to block); `GET` and `DELETE` always work. |

A `PUT` names a thing that must exist: `404 {"error":"subject not found"}` (or `post`, `franchise`,
`episode`, `user not found`) otherwise.

**Comments** are one flat thread per ThreadSubject, with an optional `parentId` for "replied to
you".

- `POST /social/comments` `{ id: uuid, subject, body, parentId?: uuid | null }`. **`id` is generated
  by the client** (a lowercase v4 uuid per draft) and is the upsert key that makes a retry safe. The
  server checks the id FIRST: an id that already exists and is yours answers **`200`** with the
  stored comment (no other check, no rate-limit charge — a replay is always cheap and stable); yours
  but deleted → **`410 {"error":"comment deleted"}`** (drop the pending write); someone else's →
  `409 id_conflict`. A new comment answers **`201`**. Both carry `{ comment: CommentView }`.
- Then, in order: a profile with a handle and display name (`409 handle_required`) and the current
  community rules accepted (`409 terms_required` + `currentVersion`); the subject exists (`404`);
  for an `ep:` room the gate is open (`409 episode_locked` + `reason: "unwatched" | "unaired"`); the
  body passes the content filter (`422 content_rejected` + `reason` — every refusal spends one of
  the hour's `rejected` budget, and once it is spent the refusal answers `429` instead); the parent
  exists in the SAME subject and is visible (`404 parent not found`); the rate limit (`429`).
- **Body rules.** The server normalises the text — NFC, CRLF → LF, zero-width and bidi controls
  removed, trailing spaces before a newline dropped, 3+ newlines collapsed to 2, trimmed — and
  stores the normalised text. Then: `empty`; `invalid_characters` (C0/C1 controls other than tab and
  newline); `too_long` over **280 Unicode code points** (count `unicodeScalars`, not UTF-16 units: an
  emoji with a skin tone is 2); `link` (any URL, `www.`, or bare domain — no links in comments in
  v1); `blocked_term` (slurs, sexual terms involving minors, self-harm incitement). The raw body may
  be at most 4000 characters. Normalisation only removes characters, so a client counting its
  trimmed draft is never refused for length by anything the server strips.
- `GET /social/comments?subject=…&sort=top|latest&cursor=…&limit=20` (limit 1…50; `top` default)
  answers a `CommentsPage`. `latest` is `(createdAt desc, id desc)`; `top` is `(likeCount desc,
  createdAt desc, id desc)`. The cursor is opaque. **`top` pages can repeat or skip a comment when
  like counts change between pages — dedupe by id.** A malformed cursor is `400`.
- The list shows what the viewer may see: not deleted, not hidden, the author not blocked by the
  viewer and not blocking the viewer, and not a comment the viewer reported. `total` counts the
  same set. `replyTo` names the parent's author only while the parent is visible to the viewer.
- `DELETE /social/comments/:id` deletes your own comment: its text is erased and a tombstone keeps
  the id (so a replayed POST answers `410`, never resurrects it); its likes and notifications go.
  Replies to it stay. Someone else's comment → `404`; already deleted → `204`. It works **even while
  comments are switched off**: deleting your own content is never switched off. **The tombstone is
  kept 30 days**, then a daily job removes it with the reports and notifications that point at it
  (a reply's `parentId` becomes null — its parent was already invisible). A replay of the same
  uuid after that creates a new comment; clients replay within their session, so this never meets
  a real retry.
- `PUT` / `DELETE /social/comments/:id/like` — a like on a visible comment (`404` for a missing,
  deleted, hidden or blocked-either-way author's comment; an `ep:` comment needs the room open).
- `POST /social/comments/:id/report` `{ reason, note? }` (`reason`: spam, harassment, hate, sexual,
  violence, spoiler, other; `note` ≤ 500 code points). One report per (reporter, comment): a repeat
  is `204` and changes nothing. Your own comment → `409 own_comment`. Only a comment you can see can
  be reported: a missing or deleted comment, one whose author you blocked or who blocked you, and a
  comment in an episode room that is not **open** to you (either reason) are `404 comment not found`
  — a HIDDEN comment can still be reported. A comment is **auto-hidden once
  `SOCIAL_AUTO_HIDE_REPORTS` (3) reports count**, and the reporter stops seeing it at once. A report
  counts while it is open and its reporter's account is at least `SOCIAL_REPORTER_MIN_AGE_HOURS`
  (24) old; the count is recomputed on every report, never incremented, so an erased reporter's
  report drops out and one person cycling accounts cannot hide a comment single-handed. Every report
  (a young account's too) reaches the operator's queue (`npm run moderation -- list`) and the
  server log; the operator is alerted on a comment's first open report and on every auto-hide. The
  author is told when a comment is hidden, and reporters when their report is decided (see
  **Moderation notices**).

```ts
interface PublicUser { id: string; handle: string; displayName: string }   // id = users.id
interface CommentView {
  id: string; subject: string; author: PublicUser; body: string; createdAt: number
  parentId: string | null
  replyTo: PublicUser | null    // the parent's author, while the parent is visible to you
  likeCount: number; liked: boolean; replyCount: number; mine: boolean
}
interface CommentsPage {
  subject: string
  locked: boolean               // episode rooms only: you may not read it; items is then []
  access: 'open' | 'unwatched' | 'unaired' | null   // null for post subjects
  total: number                 // visible comments for you (for a locked room: the global count)
  items: CommentView[]
  nextCursor: string | null
}
```

**Blocks** filter BOTH directions on every list (comments, replies, notifications): you do not see
someone you blocked, and someone who blocked you does not see you. Like and comment **counts are
global** (they are not filtered by blocks).

**The episode room** — `GET /social/episodes/:mediaId/:episode`:

```ts
interface EpisodeRoom {
  subject: string               // "ep:<mediaId>:<episode>"
  franchiseId: string; mediaId: number; episode: number
  access: 'open' | 'unwatched' | 'unaired'
  commentCount: number          // global visible count ("Mark it watched to join 12 comments")
  likeCount: number; liked: boolean
  rating: { count: number; average: number | null; yours: number | null }  // average 0–100, 1 dp;
                                                                           // null while locked or unrated
}
```

`404 episode not found` when the media is unknown or not part of a franchise.

**Status codes** (a client branches on the machine code in `error`, never on the English):

| Status | When | Body |
|---|---|---|
| `400` | Schema, parameter, cursor or id-grammar failure (an unknown field included) | `{ "error": "invalid request" }`, or `{ "error": "self_block" }` |
| `404` | The thing does not exist or is not visible to you — including a blocked-either-way author's comment — and, while comments are off, every comment route but your own delete, plus `PUT /me/blocks`, `PUT /me/profile`, `GET /me/profile/handle` and `POST /me/terms` | `{ "error": "<noun> not found" }` or `{ "error": "comments disabled" }` |
| `409` | Well-formed, but a precondition is missing | `handle_required`, `terms_required` (+`currentVersion`), `episode_locked` (+`reason`), `id_conflict`, `handle_taken`, `own_comment`, `terms_version_mismatch` (+`currentVersion`) |
| `410` | A replayed POST for a comment its author deleted | `{ "error": "comment deleted" }` |
| `422` | Content refused | `{ "error": "content_rejected", "reason": ContentRejection }`, `{ "error": "invalid_handle", "reason" }`, `{ "error": "invalid_display_name", "reason" }` |
| `429` | Rate limited | `{ "error": "rate_limited", "retryAfter": <seconds> }` + `Retry-After: <seconds>` (an integer ≥ 1) |
| `403` | Only a suspended account (see **Client failure semantics**) | `{ "error": "account_suspended" }` |

App-logic refusals are never `403`: a client treats a bare `403` as infrastructure.

`ContentRejection` = `empty | too_long | link | blocked_term | invalid_characters`.

**Rate limits** are per user (never per IP), in-process, sliding windows, keyed on the caller's
**Clerk identity** — not the account row, so deleting the account and signing straight back in does
not reset them. A denied request writes nothing and is not counted.

| Action | Default limit | Routes |
|---|---|---|
| comment | 5 / minute and 60 / hour | `POST /social/comments` (new comments only; a replay is free) |
| comment, new account | 5 / minute and **10 / hour** | the same, while the account is less than a day old (one log with the row above: the day it ages, its last hour still counts) |
| rejected | 20 / hour | every `422` from `POST /social/comments` and `PUT /me/profile`; once spent, those refusals answer `429` instead |
| read | 120 / minute | `GET /me/feed`, `GET /social/comments`, `GET /feed/posts/:id` (together) |
| toggle | 120 / minute | likes, saves, reminders, hides, ratings, comment likes |
| report | 20 / hour | `POST /social/comments/:id/report` |
| block | 30 / hour | `PUT /me/blocks` |
| profile | 10 / day | `PUT /me/profile`, `POST /me/terms` |
| lookup | 120 / minute | `GET /me/profile/handle` |
| export | 3 / hour | `GET /me/export` |

`SOCIAL_RATE_LIMIT_DISABLED=1` switches them all off for local work only: a production process
(`APP_ENV=production`) with it set refuses to boot.

**`SOCIAL_COMMENTS_ENABLED`** (server env). **The server's default is OFF**: a host whose `.env`
has no such key — every production `.env` written before this build — keeps comments off, so a
deploy can never switch public comments on by itself. `.env.example` sets `1`, so a local copy is
on. Turning them on in production is an explicit step, taken only once the published terms carry
the UGC clause and the production Clerk instance exists (`docs/beta-release.md`); every boot logs
`{ event: "social.config", commentsEnabled }`. When off, every `/social/comments*` route answers
`404 {"error":"comments disabled"}` — except `DELETE /social/comments/:id`, your own delete, which
always works — `GET /me/feed` says `capabilities.comments: false`, and the social notification kinds
are not listed. Nothing new about people is collected either: `PUT /me/profile`,
`GET /me/profile/handle`, `POST /me/terms` and `PUT /me/blocks` answer the same `404`. Likes, saves,
reminders, hides, ratings, `GET /me/profile`, reading and lifting blocks (`GET`/`DELETE /me/blocks`),
`GET /me/export` and `GET /social/episodes/…` keep working.

## Episode discussions (spoiler gate)

An episode room `ep:<mediaId>:<n>` is **open** to a viewer only when BOTH hold:

1. **the viewer has watched it**: their progress on `mediaId` is ≥ `n`, and
2. **episode `n` has aired by now**.

Otherwise it is `unaired` (checked first) or `unwatched`. A locked room still answers
`GET /social/comments` — `locked: true`, `items: []` and the room's global `total`, which drives
"Mark it watched to join N comments" — and refuses posts, comment likes and ratings with
`409 episode_locked` + `reason`. On `unwatched`, a client first replays the part's pending progress
write, then retries once. **The one thing an `unwatched` room allows is a like on the episode
itself** (`PUT /me/likes { subject: "ep:…" }`): the subject is also Following's "Episode N is out"
post, which the viewer sees before watching, and a like reveals nothing. An `unaired` episode
cannot be liked.

**Aired by now** is computed from the part's airing slots, the same rule that clamps progress:

- A timed slot (AniList) has aired once its instant has passed. A slot that has struck counts even
  before the hourly sync advances `nextAiringEpisode`.
- A **date-only** slot (TMDB) counts from **10:00 UTC on its UTC date** — the moment the earliest
  time zone on Earth (UTC+14) reaches the day after it. The client counts a date-only episode from
  the day after its date in the device's local day, which is never earlier, so **the server is never
  stricter than the client**: a room the app shows unlocked, the server accepts.
- A NOT_YET_RELEASED part has aired nothing. Only a FINISHED part counts as its size.
- A part whose episodes are still (or were only partly) coming — RELEASING, HIATUS, CANCELLED —
  counts from **evidence only**: the episode before its next slot, a slot that has struck, and any
  dated episode that has aired. Never the catalogue's episode total, which counts announced episodes
  as aired (AniList episode lists are undated, so a schedule gap would open every announced room).
- With **no evidence at all** (no slot and no dated episode) the count is unknown and the room is
  **`unaired`, whatever the progress** — it fails closed, and opens once the catalogue has a slot or
  dates, or the part finishes. The client treats a part with no airing slot, no `nextAiringAt` and no
  dated airing the same way.

`PUT /me/progress` shares the rule: a RELEASING part cannot be marked past its aired count (a mark
already stored above it is kept, never pulled down). Both progress endpoints also keep the STATUS rule
(`statusAfterWrites`, services/library.ts; the app mirrors it in `AppModel.resume` /
`settleCompletion`): a forward mark on a `planned` show moves it to `watching`, and a write that
leaves the story watched through — every non-spin-off season and every non-optional OVA, ONA and film
that is not a side story watched to what has aired, with no part releasing or announced — moves a
`planned` or `watching` show to `completed`. Nothing else moves on the server: `completed`, `paused`
and `dropped` are the user's word (a Watched show whose story goes on is the app's call, since only
it knows about a rewatch in flight). The move is sequenced on the subscription like the client's
own status writes, so a later status from the same writer keeps its place. `PUT /me/progress` does
not return the status; the next library read carries it. A `reset` re-locks rooms for the resetting
viewer; comments they already wrote stay visible to others, and Activity stops printing the text of
replies in rooms that are no longer open to them.

## Identity

The public face of an account is `PublicUser` — `{ id, handle, displayName }` — and nothing else.
**The email and the Clerk id are never public**, and the Clerk display name is never published as-is:
the user confirms a first name.

```ts
interface ProfileResponse {
  userId: string
  handle: string | null
  displayName: string | null
  termsAcceptedAt: number | null
  termsVersion: string | null
  currentTermsVersion: string   // SOCIAL_TERMS_VERSION
  canComment: boolean           // handle && displayName && termsVersion === current && comments enabled
}
interface HandleAvailability { handle: string; available: boolean; reason: null | 'taken' | HandleRejection }
```

- **Handle** (picked at the first reply; `PUT /me/profile { handle, displayName }`): trimmed, one
  leading `@` dropped, lowercased; 3–20 characters of `[a-z0-9_.]`; no leading, trailing or doubled
  `.`; at least one letter; not reserved (admin, moderator, official, support, previously,
  and the rest of the server's list, plus the prefixes `previously`, `official`, `admin`,
  `support`, `mod.`, `mod_`); no blocked term. A handle is ONE token, so a blocked term of four or
  more letters is refused ANYWHERE in it with `.`/`_` removed ("xslurx", "slur123"), after a short
  reviewed list of ordinary words that merely contain one ("grape", "peacock", "analog") is cut out;
  shorter terms are refused only as a whole word. Unique: a taken handle is `409 handle_taken`.
  `HandleRejection` = `length | characters | dots | no_letter | reserved | blocked_term`.
- **Display name**: normalised to one line, 1–40 code points, no control characters, no `@` (keeps
  emails out), no link, at least one letter, no blocked term (names also refuse general profanity,
  which comments allow), and not **reserved**: no word of the name (a plural and leet spellings
  too), nor the whole name with its separators removed, may be the app, its staff or a system voice
  (previously, admin, administrator, moderator, mod, official, support, staff, team,
  system, security) or a brand whose news or data the app carries (anilist, tmdb, justwatch,
  myanimelist, crunchyroll, funimation, hidive, netflix, aniplex) — "Previously Support" and
  "Crunchyroll" would read as the official voice beside every reply. `DisplayNameRejection` =
  `empty | too_long | invalid_characters | link | blocked_term | no_letter | at_sign | reserved`
  (decode leniently: a reason the client does not know reads "That name can't be used").
- `GET /me/profile/handle?handle=` checks availability as you type.
- **Community rules come first.** Before a first comment the user accepts the current rules:
  `POST /me/terms { version }` stamps the time and version; a stale version is
  `409 terms_version_mismatch` + `currentVersion`. **No identity is collected before that:**
  `PUT /me/profile` and `GET /me/profile/handle` answer `409 terms_required` + `currentVersion`
  until the current version is accepted (so a client's name editor sends the user through the rules
  first). When the rules change, posting answers `409 terms_required` + `currentVersion` until the
  new version is accepted.
- **Comments off.** While `SOCIAL_COMMENTS_ENABLED` is off, `PUT /me/profile`,
  `GET /me/profile/handle` and `POST /me/terms` answer `404 {"error":"comments disabled"}`: nothing
  would show a name. `GET /me/profile` and `GET /me/export` always answer.
- **Operator reset.** `npm run moderation -- reset-identity <clerkId|@handle>` clears an offensive
  handle and display name short of a ban: both become `null`, `canComment` turns `false`, the next
  reply answers `409 handle_required` so the user picks again, and until they do their comments are
  unlisted (a thread lists only authors with a handle).
- Deleting the account frees the handle.

## Discover: genres

A canonical genre vocabulary over both catalogues (an AniList genre and its TMDB counterpart are one
key; TMDB's combined genres such as "Action & Adventure" and "Sci-Fi & Fantasy" feed both halves).
Adult titles are never listed, and Ecchi, Hentai, News, Soap and Talk are not genres here.

- `GET /discover/genres?source=anilist|tmdb` (absent = the viewer's **Audience**: one catalogue for
  an `anime` or `tv` viewer, both otherwise; the response's `source` says which) → `DiscoverGenresResponse`: every genre
  with at least 3 qualifying franchises, most titles first (then by key). `posters` are up to four
  portrait URLs of the genre's top trending titles, for the tile's collage. Cached ~30 minutes.
- `GET /discover/genres/:key?source=&limit=24&cursor=` (limit 1…50; `source` defaults the same way) → `DiscoverGenrePage`: the
  genre's franchises ranked by trending, then popularity. **Owned titles are marked, not excluded**:
  `FranchiseSummary.status` is set for a show in the viewer's library. The cursor is opaque; the
  ranking moves hourly, so dedupe by id across pages. Unknown key → `404 genre not found`.

```ts
interface DiscoverGenre { key: string; name: string; count: number; posters: string[] }
interface DiscoverGenresResponse { source: 'anilist' | 'tmdb' | null; genres: DiscoverGenre[]; generatedAt: number }
interface DiscoverGenrePage { genre: DiscoverGenre; franchises: FranchiseSummary[]; nextCursor: string | null }
```

Keys: `action`, `adventure`, `comedy`, `drama`, `fantasy`, `sci-fi`, `mystery`, `romance`, `horror`,
`thriller`, `psychological`, `supernatural`, `slice-of-life`, `sports`, `mecha`, `music`,
`mahou-shoujo`, `crime`, `documentary`, `family`, `reality`, `war-politics`, `western`, `animation`.
Genre names are catalogue data (English), as the franchise's own `genres` carry them.

## Client-side derivation (ported from the legacy React app's `format.ts`/`App.tsx`)

`/me/library` returns every subscribed franchise with **all** its parts (airing + progress).
The client computes views exactly like the old app, but per **releasing part**:

- **episodesBehind(part)** = `isReleasing ? max(0, airedEpisodes - progress) : 0`.
- **availableEpisodes(part)** = `0` when `status == "NOT_YET_RELEASED"`, `airedEpisodes` while
  releasing, otherwise `airedEpisodes || totalEpisodes`. A releasing part with no dated episodes
  or next slot reports zero verified aired episodes; the planned total is not evidence of availability.
  Announced parts must never contribute to a "keep watching" backlog.
- **premiereAt(part)** = `nextAiringAt` while `status == "NOT_YET_RELEASED"` — both sources put a
  dated announced part's premiere in that slot. `null` there means the date is genuinely unknown
  (release TBA), never just "the source didn't say".
- **`nextAiringAt` in the past is stale, not a schedule.** Sources don't advance the slot the
  instant an episode airs, so clients treat a `nextAiringAt` whose *local day* is already behind
  today as absent (same-day is kept) rather than rendering it as an upcoming airing.
- **Today / "Out now"** = releasing parts whose `lastAiredAt > prevOpenedAt`. `prevOpenedAt` is the
  **previous visit**: the answer of this session's `POST /me/opened` once it has landed (a library or
  feed response never moves it after that), and the response's own `prevOpenedAt` only until then.
  Never `max()` the two — that re-introduced the echo of the stamp the session just wrote.
- **Airing soon** = releasing parts with `nextAiringAt` within 48h.
- **Schedule** = the dated airings of tracked parts, bucketed by the device's local day.
- **Library buckets** = Behind / Caught up (releasing, behind 0) / Finished / Plan, computed
  from the franchise's releasing part + subscription status.
- Render franchise chronology by `watchOrder`; use `relationship`/`optional` for honest side-story
  labels. Never reconstruct one order by separately sorting season/movie arrays.
- **Mark caught up** = `PUT /me/franchises/:id/progress {"mode":"caught_up"}`. This updates every
  member atomically and leaves a `NOT_YET_RELEASED` part at zero. The legacy per-part endpoint
  remains valid for a single +/- control.

Time math is in the **device's time zone** (the legacy app's IST-only helpers are retired). The
anchor rules live in iOS `Util/TemporalCopy.swift` and `FranchisePart.airedByNow`: a timed slot has
aired once `at <= now`; a date-only (TMDB) slot counts from the day after its UTC date in the local
day and never prints a clock; one temporal expression per item.

## Auth

iOS uses the Clerk iOS SDK; attaches the session JWT as `Authorization: Bearer …`.
Backend verifies via `@clerk/backend` `verifyToken` (JWKS / networkless `CLERK_JWT_KEY`),
maps `sub` (Clerk user id) → `users` row (upsert on first request), exposes `req.user`.

### Two issuers, and only one of them is a JWT

`dev:<clerkId>` is a **distinct, non-production issuer**, not a relaxed mode of the real one. It is
not a JWT and never will be, so:

- The server accepts it only when `APP_ENV` is not `production` **and** `DEV_AUTH_BYPASS` is set.
- **A production process rejects `dev:` tokens with `401 {"error":"invalid token"}` regardless of
  `DEV_AUTH_BYPASS`**, and never forwards a dev id to Clerk.
- A production process **refuses to start** if it sets `DEV_AUTH_BYPASS`, or if it has neither
  `CLERK_JWT_KEY` nor `CLERK_SECRET_KEY` (nothing could verify a real token). Fail closed, loudly,
  at deploy time.

The policy lives in `src/auth/authConfig.ts` (`devBypassAllowed`, `assertAuthConfig`) and
`src/auth/identity.ts` (`resolveIdentity`); `DEV_AUTH_BYPASS` is read nowhere else.

Deploy test — `npm run auth:smoke -- https://<host>` asserts `GET /health` → 200 and
`GET /me/library` with a `dev:` bearer → **401**, exiting non-zero otherwise.

### Client failure semantics

`401` means the session is gone (the client refreshes its token once, retries, and only then signs
out). That includes `401 {"error":"account deleted"}`, which every authenticated route answers for
15 minutes after `DELETE /me` (see **Account deletion**): a queued write that meets it is dropped,
never retried. `403` — including a Cloudflare/WAF HTML challenge — is an **infrastructure** failure: the
session is kept and the surface shows a stale/error frame, **with one exception: a `403` whose JSON
body is `{"error":"account_suspended"}` is a suspension**, not infrastructure. Read the body before
classifying. A suspended account gets it from every authenticated route except `DELETE /me` and
`GET /me/export`, which keep answering so the user can still delete or download their data; the
app shows a suspended state (sign out or delete). A ban takes effect within
`SOCIAL_BAN_CACHE_SECONDS` (60 s) of the operator's command. If the ban list cannot be read at all
(the database is down at boot, or the server restarted before `db:migrate`), the check fails OPEN —
requests are served as not suspended, `moderation.ban_cache_unavailable` is logged and the next
request retries — rather than answering every authenticated route with a `500`.

`409`, `410` and `422` from the social routes are **final** answers about the request, never
retried: branch on the machine code (`handle_required` → the handle picker, `terms_required` → the
rules sheet then one retry, `episode_locked` with `reason: "unwatched"` → replay the part's pending
progress then one retry, `410` → drop the pending comment, `content_rejected` → say why from
`reason`). A `429` from a social route carries `retryAfter` (and `Retry-After`); the comment limits
are per hour, so a client stops retrying after the 8 s cap below and tells the user, never loops. Any response whose body is HTML is
treated the same way at any status, including 2xx (captive portals).

Two things that look like `401` but are not. A client that cannot **mint** a token (an expired
session JWT with no network to renew it) never reaches the server and reports a *transport*
failure — being offline must not sign anyone out. A forced refresh that could not reach the token
issuer is likewise transport, not a dead session. Only an issuer that answers — with the same token,
or with none — turns a `401` into a sign-out.

Every request is bounded by one wall-clock budget (~16.6 s: a 15 s attempt plus at most ~1.6 s of
backoff), shared across retries, so a black-holed upstream can never hold a skeleton on screen.
`429` and `5xx` are retried twice while that budget lasts (`Retry-After` honoured, capped at 8 s);
an exhausted `5xx` whose body is HTML lands as infrastructure.


## History import

All routes require the signed-in account. Imports never change the source service. Export files
stay on the device; only parsed watch-history fields are submitted (no account email, IP log,
comments, ratings or private notes). The request limit is 4 MiB; at most 8 previews per account
per 10 minutes (`429`, `Retry-After: 600`).

### `POST /me/import/preview?async=1`

Body is one of:

```ts
{ source: 'anilist', username: string } // public anime list, 1–60 characters
{ source: 'mal', rows: { malId: number, status: string, watched?: number, title?: string | null }[] }
{ source: 'tvtime', shows: {
  tvdbId?: number | null, title?: string,
  seasons: { number: number, watched: number[] }[],
  followed?: boolean, forLater?: boolean, archived?: boolean,
  lastWatchedAt?: number | null // milliseconds since epoch
}[] }
```

MAL accepts 1–6,000 rows; TV Time accepts 1–4,000 shows. Missing booleans are false; missing
nullable fields become null. Invalid bodies/IDs return `400 { error: 'invalid request' }`.

The app uses `async=1`: `202 { id, state: 'reading' }` starts an account-owned read job.
`409 { error: 'import_busy' }` means an earlier preview for this account is still reading or the
preview queue is full. This read phase writes no library data. Without the query flag, small
API callers can receive the completed `ImportPreview` synchronously.

### `GET /me/import/:id/preview`

Poll the read-job id (the app polls every 2 seconds). The response is one of:

```ts
{ id, state: 'reading' }
{ id, state: 'ready', preview: ImportPreview }
{ id, state: 'failed', error: 'import_not_found' | 'import_private' | 'import_unavailable' }
```

For synchronous previews these errors instead use HTTP 422 (missing/private list) or 503
(upstream unavailable). A provider outage is not counted as an unmatched title.

```ts
interface ImportPreview {
  id: string // apply this id; it differs from the read-job id
  source: 'anilist' | 'mal' | 'tvtime'
  listed: number // source entries, including unmatched and policy-skipped rows
  ready: number // grouped franchises already in the catalogue
  toFetch: number // missing anime entries / TV shows, not necessarily distinct franchises
  episodes: number // planned/source watched counts; final writes obey aired ceilings
  byStatus: Record<'watching' | 'completed' | 'planned' | 'paused' | 'dropped', number>
  unmatched: { count: number, titles: string[] } // up to 12 titles
  skipped: { count: number, reasons: { adult_content: number } }
  sample: FranchiseSummary[] // up to 9 catalogue shows
}
```

### `POST /me/import/:id/apply` and `GET /me/import/:id`

Apply the completed preview id; GET follows its progress. Re-applying that id is idempotent.

```ts
{ id: string, state: 'preview' | 'running' | 'done', shows: number, remaining: number, failed: number,
  skipped: { count: number, reasons: { adult_content: number } } }
```

`shows` counts distinct franchises processed successfully (including existing memberships),
`remaining` counts pending source entries/shows, and `failed` counts failed ready franchises
or pending entries/shows. Counts use different units for anime, whose seasons are grouped.
Already catalogued shows are written first; missing shows follow in the background. Progress
increases are atomic and capped to aired episodes. Existing memberships retain their status.
An import can correct the status of a membership it just created as more seasons are resolved,
but only while that same membership and status are unchanged. Removing a show during the tail
prevents that import from re-adding it. Background import requests share a paced AniList budget.

Titles explicitly flagged adult or carrying the Hentai genre are omitted from consumer catalogue/import
results. Policy skips are counted separately from unmatched names and provider failures. Cached catalogues
are checked again when apply writes progress; already-owned records remain in storage and account export.

Unknown, expired or another account's job/preview returns `410 { error: 'import_expired' }`.
Sessions live in server memory: unused previews and completed results expire after 30 minutes;
running jobs are not evicted. A server restart loses remaining work, but completed library writes
remain. Re-importing safely fills gaps. The app remembers progress across relaunches, and Profile's
import row reopens the current result. Closing a reading sheet cancels client polling, not the
server read; no library writes happen until Apply.

### Mapping limits

- AniList/MAL statuses are combined per franchise; finishing a single season does not finish an
  unwatched later season. Repeating means the original part was finished; no rewatch-session
  events are manufactured.
- MAL IDs map through AniList's `idMal`; absent mappings are reported as unmatched.
- TV Time resolves TheTVDB series IDs through TMDB's TV results. Title fallback requires a unique
  exact normalized title and honors a trailing year. Ambiguous remakes are left unmatched.
- TV progress uses the highest watched episode per numbered season. TV Time anime is matched to
  AniList and its total watched count is allocated across the story in order. Numbering differences
  and non-contiguous histories are therefore approximate; the preview explains this.
- TV Time movies, ratings, comments, original watch timestamps and distinct rewatch sessions are
  not imported. The latest watch date only helps choose Watching versus Paused.
- Native file readers accept MAL XML/gzip and TV Time's GDPR/newer CSV or ZIP shapes. They verify
  gzip/ZIP checksums, reject truncated XML/archives and cap input/inflated data at 64 MiB. Encrypted,
  ZIP64 and multi-volume archives are unsupported.
