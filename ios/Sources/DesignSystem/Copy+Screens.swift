import Foundation

extension Copy {
    /// Catalogue news on the show page (`ReleaseNews`) and an announced season's episode section.
    /// A season order is not an episode list: thirteen bare "Episode N" rows (Avatar, 20 Sep) or a
    /// markable "Episode 1" on an unaired season (Wednesday, 20 Sep) were both inventions.
    enum Release {
        static let newSeason = "New season"
        /// The badge for a show with nothing out yet — never "SEASON 1 ANNOUNCED" (review i3).
        static let newSeries = "New series"
        static func available(_ name: String) -> String { "\(name) now available" }
        static func announced(_ season: String) -> String {
            season.isEmpty ? "Season announced" : "\(season) announced"
        }
        /// An announcement split for a BADGE and a line under it. A short name is the badge
        /// ("SEASON 3 ANNOUNCED"); a long one names its KIND on the badge and itself on the line
        /// ("MOVIE ANNOUNCED" over "Infinity Castle Part 2 · No date announced") — the whole
        /// curated name in amber capitals ran the width of the screen, "(MOVIE)" and all
        /// (review, 23 Sep). A trailing "(Movie)"-style note is the kind, never part of the name.
        static func announcement(_ name: String) -> (badge: String, subject: String?) {
            var subject = name.trimmingCharacters(in: .whitespaces)
            var kind: String?
            if let open = subject.range(of: #"\s*\(([^)]+)\)$"#, options: .regularExpression) {
                kind = String(subject[open]).trimmingCharacters(in: CharacterSet(charactersIn: " ()"))
                subject = String(subject[..<open.lowerBound])
            }
            if subject.count <= 16, kind == nil { return (announced(subject), nil) }
            let noun = kind.map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() } ?? newSeason
            return ("\(noun) announced", subject.isEmpty ? nil : subject)
        }
        static let episodesNotAnnounced = "Episode titles and details are still to come."
        static let episodesUnavailable = "Episode details aren’t available yet."
    }
}

// Strings the screens staged locally during the polish rounds, now in the copy table where every
// user-facing string lives. Screens reference these; their local enums are thin forwards.
extension Copy.Action {
    /// The one spelling — Search's (`Copy.Search.addToLibrary`).
    static var addToLibrary: String { Copy.Search.addToLibrary }
    static let revealEpisodeTitle = "Reveal episode title"
    static let hideEpisodeTitle = "Hide episode title"
    static let revealEpisodeTitlesAndStills = "Reveal episode titles and stills"
    /// The whole work, across its seasons. Opens a confirmation, so it carries the ellipsis.
    static let markSeriesWatched = "Mark series as watched\u{2026}"
    /// Schedule's card mark: the state once done (`markWatched` is the command before it).
    static let watched = "Watched"
    /// The app's one mark verb — Schedule's toggle said "Mark watched" (review i3).
    static var markWatched: String { Copy.Action.markAsWatched }
    static let markRewatchComplete = "Mark this rewatch complete"
    static let stopRewatch = "Stop this rewatch\u{2026}"
    static let stopRewatchTitle = "Stop this rewatch?"
    static let stopRewatchConfirm = "Stop rewatch"
    static let signOut = "Sign out"
    static let deleteAccount = "Delete account"
    static let privacyPolicy = "Privacy Policy"
    static let termsOfUse = "Terms of Use"
    static let contactSupport = "Contact support"
    static let syncNow = "Sync"
    static let retryAll = "Retry all"
    static let dismiss = "Dismiss"
}

extension Copy.Confirm {
    /// The caveat only where something is still to air — it read as boilerplate on a finished
    /// run (iteration 2).
    static func watchedBatch(title: String, scope: String, addsToLibrary: Bool, caveat: String? = nil) -> String {
        // The separator is bound to both neighbours: left to break, the popover printed
        // "Kimetsu no Yaiba ·" with the dot dangling at the end of its first line (review i3).
        "\(title)\u{00A0}\u{00B7}\u{00A0}\(scope)."
            + (caveat.map { " \($0)" } ?? "")
            + (addsToLibrary ? " Adds this show to your library." : "")
    }
    /// The caveat names what the batch actually leaves (review i3: "Unaired episodes stay
    /// unwatched" over a show whose only unreleased things were films).
    static let unairedStay = "Unaired episodes stay unwatched."
    static let unreleasedFilmsStay = "Unreleased films stay unwatched."
}

