import SwiftUI

// Gates the app on authentication, then shows the four-tab main UI.
struct RootView: View {
    @Environment(AuthManager.self) private var auth
    @Environment(AppModel.self) private var appModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The cold launch: a short brand film (`SplashView`), then the app.
    @State private var launch = LaunchHandoff()
    @State private var launchDone = false
    /// The app has started emerging beneath the splash.
    @State private var emerged = false
    /// The sign-in gate has been on screen this run: whoever is signed in now arrived through it.
    @State private var sawGate = false

    var body: some View {
        ZStack {
            ThemeColor.canvas.ignoresSafeArea()
            // The app is laid out under the ident from the first frame and EMERGES through it: a
            // hair small while the ident holds, settling to full size as the ident pushes through
            // and fades off it. It is never faded itself — an opacity ramp over the whole tree is
            // an offscreen pass on every frame; the ident's two layers fading is the same picture
            // for the price of two layers. Under Reduce Motion nothing scales.
            Group {
                if auth.isSignedIn {
                    Group {
                        if appModel.deletionNeedsConfirmation {
                            AccountDeletionRecoveryView()
                        } else {
                            SignedInRoot(fromGate: sawGate)
                        }
                    }
                    .id(auth.accountID)
                    .task(id: auth.accountID) { appModel.start(accountID: auth.accountID) }
                    .transition(.opacity.animation(ThemeMotion.uiGentle))
                } else {
                    SignInView()
                        .transition(.opacity.animation(ThemeMotion.uiGentle))
                        // Seen for real — after auth has answered that nobody is signed in — not
                        // the frame it holds under the launch while a session is being restored.
                        .task(id: auth.bootstrapped) { if auth.bootstrapped { sawGate = true } }
                }
            }
            // No scale on the whole tree (review i5): 0.96 → 1 on `uiSettle` was a full-screen
            // offscreen pass started in the frame the ident began leaving, and it froze the exit
            // at 80 % for half a second. The ident's ground IS the reveal.
            // Under the splash the app is built but not there: VoiceOver may not find it (the
            // splash takes every touch, so a first activation would die silently).
            .accessibilityHidden(!launchDone && !launch.emerging)

            if !launchDone {
                SplashView(
                    signedIn: auth.isSignedIn,
                    onLeaving: {
                        // The surface is the user's to read from here: the page-in (rise only —
                        // this emergence is the fade), the tab bar and the recap clock.
                        appModel.surfaceReady = true
                        withAnimation(ThemeMotion.pick(ThemeMotion.uiSettle, reduceMotion: reduceMotion)) {
                            emerged = true
                        }
                    },
                    onFinished: {
                        // The ident can end without `onLeaving` having fired (review i4: six
                        // captures had the app parked at 0.96 behind nothing). The surface is
                        // the user's the moment the ident is gone, whatever came before.
                        if !emerged {
                            appModel.surfaceReady = true
                            emerged = true
                        }
                        launchDone = true
                        launch.finished = true
                    })
                    .zIndex(10)
            }
        }
        .environment(launch)
        .qaReadiness(auth: auth, model: appModel)
        // The ident waits for auth's first answer before it leaves, so the screen it reveals is
        // the right one — never sign-in for a signed-in user.
        .onChange(of: auth.bootstrapped, initial: true) { _, ready in
            if ready { launch.authReady = true }
        }
        // Sign-out (chosen, or forced by an expired session) is the one moment the model outlives
        // its account: the library, the live clock, pending episode alerts and a running Live
        // Activity all survive the view tree. Tear them down here so signing in again starts clean.
        .onChange(of: auth.isSignedIn) { _, signedIn in
            if !signedIn { appModel.teardown() }
        }
        .onChange(of: auth.accountID) { previous, current in
            if let previous, previous != current, appModel.currentAccountID == previous {
                appModel.teardown()
            }
        }
        // Foreground refresh: a resumed app can be days stale (aired counts, "Out now") — the 20s
        // clock task alone can't fix data. AppModel decides how much staleness warrants a reload.
        .onChange(of: scenePhase) { _, phase in
            guard auth.isSignedIn else { return }
            switch phase {
            case .active: appModel.sceneBecameActive()
            case .background: appModel.sceneEnteredBackground()
            default: break
            }
        }
    }

}

