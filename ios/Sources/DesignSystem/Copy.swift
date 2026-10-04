import Foundation

// The copy table (spec board 09), as a Swift source of truth.
//
// Every visible state, action, status, toast, notice, progress line and confirmation string in
// the app resolves to a symbol in here. No screen inlines a sentence again: a string that appears
// on screen either comes from `Copy` or is interpolated data (a title, a date, a count).
//
// Voice: sentence case, no exclamation marks, one supporting sentence, curly apostrophes (U+2019),
// "Previously." always with its full stop. Notation is "Season 4 · Episode 19" — never E19, Ep 19
// or S5 E19.
//
// The brand is NEVER a clause subject. "Previously couldn’t reach the server" — stripped of the
// full stop the name requires — reverts to its ordinary meaning and the line parses as the adverb:
// *previously*, it couldn’t reach the server, i.e. it can now. Nor may a screen substitute its own
// subject ("Search couldn’t reach the server"), which gave one failure two names one tab apart.
// A failure states the fact and nothing else: "Couldn’t reach the server".
//
// Nor does a state promise a benefit on a different tab. "Add your first show and Today builds
// itself." ran verbatim on Library AND Schedule, under a title naming neither. Each surface owns
// its own empty sentence, about itself.
//
// Capitalisation rule (resolves the board 09 / board 03 apparent conflict):
//   • `Episode 19` is capitalised when it is a LABEL or identifier
//     ("Season 4 · Episode 19", "Episode 19 next", "Episode 19 marked as watched");
//   • it is lower-case inside a sentence-case COMMAND ("Mark through episode 1128").
// `episode(_:)` and `episodeInSentence(_:)` are the two forms; nothing else builds the string.
enum Copy {

    // MARK: - Notation

    /// "Episode 19" — the label form.
    static func episode(_ n: Int) -> String { "Episode \(n)" }

    /// "episode 19" — the form used inside a sentence-case command or message.
    static func episodeInSentence(_ n: Int) -> String { "episode \(n)" }

    /// "Season 4 · Episode 19". `label` is the source's own part label, never derived from order.
    ///
    /// A numbered season sheds its arc subtitle here: "Season 5: Hashira Training Arc · Episode 1"
    /// wrapped every row it appeared on with a separator stranded at the line end, and the arc name
    /// is Detail's fact, not a row's. Only `Season N:` prefixes compact — a label like
    /// "OVA 2: No Regrets" keeps its subtitle because the subtitle IS the identity there.
    static func watchContext(part label: String, episode n: Int) -> String {
        let compact = compactPartLabel(label)
        return compact.isEmpty ? episode(n) : "\(compact) · \(episode(n))"
    }

    /// "Season 5: Hashira Training Arc" → "Season 5"; a long "Arc - Part" label keeps its last
    /// segment ("Thousand-Year Blood War - The Calamity" → "The Calamity": the logo above it
    /// already prints the arc, and the line ran the width of the screen — review, 23 Sep);
    /// anything else unchanged.
    static func compactPartLabel(_ label: String) -> String {
        if let range = label.range(of: #"^Season \d+(?=:)"#, options: .regularExpression) {
            return String(label[range])
        }
        if label.count > 24, let dash = label.range(of: " - ", options: .backwards) {
            let tail = label[dash.upperBound...].trimmingCharacters(in: .whitespaces)
            if tail.count >= 3 { return tail }
        }
        return label
    }

    /// English-only pluraliser. A `.stringsdict` is out of scope for this prototype (confirmed);
    /// every count that reaches the user goes through here so the singular is never "1 episodes".
    ///
    /// The number is bound to its noun with a non-breaking space: a numeral must never end a line
    /// its unit doesn't start ("… · 11 / episodes left" — measured on Today's queue rows). Wraps
    /// happen between facts, never inside one.
    static func plural(_ n: Int, _ one: String, _ many: String) -> String {
        // Grouped past 999 (review i5: "1316 episodes").
        "\(n.formatted(.number))\u{00A0}\(n == 1 ? one : many)"
    }

    /// "Episodes 19–21": a run of episodes, en-dashed, the plural word once.
    static func episodeRange(_ a: Int, _ b: Int) -> String { "Episodes\u{00A0}\(a)\u{2013}\(b)" }

    static func episodes(_ n: Int) -> String { plural(n, "episode", "episodes") }

    /// What a part IS, as a caption word: "Film", "OVA", "ONA", "Special". `rawValue.capitalized`
    /// printed "Ova" (24 Sep).
    static func partKind(_ kind: PartKind) -> String {
        switch kind {
        case .season: return "Season"
        case .movie: return "Film"
        case .ova: return "OVA"
        case .ona: return "ONA"
        case .special: return "Special"
        case .music: return "Music"
        }
    }
    /// "51 min" — an episode's runtime, in the fact line a row opens to.
    static func minutes(_ n: Int) -> String { "\(n) min" }

    /// A count of episodes the USER has watched, predicated so it cannot be read as the work's
    /// length. "Watched once - 95 episodes" (the show) and "2 watch sessions - 50 episodes" (the
    /// user) sat two taps apart, so within one show the same noun phrase meant 95 and 50.
    /// Catalogue counts stay bare; progress counts come through here.
    static func episodesWatched(_ n: Int) -> String { "\(episodes(n)) watched" }
    static func changes(_ n: Int) -> String { plural(n, "change", "changes") }
    static func watchSessions(_ n: Int) -> String { plural(n, "watch session", "watch sessions") }
    static func updates(_ n: Int) -> String { plural(n, "update", "updates") }
    static func titles(_ n: Int) -> String { plural(n, "title", "titles") }

    // MARK: - Status

    /// The five user-facing statuses — the USER's list state, never the series' production state.
    /// Internal `.completed` reads "Watched" and `.planned` reads "Planned"; "Completed" and
    /// "Plan to watch" never appear.
    ///
    /// **"Finished" is not in this vocabulary.** It was carrying both meanings at once, which is how
    /// the app came to file a show as finished on one screen and promise it returns in six weeks on
    /// the next — and how one state came to be spelled four ways within two taps: "Finished" in the
    /// detail picker, "FINISHED" on the Profile tile, "COMPLETE" on a card eyebrow and "Watched
    /// once" in the same card's title. A tracker that cannot name its own states is not trustworthy.
    /// "Complete" is now reserved for the *series* (`Progress.complete`), "Watched" for the *user*.
    ///
    /// Switched on the raw value rather than the case set so it already covers `paused` and
    /// `dropped`, which the shared `WatchStatus` gains in the shared-model patch.
    static func Status(_ status: WatchStatus) -> String { statusLabel(status.rawValue) }

    static func statusLabel(_ raw: String) -> String {
        switch raw {
        case "watching":  return "Watching"
        case "planned":   return "Planned"
        case "completed": return "Watched"
        case "paused":    return "Paused"
        case "dropped":   return "Dropped"
        default:          return raw.prefix(1).uppercased() + raw.dropFirst()
        }
    }

