import SwiftUI

/// Today is the feed (brief §1–2): X's header and tabs, the stories tray, the posts the server
/// composed (`GET /me/feed`), Suggested for you, "You're all caught up", and For you's Trending.
///
/// The rules this screen keeps (spec §2.2, §5.1):
///   • the two rooms are PAGES of a real pager, X's: the finger drags a page and the tab underline
///     rides with it, and each page keeps its own place (the list never swaps its rows);
///   • each page is a `LazyVStack` of `FeedRow`s the MODEL composed and memoised — this body never
///     filters, sorts or formats a post;
///   • the scroll offset is never screen state — `FeedChromeState` is written by the probes and
///     read only by the header, the tab row and the pill;
///   • every cover and sheet is dismissed by the re-tap and the notification route, and none can
///     appear after the reader has left (the story's load is a cancellable task);
///   • the launch hands off on the first post's picture (`LaunchHandoff.artReady`), never on the
///     stories tray.
struct FeedView: View {
    let onOpenDetail: (_ franchiseId: String, _ zoomID: String) -> Void
    let onOpenRoute: (FeedRoute) -> Void
    let onOpenLibrary: (WatchStatus) -> Void
    let onAddShow: () -> Void
    let onOpenRecommendations: () -> Void
    /// Bumped when Today is re-selected: every cover and sheet goes, and the feed goes to its top.
    let topSignal: Int
    /// Bumped by the notification route: every cover and sheet goes (the route then pushes).
    let dismissSignal: Int
    /// The header's scroll state — OWNED by `MainTabView`, because the app's bar rides it too: on
    /// the feed, and only there, X's bottom bar leaves with the header and comes back with it.
    let chrome: FeedChromeState

    @Environment(AppModel.self) private var appModel
    @Environment(LaunchHandoff.self) private var launch: LaunchHandoff?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale
    @Environment(\.scenePhase) private var scenePhase

    /// X's inline video: the one trailer that plays in its post.
    @State private var autoplay = FeedAutoplay()
    /// The feed is the screen in front (not under a push, not on another tab).
    @State private var onScreen = false

    /// The page in front — where the pager has settled.
    @State private var tab: FeedTab = FeedCapture.initialTab
    /// The pager's own position (`scrollPosition(id:)`): a tab tap writes it, a swipe settles it.
    @State private var pagerTab: FeedTab? = FeedCapture.initialTab
    /// Each page's scroll proxy (the wordmark and the re-tap scroll the page in front to its top).
    @State private var proxies: [FeedTab: ScrollViewProxy] = [:]
    /// The fresh posts the pill has already been dismissed for (by its tap, or by a pull): it comes
    /// back only for posts that were not among them.
    @State private var pillDismissedFor: Set<String> = []
    // The story viewer. The reels are frozen at the tap so the tray cannot reorder under it.
    @State private var story: StoryLaunch?
    @State private var storyReelsSnapshot: [StoryReel] = []
    /// The tray keeps the snapshot while the viewer is up and until its close flight has landed:
    /// a reel seen in the viewer leaves the tray only then (`releaseTray`), so the flight lands in
    /// its own bubble, not in the one that slid into its place.
    @State private var trayHeld = false
    @State private var trayRelease: Task<Void, Never>?
    @State private var storyLoading: String?
    @State private var storyOrigins = StoryOrigins()
    @State private var storyTask: Task<Void, Never>?
    // Covers and sheets.
    @State private var viewing: FeedPostModel?
    @State private var composing: ComposeTarget?
    @State private var activityOpen = false
    @State private var showProfile = false
    /// A feed page asked for from inside Profile (Saved → a post): opened once the sheet has gone.
    @State private var pendingRouteAfterSheet: FeedRoute?
    /// An Activity row's destination: opened once the sheet has gone.
    @State private var pendingActivityRoute: OpenRoute?
    /// What the picture viewer asked for on its way out, done once it has gone.
    @State private var afterCover: AfterCover?
    @State private var artMarked = false
    /// The skeleton's minimum hold (SkeletonGate's 240 ms delay + 320 ms floor), kept here because
    /// the gate itself would wrap the rows in an eager ZStack. The page in front's only.
    @State private var skeletonHeld = false
    @State private var loadingSince: ContinuousClock.Instant?
    @State private var captureLanded = false
    /// The feed's ONE post menu: a row's `···` names its post here and the list presents one
    /// dialog (`postMenuHost`), instead of a `Menu` per realised row.
    @State private var postMenu = PostMenuRequest()
    @Namespace private var mediaZoom

