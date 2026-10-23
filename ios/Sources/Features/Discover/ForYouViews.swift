import SwiftUI

// "Recommended for you" — the views Today's shelf and the full list share: the poster TILE, its
// long-press MENU, the + disc, and the list itself (`RecommendationsView`, the shelf's "See all").
// The model half is `AppModel+Recommendations.swift`; the order is the server's.

/// A recommendation as a poster: the show's own key art whole, the NAME (an AniList cover often
/// prints none — the first cut drew Hunter x Hunter captioned only "Like Jujutsu Kaisen"), then
/// WHY in the longest form that fits ("Like Jujutsu Kaisen and 2 more" → "Like Jujutsu Kaisen"),
/// an "AIRING" tag on the art for a title on air, and + to add it to Planned (the amber check once
/// it is yours — both placed clear of the title the poster prints).
struct ForYouTile: View {
    let item: RecommendationItem
    /// The reason as the screen wants it said (`AppModel.spokenReason`, Today reorders its seeds).
    let reason: RecommendationItem.Reason
    let width: CGFloat
    /// Whether the band holds a second NAME line — only when a tile on this shelf needs one, or
    /// one-line names sat over ~34 pt of empty plate (review i5, U-N13; `ForYouShelf.needsTwoLines`).
    var reserveTwoNameLines: Bool = true
    let onOpen: () -> Void

    @Environment(AppModel.self) private var appModel
    @Environment(\.dynamicTypeSize) private var typeSize
    private var isAX: Bool { typeSize.isAccessibilitySize }

    var body: some View {
        let r = item
        let owned = appModel.isOwned(r)
        let poster = r.stub?.tilePoster
        let reasons = Copy.ForYou.tileReasons(reason)
        ArtworkPoster(url: poster?.url ?? r.images?.portrait, name: poster?.name ?? .type, title: r.displayTitle,
                      detailInset: ThemeSpace.x2,
                      detailsInBand: true,
                      artLabel: r.airing ? Copy.ForYou.airing : nil,
                      cornerMark: owned
                        ? AnyView(OwnedMark().padding(ThemeSpace.x2).allowsHitTesting(false))
                        : AnyView(TileAddDisc(label: "\(Copy.ForYou.addToPlanned), \(r.displayTitle)") { appModel.addRecommendation(r) }),
                      fixedAspect: 2.0 / 3.0,
                      onOpen: onOpen) {
            // The band is reserved for a two-line name, but the reason HUGS the name (a one-line
            // name does not leave a hole above its reason); the spare room is under. Grey — never
            // amber, never truncated mid-name while a shorter form fits (`tileReasons`).
            // Under the picture on the canvas (`PosterCaption.style == .below`, 24 Sep): the name,
            // then why — left on the tile's axis, nothing reserved (no plate to keep level).
            if PosterCaption.style != .band {
                VStack(alignment: PosterCaption.alignment, spacing: 2) {
                    Text(r.tileTitle.shelfShortened(fitting: 26))
                        .type(ThemeType.shelfTitle)
                        .foregroundStyle(ThemeColor.textPrimary)
                        .lineLimit(isAX ? 5 : 2)
                        .allowsTightening(true)
                        .fixedSize(horizontal: false, vertical: true)
                    Group {
                        if isAX {
                            Text(reasons.last ?? "").lineLimit(3).fixedSize(horizontal: false, vertical: true)
                        } else {
                            ViewThatFits(in: .horizontal) {
                                ForEach(Array(reasons.enumerated()), id: \.offset) { _, line in
                                    Text(line).lineLimit(1).allowsTightening(true)
                                }
                            }
                        }
                    }
                    .type(ThemeType.caption)
                    .foregroundStyle(ThemeColor.textSecondary)
                }
                .multilineTextAlignment(PosterCaption.textAlignment)
                .frame(maxWidth: .infinity, alignment: PosterCaption.style == .below ? .leading : .center)
            } else {
            // No typed name under a graphic LOGO — the logo on the art names the show already.
            let typedName = !(poster?.name.hasGraphicLogo ?? false)
            ZStack(alignment: .top) {
                if !isAX {
                    VStack(spacing: 2) {
                        if typedName {
                            Text(reserveTwoNameLines ? "A\nA" : "A").type(ThemeType.shelfTitle).lineLimit(2)
                        }
                        Text("A").type(ThemeType.caption)
                    }
                    .hidden()
                    .accessibilityHidden(true)
                }
                VStack(spacing: 2) {
                    // ONE size along the shelf: no scale factor on the name or the reason — a
                    // scaled last-resort reason sat at 0.87× beside its neighbours (review i5,
                    // U-N9); a line that cannot fit ends at a word's ellipsis.
                    if typedName {
                        Text(r.tileTitle.shelfShortened(fitting: 26))
                            .type(ThemeType.shelfTitle)
                            .foregroundStyle(ThemeColor.textPrimary)
                            .lineLimit(isAX ? 5 : 2)
                            .allowsTightening(true)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Group {
                        if isAX {
                            Text(reasons.last ?? "").lineLimit(3).fixedSize(horizontal: false, vertical: true)
                        } else {
                            ViewThatFits(in: .horizontal) {
                                ForEach(Array(reasons.enumerated()), id: \.offset) { _, line in
                                    Text(line).lineLimit(1).allowsTightening(true)
                                }
                            }
                        }
                    }
                    .type(ThemeType.caption)
                    .foregroundStyle(ThemeColor.textSecondary)
                }
            }
            .multilineTextAlignment(.center)
            }
        }
        .overlay {
            if appModel.resolvingRecommendations.contains(r.key) {
                ProgressView().tint(ThemeColor.textPrimary)
                    .padding(ThemeSpace.x3)
                    .background(ThemeColor.scrimStrong, in: Circle())
                    .allowsHitTesting(false)
            }
        }
        .frame(width: width)
        .zoomSource("foryou/\(r.key)")
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(r.displayTitle), \(Copy.ForYou.reasonList(reason))")
        .accessibilityHint(Copy.Accessibility.opensTheShowHint)
        .contextMenu { ForYouMenu(item: r, reason: reason, onOpen: onOpen) }
        .modifier(RecommendationImpression(key: r.key))
    }
}

/// The long press: WHY in full, then the three answers a recommendation can get.
struct ForYouMenu: View {
    let item: RecommendationItem
    let reason: RecommendationItem.Reason
    /// Opens the title's page (the tile's own tap).
    var onOpen: (() -> Void)? = nil

