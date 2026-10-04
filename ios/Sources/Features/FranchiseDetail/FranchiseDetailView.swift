import SwiftUI

// Franchise Detail (spec board 06). The hero is identity; the Next up card owns the single action
// and shares Today's mark timeline (pinned snapshot → committed result → handoff).
// Seasons & movies are flat rows in the source's own labels; a season pushes its episode list.
// Every multi-item write has Undo or a confirmation that states its exact blast radius.
struct FranchiseDetailView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.openURL) private var openURL
    let franchiseId: String
    var focus: EpisodeFocus? = nil
    /// Pushes onto the owning tab's navigation path (Detail is a push, never a sheet).
    var push: (DetailPush) -> Void = { _ in }

    @State private var fetched: Franchise?
    @State private var loading = true
    @State private var loadError = false
    @State private var synopsisExpanded = false
    // The paragraph's whole height behind its clamped one: the link is drawn only when they differ.
    @State private var synopsisFullHeight: CGFloat = 0
    @State private var synopsisClampedHeight: CGFloat = 0
    /// About three lines of `prose` on a 361-pt run (~52 characters a line).
    static let synopsisBudget = 150
    static func clampedAtWord(_ text: String, budget: Int) -> String {
        guard text.count > budget else { return text }
        let head = String(text.prefix(budget))
        guard let cut = head.lastIndex(of: " ") else { return head + "\u{2026}" }
        return String(head[..<cut]).trimmingCharacters(in: CharacterSet(charactersIn: " ,;:\u{2014}\u{2013}-")) + "\u{2026}"
    }
    @State private var tint: Color?
    /// The BANNER's palette, distinct from `tint` (the cover's). The hero's photograph is the
    /// banner, so the colour that continues it below the fold has to come from the banner too —
    /// derived from the cover it landed a warm brown under a magenta-and-cyan neon header, i.e.
    /// two light sources in one hero. The card and the episode tiles keep the cover's palette:
    /// they are the show's identity, not a continuation of this particular photograph.
    @State private var heroTint: Color?
    /// The hero art's mean lightness (`PaletteCache.lightness(for:)`), for `HeroProtection`.
    @State private var heroLightness: Double?
    /// The trailer card → stage zoom (`VideoSheet`).
    @Namespace private var trailerZoom

    // Mark timeline (identical to Today)
    @State private var pinned: Franchise?
    @State private var committedEpisode: Int?
    @State private var prompt: WritePrompt?
    /// Where the confirmation hangs from: the control that raised it. On iOS 26 a dialog is a
    /// popover anchored to the view it is attached to, and one attached to the whole page pointed
    /// its arrow at the badge while the link that opened it sat 300 pt lower (review, 23 Sep).
    @State private var promptAnchor: PromptAnchor = .page
    /// Set to scroll the page to its episode list (the add prompt's "I'm part-way through").
    @State private var scrollToEpisodes: UUID?
    enum PromptAnchor { case page, series, episodes, add }
    @State private var showStartRewatch = false
    /// Minted when a mark completes a season; the hairline sweep draws once per token.
    @State private var sweepToken: UUID?
    /// Minted when a mark completes the LAST part of the last season — the series milestone the
    /// status chip settles on. Separate from `sweepToken`: a season ending is not a show ending.
    @State private var milestoneToken: UUID?
    /// True once the hero art has left the top of the screen.
    ///
    /// The hero bleeds under the status bar, so this screen hides the navigation bar's background
    /// — and then nothing stops a season row from rendering at half opacity across the floating
    /// toolbar. `scrollEdgeChrome` holds FULL canvas only through the status bar (by design: it is
    /// a status-bar veil), and the ramp below it is exactly where the toolbar sits. So the bar
    /// takes its own background back the moment there is content rather than artwork behind it —
    /// which is what every shipping media app does, and is native rather than a second hand-rolled
    /// veil stacked on the first.
    @State private var scrolledUnderBar = false
    /// The season the Episodes section shows, once the picker has chosen one.
    @State private var selectedSeasonId: Int?
    /// The scroll offset, outside this view's state — read only by `DetailVeils` (Today's rule).
    @State private var scroll = ScrollOffset()
    /// Country-specific streaming availability, read apart from the franchise (the contract's
    /// rule, so a cold provider lookup never delays the page).
    @State private var providers: WatchAvailability?
    /// The page's trailers: the one card that plays in place (a tap — nothing starts by itself
    /// here), and its full screen.
    @State private var trailers = FeedAutoplay(autoplays: false)
    @State private var onScreen = false
    @Environment(\.scenePhase) private var scenePhase
    /// The related title whose show is being looked up, so a second tap waits for the first.
    @State private var resolvingRelated: String?
    /// The one quiet re-read that catches the catalogue's enrichment landing after the first fetch.
    @State private var enrichmentRetry: Task<Void, Never>?
    /// The profile's tab (X's Posts · Episodes · Media · About), and whether the page's own tab row
    /// has reached the bar — a copy pins there (`profileTabs`).
    @State private var showTab: ShowTab = .initial
    @State private var tabsPinned = false

    private var now: Int64 { appModel.now }
    private var isAX: Bool { typeSize.isAccessibilitySize }

    /// The cover's palette, made fit to be a GROUND (see `DetailTint`). The raw palette colour at
    /// full chroma composited to a saturated brown block on a warm poster — and to the *same*
    /// brown block on a magenta-and-cyan one, so the screen's one action card was carrying a
    /// colour that said nothing about the show it was derived from.

    /// The floating sync banner is drawn OVER content rather than inset from it, so while a
    /// failure is pending the last row of any screen is sliced through its glyphs. Until the
    /// banner carries a presented-state content inset of its own, the screens that can show one
    /// make room for it. (Shared-file request filed; this is the local half.)
    private var bottomClearance: CGFloat { DetailMetrics.bottomClearance }

    enum DetailPush: Hashable {
        case episodes(franchiseId: String, mediaId: Int, focusEpisode: Int?)
        case history(franchiseId: String)
        /// Another show, from this show's "More like this" shelf.
        case detail(franchiseId: String)
        /// Today's "Recommended for you ›" — the longer list.
        case recommendations
        /// A post on the show's timeline (its Posts tab), opened to its page.
        case post(id: String)
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            // The show's GROUND (6 Sep): the whole page sits in the art's hue at canvas depth —
            // `DetailTint.ground`, from `groundTopLightness` under the hero to `groundFootLightness`
            // at the foot, with one soft pool of the tint's light — instead of stepping from the
            // billboard onto #09090B ("the details screen should have the theme color veil over
            // the entire screen to make the experience more immersive", user). Two gradients, no
            // image, nothing per frame. The hero's copy scrim LANDS on the top colour
            // (`HeroCopyScrim(landing:)`), so there is no seam; a blurred wash behind the header
            // was tried on 30 Aug and put a 14-level luminance step across the screen because the
            // scrim landed on canvas over it. No `ArtBackdrop`: the billboard is the ambient art.
            showGround
            SkeletonGate(isLoading: franchise == nil && loading && !loadError) {
                detailSkeleton
            } content: {
                if let f = franchise {
                    screen(f)
                } else if loadError {
                    EmptyState(SyncCenter.shared.isOnline ? .serverNoCache : .offlineNoData, prominence: .major) {
                        Task { await load() }
                    }
                    .padding(.horizontal, ThemeMetrics.gutter)
                }
            }
        }
        .preference(key: TabBarGroundKey.self, value: groundFoot)
        // This screen hides its navigation-bar background so the hero can own the top. Two veils
        // replace the system edge, Today's anatomy exactly:
        //  * while ARTWORK is behind the toolbar, a soft one fades in with the scroll — the
        //    hero's own `HeroTopVeil` travels away with the picture, and the clock needs something
        //    once it has gone;
        //  * once CONTENT is behind the toolbar, the bar: opaque canvas through the toolbar's
        //    band (status bar + 46), then out over `barEdgeRamp`. It held through the status bar
        //    only before, and ramped across the toolbar — a season row at half ink under the back
        //    button.
        .chromeScrollEdgeHidden(.top)
        .overlay(alignment: .top) {
            DetailVeils(scroll: scroll, hardOn: scrolledUnderBar || tabsPinned,
                        band: Self.pinTop + (tabsPinned ? ShowTabsRow.height + FeedMetrics.hairline : 0),
                        color: DetailTint.chrome(pageTint))
        }
        // X's tabs, pinned under the bar once the page's own have reached it.
        .overlay(alignment: .top) {
            if tabsPinned, franchise != nil {
                ShowTabsRow(selected: $showTab)
                    .padding(.top, Self.pinTop)
                    .ignoresSafeArea(edges: .top)
            }
        }
        // The page steps BACK while a confirmation is up. The system alert is glass centred over
        // the hero's capsule and printed logo: the logo lit "Mark 414 episodes" as if it were the
        // default and the amber capsule tinted Cancel (review i4, N2). Under the veil, the glass
        // takes no emphasis from what happens to be behind it.
        .overlay {
            if prompt != nil {
                Color.black.opacity(0.72)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .animation(ThemeMotion.pick(ThemeMotion.uiGentle, reduceMotion: reduceMotion), value: prompt != nil)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbarBackground(.hidden, for: .navigationBar)
        // The system's own back button, at the system's own size, with no title beside it. Three
        // hand-built circles in one navigation stack — a glass one here, a flat grey one on
        // Episodes and another on History — is three answers to "how do I go back".
        .toolbarRole(.editor)
        // TWO items, not one `ToolbarItemGroup`.
        //
        // A group is one Liquid Glass capsule; the status pill and the `···` then drew their own
        // materials INSIDE it — three materials in one cluster, with a visible seam mid-capsule,
        // an empty stretch of glass around the ellipsis, and a refracted inner pill over bright
        // artwork that reads as a rendering bug. Two items are two capsules, drawn by the system,
        // and neither carries a background of its own.
        .toolbar {
            // The show's name docks into the bar once its billboard has scrolled away — the
            // native handover an inline title makes, and what Netflix's and Apple TV's bars do.
            // Before, the bar over a scrolled season list carried two pills and no noun.
            if let f = franchise {
                ToolbarItem(placement: .principal) { barTitle(f) }
                    .chromeSharedBackgroundHidden()
            }
            if let f = franchise {
                ToolbarItem(placement: .topBarTrailing) { overflowMenu(f) }
            }
        }
        .task(id: franchiseId) {
            await load()
            await loadProviders()
            #if DEBUG
            if isReadOnlyPreview, let f = franchise {
                if UserDefaults.standard.string(forKey: "detailPreviewPrompt") == "add" {
                    add(f, anchor: .add)
                } else if UserDefaults.standard.string(forKey: "detailPreviewPrompt") == "series" {
                    // From the link, as a tap raises it — so the capture shows where it hangs.
                    promptMarkSeries(f, anchor: .series)
                } else if UserDefaults.standard.string(forKey: "detailPreviewPrompt") == "season",
                          let part = focusSeason(f) {
                    promptBatchMark(f, part: part, through: part.markTarget(now: now))
                }
            }
            #endif
        }
        .task(id: loading) {
            // Keep the request through a failed fetch, then consume it only on this page after
            // a successful retry. Cancellation during a push/pop must not silently eat an Add.
            guard !loading, !loadError, fetched != nil else { return }
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled, let f = franchise else { return }
            if appModel.pendingAddPrompt == franchiseId {
                appModel.pendingAddPrompt = nil
                if !inLibrary { add(f, anchor: .add) }
            } else if appModel.pendingSeriesPrompt == franchiseId {
                appModel.pendingSeriesPrompt = nil
                promptMarkSeries(f, anchor: .series)
            }
        }
        // A trailer plays IN its card; full screen is asked for, and is that card's own player,
        // zoomed out of it (a swipe down carries it back, still playing).
        .fullScreenCover(item: Bindable(trailers).fullScreen) { playback in
            let show = franchise?.displayTitle ?? ""
            TrailerFullScreen(playback: playback, title: show,
                              subtitle: TrailerFullScreen.subtitle(playback.video, show: show),
                              byRotation: trailers.fullScreenByRotation,
                              onClosed: { trailers.fullScreenClosed(playback) })
                .navigationTransition(.zoom(sourceID: playback.key, in: trailerZoom))
                .perfScreen("Trailer")
        }
        // Nothing plays under a push or in the background.
        .onAppear { onScreen = true }
        .onDisappear {
            onScreen = false
            if appModel.pendingAddPrompt == franchiseId { appModel.pendingAddPrompt = nil }
            if appModel.pendingSeriesPrompt == franchiseId { appModel.pendingSeriesPrompt = nil }
        }
        .onChange(of: !onScreen || scenePhase != .active, initial: true) { _, held in trailers.suspend(held) }
        .onChange(of: appModel.library.count, initial: true) { _, _ in
            if let lib = appModel.franchise(id: franchiseId) { lastLibraryCopy = lib }
        }
        .modifier(PromptDialog(prompt: $prompt, shown: true))
        .sheet(isPresented: $showStartRewatch) {
            if let f = franchise {
                StartRewatchSheet(franchise: f) { scope, startedAt in startRewatch(f, scope: scope, startedAt: startedAt) }
                    // `.large` only: at `.medium` the scope list ran past the sheet's foot.
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
        }
        .allowsHitTesting(!isReadOnlyPreview)
    }

    // MARK: - Data

    /// `force` is the Retry footnote's; the appearance task passes nothing, so popping back
    /// from the season list no longer refetches the whole franchise under the user.
    private func load(force: Bool = false) async {
        guard force || fetched?.id != franchiseId else { return }
        loading = true
        defer { loading = false }
        do {
            let read = try await appModel.api.franchise(id: franchiseId, country: AppRegion.current)
            // The detail read reflows the identity line (the certificate rides it): a crossfade,
            // never a snap (review i4).
            withAnimation(ThemeMotion.pick(ThemeMotion.uiGentle, reduceMotion: reduceMotion)) { fetched = read }
            loadError = false
            retryEnrichmentIfEmpty()
        } catch {
            // A pop mid-fetch cancels the task; that is not a failed load and must not leave
            // the "couldn't refresh" footnote standing when the user comes back.
            if !error.isCancellation { loadError = true }
        }
    }

    /// Streaming availability is a second, separate read. A failure here is a missing section,
    /// never an error state: the page is about the show, not about where to stream it.
    private func loadProviders() async {
        guard providers == nil else { return }
        guard let availability = try? await appModel.api.watchProviders(id: franchiseId, country: AppRegion.current) else { return }
        withAnimation(ThemeMotion.pick(ThemeMotion.uiGentle, reduceMotion: reduceMotion)) { providers = availability }
    }

    /// The catalogue's deep metadata arrives stale-while-revalidate: the first read of a show can
    /// return before its people, related titles and trailers exist, and the server fills them in
    /// the background. One quiet re-read a few seconds later catches that, so the shelves fade in
    /// on this visit instead of the next.
    private func retryEnrichmentIfEmpty() {
        guard let f = fetched, f.looksUnenriched, enrichmentRetry == nil else { return }
        enrichmentRetry = Task {
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled,
                  let again = try? await appModel.api.franchise(id: franchiseId, country: AppRegion.current),
                  !again.looksUnenriched else { return }
            withAnimation(ThemeMotion.pick(ThemeMotion.uiGentle, reduceMotion: reduceMotion)) { fetched = again }
        }
    }

    /// The live franchise (fresh progress/status from the library) grafted with the detail
    /// fetch's per-episode data. A pinned snapshot wins while the card shows a mark's result.
    private var franchise: Franchise? {
        if let pinned { return pinned }
        // Off the library, the catalogue read keeps the face the library copy had.
        guard let base = appModel.franchise(id: franchiseId) ?? fetched.map({ f in lastLibraryCopy.map { f.keepingArt(of: $0) } ?? f }) else { return nil }
        let value = merged(base)
        #if DEBUG
        if let preview = UserDefaults.standard.string(forKey: "detailPreviewState"), !preview.isEmpty {
            let parts = value.parts.map { $0.withProgress(preview == "caught" ? $0.markTarget(now: now) : 0) }
            return Franchise(copying: value, parts: parts,
                             subscription: .some(nil), status: .some(preview == "untracked" ? nil : (preview == "planned" ? .planned : .watching)))
        }
        #endif
        return value
    }
    @State private var lastLibraryCopy: Franchise?

    private func merged(_ base: Franchise) -> Franchise {
        guard let fetched else { return base }
        return base.grafting(fetched)
    }

    private var isReadOnlyPreview: Bool {
        #if DEBUG
        return !(UserDefaults.standard.string(forKey: "detailPreviewState") ?? "").isEmpty
        #else
        return false
        #endif
    }
    private var inLibrary: Bool {
        #if DEBUG
        if isReadOnlyPreview { return UserDefaults.standard.string(forKey: "detailPreviewState") != "untracked" }
        #endif
        return appModel.isInLibrary(franchiseId) && !appModel.pendingAdds.contains(franchiseId)
    }
    private func catalogueNews(_ f: Franchise) -> ReleaseNews? {
        // The detail fetch is newer than the library snapshot and is not progress-dependent.
        (fetched ?? f).releaseNews(now: now)
    }
    private var staleAfterFailure: Bool { loadError && fetched != nil }

    // MARK: - Screen

    private func screen(_ f: Franchise) -> some View {
        ScrollViewReader { proxy in
            scrollContent(f)
                .debugDetailDrive(franchise: f, proxy: proxy, trailers: trailers, openRelated: openRelated,
                                  selectTab: { showTab = $0 })
                .onChange(of: scrollToEpisodes) { _, token in
                    guard token != nil else { return }
                    showTab = .episodes
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(120))
                        withAnimation(ThemeMotion.pick(ThemeMotion.uiSettle, reduceMotion: reduceMotion)) {
                            proxy.scrollTo("anchor-tabs", anchor: .top)
                        }
                    }
                }
                // A switch with the tabs pinned keeps them pinned: the new tab starts under them.
                .onChange(of: showTab) { _, _ in
                    guard tabsPinned else { return }
                    proxy.scrollTo("anchor-tabs", anchor: .top)
                }
        }
    }

    private func scrollContent(_ f: Franchise) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                profileHeader(f)
                profileTabs(f)
                VStack(alignment: .leading, spacing: 0) {
                    if staleAfterFailure {
                        InlineNotice(Copy.Notice.detailEpisodes) { Task { await load(force: true) } }
                            .padding(.horizontal, ThemeMetrics.gutter)
                            .padding(.top, ThemeSpace.x3)
                    }
                    profileTabContent(f)
                }
                .frame(minHeight: Self.tabMinHeight, alignment: .top)
            }
            // The scroll probe — geometry-based, because `onScrollGeometryChange` never fires on
            // the iOS 27 simulator (Today's discovery), which left the bar's veil dead in every
            // capture. The content's top edge in window space is the fact.
            .background {
                Color.clear.onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { minY in
                    scroll.set(-minY)
                }
            }
        }
        // The bottom clearance is a scroll-content MARGIN, not padding inside the stack.
        //
        // `pushedScreenChrome()` already gives every pushed screen `tabBarClearance`; this only
        // widens it while a sync failure is pending, because the floating banner is drawn OVER
        // content rather than inset from it. Padding inside the stack does nothing at all when the
        // content is shorter than the viewport, which is exactly the case in which the last line
        // came to rest inside the veil — the synopsis measured 4.39 → 1.04:1 over four lines.
        .contentMargins(.bottom, bottomClearance, for: .scrollContent)
        .scrollIndicators(.hidden)
        #if DEBUG
        .modifier(DebugScrollY())
        #endif
        .ignoresSafeArea(edges: .top)
        .task(id: f.portraitArt) { tint = await PaletteCache.shared.resolve(url: f.portraitArt, maxPixel: 420) }
        .task(id: heroArt(f).url) {
            heroTint = await PaletteCache.shared.resolve(url: heroArt(f).url, maxPixel: 420)
            heroLightness = PaletteCache.shared.lightness(for: heroArt(f).url)
            // The next loading frame's ground (iD18). `tint(for:)`, not the resolved value: it is
            // nil when the art could not be analysed, so the neutral fallback is never remembered.
            RememberedTint.remember(PaletteCache.shared.tint(for: heroArt(f).url))
        }
    }

    // MARK: - Hero (identity only)

    /// The floating toolbar's band below the status bar.
    private static let toolbarBand: CGFloat = 46
    /// The pitch between the page's catalogue shelves.
    static let shelfRhythm: CGFloat = 24
    /// The extra air before a chapter (Episodes, More like this): 24 + 16 = 40 pt.
    static let chapterBreak: CGFloat = 16

    /// The art the hero is made of: `Franchise.billboardArt` — the server-selected poster,
    /// composited whole, and the landscape only when the catalogue has none. Today's rule, for
    /// one hero grammar (the frame is a poster's shape; a backdrop in it is a slice of itself).
    private func heroArt(_ f: Franchise) -> (url: String?, portrait: Bool, ultraWide: Bool) {
        let art = f.wideArt
        return (art.url, art.portraitSource, art.ultraWide)
    }

    /// How hard the hero's veil, scrim and ground dim are drawn, from the art's lightness.
    private var heroStrength: Double {
        HeroProtection.strength(lightness: heroLightness
            ?? franchise.flatMap { PaletteCache.shared.lightness(for: heroArt($0).url) })
    }


    // MARK: - The show's ground (6 Sep)

    /// The colour the page is grounded in: the banner's palette, else the cover's (`heroBloom`'s base).
    private var groundColor: Color? { pageTint }

    /// The page's ONE colour: the billboard art's palette — resolved this visit, else remembered
    /// from the last (`PaletteCache` persists), so the page opens in its colour on the first
    /// frame. Never the cover's (`tint`) first and the billboard's a beat later: two images
    /// resolving at two moments painted the page in one hue and repainted it in another.
    private var pageTint: Color? {
        heroTint ?? franchise.flatMap { PaletteCache.shared.tint(for: heroArt($0).url) }
    }
    /// The ground's top, right under the hero — where `HeroCopyScrim` lands.
    private var groundTop: Color { DetailTint.ground(groundColor, lightness: DetailTint.groundTopLightness) }
    private var groundFoot: Color { DetailTint.ground(groundColor, lightness: DetailTint.groundFootLightness) }

    /// The whole page in the show's hue: a vertical run from the hero's foot to a near-canvas at
    /// the bottom (so the bottom chrome's canvas veil lands on it without a step), and one soft
    /// pool of the tint's light where the eye rests once the billboard has scrolled away — a light
    /// source, not a flat wash (`ArtAdaptiveGround`'s rule). Static, behind the scroll view.
    private var showGround: some View {
        ZStack(alignment: .top) {
            // The top colour holds through the hero's reach and only then eases to the foot's:
            // the hero's scrim lands on `groundTop`, and a ground already a fifth of the way to
            // `groundFoot` at the hero's foot drew a full-width seam there (review, 23 Sep). It
            // holds while scrolling too — the hero's foot only ever moves UP into the held band.
            LinearGradient(stops: [.init(color: groundTop, location: 0),
                                   .init(color: groundTop, location: 0.8),
                                   .init(color: groundFoot, location: 1)],
                           startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [(groundColor ?? PaletteCache.fallback).opacity(DetailTint.groundPool), .clear],
                           center: .init(x: 0.5, y: 0.36), startRadius: 0, endRadius: 360)
                .blendMode(.plusLighter)
        }
        .ignoresSafeArea()
        .animation(ThemeMotion.uiPoster, value: groundColor == nil)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// The loading shape has to be the shape that arrives — composed from the skeleton atoms
    /// (the DS's stale per-screen defaults were deleted in the cohesion pass).
    private var detailSkeleton: some View {
        ShowProfileSkeleton(tint: tint ?? RememberedTint.color, banner: Self.bannerHeight, avatar: Self.profileAvatar)
    }

    /// The year the WORK premiered — specials excluded.
    ///
    /// TMDB's season 0 carries the air date of the earliest featurette, which on Game of Thrones is
    /// 2010-12-05: a pre-launch promo, five months before the show existed. Taking a plain minimum
    /// across every part therefore printed "TV · 2010" on the flagship title. Same root cause as
    /// the 300-episode Specials row, and the same answer: a catalogue of extras is not a season of
    /// the work. (The server computes this field the same wrong way; filed as a shared-file
    /// request, and this is the client half so the screen is right either way.)
    private func premiereYear(_ f: Franchise) -> Int? {
        let real = f.parts.filter { $0.kind != .special }.compactMap(\.year)
        return (real.isEmpty ? f.parts.compactMap(\.year) : real).min()
    }

    /// The hero's ONE metadata line: "Anime · 2018 · Action · Adventure · Comedy" — the work's
    /// class and year, then its genres, in a single middot run (Apple TV's "TV Show · Comedy ·
    /// Sport"). The class and year used to be a small-caps eyebrow on the poster's baseline and
    /// the studio closed the genre run, where "8-Bit" and "WIT Studio" read as genres with a
    /// missing separator. A studio is a credit, not identity; it leaves the hero. The genre tail
    /// is shortened until the whole line fits one — a wrapped identity line is the same defect
    /// wearing a different hat.
    private func identityLine(_ f: Franchise) -> String? {
        // A genre is one name: "Sci-Fi & Fantasy" never breaks inside itself (review i2/i3 —
        // the AX line ended on "Sci-Fi &" with "Fantasy" alone on the next).
        let genres = f.parts.flatMap(\.genres)
            .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            .map {
                $0.localizedCapitalized
                    .replacingOccurrences(of: " ", with: "\u{00A0}")
                    // A word joiner after the hyphen: "Sci-" / "Fi" was the next break it found.
                    .replacingOccurrences(of: "-", with: "-\u{2060}")
            }
        var head = [f.kindWord]
        if let y = premiereYear(f) { head.append(String(y)) }
        // The market's own rating sits between the year and the genres, where Apple TV's line
        // puts it ("TV-MA · 2011 · Drama"). Nothing when the catalogue states nothing.
        if let rating = f.contentRatingLabel { head.append(rating) }
        // A conservative character budget for `heroMeta` across the gutter-to-gutter run. It is a
        // budget rather than a measurement on purpose: `minimumScaleFactor` absorbs the last few
        // points, and a `TextRenderer` pass on every identity change is not worth one line of type.
        // At the accessibility sizes the line BREAKS where it means to — what it is, then its
        // genres — instead of wrapping around a middot ("Action ·" ending one line, "· Sci-Fi"
        // starting the next; review, 23 Sep).
        if isAX {
            // The genres as a LIST — commas, which may end a line; a middot may not.
            let tail = Array(genres.prefix(3))
            return tail.isEmpty ? head.joined(separator: " · ")
                : head.joined(separator: " · ") + "\n" + tail.joined(separator: ", ")
        }
        let budget = 46
        var tail = Array(genres.prefix(3))
        while true {
            let line = (head + tail).joined(separator: " · ")
            if line.count <= budget || tail.isEmpty { return line }
            tail.removeLast()
        }
    }

    private func statusChoices(_ f: Franchise) -> some View {
        ForEach(WatchStatus.menuOrder, id: \.self) { option in
            // A status is a status, wherever it is chosen — the long press does the same. "Watched"
            // used to open a batch mark here (and could end in Watching); marking the episodes is
            // its own command, "Mark series as watched…" (review, 23 Sep).
            Button {
                appModel.setStatus(franchiseId: f.id, status: option)
            } label: {
                AppGlyphLabel(option.displayName, systemName: f.effectiveStatus == option ? "checkmark" : option.menuGlyph)
            }
        }
    }

    private func overflowMenu(_ f: Franchise) -> some View {
        Menu {
            if inLibrary {
                Menu { statusChoices(f) } label: {
                    AppGlyphLabel(f.effectiveStatus.displayName, systemName: f.effectiveStatus.menuGlyph)
                }
                // The toolbar acts on the season being shown in Episodes; elsewhere it uses
                // the same next part as the pinned post.
                progressChoices(f, part: showTab == .episodes ? focusSeason(f) : f.currentPart)
                if let session = RewatchStore.shared.activeSession(for: f.id) {
                    Divider()
                    Button(Copy.Action.restartRewatch) { promptRestartRewatch(f, session: session) }
                    Button(DetailCopy.stopRewatch) { promptCancelRewatch(f, session: session) }
                } else if watchedReleased(f) {
                    Divider()
                    Button(Copy.Action.startRewatch) { showStartRewatch = true }
                }
                if !RewatchStore.shared.sessions(for: f.id).isEmpty {
                    Button(Copy.Action.viewWatchHistory) { push(.history(franchiseId: f.id)) }
                }
                Divider()
                RemoveFromLibraryButton(franchise: f, appModel: appModel)
            } else {
                Button { add(f, anchor: .add) } label: {
                    AppGlyphLabel(Copy.Search.addToLibrary, systemName: "plus")
                }
                if seriesBehind(f) > 0 {
                    Button(Copy.Action.markSeriesWatched) { promptMarkSeries(f, anchor: .series) }
                }
                if let rec = appModel.recommendation(forShow: f.id) {
                    Divider()
                    Button { appModel.hideRecommendation(rec, seen: false) } label: {
                        AppGlyphLabel(Copy.ForYou.notInterested, systemName: "hand.thumbsdown")
                    }
                }
            }
        } label: {
            // No local glass disc: the toolbar item supplies the material, and the item is 44 pt,
            // so this sits on the same baseline as the back button and the status pill.
            AppGlyph(systemName: "ellipsis")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(ThemeColor.textPrimary)
                .frame(width: 44, height: 44)
        }
        // A CIRCLE, the back button's shape: two single-glyph buttons in two shapes (a 44-pt
        // circle and a 56×44 capsule) crowded a poster's printed title (critique, 24 Sep).
        .buttonBorderShape(.circle)
        .accessibilityLabel("More actions")
        .disabled(loading || appModel.pendingAdds.contains(f.id))
    }

    /// The same season/series commands in the toolbar and the pinned post.
    @ViewBuilder
    private func progressChoices(_ f: Franchise, part: FranchisePart?) -> some View {
        if let part, !part.isUpcoming {
            let target = part.markTarget(now: now)
            if target > part.progress {
                Button(Copy.Action.markAll(target - part.progress)) {
                    promptBatchMark(f, part: part, through: target)
                }
            }
            if part.progress > 0 {
                Button(Copy.Action.markAllUnwatched(part.progress)) { promptResetSeason(f, part: part) }
            }
        }
        if seriesBehind(f) > 0 {
            Button(Copy.Action.markSeriesWatched) { promptMarkSeries(f, anchor: .series) }
        }
    }

    // MARK: - Next up card

    struct NextUp: Equatable {
        enum Kind: Equatable { case actionable, backlog, caughtUp, seasonComplete, seriesComplete, waiting }
        let kind: Kind
        let part: FranchisePart?
        /// The STATE, staged in the block's capsule eyebrow — Today's hero grammar ("9 EPISODES
        /// BEHIND", "CAUGHT UP", "COMPLETE"). The fact lines below carry the object; the eyebrow
        /// carries what kind of moment this is.
        let eyebrow: String
        /// The eyebrow's amber dot — a fresh, actionable episode only, like Today's hero.
        var dot: Bool = false
        /// The WHEN, leading the lockup's one line ahead of the fact (Today's grammar, 5 Sep):
        /// today's drop ("Aired 2h ago"), a caught-up show's next airing ("Friday at 7:30 PM").
        var moment: String? = nil
        let line1: String
        let line2: String?
        let line3: String?
        let episode: Int?
        let behind: Int
        var identity: String { "\(kind)/\(part?.mediaId ?? 0)/\(episode ?? 0)" }
        static func == (a: NextUp, b: NextUp) -> Bool { a.identity == b.identity && a.line2 == b.line2 }
    }

    /// The finished state, said once.
    ///
    /// The headline used to be "You’ve finished Attack on Titan" at 22 pt, 180 pt below "Attack on
    /// Titan" at 28 pt: the show's name twice at near-hero weight in one viewport, while the two
    /// facts the card exists to deliver — how many times, and when — sat under it in tertiary grey.
    /// A card headlines its STATE; the identity is the hero's job and the hero already did it.
    private func completeState(_ f: Franchise) -> NextUp {
        let summary = RewatchStore.shared.summary(for: f.id)
        let last = summary.lastCompletedAt.flatMap {
            $0 > 0 ? "Last finished \(TemporalCopy.dateWord($0, now: now, anchor: .local))" : nil
        }
        // A show finished before the app ever saw it has no recorded date. The card still states
        // what was watched rather than leaving the fact column empty beside a 132-pt poster.
        let scale: String? = {
            // The STORY's episodes: two unwatched recap OVAs made Mob Psycho's "39" (iteration 2).
            let episodes = f.mainStoryEpisodicParts.reduce(0) { $0 + max($1.totalEpisodes, $1.progress) }
            return episodes > 0 ? Copy.episodes(episodes) : nil
        }()
        // The curated "what's next", so this page cannot say COMPLETE while the Library's shelf
        // says "Returns Oct 2026" about the same show — and a rumour is called one.
        let ahead: String? = {
            guard let up = f.upcoming, up.isFutureInstallment, !up.hasArrived(now: now) else { return nil }
            // With its verb ("Returns Jan 2027"): this page has no "Returning" header to lend one.
            let returnFact = ReturnFact.of(f, appModel: appModel)
            let fact = returnFact.sentence.isEmpty ? returnFact.text : returnFact.sentence
            if up.isRumored { return fact }
            guard let next = up.next, !next.isEmpty else { return fact }
            return "\(next) \u{00B7} \(fact)"
        }()
        // The fact and its scale on ONE line ("Watched once · 95 episodes"), then the ONE more
        // thing — the curated next, else the date. Three equal grey lines gave the reader
        // nothing to read first (review, 5 Sep).
        // "Watched once" under a COMPLETE badge beside a "Watched" pill said one fact three ways
        // (review i2/i3); the count earns its place from a second viewing on.
        let times = summary.completedCount > 1 ? Copy.Progress.watchedTimes(summary.completedCount) : nil
        let fact = [times, scale].compactMap { $0 }.joined(separator: " \u{00B7} ")
        return NextUp(kind: .seriesComplete, part: nil, eyebrow: Copy.Label.complete,
                      line1: fact, line2: ahead ?? last, line3: nil, episode: nil, behind: 0)
    }

    private func nextUpState(_ f: Franchise) -> NextUp? {
        if f.isSeriesComplete {
            return completeState(f)
        }
        // Handle an announcement before the Planned branch can invent progress + 1.
        if let part = f.currentPart, part.isUpcoming {
            return announcementState(f, part: part)
        }
        // A Planned show waits (interactive review: it shouted "2 EPISODES BEHIND" with a "Mark as
        // watched" capsule on a bookmark). The status capsule is the way to start.
        // STATUS decides where a show lives, PROGRESS what it says (iteration 2): a Planned show
        // is PLANNED here as on Today, Library and Schedule — no behind count, no mark capsule —
        // and names where you stopped ("Season 5 · Episode 9", with the bar) over "Continue
        // watching", which is the step that files it under Watching. The page alone said
        // "5 EPISODES BEHIND" about a show every other screen treated as a bookmark.
        if f.effectiveStatus == .planned, let part = f.currentPart ?? f.resumePart ?? f.releasingPart {
            // The airing with its subject — "Episode 14 airs Sunday at 4:30 PM", the page's one
            // cadence line — never a bare "Sunday at 4:30 PM" under where you stopped.
            let next: String? = f.nextAiring(now: now).map { at in
                let airing = f.releasingPart
                let episode = airing?.airings.first(where: { $0.at == at })?.episode ?? airing?.nextEpisodeNumber
                return Copy.Progress.episodeAirs(episode, when: TemporalCopy.airs(at: at, now: now, source: f.source))
            }
            return NextUp(kind: .waiting, part: part, eyebrow: Copy.Status(.planned),
                          line1: f.watchContext(part: part, episode: part.progress + 1),
                          line2: next, line3: nil, episode: nil, behind: 0)
        }
        guard let part = f.currentPart else {
            // Nothing to resume: an announced installment waits; a finished run (with extras the
            // catalogue still lists as upcoming) is complete for the viewer.
            if let up = f.parts.first(where: \.isUpcoming) {
                return announcementState(f, part: up)
            }
            // ...and so does one the catalogue announces with no placeholder season: ONE lockup
            // for "everything out is watched, the next is announced" (review i3 — Wednesday read
            // "SEASON 3 ANNOUNCED" and Thrones, Avatar and 3 Body Problem "COMPLETE" with an amber
            // rewatch, for the same state, by whether a placeholder part existed). A rumour is
            // not an announcement: that show is complete, and says the rumour.
            if let up = f.upcoming, up.isFutureInstallment, !up.isRumored, !up.hasArrived(now: now),
               catalogueNews(f) != nil {
                return announcementState(f, part: nil)
            }
            let episodic = f.episodicPartsInOrder
            if !episodic.isEmpty, episodic.allSatisfy(\.isComplete) {
                return completeState(f)
            }
            return nil
        }
        let target = part.markTarget(now: now)
        let behind = max(0, target - part.progress)
        if behind == 0 {
            if part.isComplete && !part.isReleasing {
                let next = f.episodicPartsInOrder.first { $0.isUpcoming }
                return NextUp(kind: .seasonComplete, part: part, eyebrow: Copy.Label.complete,
                              line1: Copy.Progress.complete(part.canonicalLabel),
                              line2: "\(part.canonicalLabel) · \(Copy.Progress.watchedOf(part.progress, max(part.totalEpisodes, part.progress)))",
                              line3: next.map { "\($0.canonicalLabel) \(TemporalCopy.returns(at: $0.premiereAt, now: now, source: f.source).lowercasedFirst())" },
                              episode: nil, behind: 0)
            }
            let nextEp = part.nextEpisodeNumber ?? part.progress + 1
            // The STATE goes to the eyebrow and the EPISODE is the fact (user, 30 Aug): a show
            // airing tonight led with a 22-pt "Caught up" while "Today at 8:30 PM" — the thing the
            // person opened the show for — hid in the support line. "Caught up" is what kind of
            // moment this is; "Season 5 · Episode 10 · airs tonight" is the moment itself.
            // (The shared watch-context rule: a multi-season show names its season here too.)
            // The next airing is the MOMENT, leading the line ("Friday at 7:30 PM · Season 5 ·
            // Episode 10"); only its absence is a support line.
            let next = f.nextAiring(now: now).map { TemporalCopy.airs(at: $0, now: now, source: f.source) }
            return NextUp(kind: .caughtUp, part: part, eyebrow: Copy.Progress.caughtUp,
                          moment: next,
                          line1: f.watchContext(part: part, episode: nextEp),
                          line2: next == nil ? TemporalCopy.noDateAnnounced : nil,
                          line3: nil, episode: nil, behind: 0)
        }
        let episode = part.progress + 1
        let context = f.watchContext(part: part, episode: episode)
        if behind > 1 {
            // The count is the STATE — it stages the block from the eyebrow, as on Today's hero,
            // instead of repeating under the fact as a support line.
            // The one more thing is the DROP while it is fresh — Today's last line, verbatim
            // (review i3: one lockup, two rooms, two different last lines); the cadence
            // returns as the caught-up state's moment the instant the backlog is cleared.
            // Fresh for as long as Today's deck calls it fresh (`outNowWindow`): at midnight a
            // five-hour-old drop stopped being named here while the deck still led with it and the
            // episode list still tagged it NEW (review i3).
            let last = part.lastAired(now: now, anchor: f.timeAnchor)
            let fresh = last.map { now - $0 <= AppModel.outNowWindow } ?? false
            let drop = fresh && part.isReleasing
                ? last.map { Copy.Progress.dropAired(episode: part.airedByNow(now: now, anchor: f.timeAnchor),
                                                     when: TemporalCopy.aired(at: $0, now: now, source: f.source)) } : nil
            // A show filed WATCHED with seasons unmarked says so under its own status — never a
            // backlog's "16 EPISODES LEFT" under a "Watched" pill (review i3: The Witcher, Seasons
            // 3–4 at 0; SAKAMOTO DAYS at 0 of 22). A mark moves it to Watching and says so.
            if f.effectiveStatus == .completed {
                return NextUp(kind: .backlog, part: part, eyebrow: Copy.Status(.completed),
                              line1: context, line2: Copy.Progress.unmarked(max(behind, f.seriesLeft(now: now))),
                              line3: nil, episode: episode, behind: behind)
            }
            // A FRESH drop (the deck's window, not Paused, news for this viewer) is NEW EPISODE on
            // the show page too — Today's badge for the same show — with the count on the one
            // line (24 Sep: NEW in the news red; a 3-behind drop read "3 EPISODES BEHIND" here).
            let isNewDrop = drop != nil && f.effectiveStatus != .paused
                && part.isNews(now: now, anchor: f.timeAnchor, window: AppModel.outNowWindow)
            if isNewDrop {
                return NextUp(kind: .backlog, part: part, eyebrow: Copy.Label.newEpisode,
                              line1: "\(context) \u{00B7} \(Copy.Progress.behindShort(behind))", line2: nil,
                              line3: nil, episode: episode, behind: behind)
            }
            return NextUp(kind: .backlog, part: part,
                          eyebrow: part.isReleasing ? Copy.Progress.behind(behind)
                              : Copy.Progress.left(max(behind, f.seriesLeft(now: now))),
                          line1: context, line2: drop ?? newEpisodeLine(f),
                          line3: nil, episode: episode, behind: behind)
        }
        // Today's fresh-hero grammar, verbatim (5 Sep): a drop that struck today is "NEW EPISODE"
        // on the badge with its recency leading the line ("Aired 2h ago · Season 4 · Episode
        // 19"); an older single drop wears its day on the badge and has no moment.
        let last = part.lastAired(now: now, anchor: f.timeAnchor)
        let recency = last.map { TemporalCopy.aired(at: $0, now: now, source: f.source) }
        let struck = last.map { Formatting.dayDiff(ts: $0, now: now, anchor: f.timeAnchor) == 0 } ?? false
        // No third line. "Caught up after this episode" restated what the badge and the
        // one-episode CTA already say; the capsule is the sentence.
        // NEW EPISODE only for an airing: a finished run's last episode says so, and a film of
        // the story is next up — "NEW EPISODE" over a 2018 recap OVA was the default (review,
        // 23 Sep).
        let quiet = part.kind == .movie ? Copy.Label.nextUp : Copy.Progress.lastEpisodeOfTheSeason
        // Watched with one episode unmarked: the status, and the fact about the marks.
        if f.effectiveStatus == .completed {
            return NextUp(kind: .actionable, part: part, eyebrow: Copy.Status(.completed),
                          line1: context, line2: Copy.Progress.unmarked(max(1, f.seriesLeft(now: now))),
                          line3: nil, episode: episode, behind: 1)
        }
        // The badge says the STATE and the line the moment — Today's lockup for the same show
        // (iteration 2: "AIRED YESTERDAY" on the page's badge, "NEW EPISODE" on Today's).
        return NextUp(kind: .actionable, part: part,
                      // NEW only while it is news — inside the deck's out-now window, and never
                      // on a PAUSED show: Bleach, paused, read "NEW EPISODE" over a 12-day-old
                      // episode (review i5, F14). An older single drop is one episode behind.
                      eyebrow: f.effectiveStatus == .paused
                        ? Copy.Progress.behind(1)
                        : (struck || (part.isReleasing && (last.map { now - $0 <= AppModel.outNowWindow } ?? false))
                            ? Copy.Label.newEpisode
                            : (part.isReleasing ? Copy.Progress.behind(1) : quiet)),
                      dot: true,
                      moment: part.isReleasing ? recency : nil,
                      line1: context, line2: newEpisodeLine(f),
                      line3: nil, episode: episode, behind: 1)
    }

    /// One grammar with the catalogue news a Planned show wears: the announcement ON the badge,
    /// its date — with a verb — on the line ("SEASON 3 ANNOUNCED" over "Premieres 20 Nov").
    /// "UPCOMING" over "Season 3 announced" over "No date announced" said one fact three times,
    /// and a Planned page and a Watched page stated the same announcement two ways (review, 23 Sep).
    private func announcementState(_ f: Franchise, part: FranchisePart?) -> NextUp {
        // A show you WATCH that is waiting on its next season: you are caught up — the badge is
        // your state, the announcement and its date the lines (review, 23 Sep: "UPCOMING" on the
        // badge meant this Sunday, Summer 2027, 2027 and "no date" on four pages).
        // ONE grammar for "everything out is watched, the next is announced", whatever the
        // status (24 Sep, owner: "revisit its states, there is some inconsistency"): Wistoria read
        // "CAUGHT UP · Season 3 announced", One Piece "CAUGHT UP · Season 3 · Returns 2027",
        // Wednesday "SEASON 3 ANNOUNCED · Returns summer 2027" — three shapes for one state. The
        // news is the badge; its date (or "No date yet") is the line.
        if let news = catalogueNews(f) {
            return NextUp(kind: .waiting, part: part, eyebrow: news.headline,
                          line1: news.detail ?? TemporalCopy.noDateAnnounced, line2: nil,
                          line3: nil, episode: nil, behind: 0)
        }
        guard let part else { return completeState(f) }
        let split = Copy.Release.announcement(part.canonicalLabel)
        let release = part.announcedDateLabel(source: f.source).map(TemporalCopy.premieres)
            ?? TemporalCopy.noDateAnnounced
        return NextUp(kind: .waiting, part: part, eyebrow: split.badge,
                      line1: [split.subject, release].compactMap { $0 }.joined(separator: " \u{00B7} "),
                      line2: nil, line3: nil, episode: nil, behind: 0)
    }

    /// "Episode 19 airs Friday at 7:30 PM" — the airing cadence, on the block whose eyebrow says
    /// how far behind you are. Netflix ("New episode coming on Saturday") and Apple TV ("New Episode
    /// Every Wednesday") both put it directly under the lockup; this screen had it nowhere while a
    /// show was behind. It NAMES the episode (`Copy.Progress.episodeAirs`), the future twin of the
    /// "Episode 18 aired 50 min ago" line beside it. Planned shows are off the calendar, so they
    /// get no line.
    private func newEpisodeLine(_ f: Franchise) -> String? {
        guard f.tracksAirings, let at = f.nextAiring(now: now) else { return nil }
        let part = f.releasingPart
        let episode = part?.airings.first(where: { $0.at == at })?.episode ?? part?.nextEpisodeNumber
        return Copy.Progress.episodeAirs(episode, when: TemporalCopy.airs(at: at, now: now, source: f.source))
    }

    /// The name the bar can hold: `displayTitle` when it fits at a step of scale, else the
    /// shelf-shortened form, else nil.
    static func dockedName(_ f: Franchise, budget: Int = 19) -> String? {
        if f.displayTitle.count <= budget { return f.displayTitle }
        let short = f.title.shelfShortened
        return short.count <= budget ? short : nil
    }

    /// The title, docked. Visible only once the billboard has left; hidden from VoiceOver until
    /// then so the screen does not announce its name twice.
    private func barTitle(_ f: Franchise) -> some View {
        // The short name every row and shelf uses; the full title is the billboard's. Fit, or
        // shortened, or the show's LOGO (24 Sep: Slime's bar was empty on every scrolled frame
        // while Re:ZERO's and Thrones' named themselves — the critique), or nothing (review i2):
        // between the back circle and two capsules the item has ~150 pt, and "That Time I Got
        // R…" over a season list says less than a bar with no noun. A character budget, as the
        // identity line uses.
        Group {
            if let name = Self.dockedName(f) {
                Text(name)
                    .type(ThemeType.bodyEmphasis)
                    .foregroundStyle(ThemeColor.textPrimary)
                    .lineLimit(1)
                    // "Game of Thr…" between the back circle and two capsules (review, 5 Sep): a
                    // step of scale before an ellipsis on the one docked title the app draws.
                    .minimumScaleFactor(0.85)
                    .allowsTightening(true)
            } else if !isAX, let logo = f.billboardLogo, let w = logo.width, let h = logo.height, w > 0, h > 0 {
                let aspect = CGFloat(w) / CGFloat(h)
                let height = min(Self.dockedLogoHeight, Self.dockedLogoWidth / aspect)
                RemoteImageView(url: logo.url, contentMode: .fit, maxPixel: 480, placeholderHidden: true)
                    .frame(width: height * aspect, height: height)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(f.title)
                    .accessibilityAddTraits(.isHeader)
            }
        }
        .opacity(scrolledUnderBar ? 1 : 0)
        .animation(ThemeMotion.pick(ThemeMotion.uiGentle, reduceMotion: reduceMotion), value: scrolledUnderBar)
        .accessibilityHidden(!scrolledUnderBar)
    }

    /// A docked logo's box: the bar's title height, within the ~150 pt the item has.
    private static let dockedLogoHeight: CGFloat = 28
    private static let dockedLogoWidth: CGFloat = 140

    /// Under the card once any session exists: the way into watch history (board 06 §1.6).
    @ViewBuilder
    private func historyRow(_ f: Franchise) -> some View {
        let sessions = RewatchStore.shared.sessions(for: f.id)
        if !sessions.isEmpty {
            GroupedList {
                // `symbolTint: .clear` — the glyph sits directly on the plate. A filled 28-pt tile
                // inside a plate is a second container around a symbol, and tiles are for rows that
                // carry ART. And the row states a fact the card above does not: the card says how
                // many times the show was watched, this says how much watching that was.
                GroupedRow(symbol: "clock.arrow.circlepath", symbolTint: .clear,
                           title: Copy.Action.viewWatchHistory,
                           // PREDICATED. "95 episodes" (the work) and "50 episodes" (what the user
                           // watched) sat two taps apart in the same noun phrase, so within one
                           // show the same words meant two different quantities.
                           // One rule with the history screen (review i5, F15: "72 episodes
                           // watched" here, "36" there): finished sessions count their length, the
                           // live one what is marked so far, a stopped one where it stopped.
                           subtitle: Copy.episodesWatched(sessions.reduce(0) { total, s in
                               if s.isCompleted { return total + s.episodes }
                               if s.isActive {
                                   return total + f.episodicPartsInOrder.reduce(0) { $0 + $1.progress }
                               }
                               return total + (s.cancelledAtEpisode ?? 0)
                           }),
                           trailing: .chevron(nil), separator: false) {
                    push(.history(franchiseId: f.id))
                }
            }
        }
    }

    // MARK: - Rewatch

    private func startRewatch(_ f: Franchise, scope: WatchSession.Scope, startedAt: Int64) {
        let parts: [FranchisePart] = {
            switch scope {
            case .franchise: return f.episodicPartsInOrder
            case .part(let mediaId): return f.parts.filter { $0.mediaId == mediaId }
            }
        }()
        let snapshot = parts.map { ($0.mediaId, $0.progress) }
        let previousStatus = f.effectiveStatus
        let episodes = parts.reduce(0) { $0 + max($1.totalEpisodes, $1.progress) }
        let session = RewatchStore.shared.startRewatch(franchiseId: f.id, scope: scope, startedAt: startedAt, episodes: episodes,
                                                       restoreProgress: Dictionary(uniqueKeysWithValues: snapshot),
                                                       restoreStatus: previousStatus.rawValue)
        // The rail's arrival is drawn once, on the next Watch history that renders.
        RewatchArrival.record(session.id)
        // A beginning is a commit, not an achievement (review i2): `.success` is the season's.
        FeedbackCoordinator.fire(.commitMedium)
        withAnimation(ThemeMotion.pick(ThemeMotion.uiSettle, reduceMotion: reduceMotion)) {
            for (mediaId, progress) in snapshot where progress > 0 {
                appModel.setProgress(franchiseId: f.id, mediaId: mediaId, episodes: 0, haptic: false)
            }
            appModel.setStatus(franchiseId: f.id, status: .watching, haptic: false, present: false)
        }
        appModel.presentUndo(UndoState(mediaId: nil, franchiseId: f.id, prevProgress: 0, title: f.title, episode: 0,
                                       customMessage: Copy.Toast.rewatchStarted) {
            RewatchStore.shared.delete(session.id)
            for (mediaId, progress) in snapshot { appModel.setProgress(franchiseId: f.id, mediaId: mediaId, episodes: progress, haptic: false) }
            appModel.setStatus(franchiseId: f.id, status: previousStatus, haptic: false, present: false)
        })
    }

    private func promptRestartRewatch(_ f: Franchise, session: WatchSession) {
        let watched = f.episodicPartsInOrder.reduce(0) { $0 + $1.progress }
        prompt = WritePrompt(title: Copy.Confirm.restartRewatchTitle, message: Copy.Confirm.restartRewatch(count: watched),
                             confirm: Copy.Confirm.restartRewatchConfirm, destructive: true) {
            FeedbackCoordinator.fire(.commitMedium)
            // The same receipt a season reset gets: a toast that names what moved and an Undo
            // that restores the exact snapshot. It wiped every tick with neither.
            let snapshot = f.episodicPartsInOrder.map { ($0.mediaId, $0.progress) }
            for (mediaId, progress) in snapshot where progress > 0 {
                appModel.setProgress(franchiseId: f.id, mediaId: mediaId, episodes: 0, haptic: false)
            }
            appModel.presentUndo(UndoState(mediaId: nil, franchiseId: f.id, prevProgress: 0, title: f.title, episode: 0,
                                           customMessage: Copy.Toast.rewatchRestarted) {
                for (mediaId, progress) in snapshot where progress > 0 {
                    appModel.setProgress(franchiseId: f.id, mediaId: mediaId, episodes: progress, haptic: false)
                }
            })
        }
    }

    private func promptCancelRewatch(_ f: Franchise, session: WatchSession) {
        let at = f.currentPart?.progress ?? 0
        let restores = session.restoreProgress != nil
        prompt = WritePrompt(title: Copy.Action.stopRewatchTitle,
                             message: restores
                                ? Copy.Confirm.stopRewatchRestores(at: at)
                                : "The session is kept in your history as cancelled at \(Copy.episodeInSentence(at)).",
                             confirm: Copy.Action.stopRewatchConfirm, destructive: true) {
            // Cancelling keeps the record: a commit, not a deletion.
            FeedbackCoordinator.fire(.commitLight)
            RewatchStore.shared.cancel(session.id, atEpisode: at, at: now)
            // ...and the show goes back to where it stood before the rewatch (review i5, F3: a
            // finished show stopped at Episode 1 read "35 EPISODES LEFT" everywhere).
            if let restore = session.restoreProgress {
                for (key, progress) in restore {
                    guard let mediaId = Int(key) else { continue }
                    appModel.setProgress(franchiseId: f.id, mediaId: mediaId, episodes: progress, haptic: false)
                }
                if let raw = session.restoreStatus, let status = WatchStatus(rawValue: raw) {
                    appModel.setStatus(franchiseId: f.id, status: status, haptic: false, present: false)
                }
                appModel.showNotice(Copy.Toast.rewatchStoppedRestored)
            }
        }
    }

    // MARK: - Mark timeline (board 03)

    private func mark(_ f: Franchise, part: FranchisePart) {
        guard committedEpisode == nil else { return }
        let completes = part.progress + 1 >= part.markTarget(now: now) && !part.isReleasing && part.totalEpisodes > 0
        let snapshot = f
        // The haptic (a finished season or series signs `.success`) is decided in `markNext`, the
        // same on every surface.
        guard let undo = appModel.markNext(franchiseId: f.id, mediaId: part.mediaId) else { return }
        if completes {
            sweepToken = UUID()
            let others = f.episodicPartsInOrder.filter { $0.mediaId != part.mediaId }
            let seriesDone = others.allSatisfy(\.isComplete) && !f.parts.contains { $0.isReleasing || $0.isUpcoming }
            if seriesDone {
                milestoneToken = UUID()
                if let active = RewatchStore.shared.activeSession(for: f.id) { RewatchStore.shared.complete(active.id, at: now) }
                appModel.setStatus(franchiseId: f.id, status: .completed, haptic: false, present: false)
            }
        }
        pinned = snapshot
        withAnimation(ThemeMotion.pick(ThemeMotion.uiMicro, reduceMotion: reduceMotion)) { committedEpisode = undo.episode }
        // The capsule's drawn check and exact episode are the confirmation. Repeating that fact in
        // an inline receipt directly beneath it made one write look like two competing responses;
        // the Undo — the one thing the frame cannot carry — goes to the lane once the frame has
        // settled, exactly as Today's hero and this capsule's own batch menu do (review, 23 Sep).
        Announce.status(Copy.Progress.episodeWatched(undo.episode))
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(650))
            withAnimation(ThemeMotion.pick(ThemeMotion.uiSettle, reduceMotion: reduceMotion)) {
                pinned = nil
                committedEpisode = nil
            }
            // On a clock, not the animation's completion, which did not fire for this hand-off:
            // the Undo was never presented (Today's hero, the same day).
            try? await Task.sleep(for: .milliseconds(reduceMotion ? 120 : 420))
            appModel.presentUndo(undo)
        }
    }

    // MARK: - Confirmations (exact blast radius)

    struct WritePrompt: Identifiable {
        let id = UUID()
        let title: String
        let message: String
        let confirm: String
        var destructive = false
        let perform: () -> Void
        /// A second, non-destructive choice beside the confirm ("Start from Episode 1").
        var alternative: (label: String, perform: () -> Void)? = nil
        var third: (label: String, perform: () -> Void)? = nil
        /// Further choices, in order — the season list of "Which season are you on?".
        var choices: [(label: String, perform: () -> Void)] = []
    }

    /// One Add flow for every entry point. Catalogue state changes the available answers;
    /// recommendation cache, airing status and the button's position never choose for the user.
    private func add(_ f: Franchise, anchor: PromptAnchor = .page) {
        guard !loading, !inLibrary, !appModel.pendingAdds.contains(f.id) else { return }
        let batch = WatchedBatch(franchise: f, now: now)
        // A removed/re-added show may retain watch marks. Availability is independent of them;
        // the caught-up answer still states only the marks that its write will change.
        let released = WatchedBatch(franchise: Franchise(copying: f, parts: f.parts.map { $0.withProgress(0) }), now: now)
        let seasons = f.seasonPartsInOrder.filter { !$0.isUpcoming && $0.markTarget(now: now) > 0 }
        promptAnchor = anchor
        var choice = WritePrompt(
            title: Copy.Confirm.whereAreYou(f.displayTitle),
            message: Copy.Confirm.libraryAddMessage(episodes: released.episodeCount, films: released.filmCount),
            confirm: Copy.ForYou.addToPlanned,
            perform: {
                guard !isReadOnlyPreview else { return }
                appModel.addToLibrary(franchiseId: f.id, title: f.title,
                                      isReleasing: f.isReleasing, status: .planned)
            })
        if !released.parts.isEmpty {
            choice.alternative = (Copy.Today.startOrContinue(f), {
                guard !isReadOnlyPreview else { return }
                appModel.addToLibrary(franchiseId: f.id, title: f.title,
                                      isReleasing: f.isReleasing, status: .watching)
            })
            if released.episodeCount > 1, !seasons.isEmpty {
                choice.third = (Copy.Confirm.partWay, {
                    guard !isReadOnlyPreview else { return }
                    guard seasons.count > 1 else {
                        appModel.addToLibrary(franchiseId: f.id, title: f.title,
                                              isReleasing: f.isReleasing, status: .watching)
                        selectedSeasonId = seasons.first?.mediaId
                        scrollToEpisodes = UUID()
                        return
                    }
                    Task { @MainActor in
                        // Let the first alert dismiss before presenting its second step.
                        try? await Task.sleep(for: .milliseconds(400))
                        guard onScreen else { return }
                        promptAnchor = anchor
                        prompt = seasonPrompt(f, seasons: seasons)
                    }
                })
            }
            if !batch.parts.isEmpty {
                choice.choices = [(Copy.Confirm.caughtUpAdd(batch.episodeCount, films: batch.filmCount), {
                    guard !isReadOnlyPreview else { return }
                    appModel.markWatched(f, batch: batch)
                })]
            }
        }
        prompt = choice
    }

    /// "Which season are you on?" — the part-way answer's second step.
    private func seasonPrompt(_ f: Franchise, seasons: [FranchisePart]) -> WritePrompt {
        func choose(_ part: FranchisePart) {
            guard !isReadOnlyPreview else { return }
            let earlier = WatchedBatch(franchise: f, before: part, now: now)
            if earlier.parts.isEmpty {
                appModel.addToLibrary(franchiseId: f.id, title: f.title, isReleasing: f.isReleasing, status: .watching)
            } else {
                // The add and the earlier seasons in one write, with one Undo that takes both back.
                appModel.markWatched(f, batch: earlier)
            }
            selectedSeasonId = part.mediaId
            scrollToEpisodes = UUID()
        }
        func name(_ part: FranchisePart) -> String { part.canonicalLabel.isEmpty ? part.title : part.canonicalLabel }
        let first = seasons[0]
        return WritePrompt(title: Copy.Confirm.whichSeason,
                           message: Copy.Confirm.whichSeasonMessage,
                           confirm: name(first), perform: { choose(first) },
                           choices: seasons.dropFirst().map { part in (name(part), { choose(part) }) })
    }

    private func promptBatchMark(_ f: Franchise, part: FranchisePart, through: Int,
                                 anchor: PromptAnchor = .page) {
        let count = through - part.progress
        guard count > 0 else { return }
        promptAnchor = anchor
        prompt = WritePrompt(title: Copy.Confirm.batchMarkTitle(count),
                             message: Copy.Confirm.batchMarkMessage(title: f.displayTitle, season: part.canonicalLabel, from: part.progress, to: through),
                             confirm: Copy.Confirm.batchMarkConfirm(count)) {
            let prev = part.progress
            let shelvedAs = appModel.resumableStatus(f, part: part)
            appModel.setProgress(franchiseId: f.id, mediaId: part.mediaId, episodes: through)
            var receipt = UndoState(mediaId: part.mediaId, franchiseId: f.id, prevProgress: prev,
                                    title: f.title, episode: through, count: count)
            // Marks watch the show (`AppModel.resume`) — unless this batch finished it.
            appModel.resume(shelvedAs, franchiseId: f.id, mediaId: part.mediaId, prevProgress: prev, receipt: &receipt)
            appModel.presentUndo(receipt)
        }
    }

    /// Episodes of the whole work that are aired and unwatched. 0 means there is nothing a
    /// series-level mark could do, and the command is not offered.
    /// Every released episode of the story is watched (and at least one exists) — the moment a
    /// rewatch makes sense, whether or not the catalogue has more on the way.
    private func watchedReleased(_ f: Franchise) -> Bool {
        let released = f.mainStoryEpisodicParts.filter { !$0.isUpcoming && $0.markTarget(now: now) > 0 }
        return !released.isEmpty && released.allSatisfy { $0.progress >= $0.markTarget(now: now) }
    }

    private func seriesBehind(_ f: Franchise) -> Int {
        WatchedBatch(franchise: f, now: now).episodeCount
    }

    /// "I watched all of this, elsewhere." One confirmation stating the true total across every
    /// season, then the instant write (`AppModel.markWatched`) — one `.success`, one lane Undo
    /// that puts every part (and, for a show that was not in the library, the membership) back.
    private func promptMarkSeries(_ f: Franchise, anchor: PromptAnchor = .page) {
        let batch = WatchedBatch(franchise: f, now: now)
        guard batch.episodeCount > 0 else { return }
        promptAnchor = anchor
        let seasons = Copy.plural(batch.seasonCount, "season", "seasons")
        let scope = batch.filmCount == 0 ? seasons : "\(seasons) and \(Copy.plural(batch.filmCount, "film", "films"))"
        // The caveat is about the STORY: its unaired episodes, else its unreleased films — never
        // an extra, and never "episodes" for a film (review i3).
        let unairedEpisodes = f.mainStoryEpisodicParts.contains { $0.isReleasing || $0.isUpcoming }
        let unreleasedFilms = f.mainStoryMovies.contains { $0.isUpcoming }
        let caveat = unairedEpisodes ? Copy.Confirm.unairedStay : (unreleasedFilms ? Copy.Confirm.unreleasedFilmsStay : nil)
        prompt = WritePrompt(title: Copy.Confirm.batchMarkTitle(batch.episodeCount, films: batch.filmCount),
                             message: Copy.Confirm.watchedBatch(title: f.title, scope: scope, addsToLibrary: !inLibrary,
                                                                caveat: caveat),
                             confirm: Copy.Confirm.batchMarkConfirm(batch.episodeCount, films: batch.filmCount)) {
            guard !isReadOnlyPreview else { return }
            appModel.markWatched(f, batch: batch)
            milestoneToken = UUID()
        }
    }

    private func promptResetSeason(_ f: Franchise, part: FranchisePart) {
        let total = part.progress
        prompt = WritePrompt(title: Copy.Confirm.resetSeasonTitle(total),
                             message: Copy.Confirm.resetSeason(label: part.canonicalLabel, total: total),
                             confirm: Copy.Confirm.resetSeasonConfirm(total), destructive: true) {
            appModel.setProgress(franchiseId: f.id, mediaId: part.mediaId, episodes: 0)
            appModel.presentUndo(UndoState(mediaId: part.mediaId, franchiseId: f.id, prevProgress: total,
                                           title: f.title, episode: 0, count: total,
                                           customMessage: Copy.Toast.seasonUnmarked(part.canonicalLabel)))
        }
    }

    // MARK: - About

    /// The catalogue's themes — only the ones the identity line's genres do not already say — as
    /// one quiet run under the synopsis (Netflix's "This show is: …"), never a plate of chips.
    @ViewBuilder
    private func themesLine(_ f: Franchise) -> some View {
        let themes = f.themesBeyondGenres.prefix(4)
        // A run of one is not a run (review i5: "Friendship" alone under a paragraph).
        if themes.count >= 2 {
            Text(themes.map(\.localizedCapitalized).joined(separator: " \u{00B7} "))
                .type(ThemeType.feedMeta)
                .foregroundStyle(ThemeColor.feedSecondary)
                .lineLimit(2)
        }
    }

    // MARK: - Seasons & movies

    /// Full-width rows on the canvas, sized by their artwork. The plate is gone: a season list is
    /// not a settings group, and 68-pt rows with 8 %-white rules down a stroked box is exactly
    /// what makes a media app read as Settings → General.
    /// A catalogue of featurettes is not a member of the work. TMDB's season 0 on Game of Thrones
    /// carries **300** of them; printed inline after Season 1 with an empty tick column and a
    /// subtitle in a grammar no other row used, it read as "this app thinks there are 300 Game of
    /// Thrones specials" — and a viewer who disbelieves one count disbelieves every count above it.
    private static let extraKinds: Set<PartKind> = [.special, .music]

    // MARK: - Episodes (the season picker, a window of rows, the way to the whole run)

    /// The season the Episodes section shows: the picker's choice, else the season a route landed
    /// on (a Schedule card), else the one the screen is about (airing, resuming, or the earliest
    /// unfinished) when that is a season, else the earliest unfinished season, else the last.
    private func focusSeason(_ f: Franchise) -> FranchisePart? {
        let seasons = f.seasonPartsInOrder
        if let id = selectedSeasonId ?? focus?.mediaId, let p = seasons.first(where: { $0.mediaId == id }) { return p }
        #if DEBUG
        if let label = UserDefaults.standard.string(forKey: "detailSeason"),
           let part = seasons.first(where: { $0.canonicalLabel == label }) { return part }
        #endif
        return f.defaultEpisodeSeason
    }

    /// "Episodes" and, trailing, the season as a capsule menu (`SeasonPill`) — the streaming apps'
    /// grammar: a section labelled Episodes, one "Season 4 ⌄" pill that lists seasons only.
    /// Where-you-are is the bar under it, never "18 of 24" in numerals: beside a window that opened
    /// on Episode 18 the pair read as "showing 18 of 24" (4 Sep).
    private func episodesHeader(_ f: Franchise, part: FranchisePart) -> some View {
        let seasons = f.seasonPartsInOrder
        // The hero's denominator (`progressDenominator`) — one bar, one answer, on one page.
        let total = part.progressDenominator(now: now, anchor: f.timeAnchor)
        let watched = min(part.progress, total)
        return VStack(alignment: .leading, spacing: ThemeSpace.x2) {
            // The tab says "Episodes"; the header is the season.
            HStack(alignment: .center, spacing: ThemeSpace.x2) {
                if seasons.count > 1 {
                    SeasonPill(current: part, seasons: seasons) { id in
                        withAnimation(ThemeMotion.pick(ThemeMotion.uiGentle, reduceMotion: reduceMotion)) {
                            selectedSeasonId = id
                        }
                    }
                } else if !part.canonicalLabel.isEmpty {
                    // One season with a name: the name, as a fact, not a control.
                    Text(part.canonicalLabel)
                        .type(ThemeType.metadataEmphasis)
                        .foregroundStyle(ThemeColor.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            // Only BETWEEN the ends: a full bar across the page was an amber
            // rule that read as decoration (Thrones, every season watched), an empty one a grey
            // rule saying nothing the rings do not (critique, 24 Sep).
            if total > 0, !part.isUpcoming, watched > 0, watched < total {
                ProgressBar(value: Double(watched) / Double(total),
                            spoken: Copy.Progress.watchedOf(watched, total))
            }
            // The season's command, visible (20 Sep), with the words the capsule's menu, the "…"
            // menu and the long press use — and only while there is something to mark: a finished
            // season is its discs, and the "…" menu undoes it.
            let target = part.markTarget(now: now)
            // The profile has no hero capsule: the season's batch lives here (and in the pinned
            // post's `···`).
            if inLibrary, target > part.progress {
                Button(Copy.Action.markAll(target - part.progress)) {
                    promptBatchMark(f, part: part, through: target, anchor: .episodes)
                }
                .buttonStyle(InlineLinkButtonStyle())
                // On the gutter, like "Read more": the style's 12-pt target padding set the word
                // 12 pt inside the header it belongs to (review, 23 Sep).
                .padding(.leading, -12)
                .padding(.vertical, -6)
                .disabled(loading)
            }
        }
        .zIndex(1)
    }

    // MARK: - Catalogue shelves (trailers · people · related · where to watch)

    /// The people who made it and the people in it — Apple TV's cast row: a disc, a name, a role.
    @ViewBuilder
    private func peopleShelf(_ f: Franchise) -> some View {
        let people = Array((f.people?.ordered ?? []).prefix(20))
        if !people.isEmpty {
            DetailShelf(title: Copy.Heading.castAndCrew, leading: ThemeMetrics.gutter - PersonCard.columnInset) {
                ForEach(people) { PersonCard(person: $0).frame(maxHeight: .infinity, alignment: .top) }
            }
            .id("anchor-people")
        }
    }

    /// A FINISHED show's page leads with what to watch next: the user's own recommendations that
    /// this show votes for — "Because you finished Re:ZERO" — above its episode list (review i5,
    /// N5: finishing a series ended on "Start rewatch" and the catalogue's unpersonalised "More
    /// like this"). The For you tile, reason and all; hidden when the list names none.
    @ViewBuilder
    private func becauseYouFinished(_ f: Franchise) -> some View {
        let items = inLibrary && f.effectiveStatus == .completed
            ? Array(appModel.visibleRecommendations.filter { r in
                r.reason.seeds.contains { $0.franchiseId == f.id } && !appModel.isOwned(r)
            }.prefix(12))
            : []
        if !items.isEmpty {
            DetailShelf(title: Copy.ForYou.becauseYouFinished(f.displayTitle)) {
                ForEach(items) { r in
                    ForYouTile(item: r, reason: appModel.spokenReason(r), width: PosterSize.shelfLarge.size.width) {
                        Task { if let id = await appModel.franchiseId(for: r) { push(.detail(franchiseId: id)) } }
                    }
                }
            }
        }
    }

    /// The catalogue's own recommendations, as the shelf card every other shelf draws. A title
    /// the catalogue has not materialised yet is looked up by name on the tap.
    @ViewBuilder
    private func relatedShelf(_ f: Franchise) -> some View {
        let related = Array(f.related.prefix(12))
        if !related.isEmpty {
            DetailShelf(title: Copy.Heading.moreLikeThis) {
                ForEach(related) { r in
                    // Today's shelf size: three 112-pt cards filled the run exactly and the fourth
                    // showed 5 pt, so the shelf gave no sign it scrolls (review, 23 Sep).
                    // A show you already have says where it is ("Watching"), not what it is —
                    // Mushoku read "Anime · 2021" here while Watching (review i3).
                    let owned = r.franchiseId.flatMap { appModel.franchise(id: $0) }
                    // A SHELF, not a grid: the caption sits directly under a one-line name (the
                    // owner's 24 Aug rule; a reserved second line left "Steins;Gate", a hole, then
                    // "Anime · 2011"). ONE caption anatomy — what it is and when — with a show you
                    // already have marked ON its poster, the For you shelf's owned mark: the second
                    // line alternated "Watched" / "TV · 2017" down one shelf (critique, 24 Sep).
                    ShelfCard(title: r.title,
                              caption: r.identityLine,
                              poster: r.portraitArt, slot: .todayShelf) {
                        openRelated(r)
                    }
                    .overlay(alignment: .topTrailing) {
                        if owned != nil { OwnedMark().padding(6) }
                    }
                    .opacity(resolvingRelated == r.id ? 0.55 : 1)
                    .accessibilityValue(owned.map { Copy.Status($0.effectiveStatus) } ?? "")
                    .accessibilityHint(Copy.Accessibility.opensTheShowHint)
                }
            }
            .padding(.top, Self.chapterBreak)
            .id("anchor-related")
        }
    }

    /// Two catalogue titles name the same work: equal ignoring case, diacritics and width
    /// ("ChäoS;HEAd" / "Chaos;Head"), or equal once punctuation and spacing are dropped
    /// ("Re:ZERO" / "Re ZERO").
    static func sameName(_ a: String, _ b: String) -> Bool {
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]
        if a.compare(b, options: options) == .orderedSame { return true }
        func core(_ s: String) -> String {
            s.folding(options: options, locale: nil).lowercased().filter { $0.isLetter || $0.isNumber }
        }
        let x = core(a), y = core(b)
        return !x.isEmpty && x == y
    }

    private func openRelated(_ r: RelatedTitle) {
        if let id = r.franchiseId {
            push(.detail(franchiseId: id))
            return
        }
        guard resolvingRelated == nil else { return }
        resolvingRelated = r.id
        Task {
            defer { resolvingRelated = nil }
            // The catalogue has not materialised this title yet. An exact-title search asks the
            // server to, and a same-source hit WITH THE SAME NAME is the show (the same year first,
            // when two works share a name). Never the first hit whatever it is called: "Steins;Gate"
            // in Re:ZERO's More like this opened Chaos;Head, a card promising one show and a page
            // about another (review, 23 Sep). No match is the honest notice below.
            let res: SearchResponse? = try? await appModel.api.search(query: r.title, exact: true)
            let named = (res?.franchises ?? []).filter { $0.source == r.source && Self.sameName($0.title, r.title) }
            let hit = named.first { $0.year != nil && $0.year == r.year } ?? named.first
            if let hit {
                push(.detail(franchiseId: hit.id))
            } else {
                appModel.showNotice(Copy.Notice.notInCatalogue)
            }
        }
    }

    /// Streaming, for the viewer's own market: the providers' marks in a row, the header the way
    /// to the options. Drawn only when the catalogue has a match with somewhere to stream — a
    /// section that says "not here" is not a section.
    @ViewBuilder
    private func whereToWatch(_ f: Franchise) -> some View {
        if let availability = providers, availability.status == .available, !availability.providers.isEmpty {
            WatchProvidersRow(availability: availability) {
                if let url = availability.linkURL { openURL(url) }
            }
            .id("anchor-watch")
        }
    }

    // MARK: - Movies & extras (the non-season parts, as a shelf)

    /// Everything that is not a season, as art: films and units the viewer marks whole (a tap
    /// toggles, with Undo), episodic extras — an OVA run, an ONA, a spin-off — that open their own
    /// episode list, and the catalogue's own extras — dimmed, because the app does not count them.
    /// The seasons live in the pill above.
    @ViewBuilder
    private func extrasShelf(_ f: Franchise) -> some View {
        let spine = Set(f.seasonPartsInOrder.map(\.mediaId))
        let others = f.parts.filter { !spine.contains($0.mediaId) }.sorted { $0.sequence < $1.sequence }
        // The work's own films and runs first; the catalogue's featurettes (season 0) only BESIDE
        // them. A section that existed to show one dimmed card nobody can tap — Thrones' "Specials
        // · 300 episodes" — was a placeholder with a header (critique, 24 Sep).
        let tracked = others.filter { !Self.extraKinds.contains($0.kind) }
        let parts = tracked.isEmpty ? [] : tracked + others.filter { Self.extraKinds.contains($0.kind) }
        if parts.count == 1, let part = parts.first {
            // ONE card beside 250 pt of bare ground read as a shelf that failed to load: a lone
            // part is a row, the list's own anatomy.
            VStack(alignment: .leading, spacing: ThemeMetrics.labelGap) {
                SectionHeaderRow(Copy.Heading.moviesAndExtras)
                extraRow(f, part: part)
            }
        } else if !parts.isEmpty {
            VStack(alignment: .leading, spacing: ThemeMetrics.labelGap) {
                SectionHeaderRow(Copy.Heading.moviesAndExtras)
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: ThemeMetrics.shelfGap) {
                        ForEach(parts) { part in extraCard(f, part: part) }
                    }
                    .padding(.leading, ThemeMetrics.gutter)
                    .padding(.vertical, ThemeSpace.x1)
                }
                .scrollIndicators(.hidden)
                .scrollClipDisabled()
                // Art may run off the trailing edge; TYPE may not. See `shelfScroller`.
                .shelfScroller()
                // The section sits inside the page gutter; the shelf runs edge to edge.
                .padding(.horizontal, -ThemeMetrics.gutter)
            }
        }
    }

    /// One caption anatomy for the shelf (critique, 24 Sep: "OVA 1" and "Sukuwareru Ramiris" had
    /// no second line beside "The Movie · Film · 2026"): what is COMING in accent when there is
    /// something ("Episode 4 next", "Premieres 20 Nov"), else what it is and when — "OVA · 2016".
    private func extraCaption(_ f: Franchise, part: FranchisePart) -> (text: String?, lead: Bool) {
        if Self.extraKinds.contains(part.kind) {
            return (part.totalEpisodes > 1 ? Copy.episodes(part.totalEpisodes) : Copy.partKind(part.kind), false)
        }
        let facts = partFacts(f, part: part)
        if let lead = facts.lead { return (lead, true) }
        let kindYear = [Copy.partKind(part.kind), part.year.map(String.init)].compactMap { $0 }
            .joined(separator: " \u{00B7} ")
        return (kindYear, false)
    }

    private func openExtra(_ f: Franchise, part: FranchisePart) {
        let isExtra = Self.extraKinds.contains(part.kind)
        if isExtra { return }
        // A run of episodes (an OVA series, an ONA, a spin-off) is marked episode by episode on
        // its own screen; a single unit toggles whole.
        if part.totalEpisodes > 1 {
            push(.episodes(franchiseId: f.id, mediaId: part.mediaId, focusEpisode: part.progress + 1))
        } else if inLibrary {
            toggleUnit(f, part: part)
        }
    }

    /// A lone part, as a row: its poster, its name, its caption, and the settled disc once it is
    /// watched (a run that opens its episodes carries the chevron instead).
    private func extraRow(_ f: Franchise, part: FranchisePart) -> some View {
        let isExtra = Self.extraKinds.contains(part.kind)
        let episodic = !isExtra && part.totalEpisodes > 1
        let settled = !isExtra && part.isFinished
        let caption = extraCaption(f, part: part)
        return HStack(spacing: ThemeSpace.x2) {
            MediaRow(title: part.canonicalLabel.isEmpty ? part.title : part.canonicalLabel,
                     meta: caption.lead ? nil : caption.text,
                     lead: caption.lead ? caption.text : nil,
                     poster: part.portraitArt ?? f.portraitArt,
                     slot: .row,
                     chevron: episodic,
                     separator: false,
                     hint: episodic ? "Opens its episodes" : (inLibrary ? "Toggles watched" : nil)) {
                openExtra(f, part: part)
            }
            if settled && !episodic { settledBadge }
        }
        .accessibilityValue(settled ? Copy.Accessibility.complete : "")
    }

    private func extraCard(_ f: Franchise, part: FranchisePart) -> some View {
        let isExtra = Self.extraKinds.contains(part.kind)
        let episodic = !isExtra && part.totalEpisodes > 1
        // The same count the unit's list draws (interactive review: "Complete" over a list with
        // four unwatched episodes).
        let settled = !isExtra && part.isFinished
        let caption = extraCaption(f, part: part)
        return ShelfCard(title: part.canonicalLabel.isEmpty ? part.title : part.canonicalLabel,
                         caption: caption.text,
                         captionIsLead: caption.lead,
                         poster: part.portraitArt ?? f.portraitArt,
                         slot: .todayShelf) {
            openExtra(f, part: part)
        }
        .overlay(alignment: .topTrailing) {
            if settled { settledBadge.padding(6) }
        }
        // A catalogue of featurettes the app does not track is not a control.
        .opacity(isExtra ? 0.6 : 1)
        .allowsHitTesting(!isExtra)
        // Not tappable, so not a button to VoiceOver either — it offered a double-tap that did
        // nothing.
        .accessibilityRemoveTraits(isExtra ? .isButton : [])
        .accessibilityValue(settled ? Copy.Accessibility.complete : "")
        .accessibilityHint(isExtra ? "" : (episodic ? "Opens its episodes" : (inLibrary ? "Toggles watched" : "")))
    }

    /// A settled unit's mark, in the add disc's own geometry: 26 pt, scrim ground, a check.
    private var settledBadge: some View {
        AppGlyph(systemName: "checkmark")
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(ThemeColor.textPrimary)
            .frame(width: 26, height: 26)
            .background(ThemeColor.scrimStrong, in: Circle())
            .overlay(Circle().strokeBorder(ThemeColor.hairline, lineWidth: 1))
            .accessibilityHidden(true)
    }

    /// A row's facts, split by direction and by KIND: what is coming is `lead` and earns the
    /// accent; where you are is the `progress` bar; words for what has happened are gone (the
    /// tick, the bar and the season's own label say it). "11 of 24 watched" under "9 episodes
    /// behind" under "Season 4" was three lines of text per row on a page the art should carry;
    /// Netflix and Apple TV draw the position as a bar and say nothing.
    private func partFacts(_ f: Franchise, part: FranchisePart) -> (meta: String?, lead: String?, progress: Double?, spokenProgress: String?) {
        if part.isUpcoming {
            if let d = part.announcedDateLabel(source: f.source) { return (nil, TemporalCopy.premieres(d), nil, nil) }
            return (TemporalCopy.noDateAnnounced, nil, nil, nil)
        }
        // The specials bucket is a CATALOGUE, not a run. It lives under its own EXTRAS label now,
        // and it says what it is: a pile of featurettes the app does not count against progress.
        if Self.extraKinds.contains(part.kind) {
            let scale = part.totalEpisodes > 1 ? Copy.episodes(part.totalEpisodes) : "Extras"
            return ("\(scale) · not counted towards progress", nil, nil, nil)
        }
        if part.kind != .season && part.totalEpisodes <= 1 {
            // No "Watched" word: the settled tick in the trailing column is that fact.
            var bits = [Copy.partKind(part.kind)]
            if let y = part.year { bits.append(String(y)) }
            return (bits.joined(separator: " · "), nil, nil, nil)
        }
        let total = max(part.totalEpisodes, part.airedEpisodes)
        let started = total > 0 && part.progress > 0 && part.progress < total
        let ratio: Double? = started ? Double(min(part.progress, total)) / Double(total) : nil
        let spoken: String? = started ? Copy.Progress.watchedOf(min(part.progress, total), total) : nil
        if part.isReleasing {
            let behind = part.behind(now: now, anchor: f.timeAnchor)
            if behind > 0 { return (nil, Copy.Progress.behind(behind), ratio, spoken) }
            if let at = f.nextAiring(now: now), f.releasingPart?.mediaId == part.mediaId {
                return (nil, TemporalCopy.airs(at: at, now: now, source: f.source), ratio, spoken)
            }
            return (Copy.Progress.caughtUp, nil, ratio, spoken)
        }
        // "You are here." The in-progress season carries the one forward-looking fact.
        if f.currentPart?.mediaId == part.mediaId, part.progress < total {
            return (nil, Copy.Progress.episodeNext(part.progress + 1), ratio, spoken)
        }
        // A FINISHED season says nothing: the tick is the statement.
        if part.isComplete && !part.isReleasing { return (nil, nil, nil, nil) }
        if started {
            return (nil, Copy.Progress.left(total - part.progress), ratio, spoken)
        }
        // Not started: its size, as a count, not "0 of 12 watched".
        return (total > 0 ? Copy.episodes(total) : nil, nil, nil, nil)
    }

    private func toggleUnit(_ f: Franchise, part: FranchisePart) {
        let full = max(part.totalEpisodes, 1)
        let watched = part.progress >= full
        let prev = part.progress
        appModel.setProgress(franchiseId: f.id, mediaId: part.mediaId, episodes: watched ? 0 : full)
        appModel.presentUndo(UndoState(mediaId: part.mediaId, franchiseId: f.id, prevProgress: prev, title: f.title, episode: full,
                                       customMessage: "\(part.canonicalLabel.isEmpty ? part.title : part.canonicalLabel) marked as \(watched ? "unwatched" : "watched")"))
    }
}

