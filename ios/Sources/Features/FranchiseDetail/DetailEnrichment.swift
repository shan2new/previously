import SwiftUI

// The show page's catalogue shelves — trailers, the people, related titles, where to watch — and
// the in-app trailer sheet. One shelf scaffold (`DetailShelf`) so the four sections share the
// Movies & extras shelf's anatomy exactly: `SectionHeaderRow`, a horizontal scroller that lets
// art run off the trailing edge and never type, the page gutter on the leading side.

// MARK: - Shelf scaffold

struct DetailShelf<Content: View>: View {
    /// Nil where the section's own header already names the shelf.
    let title: String?
    /// A part of a section (19 Oct): its name a step under the section's header (`ShowSubheader`).
    var subheader = false
    var count: Int? = nil
    var action: (() -> Void)? = nil
    /// Where the first card starts. The gutter, except for a shelf whose cards centre their art in
    /// a wider column (the people's discs), which pulls back so the ART sits on the gutter.
    var leading: CGFloat = ThemeMetrics.gutter
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: ThemeMetrics.labelGap) {
            if let title {
                if subheader {
                    ShowSubheader(title)
                } else {
                    SectionHeaderRow(title, count: count, action: action)
                }
            }
            // LAZY (5 Sep): a show page carries up to 13 trailers, 16 people and 12 related
            // titles, and an eager row built every one of them on the push — most of a 400-ms
            // stall on the simulator for cards three screens off to the right.
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: ThemeMetrics.shelfGap) { content() }
                    .padding(.leading, leading)
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

// MARK: - Trailer card

/// A 16:9 still with the one glyph that says "this moves", the video's name beneath and what it
/// is ("Trailer · Season 6") under that — Apple TV's Trailers row, Netflix's Trailers & More. A tap
/// PLAYS it in the card, with its sound and the player's controls (25 Sep: "It should not open full
/// screen by a mere click, player should be inline", owner); full screen is the controls' own
/// switch, or the phone turned on its side (`TrailerFullScreen`). One card plays at a time — the
/// page's `FeedAutoplay`, which starts nothing by itself here.
struct TrailerCard: View {
    let video: FranchiseVideo
    /// The show, so the card's name can drop it ("Game of Thrones | Official Series Trailer").
    var showTitle: String? = nil
    /// The shelf's card is 200 pt; the FEATURED first trailer runs the content width.
    var width: CGFloat = TrailerCard.width
    var featured: Bool = false
    /// The page's trailers: which card plays, and its player.
    let director: FeedAutoplay

