import SwiftUI

// The show's STAGE — the one billboard Home, the show page and Schedule's card draw (9 Oct, "Home's
// billboard, continued": design/show-page-2026-10-09/DIRECTION.md). The picture grammar Home taught
// (26 Sep, `HomeHeroScene.swift`): the show's best-looking POSTER (`PosterPick`) composited whole in
// a frame nearly its own shape, breathing (`ArtHeader(drift:)`) and stretching with a pull, moving at
// a little under half the page's speed and leaning with the phone (`HeroTilt`), a scrim sized to the
// copy that lands on the page's ground, and the lockup in a pool of the poster's own light. The
// arrival plays as the launch's curtain lifts (never under it): the picture settles into focus, the
// logo resolves out of a blur with a halo of its own light, the words rise beneath it. Everything
// still is Reduce Motion's.
//
// The LOCKUP is the caller's — Home's badge, episode and mark (`HomeBillboard`), the show page's
// state and action row (`FranchiseDetailView`) — handed the name the stage settled on (the logo on a
// clean picture, type otherwise) and the arrival to ride (`BillboardArrival`).

/// The arrival the lockup rides: `line(_:)` for a line of copy (`index` beats after the first —
/// Apple TV's billboard copy) and `logo` for the title card resolving out of its blur.
struct BillboardArrival {
    let arrived: Bool
    let logoIn: Bool
    let reduceMotion: Bool

    func line(_ index: Int) -> HomeArrival {
        HomeArrival(shown: arrived, delay: Double(index) * 0.07, reduceMotion: reduceMotion)
    }

    var logo: LogoResolve { LogoResolve(shown: logoIn, reduceMotion: reduceMotion) }
}

/// A line of the billboard's copy arriving: 10 pt below and clear, then in place — on one gentle
/// curve, `delay` after the first. Under Reduce Motion it is simply there.
struct HomeArrival: ViewModifier {
    let shown: Bool
    let delay: Double
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        content
            .opacity(shown || reduceMotion ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 10)
            .animation(reduceMotion ? nil : ThemeMotion.uiGentle.delay(delay), value: shown)
    }
}

struct ShowBillboard<Lockup: View>: View {
    let franchise: Franchise
    let height: CGFloat
    /// The status bar and the bar's row: the veil protects it, and a titled poster starts under it.
    let band: CGFloat
    /// The palette colour of the art (the caller resolves it: the page is painted from it too) and
    /// the ground the frame lands on — the show's hue at canvas depth.
    var tint: Color? = nil
    var landing: Color = ThemeColor.canvas
    /// The picture is a button when set (Home: it opens the show); nil on the show's own page.
    var onOpen: (() -> Void)? = nil
    var onArtLoaded: (() -> Void)? = nil
    /// The lockup's top in the window, for the bar (`HomeChrome.trackCopy`; the show page's dock).
    var onCopyTop: ((CGFloat) -> Void)? = nil
    /// The picture the billboard settled on — the page is painted from its colour.
    var onArt: ((String?) -> Void)? = nil
    var onLightingChange: ((HomeLockupLighting) -> Void)? = nil
    /// This billboard reports to the bar and the launch (`onCopyTop`, `onLightingChange`,
    /// `onArtLoaded`): the pager's front page only, so three pages do not take turns writing the
    /// chrome's one fact.
    var reportsChrome: Bool = true
    /// What VoiceOver says for the picture.
    var accessibilityLabel: String = ""
    var accessibilityHint: String? = nil
    /// A pull stretches the picture up — on a billboard at the PAGE'S TOP. A card mid-feed
    /// (Schedule's, with the past above it) sits below the scroll view's top at rest, which the
    /// stretch would read as a pull.
    var pullStretch: Bool = true
    /// The share of the poster that shows above the words, for `PosterPick.billboardName(visible:)`
    /// — a shorter card shows less of the poster, and a logotype in the hidden band is not in view.
    var visibleBand: ClosedRange<Double>? = nil
    @ViewBuilder let lockup: (BillboardName, BillboardArrival) -> Lockup

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The launch in progress: the arrival plays as its curtain lifts, not under it.
    @Environment(LaunchHandoff.self) private var launch: LaunchHandoff?
    @State private var lightness: Double?
    @State private var copyHeight: CGFloat = 220
    /// The lockup has arrived (once per billboard): the words rise in over the art, a beat apart.
    @State private var arrived = false