// MARK: - The show's profile (X's — ShowProfileParts.swift has the anatomy and the why)

extension FranchiseDetailView {
    /// Where the tabs pin: under the status bar and the floating toolbar.
    static var pinTop: CGFloat { ThemeMetrics.topSafeInset + toolbarBand }
    /// The banner: the show's landscape at 16:9 (X's is 3:1; the art leads here).
    static var bannerHeight: CGFloat { (ThemeMetrics.windowWidth * 9 / 16).rounded() }
    static let profileAvatar: CGFloat = 84
    /// A tab shorter than the screen still lets the header scroll away, so the tabs can stay
    /// pinned when a switch lands on a short one (X's rule).
    static var tabMinHeight: CGFloat {
        ThemeMetrics.windowHeight - pinTop - ShowTabsRow.height - ThemeMetrics.tabBarVisualHeight
    }

    // MARK: Header

    func profileHeader(_ f: Franchise) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            profileBanner(f)
            profileAvatarRow(f)
            VStack(alignment: .leading, spacing: ThemeSpace.x2) {
                profileName(f)
                profileIdentity(f)
                profileBio(f)
                profileFacts(f)
                profileCounts(f)
                profileReason(f)
            }
            .padding(.horizontal, ThemeMetrics.gutter)
        }
    }

    private func profileBanner(_ f: Franchise) -> some View {
        let wide = f.wideArt
        let h = Self.bannerHeight
        return ZStack {
            // The ground under the picture, so the frame never flashes canvas while it decodes.
            (pageTint ?? PaletteCache.fallback)
            LandscapeArt(url: wide.url, portraitSource: wide.portraitSource,
                         maxPixel: wide.ultraWide ? 1900 : 1400, ultraWide: wide.ultraWide)
        }
        .frame(height: h)
        .frame(maxWidth: .infinity)
        .clipped()
        // A pull grows the banner from its foot, as X's does.
        .modifier(PullStretch(scroll: scroll, height: h))
        // The clock and the floating glass read over any picture.
        .overlay(alignment: .top) {
            HeroTopVeil(band: Self.pinTop, strength: heroStrength)
                .modifier(HoldsThroughPull(scroll: scroll))
        }
        .accessibilityHidden(true)
    }

    /// X's avatar over the banner's foot, ringed in the page's ground, and the Follow pill on the
    /// right under the banner.
    private func profileAvatarRow(_ f: Franchise) -> some View {
        let a = Self.profileAvatar
        return ZStack(alignment: .topLeading) {
            HStack {
                Spacer(minLength: 0)
                followPill(f)
            }
            .padding(.top, ThemeSpace.x2)
            ShowAvatar(franchise: f, size: a)
                .padding(4)
                .background(groundTop, in: ShowAvatar.shape(a + 8))
                .offset(x: -4, y: -a / 2 - 4)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, ThemeMetrics.gutter)
        .frame(height: a / 2 + ThemeSpace.x3, alignment: .top)
    }

    @ViewBuilder
    private func followPill(_ f: Franchise) -> some View {
        if appModel.pendingAdds.contains(f.id) {
            ShowFollowPillLabel(text: Copy.Search.adding, filled: false)
                .accessibilityLabel(Copy.Search.adding)
        } else if inLibrary {
            Menu { statusChoices(f) } label: {
                ShowFollowPillLabel(text: f.effectiveStatus.displayName, filled: false, chevron: true)
            }
            .buttonStyle(.plain)
            // Finishing a series is the payoff the app is built around: the pill settles with the
            // milestone, claimed once per commit.
            .milestone(token: milestoneToken, reduceMotion: reduceMotion)
            .accessibilityLabel("Change status, \(f.effectiveStatus.displayName)")
        } else {
            Button { add(f, anchor: .add) } label: {
                ShowFollowPillLabel(text: Copy.Search.addToLibrary, filled: true)
            }
            .buttonStyle(FeedIconPressStyle())
            .disabled(loading || appModel.pendingAdds.contains(f.id))
            .accessibilityLabel("Add \(f.title) to Library")
            .accessibilityHint(Copy.Search.addHint)
        }
    }

    private func profileName(_ f: Franchise) -> some View {
        Text(f.displayTitle)
            .type(ThemeType.feedProfileName)
            .foregroundStyle(ThemeColor.feedText)
            .lineLimit(isAX ? 4 : 2)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
            // The bar docks the name the moment this one has passed under it — a flip, never a
            // per-frame write (the scroll-offset rule).
            .onGeometryChange(for: Bool.self) { $0.frame(in: .global).maxY < Self.pinTop } action: { under in
                if under != scrolledUnderBar {
                    withAnimation(ThemeMotion.pick(ThemeMotion.uiGentle, reduceMotion: reduceMotion)) { scrolledUnderBar = under }
                }
            }
    }

    /// Where X prints the handle: what the show is — "Anime · 2018 · TV-14 · Action · Adventure".
    @ViewBuilder
    private func profileIdentity(_ f: Franchise) -> some View {
        if let line = identityLine(f) {
            Text(line)
                .type(ThemeType.feedMeta)
                .foregroundStyle(ThemeColor.feedSecondary)
                .lineLimit(isAX ? 3 : 1)
                .minimumScaleFactor(0.9)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, -ThemeSpace.x1)
        }
    }

    /// The synopsis as the bio: three lines, cut at a word, and X's "Show more" when there is more.
    @ViewBuilder
    private func profileBio(_ f: Franchise) -> some View {
        let synopsis = Formatting.stripHtml(f.parts.first { !(($0.synopsis ?? "").isEmpty) }?.synopsis)
        if !synopsis.isEmpty {
            let overflows = synopsisFullHeight > synopsisClampedHeight + 1
            VStack(alignment: .leading, spacing: 0) {
                Text(synopsisExpanded || !overflows ? synopsis : Self.clampedAtWord(synopsis, budget: Self.synopsisBudget))
                    .type(ThemeType.feedLight)
                    .foregroundStyle(ThemeColor.feedText)
                    .lineSpacing(2)
                    .lineLimit(synopsisExpanded ? nil : 3)
                    .fixedSize(horizontal: false, vertical: true)
                    // The whole paragraph, measured behind the clamped one: the link only where
                    // it does something.
                    .background {
                        Text(synopsis)
                            .type(ThemeType.feedLight)
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .hidden()
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { synopsisFullHeight = $0 }
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { synopsisClampedHeight = $0 }
                if synopsisExpanded || overflows {
                    Button(synopsisExpanded ? Copy.ShowPage.showLess : Copy.ShowPage.showMore) {
                        withAnimation(ThemeMotion.pick(ThemeMotion.uiSnappy, reduceMotion: reduceMotion)) { synopsisExpanded.toggle() }
                    }
                    .buttonStyle(InlineLinkButtonStyle())
                    .padding(.leading, -12)
                    .padding(.vertical, -8)
                }
            }
            .padding(.top, ThemeSpace.x1)
        }
    }

    /// X's meta row: when the next episode airs, how many seasons, and where to watch as the link.
    @ViewBuilder
    private func profileFacts(_ f: Franchise) -> some View {
        let next: String? = f.nextAiring(now: now).map { at in
            let airing = f.releasingPart
            let episode = airing?.airings.first(where: { $0.at == at })?.episode ?? airing?.nextEpisodeNumber
            return Copy.Progress.episodeAirs(episode, when: TemporalCopy.airs(at: at, now: now, source: f.source))
        }
        let seasons = f.seasonPartsInOrder.count
        let provider = providers.flatMap { $0.status == .available ? $0.providers.first : nil }
        if next != nil || seasons > 1 || provider != nil {
            ShowFactsFlow {
                if let next {
                    AppGlyphLabel(next, systemName: "calendar")
                }
                if seasons > 1 {
                    AppGlyphLabel(Copy.ShowPage.seasons(seasons), systemName: "square.stack")
                }
                if let provider, let url = providers?.linkURL {
                    Button { openURL(url) } label: {
                        AppGlyphLabel(provider.name, systemName: "link")
                            .foregroundStyle(ThemeColor.interactive)
                    }
                    .buttonStyle(.plain)
                }
            }
            .type(ThemeType.feedMeta)
            .foregroundStyle(ThemeColor.feedSecondary)
            .labelStyle(ShowFactLabelStyle())
            .padding(.top, ThemeSpace.x1)
        }
    }

    /// X's counts, the story's: "96 Watched   99 Episodes" (only the second off the library).
    @ViewBuilder
    private func profileCounts(_ f: Franchise) -> some View {
        let story = f.mainStoryEpisodicParts
        let watched = story.reduce(0) { $0 + $1.progress }
        let episodes = story.reduce(0) { $0 + max($1.totalEpisodes, $1.progress) }
        if episodes > 0 {
            let counts = inLibrary
                ? countText(watched, Copy.ShowPage.watchedCount) + Text("   ") + countText(episodes, Copy.ShowPage.episodesCount)
                : countText(episodes, Copy.ShowPage.episodesCount)
            counts
                .type(ThemeType.feedMeta)
                .lineLimit(1)
                .minimumScaleFactor(0.9)
        }
    }

    private func countText(_ n: Int, _ label: String) -> Text {
        Text(n.formatted()).foregroundStyle(ThemeColor.feedText).fontWeight(.semibold)
            + Text(" \(label)").foregroundStyle(ThemeColor.feedSecondary)
    }

    /// X's "Followed by …", for a show recommended to you: the faces of your shows it comes from,
    /// and the reason in words.
    @ViewBuilder
    private func profileReason(_ f: Franchise) -> some View {
        if !inLibrary, let rec = appModel.recommendation(forShow: f.id) {
            let reason = appModel.spokenReason(rec)
            let seeds = Array(reason.seeds.compactMap { appModel.franchise(id: $0.franchiseId) }.prefix(3))
            HStack(spacing: ThemeSpace.x2) {
                if !seeds.isEmpty {
                    HStack(spacing: -6) {
                        ForEach(seeds, id: \.id) { seed in
                            ShowAvatar(franchise: seed, size: 20)
                                .overlay(ShowAvatar.shape(20).strokeBorder(groundTop, lineWidth: 1.5))
                        }
                    }
                    .accessibilityHidden(true)
                }
                Text(Copy.ForYou.reason(reason))
                    .type(ThemeType.feedSmall)
                    .foregroundStyle(ThemeColor.feedSecondary)
                    .lineLimit(2)
            }
            .padding(.top, ThemeSpace.x1)
        }
    }

    // MARK: Tabs

    /// The tabs in the page; a copy pins under the bar once this one reaches it (`tabsPinned`).
    func profileTabs(_ f: Franchise) -> some View {
        ShowTabsRow(selected: $showTab)
            .opacity(tabsPinned ? 0 : 1)
            // Reaches ABOVE the row by the pin height: scrolled to the top, it leaves the row
            // exactly where the pinned copy is, so a switch keeps the tabs where they were.
            .background(alignment: .bottom) {
                Color.clear
                    .frame(height: ShowTabsRow.height + 1 + Self.pinTop)
                    .id("anchor-tabs")
            }
            .onGeometryChange(for: Bool.self) { $0.frame(in: .global).minY <= Self.pinTop } action: { pinned in
                if pinned != tabsPinned { tabsPinned = pinned }
            }
            .padding(.top, ThemeSpace.x4)
    }

    @ViewBuilder
    func profileTabContent(_ f: Franchise) -> some View {
        switch showTab {
        case .posts: postsTab(f)
        case .episodes: episodesTab(f)
        case .media: mediaTab(f)
        case .about: aboutTab(f)
        }
    }

    // MARK: Posts

    private func postsTab(_ f: Franchise) -> some View {
        let posts = showPosts(f)
        let pin = pinnedContent(f)
        return VStack(spacing: 0) {
            if let pin {
                pinnedPost(f, pin)
                FeedHairline()
            }
            if posts.isEmpty && pin == nil {
                emptyTab(Copy.ShowPage.noPosts, message: Copy.ShowPage.noPostsMessage(f.displayTitle))
            }
            ForEach(posts) { m in
                FeedPostRow(model: m,
                            onOpen: { push(.post(id: m.id)) },
                            onOpenShow: {},
                            onViewMedia: { push(.post(id: m.id)) },
                            onComment: { push(.post(id: m.id)) })
            }
        }
        // A trailer in a post plays in place, on this page's one player.
        .environment(\.feedAutoplay, trailers)
    }

    /// The show's own posts — its news, trailers and seasons — from the feed: Following carries a
    /// library show's, For you a trending one's.
    private func showPosts(_ f: Franchise) -> [FeedPostModel] {
        var seen = Set<String>()
        var out: [FeedPostModel] = []
        for tab in [FeedTab.following, .forYou] {
            for row in appModel.feedRows(tab) {
                if case .post(let m) = row, m.post.franchiseId == f.id, seen.insert(m.id).inserted { out.append(m) }
            }
        }
        return out
    }

    /// What the pinned post says, from the page's one state (`nextUpState`).
    struct PinnedContent {
        enum Action { case mark, start, rewatch }
        let detail: String
        let sentence: String
        let part: FranchisePart?
        let episode: Int?
        let action: Action?
    }

    private func pinnedContent(_ f: Franchise) -> PinnedContent? {
        guard inLibrary, let state = nextUpState(f) else { return nil }
        switch state.kind {
        case .actionable, .backlog:
            guard let part = state.part, let episode = state.episode else { return nil }
            let sentence = state.behind > 1
                ? Copy.ShowPage.isNextBehind(episode, behind: state.behind)
                : (state.eyebrow == Copy.Label.newEpisode ? Copy.ShowPage.isOut(episode) : Copy.ShowPage.isNext(episode))
            return PinnedContent(detail: state.eyebrow, sentence: sentence, part: part, episode: episode, action: .mark)
        case .caughtUp:
            let sentence = newEpisodeLine(f).map { "\($0)." } ?? Copy.ShowPage.caughtUp
            return PinnedContent(detail: state.eyebrow, sentence: sentence, part: state.part, episode: nil, action: nil)
        case .waiting:
            // A Planned show you can start: where it starts. An announcement is the timeline's news.
            guard f.effectiveStatus == .planned, let part = state.part, !part.isUpcoming else { return nil }
            return PinnedContent(detail: state.eyebrow, sentence: Copy.ShowPage.startWith(state.line1),
                                 part: part, episode: part.progress + 1, action: .start)
        case .seriesComplete:
            let offersRewatch = RewatchStore.shared.activeSession(for: f.id) == nil
            // The story's episodes (two unwatched recap OVAs are not the story), and how many times.
            let episodes = f.mainStoryEpisodicParts.reduce(0) { $0 + max($1.totalEpisodes, $1.progress) }
            let times = RewatchStore.shared.summary(for: f.id).completedCount
            let sentence = times > 1
                ? "\(Copy.Progress.watchedTimes(times)) \u{00B7} \(Copy.episodes(episodes))."
                : Copy.ShowPage.finishedAll(episodes)
            return PinnedContent(detail: state.eyebrow, sentence: sentence,
                                 part: nil, episode: nil, action: offersRewatch ? .rewatch : nil)
        case .seasonComplete:
            let sentence = [state.line1, state.line3].compactMap { $0 }.joined(separator: ". ")
            return PinnedContent(detail: state.eyebrow, sentence: "\(sentence).", part: state.part, episode: nil, action: nil)
        }
    }

    private func pinnedPost(_ f: Franchise, _ pin: PinnedContent) -> some View {
        // No grey detail after the name: the sentence already says the state, and a repeat of it
        // squeezed the name to "That Time I Got Reincarnated as a S…" (25 Sep).
        ShowPinnedPost(franchise: f, detail: "", sentence: pin.sentence) {
            if pin.episode != nil || pin.action == .rewatch {
                pinnedMedia(f, part: pin.part, episode: pin.episode)
                    .padding(.top, FeedPostLayout.mediaTop)
            }
        } action: {
            pinnedAction(f, pin)
                .padding(.top, ThemeSpace.x2)
        } menu: {
            pinnedMenu(f, part: pin.part)
        }
        // A season finished by this mark draws the hairline sweep, once per commit.
        .seasonCompleteSweep(token: sweepToken, reduceMotion: reduceMotion)
    }

    /// The episode's own still, else the season's landscape, else the show's — a post's picture,
    /// with the feed's corner and pixel of rule.
    private func pinnedMedia(_ f: Franchise, part: FranchisePart?, episode: Int?) -> some View {
        let still = part.flatMap { p in episode.flatMap { e in p.episodes.first(where: { $0.number == e })?.still } }
        let wide = f.wideArt
        let shape = RoundedRectangle(cornerRadius: FeedMetrics.mediaRadius, style: .continuous)
        return ZStack {
            (pageTint ?? PaletteCache.fallback)
            if let still {
                RemoteImageView(url: still, contentMode: .fill, maxPixel: 1200, placeholderHidden: true)
            } else {
                LandscapeArt(url: wide.url, portraitSource: wide.portraitSource,
                             maxPixel: wide.ultraWide ? 1900 : 1200, ultraWide: wide.ultraWide)
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipShape(shape)
        .overlay(shape.strokeBorder(ThemeColor.feedSeparator, lineWidth: FeedMetrics.hairline))
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func pinnedAction(_ f: Franchise, _ pin: PinnedContent) -> some View {
        switch pin.action {
        case .mark:
            if let part = pin.part, let episode = pin.episode {
                let committed = committedEpisode != nil && pinned != nil
                ScheduleMarkPill(watched: committed, label: Copy.Action.markEpisodeWatched(episode)) {
                    mark(f, part: part)
                }
            }
        case .start:
            Button { appModel.setStatus(franchiseId: f.id, status: .watching) } label: {
                ShowFollowPillLabel(text: Copy.Today.startOrContinue(f), filled: true)
            }
            .buttonStyle(FeedIconPressStyle())
        case .rewatch:
            Button { showStartRewatch = true } label: {
                ShowFollowPillLabel(text: Copy.Action.startRewatch, filled: false)
            }
            .buttonStyle(FeedIconPressStyle())
        case nil:
            EmptyView()
        }
    }

    /// X's `···` on the post: the batch verbs a pill has no room for.
    @ViewBuilder
    private func pinnedMenu(_ f: Franchise, part: FranchisePart?) -> some View {
        if inLibrary && (seriesBehind(f) > 0 || (part?.progress ?? 0) > 0) {
            Menu {
                progressChoices(f, part: part)
            } label: {
                AppGlyph(systemName: "ellipsis")
                    .font(ThemeType.feedSubhead.font.weight(.medium))
                    .foregroundStyle(ThemeColor.feedSecondary)
                    .frame(width: FeedMetrics.actionHitHeight, height: FeedMetrics.actionHitHeight)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .padding(.vertical, -ThemeSpace.x3)
            .accessibilityLabel(Copy.Feed.more)
        }
    }

    // MARK: Episodes

    private func episodesTab(_ f: Franchise) -> some View {
        VStack(alignment: .leading, spacing: Self.shelfRhythm) {
            if let part = focusSeason(f) {
                VStack(alignment: .leading, spacing: ThemeMetrics.labelGap) {
                    episodesHeader(f, part: part)
                        .id("anchor-episodes-header")
                    // The page's palette: the discs and tiles sit in the show's colour.
                    EpisodeList(franchise: f, part: part, tint: DetailTint.quiet(pageTint),
                                focusEpisode: focus?.mediaId == part.mediaId ? focus?.episode : nil)
                        .id(part.mediaId)
                        .disabled(appModel.pendingAdds.contains(f.id))
                }
                .id("anchor-episodes")
            }
            extrasShelf(f)
        }
        .padding(.horizontal, ThemeMetrics.gutter)
        .padding(.top, ThemeSpace.x3)
    }

    // MARK: Media

    /// X's Media: every trailer and clip at the column's width, each playing where it is.
    @ViewBuilder
    private func mediaTab(_ f: Franchise) -> some View {
        let videos = f.allVideos
        if videos.isEmpty {
            emptyTab(Copy.ShowPage.noMedia, message: nil)
        } else {
            LazyVStack(alignment: .leading, spacing: ThemeSpace.x6) {
                ForEach(videos) { v in
                    TrailerCard(video: v, showTitle: f.title,
                                width: ThemeMetrics.windowWidth - 2 * ThemeMetrics.gutter, featured: true,
                                director: trailers)
                        .matchedTransitionSource(id: v.id, in: trailerZoom)
                }
            }
            .padding(.horizontal, ThemeMetrics.gutter)
            .padding(.top, ThemeSpace.x4)
            .id("anchor-trailers")
        }
    }

    // MARK: About

    private func aboutTab(_ f: Franchise) -> some View {
        VStack(alignment: .leading, spacing: Self.shelfRhythm) {
            themesLine(f)
            historyRow(f)
            becauseYouFinished(f)
            whereToWatch(f)
            peopleShelf(f)
            relatedShelf(f)
        }
        .padding(.horizontal, ThemeMetrics.gutter)
        .padding(.top, ThemeSpace.x3)
    }

    /// X's empty timeline: a bold line and one grey sentence.
    private func emptyTab(_ title: String, message: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .type(ThemeType.feedModuleTitle)
                .foregroundStyle(ThemeColor.feedText)
            if let message {
                Text(message)
                    .type(ThemeType.feedMeta)
                    .foregroundStyle(ThemeColor.feedSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, ThemeMetrics.gutter)
        .padding(.vertical, ThemeSpace.x6)
    }
}

// MARK: - Capture driving (DEBUG)

#if DEBUG
/// `-detailScrollY <points>` (DEBUG): parks the page at an exact offset, so a capture strip can
/// photograph the whole page top to bottom on a simulator that cannot be touched.
private struct DebugScrollY: ViewModifier {
    @State private var position = ScrollPosition(edge: .top)
    private let target: CGFloat? = UserDefaults.standard.object(forKey: "detailScrollY") == nil
        ? nil : CGFloat(UserDefaults.standard.double(forKey: "detailScrollY"))

    func body(content: Content) -> some View {
        if let target {
            content
                .scrollPosition($position)
                .task {
                    try? await Task.sleep(for: .seconds(3))
                    position.scrollTo(y: target)
                }
        } else {
            content
        }
    }
}
#endif

private extension View {
    /// `-detailAnchor trailers|people|related|watch`, `-detailTrailer inline|full`,
    /// `-detailOpenRelated N` (DEBUG, like `-openTab`): scroll a show page to a catalogue shelf,
    /// play its first trailer in its card (then full screen), or open the Nth related title — for
    /// captures on a simulator that cannot be touched.
    func debugDetailDrive(franchise f: Franchise, proxy: ScrollViewProxy,
                          trailers: FeedAutoplay,
                          openRelated: @escaping (RelatedTitle) -> Void,
                          selectTab: @escaping (ShowTab) -> Void) -> some View {
        #if DEBUG
        return task {
            let defaults = UserDefaults.standard
            let anchor = defaults.string(forKey: "detailAnchor")
            let trailer = defaults.string(forKey: "detailTrailer")
            let wantsRelated = defaults.object(forKey: "detailOpenRelated") != nil
            guard anchor != nil || trailer != nil || wantsRelated else { return }
            try? await Task.sleep(for: .seconds(2.5))
            if let anchor {
                // Each anchor lives in its tab: open the tab, then land on it.
                switch anchor {
                case "episodes": selectTab(.episodes)
                case "trailers": selectTab(.media)
                default: selectTab(.about)
                }
                try? await Task.sleep(for: .milliseconds(300))
                let target = anchor == "episodes" ? "anchor-tabs" : "anchor-\(anchor)"
                withAnimation { proxy.scrollTo(target, anchor: .top) }
            }
            if let trailer, let first = f.allVideos.first {
                // The card must be on screen to keep playing: its tab first, then the tap.
                if anchor == nil {
                    selectTab(.media)
                    try? await Task.sleep(for: .milliseconds(300))
                    withAnimation { proxy.scrollTo("anchor-tabs", anchor: .top) }
                }
                try? await Task.sleep(for: .seconds(1))
                trailers.engage(first.id, video: first)
                if trailer == "full" {
                    try? await Task.sleep(for: .seconds(2))
                    if let playback = trailers.current { trailers.openFullScreen(playback) }
                }
            }
            let index = defaults.integer(forKey: "detailOpenRelated")
            if wantsRelated, f.related.indices.contains(index) { openRelated(f.related[index]) }
        }
        #else
        return self
        #endif
    }
}

// MARK: - The Detail veils

/// The two top veils over the show page — the only view here that reads the scroll offset.
private struct DetailVeils: View {
    static let edgeRamp: CGFloat = 12
    let scroll: ScrollOffset
    let hardOn: Bool
    /// The floating toolbar's band, safe area included.
    let band: CGFloat
    /// The show's colour as bar ink (`DetailTint.chrome`), so the hardened bar is the show's
    /// glass rather than canvas.
    var color: Color? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .top) {
            // While ARTWORK is behind the toolbar: a soft veil fading in with the scroll. Mounted
            // only in that phase — a material at opacity 0 is still a backdrop blur.
            if !hardOn, scroll.y > 12 {
                ScrollEdgeChrome(height: band + 100)
                    .opacity(scroll.veilOpacity)
                    .transition(.opacity)
            }
            // The bar, once content rather than artwork is behind the toolbar.
            if hardOn {
                // A SHORT edge (12 pt, not the roots' 28): text is either under the glass or clear
                // of it — at 28 a half-lit line ghosted along the bar's foot in every scrolled
                // frame ("Isekai · Time Loop…", "Read more", a row's date; critique, 24 Sep).
                ScrollEdgeChrome(height: band + Self.edgeRamp, holdHeight: band,
                                 color: color)
                    .transition(.opacity)
            }
        }
        .animation(ThemeMotion.pick(ThemeMotion.uiGentle, reduceMotion: reduceMotion), value: hardOn)
        .allowsHitTesting(false)
    }
}

// MARK: - Surface B · Season episodes

struct SeasonEpisodesView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let franchiseId: String
    /// The season the push opened on. The header's picker can move to a sibling season in
    /// place (`selectedMediaId`) — Apple TV's season picker — instead of pop, tap, push.
    let mediaId: Int
    var focusEpisode: Int? = nil

    @State private var selectedMediaId: Int?
    @State private var fetched: Franchise?
    /// The whole-list spoiler switch (season overflow). Per-view, deliberately: it is a viewing
    /// preference for the list in front of you, not an account setting.
    @State private var revealAll = false
    @State private var prompt: FranchiseDetailView.WritePrompt?
    @State private var tint: Color?
    /// The catalogue read failed for a show that is not in the library — there is nothing local
    /// to draw, so the screen says so with the show page's own state and its "Try again", instead
    /// of holding its skeleton forever (review, 23 Sep).
    @State private var loadFailed = false

    private var now: Int64 { appModel.now }
    /// The show's colour, made fit to sit under type (see `DetailTint`).
    private var quietTint: Color? { DetailTint.quiet(tint) }
    private var franchise: Franchise? { appModel.franchise(id: franchiseId) ?? fetched }
    private var activeMediaId: Int { selectedMediaId ?? mediaId }
    private var part: FranchisePart? {
        guard let f = franchise else { return nil }
        let live = f.parts.first { $0.mediaId == activeMediaId }
        let eps = fetched?.parts.first { $0.mediaId == activeMediaId }?.episodes ?? []
        if let live, live.episodes.isEmpty, !eps.isEmpty { return live.withEpisodes(eps) }
        return live
    }

    var body: some View {
        ZStack {
            ThemeColor.canvas.ignoresSafeArea()
            // The season carries the franchise's colour too — quietly, because this screen is a
            // list and the wash is atmosphere, not identity.
            if let f = franchise {
                // The one wash spec — this list carried a private 0.7 intensity, one of the seven
                // configurations the cohesion pass collapsed.
                ArtBackdrop(url: f.landscapeArt ?? f.portraitArt, tint: tint,
                            height: ThemeMetrics.rootWashHeight,
                            intensity: ThemeMetrics.rootWashIntensity)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .ignoresSafeArea(edges: .top)
            }
            if let f = franchise, let part {
                ScrollViewReader { proxy in
                    ScrollView {
                        // A long run (Boruto's 293 episodes) opens on a window around the focused
                        // episode and grows in place (`EpisodeList`); `.id("ep-n")` and the
                        // `proxy.scrollTo` focus jump both still work.
                        seasonHeader(f, part: part)
                            .padding(.horizontal, ThemeMetrics.gutter)
                            .padding(.top, ThemeSpace.x3)
                            .padding(.bottom, ThemeSpace.x3)
                        // The one episode list (`EpisodeList`, shared with the show page), in
                        // full. Re-keyed on the season, so a picker change lands on a fresh list
                        // rather than rows morphing their numbers in place.
                        EpisodeList(franchise: f, part: part, revealAll: revealAll, tint: quietTint,
                                    focusEpisode: focusEpisode)
                            .padding(.horizontal, ThemeMetrics.gutter)
                            .id(activeMediaId)
                    }
                    // A MARGIN, not padding. A complete "Episode 11" row — tile, title and check —
                    // rendered in the strip between the floating pill and the home indicator, and
                    // "Episode 10 · Mhysa" was sliced by the pill's edge with its air date entirely
                    // covered, because padding inside the stack is not an inset for the scroll view.
                    // `pushedScreenChrome()` supplies the base clearance; this widens it while a
                    // sync failure is pending.
                    .contentMargins(.bottom, DetailMetrics.bottomClearance, for: .scrollContent)
                    .scrollIndicators(.hidden)
                    .onAppear {
                        if let focusEpisode {
                            // Twice (interactive review: the list opened at Episode 1 of 24 — the
                            // first pass can run before the lazy rows above the target exist).
                            for delay in [0.4, 1.2] {
                                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                                    withAnimation(ThemeMotion.pick(ThemeMotion.uiSettle, reduceMotion: reduceMotion)) { proxy.scrollTo("ep-\(focusEpisode)", anchor: .center) }
                                }
                            }
                        }
                    }
                }
            } else if loadFailed {
                EmptyState(SyncCenter.shared.isOnline ? .serverNoCache : .offlineNoData, prominence: .major) {
                    Task { await load() }
                }
                .padding(.horizontal, ThemeMetrics.gutter)
            } else {
                episodesSkeleton
            }
        }
        // A REAL navigation bar. This screen used to hide it and hand-build its own — a circular
        // back button, a centred 22-pt title, a circular ellipsis, no material and no scroll edge
        // effect, so the first row was chopped in half under a black band and left a decapitated
        // poster ghost at 50 % alpha. It then repeated itself, printing "Season 3" a second time
        // 150 pt below the first in larger type.
        //
        // The season is the subject, so the season is the title; its progress is the subtitle,
        // which is exactly what `navigationSubtitle` is for; the show's name is one tap back and
        // already at the top of the screen you came from.
        // The bar names the SHOW; the season is the header below, where its poster, its picker
        // and its progress live. The bar used to carry the season and a "11 of 24 watched"
        // subtitle over a list with no art at all — a settings screen for a TV show.
        // The short name, as Detail's docked bar and every row: the full title truncated with an
        // ellipsis in a 200-pt bar is the one place it was still spelled out.
        .navigationTitle(franchise?.displayTitle ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarRole(.editor)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if let f = franchise, let part, appModel.isInLibrary(f.id) {
                    seasonOverflow(f, part: part)
                }
            }
        }
        .task { if fetched == nil { await load() } }
        .task(id: franchise?.portraitArt) { tint = await PaletteCache.shared.resolve(url: franchise?.portraitArt, maxPixel: 420) }
        // An alert with Cancel, as every write confirmation (review i4).
        .alert(prompt?.title ?? "", isPresented: Binding(get: { prompt != nil }, set: { if !$0 { prompt = nil } }),
               presenting: prompt) { p in
            Button(p.confirm, role: p.destructive ? .destructive : nil) { p.perform() }
            Button(Copy.Confirm.cancel, role: .cancel) {}
        } message: { p in
            Text(p.message)
        }
    }

    /// The season's own header, in the app's one landscape grammar: its art as a wide card with
    /// the progress bar inset ON it (`ProgressBanner` — Library's Up Next card), then its name as
    /// a PICKER over the franchise's other seasons (Apple TV's "Season 4 ⌃⌄") with the count on
    /// the baseline — Detail's episodes header, verbatim. Art and a numeral, not a sentence.
    ///
    /// It was a portrait poster beside a title and a thin line — a settings row for a TV show
    /// ("absolutely trash", user, 3 Sep) — and the one place in the app that put a 2:3 cover
    /// next to a column of 16:9 stills.
    private func seasonHeader(_ f: Franchise, part: FranchisePart) -> some View {
        let total = max(part.totalEpisodes, part.airedEpisodes)
        let watched = min(part.progress, max(total, part.progress))
        // The seasons, as the show page's pill lists them; an extra opened from the shelf keeps
        // the whole episodic run as its siblings, so a viewer inside an OVA can still hop.
        let seasons = f.seasonPartsInOrder
        let siblings = seasons.contains { $0.mediaId == part.mediaId } ? seasons : f.episodicPartsInOrder
        // The season's picture where it has a real one (`wideArt(within:)`: a TRUE 16:9 at either
        // level before any banner). "The SEASON's own art" was the rule from 3 Sep, but a season's
        // only landscape is its AniList banner, and its middle third gutter to gutter was a pair of
        // eyes (Slime S4 on production, 4 Sep) while the show had a backdrop one level up.
        let wide = part.wideArt(within: f)
        return VStack(alignment: .leading, spacing: ThemeSpace.x3) {
            ProgressBanner(url: wide.url,
                           portraitSource: wide.portraitSource,
                           progress: total > 0 ? Double(watched) / Double(total) : nil,
                           ultraWide: wide.ultraWide)
                .accessibilityHidden(true)
            HStack(alignment: .center, spacing: ThemeSpace.x2) {
                if siblings.count > 1 {
                    SeasonPill(current: part, seasons: siblings) { selectedMediaId = $0 }
                } else {
                    seasonTitle(part).accessibilityAddTraits(.isHeader)
                }
                Spacer(minLength: ThemeSpace.x2)
                // The banner above carries the bar; only a season whose length the catalogue never
                // stated says its count in words.
                if total == 0, part.progress > 0 {
                    Text(Copy.episodes(part.progress) + " watched")
                        .type(ThemeType.metadata)
                        .foregroundStyle(ThemeColor.textTertiary)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// The same title the show page heads its episode list with.
    private func seasonTitle(_ part: FranchisePart) -> some View {
        Text(part.canonicalLabel.isEmpty ? part.title : part.canonicalLabel)
            .type(ThemeType.sectionTitle)
            .foregroundStyle(ThemeColor.textPrimary)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
    }

    /// Season-wide marks, plus the spoiler switch for the whole list. Same glyph as Detail's
    /// overflow — one overflow grammar across the two screens of a franchise.
    @ViewBuilder
    private func seasonOverflow(_ f: Franchise, part: FranchisePart) -> some View {
        Menu {
            let target = part.markTarget(now: now)
            if appModel.isInLibrary(f.id), target > part.progress {
                Button(Copy.Action.markAll(target - part.progress)) { promptMark(f, part: part, through: target) }
            }
            if appModel.isInLibrary(f.id), part.progress > 0 {
                Button(Copy.Action.markAllUnwatched(part.progress), role: .destructive) { promptUnmark(f, part: part, to: 0) }
            }
            Divider()
            // One switch for the whole list. The app has a spoiler model and used it on the Next
            // up card, then showed every still and every title in the one place where the next ten
            // episodes are all on screen at once. Per-row reveal stays for the one episode you
            // want; this is for the viewer who does not want the question asked.
            Toggle(isOn: $revealAll) {
                AppGlyphLabel(DetailCopy.revealEpisodeTitlesAndStills, systemName: revealAll ? "eye" : "eye.slash")
            }
        } label: {
            AppGlyph(systemName: "ellipsis")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(ThemeColor.textPrimary)
                .frame(width: 44, height: 44)
        }
        .accessibilityLabel("Episode actions")
    }

    private func load() async {
        loadFailed = false
        do {
            fetched = try await appModel.api.franchise(id: franchiseId)
        } catch {
            // A cancelled read (the screen went away) is not a failure; the library copy, when
            // there is one, is already on screen.
            guard !error.isCancellation else { return }
            loadFailed = appModel.franchise(id: franchiseId) == nil
        }
    }

    private var episodesSkeleton: some View {
        // The shape that arrives: the season's wide art card, its title line, then the rows.
        VStack(alignment: .leading, spacing: 0) {
            SkeletonBlock(height: nil, radius: ThemeRadius.card)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .padding(.top, ThemeSpace.x3)
            SkeletonLine(width: 120, height: 20)
                .padding(.top, ThemeSpace.x3)
                .padding(.bottom, ThemeSpace.x3)
            ForEach(0..<8, id: \.self) { _ in
                SkeletonRow(poster: EpisodeArtwork.slot, lines: [190, 120],
                            posterRadius: ThemeRadius.episodeStill, spacing: ThemeMetrics.artGap,
                            height: ThemeMetrics.rowEpisode)
            }
        }
        .padding(.horizontal, ThemeMetrics.gutter)
        .padding(.top, ThemeSpace.x2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func promptMark(_ f: Franchise, part: FranchisePart, through: Int) {
        let count = through - part.progress
        guard count > 0 else { return }
        prompt = .init(title: Copy.Confirm.batchMarkTitle(count), message: Copy.Confirm.batchMarkMessage(title: f.displayTitle, season: part.canonicalLabel, from: part.progress, to: through),
                       confirm: Copy.Confirm.batchMarkConfirm(count)) {
            let prev = part.progress
            appModel.setProgress(franchiseId: f.id, mediaId: part.mediaId, episodes: through)
            appModel.presentUndo(UndoState(mediaId: part.mediaId, franchiseId: f.id, prevProgress: prev, title: f.title, episode: through, count: count))
        }
    }

    private func promptUnmark(_ f: Franchise, part: FranchisePart, to: Int) {
        let count = part.progress - to
        guard count > 0 else { return }
        let message = to == 0 ? Copy.Confirm.resetSeason(label: part.canonicalLabel, total: count)
                              : Copy.Confirm.batchMarkMessage(title: f.displayTitle, season: part.canonicalLabel, from: part.progress, to: to)
        prompt = .init(title: to == 0 ? Copy.Confirm.resetSeasonTitle(count) : "Mark \(Copy.episodes(count)) as unwatched?",
                       message: message, confirm: to == 0 ? Copy.Confirm.resetSeasonConfirm(count) : "Mark \(Copy.episodes(count)) as unwatched",
                       destructive: true) {
            let prev = part.progress
            appModel.setProgress(franchiseId: f.id, mediaId: part.mediaId, episodes: to)
            appModel.presentUndo(UndoState(mediaId: part.mediaId, franchiseId: f.id, prevProgress: prev, title: f.title, episode: to, count: count,
                                           customMessage: to == 0 ? "\(part.canonicalLabel) marked as unwatched" : "\(Copy.episodes(count)) marked as unwatched"))
        }
    }
}

private extension String {
    func lowercasedFirst() -> String {
        guard let first else { return self }
        return first.lowercased() + dropFirst()
    }
}

extension String {
    /// A source's proper noun, set the way every other proper noun in the app is set — WITHOUT
    /// flattening an acronym.
    ///
    /// The catalogue hands us "WIT STUDIO", "8bit" and "HBO" in three different conventions and
    /// the hero printed all three verbatim in one type style. `localizedCapitalized` alone is
    /// worse than the disease: it turns HBO into "Hbo". So each word is title-cased *unless* it is
    /// a short all-caps token, which is an acronym and already correct.
    var normalisedProperName: String {
        split(separator: " ", omittingEmptySubsequences: true).map { word -> String in
            let w = String(word)
            let isAcronym = w.count <= 4 && w == w.uppercased() && w.contains { $0.isLetter }
            return isAcronym ? w : w.localizedCapitalized
        }.joined(separator: " ")
    }
}

/// The show page's one confirmation, hung from the control that raised it (`PromptAnchor`).
/// A write's confirmation, as an ALERT (review i3): the anchored confirmation dialog renders on
/// iOS 26 as a glass popover hanging from the control — over the amber "Mark as watched" capsule
/// it read as an amber button with white text at 3.2:1, the capsule's amber spilled out at its
/// corners, and it drew no Cancel. Schedule already confirms the same kind of write as an alert
/// with Cancel; one grammar for a write's "are you sure", centred, whatever raised it.
private struct PromptDialog: ViewModifier {
    @Binding var prompt: FranchiseDetailView.WritePrompt?
    let shown: Bool

    func body(content: Content) -> some View {
        content.alert(prompt?.title ?? "",
                      isPresented: Binding(get: { shown && prompt != nil },
                                           set: { if !$0 { prompt = nil } }),
                      presenting: prompt) { p in
            Button(p.confirm, role: p.destructive ? .destructive : nil) { p.perform() }
            if let alternative = p.alternative {
                Button(alternative.label) { alternative.perform() }
            }
            if let third = p.third {
                Button(third.label) { third.perform() }
            }
            ForEach(Array(p.choices.enumerated()), id: \.offset) { _, choice in
                Button(choice.label) { choice.perform() }
            }
            Button(Copy.Confirm.cancel, role: .cancel) {}
        } message: { p in
            Text(p.message)
        }
    }
}
