import SwiftUI

// Library (spec board 05): a calm root with ONE art moment and everything else quiet, and
// "All titles" — the instrument (search, sort, filter, view) behind one row. Urgency lives on
// Today, never here.
//
// Fix round 2. What the adversarial panel drew blood on, and what this is:
//
//  * **The A–Z index rail failed on every axis it was measured** — 11-pt hard-coded type that never
//    scaled, `textDisabled` (3.6:1) on text, 15-pt bands in a 225-pt column floating in the middle
//    of the screen, letters sitting ON the third poster column, `accessibilityHidden(true)` with no
//    substitute, and a 300 ms haptic floor that made an A→W drag produce two taps. See `indexRail`.
//  * **The WATCHING shelf answered "what do I owe" with a release year.** Three consecutive rows
//    read "Anime · 2013" / "TV · 2024" / "Anime · 2019" because `standing()` refused to speak
//    without a current part. See `LibraryRowFacts.standing`.
//  * **One show, three statuses.** The poster wall and the list derived their caption from two
//    different functions and disagreed, and nothing anywhere said a rewatch was in progress.
//    `LibraryRowFacts.catalogue(compact:)` is now the single source for both. See `gridCaption`.
//  * **Accent was the caption colour.** Every visible caption on the root shelf was amber, none of
//    them an action. `ReturnFact.soon` decides it once, for the shelf and the catalogue alike.
//  * **"All titles" was a filled rounded rectangle under a large title** — the same silhouette as
//    the search field it opens. It is a hairline row on the canvas now. See `allTitlesRow`.
//  * **The root hid its navigation bar** and drew "Library" as scrolling content, so the app had
//    three header grammars across three tab roots. It is a real inline title now — Schedule's
//    model, on every root.
//  * **"Unwatched only" could contradict "Status"** and did not say unwatched *what*. It is its
//    own axis now ("Has unwatched episodes"), composed with Status, and its predicate is the set
//    Today counts. Sort gained "Recently added" and a direction. See `filtered()`.
//
// Round 3 (audit): the root and All titles each computed their sections several times per render
// — `sections` from the wash and every loop, `results` from eight sites — so both are resolved
// ONCE at the top of `body` and passed down. Every string moved to `Copy.Library`.
// The status TABS (`LibraryRootTab` and friends) are gone (30 Aug): a permanent status-filter
// instrument mounted on the calm root — the axis All titles already owns — and the app's only
// underlined text-tab control. Every bucket is a quiet shelf again; the lists live one "See all"
// away, in the instrument, pre-filtered.

struct LibraryView: View {
    @Environment(AppModel.self) private var appModel
    let onOpenDetail: (_ franchiseId: String, _ zoomID: String) -> Void
    /// Where shows are added. Today and Schedule already take this; the Library's empty state
    /// printed the same `Add a show` label with nothing behind it.
    var onAddShow: () -> Void = {}

    @State private var all: AllTitlesRoute?
    #if DEBUG
    @State private var debugOpenedAll = false
    #endif
    /// A route another screen asked for ("View all N updates", a Profile stat); consumed once.
    @Binding var requestedAll: AllTitlesRoute?
    /// Re-selecting the tab pops All titles back to this root (see `MainTabView.selection`).
    var popSignal: Int = 0
    /// The bar's scroll-away state, owned by `MainTabView` (the tab bar rides it).
    var chrome = RootChromeState()
    /// True while the user's finger owns a pull. The system's own indicator is then the only
    /// spinner on screen — see `L-17` above.
    @State private var pullDriving = false
    /// The scroll view's own height, so a state that owns the whole surface can be centred in it.
    @State private var contentHeight: CGFloat = 0

    /// The door to All titles, in the bar: a word that opens a list carries its chevron (review
    /// i4: a grey numeral read as a fact, and it is the only door to the unfiltered list).
    private var allTitlesDoor: some View {
        Button {
            all = AllTitlesRoute()
        } label: {
            HStack(spacing: 4) {
                Text(Copy.titles(appModel.library.count))
                AppGlyph(systemName: "chevron.forward")
                    .font(.system(size: 12, weight: .semibold))
            }
        }
        .buttonStyle(.plain)
        .type(ThemeType.listAction)
        .foregroundStyle(ThemeColor.interactive)
        .frame(minWidth: 44, minHeight: 44)
        .accessibilityLabel(Copy.Library.allTitlesAccessibility(appModel.library.count))
        .accessibilityHint(Copy.Library.allTitlesHint)
    }

    /// Where a `See all` lands. Two independent axes, because the root's buckets are not all
    /// statuses: `Returning` and `Announced` are facts about a show's future, not list states.
    struct AllTitlesRoute: Hashable, Identifiable {
        var status: WatchStatus?
        var returning: ReturnScope?
        var unwatchedOnly: Bool = false
        var sort: LibraryAllView.Sort? = nil
        var id: String { "\(status?.rawValue ?? "-")/\(returning?.rawValue ?? "-")/\(unwatchedOnly)/\(sort?.rawValue ?? "-")" }
    }