extension Copy {
    /// The Planned → Watching command, the one sentence of the retired Today billboard (25 Sep:
    /// Today is the feed, `Copy.Feed`) that outlived it — the show page's lockup still says it.
    /// Its recap (`Copy.Recap`) and empty-state lines went with the screen.
    enum Today {
        /// A Planned show's one step, on its own page.
        static let startWatching = "Start watching"
        /// The same step for a Planned show already part-way through: "Start" over a show with 57
        /// of 63 episodes watched told the reader the app had forgotten them (review, 23 Sep).
        static let continueWatching = "Continue watching"
        /// The one Planned → Watching command, worded for where the reader is.
        static func startOrContinue(_ f: Franchise) -> String {
            f.parts.contains { $0.progress > 0 } ? continueWatching : startWatching
        }
    }

    enum Rewatch {
        /// The scope that covers the whole work (not "All seasons" over a list of OVAs).
        static let everything = "Everything"
    }

    enum Account {
        static let signOutTitle = "Sign out?"
        static let deleteSubtitle = "Erases your library, progress and history"
        static let deleteTitle = "Delete your account?"
        static let deleteConfirm = "Delete account"
        static let deleteFailedTitle = "Couldn\u{2019}t delete your account"
        static let upToDate = "Up to date"
        static let couldNotReachServer = "Couldn\u{2019}t connect"
        static let offlineSupporting = "Changes sync when you reconnect"
        static let showingSavedCopy = "Showing what was saved on this device"
        static let signedInWithClerk = "Signed in"
        static let signOutFailedTitle = "Couldn\u{2019}t sign out"
        static let signOutFailedMessage = "Check your connection and try again."
        static func discardChangesTitle(_ n: Int) -> String { "Discard \(Copy.changes(n))?" }
        static let discardChangesMessage = "They were never saved to your account. Your library here stays as it is."
        static func discardChangesConfirm(_ n: Int) -> String { "Discard \(Copy.changes(n))" }

        /// The sign-out confirmation's one sentence. `pending` failed changes earn a second clause,
        /// because they carry a second fact: they stay on this device until the next sign-in.
        static func signOutMessage(pending: Int) -> String {
            guard pending > 0 else {
                return "Your library stays in your account \u{2014} sign back in any time."
            }
            // "3 changes hasn't" — the one verb in the app that has to agree with its count.
            let verb = pending == 1 ? "hasn\u{2019}t" : "haven\u{2019}t"
            let pronoun = pending == 1 ? "it stays" : "they stay"
            return "Your library stays in your account. \(Copy.changes(pending)) \(verb) synced yet \u{2014} "
                + "\(pronoun) on this device and upload the next time you sign in."
        }
        /// The blast radius, in the user's own numbers. The strongest copy in the app; not shortened.
        static func deleteMessage(titles: Int) -> String {
            "This permanently deletes your account and everything in it"
                + (titles > 0 ? " \u{2014} \(Copy.titles(titles)), all progress and watch history" : "")
                + ". It can\u{2019}t be undone."
        }
        /// The suspended screen's command: it opens `deleteTitle`'s confirmation, so it carries the
        /// ellipsis (Profile's row is a settings row, whose title is the destination's name).
        static let deleteCommand = "Delete account\u{2026}"
        /// The suspended screen's export: a suspended account may still download everything the
        /// server holds about it (`GET /me/export`, server D12) — the share sheet with Profile's
        /// JSON file.
        static let exportCommand = "Export your data"
        /// The share sheet's preview title for that file.
        static let exportPreviewTitle = "Your Previously data"

