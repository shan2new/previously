import Foundation

/// Catalogue news, deliberately independent of subscription status and watch progress.
struct ReleaseNews: Equatable, Sendable {
    let headline: String
    let detail: String?
}

extension Franchise {
    /// The curated release WITH its verb, in the app's one date style: "Premieres 20 Nov" (a day;
    /// this year's without its year, as every other date in the app), "Premieres Summer 2027" (a
    /// window, printed as announced). The bare "20 Nov 2026" under "SEASON 3 ANNOUNCED" said
    /// neither what happens on that day nor matched Library's "Returns 3 Oct" (review, 23 Sep).
    private func premiereLine(_ news: FranchiseUpcoming, now: Int64) -> String? {
        if news.releaseWindow?.precision == .day, let key = news.releaseWindow?.sortKey,
           let ts = Formatting.utcTimestamp(y: key / 10_000, mo: (key / 100) % 100, d: key % 100) {
            return newsLine(TemporalCopy.dateWord(ts, now: now, anchor: .utcDate))
        }
        // A window in sentence case ("summer 2027"), as the Library prints it.
        guard let window = ArtworkSet.nonEmpty(news.displayRelease), let first = window.first else { return nil }
        return newsLine(first.lowercased() + window.dropFirst())
    }

    /// "Returns" for a show you have been watching (it went away and comes back — the Library's
    /// word), "Premieres" for one you have not started (iteration 2: the shelf said "Returns 3
    /// Oct" and the page "Premieres 3 Oct" about one date).
    private func newsLine(_ date: String) -> String {
        let seen = effectiveStatus == .watching || effectiveStatus == .completed
            || parts.contains { $0.progress > 0 }
        return seen ? TemporalCopy.returnsOn(date) : TemporalCopy.premieres(date)
    }

    func releaseNews(now: Int64) -> ReleaseNews? {
        // Nothing out yet: a NEW SERIES, not "Season 1 announced" (review i3, Seven Havens).
        let newSeries = !parts.isEmpty && parts.allSatisfy(\.isUpcoming)
        if let news = upcoming, news.isFutureInstallment, !news.hasArrived(now: now) {
            let name = ArtworkSet.nonEmpty(news.next) ?? Copy.Release.newSeason
            let split = Copy.Release.announcement(name)
            let headline = news.isRumored ? Copy.Library.rumored(next: news.next)
                : (newSeries ? Copy.Release.newSeries : split.badge)
            // A quarter is a window, never its synthetic first day. Rumours get no promised date.
            let release = !news.isRumored && news.releaseWindow.map { $0.precision != .unknown } == true
                ? premiereLine(news, now: now) : nil
            let date = seasonPartsInOrder.first { $0.isUpcoming && $0.canonicalLabel == name }?
                .announcedDateLabel(source: source).map { newsLine($0) }
            let when = release ?? date ?? TemporalCopy.noDateAnnounced
            let detail = [news.isRumored || newSeries ? nil : split.subject, news.isRumored ? nil : when]
                .compactMap { $0 }.joined(separator: " \u{00B7} ")
            return ReleaseNews(headline: headline, detail: detail.isEmpty ? nil : detail)
        }
        if let part = seasonPartsInOrder.first(where: \.isUpcoming) {
            return ReleaseNews(headline: newSeries ? Copy.Release.newSeries : part.announcementLabel,
                               detail: part.announcedDateLabel(source: source).map { newsLine($0) }
                                   ?? TemporalCopy.noDateAnnounced)
        }
        if let at = nextAiring(now: now) {
            // The state on the badge, the episode on the line — never "New episode …" for an
            // episode that has not aired (review, 23 Sep).
            let part = releasingPart
            let episode = part?.airings.first(where: { $0.at == at })?.episode ?? part?.nextEpisodeNumber
            return ReleaseNews(headline: Copy.Label.airing,
                               detail: Copy.Progress.episodeAirs(episode, when: TemporalCopy.airs(at: at, now: now, source: source)))
        }
        if let news = upcoming, news.status == "recently_aired", let name = ArtworkSet.nonEmpty(news.next) {
            return ReleaseNews(headline: Copy.Release.available(name), detail: nil)
        }
        return nil
    }
}

