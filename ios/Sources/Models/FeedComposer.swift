import Foundation

// The Today feed's view model and its one row rule (spec §1.7). Everything a post row draws is
// computed HERE, once per memo key (`AppModel.feedRows`), never in a body: the headline, the
// sentence, the post's whole text (`body`), the stamp, the art, the share text. The composer is pure — no singleton reads, no
// clock of its own — so `FeedRegression` can hold it to its rules with JSON fixtures.
//
// Also here: the model layer's small supporting types (spec §1.6.1), so the stored properties in
// `AppModel.swift` and the three extensions share one vocabulary.

// MARK: - Per-tab state

struct FeedTabState: Sendable {
    /// The last response that arrived — or the offline copy (`fromCache`, fresh flags cleared).
    var response: FeedResponse?
    /// `response` came from `feed-cache.json`; nothing in it is new since this visit (iD2).
    var fromCache = false
    var loading = false
    /// The last request failed. Content may still be on screen (a notice row says so).
    var failed = false
    /// 404: a server older than `/me/feed` (iD8). A degraded feed, never a blank one.
    var unavailable = false
    /// When `response` arrived (the cache's `savedAt` for the offline copy).
    var loadedAt: Int64 = 0
}

// MARK: - Social state

/// The server's truth for one subject (a post id, an `ep:` room, or `c:<commentId>` for a reply),
/// from the latest response that carried it. The UI reads it THROUGH the pending overlay.
struct SubjectSocial: Codable, Sendable, Hashable {
    var liked = false, likes = 0, saved = false, reminded = false, comments = 0
}

enum SocialToggleKind: String, Codable, Sendable { case like, save, remind, hidePost, muteShow, commentLike, block }

struct SocialToggleKey: Hashable, Codable, Sendable {
    let kind: SocialToggleKind
    /// A subject (like), a post id (save/remind/hidePost), a franchise id (muteShow), a comment id
    /// (commentLike) or a user id (block).
    let target: String
}

/// The newest word for one toggle that the server has not confirmed (persisted, spec §4.3).
struct SocialToggleWrite: Codable, Sendable {
    var on: Bool
    /// save/remind/hide: carried for the receipt and the reminder alert.
    var franchiseId: String?
    var queuedAt: Int64
    var attempts = 0
    /// ms epoch; set by a 429 — the lane waits until then.
    var retryAfter: Int64?
}

struct PendingRating: Codable, Sendable {
    let mediaId: Int
    let episode: Int
    /// 0…100; nil clears the rating (DELETE).
    var score: Int?
    var queuedAt: Int64
}

/// A reply that has not reached the server yet: drawn at the top of its thread ("Sending"), kept
/// across launches, and replayed with the SAME id (the server upserts on it, server §3.5).
struct PendingComment: Codable, Sendable, Identifiable, Hashable {
    enum State: String, Codable, Sendable { case sending, failed, rateLimited }
    /// Lowercase v4 uuid — the server's upsert key.
    let id: String
    let subject: String
    let franchiseId: String
    let franchiseTitle: String
    let parentId: String?
    let replyingTo: PublicUser?
    let body: String
    let createdAt: Int64
    var state: State
}

struct CommentThread: Sendable {
    var sort: CommentSort = .top
    /// Deduped by id across pages (`top` pages can repeat under changing like counts, server §13.8).
    var items: [SocialComment] = []
    var total = 0
    var nextCursor: String?
    var locked = false
    var access: EpisodeAccess?
    var loading = false
    var failed = false
    var loadedOnce = false
}

/// A post hidden IN PLACE this session, with its Undo ("Thanks · Undo"). Never persisted.
enum FeedFold: Equatable, Sendable {
    case notInterested
    case muted(show: String)
}

struct PostDetailState: Sendable {
    var detail: FeedPostDetail?
    /// Composed once when the detail lands.
    var model: FeedPostModel?
    var loading = false
    var notFound = false
    var failed = false
}

// MARK: - The post, ready to draw