    /// Display order for a status menu, independent of the enum's case order.
    static let statusesInOrder = ["Watching", "Planned", "Watched", "Paused", "Dropped"]

    // MARK: - Section eyebrows - the "next" vocabulary

    /// Five "next" forms meaning three different things shipped at once: "UP NEXT" (watchable now)
    /// and "COMING NEXT" (not yet aired) differed by one word in the same token 60 pt apart;
    /// Detail's card eyebrow said "NEXT UP"; Schedule printed "Next up Sun 23 Aug"; a season row
    /// printed "Episode 5 next". No rule a reader could infer. The rule, and the only forms:
    ///
    ///   `nextUp`     - the specific episode you can watch RIGHT NOW. One per screen, at most.
    ///   `upcoming`   - episodes that exist but have not aired. Never a second "next" on a screen.
    ///   `episodeNext(n)` (in `Progress`) - the only POSTFIX form: "Episode 5 next".
    ///
    /// Nothing else may be worded with "next".
    enum Label {
        static let nextUp = "Next up"
        /// The waiting hero's eyebrow. The MOMENT is the fact line under the title, big and in
        /// accent, so the eyebrow says only what kind of moment it is.
        static let newEpisode = "New episode"
        /// A season released whole this week (a streaming drop).
        static let newSeason = "New season"
        /// The row tag on the newest AIRED episode while it is still unwatched — the streaming
        /// apps' "NEW" on a tile, in the app's one amber-for-state rule.
        static let newTag = "NEW"
        /// The empty account's billboard pill: the chart's top show, on the hero's own slate.
        static let trending = "Trending"
        static let upcoming = "Upcoming"
        /// Catalogue news for a show on air right now — "AIRING" over "Episode 14 airs Sunday at
        /// 4:30 PM". "UPCOMING" said that and three other things (review, 23 Sep).
        static let airing = "Airing"
        static let watching = "Watching"
        /// The shelf of shows you are part-way through that have NOTHING airing. Distinct from
        /// `watching` (a status) and from `nextUp` (an episode that is out now).
        static let continueWatching = "Continue watching"
        /// The SERIES' production state - never the user's list state, which is "Watched".
        static let complete = "Complete"
        /// The identity line's word for a title the catalogue flags adult with no market rating.
        static let adultRating = "18+"
    }

    // MARK: - Headings - case and conjunction, settled once

    /// **Sentence case for every heading and control label in this app.** Title Case is for the
    /// names of works. "Sort & Filter" and "Seasons & movies" were one screen apart, so the app was
    /// visibly using two conventions at once and neither carried meaning.
    ///
    /// **"&" only between two nouns in a label that must hold one line** ("Sort & filter"); the
    /// word "and" in any sentence the user reads. `SectionLabel` uppercases at the point of
    /// rendering, so these are stored in the case they are WRITTEN in, not the case they are drawn
    /// in - which is what lets one string serve a header and a menu item.
    enum Heading {
        static let sortAndFilter = "Sort & filter"
        static let seasonsAndMovies = "Seasons & movies"
        /// The shelf of a franchise's non-season parts under the episode list — films, OVAs that
        /// are units, the catalogue's specials.
        static let moviesAndExtras = "Movies & extras"
        /// The Episodes section's title when the work has one season and no name for it.
        static let episodes = "Episodes"
        static let searchPrompt = "Anime & TV"
        static let watchHistory = "Watch history"
        static let allTitles = "All titles"
        /// The show page's catalogue shelves, in Apple TV's order: trailers, the people, related.
        static let trailers = "Trailers"
        static let castAndCrew = "Cast & crew"
        static let moreLikeThis = "More like this"
        /// The streaming row. The providers' marks say who; the header is the way to the options.
        static let whereToWatch = "Where to watch"
    }

    // MARK: - Actions

    /// One form per intent (board 09). A command that exists here must not be reworded at a call
    /// site, shortened to fit a control, or given a second form for a narrow layout.
    enum Action {
        /// A page's own back arrow (X's post page), spoken.
        static let back = "Back"
        static let readMore = "Read more"
        static let readLess = "Read less"
        static let markAsWatched = "Mark as watched"
        static let markAsUnwatched = "Mark as unwatched"
        /// "Mark episode 19 watched" — the CTA form that names its object. The bare
        /// `markAsWatched` above stays for surfaces that have no single episode to name; a control
        /// that KNOWS which episode it writes says so, because "Mark as watched" beside a hero that
        /// also shows a behind-count and a latest-aired date left the reader to work out which of
        /// three numbers the button would touch.
        static func markEpisodeWatched(_ n: Int) -> String { "Mark \(Copy.episodeInSentence(n)) as watched" }
        /// The same control once its episode is marked (Schedule's card, whose pill then reads "Watched").
        static func markEpisodeUnwatched(_ n: Int) -> String { "Mark \(Copy.episodeInSentence(n)) as unwatched" }
        /// "Mark episodes 2–5 as watched…" — a batch command STATES ITS RANGE. "Mark through episode
        /// 5" named only its endpoint, so under a hero saying "Episode 1 next · 9 behind" the 5 read
        /// as an unexplained third number rather than as first-unwatched + 4. A range confirms, so
        /// it carries the ellipsis; a single episode is `markEpisodeWatched` and does not.
        static func markThrough(from: Int, to: Int) -> String {
            // Word-joiners weld the range into one token — a narrow menu line broke it as
            // "episodes 1–" / "5", which reads as a typo, not a range.
            from >= to ? markEpisodeWatched(to)
                       : "Mark episodes \(from)\u{2060}\u{2013}\u{2060}\(to) as watched\u{2026}"
        }
        /// "Mark all 5 episodes as watched…"; ONE is not "all" ("Mark all 1 episode…", review i5).
        static func markAll(_ n: Int) -> String {
            n == 1 ? "Mark 1 episode as watched\u{2026}" : "Mark all \(Copy.episodes(n)) as watched\u{2026}"
        }
        /// The link from the show page's episode window to the whole season: "All 24 episodes".
        static func allEpisodes(_ n: Int) -> String { "All \(Copy.episodes(n))" }
        /// A long run's in-place doors on the show page (Mail's "Load Earlier Messages"): the list
        /// grows where it is, twelve rows a tap, and nothing is pushed (6 Sep).
        static let showEarlierEpisodes = "Show earlier episodes"
        static let showMoreEpisodes = "Show more episodes"
        static func markAllUnwatched(_ n: Int) -> String { "Mark all \(Copy.episodes(n)) as unwatched\u{2026}" }
        static let markCaughtUp = "Mark as caught up"
        /// A Planned show whose every released episode is marked (3 Body Problem, Season 2 "late
        /// 2026"): the status the marks already describe.
        static let moveToWatched = "Move to Watched"