    var body: some View {
        // One pass over the shelves per render.
        let sections = rootSections()
        // `watchingShelf` also contains titles that are caught up and merely waiting. The hero is
        // an instruction to continue, so only a title with a real resume part may enter it.
        let heroItems = appModel.watchingShelf.filter { $0.resumePart != nil }
        let ambientArtwork = washArtwork(sections, heroItems: heroItems)
        return ZStack(alignment: .top) {
            // Flat, as Today is: no wash behind the title (25 Sep, `flushTopBar`).
            ThemeColor.canvas.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // The refresh indicator and the stale strip, composed by the shared modifier
                    // that arbitrates them against `.refreshable`'s own spinner. The screen TITLE
                    // is not part of this stack: it is a real `navigationTitle`, so the tab roots
                    // stop having three header grammars (see `body`'s toolbar).
                    Color.clear.frame(height: 0)
                        .freshness(.catalogue, appModel: appModel, pullDriving: pullDriving)
                        .padding(.horizontal, ThemeMetrics.gutter)

                    if appModel.sectionFailed {
                        InlineNotice(Copy.Notice.library) { Task { await appModel.reload() } }
                            .padding(.horizontal, ThemeMetrics.gutter).padding(.top, ThemeSpace.x3)
                    }

                    SkeletonGate(isLoading: appModel.loading && appModel.library.isEmpty) {
                        skeleton
                    } content: {
                        if appModel.library.isEmpty {
                            // Centred in the content area, not pinned to the top of it: the error
                            // card sat above ~1,000 pt of black while the identical card on Today
                            // was centred.
                            EmptyState(appModel.emptyStateCopy, prominence: .major,
                                       artwork: appModel.surfacePhase == .emptyAccount ? .episodeFrames : nil,
                                       primary: emptyStateAction)
                                .padding(.horizontal, ThemeMetrics.gutter)
                                .centredState(contentH: contentHeight)
                        } else {
                            root(sections, heroItems: heroItems)
                        }
                    }
                }
                // The bar's scroll probe (`RootChromeState`): the content's distance from its
                // resting top — geometry, because `onScrollGeometryChange` never fires on the
                // iOS 27 simulator.
                .rootChromeProbe(chrome, rest: ThemeMetrics.topSafeInset + FeedMetrics.headerRow)
            }
            // The bar is the page's own (4 Oct): the title and the door to All titles on the
            // canvas, leaving with the scroll and taking the tab bar with it — the system bar it
            // replaced could only stay.
            .safeAreaInset(edge: .top, spacing: 0) {
                RootHeader(title: Copy.Library.title, chrome: chrome, leading: { EmptyView() }, trailing: { allTitlesDoor })
            }
            .scrollIndicators(.hidden)
            // A scroll-content MARGIN, not padding inside the stack: padding under a stack that is
            // shorter than the viewport changes no layout at all, which is exactly the case a short
            // library is in when it comes to rest inside the bottom ramp.
            .tabBarContentMargin()
            .onScrollPhaseChange { _, phase in
                pullDriving = (phase == .tracking || phase == .interacting)
                chrome.phase(phase)
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            .previouslyRefreshable { await appModel.reload() }
        }
        // The system bar is hidden on the root (and says so: a pop from a page that shows one
        // otherwise leaves its height in the top inset); the title stays for VoiceOver and for the
        // back button of what this root pushes.
        .navigationTitle(Copy.Library.title)
        .toolbar(.hidden, for: .navigationBar)
        .chromeScrollEdgeHidden(.top)
        // Leaving the root (All titles) brings the bars back: a pushed page keeps them.
        .onChange(of: all) { _, route in
            if route != nil { chrome.reveal() }
        }
        .navigationDestination(item: $all) { route in
            // The push carries the root's own wash art, so All titles opens in the same light.
            LibraryAllView(initialStatus: route.status, initialReturning: route.returning, initialSort: route.sort ?? .title,
                           initialUnwatchedOnly: route.unwatchedOnly,
                           washArt: washArtwork(rootSections(),
                                                heroItems: appModel.watchingShelf.filter { $0.resumePart != nil }),
                           onOpenDetail: onOpenDetail, onAddShow: onAddShow)
                .perfScreen("AllTitles")
                .tabBarReserve()
        }
        .onAppear {
            #if DEBUG
            // `-openAllTitles 1` (DEBUG, like `-recapDemo`): open straight onto All titles — once.
            // `onAppear` fires again when All titles pops, and the flag re-pushed it on the spot.
            if UserDefaults.standard.bool(forKey: "openAllTitles"), all == nil, !debugOpenedAll {
                debugOpenedAll = true
                all = AllTitlesRoute()
            }
            #endif
        }
        .onChange(of: requestedAll, initial: true) { _, route in
            guard let route else { return }
            all = route
            requestedAll = nil
        }
        .onChange(of: popSignal) { _, _ in all = nil }
    }

    /// The empty state's one action, and it is always a live one.
    private var emptyStateAction: () -> Void {
        appModel.loadError ? { Task { await appModel.reload() } } : onAddShow
    }

    /// The wash is taken from the first show on the first shelf — the same artwork the eye lands
    /// on first, so the room is lit by the thing you are looking at.
    private func washArtwork(_ sections: [RootSection], heroItems: [Franchise]) -> String? {
        let franchise = heroItems.first
            ?? sections.first?.items.first
            ?? appModel.library.first
        guard let franchise else { return nil }
        return [franchise.resumePart?.landscapeArt, franchise.landscapeArt,
                franchise.resumePart?.portraitArt, franchise.portraitArt]
            .compactMap { $0 }
            .first(where: { !$0.isEmpty })
    }

    // MARK: - Root

    private func root(_ sections: [RootSection], heroItems: [Franchise]) -> some View {
        // EVERY bucket is a shelf — board 05's shape: one art moment, then quiet shelves, each
        // one "See all" from the instrument. The Watching bucket is the carousel's, so its shelf
        // only renders when the carousel cannot (a watching list with nothing resumable).
        // Next up takes the Watching shows with something to resume; the Watching shelf keeps
        // the REST (caught up, waiting) — it used to render only when Next up could not, so every
        // caught-up Watching show was on no shelf at all (review, 23 Sep).
        let queued = Set(heroItems.map(\.id))
        let shelves = sections.compactMap { section -> RootSection? in
            guard section.key == .watching else { return section }
            let rest = section.items.filter { !queued.contains($0.id) }
            return rest.isEmpty ? nil : RootSection(key: .watching, items: rest)
        }

        return VStack(alignment: .leading, spacing: ThemeMetrics.sectionGap) {
            if !heroItems.isEmpty {
                LibraryContinueShelf(items: heroItems, onViewAll: { all = route(for: .watching) }) { f in
                    onOpenDetail(f.id, "lib-hero/\(f.id)")
                }
            }

            ForEach(shelves) { section in
                LibraryLandscapeShelf(title: section.key.label,
                                      items: supportingItems(section)) {
                    all = route(for: section.key)
                } onOpen: { franchise in
                    onOpenDetail(franchise.id, "lib/\(franchise.id)")
                }
            }
        }
        // The artwork starts immediately below the inline bar. The old 20-pt lead-in plus the
        // spotlight's own 20-pt gap left the first third looking like the screen we replaced.
        .padding(.top, LibraryRootMetrics.contentTopPadding)
    }

    private func supportingItems(_ section: RootSection) -> [LibraryLandscapeItem] {
        section.items.prefix(LibraryRootMetrics.supportingPreviewCount).map { franchise in
            let facts = LibraryRowFacts.root(franchise, section: section.key, appModel: appModel)
            return LibraryLandscapeItem(franchise: franchise, lead: facts.lead, meta: facts.meta)
        }
    }

    struct RootSection: Identifiable {
        let key: LibrarySection
        let items: [Franchise]
        var id: Int { key.id }
    }

    /// `AppModel.libraryShelves` stays the source of truth for membership and order; the only thing
    /// done here is splitting `comingBack` in two, because a heading that says RETURNING may not
    /// contain a show whose own detail screen says "Finished" and "No date announced".
    ///
    /// A function, not a computed property, so a call site cannot read it twice by accident: it
    /// is resolved once in `body` and handed down.
    private func rootSections() -> [RootSection] {
        var out: [RootSection] = []
        for shelf in appModel.libraryShelves {
            switch shelf.shelf {
            case .comingBack:
                // Already sorted soonest-first by `AppModel`, so the dated ones lead and the
                // partition preserves that order inside each half. One `ReturnFact` per title.
                var dated: [Franchise] = [], undated: [Franchise] = []
                for f in shelf.franchises {
                    if ReturnFact.of(f, appModel: appModel).dated { dated.append(f) } else { undated.append(f) }
                }
                if !dated.isEmpty { out.append(RootSection(key: .returning, items: dated)) }
                if !undated.isEmpty { out.append(RootSection(key: .announced, items: undated)) }
            case .watching: out.append(RootSection(key: .watching, items: shelf.franchises))
            case .planned:  out.append(RootSection(key: .planned, items: shelf.franchises))
            case .finished: out.append(RootSection(key: .finished, items: shelf.franchises))
            case .paused:   out.append(RootSection(key: .paused, items: shelf.franchises))
            case .dropped:  out.append(RootSection(key: .dropped, items: shelf.franchises))
            }
        }
        return out.sorted { $0.key.rank < $1.key.rank }
    }

    /// Every section now has an honest destination, including the two that are not statuses.
    private func route(for key: LibrarySection) -> AllTitlesRoute {
        switch key {
        case .returning: return AllTitlesRoute(returning: .dated)
        case .announced: return AllTitlesRoute(returning: .undated)
        // The queue, as the header promises (interactive review: it opened "Watching, A–Z").
        case .watching:  return AllTitlesRoute(status: .watching, sort: .progress)
        case .planned:   return AllTitlesRoute(status: .planned)
        case .finished:  return AllTitlesRoute(status: .completed)
        case .paused:    return AllTitlesRoute(status: .paused)
        case .dropped:   return AllTitlesRoute(status: .dropped)
        }
    }

    // MARK: - Loading

    /// The loading frame is the selected composition itself: one cover-flow hero, its compact
    /// progress block, then two landscape cards. The handoff therefore changes content, not shape.
    private var skeleton: some View {
        VStack(alignment: .leading, spacing: ThemeMetrics.sectionGap) {
            VStack(alignment: .leading, spacing: ThemeSpace.x3) {
                SkeletonLine(width: LibraryRootMetrics.skeletonHeroHeading,
                             height: LibraryRootMetrics.skeletonHeadingHeight)
                    .padding(.horizontal, ThemeMetrics.gutter)
                HStack(alignment: .top, spacing: ThemeMetrics.shelfGap) {
                    ForEach(0..<2, id: \.self) { _ in
                        VStack(alignment: .leading, spacing: ThemeSpace.x2) {
                            SkeletonPoster(width: LibraryRootMetrics.continueSkeletonWidth,
                                           height: LibraryRootMetrics.continueSkeletonHeight,
                                           radius: ThemeRadius.card)
                            SkeletonLine(width: LibraryRootMetrics.skeletonHeroTitle,
                                         height: LibraryRootMetrics.skeletonTitleHeight)
                            SkeletonLine(width: LibraryRootMetrics.skeletonHeroMeta * 0.6,
                                         height: LibraryRootMetrics.skeletonMetaHeight)
                        }
                    }
                }
                .padding(.horizontal, ThemeMetrics.gutter)
                .clipped()
            }

            VStack(alignment: .leading, spacing: ThemeSpace.x3) {
                HStack {
                    SkeletonLine(width: LibraryRootMetrics.skeletonShelfHeading,
                                 height: LibraryRootMetrics.skeletonHeadingHeight)
                    Spacer()
                    SkeletonLine(width: LibraryRootMetrics.skeletonShelfAction,
                                 height: LibraryRootMetrics.skeletonMetaHeight)
                }
                .padding(.horizontal, ThemeMetrics.gutter)
                HStack(spacing: ThemeMetrics.shelfGap) {
                    ForEach(0..<2, id: \.self) { _ in
                        VStack(alignment: .leading, spacing: ThemeSpace.x2) {
                            SkeletonPoster(width: LibraryRootMetrics.landscapeSkeletonWidth,
                                           height: BannerCard.height,
                                           radius: ThemeRadius.card)
                            SkeletonLine(width: LibraryRootMetrics.landscapeSkeletonWidth * 0.72,
                                         height: LibraryRootMetrics.skeletonShelfTitleHeight)
                            SkeletonLine(width: LibraryRootMetrics.landscapeSkeletonWidth * 0.55,
                                         height: LibraryRootMetrics.skeletonMetaHeight)
                        }
                    }
                }
                .padding(.horizontal, ThemeMetrics.gutter)
            }
        }
        .padding(.top, LibraryRootMetrics.contentTopPadding)
    }

}

// MARK: - Art-first Library root

/// The geometry of the selected iPhone reference, kept in one place so the real content and its
/// loading frame cannot drift. These are composition measurements, not reusable design tokens.
private enum LibraryRootMetrics {
    /// The content needs a real breath after the index; the copied rail put a section title almost
    /// directly on its rule while leaving the navigation area comparatively empty.
    static let contentTopPadding: CGFloat = 20
    /// The lead shelf's card: four fifths of the content width, 16:9, so the next card peeks.
    static let continueCardCount = 5
    static let continueCardSpan = 4
    static let continueSkeletonWidth: CGFloat = 286
    static let continueSkeletonHeight: CGFloat = 161
    static let supportingPreviewCount = 6
    static let landscapeSkeletonWidth: CGFloat = 174