        /// Export. The JSON is the account's own copy from the server (`GET /me/export`: the library,
        /// replies, likes, saves and everything else the account holds); the CSV is the library,
        /// made on this device. Never "for re-import" — there is no import (B1).
        static let exportJSONSubtitle = "Everything in your account, machine-readable"
        static let exportFootnote =
            "A copy is made when you choose a destination, and goes only where you share it."
        /// The account's copy could not be fetched (offline, the server down). Nothing was shared.
        static let exportFailed = "Your account\u{2019}s copy couldn\u{2019}t be downloaded. Check your connection and try again."
        /// `429` on `/me/export` (a few exports an hour).
        static let exportRateLimited = "You\u{2019}ve exported a few times already. Try again later."
    }
}

extension Copy.Accessibility {
    static let opensTheShowHint = "Opens the show"
    static let sectionHeader = "Section"
    static func removeFilter(_ text: String) -> String { "\(text). Remove filter" }
}

extension Copy.Progress {
    /// "Season 4 · Episode 5 next" — the postfix "next" form over a full watch context. Library
    /// used to concatenate this by hand; it is the only sibling `episodeNext` is allowed.
    static func next(context: String) -> String { "\(context) next" }
}

extension Copy {
    /// Filter vocabulary shared by Schedule's menu, its chips and Library's Arrange sheet. One
    /// phrasing per filter: the same toggle used to read "Hide watched episodes" in the menu,
    /// "Watched hidden" on the chip and "watched episodes hidden" to VoiceOver.
    enum Filter {
        static let filter = "Filter"
        static let off = "Off"
        static let source = "Source"
        static let all = "All"
        static let anime = "Anime"
        static let tv = "TV"
        static let hideWatched = "Hide watched"
    }

    /// The show page — the show's X profile (25 Sep): X's tabs and pinned post, in the app's words.
    enum ShowPage {
        static let posts = "Posts"
        static let media = "Media"
        static let about = "About"
        /// X's label over a pinned post — here, the next episode.
        static let pinned = "Pinned"
        /// X's empty timeline: a bold line and one grey sentence.
        static let noPosts = "No posts yet"
        static func noPostsMessage(_ show: String) -> String { "News, trailers and new seasons of \(show) show up here." }
        static let noMedia = "No trailers yet"
        static let showMore = "Show more"
        static let showLess = "Show less"
        /// X's counts ("123 Following  4.5M Followers"): the numeral in ink, the word in grey.
        static let watchedCount = "Watched"
        static let episodesCount = "Episodes"
        static func seasons(_ n: Int) -> String { Copy.plural(n, "season", "seasons") }
        /// The pinned post's sentence.
        static func isOut(_ episode: Int) -> String { "\(Copy.episode(episode)) is out." }
        static func isNext(_ episode: Int) -> String { "\(Copy.episode(episode)) is next." }
        static func isNextBehind(_ episode: Int, behind: Int) -> String {
            "\(Copy.episode(episode)) is next \u{2014} you\u{2019}re \(Copy.episodes(behind)) behind."
        }
        static func startWith(_ context: String) -> String { "Start with \(context)." }
        static let caughtUp = "You\u{2019}re caught up."
        /// A finished series, pinned: "You finished all 89 episodes."
        static func finishedAll(_ episodes: Int) -> String {
            episodes <= 1 ? "You finished it." : "You finished all \(Copy.episodes(episodes))."
        }

        static var sampleStrings: [String] {
            [posts, media, about, pinned, noPosts, noPostsMessage("Frieren"), noMedia, showMore, showLess,
             watchedCount, episodesCount, seasons(1), seasons(5), isOut(24), isNext(22), isNextBehind(22, behind: 3),
             startWith("Season 1 \u{00B7} Episode 1"), caughtUp, finishedAll(89), finishedAll(1)]
        }
    }