    static let width: CGFloat = 200

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openURL) private var openURL

    /// The video's own name; one that is only its KIND ("Trailer" under a header that says
    /// Trailers, twice down a shelf) is named by the part it belongs to — "Season 4" (critique,
    /// 24 Sep).
    private var name: String {
        if let cleaned = video.title(cleanedFor: showTitle) { return cleaned }
        return video.partLabel ?? video.displayTitle
    }

    var body: some View {
        let playback = director.current?.key == video.id ? director.current : nil
        VStack(alignment: .leading, spacing: ThemeSpace.x2) {
            media(playback)
            Button { director.tap(video.id, video: video) } label: {
                VStack(alignment: .leading, spacing: 2) {
                    // A SHELF keeps its meta line directly under the name, one line or two (the
                    // owner's rule for shelves): two reserved lines put "Trailer", a 20-pt hole,
                    // then "Season 4" under every card whose name is one word (24 Sep).
                    Text(name)
                        .type(featured ? ThemeType.rowTitle : ThemeType.shelfTitle)
                        .foregroundStyle(ThemeColor.textPrimary)
                        .lineLimit(1...2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    // ALWAYS a meta line (review i2): one caption anatomy per shelf — neighbouring
                    // cards were two and three rows tall.
                    Text(Self.meta(video, name: name))
                        .type(featured ? ThemeType.rowMeta : ThemeType.shelfCaption)
                        .foregroundStyle(ThemeColor.textSecondary)
                        .lineLimit(1)
                }
                .frame(width: width, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHidden(true)
        }
    }

    private func media(_ playback: TrailerPlayback?) -> some View {
        let shape = RoundedRectangle(cornerRadius: ThemeRadius.card, style: .continuous)
        let disc: CGFloat = featured ? 56 : 40
        return ZStack {
            shape.fill(ThemeColor.surfaceRaised)
            RemoteImageView(url: video.thumbnailURL, contentMode: .fill, maxPixel: featured ? 1280 : 640,
                            placeholderHidden: true)
            if let playback {
                live(playback)
            } else {
                // The play disc in the scrim's glass, the way the over-art pills are drawn.
                AppGlyph(systemName: "play.fill")
                    .font(.system(size: featured ? 21 : 15, weight: .bold))
                    .foregroundStyle(ThemeColor.textPrimary)
                    .padding(.leading, featured ? 3 : 2)
                    .frame(width: disc, height: disc)
                    .background(ThemeColor.scrimStrong, in: Circle())
                    .overlay(Circle().strokeBorder(ThemeColor.hairline, lineWidth: 1))
                    .transition(.opacity)
            }
        }
        .frame(width: width, height: (width * 9 / 16).rounded())
        .clipShape(shape)
        .overlay(shape.strokeBorder(ThemeColor.posterEdge, lineWidth: 1))
        .cardShadow(.art, shape: shape)
        .contentShape(shape)
        .onTapGesture { director.tap(video.id, video: video) }
        // The player's controls ABOVE the card's tap, so a button's tap is the button's.
        .overlay {
            if let playback, !playback.presenting, playback.chromeVisible {
                TrailerInlineControls(playback: playback, onFullScreen: { director.openFullScreen(playback) },
                                      compact: !featured)
                    .clipShape(shape)
                    .transition(.opacity)
            }
        }
        .animation(ThemeMotion.pick(ThemeMotion.uiGentle, reduceMotion: reduceMotion), value: playback?.moving)
        .animation(ThemeMotion.pick(ThemeMotion.uiGentle, reduceMotion: reduceMotion), value: playback?.chromeVisible)
        // Where the card is on screen — a card scrolled away (the page, or its shelf) stops.
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .global)
        } action: { frame in
            director.report(video.id, video: video, frame: frame)
        }
        .onDisappear { director.gone(video.id) }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            if director.current?.key == video.id { director.deviceTurned() }
        }
        .onChange(of: playback?.phase == .failed) { _, failed in
            guard failed else { return }
            // A video the provider will not play here opens where it can be.
            if let url = video.watchURL { openURL(url) }
            director.refuse(video.id)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel([name, Self.meta(video, name: name)].joined(separator: ", "))
        .accessibilityValue(playback.map { Copy.Video.positionValue($0.current, of: $0.duration) } ?? "")
        .accessibilityHint(playback == nil ? Copy.Accessibility.playsTrailerHint : "")
        .accessibilityAction(.default) { director.tap(video.id, video: video) }
        .modifier(CardTrailerActions(playback: playback, director: director))
    }

    private func live(_ playback: TrailerPlayback) -> some View {
        TrailerSurface(playback: playback, role: .inline, presenting: playback.presenting)
            .opacity(!playback.presenting && playback.moving ? 1 : 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    /// "Trailer · Season 6": what it is, then the part it belongs to — ONE anatomy down the shelf,
    /// never the provider ("YouTube" beside "Trailer · Season 1", critique 24 Sep). The part is
    /// dropped when the name already is the part; the kind always stays, so every card has the
    /// same second line.
    static func meta(_ video: FranchiseVideo, name: String?) -> String {
        let kind = Copy.Video.kind(video.kind)
        let part = video.partLabel.flatMap { label in name == label ? nil : label }
        return [kind, part].compactMap { $0 }.joined(separator: " \u{00B7} ")
    }
}

// MARK: - Person card

/// A disc, a name, a role — centred, the way Apple TV draws its cast. Not a control: there is no
/// person page, so it claims no tap.
struct PersonCard: View {
    let person: CatalogPerson

    /// Supporting information, a step smaller than the art shelves (24 Sep): 64-pt discs in
    /// 96-pt columns show three and a half people, which says "scrolls" without a sliver.
    static let disc: CGFloat = 64
    static let width: CGFloat = 96
    /// How far the shelf pulls back so the first DISC, not its column, sits on the gutter.
    static let columnInset: CGFloat = (width - disc) / 2

    /// The name as a CREDIT — two lines, broken at the space that balances them ("Yuusuke" over
    /// "Kobayashi") — so every name is two lines tall and every role lands on one baseline. A
    /// wrapped name used to push only its own role down a line (critique, 24 Sep).
    static func creditName(_ name: String) -> String {
        let words = name.split(separator: " ")
        guard words.count >= 2 else { return name }
        var split = 1, longest = Int.max
        for i in 1..<words.count {
            let head = words[..<i].joined(separator: " ").count
            let tail = words[i...].joined(separator: " ").count
            if max(head, tail) < longest { longest = max(head, tail); split = i }
        }
        return words[..<split].joined(separator: " ") + "\n" + words[split...].joined(separator: " ")
    }

    var body: some View {
        VStack(spacing: ThemeSpace.x2) {
            ZStack {
                Circle().fill(ThemeColor.surfaceRaised)
                if person.image != nil {
                    RemoteImageView(url: person.image, contentMode: .fill, maxPixel: 216,
                                    alignment: .top, placeholderHidden: true)
                } else {
                    AppGlyph(systemName: "person.fill")
                        .font(.system(size: 26, weight: .regular))
                        .foregroundStyle(ThemeColor.textTertiary)
                }
            }
            .frame(width: Self.disc, height: Self.disc)
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(ThemeColor.posterEdge, lineWidth: 1))
            VStack(spacing: 2) {
                // ONE line each (review i3): Apple TV's cast row. A reserved two-line box gave
                // four of five names a 24-pt hole; a name compresses a step before it ellipsizes.
                // One size for every name on the row (review i5: a long name at 0.85 lifted its
                // own role 7 px off the row); a long name wraps and moves only its role.
                Text(Self.creditName(person.name))
                    .type(ThemeType.shelfTitle)
                    .foregroundStyle(ThemeColor.textPrimary)
                    .lineLimit(2, reservesSpace: true)
                    .truncationMode(.tail)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                if let role = person.displayRole {
                    Text(role)
                        .type(ThemeType.shelfCaption)
                        .foregroundStyle(ThemeColor.textSecondary)
                        // One line at ONE size across the row — truncated, never scaled: a
                        // scaled "Wednesday Addams" sat 0.92× beside its neighbours with its
                        // baseline 1.3 pt high (review i4, N11).
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(width: Self.width)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Copy.Accessibility.person(person.name, role: person.role))
    }
}

// MARK: - Where to watch

/// The providers' marks in a row under a header that opens the options, and the attribution the
/// provider data requires as a footnote. The data carries one link for the whole title and none
/// per provider, so every mark opens THAT page — the options, where each service is one tap on —
/// rather than sitting there looking pressable and doing nothing (review, 23 Sep). Each mark is
/// named, and a service's store channels ("Crunchyroll Amazon Channel") fold into the service.
struct WatchProvidersRow: View {
    let availability: WatchAvailability
    let open: () -> Void

    /// One mark per service: a "<Service> Amazon Channel"-style or "<Service> with Ads" listing
    /// is the same service sold another way.
    static func distinct(_ providers: [WatchProvider]) -> [WatchProvider] {
        let names = providers.map { $0.name.lowercased() }
        // A paid add-on channel sold inside Prime Video is redundant when Prime Video itself
        // carries the title: "Anime Times" beside "Amazon Prime Video" offered a second
        // subscription for what the first already plays (review i4, P23).
        let primeCarries = names.contains { $0.hasPrefix("amazon prime video") }
        return providers.filter { p in
            let name = p.name.lowercased()
            if primeCarries, name.hasSuffix(" amazon channel") { return false }
            return !names.contains { other in
                other != name && name.hasPrefix(other + " ")
                    && (name.contains("channel") || name.contains("with ads") || name.contains("amazon"))
            }
        }
    }

    /// The SERVICE's name: a store channel is named by what it is, not the shop it is sold in —
    /// "Anime Times Amazon Channel" printed "Anime Times Amazon Cha…" (review i3).
    static func displayName(_ provider: WatchProvider) -> String {
        var name = provider.name
        for suffix in [" Amazon Channel", " Apple TV Channel", " Roku Premium Channel"] {
            if name.lowercased().hasSuffix(suffix.lowercased()), name.count > suffix.count {
                name = String(name.dropLast(suffix.count))
                break
            }
        }
        // The BRAND as its mark says it (24 Sep): "Amazon / Prime Video" wrapped under the
        // "prime video" logo and "Amazon MX Play…" was cut at the screen's edge (critique).
        let brands: [String: String] = [
            "amazon prime video": "Prime Video", "amazon mx player": "MX Player",
            "disney plus": "Disney+", "paramount plus": "Paramount+", "apple tv plus": "Apple TV+",
        ]
        return brands[name.lowercased()] ?? name
    }

    var body: some View {
        let linked = availability.linkURL != nil
        VStack(alignment: .leading, spacing: ThemeMetrics.labelGap) {
            SectionHeaderRow(Copy.Heading.whereToWatch, action: linked ? open : nil)
                .accessibilityHint(linked ? Copy.Accessibility.opensStreamingOptionsHint : "")
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: ThemeMetrics.shelfGap) {
                    ForEach(Self.distinct(availability.providers)) { provider in
                        Button(action: open) {
                            VStack(spacing: ThemeSpace.x1) {
                                ProviderMark(provider: provider)
                                // Two lines, centred, never an ellipsis: "Amazon Prim…" and
                                // "Anime Times…" named nothing (iteration 2).
                                // ONE line under every mark, so the row is one height.
                                Text(Self.displayName(provider))
                                    .type(ThemeType.caption)
                                    .foregroundStyle(ThemeColor.textSecondary)
                                    .multilineTextAlignment(.center)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.85)
                                    .allowsTightening(true)
                                    .frame(width: ProviderMark.size + 16, alignment: .top)
                            }
                        }
                        .buttonStyle(RowPressStyle())
                        .disabled(!linked)
                        .accessibilityLabel("\(Self.displayName(provider)), \(Copy.Watch.access(provider.access))")
                        .accessibilityHint(linked ? Copy.Accessibility.opensStreamingOptionsHint : "")
                    }
                }
                // Each mark is centred in a name column 16 pt wider than it: pulled back 8 pt so the
                // first MARK — not its column — sits on the gutter (iteration 2).
                .padding(.leading, ThemeMetrics.gutter - 8)

            }
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
            .shelfScroller()
            .padding(.horizontal, -ThemeMetrics.gutter)
            Text(Copy.Watch.attribution(availability.attribution))
                .type(ThemeType.caption)
                .foregroundStyle(ThemeColor.textTertiary)
        }
    }
}