        static let startRewatch = "Start rewatch"
        static let continueRewatch = "Continue rewatch"
        static let restartRewatch = "Restart rewatch\u{2026}"
        static let fromAnEpisode = "From an episode\u{2026}"

        static let add = "Add"
        static let addAShow = "Add a show"
        static let removeFromLibrary = "Remove from Library"
        static let deleteWatchHistory = "Delete watch history\u{2026}"
        static let deleteThisSession = "Delete this session\u{2026}"
        static let editSessions = "Edit sessions"

        static let viewEpisodes = "View episodes"
        static let viewWatchHistory = "View watch history"
        static func viewAllUpdates(_ n: Int) -> String { "View all \(Copy.updates(n))" }
        static let browseYourLibrary = "Browse your library"
        static let seeAll = "See all"

        static let showTitle = "Show title"
        static let hideTitle = "Hide title"

        static let tryAgain = "Try again"
        static let retry = "Retry"
        static let clear = "Clear"
        static let cancel = "Cancel"
        static let done = "Done"
        /// The trailer sheet's way out to the provider, drawn as a glyph; this is what VoiceOver says.
        static let openOnYouTube = "Open on YouTube"
        static let openInBrowser = "Open in browser"
        static let arrange = "Arrange"
        static let reset = "Reset"
        static let discard = "Discard\u{2026}"
        static let undo = "Undo"

        // MARK: The ellipsis rule, as data

        /// Board 09's rule, and Apple's: **a command that opens a confirmation ends in "…", and
        /// only such a command does.** Board 09's own action table omitted the ellipsis from the
        /// forward batch marks — which do confirm — and the table used to side with it, so the
        /// show page's menu put "Mark all episodes as watched" and "Mark all 15 episodes as
        /// unwatched…" one above the other, both opening a confirmation, one promising it (review,
        /// 23 Sep). `opensConfirmation` is still recorded independently of the trailing character,
        /// so the audit can check the two against each other in BOTH directions.
        struct Command: Hashable, Sendable {
            let label: String
            let opensConfirmation: Bool
            var endsInEllipsis: Bool { label.hasSuffix("\u{2026}") }
        }

        /// Every command in the table, with a representative argument for the parameterised ones.
        static let commands: [Command] = [
            Command(label: markAsWatched, opensConfirmation: false),
            Command(label: markAsUnwatched, opensConfirmation: false),
            Command(label: markEpisodeWatched(19), opensConfirmation: false),
            Command(label: markThrough(from: 6, to: 10), opensConfirmation: true),
            Command(label: markAll(18), opensConfirmation: true),
            Command(label: markAllUnwatched(24), opensConfirmation: true),
            Command(label: markSeriesWatched, opensConfirmation: true),
            Command(label: markCaughtUp, opensConfirmation: false),
            Command(label: startRewatch, opensConfirmation: false),
            Command(label: continueRewatch, opensConfirmation: false),
            Command(label: restartRewatch, opensConfirmation: true),
            Command(label: fromAnEpisode, opensConfirmation: true),
            Command(label: add, opensConfirmation: false),
            Command(label: removeFromLibrary, opensConfirmation: false),
            Command(label: deleteWatchHistory, opensConfirmation: true),
            Command(label: deleteThisSession, opensConfirmation: true),
            Command(label: viewEpisodes, opensConfirmation: false),
            Command(label: viewWatchHistory, opensConfirmation: false),
            Command(label: showTitle, opensConfirmation: false),
            Command(label: hideTitle, opensConfirmation: false),
            Command(label: tryAgain, opensConfirmation: false),
            Command(label: retry, opensConfirmation: false),
            Command(label: clear, opensConfirmation: false),
            Command(label: discard, opensConfirmation: true),
            // The feed and the social layer (spec §1.9.5). Report, block and delete open a sheet or
            // an alert; the post menu's items and the alert affordances act at once.
            Command(label: Social.reportCommand, opensConfirmation: true),
            Command(label: Social.blockCommand("dex"), opensConfirmation: true),
            Command(label: Social.deleteCommand, opensConfirmation: true),
            Command(label: Feed.notInterested, opensConfirmation: false),
            Command(label: Feed.mute("One Piece"), opensConfirmation: false),
            Command(label: Feed.unmute("One Piece"), opensConfirmation: false),
            Command(label: Feed.copyText, opensConfirmation: false),
            Command(label: Feed.alertsTurnOn, opensConfirmation: false),
            Command(label: Stories.turnOnAlerts, opensConfirmation: false),
            Command(label: Social.unblock, opensConfirmation: false),
            Command(label: Social.removeFromSaved, opensConfirmation: false),
        ]

        /// True when the command with this exact label opens a confirmation. Unknown labels are
        /// answered `false` — an unknown label is a copy defect, not a silent confirmation.
        static func opensConfirmation(_ label: String) -> Bool {
            commands.first { $0.label == label }?.opensConfirmation ?? false
        }

        /// An ellipsis promises a confirmation. Empty means the table is sound.
        static var ellipsisViolations: [String] {
            commands.filter { $0.endsInEllipsis && !$0.opensConfirmation }.map(\.label)
        }

        /// …and a confirmation is promised by an ellipsis (the converse, 23 Sep). Empty means the
        /// table is sound.
        static var missingEllipsis: [String] {
            commands.filter { $0.opensConfirmation && !$0.endsInEllipsis }.map(\.label)
        }

        /// A confirmation BUTTON never ends in an ellipsis. Empty means the table is sound.
        static var confirmationButtonViolations: [String] {
            Confirm.buttons.filter { $0.hasSuffix("\u{2026}") }
        }
    }

    // MARK: - Toasts

    enum Toast {
        static func marked(episode n: Int) -> String { "\(Copy.episode(n)) marked as watched" }
        static func batchMarked(_ n: Int) -> String { "\(Copy.episodes(n)) marked as watched" }
        /// The lane's fact for a batch — "4 episodes watched", parallel to `Progress.episodeWatched`:
        /// "4 episodes marked as watched" truncated beside the poster and Undo (6 Sep).
        static func batchWatched(_ n: Int) -> String { "\(Copy.episodes(n)) watched" }
        /// A series batch that took the story's films with it: "63 episodes and 2 films watched".
        static func batchWatched(_ n: Int, films: Int) -> String {
            films == 0 ? batchWatched(n) : "\(Copy.episodes(n)) and \(Copy.plural(films, "film", "films")) watched"
        }

        /// The same fact, carrying its SUBJECT. The bare form names neither show nor season, yet
        /// the identical toast fires from a Schedule row and a Library context menu, where the
        /// user has just acted on one of several shows and "Episode 2 marked as watched" cannot
        /// say which. The title is the part allowed to truncate; the fact never is.
        static func marked(title: String, episode n: Int) -> String {
            title.isEmpty ? marked(episode: n) : "\(title) \u{b7} \(Copy.episode(n)) watched"
        }