    enum Schedule {
        static let title = "Schedule"
        /// The bar's return control. It lands on today's section, which is in the feed whether or
        /// not anything airs — on a quiet day the section prints `nothingScheduled` instead of
        /// being skipped, so "Today" always means today.
        static let today = "Today"
        static let tomorrow = "Tomorrow"
        static let scrollToToday = "Scroll to today"
        static let scrollToTodayHint = "Scrolls to today\u{2019}s episodes"
        static let selected = "Selected"
        static let noEpisodes = "No episodes"
        /// The bar control that brings the month grid down over the feed. ONE label in both
        /// states — the state is its `accessibilityValue`, so VoiceOver announces a toggle rather
        /// than two different buttons.
        static let calendar = "Calendar"
        static let calendarShown = "Shown"
        static let calendarHidden = "Hidden"
        static let previousMonth = "Previous month"
        static let nextMonth = "Next month"
        /// A day in the grid past the end of the feed's window. Not "no episodes" — the app does
        /// not know yet, and saying it does is a different claim.
        static let beyondHorizon = "Not scheduled yet"
        /// The collapsed block of aired days above today — "the last seven days" without saying
        /// so twice: its value line counts them.
        static let earlier = "Earlier"
        static let showEarlier = "Show earlier episodes"
        static let hideEarlier = "Hide earlier episodes"
        /// A day in the feed with nothing on it — in practice only today, which is always drawn.
        static let nothingScheduled = "Nothing scheduled"
        static let reminderSet = "reminder set"
        /// The feed's closing line. `date` is the END OF THE WINDOW, not the last day that happens
        /// to carry something: "through 3 Oct" over a feed that holds everything to 7 Oct left the
        /// four quiet days after it reading as unknown rather than empty (review, 23 Sep).
        static func everythingThrough(_ date: String) -> String { "That\u{2019}s everything through \(date)" }
        /// The group under the closing line: each show's next dated airing past the window, one row
        /// per show — for the shows the window goes quiet on (Bleach resuming after a break).
        static let later = "Later"
        /// The card's eyebrow for an episode that has aired and is unwatched: the next thing to watch
        /// is out. Otherwise the eyebrow is the moment in the app's one ladder (`TemporalCopy.airs`).
        static let outNow = "Out now"
        /// The card's eyebrow for an evening airing today (`Formatting.isEvening`): "Tonight at
        /// 7:30 PM", where the ladder says "Today at 7:30 PM".
        static func tonightAt(_ time: String) -> String { "Tonight at \(time)" }
        /// A date-only drop of several episodes on one day: "Episodes 5–8".
        static func episodeRange(_ from: Int, _ to: Int) -> String { "Episodes \(from)\u{2013}\(to)" }
        /// "Season 2 premiere" — a row that opens a part says so. Library calls the same airing
        /// "Returns 3 Oct"; Schedule printed a bare "Episode 1" (review, 23 Sep). `part` is the
        /// part's own compacted label, a film's title, or empty on a single-part show, whose title
        /// is on the row already.
        static func premiere(_ part: String) -> String { part.isEmpty ? "Premiere" : "\(part) premiere" }
        /// "3 to watch" — the unwatched count in the Earlier block's value line.
        static func toWatch(_ n: Int) -> String { "\(n) to watch" }
    }
}

extension Copy {
    /// The trailer shelf's vocabulary: what kind of video a card is.
    enum Video {
        static func kind(_ kind: FranchiseVideo.Kind) -> String {
            switch kind {
            case .trailer: return "Trailer"
            case .teaser: return "Teaser"
            case .announcement: return "Announcement"
            case .featurette: return "Featurette"
            case .clip: return "Clip"
            case .other: return "Video"
            }
        }

        // The player's controls (`TrailerInlineControls`, `TrailerFullScreen`).
        static let play = "Play"
        static let pause = "Pause"
        static let fullScreen = "Full screen"
        static let exitFullScreen = "Exit full screen"
        static let back10 = "Back 10 seconds"
        static let forward10 = "Forward 10 seconds"
        static let close = "Close"
        /// The scrubber, to VoiceOver.
        static let position = "Playback position"
        static func positionValue(_ current: Double, of duration: Double) -> String {
            duration > 0 ? "\(clock(current)) of \(clock(duration))" : clock(current)
        }
        /// A clock reading, "0:42" / "1:05:09" — whole seconds elapsed.
        static func clock(_ seconds: Double) -> String {
            let s = max(0, Int(seconds.rounded(.down)))
            let h = s / 3600, m = (s % 3600) / 60, r = s % 60
            let two = { (n: Int) in n < 10 ? "0\(n)" : "\(n)" }
            return h > 0 ? "\(h):\(two(m)):\(two(r))" : "\(m):\(two(r))"
        }
        /// "0:42 / 2:31" on the controls' foot; the time alone until the length is known.
        static func clockPair(_ current: Double, _ duration: Double) -> String {
            duration > 0 ? "\(clock(current)) / \(clock(duration))" : clock(current)
        }