/// One provider's mark: its logo on a raised square, or its initials where it has none.
struct ProviderMark: View {
    let provider: WatchProvider
    /// The shelf's 56 pt; the stage's line draws it small (`StageWatchLine.markSide`), its corner
    /// scaled with it so a small mark is the same shape, not a rounder one.
    var side: CGFloat = ProviderMark.size

    static let size: CGFloat = 56

    var body: some View {
        let small = side < Self.size
        let shape = RoundedRectangle(cornerRadius: ThemeRadius.compactControl * side / Self.size, style: .continuous)
        ZStack {
            shape.fill(ThemeColor.surfaceRaised)
            if provider.logo != nil {
                RemoteImageView(url: provider.logo, contentMode: .fill, maxPixel: side * 2.8, placeholderHidden: true)
            } else {
                Text(initials)
                    .type(small ? ThemeType.caption : ThemeType.metadataEmphasis)
                    .fontWeight(.semibold)
                    .foregroundStyle(ThemeColor.textSecondary)
                    .minimumScaleFactor(0.6)
            }
        }
        .frame(width: side, height: side)
        .clipShape(shape)
        .overlay(shape.strokeBorder(ThemeColor.posterEdge, lineWidth: 1))
        .accessibilityLabel("\(provider.name), \(Copy.Watch.access(provider.access))")
    }

