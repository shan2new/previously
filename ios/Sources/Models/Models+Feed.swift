import Foundation

// The Today feed, the social layer and Discover's genres, as the server sends them
// (docs/api-contract.md; server spec §2.1, §3.1, §5.2, §10.2). Swift transcriptions of the wire,
// nothing more: every sentence a post draws is composed on the client (`FeedComposer`, `Copy.Feed`)
// from the structured facts here, and nothing here parses a curated `release` string.
//
// The house decoding rule (Models.swift, Models+Recommendations.swift): every field is `try?` with a
// default, so a server older or newer than this build decodes as EMPTY, never as a failure. Lists
// decode element by element (`Lenient`), so one malformed entry drops itself and not the response.
// A field the server marks REQUIRED and that is missing drops its ITEM (the item's decoder throws;
// the list's `Lenient` swallows it): a `FeedPost` needs `id` + `franchiseId`, a `SocialComment` needs
// `id` + `subject` + `author`, a `NotificationItem` needs `id`. Enum-valued strings decode to
// `.unknown` (or the stated safe default) rather than failing. Timestamps are ms epoch (`Int64`).
//
// Every decoder lives in an EXTENSION, so each struct keeps its memberwise initialiser (the
// optimistic copies and the offline cache's `asCached()` build values by hand), and `encode(to:)` is
// synthesised so the offline cache writes the contract's own shape back.

// MARK: - Decoding helpers

/// A link the app may open: `https` with a host, nothing else. The server already drops every other
/// scheme from research-derived evidence (brief §14); this is the second guard, at the wire.
enum SafeURL {
    static func https(_ raw: String?) -> URL? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
              let url = URL(string: raw), url.scheme?.lowercased() == "https",
              let host = url.host(), !host.isEmpty else { return nil }
        return url
    }
}

fileprivate extension KeyedDecodingContainer {
    /// The value, or `fallback` when it is missing, null or the wrong type.
    func value<T: Decodable>(_ key: Key, or fallback: T) -> T {
        (try? decode(T.self, forKey: key)) ?? fallback
    }

    /// The value, or nil when it is missing, null or the wrong type.
    func maybe<T: Decodable>(_ key: Key) -> T? {
        try? decodeIfPresent(T.self, forKey: key)
    }

    /// A string that says something — an empty or blank string is no string.
    func text(_ key: Key) -> String? {
        ArtworkSet.nonEmpty(try? decodeIfPresent(String.self, forKey: key))
    }

    /// A string the item cannot exist without: missing, null or blank drops the ITEM.
    func requiredText(_ key: Key) throws -> String {
        guard let s = text(key) else {
            throw DecodingError.keyNotFound(key, .init(codingPath: codingPath,
                                                       debugDescription: "required field missing or empty"))
        }
        return s
    }

    /// A list decoded element by element: a malformed entry drops itself, a missing list is empty.
    func list<T: Decodable>(_ key: Key) -> [T] {
        ((try? decodeIfPresent([Lenient<T>].self, forKey: key)) ?? []).compactMap(\.value)
    }

    /// A string-valued enum: missing, null, not a string, or a value this build does not know → `fallback`.
    func token<E: RawRepresentable>(_ key: Key, or fallback: E) -> E where E.RawValue == String {
        (try? decodeIfPresent(String.self, forKey: key)).flatMap { E(rawValue: $0) } ?? fallback
    }

    /// A timestamp or count that must not be negative.
    func nonNegative(_ key: Key) -> Int {
        max(0, (try? decode(Int.self, forKey: key)) ?? 0)
    }
}

// MARK: - Feed

enum FeedTab: String, Codable, Sendable, CaseIterable, Hashable {
    case following
    /// The server's query value (iD7).
    case forYou = "foryou"
}

/// `episode` (4 Oct): "Episode 19 is out" — an episode of a show you follow that aired this week
/// (Following only; the post's id is the episode's room, `ep:<mediaId>:<n>`).
enum FeedPostKind: String, Codable, Sendable { case dated, window, announced, rumour, trailer, episode, unknown }
enum FeedPostOrigin: String, Codable, Sendable { case research, catalogue, video, unknown }

/// When the news happened. A date-only fact is carried at 12:00 UTC of its day (`dateOnly`).
struct FeedTime: Codable, Sendable, Hashable {
    enum Basis: String, Codable, Sendable {
        case primary, firstReport = "first_report", observed, catalogue, published, aired, unknown
    }

    let at: Int64
    let dateOnly: Bool
    let basis: Basis

    /// `.utcDate` when `dateOnly` (the fact is carried at 12:00 UTC of its day).
    var anchor: Formatting.TimeAnchor { dateOnly ? .utcDate : .local }

    enum CodingKeys: String, CodingKey { case at, dateOnly, basis }
}

extension FeedTime {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        at = c.value(.at, or: 0)
        dateOnly = c.value(.dateOnly, or: false)
        basis = c.token(.basis, or: .unknown)
    }
}

/// A premiere slot. `.dateOnly` never yields a clock.
struct FeedPremiere: Codable, Sendable, Hashable {
    enum Precision: String, Codable, Sendable { case exact, dateOnly = "date_only" }

    let at: Int64
    let precision: Precision

    var anchor: Formatting.TimeAnchor { precision == .dateOnly ? .utcDate : .local }

    enum CodingKeys: String, CodingKey { case at, precision }
}

