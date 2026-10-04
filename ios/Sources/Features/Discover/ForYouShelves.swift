import SwiftUI

// Discover's For you — Netflix's home (25 Sep). "Discover's For you section is extremely poorly
// built. I just don't like it at all" (owner) — of the Instagram wall it replaced: an anonymous grid
// of cropped posters, no names, the reason on one tile in six. Three directions were built on the
// owner's own recommendations and photographed side by side (a Today-style feed of recommendation
// posts; X's "Who to follow" rows; Netflix shelves), and the owner chose the SHELVES:
//   · the TOP PICK as one big card — the poster whole, the show's own logo, what it is, why it is
//     here, "Add to Planned" and "Details" side by side (Netflix's hero card);
//   · a shelf per show of yours the rest come from ("Because you're watching Re:ZERO"), posters
//     with their names, the add disc on the art and the long-press answers (`ForYouMenu`);
//   · "Trending now" last, so a library with little to go on still opens on something.
// The order is the server's (the ranker is the recommendations' — never re-ranked here).

// MARK: - Grouping

/// The recommendations grouped by the show of yours they come from (the reason's first seed), in
/// the server's order: a group sits where its best title ranks. Seeds with one title each fold into
/// "More for you" at the end.
struct ForYouGroup: Identifiable {
    let seed: RecommendationItem.Seed?
    let kind: RecommendationItem.Reason.Kind
    var items: [RecommendationItem]
    var id: String { seed?.franchiseId ?? "more" }

    static func build(_ recs: [RecommendationItem], reason: (RecommendationItem) -> RecommendationItem.Reason,
                      minimum: Int = 2, limit: Int = 6) -> [ForYouGroup] {
        var order: [String] = []
        var groups: [String: ForYouGroup] = [:]
        var rest: [RecommendationItem] = []
        for r in recs {
            let why = reason(r)
            guard let seed = why.seeds.first, why.kind != .world else { rest.append(r); continue }
            if groups[seed.franchiseId] == nil {
                order.append(seed.franchiseId)
                groups[seed.franchiseId] = ForYouGroup(seed: seed, kind: why.kind, items: [])
            }
            groups[seed.franchiseId]?.items.append(r)
        }
        var out: [ForYouGroup] = []
        for id in order {
            guard let g = groups[id] else { continue }
            if g.items.count >= minimum, out.count < limit { out.append(g) } else { rest.append(contentsOf: g.items) }
        }
        if !rest.isEmpty { out.append(ForYouGroup(seed: nil, kind: .consensus, items: rest)) }
        return out
    }

    /// "Because you're watching Re:ZERO", "Because you watched Frieren", "More like One Piece".
    var title: String {
        guard let seed else { return Copy.ForYou.moreForYou }
        let name = seed.title.shelfShortened
        switch kind {
        case .watching, .started: return Copy.ForYou.becauseWatching(name)
        case .watched, .finished: return Copy.ForYou.becauseWatched(name)
        default: return Copy.ForYou.moreLike(name)
        }
    }
}

extension RecommendationItem {
    /// "Anime · 2019 · Action · Fantasy" — what it is, when, two genres.
    var factsLine: String {
        var bits = [source.kindLead].compactMap { $0 }
        if let year { bits.append(String(year)) }
        bits += genres.prefix(2)
        return bits.joined(separator: " \u{00B7} ")
    }

    /// The tile's one fact — as short as the Library card's ("Anime · 2019"): the two genres wrapped
    /// the grey line to a second row, so For you's cards stood taller than the Library's.
    var tileFacts: String { [source.kindLead, year.map(String.init)].compactMap { $0 }.joined(separator: " \u{00B7} ") }

    var posterURL: String? { stub?.tilePoster.url ?? images?.portrait }
}

// MARK: - The page

struct ForYouShelves: View {
    /// In the scope, best first.
    let recommendations: [RecommendationItem]
    let trending: [FranchiseSummary]
    let reason: (RecommendationItem) -> RecommendationItem.Reason
    /// A trending show as VoiceOver says it.
    let spoken: (FranchiseSummary) -> String
    /// A trending show's add control, on its poster (the search results' `AddControl(.overArt)`).
    let trendAdd: (FranchiseSummary) -> AnyView
    let onOpenRecommendation: (RecommendationItem) -> Void
    let onOpenShow: (FranchiseSummary) -> Void
    /// Under the top pick, never over it (the notification primer after an add): above it, it put
    /// the card's buttons under the tab bar on the first screen.
    var afterTopPick: AnyView? = nil

    /// The Library shelf's card width, so a poster is the same size on both tabs.
    static func tileWidth(_ typeSize: DynamicTypeSize) -> CGFloat { typeSize.isAccessibilitySize ? 210 : 150 }
    private static let trendingLimit = 20

