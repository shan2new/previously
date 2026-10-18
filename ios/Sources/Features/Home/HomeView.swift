import SwiftUI

// Home — the departures board (26 Sep 2026).
//
// "I think the today screen should become Feed… feed should not be the home screen for sure"
// (owner). Home answers the reason the app is opened — what can I watch now — in the order a
// person acts on it:
//   · the BILLBOARD — the next thing to watch, full bleed, as the old Today's was ("let's make it
//     like the full bleed art it was earlier", owner): a drop you have not seen, else the newest
//     episode out this week you have not marked, else the top of your queue — and only when nothing
//     is out at all, the next airing (`HomeCompose`);
//   · RECENTLY AIRED — the past week's episodes you have not marked ("what about previous week /
//     unmarked episodes?", owner), each one tap from marked;
//   · UP NEXT — the rest of your queue as the Library's poster cards, at the episode you left off,
//     including the shows that are NOT airing — which a calendar never shows.
// The calendar is not here: it is the Schedule TAB again (26 Sep, "combining home with Schedule was a
// bad decision… Some people specifically want the schedule view as the muscle memory", owner), and
// "This week" went with the push that it opened. Each show appears once, in the first place that
// carries it. It is short by construction: it lists what can be acted on, so it is never a wall.
//
// A mark is an EVENT here (26 Sep, "it doesn't feel as delightful as it should be", owner): the
// control fills and says so for a beat (`commitBeat`), then the write lands and what it changed
// rolls — the episode, the count, the bar — and whatever it finished leaves its place (a row, a
// tile, the billboard handing over to the next thing).
struct HomeView: View {
    let onOpenDetail: (_ franchiseId: String, _ zoomID: String, _ focus: EpisodeFocus?) -> Void
    /// Selects the Schedule tab (Recently aired's chevron, the caught-up state's button).
    let onOpenSchedule: () -> Void
    let onOpenLibrary: (WatchStatus) -> Void
    let onOpenRoute: (FeedRoute) -> Void
    let onAddShow: () -> Void
    /// The empty account's button: first run's picker (a wall of shows to tap), not a bare field.
    var onPickShows: (() -> Void)? = nil
    /// The Discover tab — the For you shelves' way to more (the directions).
    var onOpenDiscover: () -> Void = {}
    /// Bumped when Home is re-selected: every sheet goes, and the page goes to its top.
    let topSignal: Int
    /// Bumped by the notification route: every sheet goes (the route then pushes).
    let dismissSignal: Int

    @Environment(AppModel.self) private var appModel
    @Environment(LaunchHandoff.self) private var launch: LaunchHandoff?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The bar's state, owned by `MainTabView`: the tab bar rides it away with a scroll.
    let chrome: HomeChrome
    @State private var box = HomeFeedBox()
    @State private var showProfile = false
    /// Four tabs: the feed's Activity, from Home's bell; a picked row opens once the sheet has gone.
    @State private var showActivity = false
    @State private var pendingActivityRoute: OpenRoute?
    /// A feed page asked for from inside Profile (Saved → a post): opened once the sheet has gone.
    @State private var pendingRouteAfterSheet: FeedRoute?
    /// A mark that covers more than one episode waits for its exact count to be confirmed.
    @State private var prompt: FranchiseDetailView.WritePrompt?
    /// Marks mid-flight — the billboard's, a tile's (franchise id), a row's (airing id).
    @State private var committingHero = false
    @State private var committingTiles: Set<String> = []
    @State private var committingRows: Set<String> = []
    @State private var artMarked = false
    /// The billboard art's palette colour, with the picture it was read from: the page's ground and
    /// the bars are painted from it. Kept beside its picture — a hand-off's first frames wore the
    /// LAST show's colour until the next one's had been read.
    @State private var heroTint: (art: String, color: Color?)?
    /// The picture each show's billboard settled on (`HomeBillboard.settle`), by franchise id.
    @State private var heroArts: [String: String] = [:]
    /// The billboard page in front (a franchise id) when the week's drops page (`HomeBillboardPager`);
    /// the page's ground and the bars follow it.
    @State private var heroPage: String?
    /// RINGS (`RecentDirection`): the story viewer, opened from Recently aired's rings as the feed's
    /// tray opens it — the ring turns while the first picture loads (≤ 0.9 s), then the story.
    @State private var story: StoryLaunch?
    @State private var storyLoading: String?
    @State private var storyReels: [StoryReel] = []
    @State private var storyTask: Task<Void, Never>?
    @State private var storyOrigins = StoryOrigins()

    private enum Anchor {
        static let top = "home/top"
    }

    /// How long a control holds its marked state before the write lands and the page moves on —
    /// the episode list's `beginCommit` hold.
    private static let commitBeat: Duration = .milliseconds(550)

    /// A section title's line (`sectionTitle`), growing with the text size.
    @ScaledMetric(relativeTo: .title3) private var sectionTitleLine: CGFloat = 25

    /// The tab bar's top edge, in the window.
    private var barTop: CGFloat { ThemeMetrics.windowHeight - ThemeMetrics.tabBarVisualHeight }

    /// The billboard's height (26 Sep, "make the art take more height", owner): the screen above the
    /// tab bar, less the next section's TITLE — which peeks under its foot so the page says there is
    /// more — and nothing of that section's cards. Measured from the bar, not a share of the window:
    /// at 0.84 the first card's top fifteen points stood on the bar's edge with half a NEW tag ("the
    /// bottom nav looks weird when there is a recently aired item", owner, 4 Oct). The same height
    /// with nothing under it: the lockup keeps its place when a mark empties the page (the frame
    /// must not grow under a hand-off), and the receipt lane clears the mark.
    private var billboardHeight: CGFloat {
        (barTop - ThemeSpace.x4 - sectionTitleLine - ThemeMetrics.labelGap + Self.cardTuck).rounded()
    }