extension FeedPremiere {
    /// A premiere without an instant is no premiere: the decoder throws and the post's `premiere`
    /// reads nil. An unknown precision is read as date-only — the side that never prints a clock
    /// the source did not state.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let at: Int64 = c.maybe(.at), at > 0 else {
            throw DecodingError.keyNotFound(CodingKeys.at, .init(codingPath: c.codingPath,
                                                                 debugDescription: "premiere without an instant"))
        }
        self.at = at
        precision = c.token(.precision, or: .dateOnly)
    }
}

/// `releaseWindow` is the only thing sorted or branched on: a day or a month is formatted from its
/// `date`, and `release` is PRINTED verbatim only for a quarter or a year (`Copy.Feed.windowPhrase`).
/// Never parse or re-read `release` (docs/api-contract.md, brief §3).
struct FeedWindow: Codable, Sendable, Hashable {
    let release: String
    let releaseWindow: ReleaseWindow

    enum CodingKeys: String, CodingKey { case release, releaseWindow }
}

extension FeedWindow {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        release = c.value(.release, or: "").trimmingCharacters(in: .whitespacesAndNewlines)
        releaseWindow = c.value(.releaseWindow, or: ReleaseWindow(date: nil, precision: .unknown, sortKey: nil))
    }
}

/// The server's `AnnouncementEvidenceTier` (`official` … `catalogue`); `other` is this build's
/// reading of a tier it does not know yet.
enum EvidenceTier: String, Codable, Sendable { case official, trade, reputable, unknown, catalogue, other }

struct FeedSource: Codable, Sendable, Hashable {
    let publisher: String
    let tier: EvidenceTier
    /// https only. Decoding drops any other scheme (`SafeURL.https`), a second guard behind the
    /// server's (brief §14).
    let url: URL?
    let publishedAt: Int64?
    let dateOnly: Bool
    let primary: Bool

    enum CodingKeys: String, CodingKey { case publisher, tier, url, publishedAt, dateOnly, primary }
}

extension FeedSource {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        publisher = c.value(.publisher, or: "").trimmingCharacters(in: .whitespacesAndNewlines)
        tier = c.token(.tier, or: .other)
        url = SafeURL.https(c.maybe(.url))
        publishedAt = c.maybe(.publishedAt)
        dateOnly = c.value(.dateOnly, or: false)
        primary = c.value(.primary, or: false)
    }
}

/// The part a post is about: art inputs only. The client picks the frame with its existing accessors.
struct FeedPartRef: Codable, Sendable, Hashable {
    let mediaId: Int
    let label: String
    let kind: PartKind
    let status: String?
    let cover: String?
    let banner: String?
    let images: ArtworkSet?
    let artwork: ArtworkGallery?

    enum CodingKeys: String, CodingKey { case mediaId, label, kind, status, cover, banner, images, artwork }
}

extension FeedPartRef {
    /// A part without a media id is no part: the post's `part` reads nil.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mediaId = try c.decode(Int.self, forKey: .mediaId)
        label = c.value(.label, or: "")
        // `PartKind` has no unknown case; the house default (Models.swift, FranchisePart).
        kind = c.value(.kind, or: .season)
        status = c.text(.status)
        cover = c.text(.cover)
        banner = c.text(.banner)
        images = c.maybe(.images)
        artwork = c.maybe(.artwork)
    }

    // The art accessors, in the ONE order every surface answers in (Models+Enrichment.swift).
    var portraitArt: String? {
        images?.portrait ?? artwork?.portraits.first?.url ?? ArtworkSet.nonEmpty(cover)
    }
    var landscapeArt: String? {
        images?.landscape ?? artwork?.landscapes.first?.url ?? legacyBanner(banner, cover: cover)
    }
    var wideArt: WideArt { WideArt(landscape: landscapeArt, portrait: portraitArt) }
}

/// The post's author row ("the show"), shipped once per response.
struct FeedFranchise: Codable, Sendable, Identifiable {
    let id: String
    let source: MediaSource
    let title: String
    let cover: String?
    let banner: String?
    let images: ArtworkSet?
    let artwork: ArtworkGallery?
    let year: Int?
    let isReleasing: Bool
    /// The viewer's library status; nil = not in the library (or a value this build does not know).
    let status: WatchStatus?
    let upcoming: FranchiseUpcoming?

    enum CodingKeys: String, CodingKey {
        case id, source, title, cover, banner, images, artwork, year, isReleasing, status, upcoming
    }

    /// A `Franchise` carrying only these fields (`parts: []`), so every existing art and name accessor
    /// (`portraitArt`, `landscapeArt`, `textlessPortrait`, `displayTitle`, `billboardLogo`) works on
    /// it. Built once per response by the composer, never in a body.
    var stub: Franchise {
        Franchise(id: id, source: source, title: title, cover: cover, banner: banner, synopsis: nil,
                  genres: [], isReleasing: isReleasing, partCounts: nil, parts: [],
                  subscription: status.map { Subscription(status: $0) }, upcoming: upcoming,
                  year: year, images: images, artwork: artwork,
                  status: status, behind: nil, newParts: nil)
    }

    /// The calendar this show's timestamps are read in — see `MediaSource.timeAnchor`.
    var timeAnchor: Formatting.TimeAnchor { source.timeAnchor }
}