    var body: some View {
        let lead = recommendations.first(where: \.hasBillboardArt) ?? recommendations.first
        let groups = ForYouGroup.build(recommendations.filter { $0.key != lead?.key }, reason: reason)
        let recommended = Set(recommendations.compactMap(\.franchiseId))
        let trend = Array(trending.filter { !recommended.contains($0.id) }.prefix(Self.trendingLimit))
        VStack(alignment: .leading, spacing: ThemeSpace.x8) {
            if let lead {
                ForYouTopPick(item: lead, reason: reason(lead)) { onOpenRecommendation(lead) }
            }
            if let afterTopPick { afterTopPick }
            ForEach(groups) { g in
                shelf(g.title) {
                    ForEach(g.items) { r in
                        ForYouShelfTile(item: r, reason: reason(r)) { onOpenRecommendation(r) }
                    }
                }
            }
            if !trend.isEmpty {
                shelf(Copy.Search.trendingNow) {
                    ForEach(trend) { s in
                        TrendingShelfTile(item: s, spoken: spoken(s), add: trendAdd(s)) { onOpenShow(s) }
                    }
                }
            }
        }
        .padding(.top, ThemeSpace.x4)
        .padding(.bottom, ThemeSpace.x4)
    }

    private func shelf<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: ThemeMetrics.labelGap) {
            Text(title)
                .type(ThemeType.sectionTitle)
                .foregroundStyle(ThemeColor.textPrimary)
                .lineLimit(1)
                .padding(.horizontal, ThemeMetrics.gutter)
                .accessibilityAddTraits(.isHeader)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: ThemeMetrics.shelfGap) {
                    content()
                }
                .scrollTargetLayout()
            }
            .contentMargins(.horizontal, ThemeMetrics.gutter, for: .scrollContent)
            .scrollTargetBehavior(.viewAligned)
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
        }
    }
}

// MARK: - The top pick

/// Netflix's hero card: the poster whole to the card's edges, and at its foot the show's own logo
/// (its name in type where it has none; nothing where the poster already prints it), what it is,
/// why it is here, then "Add to Planned" and "Details" side by side.
struct ForYouTopPick: View {
    let item: RecommendationItem
    let reason: RecommendationItem.Reason
    let onOpen: () -> Void

    @Environment(AppModel.self) private var appModel

    private static let aspect: CGFloat = 1.32

