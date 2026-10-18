import Foundation

extension Copy {
    /// Home (26 Sep): what you can watch now — what is out, what is next. The calendar is the
    /// Schedule tab's.
    enum Home {
        static let title = "Home"
        static let upNext = "Up next"
        /// The past week's episodes you have not marked.
        static let recentlyAired = "Recently aired"
        /// The card's moment for a single fresh drop; a backlog says its count instead.
        static let newEpisode = "New episode"

        /// The board is clear: nothing out, nothing queued, nothing this week.
        static let caughtUp = EmptyStateCopy(symbol: "checkmark.circle", title: "You\u{2019}re all caught up",
                                             supporting: "New episodes land here the moment they air.",
                                             primaryLabel: "See the schedule")

        /// The directions (`Experience.doors`): caught up, Home says so in one line and points at the
        /// next airing — which is Schedule's to show, never Home's.
        static let caughtUpLine = "You\u{2019}re all caught up"
        static func nextAiring(_ show: String, _ when: String) -> String { "Next: \(show) \u{00B7} \(when)" }

        static var samples: [String] {
            [title, upNext, recentlyAired, newEpisode,
             caughtUp.title, caughtUp.supporting ?? "", caughtUp.primaryLabel ?? ""]
        }
    }
}