extension FeedFranchise {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.requiredText(.id)
        source = c.value(.source, or: .anilist)
        title = c.text(.title) ?? "Untitled"
        cover = c.text(.cover)
        banner = c.text(.banner)
        images = c.maybe(.images)
        artwork = c.maybe(.artwork)
        year = c.maybe(.year)
        isReleasing = c.value(.isReleasing, or: false)
        status = c.maybe(.status)
        upcoming = c.maybe(.upcoming)
    }

    var portraitArt: String? {
        images?.portrait ?? artwork?.portraits.first?.url ?? ArtworkSet.nonEmpty(cover)
    }
    var landscapeArt: String? {
        images?.landscape ?? artwork?.landscapes.first?.url ?? legacyBanner(banner, cover: cover)
    }
    var wideArt: WideArt { WideArt(landscape: landscapeArt, portrait: portraitArt) }
}

struct FeedViewerState: Codable, Sendable, Hashable {
    let liked: Bool
    let saved: Bool
    let reminded: Bool

    static let empty = FeedViewerState(liked: false, saved: false, reminded: false)

    enum CodingKeys: String, CodingKey { case liked, saved, reminded }
}

extension FeedViewerState {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        liked = c.value(.liked, or: false)
        saved = c.value(.saved, or: false)
        reminded = c.value(.reminded, or: false)
    }
}

struct FeedCounts: Codable, Sendable, Hashable {
    let likes: Int
    let comments: Int

    static let zero = FeedCounts(likes: 0, comments: 0)

    enum CodingKeys: String, CodingKey { case likes, comments }
}

extension FeedCounts {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        likes = c.nonNegative(.likes)
        comments = c.nonNegative(.comments)
    }
}

/// Missing (an older server) decodes as `comments: false` — the safe side of brief §9.
struct FeedCapabilities: Codable, Sendable, Hashable {
    let comments: Bool

    enum CodingKeys: String, CodingKey { case comments }
}

extension FeedCapabilities {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        comments = c.value(.comments, or: false)
    }
}

/// Why a For you post is in THIS viewer's feed (4 Oct: "for you is not really recommendation based
/// on user's watch history. It's just too random", owner — the server ranks For you from the
/// library now, and says why): the recommender picked the show from the viewer's own shows, or it
/// is a trending show in the genres they watch most. Nil on Following, on an unexplained post, and
/// from a server that predates it; an unknown kind reads as nil, never as a decode failure.
enum FeedPostContext: Codable, Sendable, Equatable {
    /// The recommender's reason: its kind and the viewer's shows behind it, strongest first.
    case recommended(kind: RecommendationItem.Reason.Kind, seeds: [RecommendationItem.Seed], count: Int)
    /// One or two genres, the viewer's strongest first.
    case taste(genres: [String])

    private enum CodingKeys: String, CodingKey { case kind, reason, genres }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch (try? c.decode(String.self, forKey: .kind)) ?? "" {
        case "recommended":
            let reason = try c.decode(RecommendationItem.Reason.self, forKey: .reason)
            self = .recommended(kind: reason.kind, seeds: reason.seeds, count: reason.count)
        case "taste":
            let genres = ((try? c.decode([String].self, forKey: .genres)) ?? []).filter { !$0.isEmpty }
            guard !genres.isEmpty else {
                throw DecodingError.dataCorruptedError(forKey: .genres, in: c, debugDescription: "no genres")
            }
            self = .taste(genres: Array(genres.prefix(2)))
        default:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "unknown context")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .recommended(let kind, let seeds, let count):
            try c.encode("recommended", forKey: .kind)
            try c.encode(RecommendationItem.Reason(kind: kind, seeds: seeds, count: count), forKey: .reason)
        case .taste(let genres):
            try c.encode("taste", forKey: .kind)
            try c.encode(genres, forKey: .genres)
        }
    }
}

/// Equatable (synthesised over every field) so a composed row redraws when anything it was built
/// from changes (`FeedPostModel.==`).
struct FeedPost: Codable, Sendable, Identifiable, Equatable {
    /// PostId:`news:<uuid>` | `catalog:<mediaId>` | `trailer:<fid>:<site>:<videoId>` — OPAQUE.
    let id: String
    let kind: FeedPostKind
    let origin: FeedPostOrigin
    let franchiseId: String
    /// "Season 2"; "" for a franchise-scope trailer.
    let installment: String
    let isMovie: Bool
    let part: FeedPartRef?
    let time: FeedTime
    /// When the app first knew this post in its current state. "New" compares this, never `time`.
    let discoveredAt: Int64
    /// Set by the server against the response's `prevOpenedAt`. Fresh posts come first.
    let fresh: Bool
    let premiere: FeedPremiere?
    let window: FeedWindow?
    let note: String?
    let video: FranchiseVideo?
    /// Ranked; `[0]` is the lead.
    let sources: [FeedSource]
    /// The ONLY condition for the gold check (brief §13).
    let isOfficial: Bool
    let viewer: FeedViewerState
    let counts: FeedCounts
    /// For you only: why this post is in the viewer's feed (`FeedPostContext`).
    let context: FeedPostContext?
    /// The episode an `.episode` post announces; nil on every other kind.
    let episode: Int?

    enum CodingKeys: String, CodingKey {
        case id, kind, origin, franchiseId, installment, isMovie, part, time, discoveredAt, fresh
        case premiere, window, note, video, sources, isOfficial, viewer, counts, context, episode
    }
}

