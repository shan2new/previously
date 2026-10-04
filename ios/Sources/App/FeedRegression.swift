#if DEBUG
import Foundation

/// `-verifyFeed 1` (DEBUG): the feed's pure rules against fixtures shaped like the server's wire —
/// the row composer (the caught-up marker, Suggested and Trending placed by rule, folds, hides,
/// mutes, the notices, the offline copy), the post model's words, the reply length as the server
/// counts it, the notification routes, the window phrase, the stamp and the episode gate. No
/// network, no account writes. Prints `FEED_VERIFY_PASS` or `FEED_VERIFY_FAIL <cases>`.
///
/// There is no iOS test target (spec §8.1); this is the app's regression pattern
/// (`-verifyArtworkIdentity`, `-verifyAnnouncements`).
@MainActor
enum FeedRegression {
    static func run() {
        var failures: [String] = []
        func check(_ ok: Bool, _ name: String) {
            if !ok { failures.append(name) }
        }

        let now: Int64 = .nowMs
        let hour = Formatting.H
        let day = Formatting.D
        let prev = now - 6 * hour

        // MARK: Composer — Following

        func following(_ posts: [[String: Any]]) -> FeedResponse? {
            response(tab: "following", posts: posts, prevOpenedAt: prev)
        }
        func ids(_ rows: [FeedRow]) -> [String] { rows.map(\.id) }
        func compose(_ res: FeedResponse?, tab: FeedTab = .following, fromCache: Bool = false,
                     failed: Bool = false, unavailable: Bool = false,
                     folds: [String: FeedFold] = [:], hidden: Set<String> = [], muted: Set<String> = [],
                     recs: [String] = ["r1", "r2", "r3", "r4"], trending: [FranchiseSummary] = [],
                     libraryEmpty: Bool = false, online: Bool = true,
                     allows: @escaping (MediaSource) -> Bool = { _ in true }) -> [FeedRow] {
            var state = FeedTabState(response: res, fromCache: fromCache, loadedAt: now)
            state.failed = failed
            state.unavailable = unavailable
            if fromCache { state.response = res?.asCached() }
            return FeedComposer.rows(tab: tab, state: state, library: [], libraryIndex: { _ in nil },
                                     now: now, folds: folds, hidden: hidden,
                                     muted: muted, recommendationKeys: recs, untrackedTrending: trending,
                                     libraryEmpty: libraryEmpty, online: online, allows: allows)
        }
        let f1 = { (id: String, fresh: Bool) in Self.post(id, fid: "fa", fresh: fresh, time: now - hour) }

        // The audience's wall (4 Oct): For you carries the viewer's kind only, whatever the response
        // holds; Following is their own shows and is never filtered. The fixtures' shows are anime.
        let wall = [f1("w1", false), f1("w2", false)]
        let posts = { (rows: [FeedRow]) in rows.filter { $0.id.hasPrefix("post/") }.count }
        check(posts(compose(response(tab: "foryou", posts: wall, prevOpenedAt: prev), tab: .forYou,
                            allows: { $0 == .tmdb })) == 0, "a TV viewer's For you holds no anime post")
        check(posts(compose(response(tab: "foryou", posts: wall, prevOpenedAt: prev), tab: .forYou,
                            allows: { $0 == .anilist })) == 2, "an anime viewer's For you keeps them")
        check(posts(compose(following(wall), allows: { $0 == .tmdb })) == 2, "Following is never filtered by audience")
        check(Audience.anime.allows(.anilist) && !Audience.anime.allows(.tmdb)
              && Audience.tv.allows(.tmdb) && !Audience.tv.allows(.anilist)
              && Audience.both.allows(.anilist) && Audience.both.allows(.tmdb), "each audience allows its own kind")
        check(Audience.anime.filter == .anime && Audience.tv.filter == .tv && Audience.both.filter == .all,
              "a single audience fixes the scope")

        // Two fresh, three not: the marker sits between the blocks; Suggested after the 3rd post.
        let mixed = following([f1("n1", true), f1("n2", true), f1("o1", false), f1("o2", false), f1("o3", false)])
        check(mixed != nil, "fixture decodes")
        check(mixed?.posts.count == 5 && mixed?.franchises.count == 2, "posts and franchises decode")
        let a = compose(mixed)
        check(ids(a) == ["post/n1", "post/n2", "caughtup", "post/o1", "suggested", "post/o2", "post/o3"],
              "caught-up between the blocks, Suggested after the 3rd post: \(ids(a))")
        if case .suggested(let keys)? = a.first(where: { $0.id == "suggested" }) {
            check(keys == ["r1", "r2", "r3"], "Suggested carries at most three keys")
        } else {
            check(false, "Suggested present")
        }
        if case .caughtUp(let since)? = a.first(where: { $0.id == "caughtup" }) {
            check(since == prev, "the marker is dated by the real previous visit")
        }
        check(a.compactMap { row -> String? in
                  if case .post(let m) = row { return m.fresh ? m.id : nil }
                  return nil
              } == ["n1", "n2"],
              "only the server's fresh posts are fresh")

        // Four fresh, two not: the 3rd post is inside the fresh block, so Suggested moves after the marker.
        let longFresh = following([f1("n1", true), f1("n2", true), f1("n3", true), f1("n4", true),
                                   f1("o1", false), f1("o2", false)])
        check(ids(compose(longFresh)) == ["post/n1", "post/n2", "post/n3", "post/n4", "caughtup", "suggested",
                                          "post/o1", "post/o2"], "the fresh block is never split")

        // Everything fresh, or nothing: no marker.
        let allFresh = following([f1("n1", true), f1("n2", true), f1("n3", true)])
        check(ids(compose(allFresh)) == ["post/n1", "post/n2", "post/n3", "suggested"], "all fresh: no marker")
        let noneFresh = following([f1("o1", false), f1("o2", false)])
        check(ids(compose(noneFresh)) == ["post/o1", "post/o2", "suggested"], "none fresh: no marker, Suggested after the last")
        let mixedNoVisit = response(tab: "following", posts: [f1("n1", true), f1("n2", true), f1("o1", false),
                                                              f1("o2", false), f1("o3", false)], prevOpenedAt: 0)
        check(ids(compose(mixedNoVisit)).contains("caughtup") == false, "no previous visit: no marker")
        // The marker is dated by the anchor the server ordered against (its echo), never the device's.
        let echoed = now - 2 * hour
        let mixedEchoed = response(tab: "following", posts: [f1("n1", true), f1("o1", false)], prevOpenedAt: echoed)
        if case .caughtUp(let since)? = compose(mixedEchoed).first(where: { $0.id == "caughtup" }) {
            check(since == echoed, "the marker reads the response's anchor")
        } else {
            check(false, "the marker reads the response's anchor (present)")
        }

        // The offline copy: nothing in it is new (iD2), and offline says so first.
        let cached = compose(mixed, fromCache: true, online: false)
        check(!ids(cached).contains("caughtup"), "a cached response has no marker")
        check(cached.first?.id == "notice/offlineCached", "offline copy: the notice leads")
        check(!cached.contains { row -> Bool in
                  if case .post(let m) = row { return m.fresh }
                  return false
              }, "a cached response has no fresh post")
        check(mixed?.asCached().posts.allSatisfy { !$0.fresh } == true, "asCached clears every fresh flag")
        check(compose(mixed, fromCache: true, online: true).first?.id != "notice/offlineCached", "online cache: no offline notice")
        check(compose(mixed, failed: true).first?.id == "notice/refreshFailed", "a failed refresh over content says so first")

        // One post, none: Suggested still appears.
        check(ids(compose(following([f1("o1", false)]))) == ["post/o1", "suggested"], "one post: Suggested after it")
        check(ids(compose(following([]))) == ["empty/noPosts", "suggested"], "no posts: the empty row, then Suggested")
        check(ids(compose(following([]), recs: [])) == ["empty/noPosts"], "no recommendations: no Suggested")

        // The empty account: the empty state and the chart.
        let chart = summaries(["t1", "t2"])
        check(chart.count == 2, "trending fixture decodes")
        check(ids(compose(following([]), trending: chart, libraryEmpty: true)) == ["empty/emptyAccount", "trending"],
              "empty account: empty state, then Trending")
        check(ids(compose(following([]), recs: [], libraryEmpty: true)) == ["empty/emptyAccount"],
              "empty account with no chart: the empty state alone")

        // Folds keep their place; hides and mutes leave.
        let three = following([f1("o1", false), f1("o2", false), post("o3", fid: "fb", time: now - 2 * hour)])
        let folded = compose(three, folds: ["o1": .notInterested], hidden: ["o1", "o2"], recs: [])
        check(ids(folded) == ["fold/o1", "post/o3"], "a fold stays in place, a hidden post leaves: \(ids(folded))")
        check(ids(compose(three, muted: ["fa"], recs: [])) == ["post/o3"], "a muted show's posts leave")
        check(ids(compose(three, folds: ["o2": .muted(show: "Alpha")], muted: ["fa"], recs: [])) == ["fold/o2", "post/o3"],
              "the post a mute came from folds in place")

        // An older server (iD8): the notice and the modules, never a blank Today.
        check(ids(compose(nil, unavailable: true, trending: chart)) == ["notice/unavailable", "suggested", "trending"],
              "unavailable: notice, Suggested, Trending")
        check(compose(nil).isEmpty, "no response yet: no rows")

        // MARK: Composer — For you

        let forYouPosts = (1...6).map { Self.post("y\($0)", fid: "fa", fresh: true, time: now - Int64($0) * hour) }
        let forYou = response(tab: "foryou", posts: forYouPosts, prevOpenedAt: prev, trending: ["t1", "t2", "t3"])
        let fy = compose(forYou, tab: .forYou)
        check(ids(fy) == ["post/y1", "post/y2", "post/y3", "post/y4", "post/y5", "trending", "post/y6"],
              "For you: Trending after the 5th post, no Suggested: \(ids(fy))")
        check(!fy.contains { row -> Bool in
                  if case .post(let m) = row { return m.fresh }
                  return false
              }, "For you has no fresh post")
        check(!ids(fy).contains("caughtup"), "For you has no marker")
        let fyEmpty = response(tab: "foryou", posts: [], prevOpenedAt: prev, trending: ["t1"])
        check(ids(compose(fyEmpty, tab: .forYou)) == ["empty/forYouEmpty", "trending"], "For you empty: the empty row, then Trending")
        check(Set(ids(fy)).count == fy.count, "row ids are unique")

        // MARK: The post model

        let show = franchise("fa", title: "Alpha")
        if let show, let res = response(tab: "following", posts: [
            post("d1", fid: "fa", kind: "dated", installment: "Season 2", time: now - hour,
                 premiere: ["at": now + day, "precision": "exact"]),
            post("r1", fid: "fa", kind: "rumour", installment: "Season 3", time: now - hour, official: true,
                 note: "Two trade reports cite production staff."),
            // The research's note: the post's second paragraph, trimmed — and nothing when blank.
            post("n1", fid: "fa", kind: "announced", installment: "Season 6", time: now - hour,
                 note: "  The studio announced it after the finale.\n"),
            post("n2", fid: "fa", kind: "announced", installment: "Season 7", time: now - hour, note: " \n "),
            post("a1", fid: "fa", kind: "announced", installment: "The Movie", isMovie: true, time: now - hour),
            post("t1", fid: "fa", kind: "trailer", installment: "", time: now - hour,
                 video: ["id": "abc123", "site": "youtube", "kind": "trailer", "title": "Alpha - Official Trailer [Subtitled]",
                         "scope": ["type": "franchise"]]),
            post("a2", fid: "fa", kind: "announced", installment: "Season 5", time: now - hour,
                 video: ["id": "jkl012", "site": "youtube", "kind": "trailer", "title": "Official Trailer",
                         "scope": ["type": "franchise"]]),
            post("s1", fid: "fa", kind: "announced", installment: "Season 4", time: now - hour, official: true,
                 sources: [["publisher": "Studio", "tier": "official", "url": "https://studio.example/news", "publishedAt": now - hour,
                            "dateOnly": false, "primary": true]]),
            // A premiere whose day has passed (the server's sync lag, or a post opened by id).
            post("d2", fid: "fa", kind: "dated", installment: "Season 2", time: now - 3 * day,
                 premiere: ["at": now - 2 * day, "precision": "exact"]),
            post("t2", fid: "fa", kind: "trailer", installment: "", time: now - hour,
                 premiere: ["at": now - 2 * day, "precision": "date_only"],
                 video: ["id": "def456", "site": "youtube", "kind": "trailer", "title": "Official Trailer",
                         "scope": ["type": "franchise"]]),
            post("t3", fid: "fa", kind: "trailer", installment: "", time: now - hour,
                 premiere: ["at": now + 3 * day, "precision": "exact"],
                 video: ["id": "ghi789", "site": "youtube", "kind": "trailer", "title": "Official Trailer",
                         "scope": ["type": "franchise"]]),
            // Windows, worded from the resolved window — never by re-reading `release`.
            post("w1", fid: "fa", kind: "window", installment: "Season 2", time: now - hour,
                 window: ["release": "Late 2026", "releaseWindow": ["date": "2026", "precision": "year", "sortKey": 20260901]]),
            post("w2", fid: "fa", kind: "window", installment: "Season 2", time: now - hour,
                 window: ["release": "TBA", "releaseWindow": ["date": NSNull(), "precision": "unknown", "sortKey": NSNull()]]),
            post("w3", fid: "fa", kind: "window", installment: "Season 2", time: now - hour,
                 window: ["release": "2027-01", "releaseWindow": ["date": "2027-01", "precision": "month", "sortKey": 20270101]]),
        ], prevOpenedAt: prev) {
            let models = Dictionary(res.posts.map { p in
                (p.id, FeedComposer.model(p, show: show, library: nil, owned: false, now: now, fresh: false))
            }, uniquingKeysWith: { x, _ in x })
            let dated = models["d1"]
            let tomorrow = TemporalCopy.premiereWhen(now + day, anchor: .local, now: now)
            check(dated?.headline == Copy.Feed.headlineDated(name: "Season 2", isMovie: false, when: tomorrow),
                  "a dated post's headline names its day")
            check(dated?.sentence == dated.map { "\($0.headline)." }, "a dated post's sentence is its headline, once")
            check(dated?.premiereLine != nil, "a dated post carries its premiere line")
            check(models["r1"]?.media == PostMediaArt.none, "a rumour has no media")
            check(models["r1"]?.showsOfficialMark == false, "a rumour never wears the check")
            check(models["a1"]?.sentence.hasPrefix("A new film, The Movie") == true, "an announced film's sentence")
            if case .trailer(let stills, let video)? = models["t1"]?.media {
                check(!stills.isEmpty && video.id == "abc123", "a trailer's stills")
            } else {
                check(false, "a trailer shows its still")
            }
            if case .trailer(_, let video)? = models["a2"]?.media {
                check(video.id == "jkl012", "news with its own trailer shows the trailer")
            } else {
                check(false, "news with its own trailer shows the trailer")
            }
            check(models["a2"]?.headline == Copy.Feed.headlineAnnounced(name: "Season 5", isMovie: false),
                  "news with a trailer keeps the news's words")
            if case .art? = models["a1"]?.media {} else { check(false, "news without a trailer shows its art") }
            check(models["t1"]?.headline.contains("[Subtitled]") == false, "a trailer's headline drops [Subtitled]")
            check(models["t1"]?.headline.contains(" - ") == false, "a trailer's headline drops its hyphens")
            check(models["s1"]?.showsOfficialMark == true, "an official lead source wears the check")
            check(models["s1"]?.shareURL?.absoluteString == "https://studio.example/news", "share links the primary source")
            check(models["s1"]?.readOn?.publisher == "Studio", "Read on names the source")
            check(models["d1"]?.shareURL == nil && models["d1"]?.readOn == nil, "no https source: nothing to open")
            check(models["s1"]?.shareText == "Alpha: \(models["s1"]?.sentence ?? "")", "share text is show and sentence")

            // ONE body — the sentence, then the note — whole on the post page, and in the timeline up
            // to X's 280 characters; past them the row draws X's cut and ends on "Show more".
            let finale = "The studio announced it after the finale."
            check(models["n1"]?.clippedBody == nil, "a short body is drawn whole in the timeline")
            let long = String(repeating: "Season two arrives soon, ", count: 16)
            let cut = FeedComposer.timelineCut(long) ?? ""
            check(cut.hasSuffix("soon\u{2026}") && cut.count <= FeedComposer.timelineLimit + 1,
                  "a long body is cut at a word inside 280 characters, its comma dropped for the ellipsis: \(cut)")
            check(FeedComposer.timelineCut(String(repeating: "a", count: FeedComposer.timelineLimit)) == nil,
                  "280 characters are drawn whole")
            check("Demon Slayer: Kimetsu no Yaiba".shelfShortened(fitting: FeedComposer.nameLineBudget) == "Demon Slayer",
                  "a long name offers the name line its identity half")
            check(models["n1"].map { $0.body == "\($0.sentence)\n\n\(finale)" } == true,
                  "a post's body is its sentence, then its note as a paragraph: \(models["n1"]?.body ?? "nil")")
            check(models["n1"]?.accessibilityLabel.contains(finale) == true, "VoiceOver reads the note the row draws")
            check(models["n2"].map { $0.body == $0.sentence } == true, "a blank note adds no paragraph")
            check(models["d1"].map { $0.body == $0.sentence } == true, "no note: the body is the sentence")
            check(models["r1"].map { $0.body == $0.sentence } == true,
                  "a rumour's body is its sentence: the note is its Community Note")
            check(models["r1"]?.accessibilityLabel.contains("Two trade reports") == false,
                  "a rumour's label leaves its note to the note's own box")
            check(models["n1"]?.shareText == "Alpha: \(models["n1"]?.sentence ?? "")", "share text stays the sentence")
            check(models["d1"]?.stamp == Copy.Feed.stampHours(1), "the stamp")

            let pastWhen = TemporalCopy.premiereWhen(now - 2 * day, anchor: .local, now: now)
            check(models["d2"]?.headline == Copy.Feed.headlinePremiered(name: "Season 2", isMovie: false, when: pastWhen),
                  "a passed premiere is told in the past tense")
            check(models["d2"]?.premiereLine == nil, "a passed premiere carries no premiere line")
            check(models["t2"].map { $0.sentence == "\($0.headline)." } == true,
                  "a trailer never announces a premiere that has passed")
            check(models["t3"].map { m in m.premiereLine.map { m.sentence.contains($0) } ?? false } == true,
                  "a trailer with a premiere to come says when")
            check(models["w1"]?.headline == Copy.Feed.headlineWindow(name: "Season 2", isMovie: false, phrase: "in late 2026"),
                  "a year window prints the server's words: \(models["w1"]?.headline ?? "nil")")
            check(models["w2"]?.headline == Copy.Feed.headlineAnnounced(name: "Season 2", isMovie: false),
                  "an unknown window is an announcement, never \"arrives in TBA\"")
            check(models["w3"].map { !$0.headline.contains("2027-01") && $0.headline.contains("2027") } == true,
                  "a month window is formatted from its date, never the raw ISO: \(models["w3"]?.headline ?? "nil")")
        } else {
            check(false, "post-model fixtures decode")
        }

        // MARK: Reply length, as the server counts it (code points of the NFC-trimmed text)

        check(SocialText.count("  hi  ") == 2, "count trims")
        check(SocialText.count("\u{1F44D}\u{1F3FD}") == 2, "an emoji with a skin tone is two code points")
        check(SocialText.count(String(repeating: "\u{1F44D}\u{1F3FD}", count: 141)) == 282, "141 toned emoji are 282")
        check(SocialText.count(String(repeating: "\u{1F44D}\u{1F3FD}", count: 140)) == SocialText.limit, "140 toned emoji fit")
        check(SocialText.count("e\u{301}") == 1, "NFC composes before counting")
        check(SocialText.count("   ") == 0, "whitespace is empty")

        // MARK: Routes

        let routes: [OpenRoute] = [
            .show(franchiseId: "8b0c1f0e-0000-4000-8000-000000000001"),
            .post(postId: "news:0b6c1f0e-0000-4000-8000-000000000002", commentId: nil),
            .post(postId: "catalog:12345", commentId: "c0ffee00-0000-4000-8000-000000000003"),
            .post(postId: "trailer:8b0c1f0e-0000-4000-8000-000000000001:youtube:ldfEtPf3CfQ", commentId: nil),
            .thread(subject: "ep:98765:4", franchiseId: "8b0c1f0e-0000-4000-8000-000000000001",
                    commentId: "c0ffee00-0000-4000-8000-000000000004"),
        ]
        for route in routes {
            check(OpenRoute(encoded: route.encoded) == route, "route round-trip \(route.encoded)")
        }
        check(OpenRoute(encoded: "nonsense") == nil, "a malformed route is nil")
        let ep = ThreadSubject.parseEpisode("ep:98765:4")
        check(ep?.mediaId == 98765 && ep?.episode == 4, "an episode subject parses")
        check(ThreadSubject.parseEpisode("news:abc") == nil, "a news id is not an episode")
        check(ThreadSubject.episode(mediaId: 98765, episode: 4) == "ep:98765:4", "an episode subject is built")
        check(ThreadSubject.catalogMediaId("catalog:77") == 77, "a catalogue id's media id")

        // The Activity deep-link rule (server §5.2).
        let model = AppModel(api: APIClient(tokenProvider: NoTokens()), isolated: true)
        if let reply = notification(["id": "n1", "franchiseId": "f", "kind": "reply", "title": "Alpha", "body": "",
                                     "createdAt": now, "actorCount": 1, "subject": "ep:5:2", "postId": NSNull(),
                                     "commentId": "c9"]),
           let news = notification(["id": "n2", "franchiseId": "f", "kind": "news_dated", "title": "Alpha",
                                    "body": "Season 2 has a date", "createdAt": now, "actorCount": 0, "postId": "news:x"]),
           let plain = notification(["id": "n3", "franchiseId": "f", "kind": "something_new", "title": "Alpha",
                                     "body": "", "createdAt": now, "actorCount": 0]) {
            check(model.openRoute(for: reply) == .thread(subject: "ep:5:2", franchiseId: "f", commentId: "c9"),
                  "a reply opens its thread at the reply")
            check(model.openRoute(for: news) == .post(postId: "news:x", commentId: nil), "news opens its post")
            check(model.openRoute(for: plain) == .show(franchiseId: "f"), "anything else opens the show")
            check(plain.kind == .unknown, "an unknown kind decodes leniently")
            check(AppModel.marked(plain, readAt: now).readAt == now, "a notification marked read")
        } else {
            check(false, "notification fixtures decode")
        }

        // MARK: Words

        func window(_ date: String?, _ precision: ReleaseWindow.Precision) -> ReleaseWindow {
            ReleaseWindow(date: date, precision: precision, sortKey: nil)
        }
        let january = Formatting.formatted(Formatting.utcTimestamp(y: 2027, mo: 1, d: 1) ?? 0, skeleton: "MMMMyyyy",
                                           anchor: .utcDate)
        check(Copy.Feed.windowPhrase(release: "2027-01", window: window("2027-01", .month)) == "in \(january)",
              "window: a month from its date, never the raw ISO")
        let fifth = Formatting.formatted(Formatting.utcTimestamp(y: 2027, mo: 7, d: 5) ?? 0, skeleton: "dMMMMyyyy",
                                         anchor: .utcDate)
        check(Copy.Feed.windowPhrase(release: "Nov 20, 2026", window: window("2027-07-05", .day)) == "on \(fifth)",
              "window: a day from its date, never the release's words")
        check(Copy.Feed.windowPhrase(release: "Summer 2027", window: window("2027-07", .quarter)) == "in summer 2027",
              "window: quarter")
        check(Copy.Feed.windowPhrase(release: "Q3 2027", window: window("2027-07", .quarter)) == "in Q3 2027",
              "window: an initialism keeps its capital")
        check(Copy.Feed.windowPhrase(release: "Late 2026", window: window("2026", .year)) == "in late 2026",
              "window: a year keeps the source's qualifier")
        check(Copy.Feed.windowPhrase(release: "2027", window: window("2027", .year)) == "in 2027", "window: year")
        check(Copy.Feed.windowPhrase(release: "TBA", window: window(nil, .unknown)).isEmpty, "window: unknown is no window")
        check(Copy.Feed.windowPhrase(release: "", window: window("2027-01", .day)).isEmpty,
              "window: a malformed day is no window")

        check(TemporalCopy.premiereHasPassed(now - 2 * day, anchor: .local, now: now), "premiere: two days ago has passed")
        check(!TemporalCopy.premiereHasPassed(now, anchor: .local, now: now), "premiere: today has not passed")
        check(!TemporalCopy.premiereWhen(now - 2 * day, anchor: .local, now: now).hasPrefix("this "),
              "premiere: a past day is never \"this <weekday>\"")

        check(TemporalCopy.feedStamp(now - 30_000, dateOnly: false, now: now) == Copy.Feed.stampNow, "stamp: now")
        check(TemporalCopy.feedStamp(now - 5 * Formatting.minuteMs, dateOnly: false, now: now) == Copy.Feed.stampMinutes(5), "stamp: minutes")
        check(TemporalCopy.feedStamp(now - 2 * hour, dateOnly: false, now: now) == Copy.Feed.stampHours(2), "stamp: hours")
        check(TemporalCopy.feedStamp(now - 3 * day, dateOnly: false, now: now) == Copy.Feed.stampDays(3), "stamp: days")
        let old = TemporalCopy.feedStamp(now - 40 * day, dateOnly: false, now: now)
        check(!old.isEmpty && old != Copy.Feed.stampDays(40), "stamp: a date past a week")
        check(TemporalCopy.feedStamp(now + 5 * Formatting.minuteMs, dateOnly: false, now: now) == Copy.Feed.stampNow,
              "stamp: an instant ahead of the clock is now")
        check(TemporalCopy.feedStamp(now + day, dateOnly: true, now: now) == Copy.Feed.stampToday,
              "stamp: a date-only fact dated ahead is today, never -1d")

        // MARK: The episode gate (iD16)

        func part(progress: Int, releasing: Bool, aired: Int, total: Int, status: String,
                  airings: [Airing] = []) -> FranchisePart {
            FranchisePart(mediaId: 5, kind: .season, sequence: 1, label: "Season 1", title: "Season 1",
                          cover: nil, banner: nil, format: nil, status: status, isReleasing: releasing,
                          totalEpisodes: total, airedEpisodes: aired, nextEpisodeNumber: nil, nextAiringAt: nil,
                          lastAiredAt: nil, synopsis: nil, genres: [], progress: progress, airings: airings)
        }
        let airing = part(progress: 3, releasing: true, aired: 4, total: 12, status: "RELEASING",
                          airings: [Airing(episode: 5, at: now - hour), Airing(episode: 6, at: now + day)])
        check(AppModel.episodeAccess(part: airing, anchor: .local, episode: 3, now: now) == .open, "gate: watched and aired")
        check(AppModel.episodeAccess(part: airing, anchor: .local, episode: 5, now: now) == .unwatched,
              "gate: a slot that struck an hour ago has aired")
        check(AppModel.episodeAccess(part: airing, anchor: .local, episode: 6, now: now) == .unaired, "gate: not aired yet")
        let announced = part(progress: 0, releasing: false, aired: 0, total: 12, status: "NOT_YET_RELEASED")
        check(AppModel.episodeAccess(part: announced, anchor: .local, episode: 1, now: now) == .unaired, "gate: announced")
        let finished = part(progress: 12, releasing: false, aired: 0, total: 12, status: "FINISHED")
        let unknownAired = part(progress: 0, releasing: true, aired: 0, total: 26, status: "RELEASING")
        check(unknownAired.availableEpisodes() == 0, "missing aired count does not expose planned episodes")
        check(!unknownAired.isCaughtUp, "missing aired count cannot establish caught up")
        check(AppModel.episodeAccess(part: finished, anchor: .local, episode: 12, now: now) == .open,
              "gate: a finished season with no aired count is its size")
        // One aired count for the mark and the room: a date-only slot whose synthesised instant
        // has struck is markable, so its room is not "unaired".
        let tmdbDrop = part(progress: 4, releasing: true, aired: 4, total: 10, status: "RELEASING",
                            airings: [Airing(episode: 5, at: now - hour), Airing(episode: 6, at: now + 7 * day)])
        check(tmdbDrop.progressCeiling(now: now, anchor: .utcDate) >= 5
                  && AppModel.episodeAccess(part: tmdbDrop, anchor: .utcDate, episode: 5, now: now) == .unwatched,
              "gate: a struck date-only slot is markable and its room is not unaired")

        // MARK: The write ceiling (only an increase is bounded)

        let aboveAired = part(progress: 12, releasing: true, aired: 5, total: 12, status: "RELEASING")
        check(aboveAired.progressCeiling(now: now, anchor: .local) == 5, "ceiling: five aired")
        check(aboveAired.writeCeiling(now: now, anchor: .local) == 12,
              "a row recorded above the aired count is never pulled down (12, 5 aired → 11 stays 11)")
        check(min(11, aboveAired.writeCeiling(now: now, anchor: .local)) == 11, "unmark 12 → 11 writes 11")
        check(min(14, aboveAired.writeCeiling(now: now, anchor: .local)) == 12, "a batch to 14 does not write backwards")

        // MARK: Excerpts (Sync status titles)

        check(AppModel.excerpt("short", 24) == "short", "a short reply is its own excerpt")
        check(AppModel.excerpt("Did anyone else catch the flashback in the cold open", 24).hasSuffix("\u{2026}"),
              "a long reply is cut with an ellipsis")

        // MARK: Video links (brief §14: the client opens https only)

        for bad in ["javascript:alert(1)", "myapp://open", "http://example.com/v", "https://"] {
            let v = FranchiseVideo(id: "x1", site: "vimeo", kind: .trailer, title: nil, url: bad, thumbnail: bad)
            check(v.watchURL == nil, "a non-https video link is never opened: \(bad)")
            check(v.thumbnailURL == nil, "a non-https video still is never drawn: \(bad)")
        }
        let tube = FranchiseVideo(id: "abc123", site: "youtube", kind: .trailer, title: nil, url: "javascript:alert(1)")
        check(tube.watchURL?.absoluteString == "https://www.youtube.com/watch?v=abc123",
              "a YouTube video with a bad link falls back to its own page")
        let good = FranchiseVideo(id: "x2", site: "vimeo", kind: .trailer, title: nil, url: "https://vimeo.com/1")
        check(good.watchURL?.absoluteString == "https://vimeo.com/1", "an https video link opens")

        print(failures.isEmpty ? "FEED_VERIFY_PASS" : "FEED_VERIFY_FAIL \(failures.joined(separator: " | "))")
    }