        static func batchMarked(title: String, _ n: Int) -> String {
            title.isEmpty ? batchMarked(n) : "\(title) \u{b7} \(Copy.episodes(n)) watched"
        }
        /// Remove never touches history, and the toast says so in words.
        static let removed = "Removed from Library \u{00B7} Watch history kept"
        /// The lane's line — the history clause is spoken, not drawn, beside the show's name.
        static let removedShort = "Removed from Library"
        /// The last episode of a finished series was marked: the show is filed under Watched.
        static let finished = "Series finished \u{00B7} Moved to Watched"
        /// A season reset from the show page's menu — the receipt names the season it cleared.
        static func seasonUnmarked(_ label: String) -> String { "\(label) marked as unwatched" }
        static func batchUnmarked(_ n: Int) -> String { "\(Copy.episodes(n)) marked as unwatched" }
        static func added(title: String, status: String) -> String { "Added \(title) to \(status)" }
        /// The lane's clause when a mark also added the show — the poster and the line beneath
        /// already name it.
        static func addedTo(_ status: String) -> String { "Added to \(status)" }
        /// Shown only where the row leaves the screen as a result of the change (Library).
        static func movedTo(_ status: String) -> String { "Moved to \(status)" }
        /// A Watched show whose next season has begun, moved back by the app (`resumeReturningSeries`).
        static let backOnWatching = "New season started \u{00B7} Moved to Watching"
        static func backOnWatchingCount(_ n: Int) -> String { "\(n) shows back on Watching \u{00B7} New seasons started" }
        static let rewatchStarted = "Rewatch started"
        /// Stopping a rewatch that knew where the show stood: the progress is back.
        static let rewatchStoppedRestored = "Rewatch stopped \u{00B7} Progress restored"
        static let alertsOn = "Episode alerts on"
        static let rewatchRestarted = "Rewatch restarted"
        static let offlinePending = "Saved on this device. Waiting to sync."
        /// The SyncBanner's line. A failure is never a transient toast.
        static func syncFailed(_ n: Int) -> String { "\(Copy.changes(n)) couldn\u{2019}t sync" }
    }

    // MARK: - Alerts (system notifications)

    /// The one sentence the app ever pushes. No full stop — Apple's own alerts carry none.
    enum Alert {
        static func episodeOut(_ n: Int?) -> String {
            n.map { "\(Copy.episode($0)) is out now" } ?? "A new episode is out now"
        }
        /// A season (or the show) premiering today: "Season 2 premieres today".
        static func premiere(_ season: String) -> String {
            season.isEmpty ? "Premieres today" : "\(season) premieres today"
        }
    }

    // MARK: - Inline notices

    /// Noun-first: the thing that failed, then what happened to it.
    enum Notice {
        /// Profile → Notifications while alerts are off in Settings: asked here first.
        static let alertsOffTitle = "Episode alerts are off"
        static let alertsOffMessage = "Turn on notifications for Previously. in Settings to hear when a new episode is out."
        static let openSettings = "Open Settings"
        static let today = "Airing dates couldn\u{2019}t refresh"
        static let schedule = "Your schedule couldn\u{2019}t refresh"
        static let library = "Your library couldn\u{2019}t refresh"
        static let detailEpisodes = "Episodes couldn\u{2019}t refresh"
        static let searchAnime = "Anime results couldn\u{2019}t refresh"
        static let searchTV = "TV results couldn\u{2019}t refresh"

        static let noConnection = "No connection"
        static let serverError = "Something went wrong"
        static let signedOut = "Signed out"
        static let timedOut = "Took too long"
        static let rateLimited = "Try again in a minute"
        /// The server refused the account (`403 account_suspended`, iD14). `APIError.suspended`'s
        /// `failureReason`, and Sync status's reason beside a write it refused.
        static let suspended = "Account suspended"
        /// A related title the catalogue has not materialised yet, and a search could not find.
        static let notInCatalogue = "Not in the catalogue yet"

        /// The reason a write failed, in the user's words. Never a status code, never a stack of
        /// `localizedDescription` — Sync status shows this beside each failed command.
        static func reason(_ error: Error) -> String {
            if let api = error as? APIError {
                switch api {
                case .unauthorized: return signedOut
                case .rateLimited: return rateLimited
                case .suspended: return suspended
                case .http(let code, _): return code == 429 ? rateLimited : serverError
                case .transport(let underlying): return transportReason(underlying)
                default: return serverError
                }
            }
            return transportReason(error)
        }

        private static func transportReason(_ error: Error) -> String {
            let code = (error as NSError).code
            guard (error as NSError).domain == NSURLErrorDomain else { return serverError }
            switch code {
            case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost,
                 NSURLErrorDataNotAllowed, NSURLErrorCannotConnectToHost,
                 NSURLErrorCannotFindHost, NSURLErrorInternationalRoamingOff:
                return noConnection
            case NSURLErrorTimedOut:
                return timedOut
            default:
                return serverError
            }
        }
    }

    // MARK: - Progress text (passive — never an action)

    enum Progress {
        static func watchedOf(_ watched: Int, _ total: Int) -> String { "\(watched) of \(total) watched" }
        static func episodeNext(_ n: Int) -> String { "\(Copy.episode(n)) next" }
        /// The committed state of the mark control. Lives here rather than in a screen's private
        /// copy enum because `MarkSplitButton` renders it on four surfaces.
        static func episodeWatched(_ n: Int) -> String { "\(Copy.episode(n)) watched" }
        /// "Episode 21 aired yesterday" — the drop, named, from `TemporalCopy.aired`'s phrase.
        /// One builder for Today's and the show page's support line (review i3).
        static func dropAired(episode n: Int, when: String) -> String {
            var fragment = when.hasPrefix("Aired ") ? String(when.dropFirst(6)) : when
            let head = fragment.prefix(while: { !$0.isWhitespace })
            if ["Today", "Tomorrow", "Yesterday"].contains(String(head)) {
                fragment = head.lowercased() + fragment.dropFirst(head.count)
            }
            return "\(Copy.episode(n)) aired \(fragment)"
        }
        static func episodeAiring(_ n: Int) -> String { "\(Copy.episode(n)) airing" }
        static func behind(_ n: Int) -> String { "\(Copy.episodes(n))\u{00A0}behind" }
        /// The count on a release's one line, under its NEW EPISODE badge ("3 behind").
        static func behindShort(_ n: Int) -> String { "\(n)\u{00A0}behind" }
        static func left(_ n: Int) -> String { "\(Copy.episodes(n))\u{00A0}left" }
        /// A season released whole this week.
        static func allOut(_ n: Int) -> String { n == 1 ? "Out now" : "All \(n) episodes out" }
        /// A Watched show's unmarked episodes, said as a fact about the marks, not a debt.
        static func unmarked(_ n: Int) -> String { "\(Copy.episodes(n)) not marked" }
        static let caughtUp = "Caught up"
        /// The calm open's headline when the next episode lands TODAY: the day is not "nothing",
        /// and "Caught up" printed over an Upcoming row saying "Today at 8:30 PM" was the state
        /// shouting over the day's real fact (the same inversion Detail's block fixed). The
        /// specifics — which show, what time — stay with the row; the headline only frames the day.
        static let newEpisodeToday = "New episode today"
        /// The airing cadence, NAMED: "Episode 19 airs Friday at 7:30 PM" · "Episode 19 airs
        /// today at 6:30 PM" · "Episode 19 airs in 27 min" — the future twin of `dropAired`
        /// ("Episode 18 aired 50 min ago"), which sits on the same block. Not "New episode …":
        /// "new" is the word for a drop that HAS struck (the NEW EPISODE badge, the episode
        /// list's NEW tag), and the show page printed "New episode 30 Sep" under a badge about
        /// an episode that aired an hour ago (review, 23 Sep). Not "next": on a show nine episodes
        /// behind, "next episode" is the one YOU watch next. With no episode number the line is
        /// the verb alone — "Airs Friday at 7:30 PM".
        static func episodeAirs(_ n: Int?, when: String) -> String {
            let phrase = when.hasPrefix("Airs ") ? String(when.dropFirst(5)) : when
            let lowered = ["Today", "Tomorrow", "In "].contains { phrase.hasPrefix($0) }
            let tail = lowered ? phrase.lowercasedFirst() : phrase
            return n.map { "\(Copy.episode($0)) airs \(tail)" } ?? "Airs \(tail)"
        }
        static let caughtUpAfterThisEpisode = "Caught up after this episode"
        /// Variant B of the calm day: nothing changed AND nothing is dated. Shared with
        /// `EmptyStateCopy.calmToday` so the sentence exists once.
        static let noNewDates = "No new dates have been announced."
        static let lastEpisodeOfTheSeason = "Last episode of the season"
        static func complete(_ label: String) -> String {
            label.isEmpty ? "Complete" : "\(label) complete"
        }

