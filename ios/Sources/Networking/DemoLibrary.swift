#if DEBUG
import Foundation

/// `-demoBusy 1` — a synthetic library state for CAPTURES, in the same family as `-calmDemo 1`
/// and `-scheduleDemoCounts 1`.
///
/// The QA account is permanently caught up (every watching show sits at `behind: 0`), so the
/// state Today actually exists to serve — a couple of drops waiting, a few shows mid-way through
/// whose run has finished — cannot be photographed from real data without writing fake progress
/// into the user's account. This rewrites the `/me/library` PAYLOAD on the way in instead: no
/// model changes, no writes, and the screen renders it exactly as it would render the real thing.
///
/// The shape it builds (the scenario under review, 6 Sep):
///   - two RELEASING shows whose latest episode struck YESTERDAY and is unwatched (`behind: 1`)
///   - three shows still in progress whose broadcast is OVER (backlog, no airings)
/// Everything else in the library is filed `completed` so it cannot crowd the stack.
enum DemoLibrary {
    static var isOn: Bool {
        UserDefaults.standard.bool(forKey: "demoBusy") || UserDefaults.standard.string(forKey: "todayDemo") == "caught"
    }

    /// Titles are matched by prefix so the fixture survives a catalogue rename.
    // "Daemons of the Shadow Realm" is not in the QA library; Re:ZERO stands in for it,
    // so the fixture has the TWO simultaneous drops the scenario asks for.
    private static let freshTitles = ["Daemons", "Bleach", "Re:ZERO"]
    private static let backlogTitles = ["Game of Thrones", "House of the Dragon", "The Witcher"]

    static func rewriteIfNeeded(path: String, data: Data) -> Data {
        guard isOn, path == "/me/library" else { return data }
        guard var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              var franchises = root["franchises"] as? [[String: Any]] else { return data }

        let todayDemo = UserDefaults.standard.string(forKey: "todayDemo")

        let day: Int64 = 86_400_000                      // the payload's airings are in ms
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        // Yesterday at 20:00 local, so the drop reads "Aired yesterday" rather than "23h ago".
        var cal = Calendar.current
        cal.timeZone = .current
        let yesterday = cal.date(byAdding: .day, value: -1, to: Date()) ?? Date()
        var comps = cal.dateComponents([.year, .month, .day], from: yesterday)
        comps.hour = 20
        let dropAt = Int64((cal.date(from: comps) ?? yesterday).timeIntervalSince1970 * 1000)

        func matches(_ title: String, _ prefixes: [String]) -> Bool {
            prefixes.contains { title.localizedCaseInsensitiveContains($0) }
        }

        for i in franchises.indices {
            let title = franchises[i]["title"] as? String ?? ""
            guard var parts = franchises[i]["parts"] as? [[String: Any]], !parts.isEmpty else { continue }

            // The inactive-library capture is a stocked account whose titles are genuinely
            // unstarted. The regular busy fixture completes every non-focus title to keep the
            // release stack deterministic; reusing that payload left this state with no valid
            // recommendation and therefore a blank screen.
            // `-todayDemo caught`: every Watching show caught up to what has aired, so the calm
            // billboard is what Today shows. Emptying the release deck alone stopped being
            // enough once a backlog took the resting billboard (iteration 2) — the real account
            // always has one, and the "caught up" capture came out as "3 EPISODES BEHIND".
            if todayDemo == "caught" {
                if franchises[i]["status"] as? String == "watching" {
                    for j in parts.indices {
                        let status = parts[j]["status"] as? String ?? ""
                        guard status != "NOT_YET_RELEASED" else { continue }
                        let aired = (parts[j]["airedEpisodes"] as? NSNumber)?.intValue ?? 0
                        let total = (parts[j]["totalEpisodes"] as? NSNumber)?.intValue ?? 0
                        let struck = (parts[j]["airings"] as? [[String: Any]] ?? [])
                            .filter { (($0["at"] as? NSNumber)?.int64Value ?? .max) <= nowMs }
                            .compactMap { ($0["episode"] as? NSNumber)?.intValue }
                            .max() ?? 0
                        let releasing = parts[j]["isReleasing"] as? Bool ?? false
                        parts[j]["progress"] = releasing ? max(aired, struck) : max(total, aired)
                    }
                    franchises[i]["behind"] = 0
                    franchises[i]["parts"] = parts
                }
                continue
            }

            if todayDemo == "inactive" {
                franchises[i]["status"] = "planned"
                franchises[i]["isReleasing"] = false
                franchises[i]["behind"] = 0
                for j in parts.indices {
                    parts[j]["progress"] = 0
                    parts[j]["isReleasing"] = false
                    parts[j]["airings"] = []
                    parts[j]["nextAiringAt"] = nil
                    parts[j]["nextEpisodeNumber"] = nil
                }
                franchises[i]["parts"] = parts
                continue
            }

            if matches(title, freshTitles) {
                franchises[i]["status"] = "watching"
                franchises[i]["isReleasing"] = true
                // The highest-sequence episodic part is the one still on air.
                let idx = parts.indices.max(by: { (parts[$0]["sequence"] as? Int ?? 0) < (parts[$1]["sequence"] as? Int ?? 0) })!
                let watched = max(1, parts[idx]["progress"] as? Int ?? 1)
                let dropped = watched + 1                      // one unwatched episode, out yesterday
                parts[idx]["isReleasing"] = true
                parts[idx]["progress"] = watched
                parts[idx]["airedEpisodes"] = dropped
                parts[idx]["lastAiredAt"] = dropAt
                parts[idx]["totalEpisodes"] = max(dropped + 4, parts[idx]["totalEpisodes"] as? Int ?? 0)
                parts[idx]["nextEpisodeNumber"] = dropped + 1
                parts[idx]["nextAiringAt"] = dropAt + 7 * day
                parts[idx]["nextAiringCount"] = 1
                parts[idx]["airings"] = [
                    ["episode": dropped, "at": dropAt],
                    ["episode": dropped + 1, "at": dropAt + 7 * day],
                ]
                franchises[i]["parts"] = parts
                franchises[i]["behind"] = 1
            } else if matches(title, backlogTitles) {
                franchises[i]["status"] = "watching"
                franchises[i]["isReleasing"] = false
                // Mid-way through a run that has finished airing: no airings, nothing upcoming.
                for j in parts.indices {
                    parts[j]["isReleasing"] = false
                    parts[j]["airings"] = []
                    parts[j]["nextAiringAt"] = nil
                    parts[j]["nextEpisodeNumber"] = nil
                }
                // The first SEASON, never the sequence-0 special: `episodicParts` excludes
                // specials, so a backlog written onto one is invisible to `resumePart` — which
                // is why Game of Thrones and House of the Dragon first came out with no shelf.
                // One of them keeps a RUNNING season whose last drop is older than the
                // out-now window: backlog, but still on air. That is the state the airing dot
                // exists for, and it cannot occur in the two clean buckets.
                let stillAiring = title.localizedCaseInsensitiveContains("Witcher")
                if stillAiring {
                    franchises[i]["isReleasing"] = true
                    if let s = parts.indices.filter({ (parts[$0]["kind"] as? String) == "season" })
                        .max(by: { (parts[$0]["sequence"] as? Int ?? 0) < (parts[$1]["sequence"] as? Int ?? 0) }) {
                        parts[s]["isReleasing"] = true
                        parts[s]["lastAiredAt"] = dropAt - 9 * day        // well outside the window
                        parts[s]["nextAiringAt"] = dropAt + 5 * day
                        parts[s]["airings"] = [["episode": 4, "at": dropAt + 5 * day]]
                    }
                }
                let seasons = parts.indices.filter { (parts[$0]["kind"] as? String) == "season" }
                guard let idx = seasons.min(by: { (parts[$0]["sequence"] as? Int ?? 0) < (parts[$1]["sequence"] as? Int ?? 0) }) else { continue }
                let total = max(8, parts[idx]["totalEpisodes"] as? Int ?? 8)
                parts[idx]["totalEpisodes"] = total
                parts[idx]["airedEpisodes"] = total
                parts[idx]["progress"] = max(1, total / 3)     // a real, resumable backlog
                franchises[i]["parts"] = parts
                franchises[i]["behind"] = 0
            } else {
                // Everything else is done, so the stack is exactly the fixture.
                franchises[i]["status"] = "completed"
                franchises[i]["isReleasing"] = false
                for j in parts.indices {
                    parts[j]["isReleasing"] = false
                    parts[j]["airings"] = []
                    parts[j]["nextAiringAt"] = nil
                    let avail = max(parts[j]["airedEpisodes"] as? Int ?? 0, parts[j]["totalEpisodes"] as? Int ?? 0)
                    parts[j]["progress"] = avail
                }
                franchises[i]["parts"] = parts
                franchises[i]["behind"] = 0
            }
        }
        root["franchises"] = franchises
        _ = nowMs
        return (try? JSONSerialization.data(withJSONObject: root)) ?? data
    }
}