/// A post ready to draw: every string computed once per memo key, never in a body.
struct FeedPostModel: Identifiable, Equatable, Sendable {
    let post: FeedPost
    let show: FeedFranchise
    /// The LIVE library copy when the show is in the library, else `show.stub`. Art and the show
    /// page id.
    let franchise: Franchise
    /// In the library at composition (the row's Add re-reads `isInLibrary` live).
    let isOwned: Bool
    /// `franchise.displayTitle`.
    let showName: String
    /// The name line's shorter spelling when the whole will not fit beside the installment and the
    /// time: the title's identity half ("Demon Slayer" of "Demon Slayer: Kimetsu no Yaiba",
    /// `shelfShortened(fitting:)`); `showName` itself when the title has no such half.
    let shortName: String
    let headline: String
    /// The post's one line.
    let sentence: String
    /// What the post SAYS, wherever it is read — the timeline, the post page, the picture viewer,
    /// the composer's quote: the sentence, then the research's note as its next paragraph. ONE
    /// text, drawn whole, as an X post is. A rumour's is the sentence alone: its note is its
    /// Community Note (`RumourNote`).
    let body: String
    /// The research's note on its own — the body's second paragraph — for the timeline, which draws
    /// the sentence whole and the note CLAMPED to two lines ending on "Show more" (9 Oct: "the Feed
    /// feels utterly cramped unlike X", owner — every post was a 280-character, two-paragraph essay).
    /// Nil on a rumour (its note is its Community Note) and when the research wrote none.
    let note: String?
    /// X's timeline cut of `body` when it runs past 280 characters — to the last word inside them,
    /// then "…" (`FeedComposer.timelineCut`); nil when the body is short enough to draw whole. The
    /// post page always draws `body`; the timeline draws `sentence` + `note`.
    let clippedBody: String?
    /// For you: why the post is here, over its name — "Because you’re watching Re:ZERO",
    /// "Trending in Fantasy" (`FeedPostContext`). Nil on Following and on an unexplained post.
    let contextLine: String?
    /// "2h", "3d", "12 Sep".
    let stamp: String
    /// "Premieres tomorrow" when the post carries a premiere still to come (nil once its day has
    /// passed).
    let premiereLine: String?
    let media: PostMediaArt
    /// The server's flag — forced false for a cached response, a post page, Saved and For you.
    let fresh: Bool
    /// The gold check: the lead source is official (brief §13). Never on a rumour.
    let showsOfficialMark: Bool
    /// The first source with an https link ("Read on …").
    let readOn: FeedSource?
    /// The primary source's link, else `readOn`'s. https only.
    let shareURL: URL?
    let shareText: String
    let accessibilityLabel: String

    var id: String { post.id }

    /// What an `.equatable()` row draws: the words, the picture and the name — a library copy or a
    /// detail graft that changes a post's art or `displayTitle` must redraw the row.
    static func == (a: Self, b: Self) -> Bool {
        a.id == b.id && a.stamp == b.stamp && a.sentence == b.sentence && a.body == b.body
            && a.isOwned == b.isOwned
            && a.fresh == b.fresh && a.premiereLine == b.premiereLine
            && a.media == b.media && a.showName == b.showName
            && a.showsOfficialMark == b.showsOfficialMark && a.readOn?.url == b.readOn?.url
            // The wire post itself: a refresh that upgrades the lead source, swaps the trailer,
            // changes the note, the window or the part's art redraws the row.
            && a.post == b.post
    }
}

/// What a post shows under its text.
enum PostMediaArt: Equatable, Sendable {
    /// A trailer still, tried in order (`FeedVideoStill.candidates`, iD10).
    case trailer(stills: [String], video: FranchiseVideo)
    case art(WideArt)
    /// A rumour: the note replaces the media.
    case none

    static func == (a: Self, b: Self) -> Bool {
        switch (a, b) {
        case let (.trailer(s1, v1), .trailer(s2, v2)): return s1 == s2 && v1.site == v2.site && v1.id == v2.id
        case let (.art(w1), .art(w2)): return w1 == w2
        case (.none, .none): return true
        default: return false
        }
    }
}

// MARK: - Rows

enum FeedRow: Identifiable, Equatable, Sendable {
    case post(FeedPostModel)
    case folded(postId: String, fold: FeedFold)
    case caughtUp(since: Int64)
    /// ≤ 3 `RecommendationItem` keys; the view reads `appModel.visibleRecommendations`.
    case suggested(keys: [String])
    /// ≤ 8 untracked shows.
    case trending([FranchiseSummary])
    case empty(FeedEmptyKind)
    /// A one-line `InlineNotice` inside the list.
    case notice(FeedNoticeKind)