    @Environment(AppModel.self) private var appModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Section(Copy.ForYou.reasonList(reason)) {
            if let id = appModel.showId(of: item), let owned = appModel.franchise(id: id) {
                // Yours now (added from the tile): the one answer left is to take it back —
                // "I've watched it" did nothing and "Not interested" dismissed a show on your
                // Planned list (review i5, N10).
                Button(role: .destructive) { appModel.removeWithUndo(owned, reduceMotion: reduceMotion) } label: {
                    AppGlyphLabel(Copy.ForYou.removeFromPlanned, systemName: "minus.circle")
                }
            } else {
                Button { appModel.addRecommendation(item) } label: {
                    AppGlyphLabel(Copy.ForYou.addToPlanned, systemName: "plus")
                }
                // Seen it elsewhere: the app's own series mark, on the title's page — the count,
                // Cancel and one Undo every series mark has; it joins the library as Watched and
                // becomes a show the next list learns from (review i5: from the long press it
                // marked a 148-episode run with no question).
                if let onOpen {
                    Button {
                        Task {
                            guard let id = await appModel.franchiseId(for: item) else { return }
                            appModel.pendingSeriesPrompt = id
                            onOpen()
                        }
                    } label: {
                        AppGlyphLabel(Copy.Action.markSeriesWatched, systemName: "checkmark.circle")
                    }
                }
                // Reversible (the lane's Undo), so not the destructive red Remove wears.
                Button { appModel.hideRecommendation(item, seen: false) } label: {
                    AppGlyphLabel(Copy.ForYou.notInterested, systemName: "hand.thumbsdown")
                }
            }
        }
    }
}

/// The + on a poster tile's corner: a 26-pt disc on the art's scrim in a 44-pt target, pulled into
/// the corner (Today's For you and first-run trending tiles). Its receipt is the add's own; once
/// the show is yours, the tile draws `OwnedMark` in its place.
struct TileAddDisc: View {
    let label: String
    let action: () -> Void

