import SwiftUI

// The top of the feed (16 Oct: "Feed screen doesn't need For You as it is already present in the
// search… We also don't need to show the previously logo in the feed screen", owner):
//   · ONE row, the roots' own (`RootHeaderRow`, Library's and Schedule's): you on the left, the
//     screen's name in the middle, your activity on the right — no brand mark, no tabs, no rule;
//   · over the roots' VEIL (`EdgeVeil`, as `RootHeader` draws it — "a lot of top and bottom BLACK
//     bars which are taking visible space", owner, 16 Oct): the posts scroll on under it, blurred
//     and dimmed, where an opaque slab of canvas hid them; it runs up through the status band, so
//     the clock stays legible once the row has gone;
//   · it gets out of the way — gone on the way down, back the moment you scroll up, tied to the
//     finger and never parked half over a post. The app's bar rides it (`ScrollAwayChrome`).
// For you lives in Discover only; the feed is Following.

// MARK: - The bar's one moving fact

/// The header's offset, held OUTSIDE the screen's state: the scroll probe WRITES it, and only
/// `FeedHeader`, `FeedPillSlot` and the app's bar read it, so a scroll frame invalidates the bars
/// and nothing else (the app's rule: the scroll offset is never screen state).
///
/// X's bar is tied to the finger, not to a timer: it slides up point for point as you read down,
/// comes back point for point the moment you scroll up, and when the scroll comes to rest it is
/// either all there or all gone.
@MainActor
@Observable
final class FeedChromeState: ScrollAwayChrome {
    /// X shows its "new posts" pill only once the reader is well down the feed: at the top the new
    /// posts are simply there.
    static let downThreshold: CGFloat = 900

    /// How far the bar has slid up: 0 (all there) … `FeedHeader.height` (gone).
    private(set) var offset: CGFloat = 0
    /// The feed is more than `downThreshold` points down.
    private(set) var down = false
    var hidden: Bool { offset >= FeedHeader.height - 0.5 }
    var awayFraction: CGFloat { offset / FeedHeader.height }

    /// The feed's last scroll distance.
    @ObservationIgnored private var lastY: CGFloat = 0
    /// `-feedPinHeader 1`: captures that jump to a post keep the bar in shot.
    private let pinned = FeedCapture.pinHeader

    /// The feed's scroll distance from its resting top (negative while pulling to refresh).
    func track(_ y: CGFloat) {
        let dy = y - lastY
        lastY = y
        let isDown = y > Self.downThreshold
        if isDown != down { down = isDown }
        guard !pinned else { return }
        let next: CGFloat = y <= 0 ? 0 : min(max(offset + dy, 0), FeedHeader.height)
        if abs(next - offset) >= 0.5 || (next == 0 && offset != 0) { offset = next }
    }

    /// At rest the bar is either shown or gone: past halfway it finishes leaving, else it returns.
    func settle() {
        guard !pinned, offset > 0, offset < FeedHeader.height else { return }
        let gone = offset > FeedHeader.height / 2 && lastY > FeedHeader.height
        withAnimation(Self.motion) { offset = gone ? FeedHeader.height : 0 }
    }

    /// The bar comes back (the title's scroll to top, a re-selected tab, the pill).
    func reveal() {
        guard offset != 0 else { return }
        withAnimation(Self.motion) { offset = 0 }
    }

    private static var motion: Animation {
        ThemeMotion.pick(ThemeMotion.uiSnappy, reduceMotion: UIAccessibility.isReduceMotionEnabled)
    }
}

// MARK: - The header

struct FeedHeader: View {
    /// One row, the roots' 44 pt (`RootHeaderRow`) — no tab row and no rule under it since 16 Oct.
    static var height: CGFloat { FeedMetrics.headerRow }

    let chrome: FeedChromeState
    let unread: Int
    let onProfile: () -> Void
    let onActivity: () -> Void
    /// The title scrolls the feed to the top, as X's logo does (so does re-tapping the tab).
    let onTop: () -> Void
    /// The status band the bar slides under (the window's, unless the host measured its own).
    var topInset: CGFloat = ThemeMetrics.topSafeInset