    /// The splash has begun to lift (always, after a launch).
    private var curtainUp: Bool { launch?.emerging ?? true }
    /// The picture and the name this billboard settled on (`settle`) — never changed under the
    /// reader afterwards.
    @State private var settled: Shown?
    /// The picture is on screen; then the logo has resolved (the arrival, `stage`).
    @State private var artIn = false
    @State private var logoIn = false

    struct Shown: Equatable {
        let art: WideArt
        let name: BillboardName
    }

    /// How long the billboard waits for the show's pick (`PosterPick`, graded on first sight) before
    /// it takes the catalogue's own picture. A pick is kept for good, so this is a first visit's wait.
    private static var pickPatience: Duration { .milliseconds(2000) }

    private var lighting: HomeLockupLighting {
        HomeLockupLighting(copyHeight: copyHeight, visible: artIn && curtainUp)
    }

    /// A pick made before this billboard existed — on its first frame.
    private var storedPick: Shown? { PosterPick.shared.choice(for: franchise).map(shown(from:)) }

    private func shown(from pick: PosterPick.Choice) -> Shown {
        let name = visibleBand.map { pick.billboardName(for: franchise, visible: $0) } ?? pick.billboardName(for: franchise)
        return Shown(art: WideArt.billboard(portrait: pick.url, landscape: nil), name: name)
    }