    static let skeletonHeroHeading: CGFloat = 108
    static let skeletonHeroTitle: CGFloat = 154
    static let skeletonHeroMeta: CGFloat = 196
    static let skeletonShelfHeading: CGFloat = 92
    static let skeletonShelfAction: CGFloat = 54
    static let skeletonEyebrowHeight: CGFloat = 10
    static let skeletonHeadingHeight: CGFloat = 19
    static let skeletonTitleHeight: CGFloat = 18
    static let skeletonMetaHeight: CGFloat = 12
    static let skeletonProgressHeight: CGFloat = 3
    static let skeletonShelfTitleHeight: CGFloat = 14
}

/// Continue watching, in the grammar Apple TV's Up Next and Netflix's Continue Watching share: a
/// horizontal shelf of landscape cards, each with its progress drawn along the bottom of the art
/// and the next episode named beneath. The cover-flow spotlight it replaces — one portrait cover
/// centred, its neighbours dimmed and tilted behind it — was a carousel from another era, and it
/// spent the root's first 300 pt on ONE show while hiding the rest behind a swipe.
private struct LibraryContinueShelf: View {
    let items: [Franchise]
    let onViewAll: () -> Void
    let onOpen: (Franchise) -> Void

    @Environment(AppModel.self) private var appModel
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: ThemeMetrics.labelGap) {
            SectionHeaderRow(Copy.Library.continueWatching, action: onViewAll)
                .padding(.horizontal, ThemeMetrics.gutter)

            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: ThemeMetrics.shelfGap) {
                    ForEach(items) { f in
                        if let part = f.resumePart {
                            LibraryContinueCard(franchise: f, part: part) { onOpen(f) }
                                .containerRelativeFrame(.horizontal,
                                                        count: typeSize.isAccessibilitySize ? 1 : LibraryRootMetrics.continueCardCount,
                                                        // A shelf of one runs gutter to gutter (review, 5 Sep).
                                                        span: typeSize.isAccessibilitySize || items.count == 1 ? (typeSize.isAccessibilitySize ? 1 : LibraryRootMetrics.continueCardCount) : LibraryRootMetrics.continueCardSpan,
                                                        spacing: ThemeMetrics.shelfGap)
                                .franchiseQuickActions(f, appModel: appModel)
                        }
                    }
                }
                .scrollTargetLayout()
            }
            .contentMargins(.horizontal, ThemeMetrics.gutter, for: .scrollContent)
            .scrollTargetBehavior(.viewAligned)
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The same scene/logo composition as Schedule; progress and the next episode stay in the art.
private struct LibraryContinueCard: View {
    let franchise: Franchise
    let part: FranchisePart
    let action: () -> Void

    // The show page's and Today's denominator (`progressDenominator`), so the card's bar is the
    // hero's bar (review i4: 79 % here, 83 % there).
    private var total: Int { max(part.progressDenominator(now: Int64(Date().timeIntervalSince1970 * 1000), anchor: franchise.timeAnchor), part.progress) }
    private var ratio: Double { total > 0 ? Double(part.progress) / Double(total) : 0 }
    private var next: String {
        let context = franchise.watchContext(part: part, episode: part.progress + 1)
        // The episode's own name, when the catalogue knows it and the server's pointer agrees
        // this is the episode (`continueWatching` — user-specific, never unaired). Spoiler-safe by
        // the row model's own rule: the NEXT episode's title is always shown.
        if let cw = franchise.continueWatching, cw.mediaId == part.mediaId, cw.episode.number == part.progress + 1,
           let title = EpisodeCopy.title(cw.episode.title, franchise: franchise.title) {
            return "\(context) \u{00B7} \(title)"
        }
        return context
    }
    private var spoken: String { Copy.Progress.watchedOf(part.progress, total) }

    var body: some View {
        ArtworkSceneCard(art: part.wideArt(within: franchise),
                         poster: franchise.portraitArt,
                         name: franchise.sceneName,
                         title: franchise.displayTitle,
                         fact: franchise.watchContext(part: part, episode: part.progress + 1),
                         progress: total > 0 ? ratio : nil,
                         onOpen: action) { EmptyView() }
            .zoomSource("lib-hero/\(franchise.id)")
            .accessibilityValue(total > 0 ? spoken : "")
    }
}

private struct LibraryLandscapeItem: Identifiable {
    let franchise: Franchise
    /// Lead and meta are carried SEPARATELY — `BannerCard` and `MediaRow` colour a lead amber,
    /// and the old merged `caption` is how this screen came to render "Returns today" in grey
    /// while Today drew the identical class of fact in accent.
    let lead: String?
    let meta: String?
    var id: String { franchise.id }
}

private struct LibraryLandscapeShelf: View {
    let title: String
    let items: [LibraryLandscapeItem]
    let onViewAll: () -> Void
    let onOpen: (Franchise) -> Void

    @Environment(AppModel.self) private var appModel
    @Environment(\.dynamicTypeSize) private var typeSize

    /// A second caption line is reserved only when a caption on THIS shelf can need one (~18
    /// characters fill a 118-pt band): Black Clover's "Watched" carried 41 pt of empty plate under
    /// it for a line nothing on its shelf used (review i4, N10).
    private var reservesSecondLine: Bool {
        typeSize.isAccessibilitySize || items.contains { ($0.lead ?? $0.meta ?? "").count > 18 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ThemeMetrics.labelGap) {
            // The app-wide header family — small-caps `SectionHeaderRow` with an inline "See all"
            // link. This shelf was the one place in the app headed by 20-pt mixed case with a
            // "View all" tertiary button: a second header grammar, one tab from Today's.
            SectionHeaderRow(title, actionLabel: Copy.Action.seeAll, action: onViewAll)
                .padding(.horizontal, ThemeMetrics.gutter)

            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: ThemeMetrics.shelfGap) {
                    ForEach(items) { item in
                        ArtworkPoster(url: item.franchise.tilePoster.url, name: item.franchise.tilePoster.name,
                                      title: item.franchise.displayTitle,
                                      detailsInBand: true,
                                      fixedAspect: 2.0 / 3.0,
                                      onOpen: { onOpen(item.franchise) }) {
                            if PosterCaption.style == .band {
                                // The lead (a date inside the horizon — "Returns 3 Oct") in amber, as
                                // Today's Planned posters draw it; the rest in white (review i3).
                                Text(item.lead ?? item.meta ?? "")
                                    .type(ThemeType.metadata)
                                    .foregroundStyle(item.lead != nil ? ThemeColor.accent : ThemeColor.textPrimary)
                                    .multilineTextAlignment(.center)
                                    // Two lines reserved where the shelf needs them: one caption
                                    // baseline and one card height across the row.
                                    .lineLimit(2, reservesSpace: reservesSecondLine)
                                    .fixedSize(horizontal: false, vertical: true)
                            } else {
                                PosterCaptionText(title: item.franchise.displayTitle,
                                                  fact: item.lead ?? item.meta, lead: item.lead != nil)
                            }
                        }
                            .frame(width: typeSize.isAccessibilitySize ? 210 : 150)
                            .zoomSource("lib/\(item.franchise.id)")
                            .franchiseQuickActions(item.franchise, appModel: appModel)
                    }
                }
                .scrollTargetLayout()
            }
            .contentMargins(.horizontal, ThemeMetrics.gutter, for: .scrollContent)
            .scrollTargetBehavior(.viewAligned)
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - All titles (the instrument)

/// Which half of "coming back" a filter means. Not a `WatchStatus` — a show's future is not a list
/// state, which is the confusion the whole round is about.
enum ReturnScope: String, Hashable, CaseIterable {
    case dated, undated
    var label: String { self == .dated ? LibrarySection.returning.label : LibrarySection.announced.label }
    var section: LibrarySection { self == .dated ? .returning : .announced }
}

/// The one screen in the Library with controls on it. Rows sit on the canvas at `rowMedia` with
/// 60×90 art, under **pinned letter headers with an index rail** — thirty alphabetical rows with
/// no section headers and no index made the sort order invisible until you scrolled, and at the
/// stated 300 titles reaching "Vinland Saga" was a flick-scroll lottery.
struct LibraryAllView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    let onOpenDetail: (_ franchiseId: String, _ zoomID: String) -> Void
    /// The empty-library state's action, the same one the root offers.
    var onAddShow: () -> Void = {}
    /// The artwork the ROOT's wash is lit by, handed through the push.
    var washArt: String? = nil
    /// The incoming filter is seeded into `@State` at INIT, not applied in `onAppear`. Applied
    /// late, the screen builds once unfiltered and once filtered — the user sees the whole library
    /// flash past on the way to the six rows they asked for, and the rows that survive both passes
    /// can keep the first pass's copy (rows under a `Watching` chip still reading "Watching").
    ///
    /// `initialUnwatchedOnly` composes with `initialStatus` rather than replacing it: Today's
    /// "View all N updates" asks for Watching AND unwatched, and dropping the status on the way in
    /// was how the list could disagree with the count that opened it.
    init(initialStatus: WatchStatus? = nil, initialReturning: ReturnScope? = nil,
         initialSort: Sort = .title, initialUnwatchedOnly: Bool = false,
         washArt: String? = nil,
         onOpenDetail: @escaping (_ franchiseId: String, _ zoomID: String) -> Void,
         onAddShow: @escaping () -> Void = {}) {
        self.onOpenDetail = onOpenDetail
        self.onAddShow = onAddShow
        self.washArt = washArt
        _status = State(initialValue: initialStatus.map(StatusFilter.status) ?? .any)
        _unwatchedOnly = State(initialValue: initialUnwatchedOnly)
        _returning = State(initialValue: initialReturning)
        _sort = State(initialValue: initialSort)
    }