    // MARK: - Fixtures (the server's wire shape, server-spec §2.1)

    private static func post(_ id: String, fid: String, kind: String = "announced", fresh: Bool = false,
                             installment: String = "Season 2", isMovie: Bool = false, time: Int64,
                             premiere: [String: Any]? = nil, video: [String: Any]? = nil, official: Bool = false,
                             sources: [[String: Any]] = [], window: [String: Any]? = nil,
                             note: String? = nil) -> [String: Any] {
        [
            "id": id, "kind": kind, "origin": kind == "trailer" ? "video" : "research", "franchiseId": fid,
            "installment": installment, "isMovie": isMovie, "part": NSNull(),
            "time": ["at": time, "dateOnly": false, "basis": "observed"],
            "discoveredAt": time, "fresh": fresh,
            "premiere": premiere ?? NSNull(), "window": window ?? NSNull(), "note": note ?? NSNull(),
            "video": video ?? NSNull(), "sources": sources, "isOfficial": official,
            "viewer": ["liked": false, "saved": false, "reminded": false],
            "counts": ["likes": 2, "comments": 1],
        ]
    }

    private static func franchiseJSON(_ id: String, title: String) -> [String: Any] {
        ["id": id, "source": "anilist", "title": title, "cover": "https://img.example/\(id).jpg",
         "banner": "", "year": 2024, "isReleasing": false, "status": "watching", "upcoming": NSNull()]
    }

