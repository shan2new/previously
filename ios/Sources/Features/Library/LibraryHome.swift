import SwiftUI

// The Library, rebuilt from the ground up (19 Oct: "Now let's overhaul the library from the ground
// up. It is extremely poorly built! It's overwhelming yet not fun. The worst experience of all!",
// owner).
//
// What it was: one A–Z wall of every show you own — 58 posters at the same 150 pt, three across,
// "Watched" printed under 44 of them, a row of status chips with counts and a search field over it.
// A database's view of a library: the order meant nothing, nothing said how far along you are, and
// the shows you finished read like a to-do list.
//
// What it is now: your shows by WHERE YOU ARE with them, in one screen. What you are WATCHING is a
// focus carousel at the top (`LibraryNowWatching`): the front poster large, its next step and where
// you are under it, the neighbours turning toward the middle as they leave. Your other shelves are
// three fanned STACKS of their own covers (`LibraryStack`: Planned, Watched, On hold), each with
// its count on a tag, fanning open under the finger and opening a page of that shelf. Search and
// the full A–Z instrument (`LibraryAllView`) sit behind the bar's magnifier. Two other layouts were
// photographed first and lost — one page of shelves, and tabs per status ("It doesn't have any wow
// factor with extreme intuitiveness", owner; `design/library-2026-10-19/`).

/// The Library's groups, by where you are with each show.
private enum LibraryGroup: String, CaseIterable, Identifiable {
    case watching, planned, finished, paused, dropped
    var id: String { rawValue }

    var status: WatchStatus {
        switch self {
        case .watching: .watching
        case .planned: .planned
        case .finished: .completed
        case .paused: .paused
        case .dropped: .dropped
        }
    }

    var title: String { Copy.Status(status) }
}

struct LibraryHome: View {
    @Environment(AppModel.self) private var appModel
    let chrome: RootChromeState
    let onOpenDetail: (_ franchiseId: String, _ zoomID: String) -> Void
    /// The full A–Z instrument (search, sort, filter), pushed.
    let onOpenAll: (LibraryView.AllTitlesRoute) -> Void
    var onAddShow: () -> Void = {}

    @State private var pullDriving = false
    @State private var contentHeight: CGFloat = 0
    /// A shelf opened from its stack.
    @State private var openShelf: LibraryShelfRoute?


    /// Each group's shows, in the order that means something for it: Watching as the app ranks it
    /// (a new episode, then mid-season, then the rest); Planned and Watched newest-added first.
    private var groups: [LibraryGroup: [Franchise]] {
        var out: [LibraryGroup: [Franchise]] = [:]
        let live = appModel.watchingShelf
        let liveIDs = Set(live.map(\.id))
        let byAdded: (Franchise, Franchise) -> Bool = {
            ($0.subscription?.addedAt ?? .min) > ($1.subscription?.addedAt ?? .min)
        }
        out[.watching] = live.filter { $0.effectiveStatus == .watching }
            + appModel.library.filter { $0.effectiveStatus == .watching && !liveIDs.contains($0.id) }
        for g in [LibraryGroup.planned, .finished, .paused, .dropped] {
            out[g] = appModel.library.filter { $0.effectiveStatus == g.status }.sorted(by: byAdded)
        }
        return out
    }

