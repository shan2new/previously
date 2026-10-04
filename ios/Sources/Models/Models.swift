import Foundation

// Codable models matching the Previously API contract (docs/api-contract.md) exactly.
// All times are milliseconds since epoch (Int64), nullable where the contract says so.

// MARK: - Enums

/// The five watch statuses (spec board 09). `completed` is the wire name; the user's word is
/// "Finished" — see `WatchStatus.displayName` / `Copy.Status(_:)`, the only places it becomes text.
/// The server column is `text()`, so `paused` and `dropped` needed no migration.
enum WatchStatus: String, Codable, Sendable, CaseIterable {
    case watching
    case completed
    case planned
    case paused
    case dropped
}

/// Which catalogue a franchise came from. A franchise never mixes sources; absent in older
/// server responses, so decoding defaults to `.anilist`.
enum MediaSource: String, Codable, Sendable {
    case anilist
    case tmdb

    /// Which calendar this source's timestamps must be read in — the anchor every `Formatting`
    /// helper takes. TMDB air dates are DATE-ONLY facts the server carries as a synthesized
    /// 17:00 UTC instant (docs/api-contract.md), so only their UTC calendar day is real; reading
    /// them locally put every timezone east of UTC+7 a day ahead. AniList ships true instants.
    /// Never branch on `source` at a formatting call site — pass this.
    var timeAnchor: Formatting.TimeAnchor { self == .tmdb ? .utcDate : .local }
}

enum PartKind: String, Codable, Sendable {
    case season
    case movie
    case ova
    case ona
    case special
    case music

    // Section grouping used by the franchise detail screen.
    var sectionTitle: String {
        switch self {
        case .season: return "Seasons"
        case .movie: return "Movies"
        case .ova, .ona: return "OVAs"
        case .special: return "Specials"
        case .music: return "Music"
        }
    }

    // Canonical ordering of sections.
    var sortRank: Int {
        switch self {
        case .season: return 0
        case .movie: return 1
        case .ova: return 2
        case .ona: return 3
        case .special: return 4
        case .music: return 5
        }
    }
}

// MARK: - Episode

/// Per-episode metadata (present only on the franchise-detail response). Richness is
/// source-dependent — TMDB is full; AniList gives best-effort titles/thumbnails and no per-episode
/// airDate/overview. Everything is optional and decoded defensively.
struct Episode: Codable, Identifiable, Sendable {
    let number: Int
    let title: String?
    let airDate: Int64?     // ms epoch
    let overview: String?
    let still: String?      // thumbnail url
    let runtime: Int?       // minutes

    var id: Int { number }

    enum CodingKeys: String, CodingKey { case number, title, airDate, overview, still, runtime }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        number = (try? c.decode(Int.self, forKey: .number)) ?? 0
        title = try? c.decodeIfPresent(String.self, forKey: .title)
        airDate = try? c.decodeIfPresent(Int64.self, forKey: .airDate)
        overview = try? c.decodeIfPresent(String.self, forKey: .overview)
        still = try? c.decodeIfPresent(String.self, forKey: .still)
        runtime = try? c.decodeIfPresent(Int.self, forKey: .runtime)
    }

    init(number: Int, title: String?, airDate: Int64?, overview: String?, still: String?, runtime: Int?) {
        self.number = number; self.title = title; self.airDate = airDate
        self.overview = overview; self.still = still; self.runtime = runtime
    }

    /// `airDate` only ever comes from TMDB — AniList exposes none (docs/api-contract.md) — so it is
    /// always a date-only fact and must be read in its own UTC day, never the device's.
    static let airDateAnchor: Formatting.TimeAnchor = .utcDate

    /// "Jun 24, 2026" for this episode's air date; nil when the source didn't date it.
    /// Use this instead of `Formatting.fmtFullDate(episode.airDate)`, which reads a day late east
    /// of UTC+7.
    var airDateLabel: String? {
        airDate.map { Formatting.fmtFullDate($0, anchor: Episode.airDateAnchor) }
    }

    /// Day word for this episode's air date ("Today" / "Thursday" / "May 4"); nil when undated.
    func airDayLabel(now: Int64) -> String? {
        airDate.map { Formatting.fmtDayLong(ts: $0, now: now, anchor: Episode.airDateAnchor) }
    }
}

// MARK: - Airing

/// One dated episode of a part inside Schedule's window (`airings` on the contract): the number
/// and the instant. TMDB's instant is date-only (17:00 UTC) — read it in the source's calendar.
struct Airing: Codable, Hashable, Sendable {
    let episode: Int
    let at: Int64
}

// MARK: - Release precision

/// How precisely the next release instant is known — **stated by the server, never inferred from
/// `source`** (docs/api-contract.md). AniList publishes a real broadcast instant; TMDB publishes a
/// calendar date the sync synthesizes to 17:00 UTC, so its clock half is not a fact and must never
/// be rendered. Absent in older server responses, which is why every field is optional here.
struct ReleasePrecision: Codable, Sendable {
    enum Precision: String, Codable, Sendable {
        /// `at` is a real broadcast instant.
        case exact
        /// `date` is the fact; `at` is synthesized and its clock half is fiction.
        case dateOnly = "date_only"
        /// Nothing is scheduled.
        case unknown
    }

    let precision: Precision
    /// ms epoch. Authoritative only when `precision == .exact`.
    let at: Int64?
    /// "YYYY-MM-DD" (UTC). Authoritative only when `precision == .dateOnly`.
    let date: String?

    enum CodingKeys: String, CodingKey { case precision, at, date }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        precision = (try? c.decode(Precision.self, forKey: .precision)) ?? .unknown
        at = try? c.decodeIfPresent(Int64.self, forKey: .at)
        date = try? c.decodeIfPresent(String.self, forKey: .date)
    }

    init(precision: Precision, at: Int64?, date: String?) {
        self.precision = precision; self.at = at; self.date = date
    }
}

// MARK: - FranchisePart

struct FranchisePart: Codable, Identifiable, Sendable {
    let mediaId: Int
    let kind: PartKind
    let sequence: Int
    let label: String
    let title: String
    let cover: String?
    let banner: String?
    let format: String?
    /// How the catalogue relates this part to the work — "SEQUEL", "PREQUEL", "SIDE_STORY",
    /// "SPIN_OFF", "SUMMARY", "OTHER"… (AniList's relation type, as the server sends it). Read for
    /// one decision only: a spin-off is an extra, not a season (`isSpinOff`).
    let relationship: String?
    let status: String?
    let isReleasing: Bool
    let totalEpisodes: Int
    let airedEpisodes: Int
    let nextEpisodeNumber: Int?
    let nextAiringAt: Int64?
    let lastAiredAt: Int64?
    let synopsis: String?
    let genres: [String]
    let progress: Int
    let year: Int?             // premiere/season year
    let studios: [String]      // studios (anime) / networks (TV)
    let nextAiringCount: Int   // episodes sharing the next airing date; > 1 ⇒ a full-season drop
    let episodes: [Episode]    // detail response only; [] on list/library payloads
    /// The honest shape of `nextAiringAt`. `nil` from a server that predates the field.
    let release: ReleasePrecision?
    /// Dated episodes 8 days back … 15 days ahead, oldest first, on EVERY payload — the calendar's
    /// per-episode facts. `[]` from a server that predates the field; see `scheduleAirings`.
    let airings: [Airing]
    /// Artwork with its orientation stated. `nil` from a server that predates the field.
    let images: ArtworkSet?
    /// The server's ranked alternatives per orientation. `nil` from a server that predates it.
    let artwork: ArtworkGallery?
    /// Trailers and teasers scoped to this exact part. `[]` from an older server.
    let videos: [FranchiseVideo]