/// Pure artwork regressions, including the two live failure shapes: a titled poster that is
/// in the gallery (Seven Havens) and one omitted by its six-image cap (Percy Jackson).
@MainActor
enum ArtworkIdentityRegression {
    static func run() {
        var passed = 0
        func check(_ condition: Bool, _ name: String) {
            precondition(condition, "Artwork identity regression: \(name)")
            passed += 1
        }
        let titled = ArtworkImage(url: "titled.jpg", source: "tmdb", width: 2000, height: 3000, language: "en")
        let clean = ArtworkImage(url: "clean.jpg", source: "tmdb", width: 1000, height: 1500)
        let legacy = ArtworkImage(url: "legacy.jpg", source: "tmdb")
        let logo = ArtworkImage(url: "logo.png", source: "tmdb", width: 1200, height: 400, language: "en")
        func gallery(_ images: [ArtworkImage]) -> ArtworkGallery {
            ArtworkGallery(portraits: images, landscapes: [], logos: [logo])
        }
        let titledOnly = gallery([titled])
        check(titledOnly.textlessPortrait == nil, "titled art is not clean")
        check(gallery([clean]).textlessPortrait == clean.url, "all-clean gallery needs no English sibling")
        check(gallery([titled, legacy]).textlessPortrait == nil, "missing metadata is not textless")
        check(gallery([titled, legacy, clean]).textlessPortrait == clean.url, "legacy fallback cannot precede clean art")
        check(!ArtworkImage(url: "anilist.jpg", source: "anilist", width: 1000, height: 1500).isTextlessKeyArt,
              "other provider missing language is unknown")
        check(!ArtworkImage(url: "invalid.jpg", source: "tmdb", width: 1000, height: 0).isTextlessKeyArt,
              "invalid dimensions cannot certify art")
        check(BillboardName.resolve(portrait: titled.url, textless: nil, gallery: titledOnly, logo: logo) == .embedded,
              "Seven Havens uses its printed logo, not a text caption")
        check(BillboardName.resolve(portrait: "selected-outside-gallery.jpg", textless: nil, gallery: titledOnly, logo: logo) == .embedded,
              "Percy cannot receive a second logo when the selected poster is unlisted")
        check(BillboardName.resolve(portrait: titled.url, textless: clean.url, gallery: gallery([titled, clean]), logo: logo) == .logo(logo),
              "clean art receives exactly one graphic logo")
        check(BillboardName.resolve(portrait: nil, textless: nil, gallery: nil, logo: nil) == .type,
              "no art retains an identifiable fallback")
        check(BillboardName.resolve(portrait: clean.url, textless: clean.url, gallery: gallery([clean]), logo: nil) == .type,
              "clean art without logo retains a readable fallback")
        check(!BillboardName.embedded.hasGraphicLogo, "embedded identity never requests an overlay")
        let untaggedLogo = ArtworkImage(url: "untagged-arabic.png", source: "tmdb", width: 1674, height: 492)
        let foreignLogo = ArtworkImage(url: "arabic.png", source: "tmdb", width: 2400, height: 800, language: "ar")
        check(ArtworkGallery(portraits: [], landscapes: [], logos: [untaggedLogo, foreignLogo, logo]).preferredLogo == logo,
              "English logo outranks larger untagged and foreign wordmarks")
        check(ArtworkGallery(portraits: [], landscapes: [], logos: [foreignLogo]).preferredLogo == nil,
              "known foreign-only wordmark is not substituted for the English title")
        check(ArtworkGallery(portraits: [], landscapes: [], logos: [untaggedLogo]).preferredLogo == untaggedLogo,
              "unknown-language fallback remains available only without English")
        let percy = PosterTitleCache.titleRegion(lines: [
            ("Disney", CGRect(x: 0.3, y: 0.65, width: 0.4, height: 0.05)),
            ("PERCW", CGRect(x: 0.15, y: 0.71, width: 0.7, height: 0.06)),
            ("JACKSON", CGRect(x: 0.1, y: 0.77, width: 0.8, height: 0.09)),
            ("AND THE OLYMPIANS", CGRect(x: 0.2, y: 0.85, width: 0.6, height: 0.03)),
            ("A NEW SEASON", CGRect(x: 0.2, y: 0.08, width: 0.6, height: 0.03)),
        ], title: "Percy Jackson and the Olympians")
        check(percy == PosterTitleRegion(top: 0.65, bottom: 0.88), "protect the entire wordmark, not an unrelated upper quote")
        check(PosterTitleCache.titleRegion(lines: [], title: "Unknown") == nil, "missing recognition stays an explicit fallback")
        let lowTitle = PosterTitleRegion(top: 0.65, bottom: 0.88)
        func stage(_ region: PosterTitleRegion, headline: CGFloat, controls: CGFloat) -> PosterStage {
            PosterStage(posterHeight: 600, region: region, chromeBottom: 110, headline: headline, controls: controls)
        }
        let split = stage(lowTitle, headline: 62, controls: 44)
        check(split.headlineY + 62 < 600 * lowTitle.top, "Percy news is above its embedded logo")
        check(split.controlsY > 600 * lowTitle.bottom && split.controlsY + 44 <= 600,
              "Percy watched control is below its logo ON the image")
        let seven = stage(.init(top: 0.63, bottom: 0.77), headline: 62, controls: 0)
        check(seven.headlineY > 600 * 0.77 && seven.headlineY + 62 <= 600, "Seven news uses remaining poster space, not a footer")
        let upper = stage(.init(top: 0.1, bottom: 0.27), headline: 40, controls: 160)
        check(upper.posterTop == 0 && upper.nameBottom == 600 * 0.27,
              "full bleed: a title printed across the top stays there, and docks only once it has passed")
        check(upper.headlineY > 600 * 0.27 && upper.controlsY + 160 <= upper.height,
              "upper-title poster keeps both groups on its lower artwork")
        let large = stage(lowTitle, headline: 108, controls: 120)
        check(large.controlsY >= 600 * lowTitle.bottom + PosterStage.gap && large.posterHeight == 600 && large.height > 600,
              "large controls stay BELOW the logo; the stage grows under the poster, never zooming it")
        let expanded = stage(lowTitle, headline: 110, controls: 240)
        check(expanded.headlineY >= 110 && expanded.controlsY + 240 <= expanded.height
              && expanded.controlsY >= 600 * lowTitle.bottom,
              "button-heavy accessibility state keeps its controls under the logo, inside its stage")
        check(stage(lowTitle, headline: 62, controls: 44).height == 600,
              "regular on-poster layout preserves native image size")
        let untitled = stage(.untitled, headline: 90, controls: 100)
        check(untitled.untitled && untitled.posterTop == 0 && untitled.controlsY + 100 <= untitled.height
              && untitled.headlineY > 300, "a poster with no lettering carries the lockup, name included, at its foot")

        // Recommendations decode LENIENTLY: a malformed item drops itself, never the list, and
        // the reason copy is the tile's and the long press's.
        let recJSON = """
        {"items":[
         {"key":"anilist:11061","franchiseId":"f1","source":"anilist","externalId":11061,"title":"Hunter x Hunter (2011)","airing":true,
          "reason":{"kind":"consensus","seeds":[{"franchiseId":"a","title":"Jujutsu Kaisen"},{"franchiseId":"b","title":"Chainsaw Man"}],"count":3},"score":1.2},
         {"title":"no key"},
         {"key":"tmdb:1399","source":"tmdb","externalId":1399,"title":"Game of Thrones",
          "reason":{"kind":"finished","seeds":[{"franchiseId":"c","title":"The Witcher"}]}}
        ],"generatedAt":1}
        """
        let recs = (try? JSONDecoder().decode(RecommendationsResponse.self, from: Data(recJSON.utf8)))?.items ?? []
        check(recs.count == 2, "a malformed recommendation drops itself, not the list")
        check(recs.first?.reason.count == 3 && recs.first?.airing == true && recs.first?.stub != nil,
              "a recommendation's reason, airing state and catalogue stub decode")
        check(recs.last?.franchiseId == nil && recs.last?.reason.count == 1,
              "a title with no show page yet decodes; its count floors at its seeds")
        check(recs.count == 2 && Copy.ForYou.reason(recs[0].reason) == "Like Jujutsu Kaisen and 2 more of yours"
              && Copy.ForYou.reason(recs[1].reason) == "Because you finished The Witcher", "the full reason")
        check(recs.first.map { Copy.ForYou.tileReasons($0.reason).first == "Like Jujutsu Kaisen and 2 more" } ?? false,
              "the tile's reason, longest first")
        let longSeed = RecommendationItem.Reason(kind: .watching,
                                                 seeds: [.init(franchiseId: "s", title: "Mushoku Tensei: Jobless Reincarnation")],
                                                 count: 1)
        check(Copy.ForYou.tileReasons(longSeed).last == "Like Mushoku Tensei",
              "a long seed name keeps its identity half as the tile's last resort")
        print("ARTWORK_IDENTITY_REGRESSIONS_PASS \(passed)")
    }
}

