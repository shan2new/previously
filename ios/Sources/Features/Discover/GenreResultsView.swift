import SwiftUI

// One genre's page (ios-spec §3.7), pushed from a Discover genre tile (`DiscoverRoute.genre`,
// registered in `RootView.detailDestinations`). The genre's shows ranked by the server
// (popularity/trending), in the scope the field is filtering, as Search's browse anatomy: a
// 3-column wall of the shows' own posters (the trending grid's `ArtworkPoster`, the 20 Sep
// direction), rows at the accessibility sizes. Nothing the viewer owns is excluded — an owned
// title is MARKED (the amber check on its art, "In Library" to VoiceOver).
//
// The page reads `DiscoverCatalog.shared` and pages on: the last six cards appearing ask for the
// next page (`nextCursor`), deduped by id. A failed first page is a notice with Retry at the top;
// a failed continuation is the same notice at the foot, under the rows that did arrive.

struct GenreResultsView: View {
    let genreKey: String
    let name: String
    let onOpenDetail: (String) -> Void

    @Environment(AppModel.self) private var appModel
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The scroll view's own height, for centring the empty state.
    @State private var contentH: CGFloat = 0

    private var catalog: DiscoverCatalog { DiscoverCatalog.shared }
    private var isAX: Bool { typeSize.isAccessibilitySize }

    /// Cards from the end of the loaded list whose appearance asks for the next page.
    private static let prefetchDistance = 6
    private static let columns = 3

    var body: some View {
        let filter = appModel.mediaFilter
        let state = catalog.page(key: genreKey, filter: filter)
        // The server filters by source; the client applies the same scope so a page loaded under
        // "All" can never show a TV show while the chip says Anime.
        let items = filter == .all ? state.items : state.items.filter { appModel.matchesMediaFilter($0.source) }
        // Captured for the pull, whose closure runs off the main actor.
        let store = catalog
        let api = appModel.api
        let key = genreKey
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // The launchpad's own resting chips: a genre opened under All can still be
                // narrowed to Anime or TV here. The scope is the app's one `mediaFilter`, so a
                // change here is a change on Discover too.
                ScopeChips()
                    .padding(.top, ThemeSpace.x2)
                if state.failed, !state.failedMore {
                    InlineNotice(Copy.Discover.genreFailed) { reload(force: true) }
                        .padding(.horizontal, ThemeMetrics.gutter)
                        .padding(.top, ThemeSpace.x3)
                }
                SkeletonGate(isLoading: items.isEmpty && !state.loaded && !state.failed) {
                    skeleton
                } content: {
                    if items.isEmpty {
                        if state.loaded, !state.failed {
                            EmptyState(.genreEmpty)
                                .padding(.horizontal, ThemeMetrics.gutter)
                                .centredState(contentH: contentH)
                        }
                    } else {
                        results(items)
                            .padding(.top, ThemeSpace.x3)
                        footer(state)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(ThemeMotion.pick(ThemeMotion.uiGentle, reduceMotion: reduceMotion), value: state.failed)
        }
        .scrollIndicators(.hidden)
        .laneClearance(appModel)
        .tabBarContentMargin()
        .previouslyRefreshable {
            await store.loadPage(api: api, key: key, filter: filter, more: false, force: true)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentH = $0 }
        .background(ThemeColor.canvas.ignoresSafeArea())
        .brandNavigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: filter) {
            catalog.adopt(account: appModel.accountEpoch)
            await catalog.loadPage(api: appModel.api, key: genreKey, filter: filter, more: false)
        }
    }

    // MARK: - Results