    var id: Int { mediaId }

    // Decode defensively: the server may omit optional/array fields.
    enum CodingKeys: String, CodingKey {
        case mediaId, kind, sequence, label, title, cover, banner, format, relationship, status
        case isReleasing, totalEpisodes, airedEpisodes, nextEpisodeNumber, nextAiringAt
        case lastAiredAt, synopsis, genres, progress
        case year, studios, nextAiringCount, episodes, release, airings, images, artwork, videos
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mediaId = try c.decode(Int.self, forKey: .mediaId)
        kind = (try? c.decode(PartKind.self, forKey: .kind)) ?? .season
        sequence = (try? c.decode(Int.self, forKey: .sequence)) ?? 0
        label = (try? c.decode(String.self, forKey: .label)) ?? ""
        title = (try? c.decode(String.self, forKey: .title)) ?? "Untitled"
        cover = try? c.decodeIfPresent(String.self, forKey: .cover)
        banner = try? c.decodeIfPresent(String.self, forKey: .banner)
        format = try? c.decodeIfPresent(String.self, forKey: .format)
        relationship = try? c.decodeIfPresent(String.self, forKey: .relationship)
        status = try? c.decodeIfPresent(String.self, forKey: .status)
        isReleasing = (try? c.decode(Bool.self, forKey: .isReleasing)) ?? false
        totalEpisodes = (try? c.decode(Int.self, forKey: .totalEpisodes)) ?? 0
        airedEpisodes = (try? c.decode(Int.self, forKey: .airedEpisodes)) ?? 0
        nextEpisodeNumber = try? c.decodeIfPresent(Int.self, forKey: .nextEpisodeNumber)
        nextAiringAt = try? c.decodeIfPresent(Int64.self, forKey: .nextAiringAt)
        lastAiredAt = try? c.decodeIfPresent(Int64.self, forKey: .lastAiredAt)
        synopsis = try? c.decodeIfPresent(String.self, forKey: .synopsis)
        genres = (try? c.decode([String].self, forKey: .genres)) ?? []
        let rawProgress = (try? c.decode(Int.self, forKey: .progress)) ?? 0
        // A season that has not premiered cannot have been watched: read it as what has aired of
        // it. Marks written before the server's clamp put 13 on Avatar: Seven Havens a fortnight
        // before its premiere — it would never read behind, NEW or on Today (iteration 2).
        progress = status == "NOT_YET_RELEASED" ? min(rawProgress, airedEpisodes) : rawProgress
        year = try? c.decodeIfPresent(Int.self, forKey: .year)
        studios = (try? c.decode([String].self, forKey: .studios)) ?? []
        nextAiringCount = (try? c.decode(Int.self, forKey: .nextAiringCount)) ?? 0
        // `Episode.id` is its number, so a malformed/duplicate 0 would collide inside a ForEach.
        episodes = ((try? c.decode([Episode].self, forKey: .episodes)) ?? []).filter { $0.number > 0 }
        release = try? c.decodeIfPresent(ReleasePrecision.self, forKey: .release)
        airings = ((try? c.decode([Airing].self, forKey: .airings)) ?? []).filter { $0.episode > 0 && $0.at > 0 }
        images = try? c.decodeIfPresent(ArtworkSet.self, forKey: .images)
        artwork = try? c.decodeIfPresent(ArtworkGallery.self, forKey: .artwork)
        videos = (try? c.decode([FranchiseVideo].self, forKey: .videos)) ?? []
    }

    // Memberwise init for previews/tests. New fields default so existing call sites keep working.
    init(mediaId: Int, kind: PartKind, sequence: Int, label: String, title: String,
         cover: String?, banner: String?, format: String?, relationship: String? = nil, status: String?,
         isReleasing: Bool, totalEpisodes: Int, airedEpisodes: Int,
         nextEpisodeNumber: Int?, nextAiringAt: Int64?, lastAiredAt: Int64?,
         synopsis: String?, genres: [String], progress: Int,
         year: Int? = nil, studios: [String] = [], nextAiringCount: Int = 0, episodes: [Episode] = [],
         release: ReleasePrecision? = nil, airings: [Airing] = [],
         images: ArtworkSet? = nil, artwork: ArtworkGallery? = nil, videos: [FranchiseVideo] = []) {
        self.mediaId = mediaId; self.kind = kind; self.sequence = sequence
        self.label = label; self.title = title; self.cover = cover; self.banner = banner
        self.format = format; self.relationship = relationship; self.status = status; self.isReleasing = isReleasing
        self.totalEpisodes = totalEpisodes; self.airedEpisodes = airedEpisodes
        self.nextEpisodeNumber = nextEpisodeNumber; self.nextAiringAt = nextAiringAt
        self.lastAiredAt = lastAiredAt; self.synopsis = synopsis; self.genres = genres
        self.progress = progress
        self.year = year; self.studios = studios
        self.nextAiringCount = nextAiringCount; self.episodes = episodes
        self.release = release
        self.airings = airings
        self.images = images
        self.artwork = artwork
        self.videos = videos
    }

    /// A copy with the episode list replaced — grafts detail-fetched episodes onto the live
    /// (library) copy, which is loaded without them.
    func withEpisodes(_ eps: [Episode]) -> FranchisePart {
        FranchisePart(mediaId: mediaId, kind: kind, sequence: sequence, label: label, title: title,
                      cover: cover, banner: banner, format: format, relationship: relationship, status: status,
                      isReleasing: isReleasing, totalEpisodes: totalEpisodes, airedEpisodes: airedEpisodes,
                      nextEpisodeNumber: nextEpisodeNumber, nextAiringAt: nextAiringAt, lastAiredAt: lastAiredAt,
                      synopsis: synopsis, genres: genres, progress: progress,
                      year: year, studios: studios, nextAiringCount: nextAiringCount, episodes: eps,
                      release: release, airings: airings, images: images, artwork: artwork, videos: videos)
    }

