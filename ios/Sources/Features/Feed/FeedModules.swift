import SwiftUI
import UserNotifications

// The feed's modules — each one a thing the references already taught people, placed BY RULE in the
// memoised composer (§1.7), never at a fixed index: X's "Who to follow" (Suggested for you), X's
// "What's happening" (Trending), Instagram's "You're all caught up", the skeleton the feed breathes
// under while it loads, and the alerts primer a reminder needs.

/// X's module grid: a heavy title, rows on the feed's 16-pt gutter, 10-pt row padding.
private enum ModuleLayout {
    static let titleTop: CGFloat = 14
    static let titleBottom: CGFloat = 6
    static let rowVertical: CGFloat = 10
    /// "Show more": X's 48-pt link row.
    static let moreHeight: CGFloat = 48
    /// The Suggested row's add control: 32 pt, 16 pt of side padding (X's follow pill).
    static let addHeight: CGFloat = 32
    static let addPadding: CGFloat = 16
}

// MARK: - Suggested for you

/// X's "Who to follow", for shows: a heavy title, rows of show · reason, each with its own add
/// control (never inside the row's button), and "Show more" to the whole recommendation list.
struct SuggestedModule: View {
    let items: [RecommendationItem]
    let reason: (RecommendationItem) -> RecommendationItem.Reason
    let onOpen: (RecommendationItem) -> Void
    var onSeeAll: (() -> Void)? = nil

    @Environment(AppModel.self) private var appModel

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                FeedModuleTitle(text: Copy.Feed.suggestedTitle)
                ForEach(items) { r in
                    HStack(spacing: FeedMetrics.gap + ThemeSpace.x1) {
                        Button { onOpen(r) } label: {
                            HStack(spacing: FeedMetrics.gap + ThemeSpace.x1) {
                                SubjectCropImage(urls: r.stub.map(FeedAvatar.candidates)
                                                 ?? [r.images?.portrait].compactMap { $0 })
                                    .frame(width: FeedMetrics.avatar, height: FeedMetrics.avatar)
                                    .clipShape(ShowAvatar.shape(FeedMetrics.avatar))
                                    .overlay(ShowAvatar.shape(FeedMetrics.avatar)
                                        .strokeBorder(ThemeColor.avatarEdge, lineWidth: FeedMetrics.hairline))
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(r.displayTitle)
                                        .type(ThemeType.feedName)
                                        .foregroundStyle(ThemeColor.feedText)
                                        .lineLimit(1)
                                    Text(Copy.ForYou.reason(reason(r)))
                                        .type(ThemeType.feedSubhead)
                                        .foregroundStyle(ThemeColor.feedSecondary)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityElement(children: .combine)
                        addControl(r)
                    }
                    .padding(.horizontal, ThemeMetrics.gutter)
                    .padding(.vertical, ModuleLayout.rowVertical)
                }
                if let onSeeAll {
                    Button(action: onSeeAll) {
                        Text(Copy.Feed.showMore)
                            .type(ThemeType.feedSubhead)
                            .foregroundStyle(ThemeColor.interactive)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, ThemeMetrics.gutter)
                            .frame(minHeight: ModuleLayout.moreHeight)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(FeedRowPressStyle())
                }
                FeedHairline()
            }
        }
    }

    /// The row's own add — X's white pill. Owned: "In Planned" with a check, disabled. Resolving
    /// (a recommendation not yet in the catalogue): a spinner in the pill. The add signs itself
    /// (`addRecommendation` → the library's haptic and lane receipt).
    @ViewBuilder
    private func addControl(_ r: RecommendationItem) -> some View {
        let owned = appModel.isOwned(r)
        let resolving = appModel.resolvingRecommendations.contains(r.key)
        Button {
            appModel.addRecommendation(r)
        } label: {
            Group {
                if resolving {
                    ProgressView()
                        .controlSize(.small)
                        .tint(ThemeColor.onAccent)
                } else if owned {
                    AppGlyphLabel(Copy.ForYou.addedToPlanned, systemName: "checkmark")
                        .labelStyle(.titleAndIcon)
                } else {
                    Text(Copy.Search.add)
                }
            }
            .type(ThemeType.feedSmall)
            .fontWeight(.bold)
            .foregroundStyle(owned ? ThemeColor.feedText : ThemeColor.onAccent)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, ModuleLayout.addPadding)
            .frame(minHeight: ModuleLayout.addHeight)
            .background(owned ? AnyShapeStyle(Color.clear) : AnyShapeStyle(ThemeGradient.ivory), in: Capsule())
            .overlay(Capsule().strokeBorder(owned ? ThemeColor.feedSeparator : .clear, lineWidth: FeedMetrics.hairline))
            .frame(minHeight: FeedMetrics.actionHitHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(FeedIconPressStyle())
        .disabled(owned || resolving)
        .accessibilityHint(owned ? "" : Copy.ForYou.addHint)
        .animation(ThemeMotion.uiMicro, value: owned)
        .animation(ThemeMotion.uiMicro, value: resolving)
    }
}

