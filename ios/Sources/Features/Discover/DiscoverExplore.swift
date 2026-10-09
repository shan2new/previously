import SwiftUI

// Discover at rest, rebuilt in Today's language (25 Sep: "Discover UX needs an overhaul to match
// this new awesome Today UX", owner). Today speaks X and Instagram; Discover spoke Apple TV — a
// "TOP PICK FOR YOU" billboard with an amber capsule, shelves under chevroned headers, a row of
// scope chips, a poster wall. It is now X's and Instagram's EXPLORE:
//   · under the field, X's tabs — For you · Trending · Genres — the words bold 16, the underline
//     riding the pager while the finger drags (Today's `FeedTabsRow`, the same numbers), each page
//     keeping its own place;
//   · For you is Netflix's home (`ForYouShelves`, chosen by the owner the same day from three
//     photographed directions): the top pick as a big card, then a shelf per show of yours the
//     rest come from, then "Trending now" — the Instagram wall it replaced had no names and gave
//     the reason on one tile in six ("extremely poorly built", owner);
//   · Trending is X's list: "1 · Anime · Trending", the title in bold, one fact, a small poster;
//   · Genres is the catalogue's genre tiles, all of them, as a page of its own.
// The scope (All / Anime / TV) is a menu in the bar; the field and its results are unchanged.

enum DiscoverSection: CaseIterable, Hashable {
    case forYou, trending, genres

    var title: String {
        switch self {
        case .forYou: Copy.Discover.tabForYou
        case .trending: Copy.Discover.tabTrending
        case .genres: Copy.Discover.tabGenres
        }
    }
}

/// The pager's position as a fraction of a page, written by the pager's probe and read ONLY by
/// the tab row, so a swipe redraws three words and a capsule.
@MainActor
@Observable
final class PagerProgress {
    private(set) var value: CGFloat = 0

    func set(_ v: CGFloat, pages: Int) {
        let clamped = min(max(v, 0), CGFloat(max(0, pages - 1)))
        let landed = clamped == clamped.rounded()
        if abs(clamped - value) >= 0.002 || (landed && clamped != value) { value = clamped }
    }
}

/// Discover's header as it scrolls away — Today's rules (`FeedChromeState`) for Explore's three
/// pages (25 Sep: "Discover also needs the scroll treatment like in Today", owner). The header slides
/// up with the finger, point for point; at rest it is either shown or gone (past halfway it
/// finishes leaving); it comes back on the way up, on a page change and on a re-selected tab. The
/// bottom bar rides it (`AppTabBar.scrollAway`), as it rides the feed's.
@MainActor
@Observable
final class DiscoverChromeState: ScrollAwayChrome {
    /// How far the header has slid up: 0 (all there) … `DiscoverHeader.height` (gone).
    private(set) var offset: CGFloat = 0
    /// The page in front; the others' probes are recorded, never acted on.
    @ObservationIgnored private var page: DiscoverSection = .forYou
    /// Each page's last scroll distance (a page keeps its place, so its header picks up from there).
    @ObservationIgnored private var lastY: [DiscoverSection: CGFloat] = [:]

    var awayFraction: CGFloat { offset / DiscoverHeader.height }

    /// One page's scroll distance from its resting top (negative while pulling to refresh).
    func track(_ y: CGFloat, page p: DiscoverSection) {
        let previous = lastY[p] ?? 0
        lastY[p] = y
        guard p == page else { return }
        let next: CGFloat = y <= 0 ? 0 : min(max(offset + (y - previous), 0), DiscoverHeader.height)
        if abs(next - offset) >= 0.5 || (next == 0 && offset != 0) { offset = next }
    }

    /// At rest the header is either shown or gone: past halfway it finishes leaving, else it returns.
    func settle(page p: DiscoverSection) {
        guard p == page, offset > 0, offset < DiscoverHeader.height else { return }
        let gone = offset > DiscoverHeader.height / 2 && (lastY[p] ?? 0) > DiscoverHeader.height
        withAnimation(Self.motion) { offset = gone ? DiscoverHeader.height : 0 }
    }

    /// A page's scroll distance from its resting top, as the probe last reported it.
    func y(of p: DiscoverSection) -> CGFloat { lastY[p] ?? 0 }

    /// The header comes back (a re-selected tab, a page change, the field).
    func reveal() {
        guard offset != 0 else { return }
        withAnimation(Self.motion) { offset = 0 }
    }

