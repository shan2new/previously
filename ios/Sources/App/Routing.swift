import SwiftUI

/// A franchise destination inside a tab's navigation stack (board 02: Detail is navigational
/// content, never modal). `zoomID` names the tapped card so the same franchise can be reached from
/// several surfaces; `focus` selects the relevant season when Episodes is opened. Every entry
/// starts at the same profile header; navigation never scrolls past its controls automatically.
struct DetailRoute: Hashable, Identifiable {
    let id: String
    let zoomID: String
    var focus: EpisodeFocus? = nil
}

/// A value on a tab's NavigationPath for the feed's own pages (iD12). Path VALUES, not item
/// destinations: re-selecting Today and the notification route both reset `paths[.today]`, and a
/// value on the path goes with it (an item destination survived both — the Library `popSignal` bug).
enum FeedRoute: Hashable, Sendable {
    /// A post page. `focusCommentId` scrolls to (and lights) one reply.
    case post(id: String, focusCommentId: String? = nil)
    /// An episode discussion as a page (a notification about an `ep:` reply lands here).
    case episode(franchiseId: String, mediaId: Int, episode: Int, focusCommentId: String? = nil)
    case saved
}

/// Discover's own pages, pushed as values on the Discover tab's path.
enum DiscoverRoute: Hashable, Sendable {
    case genre(key: String, name: String)
}

/// Where a tapped notification (or an Activity row) takes the app. Encoded into a local
/// notification's `userInfo["route"]` as one string, so the payload stays a plist value.
enum OpenRoute: Equatable, Sendable {
    case show(franchiseId: String)
    case post(postId: String, commentId: String?)
    /// `ep:` rooms.
    case thread(subject: String, franchiseId: String, commentId: String?)

    /// The field separator. No id in the grammar carries it: franchise and comment ids are uuids,
    /// PostIds and subjects are `[a-z]+:`-prefixed tokens of `[A-Za-z0-9_:-]` (server §0.1).
    private static let separator: Character = "|"

    /// `"show|<id>"` · `"post|<postId>|<commentId or empty>"` · `"thread|<subject>|<fid>|<cid or empty>"`.
    var encoded: String {
        switch self {
        case let .show(franchiseId):
            return ["show", franchiseId].joined(separator: String(Self.separator))
        case let .post(postId, commentId):
            return ["post", postId, commentId ?? ""].joined(separator: String(Self.separator))
        case let .thread(subject, franchiseId, commentId):
            return ["thread", subject, franchiseId, commentId ?? ""].joined(separator: String(Self.separator))
        }
    }

    /// The inverse of `encoded`; nil for anything else (an older payload, a malformed string), so the
    /// caller falls back to opening the show by the request's thread identifier.
    init?(encoded: String) {
        let parts = encoded.split(separator: Self.separator, omittingEmptySubsequences: false).map(String.init)
        guard let kind = parts.first else { return nil }
        func nonEmpty(_ i: Int) -> String? {
            guard parts.indices.contains(i) else { return nil }
            let s = parts[i].trimmingCharacters(in: .whitespacesAndNewlines)
            return s.isEmpty ? nil : s
        }
        switch kind {
        case "show":
            guard parts.count == 2, let id = nonEmpty(1) else { return nil }
            self = .show(franchiseId: id)
        case "post":
            // The comment field may be absent as well as empty.
            guard (2...3).contains(parts.count), let postId = nonEmpty(1) else { return nil }
            self = .post(postId: postId, commentId: nonEmpty(2))
        case "thread":
            guard (3...4).contains(parts.count), let subject = nonEmpty(1), let franchiseId = nonEmpty(2) else {
                return nil
            }
            self = .thread(subject: subject, franchiseId: franchiseId, commentId: nonEmpty(3))
        default:
            return nil
        }
    }
}

private struct OpenFeedRouteKey: EnvironmentKey {
    // Computed, not a stored `static let`: a closure is not `Sendable`, and a stored static of a
    // non-Sendable type is global mutable state under Swift 6.
    static var defaultValue: ((FeedRoute) -> Void)? { nil }
}

extension EnvironmentValues {
    /// Set by FeedView on the sheets it presents (Profile), so a screen inside a sheet can close it
    /// and open a feed page on Today (Saved → a post).
    var openFeedRoute: ((FeedRoute) -> Void)? {
        get { self[OpenFeedRouteKey.self] }
        set { self[OpenFeedRouteKey.self] = newValue }
    }
}