        static var sampleStrings: [String] {
            [kind(.trailer), kind(.teaser), kind(.announcement), kind(.featurette), kind(.clip), kind(.other),
             play, pause, fullScreen, exitFullScreen, back10, forward10, close, position,
             positionValue(42, of: 151), positionValue(42, of: 0), clock(3909), clockPair(42, 151), clockPair(42, 0)]
        }
    }

    /// Role words for the people the catalogue lists without one.
    enum People {
        static let creator = "Creator"
        static let director = "Director"
    }

    /// The streaming row's words. The providers' marks carry the names; these are for VoiceOver
    /// and for the attribution the provider data requires.
    enum Watch {
        static func access(_ access: WatchProvider.Access) -> String {
            switch access {
            case .subscription: return "Subscription"
            case .free: return "Free"
            case .ads: return "Free with ads"
            }
        }
        static func attribution(_ provider: String) -> String { "Streaming availability by \(provider)" }
    }
}

extension Copy {
    /// "Recommended for you" — Today's discovery shelf and its caught-up billboard. The REASON is
    /// the product: every title says which of your shows it comes from, never a black-box "For you".
    /// "What do you watch?" — the audience (`Audience`, AppModel+Audience.swift).
    enum Watching {
        /// The row in Profile.
        static let row = "What you watch"
        static let question = "What do you watch?"
        static let lede = "Recommendations, Trending and Discover show only this. Your library is never hidden."
        static let changeLater = "You can change this any time in Profile."
        static let kept = "Shows already in your library stay, whatever you choose."
        static let continueWord = "Continue"

        static func name(_ audience: Audience) -> String {
            switch audience {
            case .anime: "Anime"
            case .tv: "TV"
            case .both: "Anime and TV"
            }
        }

        static func detail(_ audience: Audience) -> String {
            switch audience {
            case .anime: "Series, films and OVAs. No TV shows."
            case .tv: "Series from everywhere else. No anime."
            case .both: "Everything, side by side."
            }
        }

        /// The receipt when the choice changes.
        static func receipt(_ audience: Audience) -> String {
            switch audience {
            case .anime: "Showing anime only"
            case .tv: "Showing TV only"
            case .both: "Showing anime and TV"
            }
        }

        /// The chart's title, in the viewer's words: for one audience it is simply theirs.
        static func trending(_ audience: Audience) -> String {
            switch audience {
            case .anime: "Trending anime"
            case .tv: "Trending TV"
            case .both: Copy.Label.trending
            }
        }

        /// Under a search that found nothing, for a viewer who sees one kind only: why, and where
        /// the door is.
        static func searchingOnly(_ audience: Audience) -> String? {
            switch audience {
            case .anime: "You\u{2019}re seeing anime only. Change it in Profile \u{203A} What you watch."
            case .tv: "You\u{2019}re seeing TV only. Change it in Profile \u{203A} What you watch."
            case .both: nil
            }
        }
    }

    enum ForYou {
        static let shelf = "Recommended for you"
        /// The billboard's badge when a recommendation takes the stage (nothing of yours needs it).
        static let badge = "For you"
        static let addToPlanned = "Add to Planned"
        static let addedToPlanned = "In Planned"
        static let startWatching = "Start watching"
        static let removeFromPlanned = "Remove from Planned"
        static let notInterested = "Not interested"
        static let hidden = "Won\u{2019}t be recommended"
        static let markedSeen = "Marked as seen"
        static let airingNow = "Airing now"
        static let showMore = "Show more"
        /// Discover's For you, grouped by the show of yours a title comes from (the 25 Sep spike).
        static func becauseWatching(_ title: String) -> String { "Because you\u{2019}re watching \(title)" }
        static func becauseWatched(_ title: String) -> String { "Because you watched \(title)" }
        static func moreLike(_ title: String) -> String { "More like \(title)" }
        static let moreForYou = "More for you"
        static let topPick = "Top pick for you"
        /// The top pick's second button: the show's page (Netflix's "More Info").
        static let details = "Details"
        /// A finished show's page: what its finish recommends.
        static func becauseYouFinished(_ title: String) -> String { "Because you finished \(title)" }
        static let addHint = "Adds this show to Planned"
        static let offline = "You\u{2019}re offline"