    var id: String {
        switch self {
        case .post(let m): return "post/\(m.id)"
        case .folded(let postId, _): return "fold/\(postId)"
        case .caughtUp: return "caughtup"
        case .suggested: return "suggested"
        case .trending: return "trending"
        case .empty(let kind): return "empty/\(kind.rawValue)"
        case .notice(let kind): return "notice/\(kind.rawValue)"
        }
    }

    static func == (a: Self, b: Self) -> Bool {
        switch (a, b) {
        case let (.post(x), .post(y)): return x == y
        case let (.folded(p1, f1), .folded(p2, f2)): return p1 == p2 && f1 == f2
        case let (.caughtUp(s1), .caughtUp(s2)): return s1 == s2
        case let (.suggested(k1), .suggested(k2)): return k1 == k2
        case let (.trending(t1), .trending(t2)): return t1.map(\.id) == t2.map(\.id)
        case let (.empty(e1), .empty(e2)): return e1 == e2
        case let (.notice(n1), .notice(n2)): return n1 == n2
        default: return false
        }
    }
}

enum FeedEmptyKind: String, Sendable { case emptyAccount, noPosts, forYouEmpty }
enum FeedNoticeKind: String, Sendable { case refreshFailed, unavailable, offlineCached }

enum FeedSurfacePhase: Equatable, Sendable {
    /// No response, no cache, a request in flight → skeleton.
    case loading
    /// Failed with nothing to show.
    case errorNoCache(offline: Bool)
    /// Rows (which may include notices).
    case content(refreshing: Bool)
}

// MARK: - The composer

enum FeedComposer {
    /// Suggested sits after this many post rows (or after the last one).
    static let suggestedAfter = 3
    /// For you's Trending module sits after this many post rows (or after the last one).
    static let trendingAfter = 5
    static let maxTrending = 8
    static let maxSuggested = 3