    var body: some View {
        let groups = self.groups
        ZStack(alignment: .top) {
            AppGround()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Color.clear.frame(height: 0)
                        .freshness(.catalogue, appModel: appModel, pullDriving: pullDriving)
                        .padding(.horizontal, ThemeMetrics.gutter)
                    if appModel.sectionFailed {
                        InlineNotice(Copy.Notice.library) { Task { await appModel.reload() } }
                            .padding(.horizontal, ThemeMetrics.gutter).padding(.top, ThemeSpace.x3)
                    }
                    if appModel.library.isEmpty {
                        if appModel.loading {
                            ProgressView().tint(ThemeColor.textTertiary)
                                .frame(maxWidth: .infinity, minHeight: 240)
                        } else {
                            EmptyState(appModel.emptyStateCopy, prominence: .major,
                                       artwork: appModel.surfacePhase == .emptyAccount ? .episodeFrames : nil,
                                       primary: appModel.loadError ? { Task { await appModel.reload() } } : onAddShow)
                                .padding(.horizontal, ThemeMetrics.gutter)
                                .centredState(contentH: contentHeight)
                        }
                    } else {
                        marqueePage(groups)
                    }
                }
                .rootChromeProbe(chrome, rest: ThemeMetrics.topSafeInset + FeedMetrics.headerRow)
            }
            // The page goes out under the transparent header and the status band (Home's fade) —
            // on the scroll view itself, under the header's inset, so the header is never masked.
            .modifier(HeaderEdgeFadeModifier(chrome: chrome))
            .safeAreaInset(edge: .top, spacing: 0) {
                RootHeader(title: Copy.Library.title, chrome: chrome) {
                    RootAccountButton()
                } trailing: {
                    RootHeaderGlyph(systemName: "magnifyingglass") { onOpenAll(LibraryView.AllTitlesRoute()) }
                        .accessibilityLabel(Copy.Library.allTitlesAccessibility(appModel.library.count))
                        .accessibilityHint(Copy.Library.allTitlesHint)
                }
            }
            .scrollIndicators(.hidden)
            .tabBarContentMargin()
            .onScrollPhaseChange { _, phase in
                pullDriving = (phase == .tracking || phase == .interacting)
                chrome.phase(phase)
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            .previouslyRefreshable { await appModel.reload() }
        }
        .navigationTitle(Copy.Library.title)
        .toolbar(.hidden, for: .navigationBar)
        .chromeScrollEdgeHidden(.top)
        .navigationDestination(item: $openShelf) { route in
            LibraryShelfPage(title: route.title, items: route.groups.flatMap { groups[$0] ?? [] }) { f in open(f) }
                .pushedScreenChrome()
        }
        .onChange(of: openShelf) { _, route in if route != nil { chrome.reveal() } }
    }

    // MARK: - The page

    /// What you are watching as a focus carousel at the top — the show in front large, the
    /// next one growing as it arrives, its name, its next step and where you are under it — then
    /// your other shelves as three stacks of their own covers. The whole root is one screen: no
    /// wall to scroll, nothing to read before you can act.
    @ViewBuilder
    private func marqueePage(_ groups: [LibraryGroup: [Franchise]]) -> some View {
        let watching = groups[.watching] ?? []
        let shelves: [LibraryShelfRoute] = [
            LibraryShelfRoute(groups: [.planned], title: LibraryGroup.planned.title),
            LibraryShelfRoute(groups: [.finished], title: LibraryGroup.finished.title),
            LibraryShelfRoute(groups: [.paused, .dropped], title: Copy.Library.onHold),
        ].filter { !$0.groups.flatMap { groups[$0] ?? [] }.isEmpty }
        VStack(spacing: 0) {
            if !watching.isEmpty {
                // No eyebrow: the carousel at the top of the Library is what you are watching —
                // a title saying so was implicit ("Now watching is implicit, not needed", owner).
                LibraryNowWatching(items: watching) { open($0) }
                    .padding(.top, ThemeSpace.x3)
            }
            if !shelves.isEmpty {
                VStack(alignment: .leading, spacing: ThemeSpace.x3) {
                    Text(Copy.Library.yourShelves)
                        .type(ThemeType.scheduleCaps)
                        .textCase(.uppercase)
                        .foregroundStyle(ThemeColor.textSecondary)
                        .padding(.horizontal, ThemeMetrics.gutter)
                    HStack(alignment: .top, spacing: ThemeSpace.x3) {
                        ForEach(shelves) { shelf in
                            let items = shelf.groups.flatMap { groups[$0] ?? [] }
                            LibraryStack(title: shelf.title, count: items.count,
                                         posters: items.prefix(3).compactMap { $0.tilePoster.url ?? $0.portraitArt }) {
                                openShelf = shelf
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .padding(.horizontal, ThemeMetrics.gutter)
                }
                .padding(.top, watching.isEmpty ? ThemeSpace.x4 : ThemeSpace.x8)
            }
        }
        .padding(.bottom, ThemeSpace.x8)
    }

    private func open(_ f: Franchise) { onOpenDetail(f.id, "lib/\(f.id)") }
}

// MARK: - The tiles

/// A show on a shelf you are not watching: its poster, its name, what it is.
private struct LibraryFactTile: View {
    let franchise: Franchise
    let width: CGFloat
    let onOpen: () -> Void

    var body: some View {
        let f = franchise
        let fact = [f.kindWord, f.year.map(String.init)].compactMap { $0 }.joined(separator: " \u{00B7} ")
        ArtworkPoster(url: f.tilePoster.url ?? f.portraitArt, name: f.tilePoster.name, title: f.displayTitle,
                      detailsInBand: true, fixedAspect: 2.0 / 3.0, onOpen: onOpen,
                      openLabel: "\(f.displayTitle), \(fact)") {
            PosterCaptionText(title: f.displayTitle.shelfShortened(fitting: 26), fact: fact)
        }
        .frame(width: width)
    }
}

// MARK: - The carousel and the stacks

/// A shelf opened from its stack: which groups it holds and what it is called.
struct LibraryShelfRoute: Hashable, Identifiable {
    fileprivate let groups: [LibraryGroup]
    let title: String
    var id: String { groups.map(\.rawValue).joined(separator: "+") }
}

/// NOW WATCHING: a focus carousel of your Watching shows — the card in front at full size, its
/// neighbours a step back and dimmed, the step following the finger — and under it the front
/// card's name, its next step and where you are, changing as the next card arrives.
private struct LibraryNowWatching: View {
    let items: [Franchise]
    let onOpen: (Franchise) -> Void

    @Environment(AppModel.self) private var appModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var focused: String?

    /// Half the window: the carousel, its caption and the shelves fit one screen above the bar.
    private var cardWidth: CGFloat { min((ThemeMetrics.windowWidth * 0.5).rounded(), 220) }
    private var cardHeight: CGFloat { (cardWidth * 1.5).rounded() }
    private var current: Franchise? { items.first { $0.id == focused } ?? items.first }

    var body: some View {
        VStack(spacing: ThemeSpace.x5) {
            ScrollView(.horizontal) {
                LazyHStack(spacing: ThemeSpace.x4) {
                    ForEach(items) { f in
                        Button { onOpen(f) } label: { card(f) }
                            .buttonStyle(OverArtPressStyle())
                            .franchiseQuickActions(f, appModel: appModel)
                            .accessibilityLabel(f.displayTitle)
                            .accessibilityHint(Copy.Accessibility.opensTheShowHint)
                            // COVER FLOW, quietly: a card leaving the front turns toward the
                            // middle as it shrinks — depth the finger drives, a render-pass effect.
                            .scrollTransition(.interactive, axis: .horizontal) { content, phase in
                                let t = min(1, abs(phase.value))
                                return content
                                    .rotation3DEffect(.degrees(reduceMotion ? 0 : -phase.value * 24),
                                                      axis: (x: 0, y: 1, z: 0), perspective: 0.55)
                                    .scaleEffect(reduceMotion ? 1 : 1 - 0.14 * t)
                                    .opacity(1 - 0.45 * t)
                            }
                            .id(f.id)
                    }
                }
                .scrollTargetLayout()
            }
            .contentMargins(.horizontal, (ThemeMetrics.windowWidth - cardWidth) / 2, for: .scrollContent)
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: $focused)
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
            .frame(height: cardHeight)

            if let current { caption(current) }
            if items.count > 1 { dots }
        }
    }

    private func card(_ f: Franchise) -> some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return ZStack {
            shape.fill(ThemeColor.surfaceRaised)
            RemoteImageView(url: f.tilePoster.url ?? f.portraitArt, contentMode: .fill, maxPixel: 900,
                            alignment: .top, placeholderHidden: true)
        }
        .frame(width: cardWidth, height: cardHeight)
        .clipShape(shape)
        .overlay(shape.strokeBorder(ThemeColor.posterEdge, lineWidth: FeedMetrics.hairline))
        .background {
            shape.fill(ThemeColor.canvas.shadow(.drop(color: .black.opacity(0.55), radius: 22, x: 0, y: 14)))
        }
    }

    /// The front card's name, its next step, and the bar of where you are — one block that changes
    /// with the card.
    private func caption(_ f: Franchise) -> some View {
        let facts = LibraryRowFacts.root(f, section: .watching, appModel: appModel)
        let fact = facts.lead ?? facts.meta
        return VStack(spacing: ThemeSpace.x2) {
            Text(f.displayTitle)
                .type(ThemeType.showTitleL)
                .foregroundStyle(ThemeColor.textPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
            if let fact {
                Text(fact)
                    .type(ThemeType.feedSubhead)
                    .foregroundStyle(facts.lead != nil ? ThemeColor.accent : ThemeColor.textSecondary)
                    .lineLimit(1)
            }
            if let ratio = ratio(f) {
                ProgressBar(value: ratio, spoken: nil)
                    .frame(width: 140)
                    .padding(.top, ThemeSpace.x1)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, ThemeMetrics.gutter)
        .frame(maxWidth: .infinity)
        .id(f.id)
        .transition(.opacity)
        .animation(ThemeMotion.pick(ThemeMotion.uiGentle, reduceMotion: reduceMotion), value: f.id)
        .accessibilityElement(children: .combine)
    }

    private func ratio(_ f: Franchise) -> Double? {
        guard let part = f.resumePart ?? f.releasingPart ?? f.parts.last(where: { $0.progress > 0 }) else { return nil }
        let total = max(part.progressDenominator(now: appModel.nowMinute, anchor: f.timeAnchor), part.progress)
        return total > 0 && part.progress > 0 ? Double(part.progress) / Double(total) : nil
    }

    /// Where you are in the carousel: a dot a show, the front one a short bar of ink.
    private var dots: some View {
        HStack(spacing: 6) {
            ForEach(items) { f in
                let on = f.id == (current?.id ?? "")
                Capsule()
                    .fill(on ? ThemeColor.textPrimary : ThemeColor.textPrimary.opacity(0.25))
                    .frame(width: on ? 16 : 6, height: 6)
            }
        }
        .animation(ThemeMotion.pick(ThemeMotion.uiSnappy, reduceMotion: reduceMotion), value: current?.id)
        .accessibilityHidden(true)
    }
}

/// The stack fans open while it is pressed: the press style says so to the pile inside it.
private struct StackPressedKey: EnvironmentKey { static let defaultValue = false }
private extension EnvironmentValues {
    var stackPressed: Bool {
        get { self[StackPressedKey.self] }
        set { self[StackPressedKey.self] = newValue }
    }
}

private struct StackPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.environment(\.stackPressed, configuration.isPressed)
    }
}

