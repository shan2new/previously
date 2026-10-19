import SwiftUI

// The show page is the show's X PROFILE (25 Sep 2026). "Details screen." (owner, after Today,
// Discover and Schedule were rebuilt in the feed's language); three directions were photographed
// on the owner's shows — Netflix's title page, the show as an X profile, the billboard kept but
// lighter — and the owner chose the profile. X's anatomy, the app's face (Outfit) and its art:
//   · a BANNER — the show's landscape art, 16:9 rather than X's 3:1 so the art still leads — under
//     the floating back and `···`;
//   · the show's FACE (the feed's rounded square — shows are organisations) overlapping its foot,
//     and X's FOLLOW pill as the library status ("Add" on white; the status in an outline that
//     opens the status menu);
//   · the name, a grey identity line where X prints the handle, the synopsis as the bio, X's meta
//     row (when the next episode airs, how many seasons, where to watch as the link), and X's
//     counts ("96 Watched  99 Episodes");
//   · X's TABS — Posts · Episodes · Media · About — which pin under the bar once they reach it;
//   · Posts: the next episode PINNED (X's pinned post, with the mark as X's white pill) over the
//     show's own posts from the feed (its news and trailers).
// The Apple TV billboard, its lockup and the long stack of sections it opened on are gone.

/// The profile's tabs, in X's order.
enum ShowTab: Int, CaseIterable, Hashable {
    case posts, episodes, media, about
    /// The directions' stage page only (`Experience.doors`): "More like this" and "Because you
    /// finished", named in the index instead of buried at About's foot under the cast.
    case similar

    /// The profile direction's tabs (it never had Similar).
    static var profileTabs: [ShowTab] { [.posts, .episodes, .media, .about] }

    var title: String {
        switch self {
        case .posts: return Copy.ShowPage.posts
        case .episodes: return Copy.Heading.episodes
        case .media: return Copy.ShowPage.media
        case .about: return Copy.ShowPage.about
        case .similar: return Copy.ShowPage.similar
        }
    }

    /// `-detailTab posts|episodes|media|about` (DEBUG): open on a tab, for a capture.
    static var initial: ShowTab {
        #if DEBUG
        switch UserDefaults.standard.string(forKey: "detailTab") {
        case "episodes": return .episodes
        case "media": return .media
        case "about": return .about
        default: return .posts
        }
        #else
        return .posts
        #endif
    }
}

/// X's profile tabs: equal slots, the word in `feedTab`, ink when selected and grey otherwise, X's
/// 3-pt underline 11 pt past the word gliding to the selection, one pixel of rule under the row.
struct ShowTabsRow: View {
    @Binding var selected: ShowTab
    /// The underline's glide; each copy of the row (in the page, pinned under the bar) has its own.
    @Namespace private var underline
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let height: CGFloat = 50

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(ShowTab.profileTabs, id: \.self) { tab in
                    Button {
                        withAnimation(ThemeMotion.pick(ThemeMotion.uiSnappy, reduceMotion: reduceMotion)) { selected = tab }
                    } label: {
                        ZStack(alignment: .bottom) {
                            Text(tab.title)
                                .type(ThemeType.feedTab)
                                .foregroundStyle(tab == selected ? ThemeColor.feedText : ThemeColor.feedSecondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                            if tab == selected {
                                // The word's own width (a hidden copy), 11 pt past it each side, on
                                // the row's foot.
                                Text(tab.title)
                                    .type(ThemeType.feedTab)
                                    .lineLimit(1)
                                    .fixedSize()
                                    .hidden()
                                    .frame(height: 3)
                                    .overlay(Capsule().fill(ThemeColor.feedText).padding(.horizontal, -4))
                                    .matchedGeometryEffect(id: "underline", in: underline)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .qaIdentifier("qa.detail.tab.\(String(describing: tab))")
                    .accessibilityAddTraits(tab == selected ? .isSelected : [])
                }
            }
            .frame(height: Self.height)
            FeedHairline()
        }
        .accessibilityElement(children: .contain)
    }
}

/// X's meta-row label: the glyph a step smaller than the fact, 4 pt from it.
struct ShowFactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon
                .font(.system(size: 13, weight: .regular))
                .accessibilityHidden(true)
            configuration.title
        }
    }
}