    /// Grows with the type, like `OwnedMark`: a fixed 26-pt disc sat beside ~26-pt capitals at
    /// AX-XL (review i5, U-N11).
    @ScaledMetric(relativeTo: .caption) private var disc: CGFloat = 26

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(ThemeColor.scrimStrong)
                Circle().strokeBorder(ThemeColor.posterEdge, lineWidth: FeedMetrics.hairline)
                AppGlyph(systemName: "plus")
                    .font(.system(size: disc * 0.46, weight: .bold))
                    .foregroundStyle(ThemeColor.textPrimary)
            }
            .frame(width: disc, height: disc)
            .frame(width: max(44, disc + 12), height: max(44, disc + 12))
            .contentShape(Circle())
        }
        .buttonStyle(OverArtPressStyle())
        .padding(-ThemeSpace.x1)
        .accessibilityLabel(label)
    }
}

/// The "Recommended for you" SHELF — Today's (after Up next, above Planned) and Search's (above
/// Trending, the tab people open to find something): the poster wall, a skeleton while the first
/// list is on its way, and at the accessibility sizes five rows plus "Show more" (at AX-XL a
/// 124-pt poster's band broke "Like Chainsaw" / "Man"). The header opens the longer list.
struct ForYouShelf: View {
    let items: [RecommendationItem]
    var loading: Bool = false
    /// The reason as this screen says it (Today names the seed that fits its moment).
    let reason: (RecommendationItem) -> RecommendationItem.Reason
    let onOpen: (RecommendationItem) -> Void
    var onSeeAll: (() -> Void)? = nil

    @Environment(AppModel.self) private var appModel
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var rowsShown = 5

    var body: some View {
        if typeSize.isAccessibilitySize, !items.isEmpty {
            rows
        } else {
            wall
        }
    }

    private var rows: some View {
        let shown = Array(items.prefix(rowsShown))
        return VStack(alignment: .leading, spacing: ThemeMetrics.labelGap) {
            SectionHeaderRow(Copy.ForYou.shelf, action: onSeeAll)
            VStack(spacing: 0) {
                ForEach(Array(shown.enumerated()), id: \.element.id) { i, r in
                    ForYouRow(item: r, reason: reason(r), separator: i < shown.count - 1) { onOpen(r) }
                }
                if items.count > shown.count {
                    Button(Copy.ForYou.showMore) {
                        withAnimation(ThemeMotion.pick(ThemeMotion.uiGentle, reduceMotion: reduceMotion)) {
                            rowsShown += 5
                        }
                    }
                    .buttonStyle(InlineLinkButtonStyle())
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.horizontal, ThemeMetrics.gutter)
    }

    private var wall: some View {
        VStack(alignment: .leading, spacing: ThemeMetrics.labelGap) {
            SectionHeaderRow(Copy.ForYou.shelf, action: items.isEmpty ? nil : onSeeAll)
                .padding(.horizontal, ThemeMetrics.gutter)
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: ThemeMetrics.shelfGap) {
                    if items.isEmpty, loading {
                        ForEach(0..<4, id: \.self) { _ in
                            // The tile's real height (2:3 art + the two-line name + the reason
                            // band), so nothing jumps when the list lands.
                            SkeletonBlock(height: PosterSize.shelfLarge.size.height + 72, radius: ThemeRadius.poster)
                                .frame(width: PosterSize.shelfLarge.size.width)
                        }
                    }
                    let twoLines = Self.needsTwoLines(items)
                    ForEach(items) { r in
                        ForYouTile(item: r, reason: reason(r), width: PosterSize.shelfLarge.size.width,
                                   reserveTwoNameLines: twoLines) { onOpen(r) }
                            .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    }
                }
                // Every tile carries a mark (+ or the check): one corner for the whole shelf.
                .environment(\.cornerRow, CornerRow(urls: items.compactMap { $0.stub?.tilePoster.url ?? $0.images?.portrait }))
                .padding(.horizontal, ThemeMetrics.gutter)
                .padding(.vertical, ThemeSpace.x1)
            }
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
            .animation(ThemeMotion.pick(ThemeMotion.uiGentle, reduceMotion: reduceMotion), value: items.map(\.key))
        }
    }
}

extension ForYouShelf {
    /// Whether any name on a shelf can need a second line in a 108-pt band (~15 characters of
    /// `shelfTitle` a line) — one card height along the row either way.
    static func needsTwoLines(_ items: [RecommendationItem]) -> Bool {
        items.contains { $0.tileTitle.shelfShortened(fitting: 26).count > 15 }
    }
}

