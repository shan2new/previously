import SwiftUI

// The top of the feed, as X builds its own (round 3, measured from X iOS at 393 pt):
//   · a real BAR — glass over the feed with one crisp hairline, never a gradient that lets the
//     content ghost through it half-lit;
//   · a balanced row: you on the left, the brand in the middle, your activity on the right;
//   · the feed's two rooms as TABS with an underline, directly under the brand;
//   · it gets out of the way — gone on the way down, back the moment you scroll up, tied to the
//     finger and never parked half over a post.

// MARK: - The bar's one moving fact

/// The header's offset, held OUTSIDE the screen's state: the scroll probe WRITES it, and only
/// `FeedHeader` and `FeedPillSlot` read it, so a scroll frame invalidates the bar and nothing else
/// (the app's rule: the scroll offset is never screen state).
///
/// X's bar is tied to the finger, not to a timer: it slides up point for point as you read down,
/// comes back point for point the moment you scroll up, and when the scroll comes to rest it is
/// either all there or all gone.
///
/// X's two rooms are PAGES side by side (a real pager, not a list that swaps its rows): each keeps
/// its own place, the bar follows whichever page is in front, and the tab underline rides the
/// pager's offset while the finger is still moving (`pageProgress`).
@MainActor
@Observable
final class FeedChromeState: ScrollAwayChrome {
    /// X shows its "new posts" pill only once the reader is well down the feed: at the top the new
    /// posts are simply there.
    static let downThreshold: CGFloat = 900

    /// How far the bar has slid up: 0 (all there) … `FeedHeader.height` (gone).
    private(set) var offset: CGFloat = 0
    /// The page in front is more than `downThreshold` points down.
    private(set) var down = false
    /// The pager's position: 0 = Following … 1 = For you, continuous while a swipe is under way.
    /// Read ONLY by the tab row, so a swipe redraws two words and a capsule.
    private(set) var pageProgress: CGFloat
    var hidden: Bool { offset >= FeedHeader.height - 0.5 }
    var awayFraction: CGFloat { offset / FeedHeader.height }

    /// The page in front; the other page's probe is recorded, never acted on.
    @ObservationIgnored private var page: FeedTab
    /// Each page's last scroll distance (a page keeps its place, so its bar picks up from there).
    @ObservationIgnored private var lastY: [FeedTab: CGFloat] = [:]
    /// `-feedPinHeader 1`: captures that jump to a post keep the bar in shot.
    private let pinned = FeedCapture.pinHeader

    init(page: FeedTab) {
        self.page = page
        pageProgress = Self.progress(of: page)
    }

    /// A page's resting progress: its index in the pager.
    static func progress(of page: FeedTab) -> CGFloat {
        CGFloat(FeedTab.allCases.firstIndex(of: page) ?? 0)
    }

    /// One page's scroll distance from its resting top (negative while pulling to refresh).
    func track(_ y: CGFloat, page p: FeedTab) {
        let previous = lastY[p] ?? 0
        lastY[p] = y
        guard p == page else { return }
        let dy = y - previous
        let isDown = y > Self.downThreshold
        if isDown != down { down = isDown }
        guard !pinned else { return }
        let next: CGFloat = y <= 0 ? 0 : min(max(offset + dy, 0), FeedHeader.height)
        if abs(next - offset) >= 0.5 || (next == 0 && offset != 0) { offset = next }
    }

    /// At rest the bar is either shown or gone: past halfway it finishes leaving, else it returns.
    func settle(page p: FeedTab) {
        guard p == page, !pinned, offset > 0, offset < FeedHeader.height else { return }
        let gone = offset > FeedHeader.height / 2 && (lastY[p] ?? 0) > FeedHeader.height
        withAnimation(Self.motion) { offset = gone ? FeedHeader.height : 0 }
    }

    /// The bar comes back (the wordmark's scroll to top, a page change, the pill).
    func reveal() {
        guard offset != 0 else { return }
        withAnimation(Self.motion) { offset = 0 }
    }

    /// The pager put `p` in front: the bar comes back (it carries the tabs that say where you are)
    /// and the pill's "well down" is that page's own.
    func activate(_ p: FeedTab) {
        guard p != page else { return }
        page = p
        let isDown = (lastY[p] ?? 0) > Self.downThreshold
        if isDown != down { down = isDown }
        reveal()
    }

    /// The pager's offset as a fraction of a page (the probe on the pager's content).
    func setPageProgress(_ value: CGFloat) {
        let v = min(max(value, 0), CGFloat(FeedTab.allCases.count - 1))
        let landed = v == v.rounded()
        if abs(v - pageProgress) >= 0.002 || (landed && v != pageProgress) { pageProgress = v }
    }

    private static var motion: Animation {
        ThemeMotion.pick(ThemeMotion.uiSnappy, reduceMotion: UIAccessibility.isReduceMotionEnabled)
    }
}

// MARK: - The header

struct FeedHeader: View {
    /// Measured on X iOS: a 44-pt row (avatar · logo · bell), a 44-pt tab row, one rule.
    static var height: CGFloat { FeedMetrics.headerRow + FeedMetrics.headerTabs + FeedMetrics.hairline }

    /// The page in front (the one the pager has settled on).
    let selected: FeedTab
    let chrome: FeedChromeState
    let unread: Int
    let onProfile: () -> Void
    let onActivity: () -> Void
    /// The wordmark scrolls the feed to the top, as X's logo does; so does the selected tab.
    let onTop: () -> Void
    /// A tab tapped: the pager slides to it.
    let onSelect: (FeedTab) -> Void
    /// The status band the bar slides under (the window's, unless the host measured its own).
    var topInset: CGFloat = ThemeMetrics.topSafeInset