struct FranchiseProgressValue: Codable, Equatable, Sendable {
    let mediaId: Int
    let episodes: Int
}

/// The confirmation, write and Undo use the same released-only snapshot.
struct WatchedBatch: Sendable {
    let parts: [FranchiseProgressValue]
    let previous: [FranchiseProgressValue]
    let episodeCount: Int
    let seasonCount: Int
    /// The story's released films the batch marks too (the whole series only, never a season).
    let filmCount: Int
    let status: WatchStatus

    init(franchise: Franchise, seasonID: Int? = nil, now: Int64) {
        let seasons = franchise.seasonPartsInOrder
        self.init(franchise: franchise,
                  selected: seasons.filter { seasonID == nil || $0.mediaId == seasonID },
                  includesFilms: seasonID == nil, now: now)
    }

    /// Every season BEFORE `part` — "I'm on Season 3" says Seasons 1–2 are watched (the add
    /// prompt's part-way answer, review i3). Films are left alone: where a film sits in someone's
    /// viewing is not something "Season 3" says.
    init(franchise: Franchise, before part: FranchisePart, now: Int64) {
        self.init(franchise: franchise,
                  selected: franchise.seasonPartsInOrder.filter { $0.sequence < part.sequence },
                  includesFilms: false, now: now)
    }

    private init(franchise: Franchise, selected: [FranchisePart], includesFilms: Bool, now: Int64) {
        let seasons = franchise.seasonPartsInOrder
        let anchor = franchise.timeAnchor
        let changed = selected.filter {
            !$0.isUpcoming && min($0.markTarget(now: now), $0.progressCeiling(now: now, anchor: anchor)) > $0.progress
        }
        // "I've seen all of it" includes the story's films: marking the seasons alone filed Demon
        // Slayer as Watched over "NEXT UP · Movie 1: Mugen Train" (iteration 2).
        let films = !includesFilms ? [] : franchise.mainStoryMovies.filter {
            !$0.isUpcoming && $0.availableEpisodes() > $0.progress
        }
        let filmParts = films.map { FranchiseProgressValue(mediaId: $0.mediaId, episodes: max(1, $0.availableEpisodes())) }
        let seasonParts = changed.map {
            FranchiseProgressValue(mediaId: $0.mediaId,
                                   episodes: min($0.markTarget(now: now), $0.progressCeiling(now: now, anchor: anchor)))
        }
        parts = seasonParts + filmParts
        previous = changed.map { .init(mediaId: $0.mediaId, episodes: $0.progress) }
            + films.map { .init(mediaId: $0.mediaId, episodes: $0.progress) }
        episodeCount = zip(seasonParts, changed).reduce(0) { $0 + $1.0.episodes - $1.1.progress }
        seasonCount = changed.count
        filmCount = films.count
        let targets = Dictionary(uniqueKeysWithValues: parts.map { ($0.mediaId, $0.episodes) })
        let released = seasons.filter { !$0.isUpcoming && $0.markTarget(now: now) > 0 }
        let caughtUp = !released.isEmpty && released.allSatisfy {
            (targets[$0.mediaId] ?? $0.progress) >= $0.markTarget(now: now)
        }
        status = caughtUp && !seasons.contains(where: \.isReleasing) ? .completed : .watching
    }
}

// SP-7 — the derivations more than one screen needs. This file is the ONLY place they exist.
//
// Two halves, kept as separate extension blocks so the merge that produced them stayed textual:
//   • p0-engineering: canonical labels, watch context, the undo snapshot, `WatchStatus.displayName`;
//   • detail: the aired/renderable/mark-target ladder ported out of `SeasonAccordion`, plus the
//     franchise-level "which part am I on" and "is the whole thing finished" questions.
//
// House rule for everything here: **`sequence` is the ordering key and never displays.** It counts
// a franchise's members, which is not the number the world uses for a season — rendering "S5"
// beside a label that reads "Season 4" is spec board 13's P0 #3, observed live on 2026-08-22.