        /// "Watched once" · "Watched twice" · "Watched 4 times".
        static func watchedTimes(_ n: Int) -> String {
            switch n {
            case ..<1: return "Not watched yet"
            case 1: return "Watched once"
            case 2: return "Watched twice"
            default: return "Watched \(n) times"
            }
        }

        /// "First watch" · "Second watch" · "Third watch" · "7th watch".
        static func ordinalWatch(_ n: Int) -> String {
            let words = ["", "First", "Second", "Third", "Fourth", "Fifth", "Sixth", "Seventh",
                         "Eighth", "Ninth", "Tenth"]
            if n >= 1, n < words.count { return "\(words[n]) watch" }
            return "\(n)\(ordinalSuffix(n)) watch"
        }

        private static func ordinalSuffix(_ n: Int) -> String {
            let tens = n % 100
            if (11...13).contains(tens) { return "th" }
            switch n % 10 {
            case 1: return "st"
            case 2: return "nd"
            case 3: return "rd"
            default: return "th"
            }
        }

        /// The active session's subtitle: "In progress · Episode 7 next".
        static func inProgress(nextEpisode n: Int) -> String {
            "In progress \u{00B7} \(Copy.episodeNext(n))"
        }

        static let datesUnknown = "Dates unknown"

        /// A completed session's subtitle: "Jul 4 – Jul 19 · 26 episodes", year-qualified when the
        /// session did not finish this year. `nil` dates read "Dates unknown" rather than inventing.
        static func sessionSpan(started: Int64?, completed: Int64?, episodes: Int, now: Int64) -> String {
            let count = Copy.episodes(episodes)
            guard let completed else { return "\(datesUnknown) \u{00B7} \(count)" }
            let end = TemporalCopy.dateWord(completed, now: now, anchor: .local)
            guard let started, started < completed else { return "\(end) \u{00B7} \(count)" }
            let sameYear = Formatting.localParts(started).y == Formatting.localParts(completed).y
            let start = sameYear
                ? Formatting.fmtMonthDay(started)
                : TemporalCopy.dateWord(started, now: now, anchor: .local)
            return "\(start) \u{2013} \(end) \u{00B7} \(count)"
        }
    }

    /// "Episode 19 next" at the top level too — the single most reused progress line.
    static func episodeNext(_ n: Int) -> String { Progress.episodeNext(n) }

    // MARK: - Confirmations (every one states its exact blast radius)

    enum Confirm {
        static let notNow = "Not now"
        /// Stopping a rewatch that remembers where the show stood before it.
        static func stopRewatchRestores(at episode: Int) -> String {
            "The session stays in your history, stopped at \(Copy.episodeInSentence(episode)). Your progress goes back to where it was before the rewatch."
        }
        static let cancel = "Cancel"

        // Adding a long run: where are you in it?
        static func whereAreYou(_ title: String) -> String { "Where are you in \(title)?" }
        static func whereAreYouMessage(_ n: Int) -> String {
            "\(Copy.episodes(n).prefix(1).uppercased() + Copy.episodes(n).dropFirst()) have aired. Mark them all as watched, start from the beginning, or pick up where you are."
        }
        static let partWay = "I\u{2019}m part-way through"
        static func caughtUpAdd(_ n: Int) -> String { "I\u{2019}m caught up \u{00B7} Mark \(Copy.episodes(n))" }
        /// The same answer when the batch also marks the story's films (review i4: "Mark 63
        /// episodes" beside a series prompt that said "63 episodes and 2 films" for one write).
        static func caughtUpAdd(_ n: Int, films: Int) -> String {
            films == 0 ? caughtUpAdd(n)
                : "I\u{2019}m caught up \u{00B7} Mark \(Copy.episodes(n)) and \(Copy.plural(films, "film", "films"))"
        }
        static let startFromBeginning = "Start from Episode 1"
        /// "I'm part-way through" names the season (review i3): the seasons before it are marked,
        /// so a show picked up in Season 3 does not count Seasons 1–2 as left.
        static let whichSeason = "Which season are you on?"
        static let whichSeasonMessage = "Earlier seasons are marked as watched."

        // Contiguous / whole-backlog batch mark.
        static func batchMarkTitle(_ n: Int) -> String { "Mark \(Copy.episodes(n)) as watched?" }
        static func batchMarkTitle(_ n: Int, films: Int) -> String {
            films == 0 ? batchMarkTitle(n) : "Mark \(Copy.episodes(n)) and \(Copy.plural(films, "film", "films")) as watched?"
        }
        static func batchMarkMessage(from a: Int, to b: Int) -> String {
            "Your progress will move from \(Copy.episodeInSentence(a)) to \(Copy.episodeInSentence(b))."
        }
        static func batchMarkConfirm(_ n: Int) -> String { "Mark \(Copy.episodes(n)) as watched" }
        static func batchMarkConfirm(_ n: Int, films: Int) -> String {
            films == 0 ? batchMarkConfirm(n) : "Mark \(Copy.episodes(n)) and \(Copy.plural(films, "film", "films"))"
        }
        /// The same batch where the screen is not the show's own page (Today's hero): the
        /// subject leads, then the same sentence.
        static func batchMarkMessage(title: String, season: String, from a: Int, to b: Int) -> String {
            let subject = season.isEmpty ? title : "\(title) \u{00B7} \(season)"
            return "\(subject). \(batchMarkMessage(from: a, to: b))"
        }