    /// The pager put `p` in front: the header comes back — it carries the tabs that say where you are.
    func activate(_ p: DiscoverSection) {
        guard p != page else { return }
        page = p
        reveal()
    }

    private static var motion: Animation {
        ThemeMotion.pick(ThemeMotion.uiSnappy, reduceMotion: UIAccessibility.isReduceMotionEnabled)
    }
}

/// X's Explore header: the search field's capsule with the scope beside it, then the tabs and one
/// rule — the height of Today's (a 44-pt row, a 44-pt tab row, a pixel).
enum DiscoverHeader {
    static var height: CGFloat { FeedMetrics.headerRow + FeedMetrics.headerTabs + FeedMetrics.hairline }
    /// X's search pill.
    static let fieldHeight: CGFloat = 36
}

struct DiscoverExplore: View {
    /// In the scope, best first.
    let recommendations: [RecommendationItem]
    let trending: [FranchiseSummary]
    let genres: [DiscoverGenre]
    /// Which picture the genre tiles wear (`GenreArt.flavour(for:leaning:)`).
    var genreFlavour: GenreArt.Flavour = .anime
    let reason: (RecommendationItem) -> RecommendationItem.Reason
    /// A trending show's facts for the chart: why it is trending now (a time this week leads, in
    /// amber; a next installment in grey) and what it is.
    let trendFacts: (FranchiseSummary) -> TrendFacts
    /// The chart row's add pill (the search results' `AddControl(.pill)`).
    let trendTrailing: (FranchiseSummary) -> AnyView
    /// A trending poster's add disc on For you's last shelf (`AddControl(.overArt)`).
    let trendAdd: (FranchiseSummary) -> AnyView
    let spoken: (FranchiseSummary) -> String
    let onOpenRecommendation: (RecommendationItem) -> Void
    let onOpenShow: (FranchiseSummary) -> Void
    let onRefresh: @Sendable () async -> Void
    /// Drawn over For you's shelves (the notification primer after an add).
    var header: AnyView? = nil
    /// The header's scroll state (`DiscoverChromeState`), held by the tab so the bar can ride it.
    let chrome: DiscoverChromeState
    /// The field's words at rest, and what a tap on its capsule does (the system field takes over).
    let searchPrompt: String
    let onSearch: () -> Void
    /// The scope menu (All · Anime · TV) beside the field.
    let scope: AnyView
    /// The system field is up. While it is, the pages keep their places; when it goes they are put
    /// back EXACTLY there — the system bar that comes up to search left the page in front 59 pt low
    /// (unclamped) when it went, until the next touch (25 Sep).
    var searching: Bool = false

    @Environment(AppModel.self) private var appModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var section: DiscoverSection = .forYou
    @State private var pagerSection: DiscoverSection? = .forYou
    @State private var progress = PagerProgress()
    @State private var proxies: [DiscoverSection: ScrollViewProxy] = [:]
    /// Each page's position, bound only so a page can be put back (`searching`). Written by the
    /// scroll view when a gesture takes over, never per frame.
    @State private var positions: [DiscoverSection: ScrollPosition] = [:]
    /// Where each page stood when the field came up.
    @State private var parked: [DiscoverSection: CGFloat] = [:]
    /// A half-point nudge of the pages' top inset for one beat after the field goes: the system
    /// bar's exit leaves the scroll views' insets stale until something re-lays them out.
    @State private var insetNudge: CGFloat = 0

    private static let top = "top"

    var body: some View {
        GeometryReader { geo in
            // The top inset is the WINDOW's status band, never the container's: the system bar
            // comes up only to search, and with its height in the inset every page moved by the
            // bar's height when it went away again (For you sat 60 pt low after Cancel, 25 Sep).
            let top = ThemeMetrics.topSafeInset
            let insets = EdgeInsets(top: top, leading: 0, bottom: geo.safeAreaInsets.bottom, trailing: 0)
            // Today's anatomy: the pages run under the status band and the header, each insetting
            // its own content, and the header slides over them (`DiscoverChromeState`).
            ZStack(alignment: .top) {
                pager(width: geo.size.width, insets: insets)
                exploreHeader(topInset: top)
                    .padding(.top, top)
            }
        }
        .ignoresSafeArea(.container, edges: .top)
        .onChange(of: pagerSection) { _, next in
            if let next, next != section {
                section = next
                chrome.activate(next)
            }
        }
        .onChange(of: searching) { _, now in
            if now {
                parked = Dictionary(uniqueKeysWithValues: DiscoverSection.allCases.map { ($0, chrome.y(of: $0)) })
            } else {
                restorePages()
            }
        }
    }