extension FeedPost {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.requiredText(.id)
        franchiseId = try c.requiredText(.franchiseId)
        kind = c.token(.kind, or: .unknown)
        origin = c.token(.origin, or: .unknown)
        installment = c.value(.installment, or: "").trimmingCharacters(in: .whitespacesAndNewlines)
        isMovie = c.value(.isMovie, or: false)
        part = c.maybe(.part)
        let discovered: Int64 = c.value(.discoveredAt, or: 0)
        discoveredAt = discovered
        // A post with no news date reads as when the app learned of it — never as the epoch.
        time = c.maybe(.time) ?? FeedTime(at: discovered, dateOnly: false, basis: .unknown)
        fresh = c.value(.fresh, or: false)
        premiere = c.maybe(.premiere)
        window = c.maybe(.window)
        note = c.text(.note)
        video = c.maybe(.video)
        sources = c.list(.sources)
        isOfficial = c.value(.isOfficial, or: false)
        viewer = c.value(.viewer, or: .empty)
        counts = c.value(.counts, or: .zero)
        context = c.maybe(.context)
        episode = c.maybe(.episode)
    }
}

struct FeedResponse: Codable, Sendable {
    let tab: FeedTab
    let generatedAt: Int64
    /// The previous visit the server ordered against (`users.prev_opened_at`).
    let prevOpenedAt: Int64
    let capabilities: FeedCapabilities
    /// Exactly the franchises the posts reference.
    let franchises: [FeedFranchise]
    let posts: [FeedPost]
    /// For you only: untracked, unmuted trending shows (the Trending module), ranked. `[]` on Following.
    let trending: [FranchiseSummary]

    enum CodingKeys: String, CodingKey {
        case tab, generatedAt, prevOpenedAt, capabilities, franchises, posts, trending
    }

    /// A copy with every post's `fresh` set to false (iD2) — for the offline cache. The response was
    /// fetched during an earlier visit, so nothing in it is new since this one.
    func asCached() -> FeedResponse {
        FeedResponse(tab: tab, generatedAt: generatedAt, prevOpenedAt: prevOpenedAt,
                     capabilities: capabilities, franchises: franchises,
                     posts: posts.map { p in
                         FeedPost(id: p.id, kind: p.kind, origin: p.origin, franchiseId: p.franchiseId,
                                  installment: p.installment, isMovie: p.isMovie, part: p.part, time: p.time,
                                  discoveredAt: p.discoveredAt, fresh: false, premiere: p.premiere,
                                  window: p.window, note: p.note, video: p.video, sources: p.sources,
                                  isOfficial: p.isOfficial, viewer: p.viewer, counts: p.counts,
                                  context: p.context, episode: p.episode)
                     },
                     trending: trending)
    }
}

extension FeedResponse {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tab = c.value(.tab, or: .following)
        generatedAt = c.value(.generatedAt, or: 0)
        prevOpenedAt = c.value(.prevOpenedAt, or: 0)
        capabilities = c.value(.capabilities, or: FeedCapabilities(comments: false))
        franchises = c.list(.franchises)
        posts = c.list(.posts)
        trending = c.list(.trending)
    }
}

/// Server `StoryBeat` (server spec §2.1), renamed: on iOS "story" is the tray.
struct NewsBeat: Codable, Sendable, Identifiable {
    /// yyyymmdd (UTC) of the beat's day.
    let id: String
    /// ms of the lead report.
    let day: Int64
    let publishers: [String]
    let official: Bool
    let primary: Bool
    let headline: String?
    /// https only.
    let url: URL?

    enum CodingKeys: String, CodingKey { case id, day, publishers, official, primary, headline, url }
}

extension NewsBeat {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.requiredText(.id)
        day = c.value(.day, or: 0)
        publishers = (c.list(.publishers) as [String]).compactMap { ArtworkSet.nonEmpty($0) }
        official = c.value(.official, or: false)
        primary = c.value(.primary, or: false)
        headline = c.text(.headline)
        url = SafeURL.https(c.maybe(.url))
    }
}

/// `GET /feed/posts/:id`.
struct FeedPostDetail: Codable, Sendable {
    /// `post.id` is CANONICAL: the thread subject (server §13.12).
    let post: FeedPost
    let franchise: FeedFranchise
    /// False when the franchise's feed no longer carries this post (the thread is still open).
    let live: Bool
    let storyline: [NewsBeat]
    let threadSources: [FeedSource]
    let capabilities: FeedCapabilities

    enum CodingKeys: String, CodingKey { case post, franchise, live, storyline, threadSources, capabilities }
}

extension FeedPostDetail {
    /// The post and its show are the page; without either there is nothing to draw, so the request
    /// fails (as a decode error) rather than rendering an empty page.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        post = try c.decode(FeedPost.self, forKey: .post)
        franchise = try c.decode(FeedFranchise.self, forKey: .franchise)
        live = c.value(.live, or: true)
        storyline = c.list(.storyline)
        threadSources = c.list(.threadSources)
        capabilities = c.value(.capabilities, or: FeedCapabilities(comments: false))
    }
}

/// `post: nil` means the post can no longer be composed (a catalogue post whose part has released).
struct SavedItem: Codable, Sendable, Identifiable {
    let postId: String
    let savedAt: Int64
    let post: FeedPost?
    var id: String { postId }

    enum CodingKeys: String, CodingKey { case postId, savedAt, post }
}

