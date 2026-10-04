import SwiftUI
import UIKit

// A root's own bar that leaves with the scroll — and takes the tab bar with it.
//
// 4 Oct: "In the Schedule, Library the top and bottom header and nav are there even when
// scrolling… That's not very polished and delightful" (owner). The feed and Discover have left with
// the scroll since 25 Sep, each with a header of its own; Schedule and Library still wore the
// SYSTEM navigation bar, which cannot be moved a point at a time (hiding it re-lays the page out
// under it, 59 pt of stale inset at a time). So they get the feed's anatomy: the system bar hidden,
// the app's own row in the page's top safe-area inset, slid up by what the reader has scrolled —
// point for point with the finger, settling shown or gone at rest — and `AppTabBar` rides the same
// state (`ScrollAwayChrome`), so the two leave and return together. Home's `HomeChrome` follows the
// same rule over its billboard.

/// How far a single-page root's bar has gone. Written by the page's scroll probe and its scroll
/// phase; read only by the bar's own small views (`RootChromeSlide`, `RootChromeFade`) and by
/// `AppTabBar` — a scroll frame never re-runs the screen.
@MainActor @Observable
final class RootChromeState: ScrollAwayChrome {
    /// How far the bar has slid up: 0 (all there) … `height` (gone).
    private(set) var offset: CGFloat = 0
    let height: CGFloat

    @ObservationIgnored private var lastY: CGFloat = 0
    /// The READER is moving the page — a finger, or its momentum. A scroll the app made (Schedule
    /// landing on today, a jump from the month grid, a pop to the top) is not a reader scrolling
    /// away, and must not take the bars with it.
    @ObservationIgnored private var following = false

    init(height: CGFloat = FeedMetrics.headerRow) {
        self.height = height
    }

    var awayFraction: CGFloat { offset / height }

    /// The page's scroll distance from its resting top (negative while pulling to refresh).
    func track(_ y: CGFloat) {
        let dy = y - lastY
        lastY = y
        // VoiceOver keeps its bars: one that leaves with a scroll cannot be found again by touch.
        guard following, !UIAccessibility.isVoiceOverRunning else { return }
        let next: CGFloat = y <= 0 ? 0 : min(max(offset + dy, 0), height)
        if abs(next - offset) >= 0.5 || (next == 0 && offset != 0) { offset = next }
    }

    /// The page's scroll phase: only a reader's scroll moves the bar, and at rest it is either
    /// shown or gone — past halfway it finishes leaving, else it returns.
    func phase(_ phase: ScrollPhase) {
        following = phase == .interacting || phase == .decelerating
        guard phase == .idle, offset > 0, offset < height else { return }
        let gone = offset > height / 2 && lastY > height
        withAnimation(Self.motion) { offset = gone ? height : 0 }
    }

    /// The bar comes back (a re-selected tab, a push, a control that opens under it).
    func reveal() {
        guard offset != 0 else { return }
        withAnimation(Self.motion) { offset = 0 }
    }

    private static var motion: Animation {
        ThemeMotion.pick(ThemeMotion.uiSnappy, reduceMotion: UIAccessibility.isReduceMotionEnabled)
    }
}

/// Slides a bar up by what the page has scrolled. With `RootChromeFade`, the only reader of the
/// state's offset: the bar's content is not re-evaluated for a scroll frame.
struct RootChromeSlide: ViewModifier {
    let chrome: any ScrollAwayChrome
    /// The bar's row: what it slides by when it has gone.
    var height: CGFloat = FeedMetrics.headerRow

    func body(content: Content) -> some View {
        content.offset(y: -chrome.awayFraction * height)
    }
}

/// A bar's controls thin out as it leaves (they are gone before its edge reaches the clock).
struct RootChromeFade: ViewModifier {
    let chrome: any ScrollAwayChrome

    func body(content: Content) -> some View {
        content.opacity(Double(1 - min(1, chrome.awayFraction * 1.4)))
    }
}

/// A root's bar row: its title in the app's face, centred, with a control each side — the feed
/// header's row (44 pt, the gutter, 44-pt targets). No ground of its own (`RootHeader` adds one).
struct RootHeaderRow<Leading: View, Trailing: View>: View {
    let title: String
    let chrome: RootChromeState
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        ZStack {
            Text(title)
                .type(ThemeType.bodyEmphasis)
                .foregroundStyle(ThemeColor.textPrimary)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: ThemeSpace.x1) {
                leading()
                Spacer(minLength: ThemeSpace.x2)
                trailing()
            }
        }
        .padding(.horizontal, ThemeMetrics.gutter)
        .frame(height: FeedMetrics.headerRow)
        .modifier(RootChromeFade(chrome: chrome))
    }
}

/// A root's bar: the row on the canvas, flush with the page (no rule, no material — `flushTopBar`'s
/// look), its ground running up through the status band so nothing prints under the clock once the
/// row has gone. For a page's top safe-area inset.
struct RootHeader<Leading: View, Trailing: View>: View {
    let title: String
    let chrome: RootChromeState
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        RootHeaderRow(title: title, chrome: chrome, leading: leading, trailing: trailing)
            .background(alignment: .bottom) {
                ThemeColor.canvas
                    .frame(height: FeedMetrics.headerRow + ThemeMetrics.topSafeInset)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .modifier(RootChromeSlide(chrome: chrome))
    }
}

/// A glyph in a root's bar: the feed header's icon button (bare ink, a 44-pt target).
struct RootHeaderGlyph: View {
    let systemName: String
    var tint: Color = ThemeColor.textPrimary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            AppGlyph(systemName: systemName)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: FeedMetrics.actionHitHeight, height: FeedMetrics.actionHitHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(FeedIconPressStyle())
    }
}

extension View {
    /// Feeds a root's bar from its scroll view: the scroll phase (applied here) — the page's
    /// content reports its own position with `rootChromeProbe`.
    func rootChromePhase(_ chrome: RootChromeState) -> some View {
        onScrollPhaseChange { _, phase in chrome.phase(phase) }
    }

    /// On the scroll CONTENT: reports how far it has scrolled from its resting top (`rest`: where
    /// the content's top sits in the window at rest). Geometry, not `onScrollGeometryChange`, which
    /// never fires on the iOS 27 simulator.
    func rootChromeProbe(_ chrome: RootChromeState, rest: CGFloat) -> some View {
        background {
            Color.clear.onGeometryChange(for: CGFloat.self) { proxy in
                proxy.frame(in: .global).minY
            } action: { minY in
                chrome.track(rest - minY)
            }
        }
    }
}