    private static func franchise(_ id: String, title: String) -> FeedFranchise? {
        decode(FeedFranchise.self, franchiseJSON(id, title: title))
    }

    private static func summaryJSON(_ id: String) -> [String: Any] {
        ["id": id, "source": "anilist", "title": "Trending \(id)", "isReleasing": true, "partCount": 1]
    }

    private static func summaries(_ ids: [String]) -> [FranchiseSummary] {
        ids.compactMap { decode(FranchiseSummary.self, summaryJSON($0)) }
    }

    private static func response(tab: String, posts: [[String: Any]], prevOpenedAt: Int64,
                                 trending: [String] = []) -> FeedResponse? {
        let body: [String: Any] = [
            "tab": tab, "generatedAt": Int64.nowMs, "prevOpenedAt": prevOpenedAt,
            "capabilities": ["comments": true],
            "franchises": [franchiseJSON("fa", title: "Alpha"), franchiseJSON("fb", title: "Beta")],
            "posts": posts,
            "trending": trending.map(summaryJSON),
        ]
        return decode(FeedResponse.self, body)
    }

    private static func notification(_ body: [String: Any]) -> NotificationItem? {
        decode(NotificationItem.self, body)
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ object: [String: Any]) -> T? {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    /// A transport with no session: the isolated model here never sends a request.
    private struct NoTokens: TokenProvider {
        func currentToken() async -> String? { nil }
        func hasSession() async -> Bool { false }
        func refreshedToken() async -> TokenRefreshOutcome { .notRefreshable }
    }
}
#endif
