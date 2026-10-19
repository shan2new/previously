import SwiftUI

// NEWS — Four tabs (`Experience.feedInHome`, 16 Oct): the Following feed's posts, as Home's News
// shelf and the pushed News page.
//
// Rebuilt 19 Oct ("News UI looks like utter shit", owner). It was the feed's X timeline transplanted
// into Home: an avatar column, a name line, a sentence, a two-line note with "Show more" and a full
// action bar under every post — and, after the morning's banner pass, banners and X rows taking turns
// in one list, two anatomies and two rhythms. A tracker's news is a READER's list (Apple News, the
// TV apps' "What's new"): the picture, who it is about, and the headline. So:
//   · Home's News is a SHELF of `NewsCard`s, the anatomy Recently aired's drops already use — every
//     section on Home is a shelf of cards;
//   · the News page leads with ONE `NewsCard` (the newest official announcement: the banner the owner
//     asked for), then every other post as a `NewsRow` — a thumbnail, the byline, the headline —
//     under its month;
//   · no action bar in either: like, save, remind, share and hide are the long-press menu's
//     (`PostMenuItems`) and the post page's, where the whole post is read.

/// The News page (Home's "News ›").
struct NewsListView: View {
    let onOpenPost: (String) -> Void
    let onOpenShow: (String) -> Void

    @Environment(AppModel.self) private var appModel

    var body: some View {
        let posts = NewsListView.posts(appModel)
        let lead = NewsListView.lead(posts)
        let groups = NewsGroup.build(posts.filter { $0.id != lead?.id }, now: appModel.nowMinute)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if let lead {
                    NewsCard(model: lead, width: ThemeMetrics.windowWidth - 2 * ThemeMetrics.gutter, lead: true,
                             onOpen: { open(lead) }, onOpenShow: { onOpenShow(lead.post.franchiseId) })
                        .equatable()
                        .padding(.horizontal, ThemeMetrics.gutter)
                        .padding(.top, ThemeSpace.x3)
                }
                ForEach(groups) { g in
                    SectionHeaderRow(g.title)
                        .padding(.horizontal, ThemeMetrics.gutter)
                        .padding(.top, ThemeMetrics.sectionGap)
                        .padding(.bottom, ThemeSpace.x1)
                    ForEach(g.posts, id: \.id) { m in
                        NewsRow(model: m, onOpen: { open(m) }, onOpenShow: { onOpenShow(m.post.franchiseId) })
                            .equatable()
                    }
                }
            }
            .padding(.bottom, ThemeSpace.x6)
        }
        .scrollIndicators(.hidden)
        .refreshable { await appModel.refreshFeed(.following) }
        .laneClearance(appModel, base: ThemeMetrics.tabBarClearance)
        .background(AppGround())
        .brandNavigationTitle(Copy.Feed.news)
        .navigationBarTitleDisplayMode(.inline)
    }

    /// An episode post opens its show (its room is the show's); every other opens its page.
    private func open(_ m: FeedPostModel) {
        if m.post.kind == .episode { onOpenShow(m.post.franchiseId) } else { onOpenPost(m.id) }
    }

    /// The Following feed's posts, in its order.
    static func posts(_ appModel: AppModel) -> [FeedPostModel] {
        appModel.feedRows(.following).compactMap { row in
            if case .post(let m) = row { return m }
            return nil
        }
    }

    /// The story that leads: the newest official announcement, else the newest post.
    static func lead(_ posts: [FeedPostModel]) -> FeedPostModel? {
        posts.first(where: \.isMajorAnnouncement) ?? posts.first
    }
}

/// The News page's months: "This week", then each month by name ("September", "August 2025").
struct NewsGroup: Identifiable {
    let title: String
    let posts: [FeedPostModel]
    var id: String { title }

    static func build(_ posts: [FeedPostModel], now: Int64) -> [NewsGroup] {
        let thisYear = Formatting.localParts(now).y
        var out: [NewsGroup] = []
        for m in posts {
            let at = m.post.time.at
            let title: String
            if now - at < 7 * Formatting.D {
                title = Copy.Feed.thisWeek
            } else {
                let p = Formatting.localParts(at)
                title = Formatting.formatted(at, skeleton: p.y == thisYear ? "MMMM" : "MMMMy", anchor: .local)
            }
            if let last = out.last, last.title == title {
                out[out.count - 1] = NewsGroup(title: title, posts: last.posts + [m])
            } else {
                out.append(NewsGroup(title: title, posts: [m]))
            }
        }
        return out
    }
}