    private enum AfterCover {
        case compose(ComposeTarget)
        case show(franchiseId: String, zoomID: String)
    }

    /// Scroll anchors that are not rows (the rows' own ids are anchors too: "post/<id>",
    /// "caughtup", "suggested", "trending").
    private enum Anchor {
        static let top = "top"
        static let stories = "stories"
    }

    /// SkeletonGate's timings.
    private static let skeletonDelay: Duration = .milliseconds(240)
    private static let skeletonFloor: Duration = .milliseconds(320)
    /// Instagram's open: the ring spins while the first picture loads — never longer than 0.9 s, and
    /// at least a quarter second so the spin is seen.
    private static let storyLoadCeiling: Duration = .milliseconds(900)
    private static let storySpinFloor: Duration = .milliseconds(260)
    /// The beat between the close flight landing in a seen reel's bubble and the bubble leaving.
    private static let trayReleaseBeat: Duration = .milliseconds(220)
    /// X keeps the other room warm: once Following is on screen, For you loads behind it.
    private static let prefetchDelay: Duration = .milliseconds(1200)

    // MARK: - Body

    var body: some View {
        let phase = appModel.feedPhase(tab)
        GeometryReader { geo in
            let insets = geo.safeAreaInsets
            ZStack(alignment: .top) {
                // Flat, as X's is: the posts' pictures are the only colour on screen.
                ThemeColor.canvas.ignoresSafeArea()

                pager(size: geo.size, insets: insets)

                newPostsPill

                FeedHeader(selected: tab, chrome: chrome, unread: appModel.activityUnread,
                           onProfile: { showProfile = true }, onActivity: openActivity, onTop: scrollToTop,
                           onSelect: select, topInset: insets.top)
            }
        }
        .background(ThemeColor.canvas.ignoresSafeArea())
        // The header is a bar of our own; no system edge effect under it (a root's rule).
        .chromeScrollEdgeHidden(.top)
        // …and no system navigation bar, SAID rather than left to the stack: a pop by path (the
        // tab's re-tap, X's way home) from a page that shows its bar (a show page) kept that bar's
        // 54 pt in the feed's top inset, and the header sat under a band of nothing.
        .toolbar(.hidden, for: .navigationBar)
        .postMenuHost(postMenu) { m in onOpenDetail(m.post.franchiseId, "post/\(m.id)") }
        .modifier(FeedPresentations(host: self))
        .onChange(of: overlayOpen) { _, open in
            if appModel.feedOverlayOpen != open { appModel.feedOverlayOpen = open }
        }
        // Nothing plays behind a cover, under a push, on another tab or in the background.
        .onChange(of: autoplayHeld, initial: true) { _, held in autoplay.suspend(held) }
        .onChange(of: pagerTab) { _, next in
            if let next, next != tab { tab = next }
        }
        .onChange(of: tab) { _, next in tabChanged(to: next) }
        .onChange(of: topSignal) { _, _ in
            dismissAll()
            scrollToTop()
        }
        .onChange(of: dismissSignal) { _, _ in dismissAll() }
        .onChange(of: phase == .loading, initial: true) { _, loading in skeletonPhase(loading: loading) }
        .onChange(of: phase, initial: true) { _, next in handOffIfNoArt(phase: next) }
        // No timer after the first content frame: the cached feed paints at once, so it would flip
        // `artReady` long before the film lands and the app would emerge on grey placeholders. The
        // splash's own `artPatience` and the ident's `artGrace` bound the wait for a picture.
        .task(id: isContent(phase)) { await captureLanding(phase: phase) }
        .task(id: isContent(appModel.feedPhase(.following))) { await prefetchForYou() }
        .onAppear {
            onScreen = true
            appModel.currentFeedTab = tab
            // Following's empty account and For you's Trending both draw the chart.
            appModel.loadTrendingIfNeeded()
            if FeedCapture.openProfile { showProfile = true }
        }
        // Following is loaded by the model after the visit stamp (iD3); a capture that opens on
        // For you loads it here.
        .task { if tab == .forYou { await appModel.loadFeed(.forYou) } }
        .onChange(of: appModel.libraryEmpty) { _, empty in
            if empty { appModel.loadTrendingIfNeeded() }
        }
        // A pull is a state change with no visible focus move: VoiceOver is told.
        .onChange(of: appModel.isRefreshing) { _, refreshing in
            if refreshing { Announce.status(Copy.Accessibility.refreshing) }
        }
        .onDisappear {
            onScreen = false
            cancelStoryLoad()
        }
    }