    /// The calendar facts for this part. `airings` when the server sent them; otherwise the two
    /// slots every server has always published — the next episode and the latest aired one — so a
    /// weekly show still lands on its next date and its last one. Ascending by instant.
    var scheduleAirings: [Airing] {
        if !airings.isEmpty { return airings }
        var out: [Airing] = []
        if let last = lastAiredAt, last > 0, airedEpisodes > 0 {
            out.append(Airing(episode: airedEpisodes, at: last))
        }
        if let next = nextAiringAt, next > 0 {
            // A dated season announcement is not automatically Episode 1. The fallback is
            // valid only within an already-running episodic sequence.
            let ep = nextEpisodeNumber ?? (isReleasing && airedEpisodes > 0 ? airedEpisodes + 1 : 0)
            if ep > 0, !out.contains(where: { $0.episode == ep }) {
                out.append(Airing(episode: ep, at: next))
            }
        }
        return out.sorted { $0.at < $1.at }
    }

    /// Unwatched episodes that have already aired (0 unless currently releasing).
    /// Ported verbatim from format.ts `episodesBehind`.
    var episodesBehind: Int {
        isReleasing ? max(0, airedEpisodes - progress) : 0
    }

    var isBehind: Bool { episodesBehind > 0 }

    /// Currently releasing AND fully watched up to the latest aired episode.
    var isCaughtUp: Bool { isReleasing && airedEpisodes > 0 && episodesBehind == 0 }

    // MARK: Airings-derived freshness
    //
    // `airedEpisodes`, `lastAiredAt` and `nextAiringAt` are the CATALOGUE'S facts, advanced by an
    // hourly sync. `airings` is the per-episode calendar the same payload carries, and a slot in it
    // that has struck IS an aired episode — the count merely hasn't caught up yet. Reading only the
    // counts made the one show that had just aired (Re:ZERO, 6:30 PM) the one show Today could not
    // see for up to an hour: not fresh (count unchanged), not waiting (slot passed) — gone.
    // Every "is it out yet / when is the next one" question goes through these four. The raw
    // fields stay for sort keys and the Library's calm captions, where an hour is nothing.

    /// Slots that have passed: a real instant once its clock has struck; a date-only slot the day
    /// AFTER its date (its clock is synthesized, and on the day itself it still reads "today").
    private func passedAirings(now: Int64, anchor: Formatting.TimeAnchor) -> [Airing] {
        airings.filter { a in
            anchor.isDateOnly ? Formatting.dayDiff(ts: a.at, now: now, anchor: anchor) < 0 : a.at <= now
        }
    }

    /// Episodes out BY NOW — the catalogue's count or the latest passed slot, whichever is ahead.
    func airedByNow(now: Int64, anchor: Formatting.TimeAnchor = .local) -> Int {
        guard isReleasing else { return airedEpisodes }
        return max(airedEpisodes, passedAirings(now: now, anchor: anchor).map(\.episode).max() ?? 0)
    }

    /// `episodesBehind` against what has aired by now, not by the last sync.
    func behind(now: Int64, anchor: Formatting.TimeAnchor = .local) -> Int {
        isReleasing ? max(0, airedByNow(now: now, anchor: anchor) - progress) : 0
    }

    /// Where you are in this part — ONE denominator for every bar that draws it (review i4: the
    /// hero said 83 % and the Episodes header 79 % for the same season): what is OUT while it
    /// airs (aired by now), the available run once it has finished.
    func progressDenominator(now: Int64, anchor: Formatting.TimeAnchor = .local) -> Int {
        isReleasing ? airedByNow(now: now, anchor: anchor) : availableEpisodes()
    }

    /// What is out and unwatched: `behind` for an airing part, the released run for a finished one
    /// (a season dropped whole — `Franchise.freshPart`).
    func unwatchedOut(now: Int64, anchor: Formatting.TimeAnchor = .local) -> Int {
        isReleasing ? behind(now: now, anchor: anchor) : max(0, airedEpisodes - progress)
    }

    /// A drop is NEWS only for someone who was already here: the part is started, or what is
    /// unwatched is no more than what aired in the out-now window. A show added at zero with
    /// twelve episodes out — or 1,100 — is a backlog to start, not a new episode (review i3: it
    /// took Today's deck as "12 EPISODES BEHIND" / "1,1XX EPISODES BEHIND · Episode 1").
    ///
    /// "Started" alone is not "here": One Piece at Episode 2 of 1,179 took the deck as "1,178
    /// EPISODES BEHIND" (local account, 24 Sep). A started part is news while what it is behind is
    /// within a cour (`followingSlack`) — someone a few weeks behind a weekly show is still
    /// following it; someone a thousand behind is starting a backlog.
    func isNews(now: Int64, anchor: Formatting.TimeAnchor = .local, window: Int64) -> Bool {
        let recent = passedAirings(now: now, anchor: anchor).filter { now - $0.at <= window }.count
        // What is out and unwatched — `behind` is zero on a part that has stopped releasing, which
        // made every finished run "news": nineteen unwatched shorts counted as a drop (4 Oct).
        let behind = unwatchedOut(now: now, anchor: anchor)
        if progress > 0 { return behind <= max(Self.followingSlack, recent) }
        return behind <= max(2, recent)
    }

    /// How far behind a started part may be and still be FOLLOWED (a cour of a weekly show).
    static let followingSlack = 12

    /// When the latest episode came out — `lastAiredAt`, advanced by any slot that has passed since.
    func lastAired(now: Int64, anchor: Formatting.TimeAnchor = .local) -> Int64? {
        let passed = passedAirings(now: now, anchor: anchor).map(\.at).max()
        return [lastAiredAt, passed].compactMap { $0 }.max()
    }
    /// The latest drop struck on the calendar day the app's temporal ladder calls today
    /// (review i5: a 24-hour window painted "Aired yesterday" amber). One test for the badge,
    /// the moment, the queue's lead and every shelf caption.
    func airedToday(now: Int64, anchor: Formatting.TimeAnchor) -> Bool {
        guard let last = lastAired(now: now, anchor: anchor) else { return false }
        return Formatting.dayDiff(ts: last, now: now, anchor: anchor) == 0
    }


    /// The next slot still AHEAD — strictly future for a timed source (a slot that has struck is an
    /// episode, not a wait), today-or-later for date-only — from the airings first, then the
    /// catalogue's single slot. What every "Airs Friday" / countdown reads.
    func upcomingAiring(now: Int64, anchor: Formatting.TimeAnchor = .local) -> Int64? {
        let ahead = airings
            .filter { a in anchor.isDateOnly ? Formatting.dayDiff(ts: a.at, now: now, anchor: anchor) >= 0 : a.at > now }
            .map(\.at).min()
        if let ahead { return ahead }
        guard let slot = scheduledAiring(now: now, anchor: anchor) else { return nil }
        return (anchor.isDateOnly || slot > now) ? slot : nil
    }

    /// Movies are a single binary unit (watched / not watched) — no episode count.
    var isMovie: Bool { kind == .movie }