        // Reset a season's progress. Nothing is deleted — only progress moves.
        static func resetSeasonTitle(_ total: Int) -> String { "Mark \(Copy.episodes(total)) as unwatched?" }
        static func resetSeason(label: String, total: Int) -> String {
            "This sets \(label) back to \(Copy.Progress.watchedOf(0, total)). Your watch history is kept."
        }
        static func resetSeasonConfirm(_ total: Int) -> String { "Mark \(Copy.episodes(total)) as unwatched" }

        // Restart the active rewatch.
        static let restartRewatchTitle = "Restart rewatch?"
        static func restartRewatch(count n: Int) -> String {
            "Restarting discards \(Copy.episodes(n)) of progress in this run. Earlier watches are kept."
        }
        static let restartRewatchConfirm = "Restart rewatch"

        // Delete one session.
        static let deleteSessionTitle = "Delete this session?"
        static func deleteSession(count n: Int) -> String {
            "This permanently removes \(Copy.episodes(n)) from your history. Your other sessions are unchanged."
        }
        static let deleteSessionConfirm = "Delete this session"

        // Delete the whole history.
        static let deleteHistoryTitle = "Delete watch history?"
        static func deleteHistory(sessions: Int, episodes: Int) -> String {
            "This permanently removes \(Copy.watchSessions(sessions)) covering \(Copy.episodes(episodes))."
        }
        static let deleteHistoryConfirm = "Delete watch history"

        // Discard a failed change from Sync status.
        static let discardChangeTitle = "Discard this change?"
        static let discardChangeMessage =
            "It stays on this device and is never saved to your account."
        static let discardChangeConfirm = "Discard change"

        /// Every confirmation BUTTON label. None may end in an ellipsis (board 09).
        static let buttons: [String] = [
            batchMarkConfirm(18), resetSeasonConfirm(24), restartRewatchConfirm,
            deleteSessionConfirm, deleteHistoryConfirm, discardChangeConfirm, cancel,
            Social.reportSend, Social.blockConfirm, Social.deleteConfirm,
        ]
    }

    // MARK: - Session / account state

    enum State {
        /// Notifications before the system has been asked: a state, not an instruction ("Ask",
        /// review 23 Sep).
        static let ask = "Not set"
        static let signedOut = "You\u{2019}re signed out. Sign in again to continue."
        static let checkingForChanges = "Checking for changes"
        static let couldNotCheck = "Couldn\u{2019}t check for changes"
        static let everythingSynced = "Everything synced"
        static let on = "On"
        static let off = "Off"
        static let neverSynced = "Not synced yet"
    }

    // MARK: - Freshness

    /// "Updated 8m ago" · "Updated 8h ago" · "Updated yesterday" · "Updated Wednesday" ·
    /// "Updated Aug 19" · "Updated Aug 19, 2025". Elapsed time only, so a date-only source can
    /// never produce a clock here.
    static func updated(at ts: Int64, now: Int64) -> String {
        "Updated \(elapsedWord(at: ts, now: now))"
    }

    /// "Synced 2 min ago" — Profile's account line, same ladder, different verb.
    static func synced(at ts: Int64, now: Int64) -> String {
        "Synced \(elapsedWord(at: ts, now: now))"
    }

    /// VoiceOver reads the elapsed time spelled out: "Updated 8 hours ago", never "8h".
    static func updatedSpokenLabel(at ts: Int64, now: Int64) -> String {
        let elapsed = max(0, now - ts)
        let minutes = Int(elapsed / Formatting.minuteMs)
        if minutes < 1 { return "Updated just now" }
        if minutes < 60 { return "Updated \(plural(minutes, "minute", "minutes")) ago" }
        if Formatting.dayDiff(ts: ts, now: now) == 0 {
            return "Updated \(plural(Int(elapsed / Formatting.H), "hour", "hours")) ago"
        }
        return updated(at: ts, now: now)
    }

    /// One elapsed ladder, so board 09's "Updated 8h ago" and board 08's "Synced 2 min ago" are
    /// the same function rendered under two verbs.
    private static func elapsedWord(at ts: Int64, now: Int64) -> String {
        let elapsed = max(0, now - ts)
        let minutes = Int(elapsed / Formatting.minuteMs)
        if minutes < 1 { return "just now" }
        if minutes < 60 { return "\(minutes) min ago" }
        switch Formatting.dayDiff(ts: ts, now: now) {
        case 0: return "\(Int(elapsed / Formatting.H))h ago"
        case -1: return "yesterday"
        // `fmtDayLong` only names weekdays in the FUTURE; the past needs the name directly.
        case -6 ... -2: return Formatting.weekdayNameMonFirst(Formatting.localMondayCol(ts))
        default: return TemporalCopy.dateWord(ts, now: now, anchor: .local)
        }
    }

    // MARK: - Accessibility values

    enum Accessibility {
        static let loading = "Loading"
        static let refreshing = "Refreshing"
        static let complete = "Complete"
        static let active = "Active"
        /// The episode row's tap opens the row in place — it never marks (6 Sep).
        static let showsEpisodeDetails = "Shows episode details"
        static let hidesEpisodeDetails = "Hides episode details"
        static let retryHint = "Tries the request again"
        static let changeStatus = "Change status"
        static let playsTrailerHint = "Plays the video"
        static let opensStreamingOptionsHint = "Opens the streaming options"
        static func person(_ name: String, role: String?) -> String {
            role.map { "\(name), \($0)" } ?? name
        }
        /// The wordmark's full stop is the only live indicator in the app.
        static func wordmarkLive(_ n: Int) -> String {
            n == 1
                ? "One followed episode is airing now"
                : "\(n) followed episodes are airing now"
        }
    }

    // MARK: - Empty states

    /// Board 09's canonical empty copy, plus four states the board's table does not name. Each
    /// added one is recorded with the reason it exists in `EmptyStateCopy`.
    enum Empty {
        static let account = EmptyStateCopy.emptyAccount
        static let noWatching = EmptyStateCopy.noWatching
        static let offlineCached = EmptyStateCopy.offlineCached
        static let offlineNoData = EmptyStateCopy.offlineNoData
        static let serverNoCache = EmptyStateCopy.serverNoCache
        static let nothingScheduled = EmptyStateCopy.nothingScheduled
        static let noFilterMatches = EmptyStateCopy.noFilterMatches
        static let everythingSynced = EmptyStateCopy.everythingSynced
        static func calmToday(title: String?, when: String?) -> EmptyStateCopy {
            EmptyStateCopy.calmToday(title: title, when: when)
        }
        static func caughtUp(title: String?, when: String?) -> EmptyStateCopy {
            EmptyStateCopy.caughtUp(title: title, when: when)
        }
        static func noSearchResults(query: String) -> EmptyStateCopy {
            EmptyStateCopy.noSearchResults(query: query)
        }
    }
}