    /// How far the first card starts under the bar's edge, so not a hairline of it shows at rest.
    private static let cardTuck: CGFloat = 3

    private var band: CGFloat { ThemeMetrics.topSafeInset + FeedMetrics.headerRow }

    /// The QUIET card's height (9 Oct): nothing is out, so the top of the queue or the next airing
    /// is shown shorter than the stage — about half the window — with its state as a label, not a
    /// badge. The full bleed is for drops.
    private var quietHeight: CGFloat { (billboardHeight * 0.56).rounded() }

    /// What the billboard takes: the stage for drops, the quiet card otherwise, nothing when clear.
    private func billboardHeight(_ feed: HomeFeed) -> CGFloat {
        if !feed.heroes.isEmpty { return billboardHeight }
        return feed.quiet == nil ? 0 : quietHeight
    }

    /// The show the page is painted from: the page in front when the drops page, else the lead.
    private func currentHero(_ feed: HomeFeed) -> HomeHero? {
        feed.heroes.first { $0.franchise.id == heroPage } ?? feed.hero
    }

    /// A show's billboard picture: what its billboard settled on, else the show's stored pick
    /// (`PosterPick`), else the catalogue's selection.
    private func heroArt(of f: Franchise) -> String? {
        if let settled = heroArts[f.id] { return settled }
        if let pick = PosterPick.shared.choice(for: f) { return WideArt.billboard(portrait: pick.url, landscape: nil).url }
        return f.billboardArt.url
    }

    /// The billboard in front's picture.
    private func heroArt(_ feed: HomeFeed) -> String? {
        currentHero(feed).flatMap { heroArt(of: $0.franchise) }
    }

    /// A show's art colour — resolved this visit, else remembered from the last (`PaletteCache`
    /// persists), so the page opens in its colour on the first frame.
    private func tint(of f: Franchise) -> Color? {
        let art = heroArt(of: f)
        if let heroTint, heroTint.art == art, let color = heroTint.color { return color }
        return PaletteCache.shared.tint(for: art)
    }

    /// The billboard in front's colour.
    private func tint(_ feed: HomeFeed) -> Color? {
        currentHero(feed).flatMap { tint(of: $0.franchise) }
    }

    /// How hard the bar's veil is drawn over the art: the billboard's own protection, from the
    /// picture's lightness (`PaletteCache` holds it once the tint has been read).
    private func veil(_ feed: HomeFeed) -> Double? {
        guard feed.hasBillboard else { return nil }
        return HeroProtection.strength(lightness: PaletteCache.shared.lightness(for: heroArt(feed)))
    }

    /// The shows whose pictures Home is about to draw: the billboard's pages first, then Recently
    /// aired's (a mark hands the billboard to the next of them), then the shelf's.
    private func pickShows(_ feed: HomeFeed) -> [Franchise] {
        feed.heroes.map(\.franchise) + [feed.quiet?.franchise].compactMap { $0 }
            + feed.recent.map(\.entry.franchise) + feed.queue.map(\.franchise)
    }

    /// A show's hue at canvas depth — where its billboard lands.
    private func groundTop(of f: Franchise) -> Color {
        DetailTint.ground(tint(of: f), lightness: DetailTint.groundTopLightness)
    }

    /// The show's hue at canvas depth — where the billboard lands (canvas with no billboard).
    private func groundTop(_ feed: HomeFeed) -> Color {
        guard let hero = currentHero(feed) else { return ThemeColor.canvas }
        return groundTop(of: hero.franchise)
    }

    /// What the page stands on — the bars draw the same ground (`HomeGroundWindow`).
    private func pageGround(_ feed: HomeFeed) -> HomePageGround {
        guard feed.hasBillboard else { return .canvas }
        return .show(tint: tint(feed), top: groundTop(feed), billboard: billboardHeight(feed))
    }

    /// Composed once per library and minute — never in a body.
    private var feed: HomeFeed {
        let key = appModel.scheduleFeedKey
        let experience = appModel.experience
        if box.key == key, box.experience == experience { return box.value }
        let value = HomeCompose.feed(appModel)
        box.key = key
        box.experience = experience
        box.value = value
        return value
    }

    // MARK: - Body

    var body: some View {
        let feed = feed
        let billboard = billboardHeight(feed)
        let ground = pageGround(feed)
        ScrollViewReader { proxy in
            ZStack(alignment: .top) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Color.clear.frame(height: 0).id(Anchor.top)
                        content(feed)
                    }
                    .background(alignment: .top) {
                        if feed.hasBillboard {
                            HomeGround(tint: tint(feed), top: groundTop(feed), billboard: billboard)
                                .animation(ThemeMotion.uiPoster, value: tint(feed) == nil)
                                // The ground follows the page in front as the drops page.
                                .animation(ThemeMotion.uiPoster, value: heroPage)
                        }
                    }
                    // The scroll probe: WRITES the bar's one fact, never screen state.
                    .background {
                        Color.clear.onGeometryChange(for: CGFloat.self) { proxy in
                            proxy.frame(in: .global).minY
                        } action: { minY in
                            chrome.track(contentTop: minY, billboard: billboard)
                        }
                    }
                }
                // Keep the billboard full bleed at the top; the compact navigation reserve
                // stops cards above the icon row, rather than letting artwork compete with it.
                .ignoresSafeArea(edges: .top)
                .scrollIndicators(.hidden)
                // The calm page goes out under both transparent bars rather than reading through them.
                .modifier(HomeEdgeFadeModifier(chrome: chrome, enabled: appModel.experience.calm))
                .onScrollPhaseChange { _, phase in chrome.phase(phase) }
                .laneClearance(appModel, base: ThemeSpace.x3)
                .previouslyRefreshable { await appModel.reload() }