extension SavedItem {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        postId = try c.requiredText(.postId)
        savedAt = c.value(.savedAt, or: 0)
        post = c.maybe(.post)
    }
}

struct SavedResponse: Codable, Sendable {
    let items: [SavedItem]
    let franchises: [FeedFranchise]

    enum CodingKeys: String, CodingKey { case items, franchises }
}

extension SavedResponse {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = c.list(.items)
        franchises = c.list(.franchises)
    }
}

struct ReminderItem: Codable, Sendable, Identifiable {
    let postId: String
    let remindedAt: Int64
    let post: FeedPost?
    var id: String { postId }

    enum CodingKeys: String, CodingKey { case postId, remindedAt, post }
}

extension ReminderItem {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        postId = try c.requiredText(.postId)
        remindedAt = c.value(.remindedAt, or: 0)
        post = c.maybe(.post)
    }
}

struct RemindersResponse: Codable, Sendable {
    let items: [ReminderItem]
    let franchises: [FeedFranchise]

    enum CodingKeys: String, CodingKey { case items, franchises }
}

extension RemindersResponse {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = c.list(.items)
        franchises = c.list(.franchises)
    }
}

// MARK: - Social

struct PublicUser: Codable, Sendable, Hashable, Identifiable {
    let id: String
    let handle: String
    let displayName: String

    /// The disc's letter: the first letter of the name (`AuthManager.letter(of:)`, the account
    /// disc's rule), else the handle's first character, uppercased.
    var monogram: String {
        if let letter = AuthManager.letter(of: displayName) { return letter }
        guard let first = handle.trimmingCharacters(in: .whitespacesAndNewlines).first else { return "" }
        return String(first).uppercased()
    }

    enum CodingKeys: String, CodingKey { case id, handle, displayName }
}

extension PublicUser {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.requiredText(.id)
        handle = c.value(.handle, or: "").trimmingCharacters(in: .whitespacesAndNewlines)
        displayName = c.value(.displayName, or: "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct SocialComment: Codable, Sendable, Identifiable, Hashable {
    let id: String
    let subject: String
    let author: PublicUser
    let body: String
    let createdAt: Int64
    let parentId: String?
    /// The parent's author while the parent is still visible to the viewer.
    let replyTo: PublicUser?
    let likeCount: Int
    let liked: Bool
    let replyCount: Int
    let mine: Bool

    enum CodingKeys: String, CodingKey {
        case id, subject, author, body, createdAt, parentId, replyTo, likeCount, liked, replyCount, mine
    }
}

extension SocialComment {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.requiredText(.id)
        subject = try c.requiredText(.subject)
        author = try c.decode(PublicUser.self, forKey: .author)
        body = c.value(.body, or: "")
        createdAt = c.value(.createdAt, or: 0)
        parentId = c.text(.parentId)
        replyTo = c.maybe(.replyTo)
        likeCount = c.nonNegative(.likeCount)
        liked = c.value(.liked, or: false)
        replyCount = c.nonNegative(.replyCount)
        mine = c.value(.mine, or: false)
    }
}

enum CommentSort: String, Codable, Sendable, CaseIterable { case top, latest }
enum EpisodeAccess: String, Codable, Sendable { case open, unwatched, unaired, unknown }

struct CommentsPage: Codable, Sendable {
    let subject: String
    /// Episode rooms only: the viewer may not read it, and `items` is `[]`.
    let locked: Bool
    /// nil for post subjects.
    let access: EpisodeAccess?
    /// Visible comments for this viewer (blocks and own reports applied).
    let total: Int
    let items: [SocialComment]
    /// OPAQUE; passed back verbatim.
    let nextCursor: String?

    enum CodingKeys: String, CodingKey { case subject, locked, access, total, items, nextCursor }
}

extension CommentsPage {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        subject = c.value(.subject, or: "")
        locked = c.value(.locked, or: false)
        let rawAccess: String? = c.maybe(.access)
        access = rawAccess.map { EpisodeAccess(rawValue: $0) ?? .unknown }
        total = c.nonNegative(.total)
        items = c.list(.items)
        nextCursor = c.text(.nextCursor)
    }
}

struct CommentResponse: Codable, Sendable {
    let comment: SocialComment
}

struct EpisodeRating: Codable, Sendable, Hashable {
    let count: Int
    /// 0–100, one decimal; nil when locked or when nobody has rated.
    let average: Double?
    /// 0–100.
    let yours: Int?

    static let empty = EpisodeRating(count: 0, average: nil, yours: nil)

    enum CodingKeys: String, CodingKey { case count, average, yours }
}

extension EpisodeRating {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        count = c.nonNegative(.count)
        average = (c.maybe(.average) as Double?).map { min(100, max(0, $0)) }
        yours = (c.maybe(.yours) as Int?).map { min(100, max(0, $0)) }
    }
}

struct EpisodeRoom: Codable, Sendable {
    let subject: String
    let franchiseId: String
    let mediaId: Int
    let episode: Int
    let access: EpisodeAccess
    /// The global visible count ("join N comments").
    let commentCount: Int
    let likeCount: Int
    let liked: Bool
    let rating: EpisodeRating

    enum CodingKeys: String, CodingKey {
        case subject, franchiseId, mediaId, episode, access, commentCount, likeCount, liked, rating
    }
}

