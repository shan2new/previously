import Foundation

// The Today feed's strings (spec §1.9.1): the header, the posts, their menus and action bar, the
// thread page, the modules and the feed's states. `FeedComposer` builds every post's sentence
// through here once per memo key; no feed view carries a literal of its own.
//
// Voice (Copy.swift, top): sentence case, no exclamation marks, curly apostrophes, the brand
// never a clause subject and always "Previously." with its stop, "Episode 19" never E19, counts
// through `Copy.plural`, an ellipsis only on a command that opens a confirmation.

extension Copy {
    enum Feed {

        // MARK: Tabs

        static let following = "Following"
        static let forYou = "For you"

        /// The tab bar's word for a feed tab — one place, so the header and VoiceOver agree.
        static func tab(_ tab: FeedTab) -> String {
            switch tab {
            case .following: return following
            case .forYou: return forYou
            }
        }

        // MARK: Header (VoiceOver)

        /// The centred wordmark is a button: it scrolls the feed back to its top. The brand is a
        /// label here, never a subject.
        static let scrollToTop = "Previously., scroll to top"
        static let profile = "Profile"
        static let activity = "Activity"
        /// "Activity, 3 unread" — the bell with its dot.
        static func activityUnread(_ n: Int) -> String {
            "\(activity), \(Copy.plural(n, "unread", "unread"))"
        }

        // MARK: New posts and the caught-up marker

        /// The pill over the list: "1 new post" · "4 new posts".
        static func newPosts(_ n: Int) -> String { Copy.plural(n, "new post", "new posts") }
        static let newPostsHint = "Scrolls to the newest posts"
        static let caughtUpTitle = "You\u{2019}re all caught up"
        /// `phrase` is `TemporalCopy.sinceVisit` — "this morning", "yesterday", "Tuesday".
        static func caughtUpSince(_ phrase: String) -> String {
            "You\u{2019}ve seen everything new since \(phrase)."
        }

        /// The words `TemporalCopy.sinceVisit` returns for a recent previous visit, lower case
        /// because they finish a sentence.
        static let sinceMorning = "this morning"
        static let sinceAfternoon = "this afternoon"
        static let sinceEvening = "this evening"
        static let sinceYesterday = "yesterday"

        // MARK: Modules

        static let suggestedTitle = "Suggested for you"
        /// The module's way to the whole recommendation list — the ForYou shelf's own words.
        static let showMore = Copy.ForYou.showMore
        static let trendingTitle = Copy.Label.trending
        /// "1 · Trending in Anime" — a Trending row's context line.
        static func trendingContext(rank: Int, scope: String) -> String {
            "\(rank) \u{00B7} Trending in \(scope)"
        }
        /// A Trending row's fact for a show on air now — the same words as the ForYou tiles.
        static let airingNow = Copy.ForYou.airingNow
        static let forYouEmpty = "Nothing new from the shows trending right now."

        // MARK: Notices

        static let couldntRefresh = "Your feed couldn\u{2019}t refresh"
        /// An older server with no feed (iD8): the tray and the modules still stand.
        static let unavailable = "News isn\u{2019}t available right now. Your shows are still here."

        // MARK: The post

        /// The gold check's spoken label. The check is drawn only when the lead source is the
        /// studio, network or streamer itself (brief §13).
        static let officialSource = "From the studio or network"

        /// "Season 2 premieres tomorrow" · a film: "The Movie opens Friday 3 October". `when` is
        /// `TemporalCopy.premiereWhen` — lower case inside the headline.
        static func headlineDated(name: String, isMovie: Bool, when: String) -> String {
            isMovie ? "\(name) opens \(when)" : "\(name) premieres \(when)"
        }
        /// A dated post whose date did not arrive with it.
        static func headlineDatedNoDate(name: String) -> String { "\(name) has a date" }
        /// A dated post whose premiere day has passed (`TemporalCopy.premiereHasPassed`): "Season 2
        /// premiered yesterday" · a film: "The Movie opened Tuesday". `when` is
        /// `TemporalCopy.premiereWhen`'s past form. Never "premieres" for a day that is behind us.
        static func headlinePremiered(name: String, isMovie: Bool, when: String) -> String {
            isMovie ? "\(name) opened \(when)" : "\(name) premiered \(when)"
        }