/// Signed in: the app — or, for a NEW account, first run in its place (`AppModel+FirstRun.swift`).
///
/// Three states, never an empty Home that turns into a questionnaire a moment later: while it is
/// not yet known whether the account is new, the brand holds (`FirstRunHold`, where the launch
/// left the mark); a new account gets the flow; everyone else the tabs. When the flow reaches its
/// last screen the tabs are built BENEATH it — Home composed from the shows just placed, its
/// billboard's picture on its way — so "Go to Home" lifts the flow off a page that is already
/// there, as the launch lifts off the app.
private struct SignedInRoot: View {
    /// The viewer signed in a moment ago (the gate was up): the hold is the gate's own picture.
    var fromGate = false

    @Environment(AppModel.self) private var appModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The flow is on its last screen: Home may be built under it.
    @State private var homeUnderneath = false

    /// A suspended account is never asked questions: the tabs carry its suspension screen.
    private var phase: FirstRunPhase { appModel.accountSuspended ? .done : appModel.firstRun }

    var body: some View {
        ZStack {
            if phase == .done || (phase == .due && homeUnderneath) {
                MainTabView()
                    .accessibilityHidden(phase != .done)
            }
            if phase == .checking {
                FirstRunHold(fromGate: fromGate)
                    .transition(.opacity)
                    .zIndex(1)
            }
            if phase == .due {
                FirstRunFlow(appModel: appModel, entry: .account,
                             onLineup: { homeUnderneath = true },
                             onFinished: { appModel.finishFirstRun() })
                    .transition(.opacity)
                    .zIndex(2)
            }
        }
        .animation(ThemeMotion.pick(.easeInOut(duration: 0.38), reduceMotion: reduceMotion), value: phase)
        .onChange(of: phase) { _, phase in
            if phase != .due { homeUnderneath = false }
        }
    }
}

// The five tabs: Home (what to watch now), Schedule, the Feed, Library, Discover.
// 26 Sep — "the today screen should become Feed… feed should not be the home screen for sure", then
// the same day, of Schedule pushed from Home: "combining home with Schedule was a bad decision… Some
// people specifically want the schedule view as the muscle memory" (owner). Schedule is a tab again,
// in the slot it held before Home arrived (second). `today` IS the feed; the case keeps its name so
// every route and flag that means the feed still does.
enum AppTab: Int, CaseIterable, Hashable {
    case home, schedule, today, library, discover

    var label: String {
        switch self {
        case .home:     "Home"
        case .schedule: Copy.Schedule.title
        case .today:    "Feed"
        case .library:  "Library"
        // "Discover" (25 Sep): the tab is more than its field now — a top pick, recommendations,
        // genres and the chart — and the word is the screen's own title. VoiceOver still speaks
        // "Search anime and TV" for the field itself.
        case .discover: Copy.Discover.title
        }
    }

    // LocalizedStringKey form for the iOS 26 `Tab(_:image:value:)` initializer.
    var titleKey: LocalizedStringKey {
        switch self {
        case .home:     "Home"
        case .schedule: "Schedule"
        case .today:    "Feed"
        case .library:  "Library"
        case .discover: "Discover"
        }
    }

    /// The bar's glyphs (Hugeicons, asset-catalog templates made by icon/navbar/vector.py): the
    /// outline every tab wears, in one ink (`AppTabBar`)…
    var icon: String {
        switch self {
        case .home:     "TabHome"
        case .schedule: "TabSchedule"
        case .today:    "TabToday"
        case .library:  "TabLibrary"
        case .discover: "TabDiscover"
        }
    }

    /// …and the filled form the SELECTED tab wears instead — X's only selection mark.
    var selectedIcon: String { icon + "Fill" }
}