// MARK: - Audit
//
// The table's own invariants, checkable without a test target (the prototype has none). The
// "Copy rules" preview in `Primitives+States.swift` renders `auditProblems`; it must be empty.

extension Copy {

    /// Every table string, with a representative argument for the parameterised ones.
    static var allSampleStrings: [String] {
        var out = Action.commands.map(\.label)
        out += Home.samples
        out += Confirm.buttons
        out += [
            Toast.marked(episode: 19), Toast.batchMarked(3), Toast.removed,
            Toast.added(title: "One Piece", status: "Watching"), Toast.movedTo("Watched"),
            Toast.offlinePending, Toast.syncFailed(1),
            Notice.today, Notice.schedule, Notice.library, Notice.detailEpisodes,
            Notice.searchAnime, Notice.searchTV,
            Notice.noConnection, Notice.serverError, Notice.signedOut, Notice.timedOut,
            Notice.rateLimited, Notice.suspended,
            Progress.watchedOf(18, 24), Progress.episodeNext(19), Progress.behind(3),
            Progress.left(1), Progress.caughtUp, Progress.caughtUpAfterThisEpisode,
            Progress.lastEpisodeOfTheSeason, Progress.complete("Season 4"),
            Progress.watchedTimes(2), Progress.ordinalWatch(3),
            Progress.inProgress(nextEpisode: 7), Progress.datesUnknown,
            Confirm.batchMarkTitle(18), Confirm.batchMarkMessage(from: 1122, to: 1140),
            Confirm.resetSeasonTitle(24), Confirm.resetSeason(label: "Season 4", total: 24),
            Confirm.restartRewatchTitle, Confirm.restartRewatch(count: 6),
            Confirm.deleteSessionTitle, Confirm.deleteSession(count: 26),
            Confirm.deleteHistoryTitle, Confirm.deleteHistory(sessions: 2, episodes: 59),
            Confirm.discardChangeTitle, Confirm.discardChangeMessage,
            State.signedOut, State.checkingForChanges, State.couldNotCheck,
            State.everythingSynced, State.neverSynced,
            Accessibility.wordmarkLive(1), Accessibility.wordmarkLive(3),
        ]
        out += statusesInOrder
        // The feed, stories, social layer and Discover (spec §1.9): each namespace lists one sample
        // per constant and per function, and a package that adds a string adds its sample with it.
        out += Feed.sampleStrings + Stories.sampleStrings + Social.sampleStrings + Discover.sampleStrings
        out += Video.sampleStrings
        out += FirstRun.sampleStrings
        out += Import.sampleStrings
        out += ShowPage.sampleStrings
        out += [ForYou.becauseWatching("Re:ZERO"), ForYou.becauseWatched("Frieren"), ForYou.moreLike("One Piece"),
                ForYou.moreForYou, ForYou.topPick, ForYou.details,
                Schedule.outNow, Schedule.tonightAt("7:30 PM"), Schedule.episodeRange(5, 8),
                Action.markEpisodeUnwatched(19)]
        for copy in [EmptyStateCopy.emptyAccount, .emptyToday, .emptyHome, .emptySchedule,
                     .noWatching, .offlineCached, .offlineNoData,
                     .searchFailed, .searchLaunchpad, .noSessions,
                     .serverNoCache, .noFilterMatches, .noScheduleMatches, .nothingScheduled, .everythingSynced,
                     .calmToday(title: "Frieren", when: "Returns tomorrow"),
                     .caughtUp(title: "Frieren", when: "Returns tomorrow"),
                     .noSearchResults(query: "one pece"),
                     .feedServerNoCache, .feedOfflineNoData, .feedNoPosts,
                     .feedPostGone, .feedPostGone(show: "One Piece"),
                     .activityEmpty, .savedEmpty, .blockedEmpty, .mutedEmpty,
                     .genreEmpty] {
            out.append(copy.title)
            if let s = copy.supporting { out.append(s) }
            if let s = copy.primaryLabel { out.append(s) }
            if let s = copy.secondaryLabel { out.append(s) }
        }
        return out
    }

    /// Empty when the table is sound.
    static var auditProblems: [String] {
        var problems: [String] = []
        problems += Action.ellipsisViolations.map {
            "\u{201C}\($0)\u{201D} ends in an ellipsis but opens no confirmation"
        }
        problems += Action.missingEllipsis.map {
            "\u{201C}\($0)\u{201D} opens a confirmation but has no ellipsis"
        }
        problems += Action.confirmationButtonViolations.map {
            "confirmation button \u{201C}\($0)\u{201D} ends in an ellipsis"
        }
        problems += allSampleStrings.filter(hasBannedNotation).map {
            "\u{201C}\($0)\u{201D} uses banned episode notation"
        }
        problems += allSampleStrings.filter { $0.contains("!") }.map {
            "\u{201C}\($0)\u{201D} uses an exclamation mark"
        }
        problems += allSampleStrings.filter { $0.contains("'") }.map {
            "\u{201C}\($0)\u{201D} uses a straight apostrophe"
        }
        return problems
    }

    /// "E19", "Ep 19", "S5 E19" — never written anywhere in the app.
    private static func hasBannedNotation(_ s: String) -> Bool {
        if s.contains("Ep ") || s.contains("Ep.") { return true }
        let chars = Array(s)
        for i in chars.indices where chars[i] == "E" {
            if i + 1 < chars.count, chars[i + 1].isNumber { return true }
        }
        return false
    }
}

// MARK: - Empty-state copy as data

/// One empty state's copy. It is data, not a view, so the same values drive the card, the
/// VoiceOver label and a unit test. `symbol` is `nil` where the state has no glyph (the calm day
/// is a sentence about the user's shows, not an icon).
struct EmptyStateCopy: Equatable, Sendable {
    let symbol: String?
    let title: String
    let supporting: String?
    let primaryLabel: String?
    let secondaryLabel: String?

    /// The primary action retries a fetch rather than taking a next step: it is drawn as a quiet
    /// capsule, not the accent one.
    var isRecovery: Bool {
        primaryLabel == Copy.Action.tryAgain || primaryLabel == Copy.Action.retry
    }

    init(symbol: String?, title: String, supporting: String?,
         primaryLabel: String? = nil, secondaryLabel: String? = nil) {
        self.symbol = symbol
        self.title = title
        self.supporting = supporting
        self.primaryLabel = primaryLabel
        self.secondaryLabel = secondaryLabel
    }

    // Board 09's table, verbatim.

