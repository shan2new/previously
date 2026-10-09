import SwiftUI
import UIKit

/// The app's own bottom bar — X's, not the system's (25 Sep: "iOS nav is too large and it competes
/// with the content too… We need a deep overhaul of this… Use X's not insta's", owner).
///
/// Measured off X on the owner's iPhone (393 pt wide): a 49-pt band above the home indicator,
/// FLUSH with the page (X's black; ours is the page's opaque ground), no dividing rule, the tabs
/// in equal slots across the whole width, ICONS ONLY — no labels — every glyph in one ink, and the
/// selected tab told apart by its glyph alone: filled where the others are outlines (search goes
/// heavier, having nothing to fill). The glyphs draw ~21 pt at a ~2-pt stroke, centred in the band.
///
/// What it replaced: iOS 26's floating glass pill — ~62 pt of capsule with a label under every
/// icon, lifted off the bottom edge and floating OVER the content, with an amber selected tab: the
/// largest thing on every screen that was not content. The system bar is still the `TabView`'s
/// (it keeps each tab's state and lifecycle); it is hidden (`MainTabView`) and this is drawn in its
/// place as a safe-area inset, so every scroll view stops above it with no clearance of its own.
///
/// On the FEED and on DISCOVER it scrolls away with the header and comes back with it, as X's does
/// ("it should vanish… Like X… Only in Feed", then "Discover also needs the scroll treatment like
/// in Today", owner, 25 Sep — `scrollAway`); on every other page it stays put.
/// It goes UNDER the keyboard, as X's does, instead of riding up on it (`KeyboardPresence`).
/// A header that scrolls away with the page it heads — the feed's (`FeedChromeState`) and
/// Discover's (`DiscoverChromeState`) — which the bottom bar rides.
@MainActor
protocol ScrollAwayChrome: AnyObject {
    /// How far the header has gone: 0 (all there) … 1 (gone).
    var awayFraction: CGFloat { get }
    /// The header (and the bar with it) comes back: a re-selected tab, a push, a pop.
    func reveal()
}

struct AppTabBar: View {
    let selected: AppTab
    /// An opaque surface matching the page; artwork never competes with the icons.
    var ground: Color = ThemeColor.canvas
    /// The scrolling header of the page in front — the feed's, Discover's — else nil. The bar rides
    /// the header's own offset — slid down by the same fraction the header has slid up — so the
    /// two leave together, come back together and settle together.
    var scrollAway: (any ScrollAwayChrome)? = nil
    let onSelect: (AppTab) -> Void

    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver

    /// The band above the home indicator — UIKit's tab-bar height, and X's.
    nonisolated static let height: CGFloat = 49
    /// The glyph's frame. The 30-pt template pads 3 pt each side, so the drawn glyph is ~20 pt
    /// at a ~1.9-pt stroke (X: 20.7 / 2.0).
    static let glyph: CGFloat = 28
    /// Use part of the bottom safe area to bring the icon row closer to the edge.
    /// Retain the rest for the home gesture; phones without that inset keep the normal layout.
    nonisolated static var bottomOverlap: CGFloat { min(18, ThemeMetrics.bottomSafeInset) }
    /// The space every page reserves above the window's own bottom safe area.
    nonisolated static var reservedHeight: CGFloat { height - bottomOverlap }

    /// How far the bar has gone: 0 (all there) … 1 (off the bottom edge). VoiceOver keeps it —
    /// a bar that leaves with a scroll is one the reader cannot find again by touch.
    private var away: CGFloat {
        guard let scrollAway, !voiceOver else { return 0 }
        return min(1, max(0, scrollAway.awayFraction))
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let away = away
        bar
            .offset(y: Self.bottomOverlap)
            // Its whole visible height, including the home-indicator strip, clears the edge.
            .offset(y: away * ThemeMetrics.tabBarVisualHeight)
            // Leaving the feed with the bar away (a post opened, a show) brings it back in a
            // slide, not a jump — keyed on the SOURCE only, so a scroll still moves it point for
            // point with the finger, never behind it.
            .animation(ThemeMotion.pick(ThemeMotion.uiSnappy, reduceMotion: reduceMotion),
                       value: scrollAway.map { ObjectIdentifier($0) })
            .accessibilityHidden(away >= 1)
    }