    /// Every page back where it stood before the field came up — once as the system bar leaves and
    /// once after its animation has run, which is when the unclamped offset lands.
    private func restorePages() {
        let places = parked
        Task { @MainActor in
            var still = Transaction()
            still.disablesAnimations = true
            // The stale inset lands the moment the system bar starts to leave (filmed: the page
            // faded back in 59 pt low and stayed there until the next touch), and the bar's own
            // animation can land it again — so the pages re-lay out on four beats across it, the
            // first while the page is still fading in.
            var slept = 0.0
            for beat in [0.05, 0.15, 0.3, 0.45] {
                try? await Task.sleep(for: .seconds(beat - slept))
                slept = beat
                withTransaction(still) { insetNudge = 0.5 }
                try? await Task.sleep(for: .milliseconds(17))
                slept += 0.017
                withTransaction(still) {
                    insetNudge = 0
                    for (s, y) in places {
                        if y <= 1 {
                            // At the top a position of 0 is a no-op (the view believes it is
                            // there): the anchor the tab's re-tap uses moves it for real.
                            proxies[s]?.scrollTo(Self.top, anchor: .top)
                        } else {
                            positions[s, default: ScrollPosition(edge: .top)].scrollTo(y: y)
                        }
                    }
                }
            }
        }
    }

    private func position(_ s: DiscoverSection) -> Binding<ScrollPosition> {
        Binding(get: { positions[s] ?? ScrollPosition(edge: .top) }, set: { positions[s] = $0 })
    }

    // MARK: The header

    private func exploreHeader(topInset: CGFloat) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: ThemeSpace.x1) {
                searchCapsule
                scope
                    .frame(width: FeedMetrics.actionHitHeight, height: FeedMetrics.actionHitHeight)
            }
            .padding(.leading, ThemeMetrics.gutter)
            .padding(.trailing, ThemeSpace.x1)
            .frame(height: FeedMetrics.headerRow)
            ExploreTabs(selected: section, progress: progress) { next in
                if next == section {
                    chrome.reveal()
                    withAnimation(ThemeMotion.pick(ThemeMotion.uiSnappy, reduceMotion: reduceMotion)) {
                        proxies[next]?.scrollTo(Self.top, anchor: .top)
                    }
                } else {
                    withAnimation(ThemeMotion.pick(ThemeMotion.uiSnappy, reduceMotion: reduceMotion)) {
                        pagerSection = next
                    }
                }
            }
        }
        .background { FeedHeaderGround() }
        .offset(y: -chrome.offset)
        // The status band keeps its own ground, drawn OVER the sliding header, so the header passes
        // under it instead of through the clock — Today's, point for point.
        .overlay(alignment: .top) {
            FeedHeaderGround()
                .frame(height: topInset)
                .offset(y: -topInset)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    /// X's search pill: a tap hands over to the system field (`.searchable`), which brings the
    /// recents, the results, Cancel and the scopes exactly as before.
    private var searchCapsule: some View {
        Button(action: onSearch) {
            HStack(spacing: ThemeSpace.x2) {
                AppGlyph(systemName: "magnifyingglass")
                    .font(ThemeType.feedMeta.font.weight(.medium))
                Text(searchPrompt)
                    .type(ThemeType.feedMeta)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(ThemeColor.feedSecondary)
            .padding(.horizontal, ThemeSpace.x3)
            .frame(height: DiscoverHeader.fieldHeight)
            .background(ThemeColor.surfaceRaised, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(searchPrompt)
        .accessibilityAddTraits(.isSearchField)
        .qaIdentifier("qa.search.open")
    }

    // MARK: The pager

    private func pager(width: CGFloat, insets: EdgeInsets) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 0) {
                ForEach(DiscoverSection.allCases, id: \.self) { s in
                    page(s, insets: insets)
                        .frame(width: width)
                        .id(s)
                }
            }
            .scrollTargetLayout()
            .background {
                Color.clear.onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.frame(in: .global).minX
                } action: { minX in
                    guard width > 0 else { return }
                    progress.set(-minX / width, pages: DiscoverSection.allCases.count)
                }
            }
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $pagerSection)
        .scrollIndicators(.hidden)
        .ignoresSafeArea(.container, edges: .vertical)
    }

    /// One page: its own list, its own place, its own pull — under the header's room.
    private func page(_ s: DiscoverSection, insets: EdgeInsets) -> some View {
        ScrollViewReader { reader in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Color.clear.frame(height: DiscoverHeader.height).id(Self.top)
                    switch s {
                    case .forYou: forYou
                    case .trending: trendingList
                    case .genres: genreWall
                    }
                }
                // The scroll probe: WRITES the header's offset, never screen state.
                .background {
                    Color.clear.onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.frame(in: .global).minY
                    } action: { minY in
                        chrome.track(insets.top - minY, page: s)
                    }
                }
            }
            .scrollPosition(position(s))
            .safeAreaPadding(.top, insets.top + insetNudge)
            .safeAreaPadding(.bottom, insets.bottom)
            .qaIdentifier("qa.scroll.discover")
            .scrollIndicators(.hidden)
            .tabBarContentMargin()
            .laneClearance(appModel)
            .onScrollPhaseChange { _, next in
                if next == .idle { chrome.settle(page: s) }
            }
            .previouslyRefreshable(onRefresh)
            .onAppear { proxies[s] = reader }
        }
    }

    // MARK: For you — Netflix's shelves

    @ViewBuilder
    private var forYou: some View {
        if recommendations.isEmpty && trending.isEmpty {
            if let header { header.padding(.vertical, ThemeSpace.x3) }
            placeholder
        } else {
            ForYouShelves(recommendations: recommendations, trending: trending, reason: reason, spoken: spoken,
                          trendAdd: trendAdd, onOpenRecommendation: onOpenRecommendation, onOpenShow: onOpenShow,
                          afterTopPick: header)
        }
    }

    // MARK: Trending — X's list

    @ViewBuilder
    private var trendingList: some View {
        if trending.isEmpty {
            placeholder
        } else {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(trending.enumerated()), id: \.element.id) { i, item in
                    TrendRow(rank: i + 1, item: item, facts: trendFacts(item), trailing: trendTrailing(item)) {
                        onOpenShow(item)
                    }
                }
            }
        }
    }

    // MARK: Genres

    @ViewBuilder
    private var genreWall: some View {
        if genres.isEmpty {
            ProgressView()
                .tint(ThemeColor.feedSecondary)
                .frame(maxWidth: .infinity, minHeight: 200)
                .accessibilityLabel(Copy.Accessibility.loading)
        } else {
            DiscoverGenres(genres: genres, flavour: genreFlavour, limit: nil, header: false)
                .padding(.top, ThemeSpace.x3)
        }
    }

    // MARK: States

    @ViewBuilder
    private var placeholder: some View {
        if !SyncCenter.shared.isOnline {
            EmptyState(.searchOffline, primary: { appModel.loadTrendingIfNeeded() })
                .padding(.horizontal, ThemeMetrics.gutter)
                .padding(.vertical, ThemeSpace.x8)
        } else {
            ProgressView()
                .tint(ThemeColor.feedSecondary)
                .frame(maxWidth: .infinity, minHeight: 200)
                .accessibilityLabel(Copy.Accessibility.loading)
        }
    }
}