// The tab shell: the system `TabView` keeps each tab's stack, state and lifecycle, with its own bar
// HIDDEN; the app draws X's bar in its place (`AppTabBar`).
struct MainTabView: View {
    @Environment(AppModel.self) private var appModel
    /// The launch in progress: the app emerges through the ident, so the launch tab's page-in
    /// only rises, and the tab bar waits for the emergence.
    @Environment(LaunchHandoff.self) private var launch: LaunchHandoff?
    @State private var selectedTab: AppTab = MainTabView.launchTab
    /// One navigation path per tab; Detail and its episode list push onto the active tab's path.
    @State private var paths: [AppTab: NavigationPath] = [:]
    /// An All-titles route requested from another tab, consumed by LibraryView on arrival.
    @State private var libraryRequest: LibraryView.AllTitlesRoute?
    /// Bumped when the Library tab is re-selected: All titles is an item destination, not a path
    /// entry, so clearing the path alone left it standing and the tap did nothing.
    @State private var libraryPops = 0
    /// Bumped when Today is re-selected: the feed closes every cover and sheet and goes to its top
    /// (X's and Instagram's re-tap).
    @State private var todayPops = 0
    /// Bumped when Home is re-selected: its covers close and it goes to its top.
    @State private var homePops = 0
    @State private var tabGrounds: [AppTab: Color] = [:]
    /// Bumped by the notification routes: the feed closes every cover and sheet first, so the page
    /// the route pushes is the one on screen.
    @State private var feedDismissals = 0
    /// The feed header's scroll state, held here so the bar can ride it (`AppTabBar.scrollAway`).
    @State private var feedChrome = FeedChromeState(page: FeedCapture.initialTab)
    /// Discover's Explore header, the same (25 Sep: "Discover also needs the scroll treatment like
    /// in Today", owner).
    @State private var discoverChrome = DiscoverChromeState()
    /// Schedule's and Library's bars (`RootChromeState`, 4 Oct): their own rows now, leaving with
    /// the scroll as the feed's does, the tab bar riding them.
    @State private var scheduleChrome = RootChromeState()
    @State private var libraryChrome = RootChromeState()
    /// Home's bar over its billboard (`HomeChrome`): it leaves with the scroll too.
    @State private var homeChrome = HomeChrome()
    /// "Pick your shows" — the empty Home's button: first run's picker, on its own.
    @State private var pickingShows = false
    /// The transition namespace every card registers its artwork in (`zoomSource(_:)`).
    ///
    /// Nothing consumes it today: Detail is a push again (see `detailDestinations` for the
    /// frames that retired the zoom). The sources are kept live because they are free, and a
    /// transition that fits a full page will want them.
    @Namespace private var zoom

    private func path(_ tab: AppTab) -> Binding<NavigationPath> {
        Binding(get: { paths[tab] ?? NavigationPath() }, set: { paths[tab] = $0 })
    }

    /// `-openTab schedule|today|library|discover` (DEBUG, like `-recapDemo`): open a scripted
    /// simulator run on a given tab for captures. `-openAllTitles 1` lives on `LibraryView`.
    private static var launchTab: AppTab {
        #if DEBUG
        switch UserDefaults.standard.string(forKey: "openTab") {
        case "schedule": return .schedule
        case "today", "feed": return .today
        case "library": return .library
        case "discover", "search": return .discover
        default: return .home
        }
        #else
        return .home
        #endif
    }


    private var keyboard: KeyboardPresence { .shared }

    /// X's bar (`AppTabBar`), drawn ONCE over the `TabView` — so it holds still while a page
    /// pushes and while the tabs change — with every page, root and pushed alike, reserving its
    /// height at the foot (`tabBarReserve()`), so content ends above it rather than under it and
    /// no screen needs a clearance of its own. A safe-area inset on the `TabView` or on a tab's
    /// stack never reached the pages (each is hosted in the system's own controller): the bar
    /// covered the post page's reply bar instead of the page making room for it.
    ///
    /// ON THE FEED, AND ONLY THERE, it scrolls away with the header, as X's does (25 Sep: "it
    /// should vanish… Like X… Only in Feed", owner): it rides the header's own offset, so the two
    /// leave and return together, point for point. Everywhere else — the other tabs, and any page
    /// pushed from the feed — it stays. Under the keyboard it is gone, as X's is.
    @ViewBuilder
    private var tabBar: some View {
        if !keyboard.covering {
            AppTabBar(selected: selectedTab,
                      ground: tabGrounds[selectedTab] ?? ThemeColor.canvas,
                      scrollAway: scrollingHeader) {
                selection.wrappedValue = $0
            }
            .transition(.opacity)
        }
    }