    /// Announced but not yet aired — nothing is watchable yet, so the UI shows a premiere
    /// date instead of a "Not started" stepper.
    /// Keyed on status ALONE: a catalogue that publishes an announced season's planned episode
    /// count (TMDB does) would otherwise fail the old `airedEpisodes == 0` test and the season
    /// would masquerade as released — losing its premiere date and inventing a backlog.
    var isUpcoming: Bool { status == "NOT_YET_RELEASED" }

    /// Scheduled premiere instant (ms epoch) for an upcoming part, if the source has dated it.
    var premiereAt: Int64? { isUpcoming ? nextAiringAt : nil }

    /// "Jun 24, 2026" premiere date for an announced part, read in its source's calendar.
    /// A part doesn't know its own source, so the franchise supplies it.
    func premiereDateLabel(source: MediaSource) -> String? {
        premiereAt.map { Formatting.fmtFullDate($0, anchor: source.timeAnchor) }
    }

    /// The next airing you can still count down to, or nil when there isn't one.
    ///
    /// A `nextAiringAt` in the past is STALE DATA, not a schedule: the catalogue simply hasn't
    /// advanced the slot yet (an announced premiere whose date has come and gone, a season that
    /// ended between syncs). Reading it as a live schedule is what made a week-old timestamp
    /// render as "today" every day. Same-day is kept — an episode that aired a few hours ago
    /// still legitimately reads as "today".
    ///
    /// `anchor` decides which calendar "same day" means: a TMDB slot must be judged against its
    /// own UTC date or a JST morning keeps yesterday's drop alive as "today". Prefer
    /// `Franchise.nextAiring(now:)`, which can't forget to pass it.
    func scheduledAiring(now: Int64, anchor: Formatting.TimeAnchor = .local) -> Int64? {
        guard let next = nextAiringAt,
              Formatting.dayDiff(ts: next, now: now, anchor: anchor) >= 0 else { return nil }
        return next
    }

    /// Episodes of this part that are actually available to watch right now — aired count while
    /// releasing, else the finite total. Zero for an announced part: a season that hasn't started
    /// has nothing to watch, whatever episode count the catalogue advertises for it.
    func availableEpisodes() -> Int {
        if isUpcoming { return 0 }
        if isReleasing { return airedEpisodes }
        return airedEpisodes > 0 ? airedEpisodes : totalEpisodes
    }

    /// Highest episode number that may be recorded as watched for this part (iD17, server §4.1's
    /// `clampProgressValue`, mirrored so the server never cuts a mark the client showed):
    ///
    /// - NOT_YET_RELEASED → 0: a season that has not premiered cannot have been watched.
    /// - RELEASING → what has aired BY NOW: `max(provenAiredCount(now:), airedByNow(now:anchor:))`,
    ///   so a slot that struck since the hourly sync counts at once. The old ceiling, the season's
    ///   size, let a 12-episode season with 5 aired be marked to 12, and the server now clamps that.
    ///   When nothing at all is known — no aired count, no slot, no dated episode, no total — the
    ///   server leaves the value unclamped, and so does this (`Int.max`).
    /// - Otherwise the season's SIZE, as before: a "+1" control with no ceiling ran a 10-episode
    ///   season to 59/10 behind a ring that clamped only its visual. Unknown size stays unbounded.
    ///
    /// Never above the server's: every aired count here is anchor-local, and the server admits a
    /// date-only slot at the earliest zone on Earth (UTC+14), a timed one at its instant.
    func progressCeiling(now: Int64, anchor: Formatting.TimeAnchor) -> Int {
        if isUpcoming { return 0 }
        guard isReleasing else {
            let size = max(totalEpisodes, airedEpisodes)
            return size > 0 ? size : Int.max
        }
        let aired = airedForGate(now: now, anchor: anchor)
        let known = aired > 0 || nextAiringAt != nil || !airings.isEmpty
            || episodes.contains { $0.airDate != nil } || totalEpisodes > 0
        return known ? aired : Int.max
    }

    /// The ONE aired count a releasing part's write ceiling and its episode gate share (the server's
    /// `airedCount` is one number for its clamp and its `episodeAccess`): the proven count or the
    /// latest passed slot, whichever is ahead. A TMDB episode whose synthesised 17:00 UTC slot has
    /// struck is markable AND its room opens — the gate used `airedByNow` alone and kept that room
    /// "unaired" until the next local day. Still never laxer than the server (see `progressCeiling`).
    func airedForGate(now: Int64, anchor: Formatting.TimeAnchor) -> Int {
        max(provenAiredCount(now: now), airedByNow(now: now, anchor: anchor))
    }

    /// The ceiling a WRITE is bounded by: `progressCeiling`, but never below what is already
    /// recorded — only an increase is bounded (the write rule: a progress mark never rolls back).
    /// Rows written before iD17 can sit above the aired count (the old ceiling was the season's
    /// size); bounded at the aired count, unmarking 12 → 11 on a five-aired season wrote 5, and a
    /// batch to 14 wrote backwards. Mirrors the server's `clampProgressValue(row, v, now, current)`.
    func writeCeiling(now: Int64, anchor: Formatting.TimeAnchor) -> Int {
        max(progressCeiling(now: now, anchor: anchor), progress)
    }

    /// The season's SIZE (the pre-iD17 ceiling). A releasing part is bounded by what has aired —
    /// read `progressCeiling(now:anchor:)`.
    @available(*, deprecated, message: "Use progressCeiling(now:anchor:) — a releasing part is bounded by what has aired")
    var progressCeiling: Int {
        if isUpcoming { return 0 }
        let size = max(totalEpisodes, airedEpisodes)
        return size > 0 ? size : Int.max
    }

    /// Has the user watched this part to completion? For movies this is binary (progress > 0);
    /// for finite, non-releasing parts it means progress reached the episode total.
    var isFinished: Bool {
        if isMovie { return progress > 0 }
        return !isReleasing && totalEpisodes > 0 && progress >= totalEpisodes
    }
}

// MARK: - Franchise (full detail)

struct PartCounts: Codable, Sendable {
    var season: Int = 0
    var movie: Int = 0
    var ova: Int = 0
    var ona: Int = 0
    var special: Int = 0
    var music: Int = 0
}

struct Subscription: Codable, Sendable {
    let status: WatchStatus
    /// When the user subscribed (ms since epoch). Absent in older server responses, so Library's
    /// "recently added" ordering must treat `nil` as unknown rather than as the epoch.
    let addedAt: Int64?

    init(status: WatchStatus, addedAt: Int64? = nil) {
        self.status = status
        self.addedAt = addedAt
    }
}