        /// `TemporalCopy.premiereWhen`'s words, lower case because they sit inside a headline.
        static let premieresToday = "today"
        static let premieresTomorrow = "tomorrow"
        /// "this Friday" — a premiere two to six days out.
        static func premieresThis(_ weekday: String) -> String { "this \(weekday)" }
        /// A premiere the day before today (`headlinePremiered`).
        static let premieredYesterday = "yesterday"

        /// "Season 2 arrives in January 2027" · a film: "The Movie is coming late 2026". `phrase`
        /// is `windowPhrase`; an empty one (a window with no words) falls back to the announced
        /// headline rather than printing "arrives " with nothing after it.
        static func headlineWindow(name: String, isMovie: Bool, phrase: String) -> String {
            guard !phrase.isEmpty else { return headlineAnnounced(name: name, isMovie: isMovie) }
            return isMovie ? "\(name) is coming \(phrase)" : "\(name) arrives \(phrase)"
        }

        /// The window as it finishes a headline, built from the server's RESOLVED window
        /// (`releaseWindow`) — its precision is the only thing branched on, and `release` is never
        /// parsed or re-read for words (brief §3, the contract rule):
        ///   • `.day`: "on 5 July 2027" (a day takes "on"), the date's own UTC day, locale-ordered
        ///   • `.month`: "in January 2027"
        ///   • `.quarter`, `.year`: `release` PRINTED as the server sent it, after "in" — "in summer
        ///     2027", "in late 2026", "in 2027". A capitalised first word is set lower case (a season
        ///     or a qualifier mid-sentence); "Q3 2026" keeps its capital. The bare year would drop
        ///     the "late" the source said.
        ///   • `.unknown` (or a day/month with no date): "" — "TBA" is not a window, and the
        ///     headline falls back to the announced one.
        static func windowPhrase(release: String, window: ReleaseWindow) -> String {
            switch window.precision {
            case .day, .month:
                // `parts` fills a missing month or day with 1, so a "2027-01" filed as a DAY would
                // print "on 1 January 2027" — a date nobody announced. Require the segments the
                // precision claims.
                let segments = window.date?.split(separator: "-").count ?? 0
                guard segments >= (window.precision == .day ? 3 : 2), let p = window.parts,
                      let ts = Formatting.utcTimestamp(y: p.year, mo: p.month, d: p.day) else {
                    return ""
                }
                return window.precision == .day
                    ? "on \(Formatting.formatted(ts, skeleton: "dMMMMyyyy", anchor: .utcDate))"
                    : "in \(Formatting.formatted(ts, skeleton: "MMMMyyyy", anchor: .utcDate))"
            case .quarter, .year:
                let text = release.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else {
                    guard window.precision == .year, let year = window.parts?.year else { return "" }
                    return "in \(year)"
                }
                return "in \(lowerCapitalised(text))"
            case .unknown:
                return ""
            }
        }

        /// An episode that aired this week: "Episode 19 is out" · a later season's first: "Season 2
        /// has started" · a show's very first: "The first episode is out".
        static func headlineEpisode(installment: String, episode: Int) -> String {
            guard episode == 1 else { return "\(Copy.episode(episode)) is out" }
            return installment.isEmpty ? "The first episode is out" : "\(installment) has started"
        }

        /// A first season nobody has seen is a series, not "Season 1".
        static let newSeries = "A new series"
        /// A film the catalogue only numbers ("Movie 1"): it has no name to print yet.
        static let newFilm = "A new film"

        /// "Season 3 is confirmed" · a film: "New film: The Movie" · a film with no name yet: "A
        /// new film is confirmed".
        static func headlineAnnounced(name: String, isMovie: Bool) -> String {
            guard isMovie else { return "\(name) is confirmed" }
            return name == newFilm ? "\(newFilm) is confirmed" : "New film: \(name)"
        }

        /// "Season 4 is rumoured" · an installment the research only knows as a sequel: "A sequel
        /// is rumoured".
        static func headlineRumour(name: String) -> String {
            name.lowercased().hasPrefix("sequel") ? "A \(lowerFirst(name)) is rumoured" : "\(name) is rumoured"
        }