/// A shelf as a STACK of its own covers, fanned — the pile you would pick up — with its name and
/// its count under it. A tap opens the shelf.
private struct LibraryStack: View {
    let title: String
    let count: Int
    let posters: [String]
    let onOpen: () -> Void

    private static let poster = CGSize(width: 70, height: 105)
    /// The fanned pile's width: the front cover and its two neighbours leaning out.
    private static let stackWidth: CGFloat = 110

    var body: some View {
        Button(action: onOpen) {
            VStack(spacing: ThemeSpace.x3) {
                LibraryStackPile(posters: posters, count: count, poster: Self.poster) { url in cover(url) }
                .frame(width: Self.stackWidth, height: Self.poster.height + 14)
                Text(title)
                    .type(ThemeType.feedNoteTitle)
                    .foregroundStyle(ThemeColor.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(StackPressStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(count)")
        .accessibilityHint(Copy.Library.opensShelfHint)
    }

    private func cover(_ url: String) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        return RemoteImageView(url: url, contentMode: .fill, maxPixel: 240, alignment: .top, placeholderHidden: true)
            .frame(width: Self.poster.width, height: Self.poster.height)
            .background(ThemeColor.surfaceRaised)
            .clipShape(shape)
            .overlay(shape.strokeBorder(ThemeColor.posterEdge, lineWidth: FeedMetrics.hairline))
            .background(shape.fill(ThemeColor.canvas.shadow(.drop(color: .black.opacity(0.5), radius: 8, x: 0, y: 5))))
    }
}

/// A shelf opened: its covers three across with their names, newest-added first.
private struct LibraryShelfPage: View {
    let title: String
    let items: [Franchise]
    let onOpen: (Franchise) -> Void

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let columns = typeSize.isAccessibilitySize ? 2 : 3
        let gap = ThemeMetrics.shelfGap
        let width = ((ThemeMetrics.windowWidth - 2 * ThemeMetrics.gutter - CGFloat(columns - 1) * gap) / CGFloat(columns)).rounded(.down)
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(width), spacing: gap, alignment: .top), count: columns),
                      alignment: .leading, spacing: ThemeSpace.x5) {
                ForEach(items) { f in
                    LibraryFactTile(franchise: f, width: width) { onOpen(f) }
                }
            }
            .padding(.horizontal, ThemeMetrics.gutter)
            .padding(.top, ThemeSpace.x3)
        }
        .scrollIndicators(.hidden)
        .background { ZStack { ThemeColor.canvas; AppGround() }.ignoresSafeArea() }
        .brandNavigationTitle("\(title) \u{00B7} \(items.count)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
    }
}