    private var initials: String {
        provider.name.split(separator: " ").prefix(2).compactMap { $0.first.map(String.init) }.joined().uppercased()
    }
}

/// WHERE TO WATCH on the show's stage (16 Oct: "where to watch has been removed which adds to the
/// chaos", owner — the stage had filed it in About, two sections under Episodes and Trailers for a
/// tracked show). One quiet line under the lockup's action row, centred on its axis the way Apple
/// TV names the channel beside Play: up to three services' marks, "Watch on Netflix and
/// Crunchyroll", a chevron, the WHOLE line opening the data's one link (the options page, where
/// each service is a tap on — `WatchProvidersRow`'s rule); the attribution the data requires as a
/// footnote beneath it. Both lines are one line at every size, so the line is exactly as tall as
/// its `room` — the answer fades in where the room was held, and the lockup never moves.
struct StageWatchLine: View {
    let availability: WatchAvailability
    let open: () -> Void

    @Environment(\.dynamicTypeSize) private var typeSize

    /// Small enough to sit in a line of type, large enough to read as the brand.
    static let markSide: CGFloat = 22
    /// The rest are counted in the words ("and 2 more").
    static let markLimit = 3
    /// The line is drawn mark-tall; its target is a finger tall (the 44-pt floor) without the
    /// layout growing — the action row is a spacing step above, so the two targets only touch.
    static let target: CGFloat = 44

