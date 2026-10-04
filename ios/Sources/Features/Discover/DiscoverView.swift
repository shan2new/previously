import SwiftUI
import UserNotifications

// Search (spec board 07). Empty query = the launchpad; a query = results.
//
// Fix round 1. The panel scored this the lowest screen in the build (median 3.5). What changed:
//
//  • **The field is the system's again.** `Tab(value:role: .search)` exists specifically to pair
//    with `.searchable`, and the screen hand-rolled a `TextField` inside a header with the
//    navigation bar hidden — throwing away the iOS 26 search morph, Cancel, the scope bar, the
//    keyboard's return semantics and the localised prompt, and gaining nothing. `.searchable` +
//    `.searchScopes` now do all of it, which also deletes the hand-drawn scope pills (a segmented
//    control drawn as three outlined web buttons) and the Material-Design progress rail that sat
//    under the field for an indeterminate network call.
//  • **One add control.** It used to be ~25 pt over art, 55×43 in a row and a bare grey checkmark
//    once added — three anatomies, one of them below the touch minimum, one of them not a control
//    at all. `AddControl` is one component, 44 pt, same width in both states, live in both.
//  • **One ranking.** Ranks 01–04 were poster cards and 05+ were text rows with the numeral in a
//    separate 50-pt gutter at `textDisabled`. Now: TOP 3 on the shelf, MORE TRENDING as rows, one
//    gutter, one add control.
//  • **The payoff frame is never emptier than the question.** A single result used to be one card
//    under a "TOP MATCH" label with 900 pt of black beneath it, and both the no-results and the
//    error state threw away artwork already decoded in order to say one sentence. Trending stays
//    mounted underneath in every one of those states, and the result count gives the void a
//    boundary.
//  • **"Parts" is gone**, the kind leads every result's metadata (the anime One Piece and the
//    live-action One Piece were distinguishable only by capitalisation at the moment of adding),
//    and `correctedQuery` — decoded since day one and read by nothing — is on screen.
//
// Fix round 2 (the audit). The rows and the shelf are the app's `MediaRow` and `ShelfCard` — the
// same objects Library, Schedule and Detail render — instead of a third hand-rolled pair; the
// owned tick opens a status menu instead of unsubscribing on contact; a failed catalogue is named
// above the rows that did arrive; the scope filters the chart as well as the results; and every
// string on the screen lives in `Copy.Search`.
struct DiscoverView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    let onOpenDetail: (_ franchiseId: String, _ zoomID: String) -> Void
    /// "Recommended for you ›" — the longer list, on this tab's stack.
    var onOpenRecommendations: (() -> Void)? = nil
    /// The Explore header's scroll state, held by the tab so the bottom bar can ride it.
    let chrome: DiscoverChromeState

    /// The wire marker for a catalogue that failed (`docs/api-contract.md`, `sources`). Not copy.
    private static let failedMarker = "failed"

    /// The scroll view's own height, for centring a state that owns the whole surface.
    @State private var contentH: CGFloat = 0

    /// `.searchable(isPresented:)`. Raised by `AppModel.searchFieldRequested` — an "Add a show"
    /// CTA on another tab asked for the field itself, not just this tab.
    @State private var fieldPresented = false
    /// The owned add control's "Mark all N episodes as watched…", awaiting its confirmation
    /// (`markAllConfirmation` — the long press's and the show page's).
    @State private var markAll: MarkAllRequest?
    /// A term the field SUBMITTED, waiting on its answer before it is remembered
    /// (`settleRecentTerm`).
    @State private var submittedTerm: String?

    // MARK: Notification primer (see `notificationPrimer`)

    /// An add that stuck armed the primer. Persisted, because the ask is deferred well past the
    /// undo window and the user may leave the tab in the meantime — a `@State` flag would drop it.
    @AppStorage("previously.notifPrimerPending") private var primerPending = false
    /// An airing show whose Add was taken to its page (`add`): the primer is armed on return.
    @State private var primerCandidate: FranchiseSummary?
    /// The user has answered the primer once. iOS only ever shows its own alert once per install,
    /// so the primer is one-shot too: it is the thing that earns that one alert.
    @AppStorage("previously.notifPrimerAnswered") private var primerAnswered = false
    /// The viewer's leaning for the genre art in All (`GenreArt.leaningKey`; a toggle will set it).
    @AppStorage(GenreArt.leaningKey) private var genreLeaning = GenreArt.Flavour.anime.rawValue
    /// Resolved from `UNUserNotificationCenter`: only `.notDetermined` can still be asked.
    @State private var canAskForNotifications = false
    @State private var primerVisible = false

    /// Minute precision is all a "New episode tomorrow" needs; observing the 20-second tick would
    /// re-lay out every row on the screen three times a minute for nothing.
    private var now: Int64 { appModel.nowMinute }
    private var query: String { appModel.searchQuery.trimmingCharacters(in: .whitespaces) }
    /// Where the bar's chrome ends: title + drawer at rest; once the field has focus the title
    /// collapses and only the field's band remains. The hardened veil and its probe follow it —
    /// sized to the resting chrome, the veil swallowed the grid's header the moment the field was
    /// tapped (captured 2 Sep).
    private var searchChromeBottom: CGFloat {
        fieldPresented
            ? ThemeMetrics.topSafeInset + ThemeMetrics.searchDrawerHeight
            : ThemeMetrics.inlineBarBottom + ThemeMetrics.searchDrawerHeight
    }
    private var isAX: Bool { typeSize.isAccessibilitySize }

    /// The ambient wash is keyed to the chart's leader: a poster this screen is already loading,
    /// so the atmosphere costs one decode and never changes under the user mid-session — not even
    /// when the scope hides it from the chart.
    private var washURL: String? { appModel.trending.first?.portraitArt }

    var body: some View {
        @Bindable var model = appModel
        // The probe's line per body (inert unless `-perfProbe 1`): a focus that re-runs this body
        // more than once is a focus with our work in it.
        PerfProbe.mark("search-body")
        // Computed ONCE per body and handed down. `filteredSearchResults` is a filter over the
        // whole result set and the body used to read it eight times — and the duplicate-title scan
        // inside `ResultSet` ran once per ROW on top of that.
        let results = ResultSet(appModel.filteredSearchResults)
        // The chart honours the scope. With TV selected the results were TV-only and the chart
        // underneath them still led with an anime, so the scope bar appeared to govern half the
        // screen.
        let trending = appModel.trending.filter { appModel.matchesMediaFilter($0.source) }
        let searching = fieldPresented || !query.isEmpty
        return ZStack(alignment: .top) {
            // Flat, as Today is: no wash behind the title and the field (25 Sep, `flushTopBar`).
            ThemeColor.canvas.ignoresSafeArea()
            // AT REST: X's and Instagram's Explore (`DiscoverExplore`) — For you, Trending, Genres.
            // It stays MOUNTED under the search surface (5 Sep: tearing the launchpad down on the
            // first letter and rebuilding it on Cancel was the lag the user felt); the field only
            // fades it.
            DiscoverExplore(recommendations: scopedRecommendations,
                            trending: trending,
                            genres: DiscoverCatalog.shared.genres(for: appModel.mediaFilter),
                            genreFlavour: GenreArt.flavour(for: appModel.mediaFilter, leaning: genreLeaning),
                            reason: { appModel.spokenReason($0) },
                            trendFacts: { trendFacts($0) },
                            trendTrailing: { AnyView(addControl($0, placement: .pill)) },
                            trendAdd: { AnyView(addControl($0, placement: .overArt)) },
                            spoken: { spoken($0, ambiguous: []) },
                            onOpenRecommendation: { openRecommendation($0) },
                            onOpenShow: { open($0, zoom: "trend/\($0.id)") },
                            onRefresh: { [catalog = DiscoverCatalog.shared, api = appModel.api, filter = appModel.mediaFilter] in
                                await appModel.refreshTrending()
                                await catalog.loadGenres(api: api, filter: filter, force: true)
                            },
                            header: primerVisible ? AnyView(notificationPrimer) : nil,
                            chrome: chrome,
                            searchPrompt: Copy.Search.prompt(for: appModel.mediaFilter),
                            onSearch: { fieldPresented = true },
                            // One audience has no scope to choose (`Audience`).
                            scope: appModel.audience.isSingle ? AnyView(EmptyView()) : AnyView(scopeMenu),
                            searching: searching)
                .opacity(searching ? 0 : 1)
                .allowsHitTesting(!searching)
                .accessibilityHidden(searching)
            // SEARCHING: the recents while the field is empty, the results once it is not.
            if searching {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if query.isEmpty {
                            if appModel.recentItems.isEmpty && appModel.recentSearches.isEmpty {
                                if !trending.isEmpty {
                                    trendingGrid(trending)
                                        .padding(.top, ThemeSpace.x3)
                                }
                            } else {
                                recentsList
                                    .padding(.top, ThemeSpace.x2)
                            }
                        } else {
                            searchBody(results, trending: trending)
                        }
                        // BELOW the results (interactive review: inserted above them it moved the
                        // row just tapped 88 pt down under the finger).
                        if primerVisible { notificationPrimer.padding(.top, ThemeSpace.x4) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .animation(ThemeMotion.pick(ThemeMotion.uiGentle, reduceMotion: reduceMotion), value: query.isEmpty)
                }
                .scrollIndicators(.hidden)
                .scrollDismissesKeyboard(.interactively)
                .laneClearance(appModel)
                .tabBarContentMargin()
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentH = $0 }
                .transition(.opacity)
            }
        }
        .animation(ThemeMotion.pick(ThemeMotion.keyboard, reduceMotion: reduceMotion), value: searching)
        // The genre tiles for the scope (the Genres page, and a genre page's chips); a fresh list
        // (30 min) is not re-asked.
        .task(id: appModel.mediaFilter) {
            await DiscoverCatalog.shared.loadGenres(api: appModel.api, filter: appModel.mediaFilter)
        }
        // The top edge belongs to the navigation bar and the search field now, so only the bottom
        // is ours — but it IS ours in both states. `scrollDismissesKeyboard(.interactively)` means
        // a scrolled results list ends up with the tab bar, not the keyboard, over its last row,
        // and the shipped build passed `bottom: false` on the assumption the keyboard owned the
        // bottom: which is how a saturated poster came to refract a doubled, mirrored show title
        // through the tab bar's glass and put an amber rim on the *Today* pill while Search was
        // the active tab.
        // The bottom edge is ours; the TOP is the bar's own veil (`rootBarVeil`) — the same
        // gradient the tab bar's edge carries, "relayed upwards" to the title (user, 24 Aug), drawn
        // from the very top of the screen — over the wash the navigation container paints
        // (`rootWash`): the launchpad used to open on flat near-black while every other root
        // carried its art.
        // Only while searching: at rest the Explore header is the bar, and it slides away with the
        // page (Today's treatment, 25 Sep) — a flush band here would cover what it slid off.
        .flushTopBar(searching ? searchChromeBottom : 0)
        .toolbarBackground(.hidden, for: .navigationBar)
        .chromeScrollEdgeHidden(.top)
        // Inline on every root (user decision): the field is the screen's identity here, and a
        // large title over it put two headlines on one screen.
        // "Discover" — the tab's name (ios-spec §3.1). The field keeps `Copy.Search`'s prompt, so
        // VoiceOver hears "Discover" for the screen and "Search anime and TV" for the field.
        .navigationTitle(Copy.Discover.title)
        .navigationBarTitleDisplayMode(.inline)
        // At rest the bar is the Explore header's own (`DiscoverExplore`: X's search pill, the
        // scope, the tabs), sliding away with the page as Today's does; the system bar and its
        // field come up only to SEARCH — the pill hands over to them.
        .toolbar(searching ? .visible : .hidden, for: .navigationBar)
        // The scope (All / Anime / TV) is a menu in the bar, as Schedule's filter is — X's Explore
        // keeps its settings there; the resting chips went with the launchpad.
        .toolbar {
            if !appModel.audience.isSingle {
                ToolbarItem(placement: .topBarTrailing) { scopeMenu }
            }
        }
        // The field lives UNDER the title, always — Apple Music's Search (user reference, 24 Aug):
        // title, field, then the browse grid; focused, the field pins to the top with Cancel, the
        // scope bar appears and the recents take the page. Search is an ordinary tab in the one
        // tab pill now, not the separated search island, which is what let the field move here.
        // The prompt names the VERB, not the domain, and it follows the scope — see
        // `Copy.Search.prompt(for:)`.
        .searchable(text: $model.searchQuery, isPresented: $fieldPresented,
                    placement: .navigationBarDrawer(displayMode: .always),
                    prompt: Copy.Search.prompt(for: appModel.mediaFilter))
        // A catalogue query is not a sentence. Without these the system field capitalises the
        // first letter and autocorrects romaji titles into English words ("Sousou" → "Season"),
        // both of which the hand-rolled field had correctly turned off.
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        // `.onTextEntry`: the scope bar is a RESULTS control and appears with the first
        // keystroke. On the focused-but-empty page it was a full-width pill pushing the recents
        // down for a choice that had nothing to filter yet; the bar's scope menu (`scopeMenu`)
        // chooses and shows the scope at rest instead.
        .searchScopes($model.mediaFilter, activation: .onTextEntry) {
            // No scopes for one audience: an empty builder draws no bar.
            ForEach(appModel.audience.isSingle ? [] : MediaFilter.allCases, id: \.self) { filter in
                // The segment labels are ours; the bar around them is the system's. At AX1 they
                // were measured at exactly the same cap height as at the default size — the only
                // controls on the screen still at default size, so the whole bar read as a strip
                // borrowed from another app. A text style, so they scale with everything else.
                Text(Copy.Search.scopeWord(filter))
                    .type(ThemeType.metadataEmphasis)
                    .tag(filter)
            }
        }
        // The field always carried a `.search` return key and then threw the submission away, so
        // RECENT could only ever hold terms left over from an older build. A submission is the
        // only thing that writes a TERM — and only once its answer says it was not a slip
        // (`settleRecentTerm`).
        .onSubmit(of: .search) {
            submittedTerm = query
            settleRecentTerm()
        }
        .onAppear {
            appModel.loadTrendingIfNeeded()
            consumeFieldRequest()
            if let item = primerCandidate {
                primerCandidate = nil
                if appModel.isInLibrary(item.id) { armNotificationPrimer(item) }
            }
            #if DEBUG
            // `-openSearchField 1` (DEBUG, like `-recapDemo`): open with the field focused. A
            // beat after appearance, or the searchable binding's first sync overwrites it.
            if UserDefaults.standard.bool(forKey: "openSearchField") {
                Task { try? await Task.sleep(for: .milliseconds(700)); fieldPresented = true }
            }
            // `-searchQuery <text>`: the results for a query, for captures — the field is focused
            // and the text entered as if typed (no write; recents are recorded only on submit).
            if let q = UserDefaults.standard.string(forKey: "searchQuery"), !q.isEmpty {
                Task {
                    try? await Task.sleep(for: .milliseconds(900))
                    fieldPresented = true
                    appModel.searchQuery = q
                }
            }
            #endif
        }
        // The CTA may fire while this tab is already mounted, in which case `onAppear` does not.
        .onChange(of: appModel.searchFieldRequested) { _, requested in
            if requested { consumeFieldRequest() }
        }
        .onChange(of: fieldPresented) { _, presented in
            PerfProbe.mark(presented ? "search-presented" : "search-dismissed")
        }
        // Searching, the header (and the bottom bar riding it) is all there again.
        .onChange(of: searching) { _, now in
            if now { chrome.reveal() }
        }
        .markAllConfirmation($markAll, appModel: appModel)
        .modifier(DiscoverCapture(onOpenDetail: onOpenDetail))
        .task(id: appModel.library.count) { await refreshNotificationEligibility() }
        .task { await refreshNotificationEligibility() }
        // WCAG 4.1.3. A VoiceOver user typed a query and results arrived, or didn't, or failed,
        // and nothing was spoken.
        .onChange(of: appModel.searchBusy) { _, busy in
            guard !busy else { return }
            settleRecentTerm()
            guard !query.isEmpty else { return }
            announceOutcome()
        }
        // No haptic: choosing a scope (the chips, the scope bar, a genre page's chips — all one
        // `mediaFilter`) is not a write, and a haptic is a write's signature (CLAUDE.md).
        .onChange(of: appModel.mediaFilter) { _, _ in
            guard !query.isEmpty, !appModel.searchBusy else { return }
            announceOutcome()
        }
    }

    /// The scope menu: filled while a scope is on, so a filtered Discover says so in the bar.
    private var scopeMenu: some View {
        @Bindable var model = appModel
        return Menu {
            Picker(Copy.Discover.scopeMenu, selection: $model.mediaFilter) {
                ForEach(MediaFilter.allCases, id: \.self) { filter in
                    Text(Copy.Search.scopeWord(filter)).tag(filter)
                }
            }
            .pickerStyle(.inline)
        } label: {
            AppGlyph(systemName: appModel.mediaFilter == .all
                  ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill")
        }
        .tint(appModel.mediaFilter == .all ? ThemeColor.textPrimary : ThemeColor.accent)
        .accessibilityLabel(Copy.Discover.scopeMenu)
        .accessibilityValue(Copy.Search.scopeWord(appModel.mediaFilter))
    }

    /// "Add a show" elsewhere asked for the field. Present it once and clear the request, so a
    /// later plain tab switch does not re-raise the keyboard.
    private func consumeFieldRequest() {
        guard appModel.searchFieldRequested else { return }
        fieldPresented = true
        appModel.searchFieldRequested = false
    }

    // MARK: - The notification ask

    /// **The system permission alert is never raised by an add.**
    ///
    /// `addToLibrary` used to set the undo state and then immediately raise the notification
    /// prompt, so the app's first-ever permission ask arrived unprimed, in the middle of an
    /// unrelated action, over the trending grid — with "Added … — Undo" counting down *underneath*
    /// a modal the user could not dismiss without answering. The Undo was unreachable for its whole
    /// six seconds and had expired by the time they got back to it, VoiceOver focus was stolen, and
    /// the reflex answer to an unexplained ask is Don't Allow — after which iOS never asks again
    /// and episode alerts are dead for that account permanently.
    ///
    /// So: the add arms this, and nothing else happens for the whole undo window. Once the add has
    /// *stuck*, the user gets a card that says what the permission buys, on their own screen, with
    /// a control they choose to press. The system alert only ever follows the user asking for it,
    /// which is what the HIG requires. Answered once, either way, it never appears again — Profile →
    /// Notifications is the permanent route.
    @ViewBuilder
    private var notificationPrimer: some View {
        // A row on the canvas, in the app's own row grammar: a glyph, a title, one line, and the
        // answer as a link. It was a plate with a bell in a tile, a paragraph and a full-width
        // amber capsule — a promo card from a marketing site, on a search screen.
        // At accessibility sizes the words take the full width and the answers drop to their
        // own line; beside two controls the sentence was wrapping one word per line.
        let layout = isAX
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: ThemeSpace.x2))
            : AnyLayout(HStackLayout(alignment: .center, spacing: ThemeMetrics.artGap))
        layout {
            HStack(alignment: .center, spacing: ThemeMetrics.artGap) {
                AppGlyph(systemName: "bell.badge")
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(ThemeColor.textTertiary)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: ThemeMetrics.titleGap) {
                    Text(Copy.Search.primerTitle)
                        .type(ThemeType.rowTitle)
                        .foregroundStyle(ThemeColor.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(Copy.Search.primerBody)
                        .type(ThemeType.rowMeta)
                        .foregroundStyle(ThemeColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: ThemeSpace.x2) {
                Button(Copy.Search.primerTurnOn) { answerPrimer(turnOn: true) }
                    .buttonStyle(InlineLinkButtonStyle())
                    .padding(.vertical, -12)
                    .padding(.leading, isAX ? -12 : 0)
                primerDismiss
            }
        }
        .padding(.vertical, ThemeSpace.x2)
        .frame(minHeight: ThemeMetrics.rowCompact)
        .overlay(alignment: .bottom) {
            Rectangle().fill(ThemeColor.separatorQuiet).frame(height: 1)
        }
        .padding(.horizontal, ThemeMetrics.gutter)
        .padding(.top, ThemeSpace.x2)
        .accessibilityElement(children: .contain)
    }

    private var primerDismiss: some View {
        Button { answerPrimer(turnOn: false) } label: {
            AppGlyph(systemName: "xmark")
                .font(.system(.caption2, weight: .bold))
                .foregroundStyle(ThemeColor.textTertiary)
                .frame(width: Metrics.dismissDisc, height: Metrics.dismissDisc)
                .background(ThemeColor.surfaceRaised, in: Circle())
                .overlay(Circle().strokeBorder(ThemeColor.posterEdge, lineWidth: FeedMetrics.hairline))
                .frame(width: Metrics.hitTarget, height: Metrics.hitTarget)
                .contentShape(Circle())
        }
        .accessibilityLabel(Copy.Search.primerNotNow)
        .padding(ThemeSpace.x1)
    }

    private func answerPrimer(turnOn: Bool) {
        primerAnswered = true
        primerPending = false
        withAnimation(ThemeMotion.pick(ThemeMotion.uiSettle, reduceMotion: reduceMotion)) {
            primerVisible = false
        }
        guard turnOn else { return }
        Task {
            // The card used to vanish whether the user allowed or declined, with no receipt
            // either way. Allowed is a success (one haptic, one line); declined is the system's
            // own answer and needs no second one.
            let granted = await EpisodeNotifications.shared.requestPermissionIfNeeded()
            if granted {
                // No haptic: the system's own dialog just closed under the thumb, and the
                // receipt is the confirmation (review i2).
                appModel.showNotice(Copy.Toast.alertsOn)
                await appModel.alertsWereAllowed()
            }
            await refreshNotificationEligibility()
        }
    }

    /// Only `.notDetermined` can still be asked; anything else and the primer would be a card that
    /// promises a system alert iOS will never show.
    ///
    /// The notification-centre round trip happens only while there is a primer to show. It used to
    /// run on every library change for every user, forever — including the ones who answered the
    /// primer on day one.
    private func refreshNotificationEligibility() async {
        guard primerPending, !primerAnswered else {
            if primerVisible { primerVisible = false }
            return
        }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        canAskForNotifications = settings.authorizationStatus == .notDetermined
        let shouldShow = canAskForNotifications
        guard shouldShow != primerVisible else { return }
        withAnimation(ThemeMotion.pick(ThemeMotion.uiSettle, reduceMotion: reduceMotion)) {
            primerVisible = shouldShow
        }
    }

    /// Arms the primer for one airing anime add, once the write has had the whole undo window to
    /// stick. TMDB air times are synthesised, so a TV-only add buys the user nothing and asks for
    /// nothing.
    private func armNotificationPrimer(_ item: FranchiseSummary) {
        guard item.isReleasing, item.source == .anilist, !primerAnswered else { return }
        Task {
            try? await Task.sleep(nanoseconds: UInt64((SyncCenter.shared.toastSeconds + 0.5) * 1_000_000_000))
            guard appModel.isInLibrary(item.id) else { return }
            primerPending = true
            await refreshNotificationEligibility()
        }
    }

    // MARK: - Outcome (spoken)

    /// Speaks the SAME title the visible state shows. It used to announce the anime catalogue's
    /// notice for a server error and the no-results title for a scoped-out set.
    private func announceOutcome() {
        Announce.status(outcomeTitle(ResultSet(appModel.filteredSearchResults)))
    }

    private func outcomeTitle(_ results: ResultSet) -> String {
        if scopedOut(results) { return scopedOutCopy.title }
        if results.isEmpty {
            return appModel.searchError ? errorCopy.title
                                        : EmptyStateCopy.noSearchResults(query: query).title
        }
        var parts = [Copy.Search.results(results.count)]
        if appModel.searchError { parts.append(Copy.Search.couldNotRefresh) }
        parts += catalogueNotices
        return parts.joined(separator: ". ")
    }

    // MARK: - States, as data

    /// The scope, not the query, emptied the list.
    private func scopedOut(_ results: ResultSet) -> Bool {
        // One audience has no wider scope to offer: its empty answer is "no results" (with why).
        !appModel.audience.isSingle
            && appModel.mediaFilter != .all && results.isEmpty && !appModel.searchResults.isEmpty
    }

    private var scopedOutCopy: EmptyStateCopy {
        .noScopeMatches(scope: Copy.Search.scopeWord(appModel.mediaFilter), query: query)
    }

    /// `searchFailed` carries the wifi glyph and "check your connection", so it is the OFFLINE
    /// copy; online, the catalogue itself failed. Both name SEARCH — the online branch used the
    /// library's own error, on a screen that has nothing to do with the library.
    private var errorCopy: EmptyStateCopy {
        SyncCenter.shared.isOnline ? .searchUnavailable : .searchFailed
    }

    /// One catalogue failed while the other answered. `/search` names the outcome per source
    /// (`ok` / `failed` / `disabled`); a catalogue that failed is not a catalogue with no matches,
    /// so the rows that did arrive get a notice above them rather than standing in for the whole
    /// answer. Filtered by scope: an anime notice over a TV-only list names a failure the user
    /// cannot see.
    private var catalogueNotices: [String] {
        // Only over rows that arrived (interactive review: a zero-hit query printed "Anime results
        // couldn't refresh" over "No results" — two states for one fact).
        guard let sources = appModel.searchSources, !appModel.searchResults.isEmpty else { return [] }
        var out: [String] = []
        if sources[MediaSource.anilist.rawValue] == Self.failedMarker,
           appModel.matchesMediaFilter(.anilist) {
            out.append(Copy.Notice.searchAnime)
        }
        if sources[MediaSource.tmdb.rawValue] == Self.failedMarker,
           appModel.matchesMediaFilter(.tmdb) {
            out.append(Copy.Notice.searchTV)
        }
        return out
    }

    // MARK: - Launchpad

    /// Today's recommendations in the field's scope (Anime / TV), up to twelve.
    private var scopedRecommendations: [RecommendationItem] {
        let all = appModel.visibleRecommendations
        let scoped: [RecommendationItem]
        switch appModel.mediaFilter {
        case .all: scoped = all
        case .anime: scoped = all.filter { $0.source == .anilist }
        case .tv: scoped = all.filter { $0.source == .tmdb }
        }
        return Array(scoped.prefix(12))
    }

    private func openRecommendation(_ r: RecommendationItem) {
        Task {
            if let id = await appModel.franchiseId(for: r) { onOpenDetail(id, "foryou/\(r.key)") }
        }
    }

    // MARK: Browse grid

    /// Trending as a wall of the app's own poster cards — the `ShelfCard` Today's shelf and the
    /// show page's extras draw — three across, the name and two facts under each, the add disc
    /// in the art's corner. It was a two-column wall of landscape tiles with the name printed
    /// over the art (a third card anatomy in the app, and the wrong crop for every show without a
    /// banner) that turned into compact rows once the field was focused.
    private func trendingGrid(_ trending: [FranchiseSummary]) -> some View {
        VStack(alignment: .leading, spacing: ThemeMetrics.labelGap) {
            SectionHeaderRow(Copy.Search.trendingNow)
                .padding(.horizontal, ThemeMetrics.gutter)
            if isAX {
                // At accessibility sizes a poster grid has no honest shape — one card per row
                // stretched a caption across the screen with its add disc floating at the far
                // edge. The results' own row (poster, name, facts, the square add control) is the
                // anatomy that reflows.
                VStack(spacing: 0) {
                    ForEach(Array(trending.enumerated()), id: \.element.id) { i, item in
                        mediaRow(item, zoom: "trend/\(item.id)", ambiguous: [], separator: i < trending.count - 1)
                    }
                }
                .padding(.horizontal, ThemeMetrics.gutter)
            } else {
                // EAGER (a `Grid` of three), not a `LazyVGrid`: the chart is fifteen cards, and a
                // lazy grid folded to nothing under the results dropped its cells and rebuilt
                // them on Cancel — the cost the fold exists to avoid.
                Grid(alignment: .topLeading, horizontalSpacing: ThemeMetrics.shelfGap, verticalSpacing: ThemeMetrics.shelfGap) {
                    ForEach(Array(stride(from: 0, to: trending.count, by: 3)), id: \.self) { start in
                        let row = Array(trending[start..<min(start + 3, trending.count)])
                        let owned = row.filter { appModel.isInLibrary($0.id) }
                        GridRow(alignment: .top) {
                            ForEach(row) { item in gridCard(item) }
                        }
                        // One corner for the row's owned checks (review i5, U-N16).
                        .environment(\.cornerRow, owned.isEmpty ? nil : CornerRow(urls: owned.compactMap(\.tilePoster.url)))
                    }
                }
                .padding(.horizontal, ThemeMetrics.gutter)
            }
        }
    }

    /// A chart card, equatable on what it shows (`SearchRow`): the launchpad's body re-runs
    /// when the field takes focus, and fifteen cards were rebuilt under that animation.
    private func gridCard(_ item: FranchiseSummary) -> some View {
        let caption = gridCaption(item)
        let key = SearchRowKey(id: item.id, title: item.title,
                               meta: caption.text, lead: caption.lead ? caption.text : nil,
                               poster: item.portraitArt,
                               owned: appModel.isInLibrary(item.id),
                               status: appModel.franchise(id: item.id)?.status?.rawValue ?? "",
                               separator: false)
        return SearchRow(key: key) { AnyView(gridCardBody(item, caption: caption)) }.equatable()
    }

    /// A chart row's facts: WHY it is trending now — a show on air says when its next episode lands
    /// (amber: the list's `when`), a show with a next installment names it ("Season 2 · Jan 2027",
    /// grey), else nothing is invented — and WHAT it is: the kind and its themes, else the kind
    /// and the year it began.
    private func trendFacts(_ item: FranchiseSummary) -> TrendFacts {
        let what: [String] = {
            let themes = item.themes.prefix(2)
            let parts = [item.source.kindLead].compactMap { $0 }
                + (themes.isEmpty ? [item.year.map(String.init) ?? ""] : Array(themes))
            return parts.filter { !$0.isEmpty }
        }()
        if let airs = when(item) {
            return TrendFacts(now: airs, nowLeads: true, what: what)
        }
        if let up = item.upcoming, up.isFutureInstallment, !up.hasArrived(now: now),
           let next = up.next?.trimmingCharacters(in: .whitespacesAndNewlines), !next.isEmpty {
            return TrendFacts(now: Copy.Discover.trendNext(installment: next, window: up.release,
                                                           rumoured: up.status == "rumored"),
                              nowLeads: false, what: what)
        }
        return TrendFacts(now: nil, nowLeads: false, what: what)
    }

    /// The card's ONE caption. A show whose next episode airs THIS WEEK says so — the row's own
    /// `when` ("Airs Sunday", amber), so the grid and the accessibility row stop disagreeing about
    /// one show ("One Piece · Anime · 1999" in the grid, "Airs Sunday" in the row, review 23 Sep).
    /// Everything else says what it is: kind and year. A 112-pt caption holds one fact, never a
    /// third, and the owned disc on the art already says the show is in the library.
    private func gridCaption(_ item: FranchiseSummary) -> (text: String, lead: Bool) {
        // The LIST's rule (`when`), whatever the layout: the grid dropped a show's next airing
        // past six days, so the #1 trending show read "Anime · 2016" in the grid and "Airs 30
        // Sep" as a row at the accessibility sizes (iteration 2).
        if let airs = when(item) {
            return (airs, true)
        }
        return ([item.source.kindLead, item.year.map(String.init)].compactMap { $0 }
                    .joined(separator: FactLine.separator), false)
    }

    /// The chart as a wall of POSTERS (20 Sep): each tile is the show's own titled key art, whole,
    /// on a soft wash of itself — the poster names the show, so no caption repeats it and no
    /// control sits on its lettering. Adding happens on the show's result card and its page.
    private func gridCardBody(_ item: FranchiseSummary, caption: (text: String, lead: Bool)) -> some View {
        let zoom = "trend/\(item.id)"
        // Owned is STATE, in amber: a small check disc in the corner, clear of the lettering the
        // poster prints (`cornerMark` reads where — review i3: the wall could not say which
        // trending shows were already yours; i4: pinned top-trailing it sat on Re:ZERO's "O").
        return ArtworkPoster(url: item.tilePoster.url, name: item.tilePoster.name, title: item.title,
                             showsDetails: false,
                             cornerMark: appModel.isInLibrary(item.id)
                                ? AnyView(OwnedMark().padding(ThemeSpace.x2).allowsHitTesting(false)) : nil,
                             onOpen: { open(item, zoom: zoom) }) { EmptyView() }
        .zoomSource(zoom)
        .accessibilityLabel(spoken(item, ambiguous: []))
        .accessibilityHint(Copy.Accessibility.opensTheShowHint)
        .franchiseQuickActions(appModel.franchise(id: item.id), appModel: appModel)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    // MARK: Recently searched

    /// The shows you acted on from a search, as the app's rows, then any bare terms left over.
    /// One Clear for the lot; one row at a time from its long-press.
    private var recentsList: some View {
        let items = appModel.recentItems
        let terms = appModel.recentSearches
        return VStack(alignment: .leading, spacing: ThemeMetrics.labelGap) {
            SectionHeaderRow(Copy.Search.recentlySearched, actionLabel: Copy.Action.clear, inlineAction: true) {
                withAnimation(ThemeMotion.pick(ThemeMotion.uiSnappy, reduceMotion: reduceMotion)) {
                    appModel.clearRecents()
                }
            }
            .padding(.horizontal, ThemeMetrics.gutter)
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                    let zoom = "recent/\(item.id)"
                    let meta = shelfFacts(item).joined(separator: FactLine.separator)
                    let separator = i < items.count - 1 || !terms.isEmpty
                    // Equatable on what it shows (`SearchRow`, like the results): the focus flips
                    // `fieldPresented`, the launchpad's body re-runs, and these rows — closures
                    // and all — were rebuilt under the field's own animation.
                    SearchRow(key: SearchRowKey(id: item.id, title: item.title, meta: meta, lead: nil,
                                                poster: item.portraitArt, owned: false, status: "",
                                                separator: separator)) {
                        // X's recent account: the show's avatar, its name in bold, its facts in
                        // grey — the results' own row, without the pill.
                        AnyView(recentRow(item, meta: meta, zoom: zoom, separator: separator)
                        .contextMenu {
                            Button(role: .destructive) {
                                withAnimation(ThemeMotion.pick(ThemeMotion.uiSnappy, reduceMotion: reduceMotion)) {
                                    appModel.removeRecentItem(item.id)
                                }
                            } label: {
                                AppGlyphLabel(Copy.Search.removeRecent, systemName: "trash")
                            }
                        })
                    }
                    .equatable()
                }
                ForEach(Array(terms.enumerated()), id: \.element) { i, term in
                    termRow(term, separator: i < terms.count - 1, aligned: !items.isEmpty)
                }
            }
            .padding(.horizontal, ThemeMetrics.gutter)
        }
    }

    /// A recent show, as X lists a recent account: avatar, bold name, grey facts; the row opens the
    /// show, its long press forgets it.
    private func recentRow(_ item: FranchiseSummary, meta: String, zoom: String, separator: Bool) -> some View {
        VStack(spacing: 0) {
            Button { open(item, zoom: zoom) } label: {
                HStack(alignment: .center, spacing: ThemeSpace.x3) {
                    ShowAvatar(candidates: resultAvatar(item), size: Metrics.resultAvatar)
                    VStack(alignment: .leading, spacing: ThemeSpace.x0_5) {
                        Text(item.title)
                            .type(ThemeType.feedName)
                            .foregroundStyle(ThemeColor.feedText)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        if !meta.isEmpty {
                            Text(meta)
                                .type(ThemeType.feedMeta)
                                .foregroundStyle(ThemeColor.feedSecondary)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, ThemeSpace.x3)
                .contentShape(Rectangle())
            }
            .buttonStyle(FeedRowPressStyle())
            .zoomSource(zoom)
            .accessibilityElement(children: .combine)
            .accessibilityHint(Copy.Accessibility.opensTheShowHint)
            if separator { FeedHairline() }
        }
    }

    /// A bare term: ONE line at the minimum target — the magnifier, the words, the fill-the-field
    /// arrow. It was a 60-pt disc over a second line reading "Search" under every term (review,
    /// 23 Sep): a typed word as tall as a poster row, and a subtitle saying what the glyph said.
    ///  * the glyph stands in the poster column, so a term starts on the x every show title in
    ///    this list starts on, and the rule beneath it on theirs;
    ///  * neutral, not amber — a recent QUERY is neither a next step nor a state;
    ///  * the words are `body`, not a title's weight: a query is not a show;
    ///  * the trailing glyph is the fill-the-field arrow, not a chevron. A chevron promises a push;
    ///    this row puts the words back in the field (Safari's and YouTube's convention).
    private func termRow(_ term: String, separator: Bool, aligned: Bool = true) -> some View {
        // The glyph holds the poster column only when there ARE show rows to align with; alone,
        // the terms sat at x≈70 under a column that was not there (review i3) — then the glyph
        // hugs the gutter like any list's.
        let column = aligned ? PosterSize.row.size.width : 24
        return Button { appModel.searchQuery = term } label: {
            HStack(spacing: ThemeMetrics.artGap) {
                AppGlyph(systemName: "magnifyingglass")
                    .font(.system(.body, weight: .regular))
                    .foregroundStyle(ThemeColor.textSecondary)
                    .frame(width: column)
                    .accessibilityHidden(true)
                Text(term)
                    .type(ThemeType.body)
                    .foregroundStyle(ThemeColor.textPrimary)
                    // One line; at the accessibility sizes a long term may take a second rather
                    // than lose its tail.
                    .lineLimit(isAX ? 2 : 1)
                Spacer(minLength: ThemeSpace.x3)
                AppGlyph(systemName: "arrow.up.backward")
                    .font(.system(size: Metrics.chevronSize, weight: .semibold))
                    .foregroundStyle(ThemeColor.textTertiary)
                    .frame(width: Metrics.chevronColumn, alignment: .trailing)
                    .accessibilityHidden(true)
            }
            // Inside the 44 at the default size; air around the words once they outgrow it.
            .padding(.vertical, ThemeSpace.x2)
            .frame(minHeight: Metrics.termRowHeight)
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) {
                if separator {
                    Rectangle().fill(ThemeColor.separatorQuiet).frame(height: 1)
                        .padding(.leading, column + ThemeMetrics.artGap)
                }
            }
        }
        .buttonStyle(RowPressStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(term)
        .accessibilityHint(Copy.Search.termHint)
        .contextMenu {
            Button(role: .destructive) {
                withAnimation(ThemeMotion.pick(ThemeMotion.uiSnappy, reduceMotion: reduceMotion)) {
                    appModel.removeRecentSearch(term)
                }
            } label: {
                AppGlyphLabel(Copy.Search.removeRecent, systemName: "trash")
            }
        }
    }

    /// Trending as ONE chart in two densities: the top three carry full `.shelfLarge` artwork,
    /// the rest continue as rows under their own label. The add control is the same object in
    /// both, and the row gutter is the screen's gutter — the shipped build's 50-pt rank column
    /// made ranks 05+ look like a different list.
     /// The one row anatomy for both lists on this screen: the app's `MediaRow`, no chevron (the
    /// trailing column holds a control), the amber `when` as its lead so VoiceOver hears it inside
    /// the row's combined label, and the add control in the trailing slot.
    private func mediaRow(_ item: FranchiseSummary, zoom: String,
                          ambiguous: Set<String>, separator: Bool) -> some View {
        // X's result (the X pass, 25 Sep — "redo the search results in X style too", owner): the
        // show as an ACCOUNT — its avatar, its name in bold, one line of facts (a time this week
        // leads in amber), X's Follow pill as the add — on the canvas, a one-pixel rule under it.
        // It was a landscape SCENE card per result, three to a screen.
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: ThemeSpace.x3) {
                Button { open(item, zoom: zoom) } label: {
                    HStack(alignment: .center, spacing: ThemeSpace.x3) {
                        ShowAvatar(candidates: resultAvatar(item), size: Metrics.resultAvatar)
                        VStack(alignment: .leading, spacing: ThemeSpace.x0_5) {
                            Text(disambiguated(item, ambiguous: ambiguous))
                                .type(ThemeType.feedName)
                                .foregroundStyle(ThemeColor.feedText)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                            FactLine(facts: rowFacts(item, ambiguous: ambiguous), lead: when(item),
                                     token: ThemeType.feedMeta, tint: ThemeColor.feedSecondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityHint(Copy.Accessibility.opensTheShowHint)
                addControl(item, placement: .pill)
            }
            .padding(.horizontal, ThemeMetrics.gutter)
            .padding(.vertical, ThemeSpace.x3)
            .zoomSource(zoom)
            .franchiseQuickActions(appModel.franchise(id: item.id), appModel: appModel)
            if separator { FeedHairline() }
        }
    }

    /// A result's avatar: the show's face, as the feed crops it — the textless poster, a TRUE
    /// landscape, then the poster.
    private func resultAvatar(_ item: FranchiseSummary) -> [String] {
        var out: [String] = []
        for url in [item.textlessPortrait, item.landscapeArt, item.portraitArt] {
            if let url, !url.isEmpty, !url.contains("/anime/banner/"), !out.contains(url) { out.append(url) }
        }
        return out
    }

    // MARK: - Results

    @ViewBuilder
    private func searchBody(_ results: ResultSet, trending: [FranchiseSummary]) -> some View {
        SkeletonGate(isLoading: appModel.searchBusy && results.isEmpty && !scopedOut(results) && !appModel.searchError) {
            searchSkeleton
        } content: {
            resultsContent(results, trending: trending)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The shape the results are about to take: rows at exactly the `.row` geometry the content
    /// uses, so nothing reflows when the data lands.
    private var searchSkeleton: some View {
        VStack(spacing: 0) {
            ForEach(0..<5, id: \.self) { _ in
                SkeletonRow(poster: PosterSize.row.size, lines: Metrics.skeletonRowLines,
                            posterRadius: PosterSize.row.radius,
                            spacing: ThemeMetrics.artGap, height: ThemeMetrics.rowMedia)
            }
        }
        .padding(.horizontal, ThemeMetrics.gutter)
        .padding(.top, ThemeSpace.x3)
    }

    @ViewBuilder
    private func resultsContent(_ results: ResultSet, trending: [FranchiseSummary]) -> some View {
        if scopedOut(results) {
            stateWithTrending(trending) {
                EmptyState(scopedOutCopy, primary: {
                    withAnimation(ThemeMotion.pick(ThemeMotion.uiSnappy, reduceMotion: reduceMotion)) {
                        appModel.mediaFilter = .all
                    }
                })
            }
        } else if results.isEmpty {
            stateWithTrending(trending) {
                VStack(spacing: ThemeSpace.x4) {
                    // A catalogue that failed while the other found nothing: the notice says
                    // which, so "No results" is not the whole story.
                    notices(refreshFailed: false, inset: false)
                    EmptyState(appModel.searchError ? errorCopy : .noSearchResults(query: query),
                               primary: appModel.searchError ? { appModel.retrySearch() } : nil)
                    // For one audience: the wall is why, and Profile is the door.
                    if !appModel.searchError, let why = Copy.Watching.searchingOnly(appModel.audience) {
                        Text(why)
                            .type(ThemeType.metadata)
                            .foregroundStyle(ThemeColor.textTertiary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, ThemeMetrics.gutter)
                    }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                // A stale result set with a failed refresh over it, or one catalogue down: the
                // content stays, the notice sits above it.
                notices(refreshFailed: appModel.searchError, inset: true)
                if let correction = appModel.searchCorrection { correctionLine(correction) }
                // Rows, all of them, no headers and no card: Apple TV's answer to a query is the
                // list of what matched. "Top match" (a plate, then an art tile) over "More
                // results 3" was two anatomies and a count for one list.
                //
                // An EQUATABLE child (5 Sep, "the search bar experience is lagging"): every
                // keystroke re-ran this body, and a row's closures (its action, its trailing
                // control) mean SwiftUI cannot prove a row unchanged — so every result row was
                // rebuilt on every letter typed, button style, context menu and all (sampled:
                // 300 ms per key on the simulator, most of it in the rows' `makeBody`). The list
                // now compares its DATA — the result ids, ownership, statuses, the minute — and
                // skips its body while the person types; it rebuilds when an answer lands.
                SearchResultsList(items: results.items, ambiguous: results.ambiguous,
                                  owned: results.items.map { appModel.isInLibrary($0.id) },
                                  statuses: results.items.map { appModel.franchise(id: $0.id)?.status?.rawValue ?? "" },
                                  minute: now) { item, i in
                    // Each ROW is equatable on what it shows, too: when an answer lands, the rows
                    // that were already there ("One Piece" through "one", "one p", "one pi"…)
                    // keep their bodies and only the new ones are built.
                    let key = SearchRowKey(id: item.id, title: disambiguated(item, ambiguous: results.ambiguous),
                                           meta: rowFacts(item, ambiguous: results.ambiguous).joined(separator: FactLine.separator),
                                           lead: when(item), poster: item.portraitArt,
                                           owned: appModel.isInLibrary(item.id),
                                           status: appModel.franchise(id: item.id)?.status?.rawValue ?? "",
                                           separator: i < results.count - 1)
                    return AnyView(SearchRow(key: key) {
                        AnyView(mediaRow(item, zoom: "result/\(item.id)", ambiguous: results.ambiguous,
                                         separator: i < results.count - 1))
                    }.equatable())
                }
                .equatable()
                .padding(.top, ThemeSpace.x1)
            }
            // Refining a query that already has results: the old set steps back as a group while
            // the new one is in flight, so a list that is about to change never looks settled.
            .opacity(appModel.searchBusy ? Metrics.groupDim : 1)
            .animation(ThemeMotion.pick(ThemeMotion.uiGentle, reduceMotion: reduceMotion),
                       value: appModel.searchBusy)
            // Every new result set, not just the first: this is the modifier the container-level
            // one was standing in for.
            .animation(ThemeMotion.pick(ThemeMotion.uiSnappy, reduceMotion: reduceMotion),
                       value: results.items.map(\.id))
        }
    }

    /// The notices that belong above whatever the results are: the whole-request failure, then
    /// the per-catalogue ones. Each carries the same retry.
    @ViewBuilder
    private func notices(refreshFailed: Bool, inset: Bool) -> some View {
        let messages = (refreshFailed ? [Copy.Search.couldNotRefresh] : []) + catalogueNotices
        if !messages.isEmpty {
            VStack(spacing: ThemeSpace.x2) {
                ForEach(messages, id: \.self) { message in
                    InlineNotice(message) { appModel.retrySearch() }
                }
            }
            .padding(.horizontal, inset ? ThemeMetrics.gutter : 0)
            .padding(.top, inset ? ThemeSpace.x4 : 0)
        }
    }

    /// A whole-surface state, followed by the artwork this screen already has. The app used to
    /// throw away a decoded shelf in order to say one sentence, leaving a plate over 900 pt of
    /// black — on the screen a reviewer walks first.
    @ViewBuilder
    private func stateWithTrending(_ trending: [FranchiseSummary],
                                   @ViewBuilder _ state: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            state()
                .padding(.horizontal, ThemeMetrics.gutter)
                .padding(.top, ThemeMetrics.sectionGap)
            if !trending.isEmpty {
                trendingGrid(trending).padding(.top, ThemeMetrics.sectionGap)
            } else {
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The standard "we searched for something else" disclosure, with the literal search one tap
    /// away. `correctedQuery` has been on the wire and decoded since the endpoint shipped.
    private func correctionLine(_ correction: SearchCorrection) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(Copy.Search.showingResultsFor(correction.corrected))
                .type(ThemeType.metadata)
                .foregroundStyle(ThemeColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(Copy.Search.searchInsteadFor(correction.original)) {
                appModel.searchLiterally(correction.original)
            }
            .buttonStyle(InlineLinkButtonStyle())
            .padding(.leading, -Metrics.inlineLinkInset)
        }
        .padding(.horizontal, ThemeMetrics.gutter)
        .padding(.top, ThemeMetrics.sectionGap)
        .accessibilityElement(children: .contain)
    }

    private func cardMeta(_ item: FranchiseSummary, ambiguous: Set<String>) -> some View {
        VStack(alignment: .leading, spacing: ThemeMetrics.titleGap) {
            if let w = when(item) {
                Text(w)
                    .type(ThemeType.rowMetaLead)
                    .foregroundStyle(ThemeColor.accent)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            FactLine(facts: rowFacts(item, ambiguous: ambiguous), token: ThemeType.rowMeta)
        }
    }

    // MARK: - Actions

    private func open(_ item: FranchiseSummary, zoom: String) {
        rememberFromQuery(item)
        onOpenDetail(item.id, zoom)
    }

    // MARK: - What "Recently searched" keeps

    /// The SHOW the user acted on from a query is what "Recently searched" remembers — and the
    /// show stands in for the words that found it. A bare term typed on the way there ("slim" on
    /// the way to That Time I Got Reincarnated as a Slime) goes once the show is remembered: one
    /// search, one row, and never a fragment beside the thing it found.
    private func rememberFromQuery(_ item: FranchiseSummary) {
        guard !query.isEmpty else { return }
        appModel.recordRecentItem(item)
        let typed = Self.folded(query), title = Self.folded(item.title)
        if let pending = submittedTerm.map(Self.folded), title.contains(pending) { submittedTerm = nil }
        forgetRecentTerms { typed.hasPrefix($0) && title.contains($0) }
    }

    /// Remembers the submitted term once its ANSWER is in — and not at all when the answer says
    /// the term was a slip: it found nothing, or the catalogue answered a corrected spelling
    /// ("Showing results for …"). It used to be written the instant Return was pressed, so a
    /// half-typed or misspelled word sat under "Recently searched" for good (review, 23 Sep). A
    /// FAILED request keeps the term: the failure is the network's, not the word's. The term's own
    /// partials go with it — "blea" on the way to "bleach" is one search, not two.
    private func settleRecentTerm() {
        guard let term = submittedTerm else { return }
        // The field moved on (typed further, cleared): the submission is not what is on screen.
        guard !term.isEmpty, term == query else { submittedTerm = nil; return }
        guard !appModel.searchBusy else { return }  // its answer is still in flight
        submittedTerm = nil
        if !appModel.searchError, appModel.searchResults.isEmpty || appModel.searchCorrection != nil { return }
        appModel.recordRecentSearch()
        let typed = Self.folded(term)
        forgetRecentTerms { $0 != typed && typed.hasPrefix($0) }
    }

    /// Drops the stored bare terms `drop` picks, each compared folded (`folded`).
    private func forgetRecentTerms(where drop: (String) -> Bool) {
        for term in appModel.recentSearches where drop(Self.folded(term)) {
            appModel.removeRecentSearch(term)
        }
    }

    /// Case and accents do not make a different search.
    private static func folded(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// The add control, with the menu an OWNED tap opens: the same status options and the same
    /// Undo-carrying Remove the Library row's long-press offers once the franchise is loaded; while
    /// the add is still pending (owned, not yet in `library`) the one thing that can be done is
    /// take it back out.
    private func addControl(_ item: FranchiseSummary,
                            placement: AddControlPlacement = .row) -> some View {
        AddControl(title: item.title,
                   owned: appModel.isInLibrary(item.id),
                   placement: placement,
                   asks: item.isReleasing,
                   add: { add(item) }) {
            if let f = appModel.franchise(id: item.id) {
                FranchiseContextMenu(f: f, appModel: appModel) { part, target in
                    markAll = MarkAllRequest(franchise: f, from: part.progress, to: target)
                }
            } else {
                Button(role: .destructive) {
                    // The one remove in the app with no way back: a show added seconds ago and
                    // not yet in the loaded library has no `Franchise` for `removeWithUndo`, so
                    // the receipt is built here — same toast, same six seconds, same Undo.
                    appModel.removeFromLibrary(franchiseId: item.id)
                    appModel.presentUndo(UndoState(mediaId: nil, franchiseId: item.id, prevProgress: 0,
                                                   title: item.title, episode: 0,
                                                   customMessage: Copy.Toast.removed) {
                        appModel.addToLibrary(franchiseId: item.id, title: item.title, isReleasing: item.isReleasing)
                    })
                } label: {
                    AppGlyphLabel(Copy.Action.removeFromLibrary, systemName: "trash")
                }
            }
        }
    }

    private func add(_ item: FranchiseSummary) {
        // An airing show asks WHERE YOU ARE before it is added (the show page's question, which
        // knows the episode counts this card does not): added straight to Watching at zero it
        // arrived on Today as a wall of "behind". A finished run lands on Planned — no backlog.
        if item.isReleasing {
            appModel.pendingAddPrompt = item.id
            // The alerts primer follows the add back here: it is armed when this screen returns
            // with the show in the library (review i4 — routing the add to the page left the
            // primer unreachable, and Profile the only way to turn alerts on).
            primerCandidate = item
            open(item, zoom: "search/\(item.id)")
            return
        }
        appModel.addToLibrary(franchiseId: item.id, title: item.title, isReleasing: item.isReleasing)
        rememberFromQuery(item)
        // NOT a permission prompt — see `notificationPrimer`. Nothing at all happens for the whole
        // undo window; the ask is a card the user chooses to answer, later, on their own screen.
        armNotificationPrimer(item)
    }

    // MARK: - Copy helpers

    /// How big the thing is — **only where the app can say it truthfully.**
    ///
    /// "Part" is `FranchisePart`, an internal model word nobody outside this repository can
    /// interpret. But its replacement asserted something the app disproves two taps later: Search
    /// said One Piece had "45 seasons", and One Piece's own screen prints "SEASONS & MOVIES 23"
    /// with the remainder under EXTRAS. Renaming the number does not fix it — 41 is not 23 under
    /// any label. This is the figure a user checks before adding a 45-"season" show, and a tracker
    /// that gets it wrong on the add screen is not one you trust with your progress.
    ///
    /// `FranchiseSummary` carries a single `partCount` (every member), while the split lives in
    /// `partCounts` on the full franchise, which search results do not fetch. So: TMDB, where one
    /// member genuinely is one season, keeps its count; AniList prints no count at all until the
    /// server puts the by-kind breakdown on the summary. **Server follow-up:** add `partCounts` to
    /// `FranchiseListItem` (`services/franchiseView.ts:274`) and this becomes "5 seasons · 6 extras".
    private func size(_ item: FranchiseSummary) -> String? {
        guard item.partCount > 0, item.source == .tmdb else { return nil }
        return Copy.Search.seasons(item.partCount)
    }

    /// When the next episode lands, with a predicate.
    ///
    /// The shipped row printed a bare "29 Aug 2:00 PM" as its fourth fact, in the same grey as the
    /// year and the season count — a date-time with nothing saying whether it was a premiere, the
    /// next episode or the finale, set as though it were trivia. It is the one forward-looking fact
    /// on the screen, so it is named, it leads the line, and it is the one thing on it in amber —
    /// the rule Today, Library and Schedule already follow.
    private func when(_ item: FranchiseSummary) -> String? {
        guard item.isReleasing else { return nil }
        guard let at = item.nextAiringAt, at > now else { return Copy.Search.airingNow }
        let word = TemporalCopy.airsCompact(at: at, now: now, source: item.source)
        // "today" and "tomorrow" are common nouns mid-sentence; a weekday and a month are not.
        let cased = (word == "Today" || word == "Tomorrow") ? word.lowercased() : word
        return Copy.Search.airs(day: cased)
    }

    /// The grey facts, in priority order. The amber `when` is passed separately and never dropped.
    ///
    /// **An owned show leads with its shelf.** The tick alone said "in your library" and never
    /// which of five lists it was on; the status word is the fact that answers that, in the same
    /// vocabulary Library's own rows use.
    ///
    /// **Kind next.** A search for "one piece" returns the 1999 anime, the 2023 live-action and
    /// the 2027 anime, separated by capitalisation and a year — and the scope bar directly above
    /// proves the app knows which is which. Adding the wrong one puts the wrong show in the
    /// library, and there is no other moment where the kind matters more.
    ///
    /// **The year goes when a next-episode date is present.** They are the same class of fact and
    /// the line only holds so much: for a show airing tomorrow, "1999" is the least useful thing
    /// on it, and keeping both is what pushed the row to four facts and a wrap.
    private func rowFacts(_ item: FranchiseSummary, ambiguous: Set<String>) -> [String] {
        var facts: [String] = []
        if let f = appModel.franchise(id: item.id) { facts.append(Copy.Status(f.effectiveStatus)) }
        if let kind = item.source.kindLead { facts.append(kind) }
        // …and it goes when the title is already carrying it, because a disambiguated result
        // printed "ONE PIECE (2023)" over "TV · 2023 · 3 seasons" — the same number twice, 20 pt
        // apart, on a line whose whole job is telling this result apart from the one above it.
        if let y = item.year, when(item) == nil, !titleCarriesYear(item, ambiguous: ambiguous) {
            facts.append(String(y))
        }
        if let s = size(item) { facts.append(s) }
        return facts
    }

    /// The shelf caption carries the SAME schema as a row — shelf, then kind. It carries no lead,
    /// so it keeps the year.
    private func shelfFacts(_ item: FranchiseSummary) -> [String] {
        var facts: [String] = []
        if let f = appModel.franchise(id: item.id) { facts.append(Copy.Status(f.effectiveStatus)) }
        if let kind = item.source.kindLead { facts.append(kind) }
        if let y = item.year { facts.append(String(y)) }
        if let s = size(item) { facts.append(s) }
        return facts
    }

    /// The spoken form of a result: rank (when it has one), the WHOLE title, the lead, the facts.
    private func spoken(_ item: FranchiseSummary, rank: Int? = nil, ambiguous: Set<String>) -> String {
        let title = disambiguated(item, ambiguous: ambiguous)
        var bits = [rank.map { "\($0). \(title)" } ?? title]
        if let w = when(item) { bits.append(w) }
        bits += rowFacts(item, ambiguous: ambiguous)
        return bits.joined(separator: ", ")
    }

    /// Titles that normalise to the same string carry their year INSIDE the title.
    ///
    /// A search for "one piece" returns five results whose titles differ only in capitalisation and
    /// a definite article, separated by a 13-pt grey line — so "One Piece (Anime · 1999)" and "ONE
    /// PIECE (TV · 2023)" read as the same show, and one of them is the wrong one to put in the
    /// library. Where the ambiguity is real the disambiguator is promoted into the identity line;
    /// where it is not, the source title is left exactly as the catalogue spells it, because in
    /// search the user is matching against what they typed.
    private func titleCarriesYear(_ item: FranchiseSummary, ambiguous: Set<String>) -> Bool {
        item.year != nil && ambiguous.contains(ResultSet.normalised(item.title))
    }

    private func disambiguated(_ item: FranchiseSummary, ambiguous: Set<String>) -> String {
        guard let year = item.year, titleCarriesYear(item, ambiguous: ambiguous) else { return item.title }
        return "\(item.title) (\(year))"
    }

    /// The top-match card's identity line, at the length the slot can actually hold.
    ///
    /// The rule is absolute — an identity title never ends in an ellipsis and never breaks
    /// mid-word — and four lines of the card is not enough for "HELL MODE: The Hardcore Gamer
    /// Dominates in Another World with Garbage Balancing". So the fallback is the one the direction
    /// names: **break at the colon and drop the subtitle.** "HELL MODE" is the name people use; the
    /// full string stays in the accessibility label and on the show's own screen. The rows do not
    /// go through this — `MediaRow` prints the title whole.
    ///
    /// `budget` is characters, not points — it only has to be conservative enough that the title
    /// that survives it fits with `minimumScaleFactor` still in hand.
    private func fittedTitle(_ item: FranchiseSummary, budget: Int, ambiguous: Set<String>) -> String {
        let full = disambiguated(item, ambiguous: ambiguous)
        guard full.count > budget, let colon = full.range(of: ": ") else { return full }
        let head = String(full[full.startIndex..<colon.lowerBound])
        return head.count >= 4 ? head : full
    }
}

// MARK: - The result set, scanned once

/// The visible results plus the normalised titles more than one of them shares — computed once
/// per body, not once per row. The scan is a regex over every title; at eight reads of `results`
/// and one scan per row it was running dozens of times per keystroke.
/// The result rows, built only when the RESULTS change (see `resultsContent`). `Equatable` on
/// the data alone — the row builder is a closure and is deliberately not compared.
private struct SearchResultsList: View, @MainActor Equatable {
    let items: [FranchiseSummary]
    let ambiguous: Set<String>
    let owned: [Bool]
    let statuses: [String]
    let minute: Int64
    let row: (FranchiseSummary, Int) -> AnyView

    static func == (a: SearchResultsList, b: SearchResultsList) -> Bool {
        a.items.map(\.id) == b.items.map(\.id) && a.ambiguous == b.ambiguous
            && a.owned == b.owned && a.statuses == b.statuses && a.minute == b.minute
    }

    var body: some View {
        // LAZY: an answer builds the rows on screen, not the whole list — a broad query's
        // thirty rows ("o", "on") were all built the moment it landed, under the next keystroke.
        LazyVStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                row(item, i)
            }
        }
    }
}

/// What a result row shows — the whole of its equality (see `SearchResultsList`).
private struct SearchRowKey: Equatable {
    let id: String
    let title: String
    let meta: String
    let lead: String?
    let poster: String?
    let owned: Bool
    let status: String
    let separator: Bool
}

/// One result row, rebuilt only when its `key` changes.
private struct SearchRow: View, @MainActor Equatable {
    let key: SearchRowKey
    let build: () -> AnyView

    static func == (a: SearchRow, b: SearchRow) -> Bool { a.key == b.key }

    var body: some View { build() }
}

private struct ResultSet {
    let items: [FranchiseSummary]
    let ambiguous: Set<String>

    /// The duplicate-title scan runs a regular expression per row; memoised on the result ids
    /// so the screen's body — which runs on every keystroke — pays it once per answer.
    nonisolated(unsafe) private static var lastScan: (ids: [String], ambiguous: Set<String>)?

    init(_ items: [FranchiseSummary]) {
        self.items = items
        let ids = items.map(\.id)
        if let last = ResultSet.lastScan, last.ids == ids {
            ambiguous = last.ambiguous
            return
        }
        var seen: Set<String> = []
        var duplicated: Set<String> = []
        for item in items {
            let key = ResultSet.normalised(item.title)
            if !seen.insert(key).inserted { duplicated.insert(key) }
        }
        ambiguous = duplicated
        ResultSet.lastScan = (ids, duplicated)
    }

    var isEmpty: Bool { items.isEmpty }
    var count: Int { items.count }
    var first: FranchiseSummary? { items.first }

    static func normalised(_ title: String) -> String {
        title.lowercased()
            .replacingOccurrences(of: "^the\\s+", with: "", options: .regularExpression)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
    }
}

// MARK: - Capture (DEBUG)

/// `-discoverGenre <key>` (DEBUG, ios-spec §6.3): with `-openTab discover`, pushes that genre's
/// page once the launchpad has its genres — the way to photograph the page when the simulator
/// cannot be touched. Read once, here; the shipped build gets the content untouched.
private struct DiscoverCapture: ViewModifier {
    let onOpenDetail: (_ franchiseId: String, _ zoomID: String) -> Void

    #if DEBUG
    @Environment(AppModel.self) private var appModel
    @State private var genre: DiscoverRoute?
    @State private var consumed = false
    #endif

    func body(content: Content) -> some View {
        #if DEBUG
        content
            .navigationDestination(item: $genre) { route in
                switch route {
                case let .genre(key, name):
                    GenreResultsView(genreKey: key, name: name,
                                     onOpenDetail: { onOpenDetail($0, "genre/\($0)") })
                        .pushedScreenChrome()
                }
            }
            .task {
                guard !consumed, let key = UserDefaults.standard.string(forKey: "discoverGenre"),
                      !key.isEmpty else { return }
                consumed = true
                // The name the tile would carry, once the list has answered (≤ 4 s); else the key.
                var name = key
                for _ in 0..<20 {
                    if let hit = DiscoverCatalog.shared.genres(for: appModel.mediaFilter).first(where: { $0.key == key }) {
                        name = hit.name
                        break
                    }
                    try? await Task.sleep(for: .milliseconds(200))
                }
                genre = .genre(key: key, name: name)
            }
        #else
        content
        #endif
    }
}

// MARK: - Sizes with no token

/// Sizes this screen needs that have no token equivalent. Each says why it is the number it is.
private enum Metrics {
    /// X's result avatar: 48 pt, the show's rounded square.
    static let resultAvatar: CGFloat = 48
    /// The 44-pt minimum target (HIG).
    static let hitTarget: CGFloat = 44
    /// A bare-term row: one line at the minimum target. A word is not a poster.
    static let termRowHeight: CGFloat = 44
    /// `MediaRow`'s disclosure chevron, verbatim, so the term rows share the media rows' x.
    static let chevronSize: CGFloat = 13
    static let chevronColumn: CGFloat = 11
    /// The primer's glyph tile — `EmptyState`'s grammar at row altitude: a 36-pt disc, not the
    /// state card's larger one.
    static let primerGlyphTile: CGFloat = 36
    /// The primer's dismiss disc, drawn inside its 44-pt target.
    static let dismissDisc: CGFloat = 28
    /// `InlineLinkButtonStyle` pads 12 pt leading to hold its target; pulled back by the same
    /// amount so the word starts on the gutter.
    static let inlineLinkInset: CGFloat = 12
    /// The disc and its tap target: the 26-pt disc sits centred in the 44-pt target.
    static let overArtDisc: CGFloat = 26
    static let overArtTarget: CGFloat = 44
    /// How far inside the art's corner the VISIBLE disc sits.
    static let overArtDiscInset: CGFloat = 8
    /// The target's own inset that puts the disc there: the disc is 9 pt inside its target, so
    /// the target reaches 1 pt past the art's edge and the disc lands 8 pt inside it.
    static let overArtControlInset: CGFloat = overArtDiscInset - (overArtTarget - overArtDisc) / 2
    /// The app's group-dim (`MediaRow.dimmed`): 0.72 lands `textSecondary` at ≈5.4:1 and still
    /// reads as content that has stepped back.
    static let groupDim: Double = 0.72
    /// Skeleton row lines at the widths the real rows land at.
    static let skeletonRowLines: [CGFloat] = [188, 126]
}