// MARK: - FranchisePart · canonical labels (spec board 13, P0 #3)

extension FranchisePart {
    /// The source's OWN label for this installment — "Season 4", "Final Season", "Part 2".
    ///
    /// **Never derived from `sequence`.** Empty string when the source gave no label — unknown
    /// says unknown; a fabricated "Season 1" is worse than nothing.
    var canonicalLabel: String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        // An extra the server named from its kind arrives as "Ona 4" / "Ova 2": initialisms.
        for (written, initialism) in [("Ona", "ONA"), ("Ova", "OVA")]
        where trimmed == written || trimmed.hasPrefix(written + " ") {
            return initialism + trimmed.dropFirst(written.count)
        }
        return trimmed
    }

    /// The catalogue relates this part to the work as a spin-off. A spin-off is an extra, never a
    /// season of the show, whatever its `kind` says.
    ///
    /// A SHORT-FORM series attached after the work's own first season, whose one tie to it is
    /// "my PARENT is in it", is one too: Re:ZERO's Break Time and Re:PETIT shorts arrived as "Season
    /// 6" and "Season 7" (4 Oct). Not the FIRST of its kind: the old rows also store PARENT for a
    /// first season its side stories point at (Double Wish, Ninja Hattori — short-form works in
    /// their own right). The server derives the relation correctly now (`grouping/relationship.ts`:
    /// SIDE_STORY / SPIN_OFF for the child, nothing for the parent); this reads the rows written
    /// before it, until `npm run relations:backfill -- --apply` has run.
    var isSpinOff: Bool {
        switch relationship?.uppercased() {
        case "SPIN_OFF": return true
        case "PARENT": return format?.uppercased() == "TV_SHORT" && sequence > 1
        default: return false
        }
    }

    /// Part of the story's SPINE: a season, an ONA/OVA or a film that is a sequel or prequel of
    /// its neighbours (or the first entry, with no relation). Side stories, spin-offs, recaps
    /// ("SUMMARY") and specials are extras — they live on the extras shelf and never become
    /// "what's next": a 2018 recap OVA opened Mob Psycho 100 on "NEW EPISODE · OVA 1", and a
    /// spin-off ONA put "8 EPISODES LEFT" over a finished Black Clover (review, 23 Sep).
    var isMainStory: Bool {
        guard kind == .season || kind == .ona || kind == .ova || kind == .movie else { return false }
        let name = (label + " " + title).lowercased()
        // A re-edit of the story is never the story: "ReAwakening (Compilation)", One Piece's
        // "Log: Fish-Man Island Saga" (a TV-format recap AniList relates as SEQUEL).
        if ["compilation", "recap", "summary", "digest", "log:"].contains(where: name.contains) { return false }
        if kind == .movie {
            // A FILM is story only as a sequel (iteration 2: a prequel recap film was promoted to
            // NEXT UP on a finished show). Infinity Castle qualifies.
            return relationship?.uppercased() == "SEQUEL"
        }
        // A TV SEASON is the story unless it is a spin-off, whatever else the catalogue calls it:
        // AniList relates One-Punch Man Season 2 as a SIDE_STORY, so "I'm on Season 2" marked
        // Season 1 and the app sent the viewer to Season 3 — the picker listed the season and
        // resume skipped it (review i5, F2).
        if kind == .season { return !isSpinOff }
        // An OVA/ONA tied to a film is a promo, not the story ("Film: Strong World – Episode 0"
        // took Today's billboard as "Episode 0 · Episode 1", review i5, F1).
        if name.contains("film") || name.contains("movie") || name.contains("episode 0") || name.contains("episode:0") {
            return false
        }
        // PARENT is not the story: the part names a member of the work as its parent and has no
        // sequel or prequel of its own — the shorts that air beside a season. Re:ZERO's "Break
        // Time" run took Home's billboard as "19 EPISODES LEFT · Ona 4 · Episode 1" while Season 4
        // sat one episode behind (owner, 4 Oct: "why is Ona being emphasized so damn much?").
        switch relationship?.uppercased() {
        case nil, "SEQUEL", "PREQUEL": return true
        default: return false
        }
    }

    /// "Episode 19". Never "E19", never "Ep 19" (board 09 notation table).
    func episodeLabel(_ n: Int) -> String { Copy.episode(n) }

    /// The full watch context for a metadata line:
    /// "Season 4 · Episode 19" · "Episode 19" (no label) · "Kizumonogatari" (a movie has no
    /// episode to name).
    func watchContext(episode: Int) -> String {
        let label = canonicalLabel
        if kind == .movie { return label }
        if label.isEmpty { return episodeLabel(episode) }
        return "\(label) · \(episodeLabel(episode))"
    }
}