/// The pile itself: the first cover on top and straight, the two under it leaning out — and, while
/// a finger is on it, leaning out further with the top cover lifting, the way a pile you pick up
/// spreads in the hand. Reduce Motion keeps it still.
private struct LibraryStackPile<Cover: View>: View {
    let posters: [String]
    let count: Int
    let poster: CGSize
    @ViewBuilder var cover: (String) -> Cover

    @Environment(\.stackPressed) private var pressed
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let spread = pressed && !reduceMotion
        ZStack {
            ForEach(Array(posters.enumerated().reversed()), id: \.offset) { i, url in
                let f = fan(i, spread: spread)
                cover(url)
                    // The pile's size, a chip on the top cover's corner — it rides the cover as the
                    // pile fans (19 Oct: "The chip was good, the number is shit", owner, of a 15-pt
                    // tabular numeral crammed into a circle).
                    // Top corner: a poster prints its title at its foot.
                    .overlay(alignment: .topTrailing) {
                        if i == 0 { LibraryCountChip(count: count).padding(5) }
                    }
                    .rotationEffect(.degrees(f.angle), anchor: .bottom)
                    .offset(x: f.x, y: f.y)
                    .scaleEffect(i == 0 && spread ? 1.04 : 1, anchor: .bottom)
                    .zIndex(i == 0 ? 1 : 0)
            }
            if posters.isEmpty {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(ThemeColor.hairline, lineWidth: 1)
                    .frame(width: poster.width, height: poster.height)
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.62), value: spread)
    }

    private func fan(_ i: Int, spread: Bool) -> (angle: Double, x: CGFloat, y: CGFloat) {
        let k: Double = spread ? 1.7 : 1
        switch i {
        case 0: return (0, 0, spread ? -6 : 0)
        case 1: return (-8 * k, -12 * k, 4)
        default: return (8 * k, 12 * k, 4)
        }
    }
}


/// A pile's count: a tag INSIDE the top cover's upper corner — the way a thumbnail carries its
/// duration, and clear of the title a poster prints at its foot — so it belongs to the picture (19 Oct: a grey disc standing off the cover's corner,
/// half on the art and half off, "looks awkward", owner). A dark scrim of a rounded rectangle, the
/// figure in the display face with proportional digits (Outfit's tabular "1" is as wide as an
/// "8", so "14" read "1 4").
private struct LibraryCountChip: View {
    let count: Int

    private static let figure = TypeToken(.display, .semibold, 12, .caption, tracking: 0.2)

    var body: some View {
        Text("\(count)")
            .type(Self.figure)
            .foregroundStyle(.white)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Color.black.opacity(0.68), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .accessibilityHidden(true)
    }
}