/// `FranchiseUpcoming.release` resolved into something orderable — **stated by the server**
/// (docs/api-contract.md), because `release` is prose: the catalogue announces "October 2026" and
/// "Summer 2027" far more often than it announces a date. The app's own ISO-only reading of that
/// prose filed every window under January of its year, so a shelf sorted "soonest first" put
/// October 2026 ahead of an August 2026 premiere while its own caption read "Returns Oct 2026".
/// Nothing here re-parses `release`; `sortKey` is the one order and `date` is the one date.
struct ReleaseWindow: Codable, Sendable, Hashable {
    enum Precision: String, Codable, Sendable {
        /// `date` is exactly what was announced, to the day / to the month.
        case day, month
        /// A broadcast season or quarter. `date` is that quarter's FIRST month — order by it,
        /// never print it as a month ("Summer 2027" is not "July 2027").
        case quarter
        /// Only the year may be printed. `sortKey` may still place the window inside that year
        /// ("Late 2026" sorts in September) — that placement is an order, not a fact to render.
        case year
        /// TBA, a rumor, or prose with no date in it.
        case unknown
    }

    /// "YYYY-MM-DD" | "YYYY-MM" | "YYYY", at the precision actually known.
    let date: String?
    let precision: Precision
    /// `yyyymmdd` of the earliest instant the window can mean. Ascending = soonest first;
    /// `nil` sorts LAST (never as 0, never as January of a year nobody stated).
    let sortKey: Int?

    /// Calendar parts of `date`, for the surfaces that print a month. Month/day are 1 when the
    /// window doesn't state them, so a caller must check `precision` before printing either.
    var parts: (year: Int, month: Int, day: Int)? {
        guard let date else { return nil }
        let segs = date.split(separator: "-").compactMap { Int($0) }
        guard let y = segs.first else { return nil }
        return (y, segs.count > 1 ? segs[1] : 1, segs.count > 2 ? segs[2] : 1)
    }

    enum CodingKeys: String, CodingKey { case date, precision, sortKey }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date = try? c.decodeIfPresent(String.self, forKey: .date)
        precision = (try? c.decodeIfPresent(Precision.self, forKey: .precision)) ?? .unknown
        sortKey = try? c.decodeIfPresent(Int.self, forKey: .sortKey)
    }

    init(date: String?, precision: Precision, sortKey: Int?) {
        self.date = date; self.precision = precision; self.sortKey = sortKey
    }
}

// Web-sourced "what's next" news for a franchise (announced/airing seasons & films). `release`
// is a human-readable date or window ("October 2026", "January 2027", "TBA") because announced
// seasons often have only a window, which AniList doesn't expose as a per-episode airing time.
// `releaseWindow` is that same window resolved by the server — the only thing to sort by.
struct FranchiseUpcoming: Codable, Sendable {
    let status: String?
    let next: String?
    let release: String?
    let note: String?
    let source: String?
    let checked: String?
    /// Absent from a server older than this field. Nothing here falls back to parsing `release`:
    /// that fallback IS the bug this replaced, and an unknown window sorts last rather than wrong.
    let releaseWindow: ReleaseWindow?

    enum CodingKeys: String, CodingKey { case status, next, release, note, source, checked, releaseWindow }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = try? c.decodeIfPresent(String.self, forKey: .status)
        next = try? c.decodeIfPresent(String.self, forKey: .next)
        release = try? c.decodeIfPresent(String.self, forKey: .release)
        note = try? c.decodeIfPresent(String.self, forKey: .note)
        source = try? c.decodeIfPresent(String.self, forKey: .source)
        checked = try? c.decodeIfPresent(String.self, forKey: .checked)
        releaseWindow = try? c.decodeIfPresent(ReleaseWindow.self, forKey: .releaseWindow)
    }

    init(status: String?, next: String?, release: String?, note: String?, source: String?,
         checked: String?, releaseWindow: ReleaseWindow? = nil) {
        self.status = status; self.next = next; self.release = release
        self.note = note; self.source = source; self.checked = checked
        self.releaseWindow = releaseWindow
    }

    /// Short uppercase tag for the badge, derived from `status`.
    var tag: String {
        switch status {
        case "airing": return "Airing now"
        case "upcoming_dated": return "Upcoming"
        case "announced", "announced_no_date": return "Announced"
        case "recently_aired": return "Recently aired"
        case "rumored": return "Rumored"
        case "concluded": return "Complete"
        default: return "Upcoming"
        }
    }

    /// Concluded franchises have no future season — used to soften the card styling.
    var isConcluded: Bool { status == "concluded" }

    /// Human-friendly release label (ISO dates prettified; curated windows pass through).
    var displayRelease: String {
        guard let r = release, !r.trimmingCharacters(in: .whitespaces).isEmpty else { return "" }
        return Formatting.prettyReleaseString(r)
    }

    /// Chronological sort key for ordering the Upcoming bucket nearest-first — **the server's**
    /// (`releaseWindow.sortKey`), not a reading of `release`. `value` is yyyymmdd; `precision`
    /// (3=day, 2=month or quarter, 1=year) breaks ties so a concrete month sorts ahead of a bare
    /// year. Nil when the window is genuinely unknown — TBA, prose with no date, *and* every
    /// rumor, all of which the server already resolves to `unknown` — so those sort to the end.
    ///
    /// This used to parse `release` here, and only its ISO forms, which filed "October 2026" and
    /// "Summer 2027" under January of their year. The prose lives in one grammar on the server now.
    var releaseSortKey: (value: Int, precision: Int)? {
        guard let window = releaseWindow, let value = window.sortKey else { return nil }
        switch window.precision {
        case .day: return (value, 3)
        case .month, .quarter: return (value, 2)
        case .year: return (value, 1)
        case .unknown: return nil
        }
    }

    /// True for statuses that represent a *future* installment worth flagging on a card —
    /// a season already airing is covered by the airing countdown, and recently-aired /
    /// concluded franchises have nothing upcoming to advertise.
    var isFutureInstallment: Bool {
        switch status {
        case "upcoming_dated", "announced", "announced_no_date", "rumored": return true
        default: return false
        }
    }

    /// True once a DAY-dated release is behind us: the installment is out, or slipped without the
    /// catalogue's curated note noticing (its `checked` date is weeks old). Either way "Returns
    /// Jul 5" is no longer a fact, and the Library must not file the show under Returning on it —
    /// Mushoku Tensei sat there reading "Returns today" two months into its third season.
    func hasArrived(now: Int64) -> Bool {
        guard isFutureInstallment, let key = releaseSortKey, key.precision == 3 else { return false }
        var comps = DateComponents()
        comps.year = key.value / 10000
        comps.month = (key.value / 100) % 100
        comps.day = key.value % 100
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        guard let date = cal.date(from: comps) else { return false }
        let ts = Int64((date.timeIntervalSince1970 * 1000).rounded())
        return Formatting.dayDiff(ts: ts, now: now, anchor: .utcDate) < 0
    }

    /// Compact "what's next" line for a poster card, e.g. "Season 3 · Jul 5, 2026". Empty
    /// unless this is a future installment.
    var cardBadge: String {
        guard isFutureInstallment else { return "" }
        let what = (next?.isEmpty == false) ? next! : "New season"
        let when = displayRelease
        return when.isEmpty ? what : "\(what) · \(when)"
    }
}