// MARK: - The tabs

/// X's tabs under the field — Today's `FeedTabsRow`, the same numbers: bold 16 in both states,
/// the ink and a 3-pt capsule following the pager (`PagerProgress`), a one-pixel rule under.
struct ExploreTabs: View {
    let selected: DiscoverSection
    let progress: PagerProgress
    let onSelect: (DiscoverSection) -> Void

    @State private var words: [DiscoverSection: CGRect] = [:]

    private static let underlineHeight: CGFloat = 3
    private static let underlineOverhang: CGFloat = 11
    private static let space = "exploreTabs"

    var body: some View {
        let p = progress.value
        let tabs = DiscoverSection.allCases
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(Array(tabs.enumerated()), id: \.element) { index, t in
                    let lit = max(0, 1 - abs(p - CGFloat(index)))
                    Button { onSelect(t) } label: {
                        word(t, ink: ThemeColor.feedSecondary)
                            .overlay { word(t, ink: ThemeColor.feedText).opacity(lit) }
                            .onGeometryChange(for: CGRect.self) { proxy in
                                proxy.frame(in: .named(Self.space))
                            } action: { frame in
                                if words[t] != frame { words[t] = frame }
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .frame(height: FeedMetrics.headerTabs)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(t == selected ? .isSelected : [])
                }
            }
            .overlay(alignment: .bottomLeading) { underline(p, tabs: tabs) }
            .coordinateSpace(.named(Self.space))
            FeedHairline()
        }
        .background(ThemeColor.canvas)
    }