// MARK: - FranchisePart · the aired / renderable / mark-target ladder
//
// Ported out of `SeasonAccordion`, which is being retired. Three different questions that were
// repeatedly confused for one another:
//   provenAiredCount      — how many episodes we can PROVE have aired;
//   renderableEpisodeCount — how many rows to draw (plumbing; NEVER shown as a season length);
//   markTarget            — what "mark this season watched" writes.

extension FranchisePart {
    /// How many episodes of this part have provably aired.
    ///
    /// `airedEpisodes` is the server's derivation from catalogue airing data, but a part caught
    /// mid-sync can report 0 while its own episode list already carries dates in the past. Trusting
    /// that blindly dims every row and collapses `markTarget` onto the user's progress, so a season
    /// header renders "watched" purely because there is nothing left to compare against. An episode
    /// whose air date has passed HAS aired, so take the higher count.
    ///
    /// Strictly BEFORE today, not "today or earlier": today's slot is the one the catalogue is
    /// still counting down to, and swallowing it here would cost the next-to-air row its date badge
    /// on every healthy season the moment its drop day arrives.
    func provenAiredCount(now: Int64) -> Int {
        guard isReleasing else { return airedEpisodes }
        let dated = episodes.reduce(0) { acc, ep in
            guard let d = ep.airDate,
                  Formatting.dayDiff(ts: d, now: now, anchor: Episode.airDateAnchor) < 0 else { return acc }
            return max(acc, ep.number)
        }
        // A per-episode slot that has struck is an aired episode too (`airedByNow`): without it the
        // mark target trailed the catalogue's count by a sync, so the episode Today had just called
        // "out now" could not be marked. For a date-only source this admits the drop day once its
        // synthesized 17:00 UTC instant has passed — TMDB's own date has arrived by then.
        let struck = airings.filter { $0.at <= now }.map(\.episode).max() ?? 0
        return max(airedEpisodes, dated, struck)
    }

    /// How many episode rows to render.
    ///
    /// With a known total, never exceed it. With an unknown total (0 — common for ongoing AniList
    /// shows) extend one past what has aired so the next-to-air row can carry its date badge. Row
    /// plumbing ONLY: it is a guess, and a guess must never be shown as a season length.
    func renderableEpisodeCount(now: Int64) -> Int {
        // A season order is not an episode list. Upcoming rows need editorial details,
        // not numbered placeholders (even when a provider assigns them projected dates).
        if isUpcoming { return announcedEpisodeNumbers.last ?? 0 }
        if totalEpisodes > 0 { return totalEpisodes }
        let aired = provenAiredCount(now: now)
        let nextToAir = (isReleasing && nextAiringAt != nil) ? aired + 1 : 0
        return max(aired, progress, nextToAir)
    }

