import Foundation

extension Copy {
    /// First run (4 Oct): the four questions a new account answers before its Home exists
    /// (`AppModel+FirstRun.swift`, `Features/FirstRun`). Each screen is one question; nothing here
    /// explains the app — the questions are the explanation.
    enum FirstRun {
        // MARK: The bar

        static let skip = "Skip"
        /// The picker opened on its own (the empty Home's button) closes with an ×.
        static let close = "Close"
        /// VoiceOver's word for the progress bar.
        static func step(_ n: Int, of total: Int) -> String { "Step \(n) of \(total)" }
        static let continueWord = Copy.Watching.continueWord

        // MARK: What you watch

        /// The audience question's lede at first run. Profile's says the library is never hidden —
        /// a sentence about a library a new account does not have.
        static let audienceLede = "Suggestions stick to what you pick. You can change it any time in Profile."

        // MARK: Your shows

        static let showsTitle = "Pick your shows"
        static let showsLede = "What you\u{2019}re watching now, and favourites you\u{2019}ve finished."
        static let popular = "Popular"
        static let airing = "Airing now"
        static let skipForNow = "Skip for now"
        static let couldNotLoad = "Couldn\u{2019}t load shows"
        /// The dock's button, spoken with its count (the count itself is drawn on the flap).
        static func continueWith(_ n: Int) -> String { "Continue with \(Copy.plural(n, "show", "shows"))" }
        static func picked(_ n: Int) -> String { "\(Copy.plural(n, "show", "shows")) picked" }
        /// A tile, spoken: its name and whether it is picked.
        static func tile(_ title: String, picked: Bool) -> String { picked ? "\(title), picked" : title }

        // MARK: Where you are

        static let placeTitle = "Where are you?"
        static func showOf(_ n: Int, _ total: Int) -> String { "Show \(n) of \(total)" }
        /// What is out, under the name: "62 episodes" · "3 seasons · 62 episodes" · "Film".
        static func released(seasons: Int, episodes: Int, films: Int) -> String {
            var parts: [String] = []
            if seasons > 1 { parts.append(Copy.plural(seasons, "season", "seasons")) }
            if episodes > 0 { parts.append(Copy.episodes(episodes)) }
            if films > 0, episodes == 0 { parts.append(Copy.plural(films, "film", "films")) }
            return parts.joined(separator: " \u{00B7} ")
        }
        static let airingNow = "Airing now"

        /// A show still airing: everything out so far.
        static let caughtUp = "Caught up"
        /// A finished one.
        static let seenItAll = "Seen it all"
        static let partWay = "Part-way"
        static let starting = "Just starting"
        static let later = "Save for later"

        static func caughtUpDetail(_ n: Int) -> String { n == 1 ? "The episode that\u{2019}s out" : "All \(Copy.episodes(n))" }
        static let partWayDetail = "Pick an episode"
        static let startingDetail = "From Episode 1"
        static let laterDetail = "Goes to Planned"

        /// The part-way panel.
        static let lastWatched = "Last episode you watched"
        static let done = Copy.Action.done
        static func dialValue(_ n: Int, of total: Int) -> String { "Episode \(n) of \(total)" }

        // MARK: Your lineup

        static let lineupTitle = "Here\u{2019}s what\u{2019}s next"
        static let lineupLede = "Your shows, in the order they reach you."
        /// Nothing dated and nothing to watch yet (every pick saved for later, or finished).
        static let lineupQuietTitle = "You\u{2019}re set"
        static let lineupQuietLede = "Your shows are in your library."
        static let now = "Now"
        static let laterWord = "Later"
        static let doneWord = "Done"
        static func more(_ n: Int) -> String { "And \(n.formatted(.number)) more in your library" }
        static let goHome = "Go to Home"
        /// The alerts line names the show whose next episode it would announce.
        static func alertsBody(_ title: String) -> String { "A nudge the moment \(title) airs." }
        static let alertsOn = Copy.Toast.alertsOn

        // MARK: The empty Home's way back in

        static let pickYourShows = "Pick your shows"

        static var sampleStrings: [String] {
            [skip, close, step(2, of: 4), audienceLede, showsTitle, showsLede, popular, airing, skipForNow,
             couldNotLoad, continueWith(1), continueWith(4), picked(3), tile("Frieren", picked: true),
             placeTitle, showOf(2, 5), released(seasons: 3, episodes: 62, films: 0), released(seasons: 1, episodes: 0, films: 1),
             airingNow, caughtUp, seenItAll, partWay, starting, later, caughtUpDetail(1), caughtUpDetail(12),
             partWayDetail, startingDetail, laterDetail, lastWatched, dialValue(7, of: 24),
             lineupTitle, lineupLede, lineupQuietTitle, lineupQuietLede, now, laterWord, doneWord,
             more(3), goHome, alertsBody("Frieren"), pickYourShows]
        }
    }
}

extension EmptyStateCopy {
    /// HOME's empty account. Its action is the picker (first run's second question), not a bare
    /// search field: someone with nothing on this screen wants a wall of shows to tap.
    static let emptyHome = EmptyStateCopy(
        symbol: "tv",
        title: "Nothing to watch yet",
        supporting: "Pick your shows and this screen fills in with what\u{2019}s next.",
        primaryLabel: Copy.FirstRun.pickYourShows)
}