    @Environment(AuthManager.self) private var auth
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The bell rings once when there is something new to see.
    @State private var rang = 0
    /// The mark's width in the bar: the cut P stands ~24 pt tall, X's logo's height.
    static let markWidth: CGFloat = 17

    var body: some View {
        VStack(spacing: 0) {
            // X's row: you on the left, the mark alone in the middle, one quiet control on the
            // right. Monochrome — the logo's full stop is the only colour in the bar.
            ZStack {
                Button(action: onTop) {
                    PreviouslyMark(width: Self.markWidth, style: .glyph, ink: ThemeColor.feedText)
                        .padding(.horizontal, ThemeSpace.x3)
                        .frame(minHeight: FeedMetrics.headerRow)
                        .contentShape(Rectangle())
                }
                .buttonStyle(FeedIconPressStyle())
                .accessibilityLabel(Copy.Feed.scrollToTop)
                HStack(spacing: 0) {
                    Button(action: onProfile) {
                        AccountDisc(identity: auth.identity, diameter: Self.discDiameter, quiet: true)
                            .frame(width: FeedMetrics.actionHitHeight, height: FeedMetrics.actionHitHeight,
                                   alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(FeedIconPressStyle())
                    .accessibilityLabel(Copy.Feed.profile)
                    Spacer(minLength: 0)
                    bell
                }
            }
            .padding(.horizontal, ThemeMetrics.gutter)
            .frame(height: FeedMetrics.headerRow)

            FeedTabsRow(selected: selected, chrome: chrome, onSelect: onSelect, onTop: onTop)
            Rectangle().fill(ThemeColor.feedSeparator).frame(height: FeedMetrics.hairline)
        }
        .background { FeedHeaderGround() }
        .offset(y: -chrome.offset)
        // The status band keeps its own glass, drawn OVER the sliding bar, so the bar passes under
        // it instead of through the clock — X's, point for point.
        .overlay(alignment: .top) {
            FeedHeaderGround()
                .frame(height: topInset)
                .offset(y: -topInset)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
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
    private static let discDiameter: CGFloat = 32
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

/// X's tabs: the width split between them, both words bold 16 (measured, round 3), so nothing
/// reflows under the underline. The underline and the ink FOLLOW THE PAGER (X's): while the finger
/// drags the page, the capsule slides and stretches from one word to the other and the ink moves
/// with it; a tap slides the pager and the capsule rides the same animation. This row is the only
/// reader of `pageProgress`. No haptic: a tab is not a write (the app's rule).
private struct FeedTabsRow: View {
    let selected: FeedTab
    let chrome: FeedChromeState
    let onSelect: (FeedTab) -> Void
    let onTop: () -> Void

    /// Each word's frame in the row, for the capsule's two ends.
    @State private var words: [FeedTab: CGRect] = [:]

    /// X's underline: 3 pt, and 11 pt wider than the word on each side.
    private static let underlineHeight: CGFloat = 3
    private static let underlineOverhang: CGFloat = 11
    private static let space = "feedTabsRow"

    var body: some View {
        let p = chrome.pageProgress
        HStack(spacing: 0) {
            ForEach(Array(FeedTab.allCases.enumerated()), id: \.element) { index, t in
                // 1 on the page in front, 0 a page away, in between mid-swipe.
                let lit = max(0, 1 - abs(p - CGFloat(index)))
                Button {
                    if t == selected { onTop() } else { onSelect(t) }
                } label: {
                    word(t, ink: ThemeColor.feedSecondary)
                        .overlay { word(t, ink: ThemeColor.feedText).opacity(lit) }
                        .onGeometryChange(for: CGRect.self) { proxy in
                            proxy.frame(in: .named(Self.space))
                        } action: { frame in
                            if words[t] != frame { words[t] = frame }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .frame(height: FeedMetrics.headerTabs)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(t == selected ? .isSelected : [])
            }
        }
        .overlay(alignment: .bottomLeading) { underline(p) }
        .coordinateSpace(.named(Self.space))
    }

    private func word(_ t: FeedTab, ink: Color) -> some View {
        Text(Copy.Feed.tab(t))
            .type(ThemeType.feedTab)
            .foregroundStyle(ink)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }

    /// The capsule between the two words' measured frames, `p` of the way across.
    @ViewBuilder
    private func underline(_ p: CGFloat) -> some View {
        let tabs = FeedTab.allCases
        if let first = tabs.first, let last = tabs.last, let a = words[first], let b = words[last] {
            let width = a.width + (b.width - a.width) * p + 2 * Self.underlineOverhang
            let midX = a.midX + (b.midX - a.midX) * p
            Capsule()
                .fill(ThemeColor.feedText)
                .frame(width: width, height: Self.underlineHeight)
                .offset(x: midX - width / 2)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

/// The bar's ground: the feed's own canvas, FLUSH with the content (X's and Instagram's, 25 Sep —
/// "the header area in both X and Instagram is flush (same background color) as content", owner).
/// The material under canvas at the bars' 0.74 read as a lighter grey band across the top of the
/// feed even with nothing under it: a system material lightens by itself in dark mode. The bar
/// hides on the way down, so what passes under it is rarely seen; the hairline under the tabs is
/// the only edge it draws.
struct FeedHeaderGround: View {
    var body: some View {
        ThemeColor.canvas
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