    /// What "mark this season as watched" writes: catch up to what has aired for a releasing
    /// season, else the full episode count. Bounded again by `progressCeiling` at the write.
    func markTarget(now: Int64) -> Int {
        if isUpcoming { return 0 }
        return isReleasing ? provenAiredCount(now: now) : renderableEpisodeCount(now: now)
    }

    var announcedEpisodeNumbers: [Int] {
        // Dates still belong to Schedule and the season's premiere fact. A detail list of
        // thirteen "Episode N" rows, with no titles/stills/synopses, adds no episode content.
        return Set(episodes.filter(\.hasAnnouncedDetails).map(\.number))
            .filter { $0 > 0 }.sorted()
    }

    var announcementLabel: String {
        Copy.Release.announced(canonicalLabel)
    }

    /// Every available episode of this part is watched. Uses `.nowMs` because "complete" is a
    /// property of the part at the moment it is asked, and callers that need a pinned clock use
    /// `markTarget(now:)` directly.
    var isComplete: Bool {
        let target = markTarget(now: .nowMs)
        return target > 0 && progress >= target
    }

    /// "Jun 24, 2026" for an announced part — the date the UI can actually promise.
    ///
    /// `premiereDateLabel` reads the catalogue's own premiere slot, which TMDB frequently leaves
    /// null while still dating the season through its first episode. Falling back to the earliest
    /// episode air date is the difference between a real date and a bare "TBA".
    func announcedDateLabel(source: MediaSource) -> String? {
        if let label = premiereDateLabel(source: source) { return label }
        guard let first = episodes.compactMap({ $0.airDate }).min() else { return nil }
        return Formatting.fmtFullDate(first, anchor: Episode.airDateAnchor)
    }
}

extension Episode {
    var hasAnnouncedDetails: Bool {
        if ArtworkSet.nonEmpty(still) != nil || ArtworkSet.nonEmpty(overview) != nil { return true }
        guard let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return false }
        return title.range(of: #"^(?:episode\s*\d*|tba|tbd|untitled)$"#,
                           options: [.regularExpression, .caseInsensitive]) == nil
    }
}

// MARK: - Franchise · label lookup, current part, completion, the undo snapshot

extension Franchise {
    /// Episodic members in watch order. A movie is a binary unit and is handled separately;
    /// specials and music videos are not part of the spine.
    var episodicPartsInOrder: [FranchisePart] {
        parts
            .filter { $0.kind == .season || $0.kind == .ona || $0.kind == .ova }
            .sorted { $0.sequence < $1.sequence }
    }

    /// The episodic SPINE in watch order (`FranchisePart.isMainStory`, films aside). Falls back
    /// to every episodic part for a work the catalogue relates oddly, so nothing loses its queue.
    var mainStoryEpisodicParts: [FranchisePart] {
        var spine = episodicPartsInOrder.filter(\.isMainStory)
        // Beside real seasons, a ONE-episode OVA/ONA is an extra — a prologue, a promo, a
        // bonus ("MONSTERS", "Road to Hero") — never a season-sized "next".
        if spine.contains(where: { $0.kind == .season }) {
            spine.removeAll { ($0.kind == .ova || $0.kind == .ona) && max($0.totalEpisodes, $0.airedEpisodes) <= 1 }
        }
        return spine.isEmpty ? episodicPartsInOrder : spine
    }

    /// Every released episode of the story's spine still to watch — across the seasons, not only
    /// the one you are in. A "LEFT" count on a finished run says this; "26 EPISODES LEFT" sat over
    /// a confirmation that marked 63 (review, 23 Sep).
    func seriesLeft(now: Int64) -> Int {
        mainStoryEpisodicParts.filter { !$0.isUpcoming }
            .reduce(0) { $0 + max(0, $1.markTarget(now: now) - $1.progress) }
    }