    /// LIBRARY's empty account. Every root has its own — see the voice note at the top of this
    /// file: a state may not promise a benefit on a tab the user is not looking at.
    static let emptyAccount = EmptyStateCopy(
        symbol: "rectangle.stack",
        title: "Your library is empty",
        supporting: "Everything you add shows up here.",
        primaryLabel: Copy.Action.addAShow)

    /// TODAY's empty account.
    static let emptyToday = EmptyStateCopy(
        symbol: "tv",
        title: "Nothing to watch yet",
        supporting: "Add a show and this screen fills in with what\u{2019}s next.",
        primaryLabel: Copy.Action.addAShow)

    /// SCHEDULE's empty account. Distinct from `nothingScheduled`, which is a stocked library with
    /// no dated episodes in it.
    static let emptySchedule = EmptyStateCopy(
        symbol: "calendar",
        title: "Build your schedule",
        supporting: "Add a show to see its upcoming episodes here.",
        primaryLabel: Copy.Action.addAShow)

    static let noWatching = EmptyStateCopy(
        symbol: "bookmark",
        title: "Nothing in Watching",
        supporting: "Move a show to Watching to build Today.",
        primaryLabel: Copy.Action.browseYourLibrary)

    static let offlineCached = EmptyStateCopy(
        symbol: "wifi.slash",
        title: "You\u{2019}re offline",
        supporting: "Showing what was saved on this device. Changes sync when you reconnect.")

    static let searchLaunchpad = EmptyStateCopy(
        symbol: "magnifyingglass",
        title: "Find your next show",
        supporting: "Search anime and TV by title.")
    static let noSessions = EmptyStateCopy(
        symbol: "clock.arrow.circlepath",
        title: "No watch history yet",
        supporting: "Your first watch is recorded when you finish the show. Rewatches appear here as sessions.")
    /// Search's transport failure. The SAME title as `serverNoCache` on purpose — one failure has
    /// one name — with a supporting line that names what could not be done.
    static let searchFailed = EmptyStateCopy(
        symbol: "wifi.exclamationmark",
        title: "Couldn\u{2019}t search right now",
        supporting: "Check your connection and try again.",
        primaryLabel: Copy.Action.tryAgain)
    static let offlineNoData = EmptyStateCopy(
        symbol: "wifi.slash",
        title: "You\u{2019}re offline",
        supporting: "Connect to the internet to load your library.",
        primaryLabel: Copy.Action.tryAgain)

    /// Calm day. Variant A names the next known event; variant B admits there is none. Never both.
    ///
    /// NOTE: Today no longer renders this as a plate — a calm day keeps its billboard in the
    /// caught-up grammar (`TodayView.calmLockup`); "Nothing changed since you were last here" led every calm
    /// morning with an absence, at display size, above an Upcoming row restating its own
    /// supporting sentence. Kept for previews and the audit until another surface needs it.
    static func calmToday(title: String?, when: String?) -> EmptyStateCopy {
        let supporting: String
        if let title, let when { supporting = "\(title) \(when.lowercasedFirst())." }
        else { supporting = Copy.Progress.noNewDates }
        return EmptyStateCopy(symbol: nil,
                              title: "Nothing changed since you were last here",
                              supporting: supporting)
    }

    /// Caught up. Carries the next event when one is known — never a second "caught up" sentence.
    static func caughtUp(title: String?, when: String?) -> EmptyStateCopy {
        let supporting: String?
        if let title, let when { supporting = "\(title) \(when.lowercasedFirst())." } else { supporting = nil }
        return EmptyStateCopy(symbol: "checkmark.circle.fill",
                              title: "You\u{2019}re caught up",
                              supporting: supporting)
    }

    // Four states board 09's table does not name. Recorded here as the source of truth.

    /// The network is fine and we are not. Chosen over `offlineNoData` by `SyncCenter.isOnline`
    /// (NWPathMonitor), never guessed from the error.
    static let serverNoCache = EmptyStateCopy(
        symbol: "exclamationmark.circle",
        title: "Couldn\u{2019}t load your library",
        // Not "your saved library will appear": in the no-cache state there IS no saved copy, which
        // is the whole reason this state exists rather than `offlineCached`.
        supporting: "Something went wrong. Try again in a moment.",
        primaryLabel: Copy.Action.tryAgain)

    /// Search returned nothing. Carried forward from the v5 state tiles, reworded to the v9 voice.
    static func noSearchResults(query: String) -> EmptyStateCopy {
        EmptyStateCopy(symbol: "magnifyingglass",
                       title: "No results for \u{201C}\(query)\u{201D}",
                       supporting: "Check the spelling or try another title.")
    }

    /// A filter, not the account, is why the list is empty — so the action clears the filter.
    static let noFilterMatches = EmptyStateCopy(
        symbol: "slider.horizontal.3",
        title: "No titles match",
        supporting: "Clear the filters to see everything in your library.",
        primaryLabel: Copy.Action.clear)

    /// Schedule with a filter that leaves no episode — about episodes and a schedule, never titles
    /// and a library (review i4: it borrowed Library's sentence).
    static let noScheduleMatches = EmptyStateCopy(
        symbol: "line.3.horizontal.decrease",
        title: "No episodes match",
        supporting: "Clear the filter to see the whole schedule.",
        primaryLabel: Copy.Action.clear)

    /// Schedule with a library that has no dated episodes. Not an error and not empty-account.
    static let nothingScheduled = EmptyStateCopy(
        symbol: "calendar",
        title: "Your calendar is clear",
        supporting: "New air dates will appear here as they\u{2019}re announced.")

    /// Sync status's calm frame. It claims only what `SyncCenter.failedChanges` can prove.
    static let everythingSynced = EmptyStateCopy(
        symbol: "checkmark.circle.fill",
        title: Copy.State.everythingSynced,
        supporting: "No changes are waiting to sync.")

    /// "{Title}. {Supporting}" — the card's single VoiceOver label.
    var spokenLabel: String {
        guard let supporting else { return title }
        return "\(title). \(supporting)"
    }
}

private extension String {
    /// "Returns tomorrow" → "returns tomorrow", so a `TemporalCopy` phrase can follow a title
    /// inside one sentence without a second capital.
    func lowercasedFirst() -> String {
        guard let first else { return self }
        return first.lowercased() + dropFirst()
    }
}


// MARK: - The title, as the app says it

extension Franchise {
    /// The title wherever identity is being **recognised** - Today, Library, Schedule, Detail.
    ///
    /// Source titles arrive wrapped in subtitle punctuation ("Re:ZERO -Starting Life in Another
    /// World-"), and the app rendered them three ways at once: Today shortened them, Library and
    /// Schedule printed the raw string, and a shelf caption opened a line on a hyphen. One title,
    /// three spellings, on three screens the user moves between in two taps.
    ///
    /// The raw `title` is kept for exactly two jobs: **Search results**, where the user is matching
    /// what they typed against a catalogue and every character of the source string is evidence,
    /// and **accessibility labels**, which always speak the whole title.
    var displayTitle: String { title.shelfShortened }
}