    @Environment(AuthManager.self) private var auth
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The bell rings once when there is something new to see.
    @State private var rang = 0
    /// The brand mark's width in a bar: the cut P stands ~24 pt tall, X's logo's height. The feed
    /// no longer draws it (16 Oct); Home's header still does (`HomeParts`).
    static let markWidth: CGFloat = 17

    var body: some View {
        // Library's and Schedule's row (`RootHeaderRow`), point for point: the name centred in the
        // app's face and primary ink, a control each side on the gutter, 44-pt targets.
        ZStack {
            Button(action: onTop) {
                Text(Copy.Feed.title)
                    .type(ThemeType.bodyEmphasis)
                    .foregroundStyle(ThemeColor.textPrimary)
                    .lineLimit(1)
                    .padding(.horizontal, ThemeSpace.x3)
                    .frame(minHeight: FeedMetrics.headerRow)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Copy.Feed.title)
            .accessibilityHint(Copy.Feed.scrollToTopHint)
            .accessibilityAddTraits(.isHeader)
            HStack(spacing: ThemeSpace.x1) {
                Button(action: onProfile) {
                    AccountGlyph(identity: auth.identity)
                        .frame(width: FeedMetrics.actionHitHeight, height: FeedMetrics.actionHitHeight,
                               alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(FeedIconPressStyle())
                .accessibilityLabel(Copy.Feed.profile)
                Spacer(minLength: ThemeSpace.x2)
                bell
            }
        }
        .padding(.horizontal, ThemeMetrics.gutter)
        .frame(height: FeedMetrics.headerRow)
        .barInk()
        // The row's band still takes its own touches, as its opaque ground did: a tap beside the
        // title never opens the post passing under the veil. The veil itself (status band, ramp)
        // lets everything through.
        .contentShape(Rectangle())
        // The controls thin out as the row leaves, as the other roots' do; the veil does not.
        .modifier(RootChromeFade(chrome: chrome))
        // `RootHeader`'s veil, from the screen's top edge: the status band and the row, then its
        // ramp. It slides with the row, so once the row has gone the veil's foot still lies under
        // the clock — one veil, never a second one stacked over the status band.
        .background(alignment: .top) {
            EdgeVeil(edge: .top,
                     band: topInset + FeedMetrics.headerRow,
                     line: topInset + FeedMetrics.headerRow / 2)
                .offset(y: -topInset)
        }
        .offset(y: -chrome.offset)
        .onChange(of: unread) { old, new in
            if new > old { ring() }
        }
        .task {
            // Once, a beat after the feed lands: the bell rings if there is something new.
            guard unread > 0 else { return }
            try? await Task.sleep(for: Self.ringDelay)
            guard !Task.isCancelled else { return }
            ring()
        }
    }

    /// X's disc in the bar: 32 pt in a 44-pt target.
    private static let ringDelay: Duration = .milliseconds(1100)

    private func ring() {
        guard !reduceMotion else { return }
        rang += 1
    }

    private var bell: some View {
        Button(action: onActivity) {
            AppGlyph(systemName: "bell")
                .font(.title3)
                .foregroundStyle(ThemeColor.feedText)
                // A transform, not `.symbolEffect`: the glyph is a Tabler picture. The dot below
                // is an overlay after it, so it holds still while the bell rings.
                .glyphRing(trigger: rang)
                .overlay(alignment: .topTrailing) {
                    if unread > 0 {
                        Circle().fill(ThemeColor.unreadDot)
                            .frame(width: Self.dot, height: Self.dot)
                            .overlay(Circle().strokeBorder(ThemeColor.canvas, lineWidth: Self.dotEdge))
                            .offset(x: Self.dotEdge, y: -1)
                            .transition(.scale(scale: 0.2).combined(with: .opacity))
                    }
                }
                .animation(ThemeMotion.pick(ThemeMotion.uiSnappy, reduceMotion: reduceMotion), value: unread > 0)
                .frame(width: FeedMetrics.actionHitHeight, height: FeedMetrics.actionHitHeight, alignment: .trailing)
                .contentShape(Rectangle())
        }
        .buttonStyle(FeedIconPressStyle())
        .accessibilityLabel(unread > 0 ? Copy.Feed.activityUnread(unread) : Copy.Feed.activity)
    }

    /// The unread dot: 8 pt with a 1.5-pt canvas edge, so it reads cut out of the bell.
    private static let dot: CGFloat = 8
    private static let dotEdge: CGFloat = 1.5

}

/// Discover's Explore header's ground: the canvas, FLUSH with the content (X's and Instagram's,
/// 25 Sep — "the header area in both X and Instagram is flush (same background color) as content",
/// owner). The feed's own header left it on 16 Oct for the roots' veil (`EdgeVeil`, above).
struct FeedHeaderGround: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    /// Transparent since 17 Oct (the bars are); opaque canvas under Reduce Transparency.
    var body: some View {
        reduceTransparency ? ThemeColor.canvas : Color.clear
    }
}

// MARK: - New posts

/// The new-posts pill rides under the bar: it follows the bar up, and stops under the status band.
/// It is shown only once the reader is well down the feed (`FeedChromeState.down`) — the one other
/// view that reads the chrome's scroll facts.
struct FeedPillSlot<Content: View>: View {
    let chrome: FeedChromeState
    @ViewBuilder var content: () -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if chrome.down {
                content()
                    .transition(reduceMotion
                        ? .opacity
                        : .asymmetric(insertion: .move(edge: .top).combined(with: .opacity),
                                      removal: .scale(scale: 0.8).combined(with: .opacity)))
            }
        }
        .offset(y: -chrome.offset)
        .animation(ThemeMotion.pick(ThemeMotion.uiSettle, reduceMotion: reduceMotion), value: chrome.down)
    }
}