// MARK: - Trending

/// The chart, under For you (and under an empty account), as a SHELF OF POSTERS — the Library's
/// card, as Discover's "Trending now" draws it. It was X's "What's happening": eight rows of type,
/// a rank, a truncated name and one grey fact each — six hundred points of text in the middle of
/// a feed of pictures, in an app whose subject is the pictures ("For you visuals look poorly
/// built", owner, 4 Oct). The rank is the order; VoiceOver says it.
struct TrendingModule: View {
    let items: [FranchiseSummary]
    let onOpen: (String) -> Void

    @Environment(AppModel.self) private var appModel

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                // In the viewer's words: for one audience the chart is simply theirs.
                FeedModuleTitle(text: Copy.Watching.trending(appModel.audience))
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: ThemeMetrics.shelfGap) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { i, s in
                            let fact = Self.fact(s) ?? ""
                            ShelfPosterTile(poster: s.portraitArt, title: s.title.shelfShortened(fitting: 26), facts: fact,
                                            accessibilityLabel: Copy.Feed.separated([
                                                Copy.Feed.trendingContext(rank: i + 1,
                                                                          scope: s.source == .tmdb ? Copy.Filter.tv : Copy.Filter.anime),
                                                s.title, fact,
                                            ]),
                                            onOpen: { onOpen(s.id) }) { EmptyView() }
                        }
                    }
                    .scrollTargetLayout()
                }
                .contentMargins(.horizontal, ThemeMetrics.gutter, for: .scrollContent)
                .scrollTargetBehavior(.viewAligned)
                .scrollIndicators(.hidden)
                .padding(.top, ThemeSpace.x1)
                .padding(.bottom, ThemeSpace.x4)
                FeedHairline()
            }
        }
    }

    /// What the catalogue knows: on the air now; else what is next and when (the app's own reading
    /// of the curated release, `displayRelease` — never a parse of it); else the year.
    static func fact(_ s: FranchiseSummary) -> String? {
        if s.isReleasing { return Copy.Feed.airingNow }
        if let u = s.upcoming, let next = u.next, !next.isEmpty {
            return Copy.Feed.separated([next, u.displayRelease])
        }
        return s.year.map(String.init)
    }
}

/// X's module title: heavy, 20 pt, on the 16-pt gutter.
struct FeedModuleTitle: View {
    let text: String

    var body: some View {
        Text(text)
            .type(ThemeType.feedModuleTitle)
            .foregroundStyle(ThemeColor.feedText)
            .padding(.horizontal, ThemeMetrics.gutter)
            .padding(.top, ModuleLayout.titleTop)
            .padding(.bottom, ModuleLayout.titleBottom)
            .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - You're all caught up

/// Instagram's end-of-new marker, on the gels: the ring draws itself once, the check lands, and the
/// line says since when — the REAL previous visit (`prevOpenedAt`, §4.8). Below it, the feed carries
/// on with what you have already seen. Drawn at once under Reduce Motion.
struct CaughtUpMarker: View {
    let since: Int64

    @Environment(AppModel.self) private var appModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drawn = false

    private static let ringWidth: CGFloat = 3
    private static let draw = Animation.timingCurve(0.3, 0, 0.2, 1, duration: 0.8).delay(0.15)
    /// Instagram's block: 30 pt above and below, 24 pt at the sides.
    private static let vertical: CGFloat = 30
    private static let horizontal: CGFloat = 24

    var body: some View {
        let phrase = TemporalCopy.sinceVisit(since, now: appModel.nowMinute)
        VStack(spacing: 0) {
            VStack(spacing: ThemeSpace.x2 + ThemeSpace.x0_5) {
                ZStack {
                    Circle()
                        .stroke(ThemeColor.feedSeparator, lineWidth: Self.ringWidth)
                    Circle()
                        .trim(from: 0, to: drawn ? 1 : 0)
                        .stroke(ThemeGel.ring, style: StrokeStyle(lineWidth: Self.ringWidth, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    AppGlyph(systemName: "checkmark")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(ThemeColor.feedText)
                        .scaleEffect(drawn ? 1 : 0.4)
                        .opacity(drawn ? 1 : 0)
                }
                .frame(width: FeedMetrics.caughtUpRing, height: FeedMetrics.caughtUpRing)
                .padding(.bottom, ThemeSpace.x1)
                .accessibilityHidden(true)
                Text(Copy.Feed.caughtUpTitle)
                    .type(ThemeType.feedLightLarge)
                    .bold()
                    .foregroundStyle(ThemeColor.feedText)
                    .multilineTextAlignment(.center)
                Text(Copy.Feed.caughtUpSince(phrase))
                    .type(ThemeType.feedSubhead)
                    .foregroundStyle(ThemeColor.feedSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Self.horizontal)
            .padding(.vertical, Self.vertical)
            FeedHairline()
        }
        .accessibilityElement(children: .combine)
        .onAppear {
            guard !drawn else { return }
            if reduceMotion { drawn = true; return }
            withAnimation(Self.draw) { drawn = true }
        }
    }
}

// MARK: - Loading

/// The feed's skeleton on X's grid — the square avatar, three lines, the picture — breathing under
/// the feed's skeleton gate (the app refuses shimmer).
struct FeedPostSkeleton: View {
    var lines: [CGFloat?] = [150, nil, 190]

    private static let lineHeight: CGFloat = 12
    private static let lineGap: CGFloat = 9
    private static let actionWidth: CGFloat = 26
    private static let actionHeight: CGFloat = 10
    private static let actionGap: CGFloat = 44
    private static let vertical: CGFloat = 14

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: FeedMetrics.gap) {
                SkeletonBlock(width: FeedMetrics.avatar, height: FeedMetrics.avatar,
                              radius: FeedMetrics.avatar * FeedMetrics.showCornerRatio)
                VStack(alignment: .leading, spacing: Self.lineGap) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, w in
                        SkeletonBlock(width: w, height: Self.lineHeight)
                    }
                    SkeletonBlock(width: nil, height: nil, radius: FeedMetrics.mediaRadius)
                        .aspectRatio(16.0 / 9.0, contentMode: .fit)
                        .padding(.top, ThemeSpace.x1)
                    HStack(spacing: Self.actionGap) {
                        ForEach(0..<3, id: \.self) { _ in
                            SkeletonBlock(width: Self.actionWidth, height: Self.actionHeight)
                        }
                    }
                    .padding(.top, ThemeSpace.x1 + ThemeSpace.x0_5)
                }
            }
            .padding(.horizontal, FeedMetrics.inset)
            .padding(.vertical, Self.vertical)
            FeedHairline()
        }
        .accessibilityHidden(true)
    }
}