extension EpisodeRoom {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let media: Int = c.value(.mediaId, or: 0)
        let number: Int = c.value(.episode, or: 0)
        mediaId = media
        episode = number
        subject = c.text(.subject) ?? ThreadSubject.episode(mediaId: media, episode: number)
        franchiseId = c.value(.franchiseId, or: "")
        access = c.token(.access, or: .unknown)
        commentCount = c.nonNegative(.commentCount)
        likeCount = c.nonNegative(.likeCount)
        liked = c.value(.liked, or: false)
        rating = c.value(.rating, or: .empty)
    }
}

enum ReportReason: String, Codable, Sendable, CaseIterable {
    case spam, harassment, hate, sexual, violence, spoiler, other
}

struct BlockedUser: Codable, Sendable, Identifiable {
    let user: PublicUser
    let blockedAt: Int64
    var id: String { user.id }

    enum CodingKeys: String, CodingKey { case user, blockedAt }
}

extension BlockedUser {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        user = try c.decode(PublicUser.self, forKey: .user)
        blockedAt = c.value(.blockedAt, or: 0)
    }
}

struct BlockedUsersResponse: Codable, Sendable {
    let items: [BlockedUser]

    enum CodingKeys: String, CodingKey { case items }
}

extension BlockedUsersResponse {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = c.list(.items)
    }
}

struct FeedHide: Codable, Sendable, Identifiable {
    enum Kind: String, Codable, Sendable { case post, show, unknown }

    struct Show: Codable, Sendable {
        let id: String
        let title: String

        enum CodingKeys: String, CodingKey { case id, title }
    }

    let kind: Kind
    /// A PostId for `.post`, a franchise uuid for `.show`.
    let target: String
    let createdAt: Int64
    /// Set for `.show`.
    let franchise: Show?

    var id: String { "\(kind.rawValue):\(target)" }

    enum CodingKeys: String, CodingKey { case kind, target, createdAt, franchise }
}

extension FeedHide.Show {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.requiredText(.id)
        title = c.text(.title) ?? "Untitled"
    }
}

extension FeedHide {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = c.token(.kind, or: .unknown)
        target = try c.requiredText(.target)
        createdAt = c.value(.createdAt, or: 0)
        franchise = c.maybe(.franchise)
    }
}

struct HidesResponse: Codable, Sendable {
    let items: [FeedHide]

    enum CodingKeys: String, CodingKey { case items }
}

extension HidesResponse {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = c.list(.items)
    }
}

/// The server's `ProfileResponse`.
struct SocialProfile: Codable, Sendable, Equatable {
    let userId: String
    let handle: String?
    let displayName: String?
    let termsAcceptedAt: Int64?
    let termsVersion: String?
    let currentTermsVersion: String
    /// handle && displayName && terms current && comments enabled.
    let canComment: Bool

    var needsTerms: Bool { termsVersion != currentTermsVersion }
    var needsIdentity: Bool { handle == nil || displayName == nil }

    enum CodingKeys: String, CodingKey {
        case userId, handle, displayName, termsAcceptedAt, termsVersion, currentTermsVersion, canComment
    }
}

extension SocialProfile {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        userId = c.value(.userId, or: "")
        handle = c.text(.handle)
        displayName = c.text(.displayName)
        termsAcceptedAt = c.maybe(.termsAcceptedAt)
        termsVersion = c.text(.termsVersion)
        currentTermsVersion = c.value(.currentTermsVersion, or: "")
        canComment = c.value(.canComment, or: false)
    }
}

struct HandleAvailability: Codable, Sendable {
    let handle: String
    let available: Bool
    /// nil | "taken" | a `HandleRejection` ("length", "characters", "dots", "no_letter", "reserved", "blocked_term").
    let reason: String?

    enum CodingKeys: String, CodingKey { case handle, available, reason }
}

extension HandleAvailability {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        handle = c.value(.handle, or: "")
        available = c.value(.available, or: false)
        reason = c.text(.reason)
    }
}

/// Machine codes (server §3.1, §3.4). Built from an error body's `error` string by `init(rawBody:)`.
enum SocialErrorCode: String, Sendable {
    case handleRequired = "handle_required", termsRequired = "terms_required", episodeLocked = "episode_locked"
    case idConflict = "id_conflict", handleTaken = "handle_taken", ownComment = "own_comment", selfBlock = "self_block"
    case termsVersionMismatch = "terms_version_mismatch", contentRejected = "content_rejected"
    case invalidHandle = "invalid_handle", invalidDisplayName = "invalid_display_name"
    case rateLimited = "rate_limited", accountSuspended = "account_suspended"
    case commentsDisabled = "comments disabled", commentDeleted = "comment deleted"
    case notFound, invalidRequest = "invalid request", unknown

    /// `rawBody` is the error body's `error` string ("episode_locked", "comments disabled", "post not
    /// found", …); a whole JSON error body is accepted too. Every "<noun> not found" is `.notFound`;
    /// anything this build does not know is `.unknown`.
    init(rawBody: String) {
        var raw = rawBody.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.hasPrefix("{"), let data = raw.data(using: .utf8),
           let body = try? JSONDecoder().decode(SocialError.self, from: data) {
            raw = body.error.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let lowered = raw.lowercased()
        if let code = SocialErrorCode(rawValue: lowered), code != .notFound, code != .unknown {
            self = code
        } else if lowered == "not found" || lowered.hasSuffix(" not found") {
            self = .notFound
        } else {
            self = .unknown
        }
    }
}

/// A social route's error body: `{ error, reason?, retryAfter?, currentVersion? }`.
struct SocialError: Decodable, Sendable {
    let error: String
    /// A `ContentRejection` | `HandleRejection` | `DisplayNameRejection` | `"unwatched"` | `"unaired"`.
    let reason: String?
    /// Seconds (a 429's body; the `Retry-After` header carries the same number).
    let retryAfter: Int?
    /// `terms_required` / `terms_version_mismatch`: the version to accept.
    let currentVersion: String?