/// Opt-in regressions against the production model and episode-list count, with no network or
/// account writes. Run a DEBUG build with `-verifyAnnouncements 1` and inspect the console.
@MainActor
enum AnnouncementRegression {
    static func run() {
        let now: Int64 = 1_789_862_400_000
        var passed = 0
        func check(_ condition: Bool, _ name: String) {
            precondition(condition, "Announcement regression: \(name)")
            passed += 1
        }
        func part(_ id: Int, total: Int, upcoming: Bool, progress: Int = 0,
                  episodes: [Episode] = [], nextEpisode: Int? = 1,
                  nextAt: Int64? = nil) -> FranchisePart {
            FranchisePart(mediaId: id, kind: .season, sequence: id, label: "Season \(id)",
                          title: "Season \(id)", cover: nil, banner: nil, format: nil,
                          status: upcoming ? "NOT_YET_RELEASED" : "FINISHED", isReleasing: false,
                          totalEpisodes: total, airedEpisodes: upcoming ? 0 : total,
                          nextEpisodeNumber: upcoming ? nextEpisode : nil, nextAiringAt: nextAt,
                          lastAiredAt: nil, synopsis: nil, genres: [], progress: progress,
                          episodes: episodes)
        }
        for total in [0, 1, 8, 13] {
            let announced = part(3, total: total, upcoming: true)
            check(announced.renderableEpisodeCount(now: now) == 0, "announced count \(total)")
            check(EpisodeList.count(announced, now: now) == 0, "no invented row \(total)")
            check(announced.availableEpisodes() == 0 && announced.markTarget(now: now) == 0,
                  "no watch action \(total)")
        }
        let announced = part(3, total: 0, upcoming: true)
        let payload: [String: Any] = ["id": "announcement-regression", "title": "Wednesday",
                                     "status": "completed"]
        let data = try! JSONSerialization.data(withJSONObject: payload)
        let base = try! JSONDecoder().decode(Franchise.self, from: data)
        let franchise = Franchise(copying: base, parts: [
            part(1, total: 8, upcoming: false, progress: 8),
            part(2, total: 8, upcoming: false, progress: 8), announced,
        ])
        check(franchise.resumePart == nil, "announcement is not resumable")
        check(franchise.defaultEpisodeSeason?.mediaId == 2, "browse last released season")
        check(announced.announcementLabel == "Season 3 announced", "explicit announcement")
        let actual = part(1, total: 13, upcoming: true, episodes: [
            Episode(number: 2, title: "Confirmed episode", airDate: now + 86_400_000,
                    overview: nil, still: nil, runtime: nil),
        ])
        check(actual.announcedEpisodeNumbers == [2], "only confirmed episode numbers")
        check(part(1, total: 8, upcoming: false).renderableEpisodeCount(now: now) == 8,
              "released season unchanged")
        check(part(1, total: 0, upcoming: false).renderableEpisodeCount(now: now) == 0,
              "unknown released count stays unknown")
        check(part(3, total: 0, upcoming: true, nextEpisode: nil, nextAt: now + 86_400_000)
            .scheduleAirings.isEmpty, "dated season does not invent calendar episode")
        check(part(3, total: 0, upcoming: true, nextAt: now + 86_400_000)
            .scheduleAirings.map(\.episode) == [1], "confirmed dated premiere retained on calendar")
        let placeholders = (1...13).map {
            Episode(number: $0, title: "Episode \($0)", airDate: now + 86_400_000,
                    overview: nil, still: nil, runtime: nil)
        }
        let ordered = part(1, total: 13, upcoming: true, episodes: placeholders)
        check(ordered.announcedEpisodeNumbers.isEmpty, "dated generic placeholders are not episode details")
        check(EpisodeList.count(ordered, now: now) == 0, "no 13-row placeholder list")

        // Iteration 3: a drop is news only for someone who was already here (`isNews`).
        let day: Int64 = 86_400_000
        func airing(progress: Int, aired: Int, recent: [Int]) -> FranchisePart {
            FranchisePart(mediaId: 90, kind: .season, sequence: 1, label: "Season 1", title: "Season 1",
                          cover: nil, banner: nil, format: nil, status: "RELEASING", isReleasing: true,
                          totalEpisodes: 24, airedEpisodes: aired, nextEpisodeNumber: aired + 1,
                          nextAiringAt: now + 6 * day, lastAiredAt: now - day, synopsis: nil, genres: [],
                          progress: progress,
                          airings: recent.enumerated().map { i, n in Airing(episode: n, at: now - Int64(recent.count - i) * day) })
        }
        let window = AppModel.outNowWindow
        check(!airing(progress: 0, aired: 12, recent: [12]).isNews(now: now, window: window),
              "a cour added at zero with twelve out is a backlog, not news")
        check(airing(progress: 0, aired: 1, recent: [1]).isNews(now: now, window: window),
              "a premiere's first episode is news")
        check(airing(progress: 0, aired: 2, recent: [1, 2]).isNews(now: now, window: window),
              "a double premiere is news")
        check(airing(progress: 9, aired: 12, recent: [12]).isNews(now: now, window: window),
              "a started season's drop is news")
        check(!airing(progress: 1, aired: 24, recent: [24]).isNews(now: now, window: window),
              "started at Episode 1 with 23 behind is a backlog, not news (One Piece at 2 of 1,179)")

        // Iteration 5 (the interactive pass): the spine.
        func spinePart(_ id: Int, _ kind: PartKind, _ seq: Int, _ label: String, rel: String?, total: Int,
                       releasing: Bool = false, progress: Int = 0) -> FranchisePart {
            FranchisePart(mediaId: id, kind: kind, sequence: seq, label: label, title: label, cover: nil, banner: nil,
                          format: nil, relationship: rel, status: releasing ? "RELEASING" : "FINISHED",
                          isReleasing: releasing, totalEpisodes: total, airedEpisodes: total,
                          nextEpisodeNumber: nil, nextAiringAt: nil, lastAiredAt: nil, synopsis: nil, genres: [],
                          progress: progress)
        }
        check(spinePart(1, .season, 2, "Season 2", rel: "SIDE_STORY", total: 12).isMainStory,
              "a TV season the catalogue calls a side story is still the story (One-Punch Man Season 2)")
        check(!spinePart(2, .season, 3, "Log: Fish-Man Island Saga", rel: "SEQUEL", total: 21).isMainStory,
              "a TV-format recap re-edit is not the story")
        check(!spinePart(3, .ova, 2, "Film: Strong World - Episode 0", rel: "PREQUEL", total: 1).isMainStory,
              "a film's promo OVA is not the story")
        let longRunner = Franchise(copying: base, parts: [
            spinePart(10, .season, 1, "TV Series", rel: nil, total: 1179, releasing: true, progress: 1179),
            spinePart(11, .movie, 10, "Film: Strong World", rel: "SEQUEL", total: 1),
            spinePart(12, .ona, 1, "MONSTERS", rel: "PREQUEL", total: 1),
        ])
        check(longRunner.mainStoryMovies.isEmpty, "a running show's films are side stories")
        check(!longRunner.mainStoryEpisodicParts.contains { $0.mediaId == 12 },
              "a one-episode ONA beside seasons is an extra")
        check(longRunner.resumePart == nil, "caught up on a long-runner leaves nothing to resume")

        // 4 Oct: the shorts that air beside a season are extras (Re:ZERO's "Break Time" took
        // Home's billboard as "19 EPISODES LEFT · Ona 4 · Episode 1"), and a finished run nobody
        // started is a backlog, not news.
        func run(_ id: Int, _ kind: PartKind, _ seq: Int, _ label: String, rel: String?, format: String? = nil,
                 total: Int, progress: Int, airedAgo: Int64? = nil) -> FranchisePart {
            FranchisePart(mediaId: id, kind: kind, sequence: seq, label: label, title: label, cover: nil, banner: nil,
                          format: format, relationship: rel, status: "FINISHED", isReleasing: false,
                          totalEpisodes: total, airedEpisodes: total, nextEpisodeNumber: nil, nextAiringAt: nil,
                          lastAiredAt: airedAgo.map { now - $0 }, synopsis: nil, genres: [], progress: progress,
                          airings: airedAgo.map { [Airing(episode: total, at: now - $0)] } ?? [])
        }
        let shorts = run(20, .ona, 4, "Ona 4", rel: "PARENT", total: 19, progress: 0, airedAgo: day)
        let finale = run(21, .season, 5, "Season 4", rel: "SEQUEL", total: 19, progress: 18, airedAgo: day)
        check(!shorts.isMainStory, "an ONA whose one tie is its PARENT is an extra")
        check(shorts.canonicalLabel == "ONA 4", "an initialism is not a word")
        let breakTime = run(22, .season, 6, "Season 6", rel: "PARENT", format: "TV_SHORT", total: 11, progress: 0)
        check(breakTime.isSpinOff && !breakTime.isMainStory, "a short-form series under a PARENT is a spin-off")
        check(finale.isNews(now: now, window: window), "a finale one behind is news")
        check(!shorts.isNews(now: now, window: window), "a finished run never started is a backlog, not news")
        let beside = Franchise(copying: base, parts: [
            run(23, .season, 4, "Season 3", rel: "SEQUEL", total: 16, progress: 16), shorts, finale, breakTime,
        ])
        check(beside.resumePart?.mediaId == finale.mediaId, "the season is resumed, not the shorts beside it")
        check(Franchise(copying: base, parts: [
            run(23, .season, 4, "Season 3", rel: "SEQUEL", total: 16, progress: 16), shorts,
            run(21, .season, 5, "Season 4", rel: "SEQUEL", total: 19, progress: 19), breakTime,
        ]).resumePart == nil, "caught up on the story leaves its shorts out of the queue")

        // "I'm on Season 3" marks Seasons 1–2 and nothing else (`WatchedBatch(before:)`).
        let three = Franchise(copying: base, parts: [
            part(1, total: 10, upcoming: false), part(2, total: 12, upcoming: false),
            part(3, total: 8, upcoming: false), part(4, total: 0, upcoming: true),
        ])
        let before = WatchedBatch(franchise: three, before: three.parts[2], now: now)
        check(Set(before.parts.map(\.mediaId)) == [1, 2] && before.episodeCount == 22,
              "part-way on Season 3 marks the two seasons before it")
        check(before.status == .watching, "part-way leaves the show Watching")
        check(WatchedBatch(franchise: three, before: three.parts[0], now: now).parts.isEmpty,
              "part-way on Season 1 marks nothing")

        // First run places a picked show with the same batches (`FirstRunWrite`): one write per
        // show, whatever the answer.
        let seenAll = FirstRunWrite(three, placement: .caughtUp, now: now)
        check(Set(seenAll.parts.map(\.mediaId)) == [1, 2, 3] && seenAll.status == .completed,
              "first run: caught up on a finished show marks every released season and files it Watched")
        let midway = FirstRunWrite(three, placement: .partWay(seasonId: 2, episode: 5), now: now)
        check(midway.parts == [.init(mediaId: 1, episodes: 10), .init(mediaId: 2, episodes: 5)]
              && midway.status == .watching,
              "first run: part-way marks the seasons before, and the season to its episode")
        check(FirstRunWrite(three, placement: .partWay(seasonId: 2, episode: 99), now: now).parts.last?.episodes == 12,
              "first run: part-way cannot pass what is out")
        let placed = midway.applied(to: three)
        check(placed.parts[0].progress == 10 && placed.parts[1].progress == 5 && placed.effectiveStatus == .watching,
              "first run: the library draws the placement before the server answers")
        let fresh = FirstRunWrite(three, placement: .starting, now: now)
        check(fresh.parts.isEmpty && fresh.status == .watching, "first run: just starting is Watching at zero")
        check(FirstRunWrite(three, placement: .later, now: now).status == .planned, "first run: later is Planned")
        check(FirstRunWrite(three, placement: nil, now: now).status == .planned,
              "first run: a finished show that was not asked about takes the plain add's shelf")
        check(FirstRunModel.asks(three, now: now), "first run: a show with episodes out is asked about")
        check(!FirstRunModel.asks(Franchise(copying: base, parts: [part(1, total: 0, upcoming: true)]), now: now),
              "first run: a show with nothing out is not")
        let onBoard = FirstRunModel.row(placed, ready: (placed.parts[1], 6), now: now)
        check(onBoard.when == .now && onBoard.detail == "Season 2 \u{00B7} Episode 6",
              "first run: a part-way show is on the lineup as its next episode, to watch now")
        check(FirstRunModel.row(seenAll.applied(to: three), ready: nil, now: now).when == .done,
              "first run: a finished show closes the lineup, whatever extras it has left")
        check(FirstRunModel.row(FirstRunWrite(three, placement: .later, now: now).applied(to: three),
                                ready: nil, now: now).when == .later,
              "first run: a show saved for later says so")

        // A series with nothing out yet is NEW, not "Season 1 announced".
        let brandNew = Franchise(copying: base, parts: [part(1, total: 0, upcoming: true)])
        check(brandNew.releaseNews(now: now)?.headline == Copy.Release.newSeries, "new series badge")
        check(franchise.releaseNews(now: now)?.headline != Copy.Release.newSeries,
              "a later season keeps its announcement")

        // The past week by name: "Aired Tuesday", not a date (`fmtDayLong`).
        let twoDaysAgo = now - 2 * day
        let named = Formatting.fmtDayLong(ts: twoDaysAgo, now: now)
        check(named == Formatting.weekdayFull(Formatting.localParts(twoDaysAgo).wd), "past weekday named")
        check(Formatting.fmtDayLong(ts: now - 9 * day, now: now) != Formatting.weekdayFull(Formatting.localParts(now - 9 * day).wd),
              "older dates stay dates")
        print("ANNOUNCEMENT_REGRESSIONS_PASS \(passed)")
    }
}