                HomeHeader(chrome: chrome,
                           ground: ground,
                           veil: veil(feed),
                           onActivity: appModel.experience.feedInHome ? { showActivity = true } : nil,
                           unread: appModel.activityUnread,
                           onProfile: { showProfile = true },
                           onTop: { scrollToTop(proxy) })
            }
            // The tab bar's ground is Home's: the page's own, seen through the bar, so the icons
            // stand on exactly what is behind them and no card shows under them. The root's bar
            // draws no ground here (`TabBarGroundKey` is clear).
            .overlay(alignment: .bottom) {
                HomeFootGround(chrome: chrome, ground: ground, barTop: barTop)
                    .alignmentGuide(.bottom) { $0[.top] }
            }
            .onChange(of: topSignal) { _, _ in
                dismissAll()
                scrollToTop(proxy)
            }
            #if DEBUG
            // `-homeAnchor recent|upnext|news` (DEBUG): a capture scrolled to a section.
            .task(id: appModel.library.isEmpty) {
                guard !appModel.library.isEmpty, let anchor = UserDefaults.standard.string(forKey: "homeAnchor") else { return }
                try? await Task.sleep(for: .milliseconds(1200))
                proxy.scrollTo("home/\(anchor)", anchor: UnitPoint(x: 0.5, y: 0.12))
            }
            #endif
        }
        .background(AppGround())
        .preference(key: TabBarGroundKey.self, value: Color.clear)
        // The bar is Home's own; no system edge effect and no system navigation bar under it.
        .chromeScrollEdgeHidden(.all)
        .toolbar(.hidden, for: .navigationBar)
        .fullScreenCover(item: $story) { start in
            StoryViewer(reels: storyReels, start: start, origins: storyOrigins,
                        onOpenShow: { id in
                            closeStory()
                            onOpenDetail(id, "story/\(id)", nil)
                        },
                        onClose: { closeStory() })
                .presentationBackground(.clear)
        }
        .sheet(isPresented: $showActivity, onDismiss: activityDismissed) {
            ActivitySheet(onOpen: { route in
                pendingActivityRoute = route
                showActivity = false
            })
            .perfScreen("Activity")
        }
        .sheet(isPresented: $showProfile, onDismiss: profileDismissed) {
            ProfileView(onOpenLibrary: { status in
                            showProfile = false
                            onOpenLibrary(status)
                        },
                        onOpenDetail: { id in
                            showProfile = false
                            onOpenDetail(id, "profile/\(id)", nil)
                        })
                .environment(\.openFeedRoute, { route in
                    pendingRouteAfterSheet = route
                    showProfile = false
                })
                .perfScreen("Profile")
        }
        // An alert, not a popover: a batch changes a number the user did not type (Schedule's rule).
        .alert(prompt?.title ?? "", isPresented: Binding(get: { prompt != nil }, set: { if !$0 { prompt = nil } }),
               presenting: prompt) { p in
            Button(p.confirm) { p.perform() }
            Button(Copy.Confirm.cancel, role: .cancel) {}
        } message: { p in
            Text(p.message)
        }
        .onChange(of: dismissSignal) { _, _ in dismissAll() }
        .onChange(of: showProfile) { _, open in
            if appModel.feedOverlayOpen != open { appModel.feedOverlayOpen = open }
        }
        // Nothing to wait for (no billboard, an empty or failed library): the launch may leave.
        .onChange(of: !feed.hasBillboard && !(appModel.loading && appModel.library.isEmpty), initial: true) { _, nothing in
            if nothing { markArtReady() }
        }
        .task(id: heroArt(feed)) {
            guard let url = heroArt(feed) else { return }
            let resolved = await PaletteCache.shared.resolve(url: url, maxPixel: 360)
            withAnimation(ThemeMotion.uiPoster) { heroTint = (url, resolved) }
        }
        // Each show's picture is chosen by eye (`PosterPick`, graded once and kept): the
        // billboard's show first — the billboard waits a moment for it — then the rest, in the
        // order they could take the billboard.
        .task(id: pickShows(feed).map(\.id).joined(separator: ",")) {
            let shows = pickShows(feed)
            for show in shows { await PosterPick.shared.resolve(show) }
            // The billboard's other pages, and the shows a mark could hand the billboard to: their
            // pictures and colours are read now, so a swipe or a hand-off is the next picture
            // arriving — it was an empty frame in the last show's colour for as long as a 2,000-px
            // poster takes to download (4 Oct).
            for show in feed.heroes.dropFirst().map(\.franchise)
                + [feed.recent.first?.entry.franchise, feed.queue.first?.franchise].compactMap({ $0 }) {
                await warmBillboard(show)
            }
        }
        .onAppear {
            #if DEBUG
            if FeedCapture.openProfile { showProfile = true }
            #endif
        }
    }

    // MARK: - Content

    @ViewBuilder
    private func content(_ feed: HomeFeed) -> some View {
        if appModel.loading && appModel.library.isEmpty {
            SkeletonGate(isLoading: true) { skeleton } content: { EmptyView() }
        } else if appModel.library.isEmpty {
            EmptyState(appModel.loadError
                       ? (SyncCenter.shared.isOnline ? .serverNoCache : .offlineNoData)
                       : .emptyHome,
                       prominence: .major,
                       artwork: .flapBoard,
                       primary: appModel.loadError ? { Task { await appModel.reload() } } : (onPickShows ?? onAddShow))
                .padding(.horizontal, ThemeMetrics.gutter)
                .padding(.top, band + ThemeSpace.x10 * 2)
        } else if feed.isEmpty {
            if appModel.experience.calm {
                calmCaughtUp
            } else if appModel.experience.doors {
                // The directions: caught up is one line and the way to Schedule, then shows for you —
                // the moment someone most needs a next show is the moment Home has nothing of theirs.
                // Stage's language leads with a picture (17 Oct: "the home looks really shitty in
                // this state", owner — a card for tonight, then nothing): with nothing of yours out,
                // the stage is the show you would most likely start, edge to edge. Calm has none.
                let lead = appModel.experience.stage ? HomeForYou.lead(appModel) : nil
                if let lead {
                    ForYouTopPick(item: lead, reason: appModel.spokenReason(lead), fullBleed: true) {
                        openRecommendation(lead)
                    }
                    .rootArrival(0)
                }
                caughtUpDoors(afterLead: lead != nil).rootArrival(1)
                if appModel.experience.feedInHome {
                    HomeNews(onOpenPost: { onOpenRoute(.post(id: $0)) },
                             onOpenShow: { onOpenDetail($0, "home-news/\($0)", nil) },
                             onSeeAll: { onOpenRoute(.news) })
                        .id("home/news")
                        .rootArrival(2)
                }
                HomeForYou(leading: false, excluding: lead?.key, onOpen: openRecommendation, onSeeAll: onOpenDiscover)
                    .rootArrival(3)
            } else {
                caughtUp
            }
        } else {
            if feed.heroes.count > 1 {
                // The week's drops, paged (9 Oct). The pager is keyed on its SHOWS: a mark rolls a
                // page in place; a show caught up leaves with the handoff.
                HomeBillboardPager(heroes: feed.heroes, page: $heroPage, now: appModel.nowMinute,
                                   height: billboardHeight, band: band, committing: committingHero,
                                   tint: { tint(of: $0.franchise) }, landing: { groundTop(of: $0.franchise) },
                                   onOpen: { open($0) },
                                   onMark: { markHero($0) },
                                   onArtLoaded: markArtReady,
                                   onCopyTop: { chrome.trackCopy(top: $0) },
                                   onArt: { hero, url in heroArts[hero.franchise.id] = url },
                                   onLightingChange: { chrome.trackLighting($0) })
                    .id(feed.heroes.map(\.franchise.id).joined(separator: "|"))
                    .transition(.handoff(reduceMotion: reduceMotion))
            } else if let hero = feed.hero {
                // One drop: the stage. Nothing out: the QUIET card — the top of the queue or the
                // next airing, shorter and badge-less, so the full bleed keeps its meaning.
                let quiet = feed.heroes.isEmpty
                HomeBillboard(hero: hero, now: appModel.nowMinute, height: billboardHeight(feed), band: band,
                              committing: committingHero,
                              tint: tint(feed), landing: groundTop(feed),
                              onOpen: { open(hero) },
                              onMark: { markHero(hero) },
                              onArtLoaded: markArtReady,
                              onCopyTop: { chrome.trackCopy(top: $0) },
                              onArt: { url in heroArts[hero.franchise.id] = url },
                              onLightingChange: { chrome.trackLighting($0) },
                              quiet: quiet)
                    .franchiseQuickActions(appModel.isInLibrary(hero.franchise.id) ? hero.franchise : nil,
                                           appModel: appModel)
                    // A new show on the billboard (the last one caught up): the old picture leaves,
                    // THEN the next arrives — the app's handoff, never two titles at half opacity.
                    .id((quiet ? "quiet/" : "") + hero.franchise.id)
                    .transition(.handoff(reduceMotion: reduceMotion))
            } else {
                Color.clear.frame(height: band)
            }
            if appModel.sectionFailed {
                InlineNotice(Copy.Notice.today) { Task { await appModel.reload() } }
                    .padding(.horizontal, ThemeMetrics.gutter)
                    .padding(.top, ThemeSpace.x3)
            }
            // The first section under the billboard sits close to its mark (the old Today's x4: the
            // pill to the next header ≈ 36 pt), the rest a section's gap apart.
            let lead = feed.hero != nil
            if !feed.recent.isEmpty { recent(feed.recent, leading: lead).rootArrival(1) }
            if !feed.queue.isEmpty { upNext(feed.queue, leading: lead && feed.recent.isEmpty).rootArrival(2) }
            if appModel.experience.feedInHome {
                // Four tabs: the feed is Home's News section (its page is "News ›").
                HomeNews(style: newsStyle,
                         onOpenPost: { onOpenRoute(.post(id: $0)) },
                         onOpenShow: { onOpenDetail($0, "home-news/\($0)", nil) },
                         onSeeAll: { onOpenRoute(.news) })
                    .id("home/news")
                    .rootArrival(3)
            }
            if appModel.experience.doors {
                // The directions: your shows first, then shows for you — one shelf in the calm
                // language, two in Stage's.
                HomeForYou(leading: !lead && feed.recent.isEmpty && feed.queue.isEmpty,
                           compact: appModel.experience.calm,
                           onOpen: openRecommendation, onSeeAll: onOpenDiscover)
                    .rootArrival(4)
            }
        }
    }

    /// The calm language's news is headlines; Stage keeps its shelf of cards.
    private var newsStyle: HomeNews.Style { appModel.experience.calm ? .rows : .shelf }

    /// Caught up in the calm language (19 Oct, "greeted with overwhelm", owner): today's next airing on
    /// one of your shows as the page's one card — else the caught-up line, which a card would only
    /// contradict — then today's news, if any, and one shelf for you.
    @ViewBuilder private var calmCaughtUp: some View {
        Group {
            if let e = HomeComingUp.today(appModel) {
                HomeComingUpCard(entry: e, now: appModel.nowMinute) {
                    onOpenDetail(e.franchise.id, "home-coming/\(e.franchise.id)",
                                 EpisodeFocus(mediaId: e.part.mediaId, episode: e.episode))
                }
            } else {
                HomeCaughtUp()
            }
        }
        .padding(.horizontal, ThemeMetrics.gutter)
        .padding(.top, band + ThemeSpace.x5)
        .rootArrival(1)
        if appModel.experience.feedInHome {
            HomeNews(style: newsStyle,
                     onOpenPost: { onOpenRoute(.post(id: $0)) },
                     onOpenShow: { onOpenDetail($0, "home-news/\($0)", nil) },
                     onSeeAll: { onOpenRoute(.news) })
                .id("home/news")
                .rootArrival(2)
        }
        HomeForYou(leading: false, compact: true, onOpen: openRecommendation, onSeeAll: onOpenDiscover)
            .rootArrival(3)
    }

    /// The directions' caught-up line (`Experience.doors`): said once, with the next airing as the way
    /// to Schedule — Home never draws the future itself.
    private func caughtUpDoors(afterLead: Bool) -> some View {
        VStack(alignment: .leading, spacing: ThemeSpace.x2) {
            Text(Copy.Home.caughtUpLine)
                .type(ThemeType.sectionTitle)
                .foregroundStyle(ThemeColor.textPrimary)
            if let next = nextAiring {
                Button(action: onOpenSchedule) {
                    HStack(spacing: ThemeSpace.x1) {
                        Text(Copy.Home.nextAiring(next.franchise.displayTitle,
                                                  TemporalCopy.airs(at: next.at, now: appModel.nowMinute,
                                                                    source: next.franchise.source)))
                            .lineLimit(2)
                        AppGlyph(systemName: "chevron.forward")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .type(ThemeType.metadata)
                    .foregroundStyle(ThemeColor.textSecondary)
                    .frame(minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, ThemeMetrics.gutter)
        .padding(.top, afterLead ? ThemeSpace.x4 : band + ThemeSpace.x6)
    }

    /// The next airing on the calendar, for the caught-up line.
    private var nextAiring: AppModel.ScheduleEntry? {
        appModel.scheduleDays.filter { $0.id >= 0 }.lazy.flatMap { $0.entries.filter { !$0.aired } }.first
    }

    private func openRecommendation(_ r: RecommendationItem) {
        Task {
            if let id = await appModel.franchiseId(for: r) { onOpenDetail(id, "home-foryou/\(r.key)", nil) }
        }
    }

    /// Nothing out, nothing queued, nothing airing this week: the board is clear — said once, calmly,
    /// with the way to the Schedule tab.
    private var caughtUp: some View {
        EmptyState(Copy.Home.caughtUp, prominence: .major, primary: onOpenSchedule)
            .padding(.horizontal, ThemeMetrics.gutter)
            .padding(.top, band + ThemeSpace.x10 * 2)
    }

    // MARK: - Recently aired

    /// The past week's episodes you have not marked: the agenda's own row with the day in its date
    /// column and the ring — the one next step on the row — to mark it. A marked row leaves.
    @ViewBuilder
    private func recent(_ items: [HomeAiring], leading: Bool) -> some View {
        switch RecentDirection.active {
        case .rows: recentRows(items, leading: leading)
        case .drops: recentDrops(items, leading: leading)
        case .rings: recentRings(items, leading: leading)
        }
    }

    /// DROPS: a shelf of the shows' scenes, newest drop first. A single drop is not a shelf: its
    /// card runs gutter to gutter.
    private func recentDrops(_ items: [HomeAiring], leading: Bool) -> some View {
        VStack(alignment: .leading, spacing: ThemeMetrics.labelGap) {
            // The directions: the week behind is Home's alone; Schedule starts at today.
            SectionHeaderRow(Copy.Home.recentlyAired, action: appModel.experience.doors ? nil : onOpenSchedule)
                .padding(.horizontal, ThemeMetrics.gutter)
            if items.count == 1, let item = items.first {
                dropCard(item, width: ThemeMetrics.windowWidth - 2 * ThemeMetrics.gutter)
                    .padding(.horizontal, ThemeMetrics.gutter)
                    .transition(.scale(scale: 0.94).combined(with: .opacity))
            } else {
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: ThemeMetrics.shelfGap) {
                        ForEach(items) { item in
                            dropCard(item, width: HomeDropCard.shelfWidth)
                                .scrollTransition(axis: .horizontal) { content, phase in
                                    content
                                        .scaleEffect(phase.isIdentity || reduceMotion ? 1 : 0.95, anchor: .bottom)
                                        .opacity(phase.isIdentity ? 1 : 0.75)
                                }
                                .transition(.scale(scale: 0.85).combined(with: .opacity))
                        }
                    }
                    .scrollTargetLayout()
                    .animation(ThemeMotion.pick(ThemeMotion.uiSettle, reduceMotion: reduceMotion), value: items.map(\.id))
                }
                .contentMargins(.horizontal, ThemeMetrics.gutter, for: .scrollContent)
                .scrollTargetBehavior(.viewAligned)
                .scrollIndicators(.hidden)
                .scrollClipDisabled()
            }
        }
        .padding(.top, leading ? ThemeSpace.x4 : ThemeMetrics.sectionGap)
        .id("home/recent")
    }

    private func dropCard(_ item: HomeAiring, width: CGFloat) -> some View {
        let e = item.entry
        let run = max(1, e.episode - e.part.progress)
        return HomeDropCard(entry: e, run: run, line: dropLine(e, run: run), now: appModel.nowMinute, width: width,
                            committing: committingRows.contains(item.id),
                            lit: !appModel.experience.calm,
                            onOpen: {
                                onOpenDetail(e.franchise.id, "home-drop/\(item.id)",
                                             EpisodeFocus(mediaId: e.part.mediaId, episode: e.part.progress + 1))
                            },
                            onMark: { markThrough(item) })
            .franchiseQuickActions(appModel.isInLibrary(e.franchise.id) ? e.franchise : nil, appModel: appModel)
    }

    /// What a drop offers, as the billboard would say it: "Season 2 · Episode 1" — the season
    /// wherever the show has more than one (`watchContext`) — and a run by its range, "Season 4 ·
    /// Episodes 22–24". A bare "Episode 1" under a show eight years on the shelf said nothing about
    /// the new season it was the first of.
    private func dropLine(_ e: AppModel.ScheduleEntry, run: Int) -> String {
        let f = e.franchise
        guard run > 1, e.part.kind != .movie else { return f.watchContext(part: e.part, episode: e.episode) }
        let range = Copy.episodeRange(e.episode - run + 1, e.episode)
        let label = Copy.compactPartLabel(e.part.canonicalLabel)
        let named = !e.part.isMainStory || f.mainStoryEpisodicParts.count > 1
        return named && !label.isEmpty ? "\(label) \u{00B7} \(range)" : range
    }

    /// RINGS: the feed's stories for the shows with a new episode — a tap is the story.
    private func recentRings(_ items: [HomeAiring], leading: Bool) -> some View {
        let byShow = Dictionary(appModel.storyReels.map { ($0.franchiseId, $0) }, uniquingKeysWith: { a, _ in a })
        let reels = items.compactMap { byShow[$0.entry.franchise.id] }
        return VStack(alignment: .leading, spacing: ThemeSpace.x3) {
            SectionHeaderRow(Copy.Home.recentlyAired, action: onOpenSchedule)
                .padding(.horizontal, ThemeMetrics.gutter)
            StoryTray(reels: reels, loadingReelId: storyLoading, origins: storyOrigins) { index in
                openStory(reels, index)
            }
        }
        .padding(.top, leading ? ThemeSpace.x4 : ThemeMetrics.sectionGap)
        .id("home/recent")
    }

    /// The feed's open: the ring turns while the story's first picture loads (never past 0.9 s),
    /// then the story grows out of it.
    private func openStory(_ reels: [StoryReel], _ index: Int) {
        guard storyLoading == nil, reels.indices.contains(index) else { return }
        let reel = reels[index]
        storyLoading = reel.id
        storyTask?.cancel()
        storyTask = Task {
            let started = ContinuousClock.now
            if let u = reel.frames.first?.art.url, let url = URL(string: u) {
                await withTaskGroup(of: Void.self) { group in
                    group.addTask { _ = try? await ImageLoader.shared.image(for: url, maxPixel: StoryStyle.portraitPixelCap) }
                    group.addTask { try? await Task.sleep(for: .milliseconds(900)) }
                    await group.next()
                    group.cancelAll()
                }
            }
            let spent = started.duration(to: .now)
            if spent < .milliseconds(260) { try? await Task.sleep(for: .milliseconds(260) - spent) }
            guard !Task.isCancelled else { return }
            storyReels = reels
            storyLoading = nil
            storyTask = nil
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) { story = StoryLaunch(reelIndex: index, frameIndex: 0) }
        }
    }

    private func closeStory() {
        // A mark's receipt is drawn inside the viewer; leaving with it live hands its Undo to the lane.
        if var undo = appModel.undo, case .inPlace(let host) = undo.placement, host.hasPrefix("story/") {
            undo.placement = .lane
            appModel.presentUndo(undo)
        }
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { story = nil }
    }

    private func recentRows(_ items: [HomeAiring], leading: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeaderRow(Copy.Home.recentlyAired, action: onOpenSchedule)
                .padding(.horizontal, ThemeMetrics.gutter)
                .padding(.bottom, ThemeSpace.x2)
            ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                let first = i == 0 || items[i - 1].day != item.day
                let e = item.entry
                let count = max(1, e.episode - e.part.progress)
                airingRow(item, first: first, state: .toWatch, run: count) {
                    AiringStateControl(state: .toWatch, episode: e.episode,
                                       committing: committingRows.contains(item.id),
                                       title: e.franchise.displayTitle, batch: count > 1, count: count,
                                       canMark: appModel.isInLibrary(e.franchise.id)) {
                        markThrough(item)
                    }
                }
                .padding(.top, first && i > 0 ? ThemeSpace.x3 : 0)
                .transition(.opacity.combined(with: .move(edge: .leading)))
            }
        }
        .padding(.top, leading ? ThemeSpace.x4 : ThemeMetrics.sectionGap)
        .animation(ThemeMotion.pick(ThemeMotion.uiSettle, reduceMotion: reduceMotion), value: items.map(\.id))
        .id("home/recent")
    }

    // MARK: - Up next

    private func upNext(_ items: [HomeQueueItem], leading: Bool) -> some View {
        VStack(alignment: .leading, spacing: ThemeMetrics.labelGap) {
            SectionHeaderRow(Copy.Home.upNext, action: { onOpenLibrary(.watching) })
                .padding(.horizontal, ThemeMetrics.gutter)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: ThemeMetrics.shelfGap) {
                    ForEach(items) { item in
                        HomeUpNextTile(item: item, now: appModel.nowMinute,
                                       committing: committingTiles.contains(item.id),
                                       onOpen: {
                                           onOpenDetail(item.franchise.id, "home-next/\(item.id)",
                                                        EpisodeFocus(mediaId: item.part.mediaId, episode: item.episode))
                                       },
                                       onMark: { markTile(item) })
                            .franchiseQuickActions(item.franchise, appModel: appModel)
                            // A card entering from the shelf's edge grows into place — a
                            // carousel's depth, read in the render pass (no body re-runs).
                            .scrollTransition(axis: .horizontal) { content, phase in
                                content
                                    .scaleEffect(phase.isIdentity || reduceMotion ? 1 : 0.94, anchor: .bottom)
                                    .opacity(phase.isIdentity ? 1 : 0.72)
                            }
                            .transition(.scale(scale: 0.85).combined(with: .opacity))
                    }
                }
                .scrollTargetLayout()
                .animation(ThemeMotion.pick(ThemeMotion.uiSettle, reduceMotion: reduceMotion), value: items.map(\.id))
            }
            .contentMargins(.horizontal, ThemeMetrics.gutter, for: .scrollContent)
            .scrollTargetBehavior(.viewAligned)
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
        }
        .padding(.top, leading ? ThemeSpace.x4 : ThemeMetrics.sectionGap)
        .id("home/upnext")
    }

    // MARK: - Rows

    /// Schedule's agenda row: the date on a day's first row, the show's face, its name, "Episode 14
    /// · 7:30 PM", and the trailing slot.
    private func airingRow<Trailing: View>(_ item: HomeAiring, first: Bool, state: AiringState, run: Int = 1,
                                           @ViewBuilder trailing: @escaping () -> Trailing) -> some View {
        let e = item.entry
        let f = e.franchise
        let line = airingLine(e, run: run)
        let p = Formatting.localParts(item.noon)
        return ScheduleAgendaRow(franchise: f,
                                 date: first ? (Formatting.weekdayShort(p.wd), "\(p.d)") : nil,
                                 isToday: item.day == 0, line: line, state: state,
                                 spoken: "\(Formatting.formatted(e.at, skeleton: "EEEEdMMMM", anchor: f.timeAnchor)), \(f.title), \(line)",
                                 onOpen: {
                                     onOpenDetail(f.id, "home-row/\(item.id)",
                                                  EpisodeFocus(mediaId: e.part.mediaId, episode: e.episode))
                                 },
                                 trailing: trailing)
            .franchiseQuickActions(appModel.isInLibrary(f.id) ? f : nil, appModel: appModel)
    }

    /// "Episode 18" — a premiere in its own words — and, for what has aired, no clock: the date
    /// column already says when, and a time of day on a Wednesday that has passed is noise ("6:30
    /// PM" on one row of three read as a stray). A show more than one episode behind names the run
    /// it has to watch, "Episodes 22–24".
    private func airingLine(_ e: AppModel.ScheduleEntry, run: Int = 1) -> String {
        if run > 1, e.part.kind != .movie { return Copy.episodeRange(e.episode - run + 1, e.episode) }
        let what: String
        if e.part.kind == .movie || e.episode == 1 {
            let label = e.part.kind == .movie
                ? e.part.canonicalLabel
                : (e.franchise.parts.count > 1 ? Copy.compactPartLabel(e.part.canonicalLabel) : "")
            what = Copy.Schedule.premiere(label)
        } else {
            what = Copy.episode(e.episode)
        }
        guard !e.dateOnly, !e.aired else { return what }
        return "\(what) \u{00B7} \(Formatting.fmtTime(e.at, anchor: e.franchise.timeAnchor))"
    }

    // MARK: - Loading

    /// The loading frame in the screen's own shape: the billboard's ground (Calm: the first drop's
    /// card under its title, below the bar), then a shelf of posters.
    @ViewBuilder
    private var skeleton: some View {
        if appModel.experience.calm {
            calmSkeleton
        } else {
            stageSkeleton
        }
    }

    private var calmSkeleton: some View {
        let width = ThemeMetrics.windowWidth - 2 * ThemeMetrics.gutter
        return VStack(alignment: .leading, spacing: ThemeMetrics.labelGap) {
            SkeletonLine(width: 132, height: 19)
            SkeletonBlock(width: width, height: (width * 9 / 16).rounded(), radius: ThemeRadius.card)
            SkeletonLine(width: 96, height: 19)
                .padding(.top, ThemeMetrics.sectionGap)
            HStack(spacing: ThemeMetrics.shelfGap) {
                ForEach(0..<3, id: \.self) { _ in
                    SkeletonPoster(width: 150, height: 225, radius: ThemeRadius.poster)
                }
            }
        }
        .padding(.horizontal, ThemeMetrics.gutter)
        .padding(.top, band + ThemeMetrics.sectionGap)
        .accessibilityHidden(true)
    }

    private var stageSkeleton: some View {
        VStack(alignment: .leading, spacing: ThemeSpace.x3) {
            SkeletonBlock(width: nil, height: billboardHeight, radius: 0)
            SkeletonLine(width: 96, height: 19)
                .padding(.horizontal, ThemeMetrics.gutter)
                .padding(.top, ThemeSpace.x4)
            HStack(spacing: ThemeMetrics.shelfGap) {
                ForEach(0..<3, id: \.self) { _ in
                    SkeletonPoster(width: 150, height: 225, radius: ThemeRadius.poster)
                }
            }
            .padding(.horizontal, ThemeMetrics.gutter)
        }
        .accessibilityHidden(true)
    }

    // MARK: - Actions

    private func open(_ hero: HomeHero) {
        onOpenDetail(hero.franchise.id, "home-billboard/\(hero.franchise.id)",
                     EpisodeFocus(mediaId: hero.part.mediaId, episode: hero.episode))
    }

    /// The billboard's mark: the pill says "Watched" for a beat, then the write lands and the
    /// billboard rolls to the next episode — or hands over, if that was the last one out.
    private func markHero(_ hero: HomeHero) {
        guard !committingHero else { return }
        committingHero = true
        Task {
            try? await Task.sleep(for: Self.commitBeat)
            write(hero.franchise, part: hero.part)
            committingHero = false
        }
    }

    /// A tile's mark: the disc fills for a beat, then the tile rolls to the next episode — or
    /// leaves the shelf, caught up.
    private func markTile(_ item: HomeQueueItem) {
        guard !committingTiles.contains(item.id) else { return }
        committingTiles.insert(item.id)
        Task {
            try? await Task.sleep(for: Self.commitBeat)
            write(item.franchise, part: item.part)
            committingTiles.remove(item.id)
        }
    }

    /// The next episode, written. Everything it changes rolls (numeric text, the bar) on one spring;
    /// the Undo rides the lane.
    private func write(_ f: Franchise, part: FranchisePart) {
        withAnimation(ThemeMotion.pick(ThemeMotion.uiSettle, reduceMotion: reduceMotion)) {
            if let undo = appModel.markNext(franchiseId: f.id, mediaId: part.mediaId) {
                appModel.presentUndo(undo)
            }
        }
    }

    /// A recently aired episode, marked — and everything before it, with the exact count confirmed
    /// first when that is more than one (Schedule's ladder). The ring fills, then the row leaves.
    private func markThrough(_ item: HomeAiring) {
        let e = item.entry
        let part = e.part
        let target = e.episode
        let count = target - part.progress
        guard count > 0, !committingRows.contains(item.id) else { return }
        let commit = {
            committingRows.insert(item.id)
            Task {
                try? await Task.sleep(for: Self.commitBeat)
                withAnimation(ThemeMotion.pick(ThemeMotion.uiSettle, reduceMotion: reduceMotion)) {
                    appModel.setProgress(franchiseId: e.franchise.id, mediaId: part.mediaId, episodes: target)
                }
                committingRows.remove(item.id)
            }
        }
        if count > 1 {
            prompt = .init(title: Copy.Confirm.batchMarkTitle(count),
                           message: Copy.Confirm.batchMarkMessage(from: part.progress, to: target),
                           confirm: Copy.Confirm.batchMarkConfirm(count),
                           perform: { commit() })
        } else {
            commit()
        }
    }

    /// A show's billboard picture and its colour, fetched ahead of the billboard that will draw
    /// them (the decode `ArtHeader` asks for, so it is a cache hit there).
    private func warmBillboard(_ f: Franchise) async {
        let art = PosterPick.shared.choice(for: f).map { WideArt.billboard(portrait: $0.url, landscape: nil) }
            ?? f.billboardArt
        guard let string = art.url, let url = URL(string: string) else { return }
        let pixels: CGFloat = art.portraitSource ? 2048 : (art.ultraWide ? 1900 : 1536)
        _ = try? await ImageLoader.shared.image(for: url, maxPixel: pixels)
        _ = await PaletteCache.shared.resolve(url: string, maxPixel: 360)
    }

    private func scrollToTop(_ proxy: ScrollViewProxy) {
        withAnimation(ThemeMotion.pick(ThemeMotion.uiSnappy, reduceMotion: reduceMotion)) {
            proxy.scrollTo(Anchor.top, anchor: .top)
        }
    }

    /// The launch leaves on the billboard's picture — or at once when there is none to wait for.
    /// The splash bounds the wait itself.
    private func markArtReady() {
        guard !artMarked else { return }
        artMarked = true
        launch?.artReady = true
        PerfProbe.mark("home-ready")
    }

    private func dismissAll() {
        pendingRouteAfterSheet = nil
        prompt = nil
        showProfile = false
    }

    /// Four tabs: Activity closed — read, and the row it was closed for opens.
    private func activityDismissed() {
        appModel.markActivityRead()
        guard let route = pendingActivityRoute else { return }
        pendingActivityRoute = nil
        switch route {
        case .show(let id):
            onOpenDetail(id, "activity/\(id)", nil)
        case .post(let postId, let commentId):
            onOpenRoute(.post(id: postId, focusCommentId: commentId))
        case .thread(let subject, let franchiseId, let commentId):
            if let ep = ThreadSubject.parseEpisode(subject) {
                onOpenRoute(.episode(franchiseId: franchiseId, mediaId: ep.mediaId, episode: ep.episode,
                                     focusCommentId: commentId))
            } else {
                onOpenRoute(.post(id: subject, focusCommentId: commentId))
            }
        }
    }

    private func profileDismissed() {
        if let route = pendingRouteAfterSheet {
            pendingRouteAfterSheet = nil
            onOpenRoute(route)
        }
    }
}