/// The three skeleton posts the feed shows while its first page loads (inside `SkeletonGate`, which
/// breathes them and speaks "Loading").
struct FeedSkeletonStack: View {
    var body: some View {
        VStack(spacing: 0) {
            FeedPostSkeleton()
            FeedPostSkeleton(lines: [120, nil])
            FeedPostSkeleton(lines: [170, nil, 140])
        }
    }
}

// MARK: - The alerts primer

/// Under the post whose reminder is waiting on notification permission (§4.4): the reason, then
/// "Turn on" (an explicit affordance — the one place this ask may be raised) and "Not now". When
/// notifications are denied, the Settings route instead. The remind TAP itself never raises the
/// system prompt.
struct AlertsPrimerLine: View {
    let model: FeedPostModel

    @Environment(AppModel.self) private var appModel
    @Environment(\.openURL) private var openURL
    @State private var denied = false
    @State private var asking = false

    var body: some View {
        VStack(alignment: .leading, spacing: ThemeSpace.x1) {
            Text(denied ? Copy.Feed.alertsDenied : Copy.Feed.alertsPrimer)
                .type(ThemeType.feedSubhead)
                .foregroundStyle(ThemeColor.feedSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: ThemeSpace.x4) {
                if denied {
                    Button(Copy.Notice.openSettings) {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                        appModel.reminderPrimerPostId = nil
                    }
                    .buttonStyle(InlineLinkButtonStyle())
                } else {
                    Button(Copy.Feed.alertsTurnOn) { turnOn() }
                        .buttonStyle(InlineLinkButtonStyle())
                        .disabled(asking)
                }
                Button(Copy.Feed.alertsNotNow) { appModel.reminderPrimerPostId = nil }
                    .buttonStyle(InlineLinkButtonStyle())
            }
            // The links hold their 44-pt targets with padding; pulled back so their words sit on
            // the text column's edge.
            .padding(.leading, -ThemeSpace.x3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task {
            denied = await EpisodeNotifications.shared.authorizationStatus() == .denied
        }
    }

    private func turnOn() {
        asking = true
        Task {
            let granted = await EpisodeNotifications.shared.requestPermissionIfNeeded()
            asking = false
            guard granted else {
                denied = await EpisodeNotifications.shared.authorizationStatus() == .denied
                return
            }
            // Arms every alert (the reminders ride `syncAmbient`), then says so — only now that it
            // is real (§4.4).
            await appModel.alertsWereAllowed()
            appModel.reminderPrimerPostId = nil
            if let premiere = model.post.premiere, appModel.isReminded(model.id) {
                appModel.showNotice(Copy.Feed.reminderSetFor(
                    Formatting.formatted(premiere.at, skeleton: "EEEdMMM", anchor: premiere.anchor)))
            }
        }
    }
}