        /// The post as one sentence — what an official account would write (spike's rules).
        ///   • dated, window, rumour, trailer: the headline, closed with a full stop;
        ///   • announced: "Season 3 is confirmed — no date yet." · a film: "A new film, The
        ///     Movie, is in production. No date yet.";
        ///   • then " Premieres Friday." when a premiere line is given — EXCEPT on a dated post,
        ///     whose headline already is the date, and on an announced one, which just said there
        ///     is no date.
        static func sentence(kind: FeedPostKind, headline: String, name: String, isMovie: Bool,
                             premiereLine: String?) -> String {
            let lead: String
            switch kind {
            case .dated, .window, .rumour, .trailer, .episode:
                lead = closed(headline)
            case .announced, .unknown:
                if isMovie {
                    lead = name == newFilm
                        ? "\(newFilm) is in production \u{2014} no date yet."
                        : "A new film, \(name), is in production. No date yet."
                } else {
                    lead = "\(headline) \u{2014} no date yet."
                }
            }
            switch kind {
            case .dated, .announced, .episode, .unknown:
                return lead
            case .window, .rumour, .trailer:
                guard let premiereLine, !premiereLine.isEmpty else { return lead }
                return "\(lead) \(closed(premiereLine))"
            }
        }

        /// "Premieres tomorrow" · "Premieres this Friday" · "Premieres Friday 3 October". `when`
        /// is `TemporalCopy.premiereWhen`.
        static func premiereLine(_ when: String) -> String { "Premieres \(when)" }

        // MARK: The stamp (TemporalCopy.feedStamp)

        static let stampNow = "now"
        static func stampMinutes(_ n: Int) -> String { "\(n)m" }
        static func stampHours(_ n: Int) -> String { "\(n)h" }
        static func stampDays(_ n: Int) -> String { "\(n)d" }
        /// A date-only fact from today: no clock may be invented for it.
        static let stampToday = "Today"

        // MARK: The rumour note

        static let rumourNoteTitle = "Unconfirmed \u{2014} nothing official yet"
        /// "3 reports · none from the studio or network".
        static func rumourNoteReports(_ n: Int) -> String {
            "\(Copy.plural(n, "report", "reports")) \u{00B7} none from the studio or network"
        }

        /// The row's one VoiceOver label, reading what the row draws: "One Piece. Season 2 is
        /// confirmed — no date yet. The studio announced it after the finale. 2h" — the sentence,
        /// then the research's note (`FeedPostModel.body`'s two paragraphs), closed so the stamp
        /// is its own beat. A rumour passes no note: its Community Note is read in its own box.
        static func postAccessibility(show: String, sentence: String, note: String?, stamp: String) -> String {
            let words = [sentence, note.map(closed)].compactMap { $0 }.filter { !$0.isEmpty }
            return "\(show). \(words.joined(separator: " ")) \(stamp)"
        }

        // MARK: Folds (a post hidden in place, with Undo)

        static let foldNotInterested = "Thanks. You\u{2019}ll see fewer posts like this."
        static func foldMuted(_ show: String) -> String { "You muted news from \(show)." }

        // MARK: The post's menu (commands — none opens a confirmation)

        static let notInterested = "Not interested in this post"
        static func mute(_ show: String) -> String { "Mute \(show)" }
        static func unmute(_ show: String) -> String { "Unmute \(show)" }
        static let copyText = "Copy text"
        /// Drawn only for a source with an https link.
        static func readOn(_ publisher: String) -> String { "Read on \(publisher)" }
        static func goTo(_ show: String) -> String { "Go to \(show)" }
        /// The `···` button's spoken label.
        static let more = "More"

        // MARK: The action bar (VoiceOver)