struct Franchise: Codable, Identifiable, Sendable {
    let id: String
    let source: MediaSource
    let title: String
    let cover: String?
    let banner: String?
    let synopsis: String?
    let genres: [String]
    let isReleasing: Bool
    let partCounts: PartCounts?
    let parts: [FranchisePart]
    let subscription: Subscription?
    let upcoming: FranchiseUpcoming?
    let year: Int?             // premiere year (earliest dated part)
    let studios: [String]      // primary installment's studios (anime) / networks (TV)

    // Catalogue enrichment (docs/api-contract.md). Every one of these is EMPTY, not absent, on a
    // server older than the field or a row the server's background pass has not reached yet —
    // the types and the detail-onto-library graft live in `Models+Enrichment.swift`.
    let images: ArtworkSet?
    /// The server's ranked artwork alternatives, by orientation. `nil` from an older server.
    let artwork: ArtworkGallery?
    let themes: [String]
    let featuredVideo: FranchiseVideo?
    let videos: [FranchiseVideo]
    let audience: AudienceInfo?
    let people: FranchisePeople?
    let related: [RelatedTitle]
    let continueWatching: ContinueWatching?

    // Fields present only in /me/library responses (LibraryFranchise extends Franchise).
    let status: WatchStatus?
    let behind: Int?
    let newParts: Int?

    enum CodingKeys: String, CodingKey {
        case id, source, title, cover, banner, synopsis, genres, isReleasing, partCounts, parts, subscription, upcoming
        case year, studios
        case images, artwork, themes, featuredVideo, videos, audience, people, related, continueWatching
        case status, behind, newParts
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        source = (try? c.decode(MediaSource.self, forKey: .source)) ?? .anilist
        title = (try? c.decode(String.self, forKey: .title)) ?? "Untitled"
        cover = try? c.decodeIfPresent(String.self, forKey: .cover)
        banner = try? c.decodeIfPresent(String.self, forKey: .banner)
        synopsis = try? c.decodeIfPresent(String.self, forKey: .synopsis)
        genres = (try? c.decode([String].self, forKey: .genres)) ?? []
        isReleasing = (try? c.decode(Bool.self, forKey: .isReleasing)) ?? false
        partCounts = try? c.decodeIfPresent(PartCounts.self, forKey: .partCounts)
        parts = (try? c.decode([FranchisePart].self, forKey: .parts)) ?? []
        subscription = try? c.decodeIfPresent(Subscription.self, forKey: .subscription)
        upcoming = try? c.decodeIfPresent(FranchiseUpcoming.self, forKey: .upcoming)
        year = try? c.decodeIfPresent(Int.self, forKey: .year)
        studios = (try? c.decode([String].self, forKey: .studios)) ?? []
        images = try? c.decodeIfPresent(ArtworkSet.self, forKey: .images)
        artwork = try? c.decodeIfPresent(ArtworkGallery.self, forKey: .artwork)
        themes = (try? c.decode([String].self, forKey: .themes)) ?? []
        featuredVideo = try? c.decodeIfPresent(FranchiseVideo.self, forKey: .featuredVideo)
        videos = (try? c.decode([FranchiseVideo].self, forKey: .videos)) ?? []
        audience = try? c.decodeIfPresent(AudienceInfo.self, forKey: .audience)
        people = try? c.decodeIfPresent(FranchisePeople.self, forKey: .people)
        related = ((try? c.decode([RelatedTitle].self, forKey: .related)) ?? []).filter { !$0.title.isEmpty }
        continueWatching = try? c.decodeIfPresent(ContinueWatching.self, forKey: .continueWatching)
        status = try? c.decodeIfPresent(WatchStatus.self, forKey: .status)
        behind = try? c.decodeIfPresent(Int.self, forKey: .behind)
        newParts = try? c.decodeIfPresent(Int.self, forKey: .newParts)
    }

    // Memberwise init (previews + optimistic local copies).
    init(id: String, source: MediaSource, title: String, cover: String?, banner: String?, synopsis: String?,
         genres: [String], isReleasing: Bool, partCounts: PartCounts?, parts: [FranchisePart],
         subscription: Subscription?, upcoming: FranchiseUpcoming? = nil,
         year: Int? = nil, studios: [String] = [],
         images: ArtworkSet? = nil, artwork: ArtworkGallery? = nil,
         themes: [String] = [], featuredVideo: FranchiseVideo? = nil,
         videos: [FranchiseVideo] = [], audience: AudienceInfo? = nil, people: FranchisePeople? = nil,
         related: [RelatedTitle] = [], continueWatching: ContinueWatching? = nil,
         status: WatchStatus?, behind: Int?, newParts: Int?) {
        self.id = id; self.source = source; self.title = title; self.cover = cover; self.banner = banner
        self.synopsis = synopsis; self.genres = genres; self.isReleasing = isReleasing
        self.partCounts = partCounts; self.parts = parts; self.subscription = subscription
        self.upcoming = upcoming
        self.year = year; self.studios = studios
        self.images = images; self.artwork = artwork
        self.themes = themes; self.featuredVideo = featuredVideo; self.videos = videos
        self.audience = audience; self.people = people; self.related = related; self.continueWatching = continueWatching
        self.status = status; self.behind = behind; self.newParts = newParts
    }

    /// Copy with replaced parts — used for optimistic progress updates. Every other field rides
    /// along unchanged; the account and enrichment fields take an explicit value only when a
    /// caller passes one (a status flip, the detail-onto-library graft). The double optionals
    /// are what let "leave it" and "set it to nil" be different arguments.
    init(copying other: Franchise, parts: [FranchisePart],
         subscription: Subscription?? = nil, status: WatchStatus?? = nil,
         images: ArtworkSet?? = nil, artwork: ArtworkGallery?? = nil,
         themes: [String]? = nil, featuredVideo: FranchiseVideo?? = nil,
         videos: [FranchiseVideo]? = nil, audience: AudienceInfo?? = nil, people: FranchisePeople?? = nil,
         related: [RelatedTitle]? = nil, continueWatching: ContinueWatching?? = nil) {
        self.init(id: other.id, source: other.source, title: other.title, cover: other.cover, banner: other.banner,
                  synopsis: other.synopsis, genres: other.genres, isReleasing: other.isReleasing,
                  partCounts: other.partCounts, parts: parts,
                  subscription: subscription ?? other.subscription,
                  upcoming: other.upcoming,
                  year: other.year, studios: other.studios,
                  images: images ?? other.images, artwork: artwork ?? other.artwork,
                  themes: themes ?? other.themes,
                  featuredVideo: featuredVideo ?? other.featuredVideo, videos: videos ?? other.videos,
                  audience: audience ?? other.audience, people: people ?? other.people,
                  related: related ?? other.related, continueWatching: continueWatching ?? other.continueWatching,
                  status: status ?? other.status, behind: other.behind, newParts: other.newParts)
    }
}

// MARK: - FranchiseSummary (lists)