    var code: SocialErrorCode { SocialErrorCode(rawBody: error) }

    enum CodingKeys: String, CodingKey { case error, reason, retryAfter, currentVersion }
}

extension SocialError {
    /// A body without an `error` string is not a social error body: the decoder throws, and
    /// `APIError.socialError` reads nil.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        error = try c.requiredText(.error)
        reason = c.text(.reason)
        // Whole seconds, rounded UP (a wait of 1.2 s is not over at 1 s).
        // Capped at a day so a hostile number can never overflow the conversion.
        retryAfter = (c.maybe(.retryAfter) as Double?).flatMap {
            $0.isFinite && $0 >= 0 ? Int(min($0, RetryPolicy.maxRetryAfterRaw).rounded(.up)) : nil
        }
        currentVersion = c.text(.currentVersion)
    }
}

// MARK: - Activity

enum NotificationKind: String, Codable, Sendable {
    case newsRumored = "news_rumored", newsAnnounced = "news_announced", newsDated = "news_dated"
    case reply, likeComment = "like_comment"
    /// Moderation notices (DSA Art. 16(5)/17): a row that OPENS NOTHING, worded from `body`, which
    /// is a machine category here, never English. Listed whether or not comments are on, and
    /// counted toward `unread`.
    case commentHidden = "comment_hidden", reportResolved = "report_resolved"
    case unknown
}

/// A news row's fact, read LIVE from the announcement (server §5.2): what Activity words the row
/// from, with the feed's headline grammar. `release` is PRINTED, never parsed; `releaseWindow` is
/// what is formatted. A missing or malformed value (no installment to print) reads as nil, and the
/// row falls back to `body`.
struct NotificationNews: Codable, Sendable, Hashable {
    /// `rumored` | `announced_no_date` | `announced` | `upcoming_dated`; anything else is kept as
    /// sent and read as announced.
    let status: String
    let installment: String
    let isMovie: Bool
    /// "" when research's text could not be printed (its window is then unknown unless day-precise).
    let release: String
    let releaseWindow: ReleaseWindow

    enum CodingKeys: String, CodingKey { case status, installment, isMovie, release, releaseWindow }
}

extension NotificationNews {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        installment = try c.requiredText(.installment)
        status = c.value(.status, or: "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        isMovie = c.value(.isMovie, or: false)
        release = c.value(.release, or: "").trimmingCharacters(in: .whitespacesAndNewlines)
        releaseWindow = c.value(.releaseWindow, or: ReleaseWindow(date: nil, precision: .unknown, sortKey: nil))
    }
}

struct NotificationItem: Codable, Sendable, Identifiable, Equatable {
    let id: String
    let franchiseId: String
    let kind: NotificationKind
    /// The franchise title.
    let title: String
    /// News: the server's text. Social: "".
    let body: String
    let createdAt: Int64
    let readAt: Int64?
    /// `reply` / `like_comment`.
    let actor: PublicUser?
    /// `like_comment`: the distinct likers folded in (≥ 1); 0 otherwise.
    let actorCount: Int
    /// The thread to open (social kinds).
    let subject: String?
    /// The post to open.
    let postId: String?
    /// The comment to scroll to.
    let commentId: String?
    /// The first 140 code points of the comment (reply: the reply; like: your comment); nil if gone.
    let excerpt: String?
    /// News kinds: the fact to word the row from. Nil for social and moderation kinds, for a news
    /// row whose announcement is gone, and from a server that predates the field (then `body`).
    var news: NotificationNews? = nil

    enum CodingKeys: String, CodingKey {
        case id, franchiseId, kind, title, body, createdAt, readAt, actor, actorCount
        case subject, postId, commentId, excerpt, news
    }
}

extension NotificationItem {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.requiredText(.id)
        franchiseId = c.value(.franchiseId, or: "")
        kind = c.token(.kind, or: .unknown)
        title = c.value(.title, or: "")
        body = c.value(.body, or: "")
        createdAt = c.value(.createdAt, or: 0)
        readAt = c.maybe(.readAt)
        actor = c.maybe(.actor)
        actorCount = c.nonNegative(.actorCount)
        subject = c.text(.subject)
        postId = c.text(.postId)
        commentId = c.text(.commentId)
        excerpt = c.text(.excerpt)
        news = c.maybe(.news)
    }
}

struct NotificationsPage: Codable, Sendable {
    let items: [NotificationItem]
    let unread: Int
    let nextCursor: String?

    enum CodingKeys: String, CodingKey { case items, unread, nextCursor }
}

extension NotificationsPage {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = c.list(.items)
        unread = c.nonNegative(.unread)
        nextCursor = c.text(.nextCursor)
    }
}

// MARK: - Discover genres

struct DiscoverGenre: Codable, Sendable, Identifiable, Hashable {
    let key: String
    let name: String
    let count: Int
    /// ≤ 4 portrait URLs, the genre's top trending (non-adult) shows.
    let posters: [String]
    var id: String { key }