        static func replies(_ n: Int) -> String { "Replies, \(n)" }
        static let like = "Like"
        static let unlike = "Unlike"
        /// The like button's value: "1 like" · "42 likes".
        static func likes(_ n: Int) -> String { Copy.plural(n, "like", "likes") }
        static let remindMe = "Remind me"
        static let reminderOn = "Reminder set"
        static let save = "Save"
        static let unsave = "Remove from Saved"
        static let share = "Share"
        static let playTrailer = "Play trailer"
        /// A trailer playing silently in its post (X's inline video): what VoiceOver says of it.
        static let trailerPlaying = "Trailer playing without sound"
        /// The inline trailer's sound toggle (X's corner button).
        static let soundOn = "Turn sound on"
        static let soundOff = "Turn sound off"
        /// X's pill over a finished inline video.
        static let watchAgain = "Watch again"
        /// The inline trailer's time left, "0:32" / "1:05:09" — a clock reading, not a sentence.
        static func timeLeft(_ seconds: Double) -> String {
            let s = max(0, Int(seconds.rounded(.up)))
            let h = s / 3600, m = (s % 3600) / 60, r = s % 60
            let two = { (n: Int) in n < 10 ? "0\(n)" : "\(n)" }
            return h > 0 ? "\(h):\(two(m)):\(two(r))" : "\(m):\(two(r))"
        }
        static let viewPicture = "View picture"
        static func pictureFrom(_ show: String) -> String { "Picture from \(show)" }
        /// The row's named accessibility action (a double-tap on the media likes it).
        static let likePost = "Like"

        // MARK: Receipts and the alerts primer (§4.4)

        /// Saved lives only in Profile; the receipt says where (iD6).
        static let savedNotice = "Saved to Profile"
        /// Said only once the local notification is actually armed. `date` is
        /// `Formatting.formatted(at, skeleton: "EEEdMMM", anchor:)` — "Sat 3 Oct".
        static func reminderSetFor(_ date: String) -> String { "Reminder set for \(date)" }
        static let reminderSetUndated = "Reminder set. News about it will show in Activity."
        static let alertsPrimer = "Turn on notifications so this reminder can reach you."
        /// The primer's two answers — the Search primer's words, one phrasing app-wide.
        static let alertsTurnOn = Copy.Search.primerTurnOn
        static let alertsNotNow = Copy.Search.primerNotNow
        static let alertsDenied = "Notifications are off for Previously. in Settings."

        // MARK: The post page

        static let postTitle = "Post"
        /// "via Netflix Tudum" on the thread's meta line.
        static func via(_ publisher: String) -> String { "via \(publisher)" }
        /// "1 Like" · "12 Likes" on the thread's meta line. The numeral and the noun are joined by
        /// U+00A0 (`Copy.plural`), so the view can split there and set the numeral bold.
        static func likesInline(_ n: Int) -> String { Copy.plural(n, "Like", "Likes") }
        static let howThisStoryGotHere = "How this story got here"
        static let sources = "Sources"
        static let trailFootnote = "Each report links to the article it came from."
        /// A post that has aged out of the feed: its thread stays readable.
        static let notLive = "This post has left the feed. The replies are still here."

        /// The post page for an id the server no longer answers. `postGone(show:)` offers the
        /// show's page when the show is known.
        static let postGone: EmptyStateCopy = EmptyStateCopy.feedPostGone
        static func postGone(show: String?) -> EmptyStateCopy { EmptyStateCopy.feedPostGone(show: show) }

        // MARK: Lines built of facts

        /// The separator between facts on one line: " · ".
        static let separator = " \u{00B7} "
        /// Facts joined on one line, the empty ones dropped: "Season 2 · 2h", "15 Jun 2026 · via
        /// Crunchyroll News".
        static func separated(_ parts: [String]) -> String {
            parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: separator)
        }
        /// Why a For you post is in the feed, over its name (X's social context line): the shows
        /// of yours it comes from, in the words Discover uses for the same recommendation
        /// (`ForYou.reason`: "Like Re:ZERO and Slime", "Because you finished Game of Thrones") —
        /// each named as your library names it (`name`), short enough that two fit the line — or
        /// the genre of yours it trends in.
        static func context(_ context: FeedPostContext,
                            name: (RecommendationItem.Seed) -> String = { $0.title }) -> String {
            switch context {
            case .recommended(let kind, let seeds, let count):
                var named = seeds.map {
                    RecommendationItem.Seed(franchiseId: $0.franchiseId, title: name($0).shelfShortened(fitting: 20))
                }
                // A name that fits leads: behind "That Time I Got Reincarnated as a Slime" the
                // line ended "and 4…" — the count is the half that says how sure the pick is.
                if let fits = named.firstIndex(where: { $0.title.count <= 22 }), fits > 0 {
                    named.insert(named.remove(at: fits), at: 0)
                }
                return ForYou.reason(.init(kind: kind, seeds: named, count: count))
            case .taste(let genres):
                return "Trending in \(genres.joined(separator: " and "))"
            }
        }
        /// A fact that follows another on its line, drawn as its own run: "· 2h".
        static func afterDot(_ fact: String) -> String { "\u{00B7} \(fact)" }