/// X's meta row wraps like a sentence: items left to right, onto the next line when the next one
/// does not fit — never a truncated fact.
struct ShowFactsFlow: Layout {
    var spacing: CGFloat = ThemeSpace.x4
    var lineSpacing: CGFloat = ThemeSpace.x1

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(ProposedViewSize(width: width, height: nil))
            if x > 0, x + size.width > width {
                y += line + lineSpacing
                x = 0
                line = 0
            }
            x += size.width + spacing
            line = max(line, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, width), height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += line + lineSpacing
                x = bounds.minX
                line = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            line = max(line, size.height)
        }
    }
}

/// X's Follow pill, as the library status: "Add" in canvas ink on white until the show is in the
/// library; after that the status in a one-pixel outline, which opens the status menu (X's
/// "Following").
struct ShowFollowPillLabel: View {
    let text: String
    let filled: Bool
    var chevron: Bool = false

    var body: some View {
        HStack(spacing: 6) {
            Text(text)
            if chevron {
                AppGlyph(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
            }
        }
        .type(ThemeType.feedNoteTitle)
        .lineLimit(1)
        .foregroundStyle(filled ? ThemeColor.canvas : ThemeColor.feedText)
        .padding(.horizontal, filled ? ThemeSpace.x5 : ThemeSpace.x4)
        .frame(height: 34)
        .background(filled ? AnyShapeStyle(ThemeGradient.ivory) : AnyShapeStyle(Color.clear), in: Capsule())
        .overlay(Capsule().strokeBorder(filled ? .clear : ThemeColor.feedText.opacity(0.35), lineWidth: FeedMetrics.hairline))
        .frame(minHeight: 44)
        .contentShape(Capsule())
    }
}

/// X's pinned post: "Pinned" over the text column, the show as the author, the post's words, an
/// optional picture, and the post's action. The page composes the words; this is the anatomy.
struct ShowPinnedPost<Media: View, Action: View, Menu: View>: View {
    let franchise: Franchise
    /// The grey after the name — the state, where X prints the handle and the time.
    let detail: String
    let sentence: String
    @ViewBuilder var media: () -> Media
    @ViewBuilder var action: () -> Action
    /// The post's `···` (X's), for the verbs that do not fit a pill.
    @ViewBuilder var menu: () -> Menu

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: FeedMetrics.gap) {
                AppGlyph(systemName: "pin.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: FeedMetrics.avatar, alignment: .trailing)
                Text(Copy.ShowPage.pinned)
                    .type(ThemeType.feedSmall)
                    .fontWeight(.semibold)
            }
            .foregroundStyle(ThemeColor.feedSecondary)
            .padding(.bottom, ThemeSpace.x1)
            .accessibilityHidden(true)
            HStack(alignment: .top, spacing: FeedMetrics.gap) {
                ShowAvatar(franchise: franchise)
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(franchise.displayTitle)
                            .type(ThemeType.feedPostName)
                            .foregroundStyle(ThemeColor.feedText)
                            .lineLimit(1)
                            .layoutPriority(1)
                        if !detail.isEmpty {
                            Text("\u{00B7} \(detail)")
                                .type(ThemeType.feedSubhead)
                                .foregroundStyle(ThemeColor.feedSecondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        menu()
                    }
                    Text(sentence)
                        .type(ThemeType.feedBody)
                        .foregroundStyle(ThemeColor.feedText)
                        .readingLines(FeedPostLayout.lineHeight)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                    media()
                    action()
                }
            }
        }
        .padding(.horizontal, FeedMetrics.inset)
        .padding(.top, FeedMetrics.rowTop)
        .padding(.bottom, FeedMetrics.rowBottom)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(Copy.ShowPage.pinned), \(franchise.title), \(sentence)")
    }
}