    /// Autoplay waits while anything covers the feed or the feed is not in front.
    private var autoplayHeld: Bool {
        overlayOpen || !onScreen || scenePhase != .active
    }

    // MARK: - The pager

    /// X's two rooms side by side. The pages run under the status band and the tab bar; each page
    /// insets its own content (`safeAreaPadding`), so a page's rows scroll under both as one list
    /// did.
    private func pager(size: CGSize, insets: EdgeInsets) -> some View {
        ScrollViewReader { reader in
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    ForEach(FeedTab.allCases, id: \.self) { t in
                        page(t, height: size.height, insets: insets)
                            .frame(width: size.width)
                            .id(t)
                    }
                }
                .scrollTargetLayout()
                // The pager's probe: WRITES the tab row's progress, never screen state.
                .background {
                    Color.clear.onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.frame(in: .global).minX
                    } action: { minX in
                        guard size.width > 0 else { return }
                        chrome.setPageProgress(-minX / size.width)
                    }
                }
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $pagerTab)
            .scrollIndicators(.hidden)
            .onScrollPhaseChange { _, next in autoplay.scrollMoving(next != .idle) }
            .onAppear {
                // `scrollPosition` does not place a pager on its first layout: a launch on For you
                // (`-feedTab foryou`) is put there by hand, without motion.
                guard tab != FeedTab.allCases.first else { return }
                var still = Transaction()
                still.disablesAnimations = true
                withTransaction(still) { reader.scrollTo(tab, anchor: .leading) }
            }
        }
        .ignoresSafeArea(.container, edges: .vertical)
        .environment(\.feedAutoplay, autoplay)
    }

    /// One room: its own vertical list, its own place, its own pull.
    private func page(_ t: FeedTab, height: CGFloat, insets: EdgeInsets) -> some View {
        let phase = appModel.feedPhase(t)
        let showSkeleton = phase == .loading || (t == tab && skeletonHeld) || FeedCapture.holdSkeleton
        return ScrollViewReader { reader in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    Color.clear.frame(height: FeedHeader.height).id(Anchor.top)
                    // Instagram's tray runs straight into the feed — no rule under it ("the
                    // bottom border after story is kind of bothering me", owner, 25 Sep).
                    if t == .following { storiesTray }
                    if showSkeleton {
                        SkeletonGate(isLoading: true) { FeedSkeletonStack() } content: { EmptyView() }
                    } else {
                        switch phase {
                        case .loading:
                            EmptyView()
                        case .errorNoCache(let offline):
                            EmptyState(offline ? .feedOfflineNoData : .feedServerNoCache, prominence: .major,
                                       primary: { Task { await appModel.refreshFeed(t) } })
                                .centredState(contentH: max(0, height - FeedHeader.height))
                        case .content:
                            rowList(t)
                        }
                    }
                }
                // The scroll probe: WRITES the chrome's offset, never screen state.
                .background {
                    Color.clear.onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.frame(in: .global).minY
                    } action: { minY in
                        chrome.track(insets.top - minY, page: t)
                    }
                }
            }
            .safeAreaPadding(.top, insets.top)
            .safeAreaPadding(.bottom, insets.bottom)
            .scrollIndicators(.hidden)
            .tabBarContentMargin()
            .laneClearance(appModel)
            .onScrollPhaseChange { _, next in
                autoplay.scrollMoving(next != .idle)
                if next == .idle { chrome.settle(page: t) }
            }
            .previouslyRefreshable { await pullToRefresh(t) }
            .onAppear { proxies[t] = reader }
        }
    }

    // MARK: - Pieces

    /// What the tray shows: the reels still to be seen (`AppModel.trayReels`), or — while the
    /// viewer is up and until its flight has landed — the snapshot it opened with.
    private var trayList: [StoryReel] { trayHeld ? storyReelsSnapshot : appModel.trayReels }

    @ViewBuilder
    private var storiesTray: some View {
        let reels = trayList
        if !reels.isEmpty {
            StoryTray(reels: reels, loadingReelId: storyLoading, origins: storyOrigins, onOpen: openStory)
                .padding(.top, ThemeSpace.x2)
                .padding(.bottom, ThemeSpace.x3)
                .id(Anchor.stories)
                .transition(.opacity)
        }
    }

    /// The composed rows, each a direct child of the lazy stack (so only the realised ones are
    /// built). Keyed by `FeedRow.id`.
    @ViewBuilder
    private func rowList(_ t: FeedTab) -> some View {
        let rows = appModel.feedRows(t)
        let firstPostId = rows.first { if case .post = $0 { return true } else { return false } }?.id
        ForEach(rows) { row in
            rowView(row, in: t, isFirstPost: t == tab && row.id == firstPostId)
                .transition(rowTransition)
        }
    }

    @ViewBuilder
    private func rowView(_ row: FeedRow, in t: FeedTab, isFirstPost: Bool) -> some View {
        switch row {
        case .post(let m):
            FeedPostRow(model: m, tab: t, zoom: mediaZoom,
                        // An episode's post opens its show (where the episode is marked); every
                        // other post opens its page.
                        onOpen: {
                            if m.post.kind == .episode {
                                onOpenDetail(m.post.franchiseId, "post/\(m.id)")
                            } else {
                                onOpenRoute(.post(id: m.id))
                            }
                        },
                        onOpenShow: { onOpenDetail(m.post.franchiseId, "post/\(m.id)") },
                        onViewMedia: { viewing = m },
                        onComment: { composing = composeTarget(m) },
                        onMediaLoaded: isFirstPost ? { markArtReady() } : nil)
                .equatable()
        case .folded(let postId, let fold):
            FoldedPostRow(fold: fold) { appModel.undoFold(postId: postId) }
        case .caughtUp(let since):
            CaughtUpMarker(since: since)
        case .suggested(let keys):
            let recs = appModel.visibleRecommendations
            SuggestedModule(items: keys.compactMap { k in recs.first { $0.key == k } },
                            reason: { appModel.spokenReason($0) },
                            onOpen: openRecommendation,
                            onSeeAll: onOpenRecommendations)
        case .trending(let items):
            TrendingModule(items: items) { id in onOpenDetail(id, "trending/\(id)") }
        case .empty(.emptyAccount):
            EmptyState(.emptyToday, prominence: .section, primary: onAddShow)
                .padding(.vertical, ThemeSpace.x8)
                .padding(.horizontal, ThemeMetrics.gutter)
        case .empty(.noPosts):
            VStack(spacing: 0) {
                EmptyState(.feedNoPosts, prominence: .section)
                    .padding(.vertical, ThemeSpace.x8)
                    .padding(.horizontal, ThemeMetrics.gutter)
                FeedHairline()
            }
        case .empty(.forYouEmpty):
            Text(Copy.Feed.forYouEmpty)
                .type(ThemeType.feedSubhead)
                .foregroundStyle(ThemeColor.feedSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, ThemeMetrics.gutter)
                .padding(.vertical, ThemeSpace.x8 + ThemeSpace.x2)
        case .notice(let kind):
            VStack(spacing: 0) {
                notice(kind, in: t)
                    .padding(.horizontal, ThemeMetrics.gutter)
                    .padding(.vertical, ThemeSpace.x2)
                FeedHairline()
            }
        }
    }

    @ViewBuilder
    private func notice(_ kind: FeedNoticeKind, in t: FeedTab) -> some View {
        switch kind {
        case .refreshFailed:
            InlineNotice(Copy.Feed.couldntRefresh, retry: { Task { await appModel.refreshFeed(t) } })
        case .unavailable:
            InlineNotice(Copy.Feed.unavailable, kind: .info)
        case .offlineCached:
            InlineNotice(EmptyStateCopy.offlineCached.supporting ?? EmptyStateCopy.offlineCached.title, kind: .info)
        }
    }

    /// Rows only fade in and out (a fold, a refresh); a page change is the pager's own motion.
    private var rowTransition: AnyTransition {
        if reduceMotion { return .opacity.animation(ThemeMotion.uiReduced) }
        return .asymmetric(insertion: .opacity, removal: .opacity.animation(ThemeMotion.uiDismiss))
    }

    /// X's pill: shown (by `FeedPillSlot`) only once the reader is well down the feed, and only for
    /// fresh posts it has not already been dismissed for.
    @ViewBuilder
    private var newPostsPill: some View {
        if tab == .following {
            let fresh = appModel.freshPosts(.following)
            if !fresh.isEmpty, !fresh.allSatisfy({ pillDismissedFor.contains($0.id) }) {
                FeedPillSlot(chrome: chrome) {
                    NewPostsPill(posts: Array(fresh.prefix(3)), count: fresh.count) {
                        dismissPill()
                        scrollToTop()
                    }
                }
                .padding(.top, FeedHeader.height + ThemeSpace.x3)
                .zIndex(2)
            }
        }
    }

    // MARK: - Pages

    /// A tab tapped: the pager slides to it (and the underline rides the same motion).
    private func select(_ t: FeedTab) {
        withAnimation(ThemeMotion.pick(ThemeMotion.uiSnappy, reduceMotion: reduceMotion)) { pagerTab = t }
    }

    private func tabChanged(to next: FeedTab) {
        appModel.currentFeedTab = next
        chrome.activate(next)
        if pagerTab != next { pagerTab = next }
        Task { await appModel.loadFeed(next) }
    }

    /// Once Following has content, For you loads behind it — the finger can drag it into view at
    /// any moment, and X's never opens on a skeleton. `loadFeed` skips a fresh or in-flight tab.
    private func prefetchForYou() async {
        guard isContent(appModel.feedPhase(.following)) else { return }
        try? await Task.sleep(for: Self.prefetchDelay)
        guard !Task.isCancelled else { return }
        await appModel.loadFeed(.forYou)
    }

    // MARK: - Scroll and the pill

    private func scrollToTop() {
        chrome.reveal()
        withAnimation(ThemeMotion.pick(ThemeMotion.uiSnappy, reduceMotion: reduceMotion)) {
            proxies[tab]?.scrollTo(Anchor.top, anchor: .top)
        }
    }

    private func dismissPill() {
        pillDismissedFor.formUnion(appModel.freshPosts(.following).map(\.id))
    }

    /// The pull: the pill goes (the reader is at the top, with the new posts in front of them),
    /// then the library, the tab, Activity, reminders and hides refresh together.
    private func pullToRefresh(_ t: FeedTab) async {
        if t == .following { dismissPill() }
        await appModel.refreshFeed(t)
    }

    // MARK: - Skeleton

    /// SkeletonGate's rules, for rows that must stay direct children of the lazy stack: nothing for
    /// the first 240 ms, then the skeleton, and once shown it stays at least 320 ms, then fades.
    private func skeletonPhase(loading: Bool) {
        if loading {
            loadingSince = .now
            return
        }
        guard let since = loadingSince else { return }
        loadingSince = nil
        let elapsed = since.duration(to: .now)
        guard elapsed > Self.skeletonDelay else { return }
        let remaining = Self.skeletonDelay + Self.skeletonFloor - elapsed
        guard remaining > .zero else { return }
        skeletonHeld = true
        Task {
            try? await Task.sleep(for: remaining)
            withAnimation(ThemeMotion.uiCrossfade) { skeletonHeld = false }
        }
    }

    private func isContent(_ phase: FeedSurfacePhase) -> Bool {
        if case .content = phase { return true }
        return false
    }

    // MARK: - Launch hand-off

    /// The splash leaves on the first post's picture (§2.2): its decode (a), or a feed with nothing
    /// to wait for (b) — whichever comes first. The splash bounds the wait itself.
    private func markArtReady() {
        guard !artMarked else { return }
        artMarked = true
        launch?.artReady = true
        PerfProbe.mark("feed-ready")
    }

    /// (b) a feed with nothing to wait for — an empty account, no posts, an error, an older server,
    /// or no post among the first three rows.
    private func handOffIfNoArt(phase: FeedSurfacePhase) {
        guard phase != .loading, !artMarked else { return }
        let firstRows = appModel.feedRows(tab).prefix(3)
        let hasPost = firstRows.contains { if case .post = $0 { return true } else { return false } }
        if !hasPost { markArtReady() }
    }

    // MARK: - Presentations

    fileprivate var overlayOpen: Bool {
        story != nil || viewing != nil || composing != nil || activityOpen || showProfile
    }

    /// Closes every cover and sheet (covers without animation), and any story still loading.
    private func dismissAll() {
        cancelStoryLoad()
        pendingRouteAfterSheet = nil
        pendingActivityRoute = nil
        afterCover = nil
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
            story = nil
            viewing = nil
            autoplay.fullScreen = nil
        }
        composing = nil
        activityOpen = false
        showProfile = false
    }

    private func openActivity() {
        activityOpen = true
        Task { await appModel.loadActivity(reset: true) }
    }

    /// An Activity row's destination (§4.7): a show opens its page; a post or a thread its page.
    private func open(_ route: OpenRoute) {
        switch route {
        case .show(let id):
            onOpenDetail(id, "activity/\(id)")
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

    private func openRecommendation(_ r: RecommendationItem) {
        Task { if let id = await appModel.franchiseId(for: r) { onOpenDetail(id, "foryou/\(r.key)") } }
    }

    fileprivate func composeTarget(_ m: FeedPostModel) -> ComposeTarget {
        ComposeTarget(subject: m.id, franchiseId: m.post.franchiseId, franchiseTitle: m.showName)
    }

    /// A trailer's full screen, titled by its post's show.
    fileprivate func trailerTitle(_ playback: TrailerPlayback) -> String {
        appModel.feedPost(id: playback.key)?.showName ?? ""
    }

    fileprivate func runAfterCover() {
        guard let next = afterCover else { return }
        afterCover = nil
        switch next {
        case .compose(let target): composing = target
        case .show(let id, let zoomID): onOpenDetail(id, zoomID)
        }
    }

    // MARK: - Stories

    /// Instagram's open: the tapped ring breaks into turning dashes while the story's first picture
    /// loads (never longer than 0.9 s), then the story grows out of the ring. Cancellable: a re-tap,
    /// a notification or leaving the screen means no cover appears after the reader has gone.
    private func openStory(_ index: Int) {
        let reels = trayList
        guard storyLoading == nil, reels.indices.contains(index) else { return }
        let reel = reels[index]
        storyLoading = reel.id
        let screen = CGSize(width: ThemeMetrics.windowWidth, height: ThemeMetrics.windowHeight)
        let pixels = reel.frames.first.map { StoryArt.maxPixel(for: $0.art, screen: screen, scale: displayScale) }
            ?? StoryStyle.portraitPixelCap
        storyTask?.cancel()
        storyTask = Task {
            let started = ContinuousClock.now
            if let u = reel.frames.first?.art.url, let url = URL(string: u) {
                await withTaskGroup(of: Void.self) { group in
                    group.addTask { _ = try? await ImageLoader.shared.image(for: url, maxPixel: pixels) }
                    group.addTask { try? await Task.sleep(for: Self.storyLoadCeiling) }
                    await group.next()
                    group.cancelAll()
                }
            }
            let spent = started.duration(to: .now)
            if spent < Self.storySpinFloor { try? await Task.sleep(for: Self.storySpinFloor - spent) }
            guard !Task.isCancelled else { return }
            trayRelease?.cancel()
            storyReelsSnapshot = reels
            trayHeld = true
            storyLoading = nil
            storyTask = nil
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) { story = StoryLaunch(reelIndex: index, frameIndex: 0) }
        }
    }

    private func cancelStoryLoad() {
        storyTask?.cancel()
        storyTask = nil
        storyLoading = nil
    }

    fileprivate func closeStory() {
        // A story mark's receipt is drawn inside the viewer; leaving with it still live hands its
        // Undo to the lane for a fresh window (§4.1 step 5).
        if var undo = appModel.undo, case .inPlace(let host) = undo.placement, host.hasPrefix("story/") {
            undo.placement = .lane
            appModel.presentUndo(undo)
        }
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { story = nil }
        releaseTray()
    }

    /// The flight has landed: a beat on the seen bubble, then the reels seen in the viewer leave
    /// the tray (and the tray itself, when none is left).
    private func releaseTray() {
        trayRelease?.cancel()
        trayRelease = Task {
            try? await Task.sleep(for: Self.trayReleaseBeat)
            guard !Task.isCancelled, story == nil else { return }
            withAnimation(ThemeMotion.pick(ThemeMotion.uiGentle, reduceMotion: reduceMotion)) { trayHeld = false }
            trayRelease = nil
        }
    }

    // MARK: - Captures

    /// `-feedStory`, `-feedMedia`, `-feedThread`, `-feedActivity`, `-openSaved`, `-feedAnchor`
    /// (FeedCapture): once, a beat after content lands. Inert outside DEBUG.
    private func captureLanding(phase: FeedSurfacePhase) async {
        guard isContent(phase), !captureLanded else { return }
        let wanted = FeedCapture.story != nil || FeedCapture.media != nil || FeedCapture.thread != nil
            || FeedCapture.trailer != nil
            || FeedCapture.activity || FeedCapture.openSaved || FeedCapture.anchor != nil
        guard wanted else { return }
        captureLanded = true
        try? await Task.sleep(for: FeedCapture.landingDelay)
        guard !Task.isCancelled else { return }
        let posts: [FeedPostModel] = appModel.feedRows(tab).compactMap {
            if case .post(let m) = $0 { return m } else { return nil }
        }
        if let key = FeedCapture.story {
            // The tray's reels; once they have all been seen, every reel (a capture may open one
            // the tray no longer shows — it then closes with a fade, having no bubble).
            let reels = appModel.trayReels.isEmpty ? appModel.storyReels : appModel.trayReels
            guard !reels.isEmpty else { return }
            let i = key == "first" ? 0 : (reels.firstIndex { $0.franchiseId.hasPrefix(key) } ?? 0)
            storyReelsSnapshot = reels
            trayHeld = !appModel.trayReels.isEmpty
            let frame = min(FeedCapture.storyFrame, max(0, reels[i].frames.count - 1))
            story = StoryLaunch(reelIndex: i, frameIndex: frame)
            return
        }
        if FeedCapture.media != nil,
           let m = posts.first(where: { if case .art = $0.media { return true } else { return false } }) {
            viewing = m
            return
        }
        if let mode = FeedCapture.trailer,
           let m = posts.first(where: { if case .trailer = $0.media { return true } else { return false } }),
           case .trailer(_, let video) = m.media {
            // On screen first — a trailer scrolled away stops — then the reader's tap.
            proxies[tab]?.scrollTo("post/\(m.id)", anchor: UnitPoint(x: 0.5, y: 0.2))
            try? await Task.sleep(for: .seconds(1))
            autoplay.engage(m.id, video: video)
            if mode == "full" {
                try? await Task.sleep(for: .seconds(2.5))
                if let playback = autoplay.current { autoplay.openFullScreen(playback) }
            }
            return
        }
        if let key = FeedCapture.thread {
            let m = key == "first"
                ? posts.first
                : posts.first(where: { $0.id.hasPrefix(key) || $0.post.franchiseId.hasPrefix(key) })
            onOpenRoute(.post(id: m?.id ?? key))
            return
        }
        if FeedCapture.activity { openActivity(); return }
        if FeedCapture.openSaved { onOpenRoute(.saved); return }
        if let key = FeedCapture.anchor {
            let target: String
            switch key {
            case Anchor.top, Anchor.stories, "suggested", "caughtup", "trending": target = key
            default: target = posts.first(where: { $0.id.hasPrefix(key) }).map { "post/\($0.id)" } ?? key
            }
            proxies[tab]?.scrollTo(target, anchor: UnitPoint(x: 0.5, y: 0.125))
        }
    }

    // MARK: - Bindings the presentations use

    fileprivate var storyBinding: Binding<StoryLaunch?> { $story }
    fileprivate var viewingBinding: Binding<FeedPostModel?> { $viewing }
    fileprivate var trailerBinding: Binding<TrailerPlayback?> { Bindable(autoplay).fullScreen }
    fileprivate var trailers: FeedAutoplay { autoplay }
    fileprivate var composingBinding: Binding<ComposeTarget?> { $composing }
    fileprivate var activityBinding: Binding<Bool> { $activityOpen }
    fileprivate var profileBinding: Binding<Bool> { $showProfile }
    fileprivate var reelsSnapshot: [StoryReel] { storyReelsSnapshot }
    fileprivate var origins: StoryOrigins { storyOrigins }
    fileprivate var zoomNamespace: Namespace.ID { mediaZoom }

    fileprivate func setAfterCover(compose target: ComposeTarget) { afterCover = .compose(target) }
    fileprivate func setAfterCover(show id: String, zoomID: String) { afterCover = .show(franchiseId: id, zoomID: zoomID) }
    fileprivate func activityPicked(_ route: OpenRoute) {
        pendingActivityRoute = route
        activityOpen = false
    }
    fileprivate func activityDismissed() {
        appModel.markActivityRead()
        if let route = pendingActivityRoute {
            pendingActivityRoute = nil
            open(route)
        }
    }
    fileprivate func profileWantsRoute(_ route: FeedRoute) {
        pendingRouteAfterSheet = route
        showProfile = false
    }
    fileprivate func profileDismissed() {
        if let route = pendingRouteAfterSheet {
            pendingRouteAfterSheet = nil
            onOpenRoute(route)
        }
    }
}