/// Home's News (Four tabs), led by the newest official announcement, the header opening the page.
/// Two STYLES: the 19 Oct morning's SHELF of `NewsCard`s (Stage) — a single post is not a shelf, its
/// card runs gutter to gutter (Recently aired's rule) — and, since that evening's "greeted with
/// overwhelm" (owner), the calm Home's HEADLINE: today's latest update as one `NewsRow`, else
/// nothing (`today`).
struct HomeNews: View {
    enum Style { case shelf, rows }

    var style: Style = .shelf
    let onOpenPost: (String) -> Void
    let onOpenShow: (String) -> Void
    let onSeeAll: () -> Void

    @Environment(AppModel.self) private var appModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let limit = 8
    /// A calm Home's news (19 Oct, third pass: "News should be only shown for the latest update that
    /// came that day otherwise it stays hidden", owner): the newest post, and only when it is dated
    /// today — the day its own stamp says.
    static func today(_ posts: [FeedPostModel], now: Int64) -> [FeedPostModel] {
        guard let latest = posts.max(by: { $0.post.time.at < $1.post.time.at }) else { return [] }
        // The stamp's own calendar (`TemporalCopy.feedStamp`): a date-only post is dated in UTC, so a
        // story stamped "1d" is never Home's "today".
        let time = latest.post.time
        let anchor: Formatting.TimeAnchor = time.dateOnly ? .utcDate : .local
        return Formatting.dayDiff(ts: time.at, now: now, anchor: anchor) >= 0 ? [latest] : []
    }

    var body: some View {
        let all = NewsListView.posts(appModel)
        let lead = NewsListView.lead(all)
        let ordered = [lead].compactMap { $0 } + all.filter { $0.id != lead?.id }
        let posts = style == .shelf ? Array(ordered.prefix(Self.limit)) : Self.today(all, now: appModel.nowMinute)
        if !posts.isEmpty {
            if style == .shelf {
                shelf(posts)
            } else {
                list(posts)
            }
        }
    }

    /// The headlines: the section's header, then a row per post.
    private func list(_ posts: [FeedPostModel]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeaderRow(Copy.Feed.news, action: onSeeAll)
                .padding(.horizontal, ThemeMetrics.gutter)
                .padding(.bottom, ThemeSpace.x2)
            ForEach(posts, id: \.id) { m in
                NewsRow(model: m, compact: true, onOpen: { open(m) }, onOpenShow: { onOpenShow(m.post.franchiseId) })
                    .equatable()
            }
        }
        .padding(.top, ThemeMetrics.sectionGap)
    }

    private func open(_ m: FeedPostModel) {
        m.post.kind == .episode ? onOpenShow(m.post.franchiseId) : onOpenPost(m.id)
    }

    private func shelf(_ posts: [FeedPostModel]) -> some View {
        VStack(alignment: .leading, spacing: ThemeMetrics.labelGap) {
            SectionHeaderRow(Copy.Feed.news, action: onSeeAll)
                .padding(.horizontal, ThemeMetrics.gutter)
            if posts.count == 1, let only = posts.first {
                card(only, width: ThemeMetrics.windowWidth - 2 * ThemeMetrics.gutter)
                    .padding(.horizontal, ThemeMetrics.gutter)
            } else {
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: ThemeMetrics.shelfGap) {
                        ForEach(posts, id: \.id) { m in
                            card(m, width: HomeDropCard.shelfWidth)
                                .scrollTransition(axis: .horizontal) { content, phase in
                                    content
                                        .scaleEffect(phase.isIdentity || reduceMotion ? 1 : 0.95, anchor: .bottom)
                                        .opacity(phase.isIdentity ? 1 : 0.75)
                                }
                        }
                    }
                    .scrollTargetLayout()
                }
                .contentMargins(.horizontal, ThemeMetrics.gutter, for: .scrollContent)
                .scrollTargetBehavior(.viewAligned)
                .scrollIndicators(.hidden)
                .scrollClipDisabled()
            }
        }
        .padding(.top, ThemeMetrics.sectionGap)
    }

    private func card(_ m: FeedPostModel, width: CGFloat) -> some View {
        NewsCard(model: m, width: width,
                 onOpen: { m.post.kind == .episode ? onOpenShow(m.post.franchiseId) : onOpenPost(m.id) },
                 onOpenShow: { onOpenShow(m.post.franchiseId) })
            .equatable()
    }
}

