import Foundation

// Search's strings, in the copy table where every user-facing string lives. `DiscoverView` and
// `SearchComponents` reference these and carry no literals of their own.

extension Copy {
    enum Search {
        /// The scene card's labelled add control (20 Sep): the command, then the state.
        static let add = "Add"
        /// An add that asks where you are first (an airing show — its page raises the question).
        static let addAsks = "Add\u{2026}"
        static let added = "Added"
        static let title = "Search"

        // MARK: The field's prompt — one sentence per scope

        /// The prompt names the VERB, not the domain, and it follows the scope. The launchpad's
        /// own supporting line is "Search anime and TV by title." — the same sentence with the
        /// same conjunction, minus the full stop.
        static let promptAll = "Search anime and TV"
        static let promptAnime = "Search anime"
        static let promptTV = "Search TV"

        static func prompt(for filter: MediaFilter) -> String {
            switch filter {
            case .anime: return promptAnime
            case .tv: return promptTV
            case .all: return promptAll
            }
        }

        /// The scope's own word, for a state that names it ("Nothing in Anime for …").
        static func scopeWord(_ filter: MediaFilter) -> String {
            switch filter {
            case .anime: return Copy.Filter.anime
            case .tv: return Copy.Filter.tv
            case .all: return Copy.Filter.all
            }
        }

        // MARK: Section headers

        static let recent = "Recent"
        static let recentlySearched = "Recently searched"
        // A bare recent term has no second line (review, 23 Sep): "Search" under every term said
        // what its magnifier already said. The hint is what VoiceOver hears in its place.
        static let termHint = "Searches for it again"
        static let trendingNow = "Trending now"
        static let moreTrending = "More trending"
        static let topMatch = "Top match"
        static let moreResults = "More results"

        // MARK: Counts

        static func results(_ n: Int) -> String { Copy.plural(n, "result", "results") }
        static func seasons(_ n: Int) -> String { Copy.plural(n, "season", "seasons") }

        /// A chart position, two digits, as the shelf caption leads with it.
        static func rank(_ n: Int) -> String { String(format: "%02d", n) }

        // MARK: The correction line

        static func showingResultsFor(_ corrected: String) -> String {
            "Showing results for \u{201C}\(corrected)\u{201D}"
        }
        static func searchInsteadFor(_ original: String) -> String {
            "Search instead for \u{201C}\(original)\u{201D}"
        }

        // MARK: Notices

        /// A stale result set with a failed refresh over it — the "both sources, one request" case
        /// `Copy.Notice`'s per-catalogue lines do not name.
        static let couldNotRefresh = "Results couldn\u{2019}t refresh"

        // MARK: The forward-looking fact
        //
        // Today spells "New episode" as a private literal in three places (`TodayView.queueLead`,
        // `shelfCaption`, `eyebrow`) and `FranchiseUpcoming.tag` spells "Airing now"; neither is
        // shared copy, so Search owns its own two forms here. Recorded as a duplicate to fold.

        static let airingNow = "Airing now"
        /// "Airs Friday" · "Airs today" — the future verb, never "New episode": "new" is the word
        /// for a drop that has struck (review, 23 Sep; `Copy.Progress.episodeAirs`).
        static func airs(day: String) -> String { "Airs \(day)" }

        // MARK: The add control

        static let inLibrary = "In Library"
        static let notInLibrary = "Not in library"
        static let addHint = "Choose how to add this show to your library"
        static let ownedHint = "Change its status or remove it"
        /// The long-press item behind an unowned control — the same verb the tap performs.
        static let addToLibrary = "Add to Library"
        static let adding = "Adding…"

        // MARK: Recents

        static let removeRecent = "Remove"

        // MARK: Scoped-out state

        static let showAll = "Show all"

        // MARK: The notification primer

        static let primerTitle = "Episode alerts"
        static let primerBody = "Know the moment a new episode airs."
        static let primerTurnOn = "Turn on"
        /// "Not now", not "No thanks": iOS raises its own alert once ever, so the honest offer is
        /// a deferral — and Profile → Notifications keeps it available for good.
        static let primerNotNow = "Not now"
    }
}

extension EmptyStateCopy {
    /// The scope, not the query, is why the list is empty — so the action widens the scope.
    /// `noFilterMatches` is Library's ("Clear the filters to see everything in your library") and
    /// was shown here verbatim, on a screen that has nothing to do with the library.
    static func noScopeMatches(scope: String, query: String) -> EmptyStateCopy {
        EmptyStateCopy(symbol: "magnifyingglass",
                       title: "Nothing in \(scope) for \u{201C}\(query)\u{201D}",
                       supporting: "Switch the scope to \(Copy.Filter.all) to see every result.",
                       primaryLabel: Copy.Search.showAll)
    }

    /// The launchpad when the SCOPE, not the world, emptied the chart: trending loaded, but none
    /// of it is in the selected scope. Shown where the scope bar is NOT on screen (the field is
    /// unfocused), so it names the filter and carries the same one-tap way out `noScopeMatches`
    /// has — without it the launchpad fell through to "Find your next show", copy that flatly
    /// contradicts an active TV-only scope and offers nothing to do about it.
    static func noScopeTrending(scope: String) -> EmptyStateCopy {
        EmptyStateCopy(symbol: "line.3.horizontal.decrease",
                       title: "Nothing trending in \(scope)",
                       supporting: "Switch the scope to \(Copy.Filter.all) to see what everyone is watching.",
                       primaryLabel: Copy.Search.showAll)
    }

    /// The launchpad with no connection and no chart. The SAME title as `offlineCached` — one
    /// state has one name — with a supporting line that says what this screen cannot do about it.
    /// "Find your next show" over a chart that will never load is a promise, not a state.
    /// The catalogue answered with a failure while the device is online. Named after SEARCH — the
    /// screen used the library's "Couldn't load your library" here (captured 2 Sep).
    static let searchUnavailable = EmptyStateCopy(
        symbol: "exclamationmark.circle",
        title: "Couldn\u{2019}t search right now",
        supporting: "Something went wrong. Try again in a moment.",
        primaryLabel: Copy.Action.tryAgain)
    static let searchOffline = EmptyStateCopy(
        symbol: "wifi.slash",
        title: "You\u{2019}re offline",
        supporting: "Search needs a connection. Trending shows appear when you reconnect.",
        primaryLabel: Copy.Action.tryAgain)
}