    /// The spine's films (Demon Slayer's Infinity Castle): part of the story, watched as one unit.
    var mainStoryMovies: [FranchisePart] {
        // While a TV season is still AIRING, the films are side stories of a running show —
        // One Piece's twenty "SEQUEL" films are not what comes after Episode 1179. Demon Slayer's
        // Infinity Castle, released after the last season ended, is.
        if parts.contains(where: { $0.kind == .season && $0.isReleasing && $0.isMainStory }) { return [] }
        return parts.filter { $0.kind == .movie && $0.isMainStory }.sorted { $0.sequence < $1.sequence }
    }

    /// The SEASONS — what the show page's picker lists and what "Season N" means on that screen:
    /// the `.season` parts that are not spin-offs. OVAs, ONAs, side stories, spin-offs, specials
    /// and films are extras, on the shelf under the episode list. The picker used to list every
    /// episodic part in release order — Season 1, OVA 1, Sukuwareru Ramiris, Season 2, Visions of
    /// Coleus, Season 2 Part 2… nine entries on Slime ("utterly confusing", 4 Sep); Netflix, Apple
    /// TV, Prime and Crunchyroll list seasons only. A work with no season at all (an ONA run)
    /// keeps its whole episodic spine, so it still has an Episodes section.
    var seasonPartsInOrder: [FranchisePart] {
        let seasons = episodicPartsInOrder.filter { $0.kind == .season && !$0.isSpinOff }
        guard !seasons.isEmpty else { return episodicPartsInOrder }
        // A story told in ONA/OVA RUNS before any TV season has aired: the runs are its seasons
        // until one does (review i4: SAKAMOTO DAYS — two 11-episode ONA runs and an announced TV
        // season — opened its Episodes on the empty announced season, hid its 22 aired episodes
        // under extras and offered no series mark while the hero said "22 episodes not marked").
        guard seasons.allSatisfy(\.isUpcoming) else { return seasons }
        let runs = episodicPartsInOrder.filter { ($0.kind == .ona || $0.kind == .ova) && $0.isMainStory && !$0.isUpcoming }
        // The released runs in their own order, THEN the announced seasons: sorted by `sequence`
        // the kinds interleaved on their separate counters — "ONA 1 · Season 1 · ONA 2" (review
        // i5, P4-N7).
        return runs.isEmpty ? seasons : runs + seasons
    }

    /// Browsing episodes defaults to an available season, not an announced sequel with no
    /// episodes. The announced season remains selectable and keeps its honest empty state.
    var defaultEpisodeSeason: FranchisePart? {
        let seasons = seasonPartsInOrder
        if let current = currentPart, !current.isUpcoming,
           let season = seasons.first(where: { $0.mediaId == current.mediaId }) { return season }
        let released = seasons.filter { !$0.isUpcoming }
        return released.first { !$0.isComplete } ?? released.last ?? seasons.first
    }

    /// The part the whole screen is "about": what is airing, else what the user would resume,
    /// else the earliest thing they have not finished. `nil` only when there is nothing episodic.
    var currentPart: FranchisePart? {
        if let releasing = releasingPart, hasReached(releasing) { return releasing }
        if let resume = resumePart { return resume }
        return releasingPart ?? mainStoryEpisodicParts.first { !$0.isComplete }
    }

    /// You are AT the airing part: you have started it, or everything of the story before it is
    /// watched. A viewer starting Bleach from Episode 1 is not "8 episodes behind" on The
    /// Calamity (iteration 2) — they are at Season 1, and the airing is news for later.
    func hasReached(_ part: FranchisePart) -> Bool {
        if part.progress > 0 { return true }
        let before = mainStoryEpisodicParts.filter { $0.sequence < part.sequence && !$0.isUpcoming }
        return before.allSatisfy(\.isComplete)
    }