    enum Sort: String, CaseIterable, Identifiable {
        /// "Recently added" is backed by `Subscription.addedAt`, which the API already sends. It is
        /// the one order a user needs after importing or adding twenty shows — "what did I just
        /// add" — and the shipped sheet had no way to produce it.
        case title, added, recent, progress
        var id: String { rawValue }

        var label: String {
            switch self {
            case .title: return Copy.Library.sortTitle
            case .added: return Copy.Library.sortAdded
            case .recent: return Copy.Library.sortRecent
            case .progress: return Copy.Library.sortProgress
            }
        }

        /// The reversed direction, said in the reader's terms rather than as "ascending".
        var reversedHint: String {
            switch self {
            case .title: return Copy.Library.reversedTitle
            case .added: return Copy.Library.reversedAdded
            case .recent: return Copy.Library.reversedRecent
            case .progress: return Copy.Library.reversedProgress
            }
        }
    }
    enum Display: String, CaseIterable, Identifiable {
        case posters, list
        var id: String { rawValue }
        var label: String { self == .posters ? Copy.Library.posters : Copy.Library.list }
    }

    /// **One** single-select control for "which titles" by list state.
    ///
    /// "Has unwatched episodes" is a separate axis (`unwatchedOnly`) that composes with it: Today
    /// asks for Watching AND unwatched, and a value that replaced the status could not say both.
    /// Its noun is named — the identical word on Schedule's menu means episodes.
    enum StatusFilter: Hashable, Identifiable {
        case any
        case status(WatchStatus)

        var id: String {
            switch self {
            case .any: return "any"
            case .status(let s): return s.rawValue
            }
        }

        var label: String {
            switch self {
            case .any: return Copy.Library.anyStatus
            case .status(let s): return Copy.Status(s)
            }
        }

        /// The chip form. A chip states the criterion, and "Any" is not one.
        var chip: String? { self == .any ? nil : label }

        /// True when this filter already tells the reader the row's list state, so the rows can
        /// stop repeating it.
        var givesState: Bool { if case .status = self { return true } else { return false } }

        var watchStatus: WatchStatus? { if case .status(let s) = self { return s } else { return nil } }
    }

    @State private var query = ""
    @State private var sort: Sort = .title
    /// Newest first for the date sorts, A→Z for title, most-behind first for progress — then this
    /// flips whichever it is. Three single-direction sorts meant "oldest first" simply did not
    /// exist in the product.
    @State private var sortAscending = false
    @State private var status: StatusFilter = .any
    /// Titles with an episode out now that you have not watched — Today's "N updates" set.
    @State private var unwatchedOnly = false
    @State private var returning: ReturnScope?
    @State private var display: Display = .list
    @State private var showArrange = false
    @State private var contentWidth: CGFloat = 0
    /// The scroll view's own height, so a state that owns the whole surface can be centred in it.
    @State private var contentHeight: CGFloat = 0
    /// Content has scrolled under the bar — the soft top veil hardens (same probe as the root).
    @State private var raisedTop = false
    /// The search field has focus: the inline title collapses and the bar's chrome is the
    /// drawer alone, so the hardened veil and its probe shrink with it (Search's rule).
    @State private var searchPresented = false

    private var searchChromeBottom: CGFloat {
        searchPresented
            ? ThemeMetrics.topSafeInset + ThemeMetrics.searchDrawerHeight
            : ThemeMetrics.inlineBarBottom + ThemeMetrics.searchDrawerHeight
    }
    @State private var railTouching = false
    /// Ties each pinned section header to its rotor entry, so VoiceOver can jump between letters
    /// even while the lazy stack has not built the rows in between.
    @Namespace private var rotorSpace

    private var isAX: Bool { typeSize.isAccessibilitySize }