// MARK: - Covers and sheets

/// The feed's six presentations, in one place: the story viewer, the picture viewer, the trailer's
/// stage, the composer, Activity, and Profile (the ONLY entry to Profile — settings, sign-out,
/// delete account — is the header's disc).
private struct FeedPresentations: ViewModifier {
    let host: FeedView

    func body(content: Content) -> some View {
        content
            .fullScreenCover(item: host.storyBinding) { start in
                StoryViewer(reels: host.reelsSnapshot, start: start, origins: host.origins,
                            onOpenShow: { id in host.onOpenDetail(id, "story/\(id)") },
                            onClose: { host.closeStory() })
                    .presentationBackground(.clear)
            }
            .fullScreenCover(item: host.viewingBinding, onDismiss: { host.runAfterCover() }) { m in
                FeedMediaViewer(model: m,
                                onComment: { host.setAfterCover(compose: host.composeTarget(m)) },
                                onOpenShow: { host.setAfterCover(show: m.post.franchiseId, zoomID: "media/\(m.post.franchiseId)") })
                    .navigationTransition(.zoom(sourceID: FeedZoom.media(m.id), in: host.zoomNamespace))
            }
            // A trailer's full screen: the post's own player, zoomed out of the post (a swipe down
            // carries it back, still playing).
            .fullScreenCover(item: host.trailerBinding) { playback in
                let show = host.trailerTitle(playback)
                TrailerFullScreen(playback: playback, title: show,
                                  subtitle: TrailerFullScreen.subtitle(playback.video, show: show),
                                  byRotation: host.trailers.fullScreenByRotation,
                                  onClosed: { host.trailers.fullScreenClosed(playback) })
                    .navigationTransition(.zoom(sourceID: FeedZoom.media(playback.key), in: host.zoomNamespace))
                    .perfScreen("Trailer")
            }
            .sheet(item: host.composingBinding) { target in
                ComposeSheet(target: target)
                    .perfScreen("Compose")
            }
            .sheet(isPresented: host.activityBinding, onDismiss: { host.activityDismissed() }) {
                ActivitySheet(onOpen: { route in host.activityPicked(route) })
                    .perfScreen("Activity")
            }
            .sheet(isPresented: host.profileBinding, onDismiss: { host.profileDismissed() }) {
                ProfileView(onOpenLibrary: { status in
                                host.profileBinding.wrappedValue = false
                                host.onOpenLibrary(status)
                            },
                            onOpenDetail: { id in
                                host.profileBinding.wrappedValue = false
                                host.onOpenDetail(id, "profile/\(id)")
                            })
                    .environment(\.openFeedRoute, { route in host.profileWantsRoute(route) })
                    .perfScreen("Profile")
            }
    }
}