    enum CodingKeys: String, CodingKey { case key, name, count, posters }
}

extension DiscoverGenre {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.requiredText(.key)
        name = c.text(.name) ?? key
        count = c.nonNegative(.count)
        posters = (c.list(.posters) as [String]).compactMap { ArtworkSet.nonEmpty($0) }
    }
}

struct DiscoverGenresResponse: Codable, Sendable {
    /// The scope the list was built for; nil = All.
    let source: MediaSource?
    let genres: [DiscoverGenre]
    let generatedAt: Int64

    enum CodingKeys: String, CodingKey { case source, genres, generatedAt }
}

extension DiscoverGenresResponse {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        source = c.maybe(.source)
        genres = c.list(.genres)
        generatedAt = c.value(.generatedAt, or: 0)
    }
}

struct DiscoverGenrePage: Codable, Sendable {
    let genre: DiscoverGenre
    /// Ranked; owned titles are MARKED (`status`), not excluded.
    let franchises: [FranchiseSummary]
    let nextCursor: String?

    enum CodingKeys: String, CodingKey { case genre, franchises, nextCursor }
}

extension DiscoverGenrePage {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        genre = c.value(.genre, or: DiscoverGenre(key: "", name: "", count: 0, posters: []))
        franchises = c.list(.franchises)
        nextCursor = c.text(.nextCursor)
    }
}

// MARK: - Request bodies (exact JSON keys)

/// `/me/likes`.
struct SubjectBody: Encodable, Sendable { let subject: String }
/// `/me/saves`, `/me/reminders`.
struct PostIdBody: Encodable, Sendable { let postId: String }
/// `kind` "post" (target a PostId) | "show" (target a franchise uuid).
struct HideBody: Encodable, Sendable { let kind: String; let target: String }
/// `score` 0…100.
struct RatingBody: Encodable, Sendable { let mediaId: Int; let episode: Int; let score: Int }
struct RatingKeyBody: Encodable, Sendable { let mediaId: Int; let episode: Int }
struct BlockBody: Encodable, Sendable { let userId: String }
/// `id` is the client's lowercase v4 uuid — the server's upsert key, so a replay cannot double-post.
struct CommentBody: Encodable, Sendable { let id: String; let subject: String; let body: String; let parentId: String? }
struct ReportBody: Encodable, Sendable { let reason: String; let note: String? }
struct ProfileBody: Encodable, Sendable { let handle: String; let displayName: String }
struct TermsBody: Encodable, Sendable { let version: String }
/// `ids: nil` marks everything read.
struct NotificationsReadBody: Encodable, Sendable { let ids: [String]? }

/// Any JSON body, ignored (`POST /me/notifications/read` answers a small object nobody reads). An
/// empty body is accepted too (`APIClient` returns `IgnoredResponse()` for it).
struct IgnoredResponse: Decodable, Sendable {
    init() {}
    init(from decoder: Decoder) throws {}
}

// MARK: - Subjects and compose targets (client helpers)

/// Ids are OPAQUE (server §0.1) except the episode room, which the client builds and parses.
enum ThreadSubject {
    /// `ep:<mediaId>:<n>` — byte for byte the spike's key.
    static func episode(mediaId: Int, episode: Int) -> String { "ep:\(mediaId):\(episode)" }

    /// `ep:<mediaId>:<n>` → (mediaId, n); nil for any other subject. The server's grammar exactly:
    /// `^ep:([1-9][0-9]{0,9}):([1-9][0-9]{0,4})$`, mediaId ≤ 2147483647.
    static func parseEpisode(_ subject: String) -> (mediaId: Int, episode: Int)? {
        let parts = subject.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "ep",
              let mediaId = positive(parts[1], maxDigits: 10, max: Int(Int32.max)),
              let episode = positive(parts[2], maxDigits: 5, max: 99_999) else { return nil }
        return (mediaId, episode)
    }

    static func isEpisode(_ subject: String) -> Bool { parseEpisode(subject) != nil }

    /// `catalog:<mediaId>` → mediaId (for the 404-after-adoption fallback, server §13.12).
    static func catalogMediaId(_ subject: String) -> Int? {
        let parts = subject.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0] == "catalog" else { return nil }
        return positive(parts[1], maxDigits: 10, max: Int(Int32.max))
    }

    /// A positive decimal with no leading zero and at most `maxDigits` ASCII digits, ≤ `max`.
    private static func positive(_ s: Substring, maxDigits: Int, max: Int) -> Int? {
        guard !s.isEmpty, s.count <= maxDigits, s.first != "0",
              s.allSatisfy({ $0.isASCII && $0.isNumber }),
              let value = Int(s), value <= max else { return nil }
        return value
    }
}

/// What the composer is replying to.
struct ComposeTarget: Identifiable, Hashable, Sendable {
    let subject: String
    let franchiseId: String
    /// The show's `displayTitle`.
    let franchiseTitle: String
    var parentId: String? = nil
    var replyingTo: PublicUser? = nil
    /// Set for `ep:` subjects (the audience line).
    var episode: Int? = nil
    var prefill: String = ""
    var id: String { "\(subject)|\(parentId ?? "")" }
}

/// Comment length exactly as the server counts it (server §4.2): code points of the NFC, trimmed text.
enum SocialText {
    static let limit = 280
    static func count(_ draft: String) -> Int {
        draft.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping.unicodeScalars.count
    }
}
