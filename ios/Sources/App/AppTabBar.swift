import SwiftUI
import UIKit

/// The app's own bottom bar — X's, not the system's (25 Sep: "iOS nav is too large and it competes
/// with the content too… We need a deep overhaul of this… Use X's not insta's", owner).
///
/// Measured off X on the owner's iPhone (393 pt wide): a 49-pt band above the home indicator,
/// over a veil of the page's own ground (`TabBarVeil` — since 16 Oct, never an opaque band), no
/// dividing rule, the tabs
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

/// Since 19 Oct it FLOATS, as X's and Instagram's do now ("I told you to make the bottom floating
/// nav look like X right?… X / Insta", owner — of a flat row of glyphs printed straight onto the
/// page): a SMALL pill round its icons, centred, lifted off the home indicator, the content running
/// past it and round it ("It should be much smaller", owner, of a full-width capsule). Its ground is
/// native LIQUID GLASS: a pitch-black pill was built first ("pitch black not gradient"), then the
/// same pill on glass beside it ("Show me small liquid glass native floating nav to eye ball the
/// difference"), and the owner chose the glass. Icons only, one ink, the selected one filled — as
/// before. It is still not iOS 26's TAB BAR ("not the native iOS one though"): no labels, no
/// shrinking, no amber; only its material is the system's.
struct AppTabBar: View {
    let selected: AppTab
    /// The scrolling header of the page in front — the feed's, Discover's — else nil. The bar rides
    /// the header's own offset — slid down by the same fraction the header has slid up — so the
    /// two leave together, come back together and settle together.
    var scrollAway: (any ScrollAwayChrome)? = nil
    /// The tabs, in order — the direction's (`Experience.tabs`: Four tabs has no Feed).
    var tabs: [AppTab] = AppTab.allCases
    /// Discover wears a compass (the directions, `Experience.doors`): shows to find, not a search box.
    var compass: Bool = false
    let onSelect: (AppTab) -> Void

    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver

    /// The pill's height: a ~19-pt glyph with 15 pt of air above and below.
    nonisolated static let height: CGFloat = 50
    /// One tab's slot in the pill, and the pill's padding at each end.
    static let slot: CGFloat = 60
    static let endPadding: CGFloat = 6
    /// The glyph's frame. The 30-pt template pads 3 pt each side, so the drawn glyph is ~19 pt.
    static let glyph: CGFloat = 26
    /// How far the capsule sits down into the bottom safe area: just clear of the home indicator
    /// (its foot ~22 pt from the edge, X's). A phone without the indicator lifts it 8 pt instead.
    nonisolated static var bottomOverlap: CGFloat {
        ThemeMetrics.bottomSafeInset > 0 ? min(12, ThemeMetrics.bottomSafeInset) : -8
    }
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
            ForEach(tabs, id: \.self) { tab in
                item(tab).frame(width: Self.slot)
            }
        }
        .padding(.horizontal, Self.endPadding)
        .frame(height: Self.height)
        // Native Liquid Glass (19 Oct: "Let's ship with Liquid glass variant", owner, after the black
        // pill and this one were photographed side by side) — the material below iOS 26, opaque
        // under Reduce Transparency (`chromeGlass`).
        .chromeGlass(in: Capsule(style: .continuous), interactive: true)
        .frame(maxWidth: .infinity)
        // VoiceOver reads a real tab bar: "Home, tab, 1 of 5, selected".
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isTabBar)
    }

    private func item(_ tab: AppTab) -> some View {
        let on = tab == selected
        let icon = compass && tab == .discover ? "TabCompass" : tab.icon
        return Button { onSelect(tab) } label: {
            Image(on ? icon + "Fill" : icon)
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
            Label { Text(tab.label) } icon: { Image(icon).renderingMode(.template) }
        }
    }
}

/// A bar's ground: a VEIL of the page's own ground, not a slab of it (16 Oct: "there is a lot of
/// top and bottom BLACK bars which are taking visible space", owner). The opaque bands were flush
/// only where the page was the canvas; over a tinted page — a show page's hue, Schedule's stage —
/// they printed a black strip across the top and the foot of the screen and hid the content under
/// them. Now the page runs to both edges: under a bar's controls it is dimmed in its own colour,
/// strongest at the screen's edge and gone a ramp past the bar, so there is no edge to read as a
/// bar. NO material: a blur over the dark canvas comes out LIGHTER than the canvas, and the first
/// cut printed exactly the grey band this replaced ("What is this trash?", owner, same day — the
/// 25 Sep lesson again). Reduce Transparency keeps the opaque band.
/// The tab bar's ground (`AppTabBar`) and the roots' headers (`RootHeader`, Schedule's, the feed's)
/// are all this.
struct EdgeVeil: View {
    enum Edge { case top, bottom }

    let edge: Edge
    var ink: Color = ThemeColor.canvas
    /// From the screen's edge: the bar itself (the status band or home-indicator strip included).
    let band: CGFloat
    /// From the screen's edge: the line the bar's controls sit on.
    let line: CGFloat
    /// Past the bar, where the veil runs out.
    var ramp: CGFloat = ThemeMetrics.barEdgeRamp
    /// The veil over a PICTURE that runs up under the bar (Schedule's stage at the landing): the
    /// art shows through the whole bar, dimmed. Otherwise the ground is whole from the edge to the
    /// controls' line, so a row passing under a title or an icon is gone before it reaches it —
    /// a ghost of yesterday's row behind "Schedule" was the second thing wrong with the first cut.
    var overArt = false

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    /// TRANSPARENT (17 Oct: "make the top and bottom bars transparent please! It's heavily
    /// distracting otherwise!", owner — of the veils above): nothing is drawn behind a bar; its
    /// glyphs and words carry their own shadow (`barInk`). Reduce Transparency keeps the opaque band.
    var body: some View {
        Group {
            if reduceTransparency {
                ink.frame(height: band)
            }
        }
        .frame(maxWidth: .infinity)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

extension View {
    /// What keeps a bar's glyphs and words legible with nothing behind them (17 Oct, transparent
    /// bars): a soft shadow of their own, none under Reduce Transparency (whose bars are opaque).
    func barInk() -> some View { modifier(BarInk()) }
}

private struct BarInk: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        content.shadow(color: .black.opacity(reduceTransparency ? 0 : 0.5), radius: 6, x: 0, y: 1)
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