/// A recommendation as a ROW, at the accessibility sizes: the show, the SHORT reason ("Like
/// Jujutsu Kaisen" — the full sentence ran three lines a row; VoiceOver still hears it whole), the
/// + (or the check) in the trailing column, the rule running under both to the gutter.
struct ForYouRow: View {
    let item: RecommendationItem
    let reason: RecommendationItem.Reason
    let separator: Bool
    let onOpen: () -> Void

    @Environment(AppModel.self) private var appModel

    var body: some View {
        let r = item
        HStack(spacing: ThemeSpace.x2) {
            MediaRow(title: r.tileTitle,
                     meta: Copy.ForYou.tileReasons(reason).last,
                     lead: r.airing ? Copy.ForYou.airingNow : nil,
                     poster: r.stub?.portraitArt ?? r.images?.portrait,
                     slot: .row,
                     chevron: false,
                     separator: false,
                     hint: Copy.Accessibility.opensTheShowHint,
                     action: onOpen)
                .accessibilityLabel("\(r.displayTitle), \(Copy.ForYou.reasonList(reason))")
            if appModel.isOwned(r) {
                OwnedMark().accessibilityLabel(Copy.ForYou.addedToPlanned)
            } else {
                TileAddDisc(label: "\(Copy.ForYou.addToPlanned), \(r.displayTitle)") { appModel.addRecommendation(r) }
            }
        }
        .overlay(alignment: .bottom) {
            if separator {
                Rectangle().fill(ThemeColor.separatorQuiet).frame(height: 1)
                    .padding(.leading, PosterSize.row.size.width + ThemeMetrics.artGap)
            }
        }
        .contextMenu { ForYouMenu(item: r, reason: reason, onOpen: onOpen) }
    }
}

/// "Recommended for you ›" — the shelf's See all: the longer list (up to 30, one request when the
/// screen opens), in the Search chart's grid grammar — three posters across, the same tile. Today
/// shows twelve; this is the room for someone who wants to browse. The shelf's own list stands in
/// while the longer one loads, and if it cannot load.
struct RecommendationsView: View {
    let onOpenDetail: (String) -> Void

    @Environment(AppModel.self) private var appModel
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var longer: [RecommendationItem]?
    @State private var width: CGFloat = 0

    private var items: [RecommendationItem] {
        appModel.visibleRecommendations(in: longer ?? appModel.recommendations)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if typeSize.isAccessibilitySize {
                    VStack(spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { i, r in
                            ForYouRow(item: r, reason: appModel.spokenReason(r), separator: i < items.count - 1) { open(r) }
                        }
                    }
                } else {
                    let column = max(96, (width - 2 * ThemeMetrics.shelfGap) / 3)
                    Grid(alignment: .topLeading, horizontalSpacing: ThemeMetrics.shelfGap,
                         verticalSpacing: ThemeSpace.x5) {
                        ForEach(Array(stride(from: 0, to: items.count, by: 3)), id: \.self) { start in
                            GridRow(alignment: .top) {
                                let row = Array(items[start..<min(start + 3, items.count)])
                                let twoLines = row.contains { $0.tileTitle.shelfShortened(fitting: 26).count > 12 }
                                ForEach(row) { r in
                                    ForYouTile(item: r, reason: appModel.spokenReason(r), width: column,
                                               reserveTwoNameLines: twoLines) { open(r) }
                                }
                                .environment(\.cornerRow, CornerRow(urls: row.compactMap { $0.stub?.tilePoster.url ?? $0.images?.portrait }))
                            }
                        }
                    }
                    .animation(ThemeMotion.pick(ThemeMotion.uiGentle, reduceMotion: reduceMotion), value: items.map(\.key))
                }
            }
            // Full width BEFORE it is measured: a scroll view's content is as wide as itself, and
            // the grid measured its own 96-pt columns and sat centred in 40-pt margins.
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, ThemeMetrics.gutter)
            .padding(.top, ThemeSpace.x3)
            .padding(.bottom, ThemeMetrics.tabBarClearance)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.width - 2 * ThemeMetrics.gutter }) { width = $0 }
        }
        .scrollIndicators(.hidden)
        .background(ThemeColor.canvas)
        .brandNavigationTitle(Copy.ForYou.shelf)
        .navigationBarTitleDisplayMode(.inline)
        .task { longer = await appModel.longerRecommendations() }
    }

    private func open(_ r: RecommendationItem) {
        Task {
            if let id = await appModel.franchiseId(for: r) { onOpenDetail(id) }
        }
    }
}
