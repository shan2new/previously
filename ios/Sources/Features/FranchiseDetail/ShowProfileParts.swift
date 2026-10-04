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

    var title: String {
        switch self {
        case .posts: return Copy.ShowPage.posts
        case .episodes: return Copy.Heading.episodes
        case .media: return Copy.ShowPage.media
        case .about: return Copy.ShowPage.about
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
                ForEach(ShowTab.allCases, id: \.self) { tab in
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
                                    .overlay(Capsule().fill(ThemeColor.feedText).padding(.horizontal, -11))
                                    .matchedGeometryEffect(id: "underline", in: underline)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
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