/// Exercises the real client and bulk-write/Undo paths against an in-memory transport only.
/// No live tokens, server writes, cache writes, or changes to the screen's AppModel.
@MainActor
enum DetailProgressRegression {
    static func run() async {
        let now: Int64 = 1_789_862_400_000
        var passed = 0
        func check(_ condition: Bool, _ name: String) {
            precondition(condition, "Detail progress regression: \(name)")
            passed += 1
        }
        func season(_ id: Int, progress: Int = 0, upcoming: Bool = false, releasing: Bool = false) -> FranchisePart {
            FranchisePart(mediaId: id, kind: .season, sequence: id, label: "Season \(id)", title: "Season \(id)",
                          cover: nil, banner: nil, format: nil,
                          status: upcoming ? "NOT_YET_RELEASED" : (releasing ? "RELEASING" : "FINISHED"),
                          isReleasing: releasing, totalEpisodes: 8, airedEpisodes: upcoming ? 0 : (releasing ? 3 : 8),
                          nextEpisodeNumber: releasing ? 4 : nil, nextAiringAt: releasing ? now + 86_400_000 : nil,
                          lastAiredAt: nil, synopsis: nil, genres: [], progress: progress)
        }
        // A title no real show carries: a failure is filed in Sync status under (command, title),
        // and the check below discards it — it must never merge into, or discard, a real row.
        let payload: [String: Any] = ["id": "00000000-0000-0000-0000-000000000099", "title": "Detail regression", "source": "tmdb",
            "upcoming": ["status": "announced", "next": "Season 3", "release": "Summer 2027",
                         "releaseWindow": ["precision": "quarter", "date": "2027-07", "sortKey": 20270701]]]
        let base = try! JSONDecoder().decode(Franchise.self, from: JSONSerialization.data(withJSONObject: payload))
        let untracked = Franchise(copying: base, parts: [season(1), season(2), season(3, upcoming: true)])
        let news = untracked.releaseNews(now: now)
        check(news?.headline == "Season 3 announced" && news?.detail == "Premieres summer 2027", "untracked news and honest window, with its verb")
        let oldBase = try! JSONDecoder().decode(Franchise.self, from: Data("{\"id\":\"00000000-0000-0000-0000-000000000099\",\"title\":\"Detail regression\"}".utf8))
        let oldLibrary = Franchise(copying: oldBase, parts: [season(1, progress: 3)], status: .watching)
        let refreshed = oldLibrary.grafting(untracked)
        check(refreshed.releaseNews(now: now)?.headline == news?.headline && refreshed.parts.count == 3,
              "fresh catalogue brings new seasons and news")
        check(refreshed.releaseNews(now: now)?.detail == "Returns summer 2027",
              "a show you have been watching RETURNS — the Library's verb, not Premieres")
        check(refreshed.parts.first?.progress == 3 && refreshed.effectiveStatus == .watching, "fresh catalogue preserves live progress")
        for status in WatchStatus.allCases {
            let f = Franchise(copying: untracked, parts: [season(1, progress: 4), season(2), season(3, upcoming: true)], status: status)
            check(f.releaseNews(now: now)?.headline == news?.headline, "news headline independent of \(status)")
        }
        let completed = Franchise(copying: untracked, parts: [season(1, progress: 8), season(2, progress: 8), season(3, upcoming: true)], status: .completed)
        check(completed.releaseNews(now: now)?.headline == news?.headline, "news unchanged after completion")
        let batch = WatchedBatch(franchise: untracked, now: now)
        check(batch.parts == [.init(mediaId: 1, episodes: 8), .init(mediaId: 2, episodes: 8)], "series excludes announced season")
        check(batch.episodeCount == 16 && batch.seasonCount == 2, "exact confirmation counts")
        let one = WatchedBatch(franchise: untracked, seasonID: 2, now: now)
        check(one.parts == [.init(mediaId: 2, episodes: 8)] && one.status == .watching, "one season does not finish series")
        check(WatchedBatch(franchise: completed, now: now).parts.isEmpty, "caught up is a no-op")
        check(WatchedBatch(franchise: untracked, seasonID: 3, now: now).parts.isEmpty, "upcoming is never markable")
        let ongoing = Franchise(copying: untracked, parts: [season(1, releasing: true)])
        let aired = WatchedBatch(franchise: ongoing, now: now)
        check(aired.parts == [.init(mediaId: 1, episodes: 3)] && aired.status == .watching, "releasing season marks aired only")

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ProgressRegressionProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let api = APIClient(baseURL: URL(string: "https://progress-regression.invalid")!, tokenProvider: ProgressRegressionToken(), session: session)
        let model = AppModel(api: api, isolated: true)
        /// The writes are instant now (23 Sep): the result is drawn at once and the server call
        /// runs behind it, so each assertion about the server waits for it to land.
        func settle(_ done: @escaping () -> Bool) async throws {
            for _ in 0..<100 where !done() { try await Task.sleep(for: .milliseconds(20)) }
        }
        /// Until the transport has been quiet for 200 ms: a section's writes (lanes, status
        /// writes, an Undo's) must all have landed before the next section changes the rules.
        func quiesce() async throws {
            var last = -1
            for _ in 0..<50 {
                let now = ProgressRegressionProtocol.store.requestCount
                if now == last { return }
                last = now
                try await Task.sleep(for: .milliseconds(200))
            }
        }
        /// Rows in the app's REAL Sync status that name the test show. An older build of this
        /// runner left two there (23 Sep), which the next launch offered to replay — purged first.
        func leakedRows() -> [FailedChange] {
            SyncCenter.shared.failedChanges.filter { change in
                switch change.intent {
                case .franchiseProgress(let id, _, _, _)?, .progress(let id, _, _)?, .status(let id, _)?,
                     .subscribe(let id, _, _)?, .unsubscribe(let id, _)?:
                    return id == untracked.id
                case .comment(_, _, _, _, let franchiseId, _)?:
                    return franchiseId == untracked.id
                case nil:
                    return false
                }
            }
        }
        for change in leakedRows() { SyncCenter.shared.discard(change.id) }
        ProgressRegressionProtocol.store.reset(untracked)
        do {
            model.markWatched(untracked, batch: batch)
            check(model.isInLibrary(untracked.id), "mark from search adds membership at once")
            check(model.franchise(id: untracked.id)?.parts.map(\.progress) == [8, 8, 0], "progress drawn at once")
            check(model.undo?.count == 16, "one Undo with actual count, at once")
            try await settle { ProgressRegressionProtocol.store.writeCount == 1 && model.savingProgressFor.isEmpty }
            check(model.franchise(id: untracked.id)?.effectiveStatus == .completed, "completed status applied")
            check(ProgressRegressionProtocol.store.writeCount == 1, "one atomic write, not per-season requests")
            if let undo = model.undo { model.undoTapped(undo) }
            check(!model.isInLibrary(untracked.id), "Undo takes the membership back at once")
            try await settle { ProgressRegressionProtocol.store.values == [1: 0, 2: 0, 3: 0] && model.savingProgressFor.isEmpty }
            check(!model.isInLibrary(untracked.id), "Undo restores missing membership")
            check(ProgressRegressionProtocol.store.values == [1: 0, 2: 0, 3: 0], "Undo restores all prior progress")

            ProgressRegressionProtocol.store.reset(untracked)
            model.markWatched(untracked, batch: one)
            check(model.franchise(id: untracked.id)?.parts.map(\.progress) == [0, 8, 0], "season action touches only selected season")
            check(model.savingProgressFor.contains(untracked.id), "busy from the moment the write is queued")
            try await settle { ProgressRegressionProtocol.store.writeCount == 1 && model.savingProgressFor.isEmpty }
            check(ProgressRegressionProtocol.store.values == [1: 0, 2: 8, 3: 0], "season write landed alone")
            try await quiesce()

            let paused = Franchise(copying: untracked, parts: [season(1, progress: 3), season(2), season(3, upcoming: true)], status: .paused)
            model.library = [paused]
            ProgressRegressionProtocol.store.reset(paused)
            model.markWatched(paused, batch: WatchedBatch(franchise: paused, now: now))
            check(model.franchise(id: paused.id)?.parts.map(\.progress) == [8, 8, 0], "in-library batch drawn at once")
            if let undo = model.undo { model.undoTapped(undo) }
            check(model.franchise(id: paused.id)?.effectiveStatus == .paused, "Undo restores prior shelf")
            check(model.franchise(id: paused.id)?.parts.map(\.progress) == [3, 0, 0], "Undo restores partial progress")
            try await settle { ProgressRegressionProtocol.store.values == [1: 3, 2: 0, 3: 0] }
            try await quiesce()
            check(ProgressRegressionProtocol.store.values == [1: 3, 2: 0, 3: 0], "server ends on the Undo")

            // A Planned show you are part-way into: its first mark moves it to Watching, says so
            // on the receipt's second line, and one Undo puts the episode AND the status back.
            let plannedStarted = Franchise(copying: untracked, parts: [season(1, progress: 3), season(2), season(3, upcoming: true)],
                                           status: .planned)
            model.library = [plannedStarted]
            ProgressRegressionProtocol.store.reset(plannedStarted)
            let firstMark = model.markNext(franchiseId: plannedStarted.id)
            check(model.franchise(id: plannedStarted.id)?.effectiveStatus == .watching
                  && model.franchise(id: plannedStarted.id)?.parts.first?.progress == 4,
                  "first mark on a started Planned show moves it to Watching")
            check(firstMark?.subtitle == Copy.Toast.movedTo(WatchStatus.watching.displayName) && firstMark?.customMessage == nil,
                  "the move rides the receipt's second line, the fact stays whole")
            try await quiesce()
            if let firstMark { model.undoTapped(firstMark) }
            check(model.franchise(id: plannedStarted.id)?.effectiveStatus == .planned
                  && model.franchise(id: plannedStarted.id)?.parts.first?.progress == 3,
                  "its one Undo puts the status and the episode back")
            try await quiesce()
            check(ProgressRegressionProtocol.store.values[1] == 3, "the server ends on the Undo")

            // A show filed WATCHED whose story went on: the first mark on the next season moves it
            // back to Watching, and one Undo files it back (review i3, Black Clover's Season 2).
            let watchedReturning = Franchise(copying: untracked, parts: [season(1, progress: 8), season(2), season(3, upcoming: true)],
                                             status: .completed)
            model.library = [watchedReturning]
            ProgressRegressionProtocol.store.reset(watchedReturning)
            let backMark = model.markNext(franchiseId: watchedReturning.id)
            check(model.franchise(id: watchedReturning.id)?.effectiveStatus == .watching
                  && model.franchise(id: watchedReturning.id)?.parts.map(\.progress) == [8, 1, 0],
                  "a mark on a Watched show's next season moves it to Watching")
            check(backMark?.subtitle == Copy.Toast.movedTo(WatchStatus.watching.displayName),
                  "the move back is said on the receipt")
            try await quiesce()
            if let backMark { model.undoTapped(backMark) }
            check(model.franchise(id: watchedReturning.id)?.effectiveStatus == .completed
                  && model.franchise(id: watchedReturning.id)?.parts.map(\.progress) == [8, 0, 0],
                  "its Undo files it back under Watched")
            try await quiesce()

            model.library = []
            model.undo = nil
            ProgressRegressionProtocol.store.reset(untracked, fail: true)
            model.markWatched(untracked, batch: batch)
            try await settle { !model.isInLibrary(untracked.id) && model.savingProgressFor.isEmpty }
            // Membership rolls back (the write rules); the failure is in Sync status with a Retry.
            check(!model.isInLibrary(untracked.id) && model.undo == nil, "failure rolls the membership back")
            check(model.savingProgressFor.isEmpty, "failure releases busy state")
            let filed = model.isolatedFailures.filter {
                if case .franchiseProgress(let id, _, _, _)? = $0 { return id == untracked.id }
                return false
            }
            check(filed.count == 1 && model.isolatedFailures.count == 1, "failure is filed once, with its exact write")
            try await quiesce()
            check(leakedRows().isEmpty, "a scratch model files nothing in the app's Sync status")
            let intent = WriteIntent.franchiseProgress(franchiseId: untracked.id, parts: batch.parts, status: batch.status, removeMembership: false)
            let decoded = try JSONDecoder().decode(WriteIntent.self, from: JSONEncoder().encode(intent))
            check(decoded == intent, "failed bulk write can persist and replay")
            print("DETAIL_PROGRESS_REGRESSIONS_PASS \(passed)")
        } catch { preconditionFailure("Detail progress regression transport: \(error)") }
    }
}

