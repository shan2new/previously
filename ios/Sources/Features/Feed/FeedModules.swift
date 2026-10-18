import SwiftUI
import UserNotifications

// The feed's modules — each one a thing the references already taught people, placed BY RULE in the
// memoised composer (§1.7), never at a fixed index: the chart (under an empty account), Instagram's
// "You're all caught up", the skeleton the feed breathes under while it loads, and the alerts primer
// a reminder needs. X's "Who to follow" (Suggested for you) left the feed on 16 Oct with For you:
// it was the recommender's picks, which Discover's For you already shelves.

/// X's module grid: a heavy title on the feed's 16-pt gutter. 16 Oct, with the posts' air: 20 over
/// the title and 10 under it (were 14 and 6).
private enum ModuleLayout {
    static let titleTop: CGFloat = 20
    static let titleBottom: CGFloat = 10
    /// The chart's shelf → its rule: 20 (was 16).
    static let shelfBottom: CGFloat = ThemeSpace.x5
}

// MARK: - Trending

/// The chart, under an empty account (and an older server's notice), as a SHELF OF POSTERS — the
/// Library's card, as Discover's "Trending now" draws it. It was X's "What's happening": eight rows
/// of type, a rank, a truncated name and one grey fact each — six hundred points of text in the
/// middle of a feed of pictures, in an app whose subject is the pictures ("For you visuals look
/// poorly built", owner, 4 Oct). The rank is the order; VoiceOver says it.
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
                .padding(.bottom, ModuleLayout.shelfBottom)
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
    /// Instagram's block: 36 pt above and below (30 until 16 Oct's air), 24 pt at the sides.
    private static let vertical: CGFloat = 36
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
    /// The post's foot, in placeholders (16 Oct's air): picture → the action marks 23 with the
    /// stack's own gap (a post's picture → its glyphs: 21½), the marks → the rule 24 (25½).
    private static let actionsTop: CGFloat = 14
    private static let foot: CGFloat = 24

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
                    .padding(.top, Self.actionsTop)
                }
            }
            .padding(.horizontal, FeedMetrics.inset)
            .padding(.top, FeedMetrics.rowTop)
            .padding(.bottom, Self.foot)
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