    var body: some View {
        let width = ThemeMetrics.windowWidth - 2 * ThemeMetrics.gutter
        let height = (width * Self.aspect).rounded()
        let shape = RoundedRectangle(cornerRadius: ThemeRadius.card, style: .continuous)
        ZStack(alignment: .bottom) {
            Button(action: onOpen) {
                RemoteImageView(url: item.stub?.billboardArt.url ?? item.posterURL, contentMode: .fill,
                                maxPixel: 1400, alignment: .top, placeholderHidden: true)
                    .frame(width: width, height: height)
                    .clipped()
                    .overlay {
                        LinearGradient(stops: [
                            .init(color: .clear, location: 0.42),
                            .init(color: .black.opacity(0.5), location: 0.66),
                            .init(color: .black.opacity(0.9), location: 1),
                        ], startPoint: .top, endPoint: .bottom)
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(item.displayTitle), \(Copy.ForYou.reasonList(reason))")
            .accessibilityHint(Copy.Accessibility.opensTheShowHint)
            VStack(spacing: ThemeSpace.x2) {
                name
                Text(item.factsLine)
                    .type(ThemeType.metadata)
                    .foregroundStyle(ThemeColor.textPrimary.opacity(0.86))
                    .lineLimit(1)
                Text(Copy.ForYou.reason(reason))
                    .type(ThemeType.caption)
                    .foregroundStyle(ThemeColor.textPrimary.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                buttons
                    .padding(.top, ThemeSpace.x2)
            }
            .padding(.horizontal, ThemeSpace.x4)
            .padding(.bottom, ThemeSpace.x4)
            .accessibilityElement(children: .contain)
        }
        .frame(width: width, height: height)
        .clipShape(shape)
        .overlay(shape.strokeBorder(ThemeColor.posterEdge, lineWidth: 1))
        .cardShadow(.art, shape: shape)
        .contextMenu { ForYouMenu(item: item, reason: reason, onOpen: onOpen) }
        .padding(.horizontal, ThemeMetrics.gutter)
    }

    /// The show's logo, else its name in type. A NAME IS ALWAYS DRAWN (the billboards' rule): an
    /// AniList cover is taken as printing its title whenever no textless poster is known, and the
    /// card's foot covers where such a title sits — the first cut, trusting that, named nothing.
    @ViewBuilder
    private var name: some View {
        let billboardName = item.stub?.billboardName ?? .type
        switch billboardName {
        case .logo where billboardName.hasGraphicLogo:
            ArtworkLogo(name: billboardName, title: item.displayTitle, height: 76)
                .padding(.horizontal, ThemeSpace.x8)
        default:
            Text(item.tileTitle)
                .type(ThemeType.displayL)
                .foregroundStyle(ThemeColor.textPrimary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
        }
    }

    private var buttons: some View {
        let owned = appModel.isOwned(item)
        return HStack(spacing: ThemeSpace.x3) {
            Button { if !owned { appModel.addRecommendation(item) } } label: {
                AppGlyphLabel(owned ? Copy.ForYou.addedToPlanned : Copy.ForYou.addToPlanned, systemName: owned ? "checkmark" : "plus")
                    .type(ThemeType.bodyEmphasis)
                    .foregroundStyle(owned ? ThemeColor.textPrimary : ThemeColor.canvas)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(owned ? AnyShapeStyle(ThemeColor.textPrimary.opacity(0.2)) : AnyShapeStyle(ThemeGradient.ivory), in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(FeedIconPressStyle())
            .accessibilityHint(owned ? "" : Copy.ForYou.addHint)
            Button(action: onOpen) {
                AppGlyphLabel(Copy.ForYou.details, systemName: "info.circle")
                    .type(ThemeType.bodyEmphasis)
                    .foregroundStyle(ThemeColor.textPrimary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(ThemeColor.textPrimary.opacity(0.2), in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(FeedIconPressStyle())
        }
    }
}

// MARK: - The tiles

/// A recommendation on a shelf: the poster, its name and what it is; the add disc on the art (the
/// amber check once it is yours), the long-press answers ("Not interested", "Already seen").
struct ForYouShelfTile: View {
    let item: RecommendationItem
    let reason: RecommendationItem.Reason
    let onOpen: () -> Void

    @Environment(AppModel.self) private var appModel

    var body: some View {
        let owned = appModel.isOwned(item)
        ShelfPosterTile(poster: item.posterURL, name: item.stub?.tilePoster.name ?? .type, title: item.tileTitle, facts: item.tileFacts,
                        accessibilityLabel: "\(item.displayTitle), \(Copy.ForYou.reasonList(reason))",
                        onOpen: onOpen) {
            if owned {
                OwnedMark().padding(ThemeSpace.x2).allowsHitTesting(false)
            } else {
                TileAddDisc(label: "\(Copy.ForYou.addToPlanned), \(item.displayTitle)") { appModel.addRecommendation(item) }
            }
        }
        .contextMenu { ForYouMenu(item: item, reason: reason, onOpen: onOpen) }
        .overlay {
            if appModel.resolvingRecommendations.contains(item.key) {
                ProgressView().tint(ThemeColor.textPrimary)
                    .padding(ThemeSpace.x3)
                    .background(ThemeColor.scrimStrong, in: Circle())
                    .allowsHitTesting(false)
            }
        }
    }
}

/// A trending show on the last shelf — the same tile, its add control the search results'.
struct TrendingShelfTile: View {
    let item: FranchiseSummary
    let spoken: String
    let add: AnyView
    let onOpen: () -> Void

    var body: some View {
        let facts = [item.source.kindLead, item.year.map(String.init)].compactMap { $0 }.joined(separator: " \u{00B7} ")
        ShelfPosterTile(poster: item.tilePoster.url ?? item.portraitArt, name: item.tilePoster.name, title: item.title.shelfShortened(fitting: 26),
                        facts: facts, accessibilityLabel: spoken, onOpen: onOpen) {
            add
        }
    }
}

/// The shelf's tile IS the Library's poster card (26 Sep: "the poster cards in Discover → For You
/// should be identical to what is in the Library", owner): `ArtworkPoster` at the Library shelf's
/// 150 pt (210 at the accessibility sizes), the art whole in a 2:3 frame with its hairline edge and
/// contact shadow, the name and one fact under it (`PosterCaptionText`). The corner control rides
/// the poster as the card's `cornerMark` — above its open target, never inside it — and moves to
/// the art's foot where the poster prints its title up top, as the Library's does.
struct ShelfPosterTile<Corner: View>: View {
    let poster: String?
    var name: BillboardName = .type
    let title: String
    let facts: String
    let accessibilityLabel: String
    let onOpen: () -> Void
    @ViewBuilder var corner: () -> Corner

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        ArtworkPoster(url: poster, name: name, title: title, detailsInBand: true,
                      cornerMark: AnyView(corner()), fixedAspect: 2.0 / 3.0, onOpen: onOpen,
                      openLabel: accessibilityLabel) {
            PosterCaptionText(title: title, fact: facts)
        }
        .frame(width: ForYouShelves.tileWidth(typeSize))
    }
}