    /// The show's best-looking poster, any season ("choose the best-looking poster, even if it is
    /// from an earlier season", owner, 26 Sep), when it is known or becomes known within
    /// `pickPatience`; else the catalogue's selection. Once.
    private func settle() async {
        let f = franchise
        if settled == nil, !PosterPick.candidates(for: f).isEmpty {
            let deadline = ContinuousClock.now + Self.pickPatience
            while PosterPick.shared.choice(for: f) == nil, ContinuousClock.now < deadline, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        guard !Task.isCancelled, settled == nil else { return }
        let pick = PosterPick.shared.choice(for: f)
        let next = pick.map(shown(from:)) ?? Shown(art: f.billboardArt, name: f.billboardName)
        PerfProbe.mark("billboard-settled", pick == nil ? "catalogue" : "pick")
        settled = next
        onArt?(next.art.url)
    }

    /// The picture is on screen (the launch waits for this). Its arrival — into focus, then the
    /// logo, then the words — plays once the curtain is up (`stage`).
    private func artLoaded() {
        if reportsChrome { onArtLoaded?() }
        if !artIn { artIn = true }
    }

    /// The arrival, once the picture is here AND the splash is lifting: the picture settles into
    /// focus now, the words rise from a beat later, the logo resolves among them.
    private func stage() async {
        guard artIn, curtainUp, !arrived else { return }
        try? await Task.sleep(for: .milliseconds(reduceMotion ? 0 : 120))
        // The title card first — the logo resolves as the badge lands — then the words beneath.
        logoIn = true
        arrived = true
    }

    var body: some View {
        // Nothing but the ground until the picture is settled: never one poster, then another.
        let shown = settled ?? storedPick
        let art = shown?.art ?? WideArt(landscape: nil, portrait: nil)
        let name = shown?.name ?? franchise.billboardName
        let strength = HeroProtection.strength(lightness: lightness)
        let h = height
        let still = reduceMotion
        ZStack(alignment: .bottom) {
            picture(art: art, name: name, height: h, still: still, strength: strength)
                // A pull stretches the picture up into the space it opens, from its foot; scrolling
                // on, it moves at a little under half the page's speed — depth, read from geometry
                // in the render pass (`visualEffect`), so neither ever re-runs a body.
                .visualEffect { content, proxy in
                    // The VERTICAL scroll view's: inside Home's pager the nearest one scrolls sideways.
                    let y = proxy.frame(in: .scrollView(axis: .vertical)).minY
                    let pull = pullStretch ? max(0, y) : 0
                    let push = still ? 0 : min(max(0, -y), h) * 0.42
                    return content
                        .scaleEffect(1 + pull / max(h, 1), anchor: .bottom)
                        .offset(y: push)
                }
                // Nothing of the PICTURE below the frame — it leans and moves with the scroll inside
                // it — while a pull may still stretch it up past the top. The picture alone: the
                // lockup's light is not cut here (below).
                .clipShape(BelowClip())
                .accessibilityLabel(accessibilityLabel)
                .accessibilityHint(accessibilityHint ?? "")

            HeroCopyScrim(copyHeight: copyHeight, strength: strength, landing: landing)
                // The lockup sits in a pool of the poster's own light, not on a dead ground. An
                // ellipse that is spent at its own rim, centred on the lockup and free to run past
                // the billboard's foot onto the page (an overlay, so its size is not the
                // billboard's): as a circle wider than its frame, cut again by the billboard, it
                // ended on two straight lines under the mark ("the seam looks ugly", owner, 4 Oct).
                .overlay(alignment: .bottom) {
                    HomeLockupGlow(tint: tint, lighting: lighting)
                        .offset(y: HomeLockupGlow.height / 2 - lighting.bottomInset)
                }

            lockup(name, BillboardArrival(arrived: arrived, logoIn: logoIn, reduceMotion: reduceMotion))
                .padding(.horizontal, ThemeMetrics.gutter)
                .padding(.bottom, ThemeSpace.x5)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { copyHeight = $0 }
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { if reportsChrome { onCopyTop?($0) } }
        }
        .frame(height: h)
        .frame(maxWidth: .infinity)
        .onAppear { if !reduceMotion { HeroTilt.shared.start() } }
        .onDisappear { if !reduceMotion { HeroTilt.shared.stop() } }
        .task(id: art.url) {
            guard art.url != nil else { return }
            _ = await PaletteCache.shared.resolve(url: art.url, maxPixel: 360)
            lightness = PaletteCache.shared.lightness(for: art.url)
        }
        .task(id: franchise.id) { await settle() }
        .task {
            // The arrival is staged on the picture and the curtain (`stage`); this is the net for a
            // billboard whose picture never comes. Under Reduce Motion the words are simply there.
            guard !arrived else { return }
            if reduceMotion {
                arrived = true
                logoIn = true
                return
            }
            try? await Task.sleep(for: .milliseconds(3000))
            if !arrived { arrived = true; logoIn = true }
        }
        .task(id: artIn && curtainUp) { await stage() }
        .onChange(of: lighting, initial: true) { _, next in if reportsChrome { onLightingChange?(next) } }
        // A page brought to the front reports what the bar has not heard from it.
        .onChange(of: reportsChrome) { _, now in if now { onLightingChange?(lighting) } }
    }

    /// The picture: a button where the billboard opens its show, the art alone on the show's page.
    @ViewBuilder
    private func picture(art: WideArt, name: BillboardName, height h: CGFloat, still: Bool, strength: Double) -> some View {
        let art = ArtHeader(url: art.url, height: h, tint: tint, scrimTop: 0, scrimBottom: 0,
                            focus: .top, portraitSource: art.portraitSource, portraitFill: true, drift: true,
                            ultraWide: art.ultraWide, onArtLoaded: artLoaded,
                            // A poster's own logotype is INK a veil cannot remove: a name set in
                            // type starts its poster under the bar (the old Today's rule).
                            topInset: name == .type ? band : 0,
                            groundDim: HeroProtection.groundDim(strength)) { EmptyView() }
            // The picture arrives into focus, and leans with the phone — a hair larger than
            // its frame, so a lean never shows an edge.
            .modifier(FocusSettle(settled: artIn && curtainUp, reduceMotion: reduceMotion))
            .scaleEffect(still ? 1 : 1.035, anchor: .center)
            .modifier(TiltShift(amount: still ? 0 : 6))
        if let onOpen {
            Button(action: onOpen) { art }
                .buttonStyle(.plain)
        } else {
            art
        }
    }
}