    /// The rows of one tab. Modules are placed BY RULE, never by a fixed index — Suggested appears
    /// with 0, 1, 2 or 200 posts (spec §1.7).
    static func rows(tab: FeedTab, state: FeedTabState, library: [Franchise], libraryIndex: (String) -> Franchise?,
                     now: Int64, folds: [String: FeedFold], hidden: Set<String>,
                     muted: Set<String>, recommendationKeys: [String], untrackedTrending: [FranchiseSummary],
                     libraryEmpty: Bool, online: Bool,
                     allows: (MediaSource) -> Bool = { _ in true }) -> [FeedRow] {
        let suggestedRow: FeedRow? = recommendationKeys.isEmpty
            ? nil : .suggested(keys: Array(recommendationKeys.prefix(maxSuggested)))
        let trendingList = Array(untrackedTrending.prefix(maxTrending))

        // An older server (iD8): the notice, then the modules that do not need it.
        if state.unavailable {
            var rows: [FeedRow] = [.notice(.unavailable)]
            if let suggestedRow { rows.append(suggestedRow) }
            if !trendingList.isEmpty { rows.append(.trending(trendingList)) }
            return rows
        }
        guard let response = state.response else { return [] }

        // The empty account: the empty state and the chart (Following only).
        if tab == .following, libraryEmpty, response.posts.isEmpty {
            return [.empty(.emptyAccount)] + (trendingList.isEmpty ? [] : [.trending(trendingList)])
        }

        // Posts in the server's order (fresh first, server D8). A folded post keeps its place.
        let shows = Dictionary(response.franchises.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var body: [FeedRow] = []
        var freshFlags: [Bool] = []          // parallel to the post/folded rows in `body`
        for post in response.posts {
            let isFresh = tab == .following && !state.fromCache && post.fresh
            if let fold = folds[post.id] {
                body.append(.folded(postId: post.id, fold: fold))
                freshFlags.append(isFresh)
                continue
            }
            guard !hidden.contains(post.id), !muted.contains(post.franchiseId),
                  let show = shows[post.franchiseId] else { continue }
            // For you is the viewer's kind only (`Audience`). The server composes it so; this holds
            // a response cached before the choice, or from an older server, to the same wall.
            // Following is the viewer's own shows and is never filtered.
            guard tab == .following || allows(show.source) else { continue }
            let copy = libraryIndex(post.franchiseId)
            body.append(.post(model(post, show: show, library: copy, owned: copy != nil, now: now, fresh: isFresh,
                                    seedName: { libraryIndex($0.franchiseId)?.displayTitle ?? $0.title })))
            freshFlags.append(isFresh)
        }
        let postRows = body.count

        switch tab {
        case .following:
            // The caught-up marker: between the fresh block and the rest, only when both exist.
            var freshCount = 0
            for (row, fresh) in zip(body, freshFlags) where fresh {
                if case .post = row { freshCount += 1 }
            }
            // Dated by the anchor the server ACTUALLY ordered against (the response's echo of
            // `since`, else its stored visit) — never the device's own, which can disagree with the
            // block boundary it labels (a failed stamp, another device's stamp).
            let anchor = response.prevOpenedAt
            var caughtUpIndex: Int?
            if anchor > 0, freshCount > 0, freshCount < postRows,
               let firstStale = freshFlags.firstIndex(of: false) {
                body.insert(.caughtUp(since: anchor), at: firstStale)
                caughtUpIndex = firstStale
            }
            if postRows == 0 { body.append(.empty(.noPosts)) }
            if let suggestedRow {
                var at = insertionIndex(in: body, afterPostRows: suggestedAfter)
                // The fresh block is never split: a point inside it moves to just after the marker.
                if let caughtUpIndex, at <= caughtUpIndex { at = caughtUpIndex + 1 }
                body.insert(suggestedRow, at: min(at, body.count))
            }
        case .forYou:
            if postRows == 0 { body.append(.empty(.forYouEmpty)) }
            let chart = Array(response.trending.filter { libraryIndex($0.id) == nil }.prefix(maxTrending))
            if !chart.isEmpty {
                body.insert(.trending(chart), at: insertionIndex(in: body, afterPostRows: trendingAfter))
            }
        }

        // One notice at most, first: offline explains a failed refresh better than "couldn't refresh".
        if state.fromCache && !online {
            body.insert(.notice(.offlineCached), at: 0)
        } else if state.failed {
            body.insert(.notice(.refreshFailed), at: 0)
        }
        return body
    }

    /// The index just after the `n`th post/folded row — or after the last one when there are fewer,
    /// or after the empty row when there are none (the end of `rows` either way).
    private static func insertionIndex(in rows: [FeedRow], afterPostRows n: Int) -> Int {
        var seen = 0
        var lastPostEnd: Int?
        for (i, row) in rows.enumerated() {
            switch row {
            case .post, .folded:
                seen += 1
                lastPostEnd = i + 1
                if seen == n { return i + 1 }
            default:
                continue
            }
        }
        if let lastPostEnd { return lastPostEnd }
        if let empty = rows.firstIndex(where: { if case .empty = $0 { return true }; return false }) { return empty + 1 }
        return rows.count
    }

    /// One post, composed. Every word goes through `Copy.Feed` / `TemporalCopy`.
    /// `seedName`: how the viewer's library names a show a For you reason cites (its display title).
    static func model(_ post: FeedPost, show: FeedFranchise, library copy: Franchise?, owned: Bool,
                      now: Int64, fresh: Bool,
                      seedName: (RecommendationItem.Seed) -> String = { $0.title }) -> FeedPostModel {
        let franchise = copy ?? show.stub
        let showName = franchise.displayTitle
        // What the news is about, as a person would say it: the installment — but "Season 1 is
        // confirmed" is a NEW SERIES, and a film the catalogue only numbers ("Movie 1") has no name
        // to print ("A new film, Movie 1, is in production", 4 Oct).
        let numberedFilm = post.isMovie
            && post.installment.range(of: #"^(Movie|Film)( \d+)?$"#, options: [.regularExpression, .caseInsensitive]) != nil
        let firstSeason = !post.isMovie && post.installment.caseInsensitiveCompare("Season 1") == .orderedSame
        let announcement = post.kind == .announced || post.kind == .window || post.kind == .unknown
        let name: String
        if numberedFilm {
            name = Copy.Feed.newFilm
        } else if firstSeason && announcement {
            name = Copy.Feed.newSeries
        } else {
            name = post.installment.isEmpty ? showName : post.installment
        }

        let premiereWhen = post.premiere.map { TemporalCopy.premiereWhen($0.at, anchor: $0.anchor, now: now) }
        // A premiere whose day has passed (the server's hourly sync, or a post opened by id) is told
        // in the past tense, and never announced again as a "Premieres …" line.
        let premierePassed = post.premiere.map {
            TemporalCopy.premiereHasPassed($0.at, anchor: $0.anchor, now: now)
        } ?? false
        let premiereLine = premierePassed ? nil : premiereWhen.map { Copy.Feed.premiereLine($0) }

        let headline: String
        switch post.kind {
        case .dated:
            if let premiereWhen {
                headline = premierePassed
                    ? Copy.Feed.headlinePremiered(name: name, isMovie: post.isMovie, when: premiereWhen)
                    : Copy.Feed.headlineDated(name: name, isMovie: post.isMovie, when: premiereWhen)
            } else {
                headline = Copy.Feed.headlineDatedNoDate(name: name)
            }
        case .window:
            if let window = post.window {
                let phrase = Copy.Feed.windowPhrase(release: window.release, window: window.releaseWindow)
                headline = Copy.Feed.headlineWindow(name: name, isMovie: post.isMovie, phrase: phrase)
            } else {
                headline = Copy.Feed.headlineAnnounced(name: name, isMovie: post.isMovie)
            }
        case .announced, .unknown:
            headline = Copy.Feed.headlineAnnounced(name: name, isMovie: post.isMovie)
        case .rumour:
            headline = Copy.Feed.headlineRumour(name: name)
        case .trailer:
            headline = trailerHeadline(post.video, show: show)
        case .episode:
            headline = Copy.Feed.headlineEpisode(installment: post.installment, episode: post.episode ?? 1)
        }

        let sentence = Copy.Feed.sentence(kind: post.kind, headline: headline, name: name,
                                          isMovie: post.isMovie, premiereLine: premiereLine)
        let stamp = TemporalCopy.feedStamp(post.time.at, dateOnly: post.time.dateOnly, now: now)

        let media: PostMediaArt
        if post.kind == .rumour {
            media = .none
        } else if let video = post.video, post.kind == .trailer || video.youtubeID != nil {
            // X's news accounts post the trailer WITH the headline: news that carries its own cut
            // (the server attaches the official one published within ten days of it) shows the
            // video, which plays in the post (`FeedAutoplay`), not a still of the key art.
            // The show's own picture closes the list: a trailer whose stills are gone (a video
            // taken down since the catalogue listed it) was a black box with a play button.
            media = .trailer(stills: FeedVideoStill.candidates(video)
                                + [wideArt(part: post.part, show: show).url].compactMap { $0 },
                             video: video)
        } else {
            media = .art(wideArt(part: post.part, show: show))
        }

        // The research's note is the post's second paragraph (the timeline used to draw the
        // sentence alone and lose it) — except on a rumour, which has no media: there the note is
        // the Community Note under the words.
        let note: String? = {
            if case .none = media { return nil }
            guard let trimmed = post.note?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
                return nil
            }
            return trimmed
        }()
        let body = note.map { "\(sentence)\n\n\($0)" } ?? sentence
        let clippedBody = timelineCut(body)

        let readOn = post.sources.first { isHTTPS($0.url) }
        let primaryURL = post.sources.first { $0.primary && isHTTPS($0.url) }?.url
        let shareURL = primaryURL ?? readOn?.url

        return FeedPostModel(
            post: post, show: show, franchise: franchise, isOwned: owned, showName: showName,
            shortName: franchise.title.shelfShortened(fitting: nameLineBudget),
            headline: headline, sentence: sentence, body: body, note: note, clippedBody: clippedBody,
            contextLine: post.context.map { Copy.Feed.context($0, name: seedName) },
            stamp: stamp, premiereLine: premiereLine,
            media: media, fresh: fresh,
            showsOfficialMark: post.isOfficial && post.kind != .rumour,
            readOn: readOn, shareURL: shareURL,
            shareText: "\(showName): \(sentence)",
            accessibilityLabel: Copy.Feed.postAccessibility(show: showName, sentence: sentence, note: note,
                                                            stamp: stamp))
    }

    /// X's timeline limit: a longer post is cut there and ends on "Show more".
    static let timelineLimit = 280
    /// A title longer than this offers its identity half to the name line (`shortName`).
    static let nameLineBudget = 18

    /// X's timeline cut: `text` to the last word inside `limit` characters, with what would dangle
    /// before the ellipsis (a space, a paragraph break, a comma or a dash) taken off; a cut that ends
    /// a sentence keeps its full stop and takes no ellipsis. Nil when `text` fits whole.
    static func timelineCut(_ text: String, limit: Int = timelineLimit) -> String? {
        guard text.count > limit else { return nil }
        let head = text.prefix(limit)
        var cut = String(head[..<(head.lastIndex(where: \.isWhitespace) ?? head.endIndex)])
        while let last = cut.last, last.isWhitespace || ",;:\u{2013}\u{2014}-".contains(last) {
            cut.removeLast()
        }
        if let last = cut.last, ".!?".contains(last) { return cut }
        return cut + "\u{2026}"
    }

    /// A trailer's headline: the provider's title without the show's name, "[Subtitled]" or its
    /// hyphen separators; else what kind of video it is.
    static func trailerHeadline(_ video: FranchiseVideo?, show: FeedFranchise) -> String {
        guard let video else { return Copy.Video.kind(.trailer) }
        guard let cleaned = video.title(cleanedFor: show.title) else { return Copy.Video.kind(video.kind) }
        let tidy = cleaned
            .replacingOccurrences(of: "[Subtitled]", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: " - ", with: " \u{00B7} ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespaces)
        // The uploader's shorthand is not a headline: "PV", "CM 2", "Promotional Video" say what
        // the kind already says, in a trade's words ("Overlord · PV.", For you, 4 Oct).
        let shorthand = tidy.range(of: #"^(PV|CM|PROMO|Promotional Video|Promotion Video)( ?\d+)?$"#,
                                   options: [.regularExpression, .caseInsensitive]) != nil
        return tidy.isEmpty || shorthand ? Copy.Video.kind(video.kind) : tidy
    }

    /// A TRUE 16:9 for the post's frame — the season's, the show's, then the galleries' — never an
    /// AniList ultra-wide banner (its middle third in a 16:9 frame is a pair of eyes); else the
    /// poster, composited whole (spike `wide(part:f:)`).
    ///
    /// A CLEAN scene: a backdrop the catalogue tags with a language is the show's banner — its
    /// logo lettered across the picture — and in a post it read as an advertisement beside the
    /// name line that already says the show (Seirei Gensouki, LIAR GAME; "For you visuals look
    /// poorly built", owner, 4 Oct). The order is a clean scene, then the POSTER (the designed key
    /// art, cropped to its faces), and a lettered backdrop only when there is nothing else. An
    /// untagged gallery (the older shape) says nothing, so its first landscape stands as before.
    static func wideArt(part: FeedPartRef?, show: FeedFranchise) -> WideArt {
        let gallery = (part?.artwork?.landscapes ?? []) + (show.artwork?.landscapes ?? [])
        // The same picture at another size is the same picture: its file, not its URL.
        func file(_ url: String) -> Substring { url.split(separator: "/").last ?? Substring(url) }
        let lettered = Set(gallery.filter { ArtworkSet.nonEmpty($0.language) != nil }.map { file($0.url) })
        let scenes = ([part?.landscapeArt, show.landscapeArt] + gallery.map(\.url))
            .compactMap { $0 }
            .filter { !$0.isEmpty && !$0.contains("/anime/banner/") }
        if let clean = scenes.first(where: { !lettered.contains(file($0)) }) {
            return WideArt(landscape: clean, portrait: nil)
        }
        if let poster = part?.portraitArt ?? show.stub.portraitArt, !poster.isEmpty {
            return WideArt(landscape: nil, portrait: poster)
        }
        return WideArt(landscape: scenes.first, portrait: nil)
    }

    private static func isHTTPS(_ url: URL?) -> Bool {
        guard let url, url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty else { return false }
        return true
    }
}