    private var bar: some View {
        HStack(spacing: 0) {
            ForEach(AppTab.allCases, id: \.self) { tab in
                item(tab)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: Self.height)
        .background {
            ground.ignoresSafeArea(edges: .bottom)
        }
        // VoiceOver reads a real tab bar: "Home, tab, 1 of 5, selected".
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isTabBar)
    }

    private func item(_ tab: AppTab) -> some View {
        let on = tab == selected
        return Button { onSelect(tab) } label: {
            Image(on ? tab.selectedIcon : tab.icon)
                .renderingMode(.template)
                .resizable()
                .frame(width: Self.glyph, height: Self.glyph)
                .foregroundStyle(ThemeColor.feedText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(FeedIconPressStyle())
        .accessibilityLabel(tab.label)
        .qaIdentifier("qa.tab.\(tab == .today ? "feed" : String(describing: tab))")
        .accessibilityAddTraits(on ? [.isSelected] : [])
        // The bar keeps its size at every text size, as the system's does; at the accessibility
        // sizes a long press shows the tab large (the system bar's large content viewer).
        .accessibilityShowsLargeContentViewer {
            Label { Text(tab.label) } icon: { Image(tab.icon).renderingMode(.template) }
        }
    }
}

/// The visible page reports its ground so the persistent navigation meets it without a seam.
struct TabBarGroundKey: PreferenceKey {
    // Unstyled overlays must not replace the page color when preferences are combined.
    static var defaultValue: Color? { nil }
    static func reduce(value: inout Color?, nextValue: () -> Color?) {
        if let next = nextValue() { value = next }
    }
}

private struct TabBarGroundActionKey: EnvironmentKey {
    static var defaultValue: (Color) -> Void { { _ in } }
}

extension EnvironmentValues {
    var tabBarGroundChanged: (Color) -> Void {
        get { self[TabBarGroundActionKey.self] }
        set { self[TabBarGroundActionKey.self] = newValue }
    }
}

/// Report from each page's own hosting controller. Preferences do not cross NavigationStack's
/// destination hosts. A covered page may finish loading artwork, but must not recolor the bar.
struct TabBarGroundReporter: ViewModifier {
    @Environment(\.tabBarGroundChanged) private var report
    @State private var ground = ThemeColor.canvas
    @State private var visible = false

    func body(content: Content) -> some View {
        content
            .onPreferenceChange(TabBarGroundKey.self) { next in
                ground = next ?? ThemeColor.canvas
                if visible { report(ground) }
            }
            .onAppear {
                visible = true
                report(ground)
            }
            .onDisappear { visible = false }
    }
}

/// Whether the software keyboard covers the bottom of the window — the one thing that takes
/// `AppTabBar` off screen. X's bar sits UNDER the keyboard; a bar inset into the safe area would
/// otherwise ride up on top of it.
///
/// Read from the keyboard's FRAME, not from "will show": the launch's unseen warm-up
/// (`KeyboardWarmup`) presents a keyboard with an empty input view — a zero-height frame — and a
/// hardware keyboard shows only a short shortcut bar; neither may blink the bar.
@MainActor @Observable
final class KeyboardPresence {
    static let shared = KeyboardPresence()

    private(set) var covering = false

    /// A keyboard shorter than this is a shortcut bar or the warm-up's empty input view.
    @ObservationIgnored private let threshold: CGFloat = 120
    @ObservationIgnored private var installed = false

    func install() {
        guard !installed else { return }
        installed = true
        let center = NotificationCenter.default
        center.addObserver(forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main) { n in
            guard let end = (n.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue else { return }
            MainActor.assumeIsolated {
                KeyboardPresence.shared.update(overlap: max(0, ThemeMetrics.windowHeight - end.minY))
            }
        }
        center.addObserver(forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { KeyboardPresence.shared.update(overlap: 0) }
        }
    }

    private func update(overlap: CGFloat) {
        let next = overlap > threshold
        guard next != covering else { return }
        // On the keyboard's own clock, so the bar leaves (and returns) with the keyboard's edge.
        withAnimation(ThemeMotion.keyboard) { covering = next }
    }
}