    /// The filtered, sorted catalogue. A function, not a property: it was read from eight sites
    /// per render (the list, the grid, the rail, the rotor, `showsRail`, `isSectioned`, the
    /// footer, the rail's VoiceOver value), each one re-filtering and re-sorting the library. It
    /// is resolved once in `body` and passed down.
    ///
    /// "Has unwatched episodes" is **the set Today counts** — `AppModel.outNow`, resolved once per
    /// pass — so "View all 12 updates" lands on twelve rows. The shipped predicate was its own
    /// (`markTarget > progress`), which counted unaired seasons as unwatched and could not agree
    /// with the number that opened the screen.
    private func filtered() -> [Franchise] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let outNow: Set<String> = unwatchedOnly ? Set(appModel.outNow.map(\.id)) : []
        var arr = appModel.library.filter { f in
            let statusOK: Bool
            switch status {
            case .any: statusOK = true
            case .status(let s): statusOK = f.effectiveStatus == s
            }
            return statusOK
                && (!unwatchedOnly || outNow.contains(f.id))
                && (returning == nil
                    || LibraryShelving.section(of: f, appModel: appModel) == returning?.section)
                && (q.isEmpty || f.title.lowercased().contains(q))
        }
        switch sort {
        case .title: arr.sort(by: LibraryAllView.titleAscending)
        // `addedAt` is absent in older server responses; an unknown date sorts LAST in the default
        // (newest-first) order rather than pretending to be 1970.
        case .added: arr.sort(by: LibraryAllView.descending { $0.subscription?.addedAt ?? .min })
        case .recent: arr.sort(by: LibraryAllView.descending { $0.lastAiredSortKey })
        // Two tiers (interactive review: "Most left to watch" put Planned and Watched shows
        // first): what you are watching by its backlog, then everything else.
        case .progress: arr.sort(by: LibraryAllView.descending {
            ($0.effectiveStatus == .watching || $0.effectiveStatus == .paused ? 1_000_000 : 0) + $0.continueBacklog
        })
        }
        return sortAscending ? arr.reversed() : arr
    }

    /// The ONE tie-break, and the one title order. Three sorts used to break ties three ways
    /// (`lowercased()`, raw `title`, and a locale-aware compare), so "Ōoku" moved between them.
    private static func titleAscending(_ a: Franchise, _ b: Franchise) -> Bool {
        a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
    }

    /// Largest key first, `titleAscending` between equals.
    private static func descending<K: Comparable>(_ key: @escaping (Franchise) -> K)
        -> (Franchise, Franchise) -> Bool {
        { a, b in
            let ka = key(a), kb = key(b)
            return ka != kb ? ka > kb : titleAscending(a, b)
        }
    }

    /// A filter is a thing the user chose that hides rows. The **view mode** is not one — which is
    /// why the shipped "Posters … Clear" row offered a destructive-sounding action against a state
    /// that was nowhere on screen, and why the amber glyph in the bar meant nothing you could see.
    private var hasFilters: Bool {
        status != .any || unwatchedOnly || returning != nil || sort != .title || sortAscending
    }

    var body: some View {
        // Resolved ONCE per render, top to bottom: the rows, their sections, and the two facts
        // the chrome derives from them.
        let results = filtered()
        let sections = titleSections(results)
        let sectioned = isSectioned(results)
        let rail = showsRail(results)
        // The reader wraps the SCROLL VIEW. It used to sit inside the content, around the lazy
        // stack — which then had no scroll container to size against, reported zero height, and
        // drew its rows over the footer count that followed it ("30 titles" under the first row).
        return ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // The same freshness pair, failure notice and loading gate the root carries: this
                // screen used to open on a bare list whatever the catalogue's state was.
                Color.clear.frame(height: 0)
                    .freshness(.catalogue, appModel: appModel)
                    .padding(.horizontal, ThemeMetrics.gutter)

                if appModel.sectionFailed {
                    InlineNotice(Copy.Notice.library) { Task { await appModel.reload() } }
                        .padding(.horizontal, ThemeMetrics.gutter).padding(.top, ThemeSpace.x3)
                }

                if !activeChips.isEmpty { chipRow }

                SkeletonGate(isLoading: appModel.loading && appModel.library.isEmpty) {
                    skeleton
                } content: {
                  // ONE view. `SkeletonGate` lays its content out in a ZStack, so the list and the
                  // footer count handed to it as two siblings were drawn on top of each other —
                  // "30 titles" sitting across the first row.
                  VStack(alignment: .leading, spacing: 0) {
                    if appModel.library.isEmpty {
                        // The account, not a filter, is why there is nothing here — so the card
                        // is the root's, with the root's action. `.noFilterMatches` with no
                        // handler is the SYS-4 bug the DEBUG assert exists to catch.
                        EmptyState(appModel.emptyStateCopy, prominence: .major,
                                   primary: emptyLibraryAction)
                            .padding(.horizontal, ThemeMetrics.gutter)
                            .centredState(contentH: contentHeight)
                    } else if results.isEmpty {
                        // `hasFilters` is what emptied a query-less list, so `.noFilterMatches`
                        // always has its Clear; with a query the card still offers to clear
                        // whatever filters are narrowing it.
                        EmptyState(emptyResultsCopy, prominence: .major,
                                   primary: hasFilters ? { resetFilters() } : nil)
                            .padding(.horizontal, ThemeMetrics.gutter)
                            .centredState(contentH: contentHeight)
                    } else if display == .posters && !typeSize.isAccessibilitySize {
                        grid(sections, sectioned: sectioned, rail: rail).padding(.top, ThemeSpace.x2)
                    } else {
                        // No lead-in: the search drawer already carries its own margin, and the
                        // first row's own 8-pt padding is the gap iOS lists keep under a field.
                        list(sections, sectioned: sectioned, rail: rail)
                    }
                    if !results.isEmpty {
                        // Spoken, like the root's: the count is a fact about the list.
                        Text(Copy.titles(results.count))
                            .type(ThemeType.metadata).foregroundStyle(ThemeColor.textTertiary)
                            .numericFact(results.count)
                            .frame(maxWidth: .infinity)
                            .padding(.top, ThemeSpace.x6)
                    }
                  }
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { contentWidth = $0 }
            // The raised-edge probe (geometry-based; `onScrollGeometryChange` is dead on the
            // iOS 27 simulator). The drawer sits under the title, so content starts lower here —
            // the same status-band threshold still only trips once it has really scrolled.
            .background {
                Color.clear.onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.frame(in: .global).minY
                } action: { minY in
                    let raised = minY < searchChromeBottom
                    if raised != raisedTop { raisedTop = raised }
                }
            }
        }
        .scrollIndicators(.hidden)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        .onChange(of: railScroll) { _, key in
            guard let key else { return }
            proxy.scrollTo("sec-\(key)", anchor: .top)
        }
        // Flat, as the root and Today are (25 Sep, `flushTopBar`).
        .background(ThemeColor.canvas.ignoresSafeArea())
        .flushTopBar(searchChromeBottom)
        .toolbarBackground(.hidden, for: .navigationBar)
        .chromeScrollEdgeHidden(.top)
        .laneClearance(appModel, base: ThemeMetrics.tabBarClearance)
        // The rail owns a lane. Rows reserve it through `listTrailingInset`, so a chevron and an
        // index letter can never land on the same 4 pt of screen, and the poster grid narrows its
        // available width by the same amount — the letters used to sit ON the third column's
        // artwork, and a tap near a poster's right edge could be swallowed by the rail's gesture.
        .environment(\.listTrailingInset, rail ? LibraryAllView.railLane : 0)
        .overlay(alignment: .trailing) { if rail { indexRail(sections) } }
        .brandNavigationTitle(Copy.Heading.allTitles)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .searchable(text: $query, isPresented: $searchPresented,
                    placement: .navigationBarDrawer(displayMode: .always),
                    prompt: Copy.Library.searchPrompt)
        // The same field discipline as Search: titles are names, not sentences, and the keyboard
        // follows the finger down. This one auto-capitalised and sat over its own results.
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .scrollDismissesKeyboard(.interactively)
        // It drew the catalogue's stale strip with no gesture to answer it.
        .previouslyRefreshable { await appModel.reload() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showArrange = true } label: {
                    AppGlyph(systemName: "line.3.horizontal.decrease")
                }
                // Accent is selection here, and only here: an idle filter control is not the
                // screen's primary action and has no business being the loudest thing on it.
                .tint(hasFilters ? ThemeColor.accent : ThemeColor.textPrimary)
                .accessibilityLabel(ArrangeSheet.title)
            }
        }
        .sheet(isPresented: $showArrange) {
            ArrangeSheet(sort: $sort, ascending: $sortAscending, status: $status,
                         unwatchedOnly: $unwatchedOnly, display: $display, onReset: resetFilters)
                // Resolved BEFORE presentation from the row count and the type size. A detent that
                // measures itself cannot be right on the first frame: the sheet grew 68 pt under
                // the user's eye and only looked correct the second time it opened.
                .presentationDetents([.custom(ArrangeDetent.self), .large])
                .presentationDragIndicator(.visible)
                // Without this the sheet's plate stopped 34 pt short of the screen and the
                // undimmed list showed through the gap — it read as a rendering failure.
                .presentationBackground(ThemeColor.canvasRaised)
        }
        }
    }

    /// The empty-library action, and it is always a live one — the root's rule.
    private var emptyLibraryAction: () -> Void {
        appModel.loadError ? { Task { await appModel.reload() } } : onAddShow
    }

    /// Which "nothing here" card. A query names itself; a filter names the way out.
    private var emptyResultsCopy: EmptyStateCopy {
        query.isEmpty ? .noFilterMatches : Copy.Library.noSearchResults(query: query, filtered: hasFilters)
    }

    /// The list's stand-in: rows at the row slot, so the swap lands flush.
    private var skeleton: some View {
        VStack(spacing: 0) {
            ForEach(0..<Metrics.skeletonRowCount, id: \.self) { _ in
                SkeletonRow(poster: PosterSize.row.size, lines: Metrics.skeletonRowLines,
                            posterRadius: PosterSize.row.radius,
                            spacing: ThemeMetrics.artGap)
            }
        }
        .padding(.horizontal, ThemeMetrics.gutter)
        .padding(.top, ThemeSpace.x1)
    }

    // MARK: - Active filters, as chips

    private struct Chip: Identifiable {
        let id: String
        let text: String
        let clear: () -> Void
    }

    /// The iOS 26 filter-chip pattern: the criteria that are actually narrowing the list, each one
    /// removable on its own. The shipped row named the *view mode* in grey and offered an amber
    /// `Clear` beside it that reset four unrelated things at once, none of them on screen.
    private var activeChips: [Chip] {
        var chips: [Chip] = []
        if let text = status.chip {
            chips.append(Chip(id: "status", text: text) { self.status = .any })
        }
        if unwatchedOnly {
            chips.append(Chip(id: "unwatched", text: Copy.Library.hasUnwatched) { self.unwatchedOnly = false })
        }
        if let returning {
            chips.append(Chip(id: "returning", text: returning.label) { self.returning = nil })
        }
        if sort != .title || sortAscending {
            chips.append(Chip(id: "sort", text: sortChipLabel) { sort = .title; sortAscending = false })
        }
        return chips
    }

    /// The chip names the order the way the sheet does, direction included — a "Recently added"
    /// chip that silently means *oldest* first is a lie the reader cannot see.
    private var sortChipLabel: String {
        sortAscending ? Copy.Library.reversed(sort.label) : sort.label
    }

    private var chipRow: some View {
        ScrollView(.horizontal) {
            HStack(spacing: ThemeSpace.x2) {
                ForEach(activeChips) { chip in
                    Button {
                        FeedbackCoordinator.fire(.selection)
                        withAnimation(ThemeMotion.pick(ThemeMotion.uiSnappy, reduceMotion: reduceMotion)) {
                            chip.clear()
                        }
                    } label: {
                        FilterChipLabel(text: chip.text)
                    }
                    .buttonStyle(FilterChipStyle())
                    .accessibilityLabel(Copy.Accessibility.removeFilter(chip.text))
                }
                if activeChips.count > 1 {
                    Button(Copy.Action.reset) {
                        FeedbackCoordinator.fire(.selection)
                        withAnimation(ThemeMotion.pick(ThemeMotion.uiSnappy, reduceMotion: reduceMotion)) {
                            resetFilters()
                        }
                    }
                    // Neutral, not amber: returning to the default is the smallest thing on the
                    // row, and the screen's one accent is not spent on a utility.
                    .buttonStyle(ChipButtonStyle())
                }
            }
            .padding(.horizontal, ThemeMetrics.gutter)
        }
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
        .padding(.bottom, ThemeSpace.x2)
    }

    private func resetFilters() {
        // The VIEW MODE is deliberately untouched: it is a preference, not a filter, and nothing
        // on this row claims otherwise.
        sort = .title; sortAscending = false; status = .any; unwatchedOnly = false; returning = nil
    }

    // MARK: - Sections and the index

    struct TitleSection: Identifiable {
        let key: String
        let items: [Franchise]
        var id: String { key }
    }

    /// Grouped by the ACTIVE sort key — first letter for `.title`, month for the date sort. The
    /// backlog sort has no natural grouping, so it stays one flat list and the rail is suppressed
    /// with it; a header the sort cannot justify is noise.
    private func titleSections(_ results: [Franchise]) -> [TitleSection] {
        // One bucket when the list is not sectioned. A `Section` inside a `LazyVGrid` starts a new
        // ROW even when its header is an `EmptyView`, so leaving the per-letter buckets in place
        // and merely hiding the headers laid a ten-title poster wall out two-then-one down the
        // page with holes where the letters changed.
        guard isSectioned(results) else { return [TitleSection(key: "", items: results)] }
        switch sort {
        case .title:
            var buckets: [String: [Franchise]] = [:]
            for f in results { buckets[LibraryAllView.indexKey(f.title), default: []].append(f) }
            return buckets.keys.sorted { a, b in
                if (a == "#") != (b == "#") { return b == "#" }
                return a < b
            }.map { TitleSection(key: $0, items: buckets[$0] ?? []) }
        case .recent, .added:
            var order: [String] = []
            var buckets: [String: [Franchise]] = [:]
            for f in results {
                // `addedAt` is the user's own instant (local); an airing is read in the
                // franchise's calendar, so a TMDB date-only row lands in the month it names.
                let key = sort == .added
                    ? LibraryAllView.monthKey(f.subscription?.addedAt ?? 0, anchor: .local)
                    : LibraryAllView.monthKey(f.lastAiredSortKey, anchor: f.timeAnchor)
                if buckets[key] == nil { order.append(key) }
                buckets[key, default: []].append(f)
            }
            return order.map { TitleSection(key: $0, items: buckets[$0] ?? []) }
        case .progress:
            return [TitleSection(key: "", items: results)]
        }
    }

    /// Headers earn their keep only once the list is long enough that the sort order stops being
    /// obvious. Below that they cost more than they explain — and in the three-column grid an
    /// alphabetical break with one title behind it burns two empty cells, which is what a filtered
    /// poster wall looked like: one cover per row. Same threshold as the rail, so the two controls
    /// never disagree about whether this list has sections.
    private func isSectioned(_ results: [Franchise]) -> Bool {
        sort != .progress && results.count > LibraryAllView.sectionFloor
    }

    static let sectionFloor = 48

    /// Forty-eight rows is about five screens; below that a flick is faster than an alphabet, and
    /// a thirty-title library dressed in letter headers and a rail read as a phone book for one
    /// street. At the stated 300 titles the rail is the difference between finding "Vinland Saga"
    /// and hunting for it. Suppressed for every other sort order, where A–Z would be a lie.
    private func showsRail(_ results: [Franchise]) -> Bool {
        sort == .title && results.count > LibraryAllView.sectionFloor && !isAX
    }

    /// "A"…"Z" and "#" for everything that does not start with a letter.
    static func indexKey(_ title: String) -> String {
        let folded = title.folding(options: [.diacriticInsensitive, .caseInsensitive],
                                   locale: .current)
        guard let first = folded.first(where: { $0.isLetter || $0.isNumber }) else { return "#" }
        return first.isLetter ? String(first).uppercased() : "#"
    }

    /// `at` is **milliseconds**, like every other instant in this app. It was read as seconds here,
    /// which put the "Recently updated" month headers roughly fifty-five thousand years out.
    private static func monthKey(_ at: Int64, anchor: Formatting.TimeAnchor) -> String {
        guard at > 0 else { return Copy.Library.noDate }
        return LibraryDates.monthYear(at, anchor: anchor)
    }

    /// A pinned strip, not a floating label: content scrolls UNDER it, so it is opaque canvas with
    /// a quiet rule beneath — the same separator the rows carry.
    ///
    /// `inset` puts that rule on the SAME left edge as the row separators below it. Full width, it
    /// was a second separator inset on one screen (rows start their hairline at the title, x≈164)
    /// and the letter read as a stray character standing beside a rule that belonged to nothing.
    private func sectionHeader(_ key: String, inset: CGFloat, rail: Bool) -> some View {
        HStack(spacing: 0) {
            Text(key)
                .type(ThemeType.sectionLabel)
                .foregroundStyle(ThemeColor.textTertiary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, ThemeMetrics.gutter)
        .padding(.top, ThemeSpace.x3)
        .padding(.bottom, ThemeSpace.x1)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Opaque, and FULL-BLEED. Inset to the gutter it painted a visible canvas rectangle
        // against the ambient wash behind the list — a plate, which is exactly what a pinned
        // header must not look like. A pinned bar reaches both bezels.
        .background { ThemeColor.canvas.padding(.horizontal, -ThemeMetrics.gutter) }
        .overlay(alignment: .bottom) {
            Rectangle().fill(ThemeColor.separatorQuiet).frame(height: 1)
                .padding(.leading, inset)
                .padding(.trailing, rail ? LibraryAllView.railLane : 0)
        }
        .accessibilityAddTraits(.isHeader)
    }

    /// The A–Z rail — rebuilt. Everything it was measured on failed:
    ///
    ///  * **Type.** `.font(.system(size: 11, weight: .semibold))` is hard-coded, so it stayed 11 pt
    ///    at AX5; `sectionLabel` is the app's smallest token and it scales.
    ///  * **Contrast.** `textDisabled` is 3.6:1 — the non-text threshold — on TEXT. `textTertiary`
    ///    is 5.14:1, and while the finger is down the letters lift to `textSecondary` with the
    ///    ACTIVE one in accent, so the rail says which letter it is on instead of all of them.
    ///  * **Extent.** 15 letters × 15 pt was a 225-pt column floating in the vertical middle,
    ///    attached to nothing. It now spans the list, top to bottom, so its geometry means what it
    ///    looks like it means — and every band is at least 22 pt.
    ///  * **Target.** 22×15 pt bands inside a 22-pt column. The letters sit right-aligned in the
    ///    `railLane` (28 pt) the rows reserve (`listTrailingInset`); the GESTURE host is `railHit`
    ///    (44 pt) wide, reaching 16 pt into the rows' trailing padding, so the hit area is what
    ///    the comment says it is and the rail no longer sits on the third poster column's artwork.
    ///  * **VoiceOver.** It was `.accessibilityHidden(true)` with no substitute, so a user with 500
    ///    titles had to swipe every row. It is one adjustable element now, and the list carries a
    ///    "Sections" rotor.
    ///  * **Feel.** The 300 ms blanket haptic floor meant an A→W drag produced two taps. `.selection`
    ///    now has its own 40 ms floor (SYS-7), which is what makes this control feel alive.
    private func indexRail(_ sections: [TitleSection]) -> some View {
        let keys = sections.map(\.key)
        return GeometryReader { geo in
            let step = max(LibraryAllView.railMinStep,
                           geo.size.height / CGFloat(max(keys.count, 1)))
            VStack(spacing: 0) {
                ForEach(Array(keys.enumerated()), id: \.element) { i, key in
                    Text(key)
                        .type(ThemeType.sectionLabel)
                        .foregroundStyle(railTint(index: i))
                        .frame(maxWidth: .infinity)
                        .frame(height: step)
                }
            }
            .frame(width: LibraryAllView.railLane)
            .frame(width: LibraryAllView.railHit, height: geo.size.height, alignment: .topTrailing)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        railTouching = true
                        let i = Int(value.location.y / step)
                        select(index: max(0, min(keys.count - 1, i)), keys: keys)
                    }
                    .onEnded { _ in railTouching = false; railIndex = nil; railScroll = nil }
            )
        }
        .frame(width: LibraryAllView.railHit)
        // Between the search drawer and the tab bar, so the column IS the list's extent.
        .padding(.top, ThemeSpace.x3)
        .padding(.bottom, ThemeMetrics.tabBarClearance)
        .background(alignment: .trailing) {
            // The ground appears only under the finger, and only behind the letters.
            Capsule()
                .fill(ThemeColor.surfaceRaised.opacity(railTouching ? 1 : 0))
                .frame(width: LibraryAllView.railLane)
                .padding(.vertical, ThemeSpace.x2)
        }
        .animation(ThemeMotion.pick(ThemeMotion.uiMicro, reduceMotion: reduceMotion), value: railTouching)
        .accessibilityElement()
        .accessibilityLabel(Copy.Library.sectionIndex)
        .accessibilityValue(railIndex.flatMap { keys.indices.contains($0) ? keys[$0] : nil }
                            ?? keys.first ?? "")
        .accessibilityHint(Copy.Library.sectionIndexHint)
        .accessibilityAdjustableAction { direction in
            let current = railIndex ?? 0
            let next = direction == .increment ? current + 1 : current - 1
            guard keys.indices.contains(next) else { return }
            select(index: next, keys: keys)
        }
    }

    /// One selection, wherever it came from — the finger or the VoiceOver rotor.
    private func select(index: Int, keys: [String]) {
        guard keys.indices.contains(index), index != railIndex else { return }
        railIndex = index
        FeedbackCoordinator.fire(.selection)
        railScroll = keys[index]
    }

    private func railTint(index: Int) -> Color {
        guard railTouching else { return ThemeColor.textTertiary }
        return index == railIndex ? ThemeColor.accent : ThemeColor.textSecondary
    }

    @State private var railIndex: Int?
    @State private var railScroll: String?

    /// The reserved trailing lane. Rows stop short of it and the poster grid narrows by it, which
    /// is what Contacts does and what stops a letter landing on a cover.
    static let railLane: CGFloat = 28
    /// The rail's gesture host — the minimum touch target, wider than the lane the letters draw in.
    static let railHit: CGFloat = 44
    /// A band is never smaller than this, however few letters there are; above that the rail fills
    /// the list's height so the column is anchored to the thing it scrolls.
    private static let railMinStep: CGFloat = 22

    // MARK: - List

    private func list(_ sections: [TitleSection], sectioned: Bool, rail: Bool) -> some View {
        // LAZY, and SECTIONED. At the stated 300-title library an eager `VStack` instantiates 300
        // `MediaRow`s and 300 `RemoteImageView`s on push, and thirty unbroken alphabetical rows
        // make the sort order invisible until you have already scrolled past it.
        LazyVStack(spacing: 0, pinnedViews: sectioned ? [.sectionHeaders] : []) {
            ForEach(sections) { section in
                Section {
                    ForEach(Array(section.items.enumerated()), id: \.element.id) { i, f in
                        row(f, last: i == section.items.count - 1)
                    }
                } header: {
                    listHeader(section, sectioned: sectioned, rail: rail)
                }
            }
        }
        .padding(.horizontal, ThemeMetrics.gutter)
        // The rail's VoiceOver counterpart: the same jumps, through the system's own rotor.
        .accessibilityRotor(Copy.Library.sectionsRotor, entries: sections, entryID: \.key, entryLabel: \.key)
    }

    /// Extracted: the pinned header, inset to the rows' own hairline and wired to the rotor.
    @ViewBuilder
    private func listHeader(_ section: TitleSection, sectioned: Bool, rail: Bool) -> some View {
        if sectioned {
            sectionHeader(section.key, inset: ThemeMetrics.rowRuleInset, rail: rail)
                .id("sec-\(section.key)")
                .accessibilityRotorEntry(id: section.key, in: rotorSpace)
        }
    }

    private func row(_ f: Franchise, last: Bool) -> some View {
        let facts = LibraryRowFacts.catalogue(f, appModel: appModel, stateIsGiven: status.givesState)
        // `.row` (60×90 at `rowMedia`) — the one list-row slot. At 48 pt wide a logo-led cover is
        // below the recognition floor ("Avatar: Seven Havens" rendered as a black rectangle with
        // unreadable type), and this is the catalogue, the one screen whose whole job is picking
        // a title out of three hundred.
        return ArtworkSceneCard(art: f.wideArt, poster: f.portraitArt,
                                name: f.sceneName, title: f.displayTitle,
                                fact: facts.lead, detail: facts.meta, detailLead: facts.metaLead,
                                aspect: isAX ? 1 : 1.65,
                                onOpen: { onOpenDetail(f.id, "all/\(f.id)") }) { EmptyView() }
        .zoomSource("all/\(f.id)")
        .padding(.bottom, ThemeSpace.x4)
        .franchiseQuickActions(f, appModel: appModel)
    }

    // MARK: - Poster wall

    /// Three columns that exactly fill the gutters instead of an adaptive grid that leaves a ragged
    /// 30 pt down the trailing edge — and the same pinned headers the list carries, because a wall
    /// of 300 covers needs the alphabet even more than a list of them does.
    private func grid(_ sections: [TitleSection], sectioned: Bool, rail: Bool) -> some View {
        let columns = 3
        let lane = rail ? LibraryAllView.railLane : 0
        let available = max(0, contentWidth - ThemeMetrics.gutter * 2 - lane)
        let cellWidth = available > 0
            ? (available - ThemeMetrics.shelfGap * CGFloat(columns - 1)) / CGFloat(columns)
            : PosterSize.shelfMedium.size.width
        return LazyVGrid(columns: Array(repeating: GridItem(.fixed(cellWidth), spacing: ThemeMetrics.shelfGap,
                                                            alignment: .top),
                                        count: columns),
                         alignment: .leading, spacing: ThemeSpace.x6,
                         pinnedViews: sectioned ? [.sectionHeaders] : []) {
                ForEach(sections) { section in
                    Section {
                        ForEach(section.items) { f in
                            cell(f, width: cellWidth, alignCaptions: section.items.count > 1)
                        }
                    } header: {
                        if sectioned {
                            // No poster column to align to in the wall, so the rule starts at the
                            // gutter — and stops short of the rail's lane, like every row does.
                            sectionHeader(section.key, inset: ThemeMetrics.gutter, rail: rail)
                                .padding(.horizontal, -ThemeMetrics.gutter)
                                .id("sec-\(section.key)")
                                .accessibilityRotorEntry(id: section.key, in: rotorSpace)
                        }
                    }
                }
            }
            .padding(.horizontal, ThemeMetrics.gutter)
            .accessibilityRotor(Copy.Library.sectionsRotor, entries: sections, entryID: \.key, entryLabel: \.key)
    }

    /// A `ShelfCard` at the grid's own width. The card's rules, verbatim — `shelfShortened`
    /// title, THREE reserved lines at a 0.82 floor, two-line tail-truncated caption, the shelf
    /// slot's radius — because the wall and the Returning shelf are one poster-plus-caption
    /// object and were drifting on every one of those (two lines here, no scale floor, a
    /// hand-picked radius). `ShelfCard` itself sizes from a slot and cannot take the computed
    /// column width, which is the only reason this is not a call to it.
    ///
    /// `alignCaptions` reserves the title lines so a row of cells keeps ONE caption baseline. A
    /// section holding a single title has nothing to align with, and reserving there left a hole
    /// between a one-line title and its caption — the caption ended up nearer the next section
    /// than its own cover.
    private func cell(_ f: Franchise, width: CGFloat, alignCaptions: Bool = true) -> some View {
        // Resolved once — calling the accessor twice to pick a colour is how a caption and its
        // colour drift apart.
        let caption = gridCaption(f)
        return ArtworkPoster(url: f.tilePoster.url, name: f.tilePoster.name, title: f.displayTitle,
                             detailInset: ThemeSpace.x2,
                             detailsInBand: true,
                             fixedAspect: 2.0 / 3.0,
                             onOpen: { onOpenDetail(f.id, "all/\(f.id)") }) {
            if PosterCaption.style == .band {
                if let caption {
                    Text(caption.text)
                        .type(ThemeType.shelfCaption)
                        .foregroundStyle(ThemeColor.textPrimary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                PosterCaptionText(title: f.displayTitle, fact: caption?.text, lead: caption?.lead ?? false)
            }
        }
        .frame(width: width)
        .zoomSource("all/\(f.id)")
        .franchiseQuickActions(f, appModel: appModel)
        .accessibilityElement(children: .combine)
        // The spoken title is the WHOLE title, never the shortened one.
        .accessibilityLabel([f.title, caption?.text].compactMap { $0 }.joined(separator: ", "))
        .accessibilityHint(Copy.Accessibility.opensTheShowHint)
    }

    /// The grid cell is ~136 pt wide, not 360 — so it gets the SHORTEST honest form of the **same**
    /// facts, from the same function the list rows use.
    ///
    /// This used to be a second implementation, and it reached a different conclusion: the wall
    /// said "Episode 1 next" in amber where the list said "Watched" in grey for the same show one
    /// segment apart, and neither mentioned the rewatch that was actually in progress. A user reads
    /// that as the app losing their data. `catalogue(compact:)` is now the single source; the mode
    /// changes the layout and never the facts. Board 09's rule holds: drop a fact, never truncate.
    private func gridCaption(_ f: Franchise) -> (text: String, lead: Bool)? {
        let facts = LibraryRowFacts.catalogue(f, appModel: appModel,
                                              stateIsGiven: status.givesState, compact: true)
        if let lead = facts.lead { return (lead, true) }
        if let meta = facts.meta { return (meta, false) }
        return nil
    }

    /// Geometry this screen owns and no token names. One line of reason each.
    private enum Metrics {
        /// Enough skeleton rows to fill a phone screen at the row slot; the same line widths the
        /// root's list stand-in uses, so the two loading frames are one object.
        static let skeletonRowCount = 8
        static let skeletonRowLines: [CGFloat] = [196, 108]
    }
}

// MARK: - Sort and filter

/// The detent, resolved before the sheet is on screen.
///
/// `arrangeHeight` used to start at a 340-pt guess and be corrected by `onGeometryChange` feeding
/// `.presentationDetents([.height(h)])`, so the sheet grew 68 pt under the user's eye on first open
/// and only looked right the second time. A custom detent computes from what the sheet actually
/// contains — five rows, two groups, a header — scaled by the type size, and is correct on frame 1.
private enum ArrangeGeometry {
    /// What the detent measures: four rows in the first group, one in the second.
    static let rowCount: CGFloat = 5
    /// Header (52) + its top pad (12) + the groups' top pad (20) + the gap between the groups (30)
    /// + the bottom pad (24) + the home-indicator strip a sheet's scroll view inherits (34) — less
    /// the 42 pt the sheet measured under that sum on the simulator. A detent computed purely from
    /// first principles left 42 pt of void beneath the last row.
    /// The one `SectionLabel` group header the sheet gained is paid for out of the gap between the
    /// groups, which the label now occupies — measured on the simulator, the sum above still lands
    /// the last row's baseline where it was.
    static let chrome: CGFloat = ArrangeMetrics.headerHeight + 12 + 20 + 30 + 24 + 34 - 42
}

/// Geometry the sheet owns and no token names. One line of reason each.
private enum ArrangeMetrics {
    /// The sheet's hand-built header: a 44-pt link row plus the drag indicator's clearance.
    static let headerHeight: CGFloat = 52
    /// `GroupedRow`'s own insets (14 leading, 16 trailing), so a menu row and a toggle row in the
    /// same plate share one text edge.
    static let rowInsetLeading: CGFloat = 14
    static let rowInsetTrailing: CGFloat = 16
    /// The pop-up glyph (`chevron.up.chevron.down`) at the size the system draws it in a menu row.
    static let popupGlyphSize: CGFloat = 12
    /// Two segments ("Posters" / "List") at their natural width beside a label on one row.
    static let segmentedWidth: CGFloat = 168
}

private struct ArrangeDetent: CustomPresentationDetent {
    static func height(in context: Context) -> CGFloat? {
        let rows = ArrangeGeometry.rowCount * ThemeMetrics.rowCompact * typeFactor(context.dynamicTypeSize)
        return min(rows + ArrangeGeometry.chrome, context.maxDetentValue * 0.92)
    }

    /// Body text grows roughly linearly with the Dynamic Type ramp; the rows are `minHeight`
    /// bound, so this only has to be right to a few points.
    private static func typeFactor(_ size: DynamicTypeSize) -> CGFloat {
        switch size {
        case .xSmall: return 0.92
        case .small: return 0.95
        case .medium: return 0.98
        case .large: return 1.00
        case .xLarge: return 1.08
        case .xxLarge: return 1.16
        case .xxxLarge: return 1.26
        case .accessibility1: return 1.52
        case .accessibility2: return 1.74
        case .accessibility3: return 2.05
        case .accessibility4: return 2.35
        case .accessibility5: return 2.60
        @unknown default: return 1.00
        }
    }
}

/// Board 05, verbatim: "a grouped list, not a chip cloud — Sort by and Status rows, a segmented
/// View, native toggles, Reset."
///
/// Titled **Sort & filter** (sentence case, `Copy.Heading`), because "Arrange" is Files.app's word
/// for ordering a grid and this sheet holds a sort, its direction and a status filter. "Has
/// unwatched episodes" is a native toggle under Status — its own axis, composed with the status,
/// and named for its noun. What is left over is `View as`, which is neither a sort nor a filter —
/// so it gets its own named group and stops reading as an afterthought.
///
/// The header is hand-built rather than a `NavigationStack` toolbar: on this OS a toolbar button
/// renders as a filled glass capsule, which made `Done` the single heaviest object in a sheet whose
/// whole job is to be quiet. `Done` is a link. `Reset` is a link. The rows are the content.
private struct ArrangeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @Binding var sort: LibraryAllView.Sort
    @Binding var ascending: Bool
    @Binding var status: LibraryAllView.StatusFilter
    @Binding var unwatchedOnly: Bool
    @Binding var display: LibraryAllView.Display
    let onReset: () -> Void

    private var isAX: Bool { typeSize.isAccessibilitySize }

    private var hasFilters: Bool { sort != .title || ascending || status != .any || unwatchedOnly }

    /// Sentence case, and the `&` only because these are two nouns in a label that has to hold one
    /// line. `Copy.Heading` settles both rules once for the whole app.
    static var title: String { Copy.Heading.sortAndFilter }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                header
                groups
                    .padding(.horizontal, ThemeMetrics.gutter)
                    .padding(.top, ThemeSpace.x5)
                    .padding(.bottom, ThemeSpace.x6)
            }
        }
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize)
        // The sheet's own ground is set with `.presentationBackground` at the call site so it
        // reaches the screen's bottom edge; painting it on this scroll view left the plate 34 pt
        // short and the undimmed list showing through underneath.
    }

    private var groups: some View {
        VStack(alignment: .leading, spacing: ThemeMetrics.sectionGap) {
            // The first group needs no label: the sheet's own title names it, and repeating
            // "SORT & FILTER" 30 pt under "Sort & filter" is an echo. The SECOND group gets one,
            // which is the whole point — "View as" is neither a sort nor a filter, and unlabelled
            // it read as an afterthought stranded in a plate of its own. (iOS Settings grammar:
            // the first group is implicit, later groups are named.)
            GroupedList {
                valueRow(title: Copy.Library.sortBy, value: sort.label, separator: true) {
                    Picker(Copy.Library.sortBy, selection: sortBinding) {
                        ForEach(LibraryAllView.Sort.allCases) { s in
                            Text(s.label).tag(s)
                        }
                    }
                    .pickerStyle(.inline)
                }
                // Every sort shipped in exactly one direction, so "oldest first" did not exist.
                GroupedRow(title: Copy.Library.reverseOrder,
                           subtitle: ascending ? sort.reversedHint : nil,
                           trailing: .toggle(ascendingBinding), separator: true)
                valueRow(title: Copy.Library.status, value: status.label, separator: true) {
                    Picker(Copy.Library.status, selection: statusBinding) {
                        Text(LibraryAllView.StatusFilter.any.label)
                            .tag(LibraryAllView.StatusFilter.any)
                        ForEach(WatchStatus.menuOrder, id: \.self) { s in
                            Text(LibraryRowFacts.listState(status: s))
                                .tag(LibraryAllView.StatusFilter.status(s))
                        }
                    }
                    .pickerStyle(.inline)
                }
                // Its own axis, so Today's "Watching AND unwatched" is representable — and a
                // native toggle, which is what board 05 asked for.
                GroupedRow(title: Copy.Library.hasUnwatched,
                           trailing: .toggle(unwatchedBinding), separator: false)
            }

            GroupedList(header: Copy.Library.view) { viewAsRow }
        }
    }

    /// Board 05 asks for a segmented View. At accessibility sizes two words cannot share a row with
    /// their label, so the control drops under it rather than squeezing to 60 pt.
    private var viewAsRow: some View {
        let picker = Picker(Copy.Library.viewAs, selection: displayBinding) {
            ForEach(LibraryAllView.Display.allCases) { d in
                Text(d.label).tag(d)
            }
        }
        .pickerStyle(.segmented)

        return Group {
            if isAX {
                VStack(alignment: .leading, spacing: ThemeSpace.x2) {
                    Text(Copy.Library.viewAs).type(ThemeType.body).foregroundStyle(ThemeColor.textPrimary)
                    picker
                }
                .padding(.vertical, ThemeSpace.x3)
            } else {
                HStack(spacing: ThemeSpace.x3) {
                    Text(Copy.Library.viewAs).type(ThemeType.body).foregroundStyle(ThemeColor.textPrimary)
                    Spacer(minLength: ThemeSpace.x3)
                    picker.frame(width: ArrangeMetrics.segmentedWidth)
                }
            }
        }
        .padding(.leading, ArrangeMetrics.rowInsetLeading).padding(.trailing, ArrangeMetrics.rowInsetLeading)
        .frame(minHeight: ThemeMetrics.rowCompact)
    }

    /// A `GroupedRow` that opens a menu instead of pushing. Same 14/16 insets, same 56-pt height,
    /// same quiet separator — it is the shared row's geometry with a `Menu` where the `Button` is,
    /// which `GroupedRow` has no case for yet (see the shared-file request in the report).
    private func valueRow<Content: View>(title: String, value: String, separator: Bool,
                                         @ViewBuilder menu: () -> Content) -> some View {
        Menu {
            menu()
        } label: {
            HStack(spacing: ThemeSpace.x3) {
                Text(title).type(ThemeType.body).foregroundStyle(ThemeColor.textPrimary)
                Spacer(minLength: ThemeSpace.x3)
                Text(value)
                    .type(ThemeType.body).foregroundStyle(ThemeColor.textTertiary)
                    .lineLimit(1)
                // The pop-up glyph, not `chevron.forward`: this row opens a menu in place, it does
                // not push a screen, and iOS has one symbol for each.
                AppGlyph(systemName: "chevron.up.chevron.down")
                    .font(.system(size: ArrangeMetrics.popupGlyphSize, weight: .semibold))
                    .foregroundStyle(ThemeColor.textDisabled)
            }
            .padding(.leading, ArrangeMetrics.rowInsetLeading).padding(.trailing, ArrangeMetrics.rowInsetTrailing)
            .frame(minHeight: ThemeMetrics.rowCompact)
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) {
                if separator {
                    Rectangle().fill(ThemeColor.separatorQuiet)
                        .frame(height: 1).padding(.leading, ArrangeMetrics.rowInsetLeading)
                }
            }
        }
        .accessibilityLabel(title)
        .accessibilityValue(value)
    }

    /// The title is an OVERLAY, not a stack member: with `Reset` present on one side only, a
    /// three-item HStack puts the title wherever the two buttons' widths happen to leave it.
    private var header: some View {
        HStack {
            if hasFilters {
                Button(Copy.Action.reset) {
                    FeedbackCoordinator.fire(.selection)
                    withAnimation(ThemeMotion.pick(ThemeMotion.uiSnappy, reduceMotion: reduceMotion)) {
                        onReset()
                    }
                }
                .buttonStyle(InlineLinkButtonStyle())
            }
            Spacer(minLength: 0)
            Button(Copy.Action.done) { dismiss() }
                .buttonStyle(InlineLinkButtonStyle())
        }
        .overlay {
            Text(ArrangeSheet.title)
                .type(ThemeType.showTitleM).foregroundStyle(ThemeColor.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .padding(.horizontal, ThemeMetrics.gutter)
        .frame(height: ArrangeMetrics.headerHeight)
        .padding(.top, ThemeSpace.x3)
    }

    // MARK: - Bindings
    //
    // A `Picker` writes straight through its binding, so the haptic and the settle animation the
    // spec asks of a selection have to live in the binding rather than at a tap site.

    private func select<V: Equatable>(_ current: V, _ new: V, _ apply: @escaping () -> Void) {
        guard new != current else { return }
        FeedbackCoordinator.fire(.selection)
        withAnimation(ThemeMotion.pick(ThemeMotion.uiMicro, reduceMotion: reduceMotion), apply)
    }

    private var sortBinding: Binding<LibraryAllView.Sort> {
        Binding(get: { sort }, set: { new in select(sort, new) { sort = new } })
    }

    private var statusBinding: Binding<LibraryAllView.StatusFilter> {
        Binding(get: { status }, set: { new in select(status, new) { status = new } })
    }

    private var displayBinding: Binding<LibraryAllView.Display> {
        Binding(get: { display }, set: { new in select(display, new) { display = new } })
    }

    private var ascendingBinding: Binding<Bool> {
        Binding(get: { ascending }, set: { new in select(ascending, new) { ascending = new } })
    }

    private var unwatchedBinding: Binding<Bool> {
        Binding(get: { unwatchedOnly }, set: { new in select(unwatchedOnly, new) { unwatchedOnly = new } })
    }
}