        // MARK: The picture viewer and the trail

        /// The picture viewer's way out (VoiceOver and the close glyph's label).
        static let closeViewer = "Close"
        /// A trail beat reported by more than one outlet: "Also Variety, Deadline" · "Also Variety,
        /// Deadline and 3 more".
        static func trailAlso(_ publishers: [String], more: Int) -> String {
            let names = publishers.joined(separator: ", ")
            return more > 0 ? "Also \(names) and \(more) more" : "Also \(names)"
        }
        /// For you's Add capsule: what it does, spoken.
        static var addHint: String { Copy.Search.addHint }

        // MARK: Helpers

        private static func lowerFirst(_ s: String) -> String {
            guard let first = s.first else { return s }
            return first.lowercased() + s.dropFirst()
        }

        /// `lowerFirst` for a CAPITALISED first word only ("Late 2026" → "late 2026", "Mid-2027" →
        /// "mid-2027"): an initialism or a code keeps its capital ("Q3 2026", never "q3 2026").
        /// Typography, not a reading of the words.
        private static func lowerCapitalised(_ s: String) -> String {
            let chars = Array(s.prefix(2))
            guard chars.count == 2, chars[0].isUppercase, chars[1].isLowercase else { return s }
            return lowerFirst(s)
        }

        /// A resolved window for the audit's samples (the server's shape: "2027-01" at `.month`).
        private static func sampleWindow(_ date: String, _ precision: ReleaseWindow.Precision) -> ReleaseWindow {
            ReleaseWindow(date: date, precision: precision, sortKey: nil)
        }

        /// A headline closes with a full stop unless it already ends a sentence (a trailer's own
        /// title may).
        private static func closed(_ s: String) -> String {
            guard let last = s.last else { return s }
            return ".?!\u{2026}".contains(last) ? s : s + "."
        }

        // MARK: Audit