extension FeedPostModel {
    /// A MAJOR announcement (19 Oct: "For major announcements (feed) they can be full screen banner
    /// like it is done in a lot of other apps but not an immersive view", owner): a new season, film
    /// or series confirmed, dated or given a window, on the studio's or network's own word (the
    /// gold check). Not a rumour, not a trade report, not a trailer and not an episode. It decides
    /// which story LEADS — Home's shelf and the News page both open on it.
    var isMajorAnnouncement: Bool {
        switch post.kind {
        case .announced, .dated, .window: return showsOfficialMark
        case .rumour, .trailer, .episode, .unknown: return false
        }
    }
}

// MARK: - The pieces

/// A post as a CARD: its picture at 16:9 with the show's logo on its foot (a NEW tag while it is
/// fresh, a play disc on a trailer), then the byline and the headline. Home's shelf draws it 300 pt
/// wide; the News page's lead runs it gutter to gutter, its headline a step larger, with the
/// research's note under it.
struct NewsCard: View, @MainActor Equatable {
    let model: FeedPostModel
    let width: CGFloat
    var lead = false
    let onOpen: () -> Void
    let onOpenShow: () -> Void

    static func == (a: Self, b: Self) -> Bool { a.model == b.model && a.width == b.width && a.lead == b.lead }

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: ThemeSpace.x3) {
                NewsArt(model: model, width: width, height: (width * 9 / 16).rounded(), card: true)
                VStack(alignment: .leading, spacing: ThemeSpace.x1) {
                    NewsByline(model: model)
                    Text(model.headline)
                        .type(lead ? ThemeType.newsLeadHeadline : ThemeType.newsHeadline)
                        .foregroundStyle(ThemeColor.textPrimary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(lead ? 3 : 2, reservesSpace: !lead)
                    if lead, let note = model.note {
                        Text(note)
                            .type(ThemeType.prose)
                            .foregroundStyle(ThemeColor.textSecondary)
                            .lineLimit(3)
                            .lineSpacing(3)
                            .padding(.top, ThemeSpace.x0_5)
                    }
                }
                .padding(.horizontal, ThemeSpace.x0_5)
            }
            .frame(width: width, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(OverArtPressStyle())
        .contextMenu { PostMenuItems(model: model, onOpenShow: onOpenShow) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.accessibilityLabel)
        .accessibilityAddTraits(.isButton)
    }
}

/// A post as a ROW on the News page: a 16:9 thumbnail (the episode list's tile size), the byline and
/// the headline beside it — the platform's news list.
struct NewsRow: View, @MainActor Equatable {
    let model: FeedPostModel
    /// Home's headlines (19 Oct: "News too loud", owner): a smaller picture and a lighter headline,
    /// so the news reads as a list under your own shows rather than beside them.
    var compact = false
    let onOpen: () -> Void
    let onOpenShow: () -> Void

    static func == (a: Self, b: Self) -> Bool { a.model == b.model && a.compact == b.compact }

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .top, spacing: ThemeSpace.x3) {
                NewsArt(model: model, width: compact ? 88 : 120, height: compact ? 50 : 68, card: false)
                VStack(alignment: .leading, spacing: compact ? ThemeSpace.x0_5 : ThemeSpace.x1) {
                    NewsByline(model: model)
                    Text(model.headline)
                        .type(compact ? ThemeType.newsHeadlineQuiet : ThemeType.newsHeadline)
                        .foregroundStyle(ThemeColor.textPrimary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(compact ? 2 : 3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, ThemeMetrics.gutter)
            .padding(.vertical, ThemeSpace.x2)
            .contentShape(Rectangle())
        }
        .buttonStyle(FeedRowPressStyle())
        .contextMenu { PostMenuItems(model: model, onOpenShow: onOpenShow) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.accessibilityLabel)
        .accessibilityAddTraits(.isButton)
    }
}

/// Who the news is about and when: "Wednesday ✓ · 30 Sep" — the gold check only on the studio's or
/// network's own word.
struct NewsByline: View {
    let model: FeedPostModel

