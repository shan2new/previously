import Foundation

// The Library's strings — the root shelf and All titles. A Library screen renders nothing that is
// not here or in `Copy` proper: the status shelves are `Copy.Status`, the "All titles" heading is
// `Copy.Heading.allTitles`, progress lines are `Copy.Progress`.
extension Copy {
    enum Library {
        /// The rebuilt root (19 Oct): the shelves' eyebrow, Paused and Dropped as one stack, and
        /// what a stack does.
        static let yourShelves = "Your shelves"
        static let onHold = "On hold"
        static let opensShelfHint = "Opens this shelf"
        static let title = "Library"
        // The same shelf Today heads "Next up" (review i4): one object, one name across rooms.
        static let continueWatching = "Next up"
        // The root's tab-strip strings went with the tabs (30 Aug): every bucket is a shelf, and
        // an empty bucket simply has no shelf — no per-status empty state to name.

        /// The anticipation shelf. Board 05's word, and the word its captions use ("Returns Oct 2026").
        static let returning = "Returning"
        /// A sequel exists and nobody has said when. The absence of a date is the content.
        static let announced = "Announced"
        /// An unconfirmed report, said as one: "Season 3 rumored". Never a date, never amber.
        static func rumored(next: String?) -> String {
            guard let next, !next.isEmpty else { return "Rumoured" }
            // The curated `next` sometimes already says it — "New anime film (rumored)" — and
            // two adjacent pages stated one class of fact in two grammars (Attack on Titan,
            // Thrones, 5 Sep). One: strip the parenthetical, then say it once, our way.
            let bare = next.replacingOccurrences(of: #"\s*\((?:rumou?red)\)\s*"#, with: " ",
                                                 options: [.regularExpression, .caseInsensitive])
                .trimmingCharacters(in: .whitespaces)
            if bare.range(of: "rumou?red", options: [.regularExpression, .caseInsensitive]) != nil { return bare }
            return "\(bare) rumoured"
        }
        static let allTitlesHint = "Opens your whole library, with search, sorting and filters"
        static func allTitlesCount(_ count: Int) -> String { "All \(count)" }
        static func allTitlesAccessibility(_ count: Int) -> String {
            "All titles, \(Copy.titles(count))"
        }
        static let searchPrompt = "Search your library"

        // "View all" is gone (30 Aug): section actions say "See all" everywhere
        // (`Copy.Action.seeAll`) — one verb for one gesture, Today's and Library's alike.
        static let focusTitleHint = "Shows this title in the centre"

        static func partProgress(_ label: String, watched: Int, total: Int) -> String {
            let progress = Copy.Progress.watchedOf(watched, total)
            return label.isEmpty ? progress : "\(label) \u{00B7} \(progress)"
        }

        // MARK: Sort & filter

        static let sortBy = "Sort by"
        static let reverseOrder = "Reverse order"
        static let status = "Status"
        /// The Status picker's "no filter" value. A chip never states it: "Any" is not a criterion.
        static let anyStatus = "Any"
        /// The directions' Library root (`Experience.doors`): the status row's first chip — every show.
        static let allStatus = "All"
        /// Says unwatched *what* — the identical word on Schedule's menu means episodes.
        static let hasUnwatched = "Has unwatched episodes"
        static let view = "View"
        static let viewAs = "View as"
        /// "Recently added, reversed" — the chip names the direction, or it is lying.
        static func reversed(_ label: String) -> String { "\(label), reversed" }

        static let sortTitle = "Title"
        static let sortAdded = "Recently added"
        static let sortRecent = "Recently updated"
        static let sortProgress = "Most left to watch"
        /// The direction, said in the reader's terms rather than as "ascending".
        static let reversedTitle = "Z to A"
        static let reversedAdded = "Oldest first"
        static let reversedRecent = "Least recent first"
        static let reversedProgress = "Least left to watch first"

        static let posters = "Posters"
        static let list = "List"

        // MARK: Sections and the index

        /// The month header for titles with no date behind the active sort.
        static let noDate = "No date"
        static let sectionIndex = "Section index"
        static let sectionIndexHint = "Jumps the list to a section"
        static let sectionsRotor = "Sections"

        /// Search found nothing while filters are ALSO narrowing the list: the card offers to
        /// clear them, the same action `noFilterMatches` carries. Without it a query under a
        /// "Watched" chip dead-ended on a card with no way out but the chip row.
        static func noSearchResults(query: String, filtered: Bool) -> EmptyStateCopy {
            let base = EmptyStateCopy.noSearchResults(query: query)
            guard filtered else { return base }
            return EmptyStateCopy(symbol: base.symbol, title: base.title, supporting: base.supporting,
                                  primaryLabel: Copy.Action.clear)
        }
    }
}