/// The loading shape of the profile, at its geometry: the banner, the face and the pill, the name,
/// the bio, the tabs, two posts.
struct ShowProfileSkeleton: View {
    let tint: Color?
    let banner: CGFloat
    let avatar: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            (tint ?? ThemeColor.ambientBackdropFallback)
                .frame(height: banner)
            HStack(alignment: .top) {
                SkeletonBlock(width: avatar, height: avatar, radius: avatar * FeedMetrics.showCornerRatio)
                    .offset(y: -avatar / 2)
                Spacer(minLength: 0)
                SkeletonBlock(width: 104, height: 34, radius: 17)
                    .padding(.top, ThemeSpace.x3)
            }
            .frame(height: avatar / 2 + ThemeSpace.x4, alignment: .top)
            .padding(.horizontal, ThemeMetrics.gutter)
            VStack(alignment: .leading, spacing: ThemeSpace.x2) {
                SkeletonLine(width: 230, height: 20)
                SkeletonLine(width: 180, height: 12)
                SkeletonLine(height: 12).padding(.top, ThemeSpace.x2)
                SkeletonLine(height: 12)
                SkeletonLine(width: 210, height: 12)
                SkeletonLine(width: 150, height: 12).padding(.top, ThemeSpace.x2)
            }
            .padding(.horizontal, ThemeMetrics.gutter)
            SkeletonLine(height: 1)
                .padding(.top, ThemeSpace.x6 + ShowTabsRow.height)
            ForEach(0..<2, id: \.self) { _ in
                HStack(alignment: .top, spacing: FeedMetrics.gap) {
                    SkeletonBlock(width: FeedMetrics.avatar, height: FeedMetrics.avatar,
                                  radius: FeedMetrics.avatar * FeedMetrics.showCornerRatio)
                    VStack(alignment: .leading, spacing: ThemeSpace.x2) {
                        SkeletonLine(width: 170, height: 13)
                        SkeletonLine(height: 12)
                        SkeletonBlock(height: nil, radius: 16).aspectRatio(16 / 9, contentMode: .fit)
                    }
                }
                .padding(.horizontal, FeedMetrics.inset)
                .padding(.top, FeedMetrics.rowTop)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .ignoresSafeArea(edges: .top)
        .accessibilityHidden(true)
    }
}

// MARK: - The show's STAGE (9 Oct — "Home's billboard, continued")

// The show page is Home's billboard, continued (9 Oct: "the Franchise details UX is absolutely
// shit and disconnected with the rest of the amazing app experience", owner —
// design/show-page-2026-10-09/DIRECTION.md): the same stage (`ShowBillboard`) with the page's STATE
// in its lockup (the badge, the logo, "Season 4 · Episode 19 · Aired yesterday", the season bar,
// the ivory mark pill beside the status capsule), then ONE scrolling page under an INDEX that pins
// under the bar — Episodes · Trailers · About · Posts — and scrolls to its section instead of
// swapping content (App Store, Apple Music). The X profile of 25 Sep (banner, face, bio, counts,
// four tabs) put the one action below the fold on every tab and spoke a different language from the
// screen it was opened from; it stays reachable in DEBUG (`-detailDirection profile`) until the
// photographs are approved.

/// Which section is in view — written by the sections' geometry probes, read only by the index row
/// (the app's rule: the scroll offset is never screen state). `current` changes only when a section
/// boundary passes the pin line, so a scroll frame never re-runs the page.
@MainActor @Observable
final class ShowIndexState {
    private(set) var current: ShowTab = .episodes
    @ObservationIgnored var order: [ShowTab] = []
    @ObservationIgnored private var tops: [ShowTab: CGFloat] = [:]

    func reset(order: [ShowTab]) {
        self.order = order
        tops = [:]
        if !order.contains(current), let first = order.first { current = first }
    }

    /// A tap on the index: the underline moves at once; the probes take over as the page lands.
    func select(_ section: ShowTab) {
        if section != current { current = section }
    }

    /// A section's top edge in the window; `threshold` is the pinned index row's bottom edge.
    func track(_ section: ShowTab, top: CGFloat, threshold: CGFloat) {
        tops[section] = top
        var next = order.first ?? section
        for candidate in order {
            if let t = tops[candidate], t <= threshold { next = candidate }
        }
        if next != current { current = next }
    }
}