private struct ProgressRegressionToken: TokenProvider {
    func currentToken() async -> String? { "in-memory-test-only" }
    func hasSession() async -> Bool { true }
    func refreshedToken() async -> TokenRefreshOutcome { .notRefreshable }
}

private final class ProgressRegressionStore: @unchecked Sendable {
    private let lock = NSLock()
    private var progress: [Int: Int] = [:]
    private var status: WatchStatus?
    private var fail = false
    private var writes = 0
    private var requests = 0
    var values: [Int: Int] { lock.withLock { progress } }
    var writeCount: Int { lock.withLock { writes } }
    var requestCount: Int { lock.withLock { requests } }
    func reset(_ f: Franchise, fail: Bool = false) {
        lock.withLock {
            progress = Dictionary(uniqueKeysWithValues: f.parts.map { ($0.mediaId, $0.progress) })
            status = f.status; self.fail = fail; writes = 0
        }
    }
    func respond(to request: URLRequest) -> (Int, Data) {
        lock.withLock {
            precondition(request.url?.host == "progress-regression.invalid", "Mock must never reach a live host")
            requests += 1
            if fail { return (400, Data("{\"error\":\"test failure\"}".utf8)) }
            if request.httpMethod == "DELETE" {
                status = nil
                return (200, Data("{\"ok\":true}".utf8))
            }
            var data = request.httpBody ?? Data()
            if data.isEmpty, let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    guard count > 0 else { break }
                    data.append(buffer, count: count)
                }
            }
            let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            // An in-library batch writes per part (`PUT /me/progress`) and its status separately.
            if let mediaId = body["mediaId"] as? Int, let episodes = body["episodes"] as? Int {
                progress[mediaId] = episodes
                return (200, Data("{\"ok\":true}".utf8))
            }
            if request.httpMethod == "PATCH" || request.httpMethod == "POST" {
                if let raw = body["status"] as? String { status = WatchStatus(rawValue: raw) }
                return (200, Data("{\"ok\":true}".utf8))
            }
            guard let parts = body["parts"] as? [[String: Int]] else {
                preconditionFailure("Detail progress regression: unexpected \(request.httpMethod ?? "") \(request.url?.path ?? "")")
            }
            for part in parts { progress[part["mediaId"]!] = part["episodes"]! }
            if let raw = body["status"] as? String { status = WatchStatus(rawValue: raw) }
            writes += 1
            let response = FranchiseProgressResponse(ok: true, franchiseId: request.url!.deletingLastPathComponent().lastPathComponent,
                                                     status: status, progress: progress.sorted { $0.key < $1.key }.map { .init(mediaId: $0.key, episodes: $0.value) })
            return (200, try! JSONEncoder().encode(response))
        }
    }
}

private final class ProgressRegressionProtocol: URLProtocol, @unchecked Sendable {
    static let store = ProgressRegressionStore()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, data) = Self.store.respond(to: request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
#endif