    /// The feed itself is the page on screen (Today selected, nothing pushed on it).
    private var feedInFront: Bool {
        selectedTab == .today && (paths[.today] ?? NavigationPath()).isEmpty
    }

    /// Discover's Explore is the page on screen.
    private var discoverInFront: Bool {
        selectedTab == .discover && (paths[.discover] ?? NavigationPath()).isEmpty
    }

    /// The header the bar rides: the root in front's own (every tab has one since 4 Oct); none
    /// on a pushed page, which keeps the bar.
    private var scrollingHeader: (any ScrollAwayChrome)? {
        guard (paths[selectedTab] ?? NavigationPath()).isEmpty else { return nil }
        return rootChrome(selectedTab)
    }

    /// The first-run question is due and there is a place to ask it.
    private var audienceQuestion: Binding<Bool> {
        Binding(get: { appModel.audiencePromptDue && !appModel.accountSuspended && (launch?.finished ?? true) },
                set: { if !$0 { appModel.audiencePromptDue = false } })
    }

    /// How deep the tab in front has pushed.
    private var frontDepth: Int { paths[selectedTab]?.count ?? 0 }

    private func rootChrome(_ tab: AppTab) -> any ScrollAwayChrome {
        switch tab {
        case .home: return homeChrome
        case .schedule: return scheduleChrome
        case .today: return feedChrome
        case .library: return libraryChrome
        case .discover: return discoverChrome
        }
    }

    /// Re-selecting the active tab pops it to its root (system behaviour, made explicit).
    private var selection: Binding<AppTab> {
        Binding(get: { selectedTab }, set: { tab in
            if tab == selectedTab {
                paths[tab] = NavigationPath()
                if tab == .library { libraryPops += 1 }
                if tab == .today { todayPops += 1 }
                if tab == .home { homePops += 1 }
                rootChrome(tab).reveal()
            } else {
                // Arriving on a tab, the bar that was just tapped does not slide away under the
                // finger: the header (which the bar rides) comes back first.
                rootChrome(tab).reveal()
                selectedTab = tab
            }
        })
    }