    private func word(_ t: DiscoverSection, ink: Color) -> some View {
        Text(t.title)
            .type(ThemeType.feedTab)
            .foregroundStyle(ink)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }

    /// The capsule between the two words either side of `p`, `p`'s fraction of the way across.
    @ViewBuilder
    private func underline(_ p: CGFloat, tabs: [DiscoverSection]) -> some View {
        let lower = max(0, min(tabs.count - 1, Int(p.rounded(.down))))
        let upper = min(tabs.count - 1, lower + 1)
        if let a = words[tabs[lower]], let b = words[tabs[upper]] {
            let f = p - CGFloat(lower)
            let width = a.width + (b.width - a.width) * f + 2 * Self.underlineOverhang
            let midX = a.midX + (b.midX - a.midX) * f
            Capsule()
                .fill(ThemeColor.feedText)
                .frame(width: width, height: Self.underlineHeight)
                .offset(x: midX - width / 2)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

// MARK: - The chart row

/// What a chart row says about a show: WHY it is trending now, and WHAT it is.
struct TrendFacts {
    /// "Airs Sunday" (amber: a time this week) · "Season 2 · Jan 2027" (grey) · nil.
    let now: String?
    let nowLeads: Bool
    /// ["Anime", "Isekai", "Military"] — the kind and its themes, else the kind and the year. Drawn
    /// by `FactLine`, which drops a fact that does not fit rather than cutting one in half.
    let what: [String]
}

/// A chart row (rebuilt 25 Sep — "Trending tab in discover is incorrectly built. It makes no sense
/// man!", owner: every row repeated "1 · Anime · Trending" under a tab already called Trending, the
/// next line repeated "Anime", the rank was a grey footnote, and nothing said why a 2017 show was
/// on the chart). Now the charts' own grammar — Apple TV's Top Charts, Netflix's Top 10: the RANK
/// as a numeral, the poster, the title, why it is here now, what it is — and X's Follow pill to add
/// it. The row opens the show; its long press is the library's quick actions.
private struct TrendRow: View {
    let rank: Int
    let item: FranchiseSummary
    let facts: TrendFacts
    let trailing: AnyView
    let action: () -> Void

    @Environment(AppModel.self) private var appModel

    private static let rankColumn: CGFloat = 28
    private static let posterWidth: CGFloat = 56
    private static let posterRadius: CGFloat = 6
    /// The chart's podium: the top three ranks in ink, the rest grey.
    private static let podium = 3

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Self.posterRadius, style: .continuous)
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: ThemeSpace.x3) {
                Button(action: action) {
                    HStack(alignment: .center, spacing: ThemeSpace.x3) {
                        Text(Copy.Discover.trendRank(rank))
                            .type(ThemeType.trendRank)
                            .foregroundStyle(rank <= Self.podium ? ThemeColor.feedText : ThemeColor.feedSecondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .frame(width: Self.rankColumn)
                        RemoteImageView(url: item.tilePoster.url ?? item.portraitArt, contentMode: .fill,
                                        maxPixel: 300, alignment: .top)
                            .frame(width: Self.posterWidth, height: Self.posterWidth * 1.5)
                            .clipShape(shape)
                            .overlay(shape.strokeBorder(ThemeColor.posterEdge, lineWidth: FeedMetrics.hairline))
                        VStack(alignment: .leading, spacing: ThemeSpace.x0_5) {
                            // Three lines: anime titles run long, and a chart that cuts the
                            // name it ranks has not said what is trending.
                            Text(item.title)
                                .type(ThemeType.feedName)
                                .foregroundStyle(ThemeColor.feedText)
                                .lineLimit(3)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                            if let now = facts.now {
                                Text(now)
                                    .type(ThemeType.feedMeta)
                                    .foregroundStyle(facts.nowLeads ? ThemeColor.accent : ThemeColor.feedSecondary)
                                    .lineLimit(1)
                            }
                            FactLine(facts: facts.what, token: ThemeType.feedMeta, tint: ThemeColor.feedSecondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Copy.Discover.trendA11y(rank: rank, title: item.title,
                                                            facts: [facts.now ?? "", facts.what.joined(separator: FactLine.separator)]))
                .accessibilityHint(Copy.Accessibility.opensTheShowHint)
                trailing
            }
            .padding(.leading, ThemeSpace.x2)
            .padding(.trailing, ThemeMetrics.gutter)
            .padding(.vertical, ThemeSpace.x3)
            .franchiseQuickActions(appModel.franchise(id: item.id), appModel: appModel)
            FeedHairline()
        }
    }
}