/// X's pill: the faces of what is new, "N new posts", an arrow. Tap it and the feed goes to the
/// top. Amber here is STATE (new since your last visit), with `onAccent` ink on it.
struct NewPostsPill: View {
    let posts: [FeedPostModel]
    let count: Int
    let action: () -> Void

    /// The faces overlap by 7 pt, each edged in the pill's own amber.
    private static let faceOverlap: CGFloat = -7
    private static let faceEdge: CGFloat = 1.5

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: FeedMetrics.pillHeight / 2, style: .continuous)
        Button(action: action) {
            HStack(spacing: ThemeSpace.x2) {
                AppGlyph(systemName: "arrow.up")
                    .font(ThemeType.feedSmall.font.weight(.bold))
                HStack(spacing: Self.faceOverlap) {
                    ForEach(posts.prefix(3)) { p in
                        FeedAvatar(candidates: FeedAvatar.candidates(p.franchise), size: FeedMetrics.pillAvatar)
                            .overlay(Circle().strokeBorder(ThemeColor.accent, lineWidth: Self.faceEdge))
                    }
                }
                Text(Copy.Feed.newPosts(count))
                    .type(ThemeType.feedPill)
                    .lineLimit(1)
            }
            .foregroundStyle(ThemeColor.onAccent)
            .padding(.leading, ThemeSpace.x3)
            .padding(.trailing, ThemeSpace.x4)
            .frame(height: FeedMetrics.pillHeight)
            .background(ThemeGradient.accent, in: shape)
            // The shadow is drawn by the capsule's own shape (rasterised with it), never `.shadow`
            // on the composited pill.
            .cardShadow(.floating, shape: shape, fill: ThemeColor.accent)
            .frame(minHeight: FeedMetrics.actionHitHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(FeedIconPressStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Copy.Feed.newPosts(count))
        .accessibilityHint(Copy.Feed.newPostsHint)
        .accessibilityAddTraits(.isButton)
    }
}