        /// One sample per constant and per function (spec §1.9), for `Copy.allSampleStrings`.
        static var sampleStrings: [String] {
            var out: [String] = [
                following, forYou, tab(.following), tab(.forYou),
                scrollToTop, profile, activity, activityUnread(1), activityUnread(3),
                newPosts(1), newPosts(4), newPostsHint,
                caughtUpTitle, caughtUpSince(sinceYesterday),
                sinceMorning, sinceAfternoon, sinceEvening, sinceYesterday,
                suggestedTitle, showMore, trendingTitle, trendingContext(rank: 1, scope: Copy.Filter.anime),
                airingNow, forYouEmpty, couldntRefresh, unavailable, officialSource,
                headlineDated(name: "Season 2", isMovie: false, when: premieresTomorrow),
                headlineDated(name: "The Movie", isMovie: true, when: premieresThis("Friday")),
                headlineDatedNoDate(name: "Season 2"),
                headlinePremiered(name: "Season 2", isMovie: false, when: premieredYesterday),
                headlinePremiered(name: "The Movie", isMovie: true, when: "Tuesday"),
                premieresToday, premieresTomorrow, premieresThis("Friday"), premieredYesterday,
                headlineWindow(name: "Season 2", isMovie: false,
                               phrase: windowPhrase(release: "January 2027", window: sampleWindow("2027-01", .month))),
                headlineWindow(name: "The Movie", isMovie: true,
                               phrase: windowPhrase(release: "Late 2026", window: sampleWindow("2026", .year))),
                headlineWindow(name: "Season 2", isMovie: false, phrase: ""),
                windowPhrase(release: "January 2027", window: sampleWindow("2027-01", .month)),
                windowPhrase(release: "Summer 2027", window: sampleWindow("2027-07", .quarter)),
                windowPhrase(release: "Q3 2027", window: sampleWindow("2027-07", .quarter)),
                windowPhrase(release: "Late 2026", window: sampleWindow("2026", .year)),
                windowPhrase(release: "2027-07-05", window: sampleWindow("2027-07-05", .day)),
                windowPhrase(release: "2027", window: sampleWindow("2027", .year)),
                headlineAnnounced(name: "Season 3", isMovie: false),
                headlineAnnounced(name: "The Movie", isMovie: true),
                headlineRumour(name: "Season 4"), headlineRumour(name: "Sequel"),
                premiereLine(premieresTomorrow),
                stampNow, stampMinutes(5), stampHours(2), stampDays(3), stampToday,
                rumourNoteTitle, rumourNoteReports(1), rumourNoteReports(3),
                postAccessibility(show: "One Piece", sentence: "Season 2 premieres tomorrow.", note: nil,
                                  stamp: stampHours(2)),
                postAccessibility(show: "One Piece", sentence: "Season 3 is confirmed \u{2014} no date yet.",
                                  note: "The studio announced it after the finale", stamp: stampHours(2)),
                foldNotInterested, foldMuted("One Piece"),
                notInterested, mute("One Piece"), unmute("One Piece"), copyText,
                readOn("Crunchyroll News"), goTo("One Piece"), more,
                replies(3), like, unlike, likes(1), likes(42),
                remindMe, reminderOn, save, unsave, share, playTrailer, viewPicture,
                pictureFrom("One Piece"), likePost,
                savedNotice, reminderSetFor("Sat 3 Oct"), reminderSetUndated,
                alertsPrimer, alertsTurnOn, alertsNotNow, alertsDenied,
                postTitle, via("Netflix Tudum"), likesInline(1), likesInline(12),
                howThisStoryGotHere, sources, trailFootnote, notLive,
                separator, separated(["Season 2", stampHours(2)]), afterDot(stampHours(2)),
                closeViewer, trailAlso(["Variety", "Deadline"], more: 0),
                trailAlso(["Variety", "Deadline"], more: 3), addHint,
            ]
            let samples: [(FeedPostKind, String, String, Bool, String?)] = [
                (.dated, headlineDated(name: "Season 2", isMovie: false, when: premieresTomorrow), "Season 2", false,
                 premiereLine(premieresTomorrow)),
                (.window, headlineWindow(name: "Season 2", isMovie: false, phrase: "in January 2027"), "Season 2", false, nil),
                (.announced, headlineAnnounced(name: "Season 3", isMovie: false), "Season 3", false, nil),
                (.announced, headlineAnnounced(name: "The Movie", isMovie: true), "The Movie", true, nil),
                (.rumour, headlineRumour(name: "Season 4"), "Season 4", false, nil),
                (.trailer, "Official Trailer", "Season 2", false, premiereLine(premieresThis("Friday"))),
                (.unknown, headlineAnnounced(name: "Season 3", isMovie: false), "Season 3", false, nil),
            ]
            out += samples.map { sentence(kind: $0.0, headline: $0.1, name: $0.2, isMovie: $0.3, premiereLine: $0.4) }
            return out
        }
    }
}

// MARK: - The feed's empty states

extension EmptyStateCopy {
    /// The feed failed with nothing cached, while the device is online.
    static let feedServerNoCache = EmptyStateCopy(
        symbol: "exclamationmark.circle",
        title: "Couldn\u{2019}t load your feed",
        supporting: "Pull down to try again.",
        primaryLabel: Copy.Action.tryAgain)

    /// The feed failed with nothing cached, and `SyncCenter.isOnline` says the network is gone.
    static let feedOfflineNoData = EmptyStateCopy(
        symbol: "wifi.slash",
        title: "You\u{2019}re offline",
        supporting: "Connect to the internet to load your feed.",
        primaryLabel: Copy.Action.tryAgain)

    /// A stocked library whose shows have no news yet. Not an error, and not the empty account
    /// (which reuses `emptyToday`).
    static let feedNoPosts = EmptyStateCopy(
        symbol: "newspaper",
        title: "No news from your shows yet",
        supporting: "Premiere dates, trailers and announcements show up here.")

    /// A post page whose id the server no longer answers, with no way onward.
    static let feedPostGone: EmptyStateCopy = EmptyStateCopy.feedPostGone(show: nil)

    /// …and with the show's page as the way onward when the show is known.
    static func feedPostGone(show: String?) -> EmptyStateCopy {
        EmptyStateCopy(symbol: "questionmark.bubble",
                       title: "This post isn\u{2019}t available",
                       supporting: "It was updated or removed.",
                       primaryLabel: show.map { Copy.Feed.goTo($0) })
    }
}