    var body: some View {
        HStack(spacing: ThemeSpace.x1) {
            Text(model.shortName)
                .type(ThemeType.metadataEmphasis)
                .foregroundStyle(ThemeColor.textSecondary)
                .lineLimit(1)
            if model.showsOfficialMark { ConfirmedMark(size: 13) }
            Text("\u{00B7} \(model.stamp)")
                .type(ThemeType.metadata)
                .foregroundStyle(ThemeColor.textTertiary)
                .lineLimit(1)
                .fixedSize()
        }
    }
}

/// A post's picture in a frame: the trailer's still (with a play disc), the news's own art, or — for
/// a rumour, which carries none — the show's. A card wears the show's logo on its foot and the NEW
/// tag while the post is fresh; a thumbnail wears only the play disc.
struct NewsArt: View {
    let model: FeedPostModel
    let width: CGFloat
    let height: CGFloat
    let card: Bool

    @Environment(\.displayScale) private var displayScale

    private var pixels: CGFloat { min(PostMedia.maxPixels, width * displayScale) }
    private var f: Franchise { model.franchise }
    private var isTrailer: Bool { if case .trailer = model.media { true } else { false } }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: card ? ThemeRadius.card : 8, style: .continuous)
        ZStack(alignment: .bottomLeading) {
            picture
                .frame(width: width, height: height)
                .clipped()
            // A trailer's still is the video's own thumbnail, and it is lettered more often than not
            // ("ONE PUNCH MAN · VIZ OFFICIAL TRAILER"): the show's logo over it printed the name twice
            // (19 Oct). The byline under the card names the show.
            if card, !isTrailer {
                LinearGradient(stops: [.init(color: .clear, location: 0.45),
                                       .init(color: .black.opacity(0.7), location: 1)],
                               startPoint: .top, endPoint: .bottom)
                logo.padding(ThemeSpace.x3)
            }
        }
        .frame(width: width, height: height)
        .background(ThemeColor.surfaceRaised)
        .clipShape(shape)
        .overlay(shape.strokeBorder(ThemeColor.posterEdge, lineWidth: 1))
        .overlay(alignment: .topLeading) {
            if card, model.fresh {
                HomeNewTag(text: Copy.Stories.ringTag(1)).padding(HomeNewTag.inset)
            }
        }
        .overlay {
            if case .trailer = model.media {
                if card {
                    PlayGlyph()
                } else {
                    AppGlyph(systemName: "play.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 26, height: 26)
                        .background(.black.opacity(0.55), in: Circle())
                }
            }
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder private var picture: some View {
        switch model.media {
        case .trailer(let stills, _):
            ChainedRemoteImage(urls: stills, contentMode: .fill, maxPixel: pixels)
        case .art(let art):
            artwork(art)
        case .none:
            artwork(FeedComposer.wideArt(part: model.post.part, show: model.show))
        }
    }

    @ViewBuilder private func artwork(_ art: WideArt) -> some View {
        if art.portraitSource {
            // A poster in a wide frame: laid out whole across the width and moved up so the band
            // where a key visual's faces sit is the one in view (the feed's crop, `PostMedia`).
            let tall = width / PostMedia.posterWhole
            RemoteImageView(url: art.url, contentMode: .fill, maxPixel: min(1800, tall * displayScale),
                            alignment: .top, placeholderHidden: true)
                .frame(width: width, height: tall)
                .offset(y: -(tall - height) * PostMedia.posterFocus)
                .frame(width: width, height: height, alignment: .top)
        } else {
            RemoteImageView(url: art.url, contentMode: .fill,
                            maxPixel: art.ultraWide ? max(pixels, LandscapeArt.ultraWidePixels) : pixels,
                            alignment: .top, placeholderHidden: true)
        }
    }

    /// The show's logo on its picture; the name in type where it has none.
    @ViewBuilder private var logo: some View {
        if f.hasDrawableLogo, let logo = f.billboardLogo {
            ArtworkLogo(name: .logo(logo), title: f.displayTitle, height: width > 320 ? 44 : 34,
                        alignment: .bottomLeading)
                .frame(maxWidth: width * 0.55, alignment: .bottomLeading)
        } else {
            Text(f.displayTitle)
                .type(width > 320 ? ThemeType.sectionTitle : ThemeType.rowTitle)
                .foregroundStyle(ThemeColor.textPrimary)
                .lineLimit(2)
                .shadow(.art)
        }
    }
}