    /// The line's room, held while the read is out: the same view, hidden, so its height is the
    /// line's at any text size.
    static var room: some View {
        StageWatchLine(availability: WatchAvailability(country: "", status: .available,
                                                       providers: [WatchProvider(id: 0, name: "", logo: nil, access: .subscription)],
                                                       link: nil),
                       open: {})
            .hidden()
            .accessibilityHidden(true)
    }

    var body: some View {
        let services = WatchProvidersRow.distinct(availability.providers)
        let names = services.map(WatchProvidersRow.displayName)
        let linked = availability.linkURL != nil
        let slop = max(0, (Self.target - Self.markSide) / 2)
        VStack(spacing: ThemeSpace.x1) {
            Button(action: open) {
                HStack(spacing: ThemeSpace.x2) {
                    HStack(spacing: ThemeSpace.x1) {
                        ForEach(services.prefix(Self.markLimit)) { provider in
                            ProviderMark(provider: provider, side: Self.markSide)
                        }
                    }
                    .accessibilityHidden(true)
                    // The count form at the accessibility sizes: one line, never cut mid-name.
                    Text(Copy.Watch.watchOn(names, compact: typeSize.isAccessibilitySize))
                        .type(ThemeType.feedSubhead)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .shadow(.art)
                    if linked {
                        AppGlyph(systemName: "chevron.forward")
                            .font(ThemeType.feedSmall.font.weight(.bold))
                            .foregroundStyle(ThemeColor.textPrimary.opacity(0.66))
                            .accessibilityHidden(true)
                    }
                }
                .foregroundStyle(ThemeColor.interactive)
                .frame(minHeight: Self.markSide)
                .padding(.vertical, slop)
                .contentShape(Rectangle())
                .padding(.vertical, -slop)
            }
            .buttonStyle(OverArtPressStyle())
            .disabled(!linked)
            .qaIdentifier("qa.detail.watch")
            .accessibilityLabel(Copy.Watch.watchOnSpoken(names))
            .accessibilityHint(linked ? Copy.Accessibility.opensStreamingOptionsHint : "")
            Text(Copy.Watch.attribution(availability.attribution))
                .type(ThemeType.feedSmall)
                .foregroundStyle(ThemeColor.textTertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .shadow(.art)
        }
        .multilineTextAlignment(.center)
    }
}

/// A playing card's controls as named VoiceOver actions (its buttons sit inside one element):
/// play/pause, full screen and the sound. Conditional INSIDE the builder, so the card keeps its
/// identity when its trailer starts.
private struct CardTrailerActions: ViewModifier {
    let playback: TrailerPlayback?
    let director: FeedAutoplay

    func body(content: Content) -> some View {
        content.accessibilityActions {
            if let playback {
                let playing = playback.phase == .playing || playback.phase == .buffering
                Button(playing ? Copy.Video.pause : Copy.Video.play) { playback.togglePlay() }
                Button(Copy.Video.fullScreen) { director.openFullScreen(playback) }
                Button(playback.soundLabel) { playback.setMuted(!playback.muted) }
            }
        }
    }
}