        /// The full reason — the billboard's line, the long press's title, what VoiceOver says:
        /// "Like Jujutsu Kaisen and 5 more of yours", "Like Re:ZERO and Slime", "Because you
        /// finished Game of Thrones", "From the world of Avatar".
        static func reason(_ r: RecommendationItem.Reason) -> String {
            guard let a = r.seeds.first?.title else { return "Picked from your library" }
            if r.kind == .world { return "From the world of \(a)" }
            if r.count >= 3 { return "Like \(a) and \(r.count - 1) more of yours" }
            if r.count == 2, let b = r.seeds.dropFirst().first?.title { return "Like \(a) and \(b)" }
            switch r.kind {
            case .finished: return "Because you finished \(a)"
            case .watching: return "Because you\u{2019}re watching \(a)"
            case .watched: return "Because you watched \(a)"
            case .started: return "Because you started \(a)"
            case .planned: return "Like \(a), on your list"
            case .consensus, .world: return "Like \(a)"
            }
        }

        /// The long press's title and the spoken label: every show of theirs the list names —
        /// "Like Jujutsu Kaisen, Chainsaw Man, Solo Leveling and 2 more of yours" — where the tile
        /// had room for one (review i5, N8).
        static func reasonList(_ r: RecommendationItem.Reason) -> String {
            let names = r.seeds.map(\.title)
            guard names.count >= 2, r.kind != .world else { return reason(r) }
            let rest = r.count - names.count
            if rest > 0 { return "Like \(names.joined(separator: ", ")) and \(rest) more of yours" }
            return "Like \(names.dropLast().joined(separator: ", ")) and \(names[names.count - 1])"
        }

        /// The tag on a tile's art for a title on air now — a state, so it may be amber-dotted.
        static let airing = "Airing"

        /// The tile's reason line, longest first — the tile draws the first that fits on one line
        /// ("Like Jujutsu Kaisen and 2 more", "Like Jujutsu Kaisen", "Like Jujutsu"). The full
        /// sentence is the long press's title and the VoiceOver label.
        ///
        /// When the first show's name cannot fit even by its identity half, ANOTHER of the user's
        /// shows that agrees is named instead ("Like Re:Monster" for Overlord, whose first seed is
        /// "That Time I Got Reincarnated as a Slime") — a true reason whole beats a truncated one.
        /// The last entry is what is drawn (truncated) if nothing fits: the first show, shortest.
        static func tileReasons(_ r: RecommendationItem.Reason) -> [String] {
            guard let seed = r.seeds.first?.title else { return ["From your library"] }
            let full = seed.shelfShortened
            let short = seed.shelfShortened(fitting: 14)
            if r.kind == .world { return ["World of \(full)", "World of \(short)"] }
            var lines: [String] = []
            if r.count > 1 {
                lines.append("Like \(full) and \(r.count - 1) more")
                // The consensus is the ranker's strongest signal; the compact form keeps it on a
                // tile whenever the name allows (review i5, N8).
                lines.append("Like \(full) & \(r.count - 1) more")
            }
            lines.append("Like \(full)")
            if short != full { lines.append("Like \(short)") }
            for other in r.seeds.dropFirst() { lines.append("Like \(other.title.shelfShortened)") }
            if lines.last != "Like \(short)" { lines.append("Like \(short)") }
            return lines
        }
    }
}

extension Copy.Schedule {
    /// A countdown to today's next airing, where its caption's clock was: "in 2h 14m", "in 27m".
    static func countdown(_ wait: String) -> String { "in \(wait)" }
}