struct FranchiseSummary: Codable, Identifiable, Sendable {
    let id: String
    let source: MediaSource
    let title: String
    let cover: String?
    let banner: String?
    let isReleasing: Bool
    let partCount: Int
    let nextAiringAt: Int64?
    let upcoming: FranchiseUpcoming?
    let year: Int?
    let images: ArtworkSet?
    /// The server's ranked artwork alternatives, by orientation. `nil` from an older server.
    let artwork: ArtworkGallery?
    let themes: [String]
    let featuredVideo: FranchiseVideo?

    // Present only in /me/library:
    let status: WatchStatus?
    let behind: Int?
    let newParts: Int?

    enum CodingKeys: String, CodingKey {
        case id, source, title, cover, banner, isReleasing, partCount, nextAiringAt, upcoming, year, status, behind, newParts
        case images, artwork, themes, featuredVideo
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        source = (try? c.decode(MediaSource.self, forKey: .source)) ?? .anilist
        title = (try? c.decode(String.self, forKey: .title)) ?? "Untitled"
        cover = try? c.decodeIfPresent(String.self, forKey: .cover)
        banner = try? c.decodeIfPresent(String.self, forKey: .banner)
        isReleasing = (try? c.decode(Bool.self, forKey: .isReleasing)) ?? false
        partCount = (try? c.decode(Int.self, forKey: .partCount)) ?? 0
        nextAiringAt = try? c.decodeIfPresent(Int64.self, forKey: .nextAiringAt)
        upcoming = try? c.decodeIfPresent(FranchiseUpcoming.self, forKey: .upcoming)
        year = try? c.decodeIfPresent(Int.self, forKey: .year)
        images = try? c.decodeIfPresent(ArtworkSet.self, forKey: .images)
        artwork = try? c.decodeIfPresent(ArtworkGallery.self, forKey: .artwork)
        themes = (try? c.decode([String].self, forKey: .themes)) ?? []
        featuredVideo = try? c.decodeIfPresent(FranchiseVideo.self, forKey: .featuredVideo)
        status = try? c.decodeIfPresent(WatchStatus.self, forKey: .status)
        behind = try? c.decodeIfPresent(Int.self, forKey: .behind)
        newParts = try? c.decodeIfPresent(Int.self, forKey: .newParts)
    }

    /// The calendar this summary's `nextAiringAt` must be read in — see `MediaSource.timeAnchor`.
    var timeAnchor: Formatting.TimeAnchor { source.timeAnchor }
}

// MARK: - Endpoint response envelopes

struct FranchiseListResponse: Codable, Sendable {
    let franchises: [FranchiseSummary]
    /// `/search` only — set when the server spell-corrected/completed the query before searching.
    let correctedQuery: String?
    /// `/search` only — the query the caller sent, echoed **only** alongside `correctedQuery`.
    let originalQuery: String?
    /// `/search` only — per-catalogue outcome (`ok` / `failed` / `disabled`). Absent means
    /// "nothing to report", never "everything failed": a catalogue that FAILED is not a
    /// catalogue with no matches.
    let sources: [String: String]?

    enum CodingKeys: String, CodingKey { case franchises, correctedQuery, originalQuery, sources }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // `franchises` stays a hard requirement: a body without it is a broken response, not an
        // empty result, and swallowing that would render "no results" for a server fault.
        franchises = try c.decode([FranchiseSummary].self, forKey: .franchises)
        correctedQuery = try? c.decodeIfPresent(String.self, forKey: .correctedQuery)
        originalQuery = try? c.decodeIfPresent(String.self, forKey: .originalQuery)
        sources = try? c.decodeIfPresent([String: String].self, forKey: .sources)
    }

    init(franchises: [FranchiseSummary], correctedQuery: String? = nil,
         originalQuery: String? = nil, sources: [String: String]? = nil) {
        self.franchises = franchises
        self.correctedQuery = correctedQuery
        self.originalQuery = originalQuery
        self.sources = sources
    }
}

struct LibraryResponse: Codable, Sendable {
    let franchises: [Franchise]   // LibraryFranchise = full Franchise + status/behind/newParts
    let prevOpenedAt: Int64
}

struct OpenedResponse: Codable, Sendable {
    let prevOpenedAt: Int64
}

struct OKResponse: Codable, Sendable {
    let ok: Bool
}

struct FranchiseProgressResponse: Codable, Sendable {
    let ok: Bool
    let franchiseId: String
    let status: WatchStatus?
    let progress: [FranchiseProgressValue]
}

struct FranchiseProgressBody: Encodable, Sendable {
    let parts: [FranchiseProgressValue]
    let status: WatchStatus?
}

// MARK: - Request bodies

struct RecommendationFeedbackBody: Encodable, Sendable {
    let key: String
    let kind: String?
}

struct ResolveBody: Encodable, Sendable {
    let source: String
    let externalId: Int
}

struct SubscribeBody: Encodable, Sendable {
    let franchiseId: String
    let status: WatchStatus?
}

struct StatusBody: Encodable, Sendable {
    let status: WatchStatus
}

struct ProgressBody: Encodable, Sendable {
    let mediaId: Int
    let episodes: Int
}

// MARK: - Franchise derivation helpers

extension Franchise {
    /// The calendar this franchise's timestamps must be read in — see `MediaSource.timeAnchor`.
    var timeAnchor: Formatting.TimeAnchor { source.timeAnchor }

    /// The next airing you can still count down to, read in this franchise's own calendar.
    /// Prefer this over `releasingPart?.scheduledAiring(now:)`, which defaults to `.local` and so
    /// keeps a TMDB drop alive a day too long east of UTC+7.
    /// Airings-aware: a timed slot that has already struck is an episode, not a wait, so this
    /// moves on to the following one the moment an episode is out (`FranchisePart.upcomingAiring`).
    func nextAiring(now: Int64) -> Int64? {
        releasingPart?.upcomingAiring(now: now, anchor: timeAnchor)
    }

    /// Calendar-day bucket key for one of this franchise's timestamps — what day-grouped feeds
    /// (the Schedule rail, Today's buckets) must group on so a TV row lands on its real date.
    func dayKey(of ts: Int64) -> Int64 { Formatting.localDayKey(ts, anchor: timeAnchor) }

    /// Whole-day offset of one of this franchise's timestamps from today (0 = today, +1 = tomorrow,
    /// −1 = yesterday).
    func dayDiff(of ts: Int64, now: Int64) -> Int {
        Formatting.dayDiff(ts: ts, now: now, anchor: timeAnchor)
    }

    /// The one "when does this land" label for this franchise: anime gets day + clock
    /// ("Tomorrow 9:00 PM"), TV gets a day word alone ("Tomorrow" / "Thursday" / "May 4").
    func whenLabel(ts: Int64, now: Int64) -> String {
        Formatting.fmtWhen(ts: ts, now: now, anchor: timeAnchor)
    }