/// The page's INDEX, in X's tab row anatomy (`ShowTabsRow`): equal slots, the word in `feedTab`,
/// ink for the section in view and grey otherwise, the 3-pt underline gliding to it, one pixel of
/// rule under the row. A tap scrolls to the section; the row never swaps content. The slots sit
/// INSIDE the gutters (19 Oct: "The tab bottom strip sticking to the edge looks weird", owner):
/// five slots edge to edge put "Episodes" at the screen's edge and its underline, 11 pt wider than
/// the word, ran into it. Three slots in the gutters, the underline hugging its word.
struct ShowIndexRow: View {
    let sections: [ShowTab]
    let current: ShowTab
    let onSelect: (ShowTab) -> Void
    @Namespace private var underline
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The index names Trailers where the profile's tab said Media.
    static func title(_ section: ShowTab) -> String {
        section == .media ? Copy.Heading.trailers : section.title
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(sections, id: \.self) { section in
                    Button {
                        onSelect(section)
                    } label: {
                        ZStack(alignment: .bottom) {
                            Text(Self.title(section))
                                .type(ThemeType.feedTab)
                                .foregroundStyle(section == current ? ThemeColor.feedText : ThemeColor.feedSecondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                            if section == current {
                                Text(Self.title(section))
                                    .type(ThemeType.feedTab)
                                    .lineLimit(1)
                                    .fixedSize()
                                    .hidden()
                                    .frame(height: 3)
                                    .overlay(Capsule().fill(ThemeColor.feedText).padding(.horizontal, -4))
                                    .matchedGeometryEffect(id: "underline", in: underline)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .qaIdentifier("qa.detail.section.\(String(describing: section))")
                    .accessibilityAddTraits(section == current ? .isSelected : [])
                    .accessibilityHint(Copy.Accessibility.scrollsToSectionHint)
                }
            }
            .padding(.horizontal, ThemeMetrics.gutter)
            .frame(height: ShowTabsRow.height)
            .animation(ThemeMotion.pick(ThemeMotion.uiSnappy, reduceMotion: reduceMotion), value: current)
            FeedHairline()
        }
        .accessibilityElement(children: .contain)
    }
}

/// The loading shape of the stage page, at its geometry: the billboard's ground at its height, the
/// index row, a section title and three lines.
struct ShowStageSkeleton: View {
    let tint: Color?
    let height: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            (tint ?? ThemeColor.ambientBackdropFallback)
                .frame(height: height)
                .overlay(alignment: .bottom) {
                    VStack(spacing: ThemeSpace.x2) {
                        SkeletonBlock(width: 110, height: 20, radius: 4)
                        SkeletonLine(width: 220, height: 44)
                        SkeletonLine(width: 160, height: 12)
                        SkeletonBlock(width: 190, height: 36, radius: 18)
                            .padding(.top, ThemeSpace.x2)
                    }
                    .padding(.bottom, ThemeSpace.x5)
                }
            SkeletonLine(height: 1)
                .padding(.top, ShowTabsRow.height)
            VStack(alignment: .leading, spacing: ThemeSpace.x2) {
                SkeletonLine(width: 120, height: 20)
                SkeletonLine(height: 12).padding(.top, ThemeSpace.x2)
                SkeletonLine(height: 12)
                SkeletonLine(width: 210, height: 12)
            }
            .padding(.horizontal, ThemeMetrics.gutter)
            .padding(.top, ThemeSpace.x4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .ignoresSafeArea(edges: .top)
        .accessibilityHidden(true)
    }
}

// MARK: - The page's hierarchy (19 Oct)

/// A PART of a show-page section — "Movies & extras" under Episodes, "Cast & crew" under About: the
/// row title's size in the title face, a step under the section's header (`SectionHeaderRow`), so a
/// part never reads as a section of its own (it did: both were the same 20-pt header).
struct ShowSubheader: View {
    let title: String

    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .type(ThemeType.showTitleM)
            .foregroundStyle(ThemeColor.textPrimary)
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

/// About's facts, CALM (20 Oct: "The details part is just shit as if no attention has been paid to
/// it at all!", owner, of `ShowInfoList` — a grey label column, white values and a hairline under
/// every row: a settings form in the middle of the show). Now the FIGURES — premiered, seasons,
/// episodes, the rating — each its small-caps word over its figure ("Nice but invert it", owner,
/// of the figure-over-word first cut), between two hairlines: Profile's counts, read the way a
/// spec sheet is read, name first. The genres follow as Discover's own tiles (`ShowGenreShelf`);
/// the themes and the next airing are not here — TMDB's keywords were the block's noise, and the
/// episode list's next row states the airing. At the accessibility sizes the figures stack.
struct ShowAboutFacts: View {
    struct Figure: Identifiable {
        let value: String
        let word: String
        var id: String { word }
    }

    let figures: [Figure]

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        if !figures.isEmpty {
            Group {
                if typeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: ThemeSpace.x3) {
                        ForEach(figures) { figure($0, alignment: .leading) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    // JUSTIFIED (20 Oct: "Not horizontally centered yet. In fact it's aligned to
                    // nothing, just hanging randomly", owner): equal columns centred a short "A" in
                    // as much room as "PREMIERED", so the run sat left of the page and its first and
                    // last words met neither edge. The first figure starts on the gutter, the last
                    // ends on it, the gaps between are equal, and each rule stands in the middle of
                    // its gap — the run is centred on the page because both its ends are on its edges.
                    HStack(alignment: .center, spacing: 0) {
                        ForEach(Array(figures.enumerated()), id: \.element.id) { i, f in
                            if i > 0 {
                                Spacer(minLength: ThemeSpace.x2)
                                Rectangle().fill(ThemeColor.hairline).frame(width: ThemeMetrics.pixel, height: 36)
                                Spacer(minLength: ThemeSpace.x2)
                            }
                            figure(f, alignment: .center).fixedSize()
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.vertical, ThemeSpace.x4)
            .overlay(alignment: .top) { Rectangle().fill(ThemeColor.hairline).frame(height: ThemeMetrics.pixel) }
            .overlay(alignment: .bottom) { Rectangle().fill(ThemeColor.hairline).frame(height: ThemeMetrics.pixel) }
        }
    }

    private func figure(_ f: Figure, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: ThemeSpace.x1) {
            Text(f.word)
                .type(ThemeType.scheduleCaps)
                .textCase(.uppercase)
                .foregroundStyle(ThemeColor.textTertiary)
                .lineLimit(1)
            Text(f.value)
                .type(ThemeType.showTitleL)
                .foregroundStyle(ThemeColor.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A show's genres as DISCOVER's keys (`server/src/discover/genres.ts`, mirrored): source-aware —
/// an anime joins a key through its AniList names, a TV show through its TMDB names, where one
/// name can feed two keys ("Sci-Fi & Fantasy" is Sci-Fi and Fantasy). Names the catalogue never
/// browses (Ecchi, Soap, Talk…) have no key and are dropped. The show's own order, no repeats.
enum ShowGenres {
    struct Genre: Identifiable, Equatable {
        let key: String
        let name: String
        var id: String { key }
    }

    private static let table: [(key: String, name: String, anilist: [String], tmdb: [String])] = [
        ("action", "Action", ["Action"], ["Action & Adventure"]),
        ("adventure", "Adventure", ["Adventure"], ["Action & Adventure"]),
        ("comedy", "Comedy", ["Comedy"], ["Comedy"]),
        ("drama", "Drama", ["Drama"], ["Drama"]),
        ("fantasy", "Fantasy", ["Fantasy"], ["Sci-Fi & Fantasy"]),
        ("sci-fi", "Sci-Fi", ["Sci-Fi"], ["Sci-Fi & Fantasy"]),
        ("mystery", "Mystery", ["Mystery"], ["Mystery"]),
        ("romance", "Romance", ["Romance"], []),
        ("horror", "Horror", ["Horror"], []),
        ("thriller", "Thriller", ["Thriller"], []),
        ("psychological", "Psychological", ["Psychological"], []),
        ("supernatural", "Supernatural", ["Supernatural"], []),
        ("slice-of-life", "Slice of Life", ["Slice of Life"], []),
        ("sports", "Sports", ["Sports"], []),
        ("mecha", "Mecha", ["Mecha"], []),
        ("music", "Music", ["Music"], []),
        ("mahou-shoujo", "Mahou Shoujo", ["Mahou Shoujo"], []),
        ("crime", "Crime", [], ["Crime"]),
        ("documentary", "Documentary", [], ["Documentary"]),
        ("family", "Family", [], ["Family", "Kids"]),
        ("reality", "Reality", [], ["Reality"]),
        ("war-politics", "War & Politics", [], ["War & Politics"]),
        ("western", "Western", [], ["Western"]),
        ("animation", "Animation", [], ["Animation"]),
    ]

    static func of(_ f: Franchise) -> [Genre] {
        let names = (f.genres + f.parts.flatMap(\.genres))
            .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        var out: [Genre] = []
        for name in names {
            for def in table where (f.source == .tmdb ? def.tmdb : def.anilist).contains(name) {
                if !out.contains(where: { $0.key == def.key }) { out.append(Genre(key: def.key, name: def.name)) }
            }
        }
        return out
    }
}

/// About's genres as a shelf of DISCOVER's genre tiles (`GenreTile`: the genre's own duotone art in
/// the show's flavour, the name at its foot), each opening that genre's page — the genres were a
/// comma run beside a label, then a wrap of mixed capsules ("the genres UX is poorly built.
/// Direction isn't totally bad but build it abysmal", owner, 20 Oct). One line that scrolls, never
/// a ragged wrap; the same picture a reader meets in Discover, so a genre looks like itself.
struct ShowGenreShelf: View {
    let genres: [ShowGenres.Genre]
    let flavour: GenreArt.Flavour
    let onOpen: (ShowGenres.Genre) -> Void

    @Environment(\.dynamicTypeSize) private var typeSize

    /// Smaller than Discover's half-width tile, so two and a half sit across and the shelf says
    /// it scrolls; at the accessibility sizes, wide enough for the name.
    private var width: CGFloat { typeSize.isAccessibilitySize ? 220 : 148 }

    var body: some View {
        if !genres.isEmpty {
            ScrollView(.horizontal) {
                LazyHStack(spacing: ThemeSpace.x3) {
                    ForEach(genres) { g in
                        Button { onOpen(g) } label: {
                            ShowGenreCard(key: g.key, name: g.name, flavour: flavour, width: width)
                        }
                        .buttonStyle(OverArtPressStyle())
                        .accessibilityLabel(g.name)
                        .accessibilityHint(Copy.ShowPage.opensGenreHint)
                    }
                }
                .padding(.horizontal, ThemeMetrics.gutter)
            }
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
            // The section sits inside the page gutter; the shelf runs edge to edge.
            .padding(.horizontal, -ThemeMetrics.gutter)
        }
    }
}

/// One genre on a show's About: Discover's art for it (`GenreArt`, the show's flavour), built as a
/// CONTROL in the app's materials rather than pasted in (20 Oct: "the Genre cards look poorly
/// built", owner, of Discover's `GenreTile` dropped onto the page — three flat, fully saturated
/// fields with 17-pt names, the loudest thing on a page made quiet, with no edge and no depth).
/// The picture is held down — a shade of the canvas over it, deepening toward the name so the
/// colour stays a hue and the words sit on a ground of their own — and the card is lit from above
/// with the one-pixel edge every raised control wears (`ThemeGradient.litEdge`), casting a soft
/// shadow from its shape. The name is the title face a step under Discover's.
struct ShowGenreCard: View {
    let key: String
    let name: String
    let flavour: GenreArt.Flavour
    let width: CGFloat

    static let aspect: CGFloat = 16 / 9
    static let radius: CGFloat = ThemeRadius.poster

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
        let height = (width / Self.aspect).rounded()
        ZStack(alignment: .bottomLeading) {
            if let art = GenreArt.image(key, flavour: flavour) {
                Image(uiImage: art)
                    .resizable()
                    .scaledToFill()
                    .frame(width: width, height: height)
                    .accessibilityHidden(true)
            } else {
                ThemeColor.surfaceRaised
            }
            // The canvas over the picture: a breath at the top, most of the way to the ground at
            // the foot, so a red or a green reads as the genre's colour, not a slab of it.
            LinearGradient(stops: [.init(color: ThemeColor.canvas.opacity(0.22), location: 0),
                                   .init(color: ThemeColor.canvas.opacity(0.34), location: 0.45),
                                   .init(color: ThemeColor.canvas.opacity(0.78), location: 1)],
                           startPoint: .top, endPoint: .bottom)
            Text(name)
                .type(ThemeType.genreCardName)
                .foregroundStyle(ThemeColor.textPrimary)
                .lineLimit(name.contains(" ") ? 2 : 1)
                .minimumScaleFactor(0.8)
                .multilineTextAlignment(.leading)
                .padding(.horizontal, ThemeSpace.x3)
                .padding(.bottom, ThemeSpace.x3 - 2)
        }
        .frame(width: width, height: height)
        .clipShape(shape)
        .overlay(shape.strokeBorder(ThemeGradient.litEdge, lineWidth: 1))
        .cardShadow(.art, shape: shape, fill: ThemeColor.canvas)
        .contentShape(shape)
    }
}

/// The stage's two pills — the mark (or Start watching, Start rewatch, Add) and the status — in
/// ONE geometry (20 Oct: "Mark as Watched CTA and Watching CTAs don't have the same core
/// dimensions? Why? It looks so visually weird", owner): the mark was Schedule's pill (36 pt and a
/// glyph) beside the profile's 34-pt Follow pill, an outline that reads smaller again beside a
/// fill. Now both are 40 pt in a 44-pt target, one type, one padding; the second is a fill of the
/// page's light with a crisp edge (the season pill's material), so the pair has one mass.
struct StagePillLabel: View {
    let text: String
    var glyph: String? = nil
    let filled: Bool
    var chevron: Bool = false

    static let height: CGFloat = 40

    var body: some View {
        HStack(spacing: 6) {
            if let glyph {
                AppGlyph(systemName: glyph).font(.system(size: 13, weight: .bold))
            }
            Text(text)
            if chevron {
                AppGlyph(systemName: "chevron.down").font(.system(size: 10, weight: .bold))
            }
        }
        .type(ThemeType.feedNoteTitle)
        .lineLimit(1)
        .fixedSize()
        .foregroundStyle(filled ? ThemeColor.canvas : ThemeColor.textPrimary)
        .padding(.horizontal, ThemeSpace.x5)
        .frame(height: Self.height)
        .background(filled ? AnyShapeStyle(ThemeGradient.ivory) : AnyShapeStyle(ThemeColor.textPrimary.opacity(0.12)),
                    in: Capsule())
        .overlay(Capsule().strokeBorder(filled ? AnyShapeStyle(Color.clear) : AnyShapeStyle(ThemeGradient.litEdge),
                                        lineWidth: 1))
        .frame(minHeight: 44)
        .contentShape(Capsule())
    }
}

/// About's facts as a labelled list — the App Store's Information block: each fact under its name
/// in a column of its own, one hairline between rows, so a reader looking for the seasons or the
/// next episode finds the word, not a middot run. At the accessibility sizes the name sits above
/// its value.
struct ShowInfoList: View {
    struct Row: Identifiable {
        let label: String
        let value: String
        var id: String { label }
    }

    let rows: [Row]

    @Environment(\.dynamicTypeSize) private var typeSize

    static let labelColumn: CGFloat = 108

    var body: some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { i, r in
                    if i > 0 {
                        Rectangle().fill(ThemeColor.hairline).frame(height: ThemeMetrics.pixel)
                    }
                    Group {
                        if typeSize.isAccessibilitySize {
                            VStack(alignment: .leading, spacing: ThemeSpace.x1) { label(r); value(r) }
                        } else {
                            HStack(alignment: .firstTextBaseline, spacing: ThemeSpace.x3) {
                                label(r).frame(width: Self.labelColumn, alignment: .leading)
                                value(r)
                            }
                        }
                    }
                    .padding(.vertical, ThemeSpace.x3)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private func label(_ r: Row) -> some View {
        Text(r.label)
            .type(ThemeType.metadata)
            .foregroundStyle(ThemeColor.textTertiary)
            .lineLimit(1)
    }

    private func value(_ r: Row) -> some View {
        Text(r.value)
            .type(ThemeType.callout)
            .foregroundStyle(ThemeColor.textPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A section's header fades out as it rises toward the pinned index (19 Oct): the index already
/// says which section this is, so the two words never stand stacked — a jump from the index lands
/// with the header under the row, and a scroll brings it in only where it divides two sections.
/// Read in the render pass (`visualEffect`): no body re-runs on scroll.
struct UnderIndexFade: ViewModifier {
    /// The pinned index's foot, in the window.
    let foot: CGFloat

    /// Gone until its foot is this far under the index's…
    private static let clear: CGFloat = 16
    /// …whole this much further down.
    private static let ramp: CGFloat = 20

    func body(content: Content) -> some View {
        let foot = foot, clear = Self.clear, ramp = Self.ramp
        return content.visualEffect { c, proxy in
            let below = proxy.frame(in: .global).maxY - foot - clear
            return c.opacity(Double(min(1, max(0, below / ramp))))
        }
    }
}