    /// The whole work is finished: every episodic member complete, nothing releasing, and no
    /// future installment announced. This is the question `Copy.Progress.complete(_:)` and the
    /// series-complete milestone both ask — it lives here so no screen re-derives it.
    var isSeriesComplete: Bool {
        // The episodic SPINE: an unwatched recap OVA does not hold a finished show open, and
        // neither does a film — a film is "next" for a show you watch, never a debt that keeps
        // a Watched show from COMPLETE (iteration 2).
        let episodic = mainStoryEpisodicParts
        guard !episodic.isEmpty else { return false }
        guard episodic.allSatisfy({ $0.isComplete }) else { return false }
        guard !parts.contains(where: { $0.isReleasing || $0.isUpcoming }) else { return false }
        return upcoming?.isFutureInstallment != true
    }

    /// Watched through: every episodic member complete and nothing releasing or upcoming — the
    /// series-complete milestone's own test. Unlike `isSeriesComplete` a curated rumour ("Sequel
    /// series rumoured") does not count: a rumour is not a season to watch, and Thrones stayed
    /// under "Watching ⌄" over "COMPLETE · Watched once" because of one (review i4).
    var isWatchedThrough: Bool {
        let episodic = mainStoryEpisodicParts
        guard !episodic.isEmpty, episodic.allSatisfy({ $0.isComplete }) else { return false }
        return !parts.contains(where: { $0.isReleasing || $0.isUpcoming })
    }

    /// The canonical label of one member, by media id. "" when the part is unknown or unlabelled.
    func canonicalPartLabel(for mediaId: Int) -> String {
        parts.first { $0.mediaId == mediaId }?.canonicalLabel ?? ""
    }

    /// "Anime" | "TV" — the word for what this is, in the user's vocabulary. Board 09 never says
    /// "AniList" or "TMDB" to a viewer.
    var kindWord: String { source.kindWord }

    /// THE watch-context rule: "Season 7 · Episode 5" on a multi-part franchise, "Episode 5" on a
    /// single one. Today owned this rule privately while Library and Schedule always printed the
    /// season and Detail's Next up card never did — one fact, three grammars. Every screen calls
    /// this now.
    ///
    /// "Multi-part" means more than one EPISODIC part of the story to tell apart: One Piece — one
    /// 1,100-episode series among fifteen films and its specials — read "TV Series · Episode 2"
    /// (the catalogue's format name standing in for a season). An extra being watched keeps its
    /// name ("OVA · Episode 1"); a film is its name.
    func watchContext(part: FranchisePart, episode n: Int) -> String {
        if part.kind == .movie { return part.canonicalLabel }
        let named = !part.isMainStory || mainStoryEpisodicParts.count > 1
        return named ? Copy.watchContext(part: part.canonicalLabel, episode: n) : Copy.episode(n)
    }

    /// The value `UndoState.removedFranchise` carries. `Franchise` is a value type, so this is the
    /// whole show — parts, progress and status — frozen at the instant of the removal. That is what
    /// lets Undo restore instantly, before any network round-trip.
    var snapshotForUndo: Franchise { self }
}

// MARK: - WatchStatus · the one place a status becomes words

extension WatchStatus {
    /// Board 09's status vocabulary, for all five cases. `.completed` is an internal name; the
    /// user's word is "Watched" (SYS-4 — "Finished" is out of the vocabulary; it was carrying both
    /// the user's list state and the series' production state).
    var displayName: String { Copy.Status(self) }
}

extension MediaSource {
    /// "Anime" | "TV" — the word for what a title is, in the user's vocabulary. Board 09 never says
    /// "AniList" or "TMDB" to a viewer. Lives on the source so `FranchiseSummary` (Search) and
    /// `Franchise` (Library, Detail) cannot spell it differently.
    var kindWord: String { self == .tmdb ? "TV" : "Anime" }

    /// The kind word where the app SUGGESTS titles (Discover, For you, a genre's page): said only
    /// to a viewer who sees both kinds. To someone who watches anime alone, "Anime ·" before every
    /// title on a wall of anime is the app reminding them of a choice they made once (`Audience`).
    /// Their own shows keep `kindWord` — a library may hold both.
    var kindLead: String? { Audience.stored.isSingle ? nil : kindWord }
}