    @ViewBuilder
    private func results(_ items: [FranchiseSummary]) -> some View {
        if isAX {
            // At accessibility sizes a poster grid has no honest shape (Search's rule): the app's
            // row — poster, name, facts — reflows where a card cannot.
            LazyVStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                    row(item, separator: i < items.count - 1)
                        .onAppear { reachedCard(i, of: items.count) }
                }
            }
            .padding(.horizontal, ThemeMetrics.gutter)
        } else {
            // LAZY by row: a genre runs to hundreds of shows over its pages, and every card is a
            // poster decode. Each row carries its owned marks' one corner (`CornerRow`, Search's).
            LazyVStack(alignment: .leading, spacing: ThemeMetrics.shelfGap) {
                ForEach(Array(stride(from: 0, to: items.count, by: Self.columns)), id: \.self) { start in
                    let row = Array(items[start..<min(start + Self.columns, items.count)])
                    let owned = row.filter(isOwned)
                    HStack(alignment: .top, spacing: ThemeMetrics.shelfGap) {
                        ForEach(Array(row.enumerated()), id: \.element.id) { offset, item in
                            card(item)
                                .onAppear { reachedCard(start + offset, of: items.count) }
                        }
                        // A short last row keeps the grid's column width.
                        ForEach(0..<(Self.columns - row.count), id: \.self) { _ in
                            Color.clear.frame(maxWidth: .infinity).frame(height: 0)
                        }
                    }
                    .environment(\.cornerRow, owned.isEmpty ? nil : CornerRow(urls: owned.compactMap(\.tilePoster.url)))
                }
            }
            .padding(.horizontal, ThemeMetrics.gutter)
        }
    }

    /// The trending wall's card, verbatim in anatomy: the show's own titled key art, whole; the
    /// poster names the show, so no caption repeats it; owned is the amber check in the corner.
    private func card(_ item: FranchiseSummary) -> some View {
        let owned = isOwned(item)
        return ArtworkPoster(url: item.tilePoster.url, name: item.tilePoster.name, title: item.title,
                             showsDetails: false,
                             cornerMark: owned
                                ? AnyView(OwnedMark().padding(ThemeSpace.x2).allowsHitTesting(false)) : nil,
                             onOpen: { onOpenDetail(item.id) }) { EmptyView() }
            .accessibilityLabel(spoken(item, owned: owned))
            .accessibilityHint(Copy.Accessibility.opensTheShowHint)
            .franchiseQuickActions(appModel.franchise(id: item.id), appModel: appModel)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
    }

    private func row(_ item: FranchiseSummary, separator: Bool) -> some View {
        let owned = isOwned(item)
        return MediaRow(title: item.title,
                        meta: facts(item).joined(separator: FactLine.separator),
                        lead: owned ? Copy.Discover.owned : nil,
                        poster: item.portraitArt,
                        slot: .row,
                        separator: separator,
                        hint: Copy.Accessibility.opensTheShowHint) {
            onOpenDetail(item.id)
        }
        .franchiseQuickActions(appModel.franchise(id: item.id), appModel: appModel)
    }

    /// The shape of the page about to arrive: two rows of the grid's cards (the rows' own at the
    /// accessibility sizes), so nothing reflows when the first page lands.
    @ViewBuilder
    private var skeleton: some View {
        if isAX {
            VStack(spacing: 0) {
                ForEach(0..<4, id: \.self) { _ in
                    SkeletonRow(poster: PosterSize.row.size, lines: Metrics.skeletonRowLines,
                                posterRadius: PosterSize.row.radius,
                                spacing: ThemeMetrics.artGap, height: ThemeMetrics.rowMedia)
                }
            }
            .padding(.horizontal, ThemeMetrics.gutter)
            .padding(.top, ThemeSpace.x3)
        } else {
            VStack(spacing: ThemeMetrics.shelfGap) {
                ForEach(0..<Metrics.skeletonGridRows, id: \.self) { _ in
                    HStack(spacing: ThemeMetrics.shelfGap) {
                        ForEach(0..<Self.columns, id: \.self) { _ in
                            SkeletonBlock(height: nil, radius: ThemeRadius.poster)
                                .aspectRatio(Metrics.posterAspect, contentMode: .fit)
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
            }
            .padding(.horizontal, ThemeMetrics.gutter)
            .padding(.top, ThemeSpace.x3)
        }
    }

    /// Under the rows: the next page on its way, or a continuation that failed (Retry continues).
    @ViewBuilder
    private func footer(_ state: GenrePageState) -> some View {
        if state.failedMore {
            InlineNotice(Copy.Discover.genreFailed) { loadMore(retry: true) }
                .padding(.horizontal, ThemeMetrics.gutter)
                .padding(.top, ThemeSpace.x4)
        } else if state.loading {
            ProgressView()
                .tint(ThemeColor.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, ThemeSpace.x5)
                .accessibilityLabel(Copy.Accessibility.loading)
        }
    }

    // MARK: - Paging

    private func reachedCard(_ index: Int, of count: Int) {
        guard index >= count - Self.prefetchDistance else { return }
        loadMore(retry: false)
    }

    /// The next page. An appearing card never retries a failed continuation — that would loop
    /// against a dead network as the rows scroll; the footer's Retry does.
    private func loadMore(retry: Bool) {
        let filter = appModel.mediaFilter
        let state = catalog.page(key: genreKey, filter: filter)
        guard !state.loading, !state.exhausted, retry || !state.failed else { return }
        Task { await catalog.loadPage(api: appModel.api, key: genreKey, filter: filter, more: true) }
    }

    private func reload(force: Bool) {
        let filter = appModel.mediaFilter
        Task { await catalog.loadPage(api: appModel.api, key: genreKey, filter: filter, more: false, force: force) }
    }

    // MARK: - Facts

    /// Owned: the LIBRARY's answer — live, so an add or a removal made since the page loaded (the
    /// page is cached for ten minutes) reads true at once. The server's per-viewer `status` mark
    /// stands in only while there is no library to ask yet (a cold launch that opened here).
    private func isOwned(_ item: FranchiseSummary) -> Bool {
        if appModel.library.isEmpty { return item.status != nil || appModel.isInLibrary(item.id) }
        return appModel.isInLibrary(item.id)
    }

    private func facts(_ item: FranchiseSummary) -> [String] {
        [item.source.kindLead, item.year.map(String.init)].compactMap { $0 }
    }

    /// The whole title, then "In Library" when it is yours, then kind and year.
    private func spoken(_ item: FranchiseSummary, owned: Bool) -> String {
        ([item.title] + (owned ? [Copy.Discover.owned] : []) + facts(item)).joined(separator: ", ")
    }
}

/// Sizes with no token. Each says why it is the number it is.
private enum Metrics {
    /// A poster's shape, for the skeleton's cards (the wall's covers are ~2:3).
    static let posterAspect: CGFloat = 2.0 / 3.0
    /// Two rows of cards fill the first screen under the bar.
    static let skeletonGridRows = 2
    /// Skeleton row lines at the widths the real rows land at (Search's).
    static let skeletonRowLines: [CGFloat] = [188, 126]
}