    var body: some View {
        ZStack(alignment: .bottom) {
            TabView(selection: selection) {
                Tab(AppTab.home.titleKey, image: AppTab.home.icon, value: AppTab.home) {
                    NavigationStack(path: path(.home)) {
                        // Home is the landing (26 Sep): what you can watch now. The calendar is the
                        // Schedule TAB (its links switch to it), and Profile's door is the bar's disc.
                        HomeView(onOpenDetail: openEpisode,
                                 onOpenSchedule: { selection.wrappedValue = .schedule },
                                 onOpenLibrary: { status in
                                     libraryRequest = .init(status: status)
                                     selectedTab = .library
                                 },
                                 onOpenRoute: { push(.home, $0) },
                                 onAddShow: {
                                     appModel.searchFieldRequested = true
                                     selectedTab = .discover
                                 },
                                 onPickShows: { pickingShows = true },
                                 topSignal: homePops,
                                 dismissSignal: feedDismissals,
                                 chrome: homeChrome)
                            .detailDestinations(push: { push(.home, $0) })
                            .perfScreen("Home")
                            .tabBarReserve()
                    }
                    .tint(ThemeColor.interactive)
                    .pageInTransition(isActive: selectedTab == .home && appModel.surfaceReady, fadeIn: launch?.finished ?? true)
                    .systemTabBarHidden()
                    .environment(\.tabBarGroundChanged, { tabGrounds[.home] = $0 })
                }
                Tab(AppTab.schedule.titleKey, image: AppTab.schedule.icon, value: AppTab.schedule) {
                    NavigationStack(path: path(.schedule)) {
                        ScheduleView(onOpenDetail: openEpisode,
                                     onAddShow: { appModel.searchFieldRequested = true; selectedTab = .discover },
                                     active: selectedTab == .schedule && appModel.surfaceReady,
                                     rootChrome: scheduleChrome)
                            .detailDestinations(push: { push(.schedule, $0) })
                            .perfScreen("Schedule")
                            .tabBarReserve()
                    }
                    .tint(ThemeColor.interactive)
                    .pageInTransition(isActive: selectedTab == .schedule && appModel.surfaceReady, fadeIn: launch?.finished ?? true)
                    .systemTabBarHidden()
                    .environment(\.tabBarGroundChanged, { tabGrounds[.schedule] = $0 })
                }
                Tab(AppTab.today.titleKey, image: AppTab.today.icon, value: AppTab.today) {
                    NavigationStack(path: path(.today)) {
                        // Today IS the feed (25 Sep). Profile's only entry is the feed header's
                        // disc; its Library tiles take the same filtered All-titles route Library's
                        // own "See all" does.
                        FeedView(onOpenDetail: openDetail,
                                 onOpenRoute: { push(.today, $0) },
                                 onOpenLibrary: { status in
                                     libraryRequest = .init(status: status)
                                     selectedTab = .library
                                 },
                                 onAddShow: {
                                     appModel.searchFieldRequested = true
                                     selectedTab = .discover
                                 },
                                 onOpenRecommendations: {
                                     push(.today, FranchiseDetailView.DetailPush.recommendations)
                                 },
                                 topSignal: todayPops,
                                 dismissSignal: feedDismissals,
                                 chrome: feedChrome)
                            .detailDestinations(push: { push(.today, $0) })
                            .perfScreen("Today")
                            .tabBarReserve()
                    }
                    .tint(ThemeColor.interactive)
                    .pageInTransition(isActive: selectedTab == .today && appModel.surfaceReady, fadeIn: launch?.finished ?? true)
                    .systemTabBarHidden()
                    .environment(\.tabBarGroundChanged, { tabGrounds[.today] = $0 })
                }
                Tab(AppTab.library.titleKey, image: AppTab.library.icon, value: AppTab.library) {
                    NavigationStack(path: path(.library)) {
                        LibraryView(onOpenDetail: openDetail,
                                    onAddShow: { appModel.searchFieldRequested = true; selectedTab = .discover },
                                    requestedAll: $libraryRequest,
                                    popSignal: libraryPops,
                                    chrome: libraryChrome)
                            .detailDestinations(push: { push(.library, $0) })
                            .perfScreen("Library")
                            .tabBarReserve()
                    }
                    .tint(ThemeColor.interactive)
                    .pageInTransition(isActive: selectedTab == .library && appModel.surfaceReady, fadeIn: launch?.finished ?? true)
                    .systemTabBarHidden()
                    .environment(\.tabBarGroundChanged, { tabGrounds[.library] = $0 })
                }
                // An ORDINARY tab, not the search role: the field lives under the title on the
                // screen itself (Apple Music's Search — user reference, 24 Aug).
                Tab(AppTab.discover.titleKey, image: AppTab.discover.icon, value: AppTab.discover) {
                    NavigationStack(path: path(.discover)) {
                        DiscoverView(onOpenDetail: openDetail,
                                     onOpenRecommendations: {
                                         push(.discover, FranchiseDetailView.DetailPush.recommendations)
                                     },
                                     chrome: discoverChrome)
                            .detailDestinations(push: { push(.discover, $0) })
                            .perfScreen("Discover")
                            .tabBarReserve()
                    }
                    .tint(ThemeColor.interactive)
                    .pageInTransition(isActive: selectedTab == .discover && appModel.surfaceReady, fadeIn: launch?.finished ?? true)
                    .systemTabBarHidden()
                    .environment(\.tabBarGroundChanged, { tabGrounds[.discover] = $0 })
                }
            }
            .environment(\.zoomNamespace, zoom)
            // Back on the feed from a page pushed on it: the header — and the bar with it — are
            // there to meet the reader, not left wherever the feed's scroll had put them.
            // A push or a pop on the tab in front brings its root's bars back: a pushed page keeps
            // the tab bar, and a root is returned to with its header in place.
            .onChange(of: frontDepth) { _, _ in rootChrome(selectedTab).reveal() }
            // No haptic on a tab switch (review, 5 Sep): Music, TV and the App Store are silent
            // on the most frequent gesture in the app; a haptic is a signature for a WRITE.
            // A tapped episode alert opens its show — on Today, above whatever was there.
            .onChange(of: appModel.pendingOpen, initial: true) { _, id in
                guard let id else { return }
                // Opened FOR this show: the launch film gives way at once.
                if let launch, !launch.finished { launch.intent = true }
                appModel.pendingOpen = nil
                // The feed closes whatever it has up (a story, a sheet) before the page arrives.
                feedDismissals += 1
                selectedTab = .home
                paths[.home] = NavigationPath([DetailRoute(id: id, zoomID: "alert/\(id)")])
            }
            // A tapped reminder or an Activity-style route: a post page or a thread, on Today.
            .onChange(of: appModel.pendingRoute, initial: true) { _, route in
                guard let route else { return }
                if let launch, !launch.finished { launch.intent = true }
                appModel.pendingRoute = nil
                feedDismissals += 1
                selectedTab = .today
                switch route {
                case .show(let id):
                    // Delivered through `pendingOpen` (PreviouslyApp); handled here for completeness.
                    paths[.today] = NavigationPath([DetailRoute(id: id, zoomID: "alert/\(id)")])
                case .post(let postId, let commentId):
                    paths[.today] = NavigationPath([FeedRoute.post(id: postId, focusCommentId: commentId)])
                case .thread(let subject, let franchiseId, let commentId):
                    if let ep = ThreadSubject.parseEpisode(subject) {
                        paths[.today] = NavigationPath([FeedRoute.episode(franchiseId: franchiseId, mediaId: ep.mediaId,
                                                                          episode: ep.episode, focusCommentId: commentId)])
                    } else {
                        paths[.today] = NavigationPath([FeedRoute.post(id: subject, focusCommentId: commentId)])
                    }
                }
            }
            // Back online: the social words queued while offline (likes, saves, reminders, hides),
            // the replies waiting to send and the rewatch history's changes go now.
            .onChange(of: SyncCenter.shared.isOnline) { _, online in
                if online { appModel.flushSocial(); appModel.flushWatchSessions() }
            }
            .task {
                KeyboardMotion.install()
                KeyboardPresence.shared.install()
                KeyboardWarmup.install()
                // One freshness source for every stale strip and Profile's sync line.
                SyncCenter.shared.signals = {
                    .init(lastLoadedAt: appModel.lastLoadedAt, loading: appModel.loading)
                }
                SyncCenter.shared.startMonitoring()
                #if DEBUG
                ToastDemo.arm(appModel)
                if UserDefaults.standard.bool(forKey: "verifyArtworkIdentity") {
                    ArtworkIdentityRegression.run()
                }
                if UserDefaults.standard.bool(forKey: "verifyAnnouncements") {
                    AnnouncementRegression.run()
                }
                // `-verifyCopy 1`: the copy table's own audit (the ellipsis rule and friends),
                // which otherwise only a preview renders.
                if UserDefaults.standard.bool(forKey: "verifyCopy") {
                    let problems = Copy.auditProblems
                    print(problems.isEmpty ? "COPY_AUDIT_PASS" : "COPY_AUDIT_FAIL \(problems)")
                }
                if UserDefaults.standard.bool(forKey: "verifyDetailProgress") {
                    await DetailProgressRegression.run()
                }
                // `-verifyImport 1`: the export-file readers (zip, gzip, CSV, the three shapes).
                if UserDefaults.standard.bool(forKey: "verifyImport") {
                    ImportRegression.run()
                }
                // `-verifyFeed 1`: the feed's pure rules (composer, counting, routes) against fixtures.
                if UserDefaults.standard.bool(forKey: "verifyFeed") {
                    FeedRegression.run()
                }
                // `-discoverGenre <key>` (FeedCapture), with `-openTab discover`: a genre page.
                if let key = FeedCapture.discoverGenre {
                    selectedTab = .discover
                    paths[.discover] = NavigationPath([DiscoverRoute.genre(key: key, name: key.capitalized)])
                }
                // Read-only capture route; never changes library status or progress.
                if let id = UserDefaults.standard.string(forKey: "openFranchise"), !id.isEmpty {
                    selectedTab = .home
                    paths[.home] = NavigationPath([DetailRoute(id: id, zoomID: "capture/\(id)")])
                }
                #endif
            }

            tabBar
                .ignoresSafeArea(.keyboard, edges: .bottom)

            // The receipt lane, the sync banner and the notices float just above the bar, over
            // whatever is pushed, on the page's gutter. This ZStack is aligned to the safe area's
            // bottom (the home indicator, or the keyboard's top), not to the bar, so the lift is
            // the bar's own height while the bar is up.
            ToastHost()
                .padding(.horizontal, ThemeMetrics.gutter)
                .padding(.bottom, (keyboard.covering ? 0 : AppTabBar.reservedHeight) + ThemeSpace.x3)

            // A suspended account (iD14): the app is covered — Sign out and Delete account only.
            if appModel.accountSuspended {
                AccountSuspendedView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity)
                    .zIndex(30)
            }
        }
        .animation(ThemeMotion.uiGentle, value: appModel.accountSuspended)
        // "What do you watch?" — asked once per account, when the app has emerged and the account
        // has no answer (`AppModel.syncAudience`). Not over a suspension, and not under the launch.
        .sheet(isPresented: audienceQuestion) {
            AudienceChooser(mode: .firstRun, onDone: { appModel.audiencePromptDue = false })
        }
        .fullScreenCover(isPresented: $pickingShows) {
            FirstRunFlow(appModel: appModel, entry: .shows, onFinished: { pickingShows = false })
                .environment(appModel)
        }
        // The text-input stack, loaded while the person is still reading Today (`KeyboardWarmup`):
        // only if they have not moved on — a tab switched or a page pushed means the moment has
        // passed, and the first field will pay for itself.
        .task(id: appModel.surfaceReady) {
            guard appModel.surfaceReady else { return }
            try? await Task.sleep(for: KeyboardWarmup.delay)
            guard !Task.isCancelled, selectedTab == MainTabView.launchTab,
                  (paths[selectedTab] ?? NavigationPath()).isEmpty,
                  // Not under a feed cover or sheet (a story, a composer): its own field may be up.
                  !appModel.feedOverlayOpen else { return }
            // Not over a banner or a lane: the unseen keyboard's safe-area inset would move them.
            KeyboardWarmup.warm(allowed: appModel.laneItem == nil && SyncCenter.shared.failedChanges.isEmpty)
        }
    }

    private func push(_ tab: AppTab, _ value: any Hashable) {
        var p = paths[tab] ?? NavigationPath()
        p.append(value)
        paths[tab] = p
    }

    /// Navigation is silent (board 11): no haptic on open.
    private func openDetail(_ id: String, zoomID: String) {
        push(selectedTab, DetailRoute(id: id, zoomID: zoomID))
    }

    /// Episode context selects the season when the viewer opens Episodes. The show still opens
    /// at its common header, just like Library, Search, a post or a recommendation.
    private func openEpisode(_ id: String, zoomID: String, focus: EpisodeFocus?) {
        push(selectedTab, DetailRoute(id: id, zoomID: zoomID, focus: focus))
    }
}