    /// The currently-RELEASING part that Home / Schedule / Library logic operates on.
    /// Mirrors the api-contract "Client-side derivation": pick the releasing part, preferring
    /// the one with the soonest next airing, else the most recently aired.
    /// The part a FRESH drop is on — Today's deck, "out now", the move back to Watching: the
    /// airing part, else a main-story season RELEASED WHOLE inside `window` (a streaming drop:
    /// every episode out on one day, the part FINISHED within a day of it, so it was never
    /// "releasing" long enough to be seen — Wednesday, The Witcher, review i4).
    func freshPart(now: Int64, window: Int64) -> FranchisePart? {
        if let p = releasingPart { return p }
        return mainStoryEpisodicParts.first { p in
            !p.isReleasing && !p.isUpcoming && p.airedEpisodes > p.progress
                && (p.lastAiredAt.map { $0 <= now && now - $0 <= window } ?? false)
        }
    }

    var releasingPart: FranchisePart? {
        let releasing = parts.filter { $0.isReleasing }
        if releasing.isEmpty { return nil }
        // Prefer a part with an upcoming airing (soonest first).
        let upcoming = releasing
            .filter { $0.nextAiringAt != nil }
            .sorted { ($0.nextAiringAt ?? .max) < ($1.nextAiringAt ?? .max) }
        if let first = upcoming.first { return first }
        // Otherwise the most recently aired releasing part.
        return releasing.sorted { ($0.lastAiredAt ?? 0) > ($1.lastAiredAt ?? 0) }.first
    }

    /// Soonest upcoming airing as an ascending sort key — franchises without a known next airing
    /// (or no releasing part) sort last. Centralizes the `?? .max` sentinel for the schedule/today/
    /// library "soonest first" orderings.
    var nextAiringSortKey: Int64 { releasingPart?.nextAiringAt ?? .max }

    /// Most-recent airing as a descending sort key — franchises with no aired part sort last.
    /// The CATALOGUE'S field: fine for the Library's calm shelves, wrong for anything live — sort
    /// Today's stack on `lastAired(now:)`, or tonight's episode loses the hero to a days-old drop.
    var lastAiredSortKey: Int64 { releasingPart?.lastAiredAt ?? 0 }

    /// When this franchise's latest episode came out, advanced by any airing slot that has struck
    /// since the last sync (`FranchisePart.lastAired`). The recency every live ordering sorts on.
    func lastAired(now: Int64) -> Int64? {
        releasingPart?.lastAired(now: now, anchor: timeAnchor)
    }

    /// The episodic spine (a movie is binary, handled below) in watch order — side stories,
    /// spin-offs and recaps are extras, never the part to resume (`FranchisePart.isMainStory`).
    private var episodicParts: [FranchisePart] { mainStoryEpisodicParts }

    /// Already-available episodes of a part — see `FranchisePart.availableEpisodes()`.
    private static func availableEpisodes(_ p: FranchisePart) -> Int { p.availableEpisodes() }

    /// The part the user would actually resume, in watch order: the one they're mid-way through,
    /// else the first unstarted part *after* everything they finished, else the earliest part with
    /// anything left. Nil when there's no backlog anywhere.
    /// Picking by sequence (not by largest backlog) is the point: a max() would resume S3 at 3/10
    /// into an untouched S5 just because S5 is longer.
    /// With non-sequential progress (S2 untouched, S3 half-watched) the mid-watch part still wins —
    /// resuming what you're actively watching beats sending you back to a season you skipped.
    var resumePart: FranchisePart? {
        let eps = episodicParts
        func available(_ p: FranchisePart) -> Int { Franchise.availableEpisodes(p) }

        if let mid = eps.first(where: { $0.progress > 0 && $0.progress < available($0) }) { return mid }
        // `last` over the ascending list = highest-sequence part watched to completion.
        if let doneSeq = eps.last(where: { available($0) > 0 && $0.progress >= available($0) })?.sequence {
            if let next = eps.first(where: { $0.sequence > doneSeq && available($0) - $0.progress > 0 }) {
                return next
            }
            // Everything from the furthest finished part on is watched: earlier unmarked parts are
            // gaps the viewer skipped or saw elsewhere, never "next" — finishing Season 3 sent
            // Grand Blue's billboard back to "24 EPISODES LEFT · Season 1 · Episode 1" (review
            // i5, F18). The story's films still follow.
            return mainStoryMovies.first { !$0.isUpcoming && available($0) > $0.progress }
        }
        if let first = eps.first(where: { available($0) - $0.progress > 0 }) { return first }
        // Every episode of the spine is watched: the first released film of the story that is
        // not — Demon Slayer's Infinity Castle, the server's own `continueWatching`, sat in no
        // queue anywhere (review, 23 Sep).
        return mainStoryMovies.first { !$0.isUpcoming && available($0) > $0.progress }
    }

    /// Unwatched, already-available episodes of the part you'd resume — the "Keep watching" count.
    /// Zero when nothing is left to watch.
    var continueBacklog: Int {
        guard let p = resumePart else { return 0 }
        return max(0, Franchise.availableEpisodes(p) - p.progress)
    }

    var effectiveStatus: WatchStatus {
        status ?? subscription?.status ?? .planned
    }

    /// Does this show belong on the CALENDAR surfaces — Schedule, and Today's "Out now" /
    /// "Airing soon" / Now Bar?
    ///
    /// A `planned` show is in your library but not in your week. You are not behind on it and you
    /// are not waiting on its next episode; it is something you might start. Without this test a
    /// mid-broadcast show you had only shelved arrived on Today as "20 episodes behind" and on
    /// Schedule with a mark ring whose action was "Mark 20 episodes as watched" — an obligation
    /// invented out of a bookmark, which is exactly what the urgency pact forbids.
    ///
    /// Every other status keeps its airings, deliberately: a `completed` show that starts a new
    /// season is news, and a `paused` one still has a calendar. `EpisodeNotifications` and
    /// `AiringLiveActivityManager` gate harder still (`watching` only) — they interrupt you.
    ///
    /// A DROPPED show is off it too (review, 23 Sep): you walked away, and it kept arriving on
    /// Today's release deck and on Schedule with mark rings — "4 EPISODES BEHIND" on a show you
    /// had said you were done with.
    var tracksAirings: Bool { effectiveStatus != .planned && effectiveStatus != .dropped }

    /// Parts grouped into ordered sections for the detail screen. Seasons are listed newest-first
    /// (reverse sequence) so the latest season is at the top; other kinds stay chronological.
    var sections: [(kind: PartKind, parts: [FranchisePart])] {
        let groups = Dictionary(grouping: parts, by: { $0.kind })
        return groups
            .map { (key, value) -> (kind: PartKind, parts: [FranchisePart]) in
                let ordered = value.sorted { $0.sequence < $1.sequence }
                return (kind: key, parts: key == .season ? ordered.reversed() : ordered)
            }
            .sorted { $0.kind.sortRank < $1.kind.sortRank }
    }
}
