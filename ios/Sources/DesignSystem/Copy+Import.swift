import Foundation

extension Copy {
    /// History import (4 Oct): bringing a list kept elsewhere — AniList, MyAnimeList, TV Time — into
    /// the library (`Features/Import`). It says what WILL happen before it happens, in counts.
    enum Import {
        /// The picker's line, and Profile's row.
        static let invite = "Already keep a list? Bring it in"
        static let row = "Import your history"

        static let title = "Bring your history"
        static let lede = "Your shows, and where you are in each."
        static let privacy = "Files are read on this phone. Only your watch history is sent."

        static let anilist = "AniList"
        static let anilistDetail = "Your public list, by username"
        static let mal = "MyAnimeList"
        static let malDetail = "The list export from your account"
        static let tvtime = "TV Time"
        static let tvtimeDetail = "The data export you saved"

        // AniList
        static let anilistTitle = "Your AniList name"
        static let anilistPrompt = "Username"
        static let anilistNote = "The list has to be public. Nothing is changed on AniList."
        static let find = "Find my list"

        // Files
        static let malTitle = "Your MyAnimeList export"
        static let malSteps = ["On myanimelist.net, open your profile menu and choose Export.",
                               "Export your anime list. It downloads as a file ending in .xml.gz.",
                               "Choose that file here."]
        static let tvtimeTitle = "Your TV Time export"
        static let tvtimeSteps = ["Find the export you downloaded from TV Time: a .zip file.",
                                  "Choose it here, as it is. There is no need to open it."]
        static let chooseFile = "Choose the file"

        static let reading = "Reading your list"
        static let busy = "Another list is still being read. Give it a moment, then try again."
        static let another = "Import another list"
        static let tvProgressNote = "TV seasons use your highest watched episode. Anime uses the total watched across its story. Episode numbering may differ; check your place afterwards."
        static let preserved = "Shows already in your library keep their status. Your progress can only move forward."

        // Preview
        /// The list in ITS unit. TV Time counts shows. An anime list counts entries — a season, a
        /// film — and this app keeps a series together, so an entry is never called a show: the
        /// number is the one their own profile shows them, with no noun to be wrong.
        static func found(_ n: Int, entries: Bool) -> String {
            entries ? "\(n.formatted(.number)) on your list" : Copy.plural(n, "show", "shows")
        }
        static func episodes(_ n: Int) -> String { "\(Copy.episodes(n)) watched" }
        /// Over the shelves: how many SHOWS, and — when more are to come — that these are the
        /// ones in already.
        static func ready(_ n: Int, more: Bool) -> String {
            more ? "Ready now \u{00B7} \(Copy.plural(n, "show", "shows"))" : Copy.plural(n, "show", "shows")
        }
        static let grouped = "Seasons and films of one series are kept together here, as one show."
        /// The tail, with the time it really takes: the server builds a series every few seconds
        /// (AniList's pace — about 2.5 s a list entry, measured 4 Oct on a 409-entry tail), so the
        /// wait is SAID, rounded up, rather than promised as "a few minutes".
        static func fetching(_ n: Int) -> String {
            let lead = "\(Copy.plural(n, "more is", "more are")) new to the catalogue"
            guard n > 20 else { return "\(lead) and will be added over the next few minutes." }
            return "\(lead). They are added in the background, what you\u{2019}re watching first: \(tailWait(n))."
        }
        /// Three seconds an entry, in five-minute steps.
        static func tailWait(_ n: Int) -> String {
            let minutes = max(5, Int((Double(n) * 3 / 300).rounded(.up)) * 5)
            switch minutes {
            case ..<50: return "about \(minutes) minutes"
            case ..<80: return "about an hour"
            default: return "a couple of hours"
            }
        }
        static func unmatched(_ n: Int, titles: [String]) -> String {
            let names = titles.prefix(3).joined(separator: ", ")
            let more = n > 3 ? " and \((n - min(3, titles.count)).formatted(.number)) more" : ""
            return "\(Copy.plural(n, "title", "titles")) couldn\u{2019}t be matched: \(names)\(more)."
        }
        static func adultSkipped(_ n: Int) -> String {
            "\(Copy.plural(n, "title marked as adult was", "titles marked as adult were")) skipped."
        }
        static let filmsNote = "Films from TV Time aren\u{2019}t imported."
        static func add(_ n: Int, entries: Bool) -> String {
            guard entries else { return "Add \(Copy.plural(n, "show", "shows"))" }
            return n > 1 ? "Add all \(n.formatted(.number))" : Copy.Search.addToLibrary
        }
        static let nothingFound = "Nothing to import"
        static let nothingFoundDetail = "That list has no shows this app could place."

        // Result
        static func added(_ n: Int) -> String { "\(Copy.plural(n, "show", "shows")) added" }
        static func onTheirWay(_ n: Int) -> String {
            "\(Copy.plural(n, "more is", "more are")) on the way and will appear as they arrive."
        }
        /// What did not arrive, and the way to get it: an import is safe to run again.
        static func missed(_ n: Int) -> String {
            "\(Copy.plural(n, "couldn\u{2019}t", "couldn\u{2019}t")) be fetched. Import again later to pick \(n == 1 ? "it" : "them") up."
        }
        static let done = Copy.Action.done

        // Failures, in the viewer's words
        static let notFound = "No AniList user by that name."
        static let privateList = "That list is private. Make it public on AniList, then try again."
        static let unavailable = "The list couldn\u{2019}t be reached. Try again in a moment."
        static let rateLimited = "That\u{2019}s a lot of tries. Wait a few minutes, then try again."
        static let unrecognised = "That isn\u{2019}t a file this can read."
        static let encrypted = "That zip is password-protected. Unzip it, then choose tracking-prod-records-v2.csv from inside."
        static let emptyFile = "That file has no watch history in it."
        static let expired = "That took too long. Start the import again."

        static var sampleStrings: [String] {
            [invite, row, title, lede, privacy, anilist, anilistDetail, mal, malDetail, tvtime, tvtimeDetail,
             anilistTitle, anilistPrompt, anilistNote, find, malTitle, tvtimeTitle, chooseFile, reading, busy, another, tvProgressNote, preserved,
             found(212, entries: false), found(594, entries: true), episodes(3480), ready(82, more: true),
             ready(7, more: false), grouped, fetching(1), fetching(409), fetching(1100), fetching(2400), unmatched(5, titles: ["A", "B", "C"]), adultSkipped(1), adultSkipped(4),
             filmsNote, add(212, entries: false), add(594, entries: true), add(1, entries: true), nothingFound, nothingFoundDetail, added(170), onTheirWay(1), onTheirWay(42), missed(1), missed(12),
             notFound, privateList, unavailable, rateLimited, unrecognised, encrypted, emptyFile, expired]
                + malSteps + tvtimeSteps
        }
    }
}