extension View {
    /// The system tab bar, hidden for good: the app draws X's (`AppTabBar`). Applied to every
    /// tab's stack and again on every pushed screen (`pushedScreenChrome`), so no push can bring
    /// the system's pill back over the app's bar.
    func systemTabBarHidden() -> some View {
        toolbarVisibility(.hidden, for: .tabBar)
    }
}

private extension View {

    /// The two destinations every tab can reach: a franchise, and a season's episode list.
    ///
    /// Detail is a PUSH — the system slide, the transition Apple TV, Disney+ and Crunchyroll open
    /// a show with. It was `.zoom` from the tapped artwork (2 Sep) and the frames say why that is
    /// wrong here: the zoom scales the WHOLE destination into the source's frame, so for its
    /// first 150 ms the show page was a miniature of itself — billboard, pill, title and amber
    /// capsule squeezed into a 60×90 poster — inflating ("the details opening motion is just
    /// trash", user, 3 Sep). The HIG reserves zoom for a destination that IS the source, larger
    /// (a photo, a card's own art); a page with a landscape billboard cropped from a different
    /// picture is not that. The `zoomSource` registrations stay: they cost nothing and are the
    /// hook if a transition that fits ever arrives.
    ///
    /// The feed's pages (`FeedRoute`) and Discover's (`DiscoverRoute`) are path VALUES registered
    /// here too (iD12): re-selecting Today and the notification route reset the path, and a value
    /// on it goes with it. `push` takes any path value, so a post page can open a show and a genre
    /// page a title.
    func detailDestinations(push: @escaping (any Hashable) -> Void) -> some View {
        self
            .navigationDestination(for: DetailRoute.self) { route in
                FranchiseDetailView(franchiseId: route.id, focus: route.focus, push: { push($0) })
                    .pushedScreenChrome()
                    .perfScreen("Detail")
            }
            .navigationDestination(for: FranchiseDetailView.DetailPush.self) { p in
                Group {
                    switch p {
                    case .episodes(let franchiseId, let mediaId, let focusEpisode):
                        SeasonEpisodesView(franchiseId: franchiseId, mediaId: mediaId, focusEpisode: focusEpisode)
                            .perfScreen("Episodes")
                    case .history(let franchiseId):
                        WatchHistoryView(franchiseId: franchiseId)
                            .perfScreen("History")
                    case .detail(let franchiseId):
                        // A related title, opened from a show page: the same page, one deeper.
                        FranchiseDetailView(franchiseId: franchiseId, push: { push($0) })
                            .perfScreen("Detail")
                    case .recommendations:
                        RecommendationsView { id in push(FranchiseDetailView.DetailPush.detail(franchiseId: id)) }
                            .perfScreen("ForYou")
                    case .post(let id):
                        // A post from a show's timeline: its page, as the feed opens it.
                        FeedThreadView(postId: id, focusCommentId: nil, push: push)
                            .perfScreen("Post")
                    }
                }
                // The pushed-screen scaffold belongs here, not to six per-screen opt-ins: every
                // push inherits the list's end margin and the hidden system bar.
                .pushedScreenChrome()
            }
            .navigationDestination(for: FeedRoute.self) { route in
                switch route {
                case .post(let id, let focus):
                    FeedThreadView(postId: id, focusCommentId: focus, push: push)
                        .pushedScreenChrome()
                        .perfScreen("Post")
                case .episode(let franchiseId, let mediaId, let episode, let focus):
                    EpisodeDiscussionView(franchiseId: franchiseId, mediaId: mediaId, episode: episode,
                                          presentation: .page, focusCommentId: focus,
                                          onOpenShow: { push(FranchiseDetailView.DetailPush.detail(franchiseId: $0)) })
                        .pushedScreenChrome()
                        .perfScreen("Discussion")
                case .saved:
                    SavedPostsView(onOpenPost: { push(FeedRoute.post(id: $0)) },
                                   onOpenShow: { push(FranchiseDetailView.DetailPush.detail(franchiseId: $0)) })
                        .pushedScreenChrome()
                        .perfScreen("Saved")
                }
            }
            .navigationDestination(for: DiscoverRoute.self) { route in
                switch route {
                case .genre(let key, let name):
                    GenreResultsView(genreKey: key, name: name,
                                     onOpenDetail: { push(FranchiseDetailView.DetailPush.detail(franchiseId: $0)) })
                        .pushedScreenChrome()
                        .perfScreen("Genre")
                }
            }
    }
}
