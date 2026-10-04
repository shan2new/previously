import SwiftUI
import UIKit

// The interaction-system tokens (spec v8, board 10/11). Exact values, no ranges. The legacy
// `Theme` statics stay for screens not yet migrated; new surfaces use these namespaces only.

extension Color {
    init(hex: UInt32, alpha: Double = 1.0) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }
}

enum ThemeColor {
    // Canvas
    static let canvas = Color(hex: 0x09090B)
    static let canvasRaised = Color(hex: 0x0D0E11)
    // Opaque content surfaces.
    //
    // These are the RESULT of `plateLift` / `raisedLift` composited over `canvas`, so a screen that
    // reaches for the token directly and a container that goes through `.surface(_:)` land on the
    // same colour. The shipped values (#121318 / #181A20) were a 9-value 8-bit step off a #09090B
    // canvas and 6 values apart from each other — Apple's dark grouped step is roughly twice that,
    // which is why every container still needed an outline to exist.
    static let surfaceFlat = Color(hex: 0x171719)
    static let surfaceRaised = Color(hex: 0x242428)
    /// Graphite, the board's own (`FlapGeometry`): these two were a cool blue-grey (#2A2D36,
    /// #353842) beside neutral plates and warm ink — a second temperature in one ramp (4 Oct).
    static let surfaceFloating = Color(hex: 0x2C2B32)
    static let surfacePressed = Color(hex: 0x38373F)
    // Text
    static let textPrimary = Color(hex: 0xF4F1EC)
    static let textSecondary = Color(hex: 0xAAA6A0)
    static let textTertiary = Color(hex: 0x85817C)
    /// The quietest ink that is still *read*. #6C6965 measured 3.29:1 on the canvas — legal for a
    /// chevron (decoration, 3:1) and wrong for the section counts and index letters this token is
    /// also assigned to. #807C77 is ≈4.6:1 and nothing else in the ramp moves.
    static let textDisabled = Color(hex: 0x807C77)
    // Brand
    static let accent = Color(hex: 0xF0A24E)
    /// The full stop. The app icon's coral bead (design/app-icon-v2/glass/x9-final.icon), and the
    /// period of "Previously." everywhere the name is set — the launch still, the header, the
    /// sign-in gate, the colophon — so the icon's two objects are the wordmark's two objects. It is
    /// not amber (amber is a fact or a state) and it is not an action colour: it is the name's.
    static let brandPeriod = Color(hex: 0xF0563F)
    static let accentPressed = Color(hex: 0xD88D3B)
    /// The accent as a LIT MATERIAL (4 Oct: "the selection ring doesn't feel as premium… improve
    /// the design system and colours everywhere", owner). Flat #F0A24E across a capsule or round a
    /// card is a swatch of orange; the same hue lit from above — a bright crown, a shaded foot — is
    /// an object. These two are the ends of that light (`ThemeGradient`); `accent` stays the hue
    /// every flat use reads (a word, a 2-pt bar, a tag).
    static let accentHigh = Color(hex: 0xFFC27A)
    static let accentDeep = Color(hex: 0xE2852E)
    /// NEWS red — "NEW EPISODE", "NEW SEASON", "NEW SERIES", the episode list's NEW tag and the
    /// Activity bell's unread dot (`ThemeColor.unreadDot`, FeedTokens.swift — the same "something
    /// new"), and nothing else (24 Sep, owner: "New Episode is not standing out properly despite the shimmer
    /// … think of using a Netflix like red"). An amber tag over warm art, 40 pt above the amber
    /// capsule, was one more amber thing; the streaming apps flag what is NEW in red. White ink.
    static let news = Color(hex: 0xE5262D)
    static let newsDeep = Color(hex: 0xB8161D)
    static let onNews = Color.white
    static let accentSoft = Color(hex: 0xF0A24E).opacity(0.14)
    /// Immediate ground for an artwork wash before a remote image or its palette is available.
    /// It must be visibly warmer than `canvas`: a near-black fallback made a cold device launch
    /// look as though the gradient had not rendered, while a cache-warm simulator showed the art.
    static let ambientBackdropFallback = Color(hex: 0x432D21)
    static let onAccent = Color(hex: 0x0B0B0D)
    /// The ink of a bare interactive word or glyph — "See all", "Read more", "Clear", "Sync now",
    /// "Details", "Add", "Done", a tertiary button in an empty state.
    ///
    /// **Amber is not an action colour.** It is rationed to two readings and neither is "tappable":
    ///   · MEANING — a real next step ("Returns Oct 2", "Episode 19 next", a future air time);
    ///   · STATE   — today, owned, selected, an active filter, a committed mark.
    /// Amber may also be a GROUND (`PrimaryButtonStyle2`'s capsule, `MarkRing`'s fill, `accentSoft`
    /// discs) — there the amber is the object and the ink on it is `onAccent`, so no amber *word*
    /// is drawn and nothing competes.
    ///
    /// Before this token, twenty tappable words and glyphs wore `accent` and collided head-on with
    /// the first reading: Detail's toolbar said "+ Add" in amber directly above "Episode 14 next"
    /// in amber, and a Library section header put an amber "See all" over amber "Returns Oct 2"
    /// captions. One hue cannot mean "this is a fact about your future" and "this is a button".
    /// Search's add control had it right all along — the actionable `+` is neutral and only the
    /// owned `✓` is amber (`SearchComponents.swift`).
    ///
    /// A bare action carries its affordance the way iOS lists do: position (a toolbar slot, a
    /// section header's trailing edge), semibold weight, a 44-pt target, and a chevron where the
    /// row has one. An alias, not a new colour — if this ever needs its own hue, it changes here.
    ///
    /// One clarification the STATE reading needs, settled once (cohesion pass, 30 Aug): a
    /// selector's SELECTED value is legal amber (it is a state, like an active filter) — *except*
    /// inside a control where amber already carries another meaning. Schedule's ticker is that
    /// exception: amber is today's alone there, so its selection is a neutral raised plate.
    /// Library's root tabs keep the amber selection; the two controls are answering different
    /// constraints, not disagreeing.
    static let interactive = textPrimary
    // Semantic
    static let success = Color(hex: 0x30D158)
    static let warning = Color(hex: 0xFFD60A)
    static let destructive = Color(hex: 0xFF453A)
    static let information = Color(hex: 0x64D2FF)
    // Structure
    static let separator = Color.white.opacity(0.08)
    static let stroke = Color.white.opacity(0.12)
    static let strokeStrong = Color.white.opacity(0.20)
    /// The unmarked `MarkRing`'s stroke. `strokeStrong` at 1.5 pt over a dark poster read as a
    /// disabled ghost — the app's core control was the least visible element on its row. The mark's
    /// idle state is an INVITATION and gets its own, clearly-drawn weight.
    static let markRingIdle = Color.white.opacity(0.34)
    /// Skeleton fill. At 8 % over the old #09090B canvas the structure was ~4 % above ground and
    /// effectively invisible; it has to read as the shape of what is coming.
    static let skeleton = Color(hex: 0xF4F1EC).opacity(0.11)
    static let focusRing = Color(hex: 0xF0A24E).opacity(0.70)
    // Overlays
    static let scrim = Color.black.opacity(0.56)
    static let scrimStrong = Color.black.opacity(0.72)

    // MARK: - Edges (polish pass)
    //
    // On a #09090B ground an outline all the way round a card is the cheapest possible way to say
    // "this is a surface" — it is what a wireframe does. A premium dark UI separates surfaces by
    // TONE and lights their top edge, the way a physical object catches light. These four tokens
    // exist so no screen ever reaches for `stroke` to make a card visible again.

    /// 1-px highlight along the TOP edge of a raised surface, fading out by its vertical centre.
    /// This is the only "stroke" a content card is allowed.
    static let hairline = Color.white.opacity(0.055)
    /// Divider INSIDE a plate. `separator` (0.08) repeated eight times down one list reads as a
    /// spreadsheet; at 0.045 the eye reads grouping instead of ruling.
    static let separatorQuiet = Color.white.opacity(0.045)
    /// The edge of artwork. Never `stroke` — a 12 %-white outline around a bright poster is a
    /// picture frame, and around a dark poster it is a glow. Just enough to stop art bleeding
    /// into the canvas: at 5 % a near-black poster dissolved into #09090B entirely, so 9 % is the
    /// floor at which the art still has a boundary and a bright poster still has no frame.
    static let posterEdge = Color.white.opacity(0.09)

    // MARK: - Surface lifts
    //
    // A surface is a RELATIVE lift, not an absolute fill. The shipped `.plate` painted opaque
    // `surfaceFlat` wherever it landed, so on any screen carrying an `ArtBackdrop` the ambient wash
    // lifted the canvas AROUND the plate and the plate itself inverted into a hole 13 levels darker
    // than its own ground — measured on Library, where it is the first element on the screen.
    // Painting white over whatever is beneath means a plate is always *above* its ground.

    /// `.plate` — grouped lists, section grounds, notices.
    static let plateLift = Color.white.opacity(0.055)
    /// `.raised` — a card that carries the screen's action.
    static let raisedLift = Color.white.opacity(0.11)
    /// The bottom of a full-bleed ambient backdrop, where art hands over to the canvas.
    static let backdropFade = canvas
    /// The veil that hides scrolling content as it approaches the status bar. Full canvas, so the
    /// handover is invisible: content does not slide *under a grey bar*, it dissolves into the app.
    static let chromeVeil = canvas
    /// The light along the top edge of a filled control (the accent capsule, a chip). An orange
    /// rectangle is a swatch; an orange rectangle with a lit top edge is an object.
    static let controlSheen = Color.white.opacity(0.22)
}

// MARK: - Materials

/// Fills that are a material, not a swatch: the accent lit from above. Every filled accent control
/// (the primary capsule, a selected chip, a committed check) and the selection ring draw from here,
/// so the app's one colour has one light.
enum ThemeGradient {
    /// The accent, lit from above.
    static let accent = LinearGradient(
        stops: [.init(color: ThemeColor.accentHigh, location: 0),
                .init(color: ThemeColor.accent, location: 0.46),
                .init(color: ThemeColor.accentDeep, location: 1)],
        startPoint: .top, endPoint: .bottom)
    /// The same, under a finger.
    static let accentPressed = LinearGradient(
        colors: [ThemeColor.accent, ThemeColor.accentPressed], startPoint: .top, endPoint: .bottom)
    /// The selection ring's metal: the light catches its top-left and runs out toward the foot.
    static let ring = LinearGradient(
        stops: [.init(color: Color(hex: 0xFFDCA8), location: 0),
                .init(color: ThemeColor.accent, location: 0.42),
                .init(color: ThemeColor.accentDeep, location: 1)],
        startPoint: .topLeading, endPoint: .bottomTrailing)
    /// Ivory, lit from above: the white pill ("Mark as watched", "Add") as an object. Flat white
    /// is the brightest rectangle on a dark screen; with a crown and a foot it is a key to press.
    static let ivory = LinearGradient(
        stops: [.init(color: .white, location: 0),
                .init(color: ThemeColor.textPrimary, location: 0.5),
                .init(color: Color(hex: 0xE2DED6), location: 1)],
        startPoint: .top, endPoint: .bottom)
    /// The edge of a raised CONTROL (a quiet capsule, a chip, a tile): light along its crown,
    /// gone by its foot. Never for artwork — a picture's edge stays `posterEdge`, quiet all round
    /// (a bright line across the top of someone's illustration is a frame).
    static let litEdge = LinearGradient(
        colors: [.white.opacity(0.26), .white.opacity(0.05)], startPoint: .top, endPoint: .bottom)
    /// The same edge on a filled accent or ivory control, where the crown catches more.
    static let litEdgeStrong = LinearGradient(
        colors: [.white.opacity(0.48), .clear], startPoint: .top, endPoint: .center)
    /// A bar's fill: brightest at its head, where the progress is.
    static let accentBar = LinearGradient(
        colors: [ThemeColor.accentDeep, ThemeColor.accent, ThemeColor.accentHigh],
        startPoint: .leading, endPoint: .trailing)
}

// MARK: - Elevation

/// A shadow is one token, never three numbers at a call site. On a near-black canvas a shadow is
/// not "depth" on its own — it is the soft contact edge under a card whose FILL already separates
/// it. Never apply one to a surface that has no tone of its own.
struct ShadowToken {
    let color: Color
    let radius: CGFloat
    let y: CGFloat

    static let none = ShadowToken(color: .clear, radius: 0, y: 0)
    /// Content card sitting on the canvas or on a plate.
    static let card = ShadowToken(color: .black.opacity(0.45), radius: 18, y: 10)
    /// Artwork: posters and stills read as physical objects, so their shadow is tighter and darker.
    static let art = ShadowToken(color: .black.opacity(0.55), radius: 12, y: 7)
    /// Art laid ON a coloured tile (Discover's genre tiles, Spotify's): a light contact edge — the
    /// tile's colour, not the shadow, is what separates it.
    static let artOnTile = ShadowToken(color: .black.opacity(0.35), radius: 6, y: 3)
    /// A hero poster, which is the largest object on its screen.
    static let artHero = ShadowToken(color: .black.opacity(0.60), radius: 26, y: 14)
    /// Toast, sync banner, anything that floats over content it must not be mistaken for.
    static let floating = ShadowToken(color: .black.opacity(0.50), radius: 26, y: 14)
}

extension View {
    /// `.shadow(.card)` — the only sanctioned way to cast a shadow on a view that is not a card
    /// (a toast, the brand mark). A CARD uses `cardShadow`.
    func shadow(_ token: ShadowToken) -> some View {
        shadow(color: token.color, radius: token.radius, y: token.y)
    }

    /// A card's shadow, drawn by its ground SHAPE and rasterised with it — never `.shadow` on the
    /// composited card (5 Sep). A layer shadow has no path: the render server draws the whole
    /// card offscreen to find its silhouette on EVERY frame the card is on screen, one pass per
    /// poster per scroll frame. The shape's fill knows its own silhouette and is drawn once.
    /// `fill` is the card's own ground colour, so nothing under the (opaque) card changes.
    func cardShadow(_ token: ShadowToken, shape: RoundedRectangle, fill: Color = ThemeColor.surfaceRaised) -> some View {
        background {
            if token.radius > 0 {
                shape.fill(fill.shadow(.drop(color: token.color, radius: token.radius, x: 0, y: token.y)))
            }
        }
    }
}

enum ThemeSpace {
    static let x0_5: CGFloat = 2
    static let x1: CGFloat = 4
    static let x2: CGFloat = 8
    static let x3: CGFloat = 12
    static let x4: CGFloat = 16
    static let x5: CGFloat = 20
    static let x6: CGFloat = 24
    static let x8: CGFloat = 32
    static let x10: CGFloat = 40
    static let x12: CGFloat = 48
    static let x16: CGFloat = 64
}

enum ThemeRadius {
    static let episodeStill: CGFloat = 8
    static let poster: CGFloat = 10
    static let compactControl: CGFloat = 12
    static let row: CGFloat = 16
    static let toast: CGFloat = 18
    static let card: CGFloat = 22
    static let focusCard: CGFloat = 24
}

// MARK: - Rhythm

/// Spacing is a scale (`ThemeSpace`); RHYTHM is which step a given relationship gets. Every screen
/// used 16 for everything, which is why the shipped build reads as a settings table: a section
/// break, a card gap and a title-to-metadata gap cannot all be the same distance and still say
/// anything. These are the relationships, named once.
enum ThemeMetrics {
    /// Screen side margin. Content, section labels and card edges all align to it.
    static let gutter: CGFloat = 16
    /// Between two SECTIONS. Big enough that the eye takes a breath and re-orients.
    static let sectionGap: CGFloat = 30
    /// Section label → the first thing under it. The label belongs to what follows.
    static let labelGap: CGFloat = 10
    /// Between two sibling cards inside one section.
    static let cardGap: CGFloat = 10
    /// Between shelf items.
    static let shelfGap: CGFloat = 12
    /// Title → its own metadata line. Tight: they are one thought.
    static let titleGap: CGFloat = 3
    /// Art → the text it belongs to.
    static let artGap: CGFloat = 14
    /// A small decorative object in a first-use state; bounded so the action stays dominant.
    static let emptyStateArtWidth: CGFloat = 128
    static let emptyStateArtHeight: CGFloat = 100
    /// Below a hero, before the first content block.
    static let heroClearance: CGFloat = 26
    /// The breathing room under a scroll view's last row. NOT a clearance for the bar: the app's
    /// bar (`AppTabBar`, 25 Sep) is a safe-area inset, so every scroll view already ends above it.
    /// (It was 76 — the floating glass pill plus the ramp that gave it a ground — when the layout
    /// was not inset by the system's iOS 26 bar.)
    static let tabBarClearance: CGFloat = ThemeSpace.x3
    /// The bar's VISUAL height, from the window's bottom edge: its band plus the home-indicator
    /// strip under it. For a measurement taken in WINDOW coordinates — the feed's pager, which
    /// ignores the safe area, and the autoplay's viewport; a view laid out inside the safe area is
    /// already clear of the bar.
    static var tabBarVisualHeight: CGFloat { AppTabBar.reservedHeight + bottomSafeInset }

    // Row heights. A row's height is set by its ART, not by a hairline grid: 68 pt everywhere is
    // what makes a media app look like a list of settings.
    /// Text-only or 40-pt-art rows (menus, selection lists).
    static let rowCompact: CGFloat = 56
    /// The standard media row: 48×72 poster.
    static let rowStandard: CGFloat = 88
    /// The heavier media row: 56×84 poster, two-line title allowed.
    static let rowMedia: CGFloat = 100
    /// Episode row carrying a 96×54 still.
    static let rowEpisode: CGFloat = 82

    // MARK: Chrome edges
    //
    // Every root screen in the shipped build scrolls its content straight through the status bar:
    // a poster and a show title sit on top of the clock and the battery with nothing between them.
    // No shipping media app does this. The fix is systemic, not per-screen — see `scrollEdgeChrome`.

    /// The device's status-bar inset, read once from the key window and cached. 59 pt is the
    /// modern Dynamic Island default and is only used before a window exists.
    ///
    /// A `GeometryReader` cannot supply this: the chrome is an OVERLAY on a view that already sits
    /// inside the safe area, so its proxy reports an inset of zero. Reading the window is the
    /// honest way to know how tall the band the clock lives in actually is.
    nonisolated(unsafe) private static var cachedTopInset: CGFloat?

    static var topSafeInset: CGFloat {
        if let cachedTopInset { return cachedTopInset }
        guard Thread.isMainThread else { return 59 }
        let value = MainActor.assumeIsolated { () -> CGFloat in
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
            let inset = scene?.windows.first(where: \.isKeyWindow)?.safeAreaInsets.top
                ?? scene?.windows.first?.safeAreaInsets.top ?? 0
            return inset > 0 ? inset : 59
        }
        // Only cache a real measurement; a pre-window 59 must not become permanent.
        if value != 59 { cachedTopInset = value }
        return value
    }

    nonisolated(unsafe) private static var cachedBottomInset: CGFloat?

    /// The home-indicator strip (34 pt on a Face ID phone, 0 on a Home-button one), read once from
    /// the key window like `topSafeInset`. The WINDOW's inset: it never includes the app's bar.
    static var bottomSafeInset: CGFloat {
        if let cachedBottomInset { return cachedBottomInset }
        guard Thread.isMainThread else { return 34 }
        let value = MainActor.assumeIsolated { () -> CGFloat? in
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
            return (scene?.windows.first(where: \.isKeyWindow) ?? scene?.windows.first)?.safeAreaInsets.bottom
        }
        // Only cache a real measurement (a window exists); before one, assume a Face ID phone.
        if let value { cachedBottomInset = value }
        return value ?? 34
    }

    /// How far BELOW the status bar the veil takes to disappear. Short and hard on purpose: it
    /// must clear a large title that sits just underneath, so it may not be a lazy 120-pt wash.
    static let topChromeRamp: CGFloat = 22
    /// Total height of the top chrome, safe area included.
    static var topChromeHeight: CGFloat { topSafeInset + topChromeRamp }
    /// The system's inline navigation bar, below the status bar.
    static let inlineBarHeight: CGFloat = 44
    /// The ramp under a HARDENED top veil — the band in which content scrolling out from under
    /// an opaque bar goes from hidden to fully lit. Short, like a material bar's own edge.
    ///
    /// The veils used to hold opaque canvas through the status bar only and then ramp out over
    /// 22–150 pt — straight through the title bar, so a row title sat half-lit UNDER "Library"
    /// and a hero's support line ghosted under Today's handed-over title (captured 2 Sep on both).
    /// A bar is opaque to its bottom edge and content is either under it or not; the only soft
    /// part is this edge.
    static let barEdgeRamp: CGFloat = 28
    /// The hardened bar's canvas over its material — a BAR, not a slab. What has scrolled under
    /// the title stays faintly alive through the blur, the way every material bar in iOS keeps
    /// the content behind it present. At 1.0 the top ~100 pt of every scrolled screen was a flat
    /// #09090B rectangle with a 28-pt edge ("the top area becomes pure black", user, 3 Sep) —
    /// and the `.ultraThinMaterial` painted under it was doing nothing at all. Reduce Transparency
    /// drops the material, so it gets the opaque bar back (`ScrollEdgeChrome.veil`).
    static let chromeBarOpacity: Double = 0.74
    /// The hardened bar's veil when it carries a show's COLOUR (`ScrollEdgeChrome(color:)`): a
    /// coloured ink can sit lighter over the blur than canvas can — the hue does the separating,
    /// and at 0.74 the show page's bar read as a slab of colour rather than its glass ("better
    /// but not quite there", user, 4 Sep).
    static let chromeBarTintedOpacity: Double = 0.62
    /// The bar's full band: status bar + inline bar. What a root's hardened veil holds through.
    static var inlineBarBottom: CGFloat { topSafeInset + inlineBarHeight }

    /// The scroll offset a screen's chrome actually NEEDS, for writing back to view state.
    ///
    /// Every veil, mask and title handover in the app saturates within the first ~120 pt of
    /// scroll and the pull-down stretch within ~300 pt; past that the offset changes nothing on
    /// screen. Writing the raw offset to `@State` on every frame re-evaluated Today's whole body
    /// — the stack, the queue, the shelf, the upcoming rows, every row diff — at 60–120 Hz for
    /// the entire length of the scroll, which is the jank the user felt (2 Sep). Clamped and
    /// rounded to the half-point, the value stops changing once the chrome has settled, so the
    /// body stops re-running. Callers still guard `if v != scrollY`.
    static func scrollSample(_ y: CGFloat, floor: CGFloat = -320, ceiling: CGFloat = 240) -> CGFloat {
        (min(max(y, floor), ceiling) * 2).rounded() / 2
    }

    nonisolated(unsafe) private static var cachedWindowHeight: CGFloat?

    /// The window's height, read once like `topSafeInset`. Billboard heroes are sized as a
    /// fraction of the SCREEN (status bar included), which no `GeometryReader` inside a
    /// navigation stack can report.
    static var windowHeight: CGFloat {
        if let cachedWindowHeight { return cachedWindowHeight }
        guard Thread.isMainThread else { return 852 }
        let value = MainActor.assumeIsolated { () -> CGFloat in
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
            let h = scene?.windows.first(where: \.isKeyWindow)?.bounds.height
                ?? scene?.windows.first?.bounds.height ?? 0
            return h > 0 ? h : 852
        }
        if value != 852 { cachedWindowHeight = value }
        return value
    }

    nonisolated(unsafe) private static var cachedPixel: CGFloat?

    /// One physical pixel, in points (1/3 on a 3× phone). X draws every rule and every border at
    /// this width; a 0.5-pt rule on a 3× screen is a pixel and a half, antialiased across two —
    /// visibly heavier ("The separator and borders are thicker than X. Everywhere", owner, 25 Sep).
    static var pixel: CGFloat {
        if let cachedPixel { return cachedPixel }
        guard Thread.isMainThread else { return 1.0 / 3.0 }
        let measured = MainActor.assumeIsolated { () -> CGFloat? in
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
            let scale = scene?.traitCollection.displayScale ?? 0
            return scale > 0 ? 1 / scale : nil
        }
        if let measured { cachedPixel = measured }
        return measured ?? 1.0 / 3.0
    }

    nonisolated(unsafe) private static var cachedWindowWidth: CGFloat?

    /// The window's width, read the same way. The billboard's copy runs gutter to gutter, and
    /// `HeroTitle` decides between a logo and the name in type against that run before the view
    /// has a frame to measure.
    static var windowWidth: CGFloat {
        if let cachedWindowWidth { return cachedWindowWidth }
        guard Thread.isMainThread else { return 393 }
        let measured = MainActor.assumeIsolated { () -> CGFloat? in
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
            let w = scene?.windows.first(where: \.isKeyWindow)?.bounds.width
                ?? scene?.windows.first?.bounds.width ?? 0
            return w > 0 ? w : nil
        }
        if let measured { cachedWindowWidth = measured }
        return measured ?? 393
    }
    /// The billboard copy's run: the window less both gutters.
    static var billboardCopyWidth: CGFloat { windowWidth - 2 * gutter }
    /// The ambient art wash under a TAB ROOT's inline navigation bar — Schedule, Library, Search.
    /// One height and one strength: the three roots shipped with 300/0.3, 380–520/0.5–0.68 and
    /// 400/0.68, so the same atmosphere was a whisper on one tab and a stain on the next — and by
    /// the cohesion pass (30 Aug) the tree had re-diverged into seven configurations. The rule from
    /// here: EVERY ambient wash uses this pair — tab roots, pushed lists (Season episodes, Watch
    /// history), and Today's no-hero states alike. A screen may not carry a private wash spec;
    /// Today's full-bleed hero is the one composition that replaces the wash outright.
    static let rootWashHeight: CGFloat = 320
    static let rootWashIntensity: Double = 0.4

    /// The height the system search drawer adds under an inline title (`.navigationBarDrawer`).
    /// Search and All titles both size their top veil past it; each carried a private 52 and the
    /// two had already been declared twice when this token was minted.
    static let searchDrawerHeight: CGFloat = 52

    /// Where a poster row's hairline starts — the title's leading edge. Schedule's day-header rule
    /// and All titles' letter-header rule both use the same x, and each had computed it privately.
    static var rowRuleInset: CGFloat { gutter + PosterSize.row.size.width + artGap }
}

/// Artwork slots, named by CONTEXT rather than by number, so no screen has to remember a size.
/// Art is this product's only real material — every one of these is at or above the size the
/// shipped build used, never below.
///
/// **One row slot.** Library rows were 48×72, Search rows 60×90 and Schedule built its own 56×84
/// by hand — three poster sizes for the one object the app renders most. `.row` is now the
/// single list-row slot for Library, Search and Schedule; `.queue` stays for Today's compact
/// queue, which is a different, denser object under the hero.
enum PosterSize {
    /// Detail hero. The largest identity object in the app.
    case hero
    /// Library's cover-flow carousel card — the root's single art moment. In the slot table so its
    /// geometry stops living in a per-screen metrics enum (it shipped there at r18, a radius no
    /// token names).
    case libraryHero
    /// Today's Focus / Recap card.
    case focus
    /// Library "Returning" shelf, Search trending.
    case shelfLarge
    /// Today "Watching" shelf.
    case shelfMedium
    /// Today's denser resting shelf. The hero already owns the first visual beat, so this shelf
    /// must read as supporting context rather than a second wall of key art.
    case todayShelf
    /// THE list row — Library, Search and Schedule. 60×90.
    case row
    /// Today's actionable queue: recognisable at a glance without inheriting a catalogue row's
    /// full 100-pt height.
    case todayQueue
    /// Today's compact queue rows under the hero.
    case queue

    /// A recap beat — the smallest slot that still reads as a show.
    case beat

    var size: CGSize {
        switch self {
        case .hero: return CGSize(width: 112, height: 168)
        case .libraryHero: return CGSize(width: 192, height: 288)
        case .focus: return CGSize(width: 88, height: 132)
        // Widened so a shelf caption's first line carries a real WORD. At 100 pt "That Time I Got
        // Reincarnated as a Slime" broke as "That Time I / Got Reincarn…" and "Re:ZERO / -Starting
        // Life…" opened a line on a hyphen — the app truncating an identity title on one screen
        // while Library's rows render the same title whole.
        case .shelfLarge: return CGSize(width: 124, height: 186)
        case .shelfMedium: return CGSize(width: 112, height: 168)
        case .todayShelf: return CGSize(width: 100, height: 150)
        case .row: return CGSize(width: 60, height: 90)
        case .todayQueue: return CGSize(width: 52, height: 78)
        case .queue: return CGSize(width: 44, height: 66)
        case .beat: return CGSize(width: 34, height: 51)
        }
    }

    /// Radius tracks size: a 10-pt radius on a 34-pt slot is a blob, on a 112-pt slot it is sharp.
    var radius: CGFloat {
        switch self {
        case .libraryHero: return 14
        case .hero, .shelfLarge, .shelfMedium: return 12
        case .todayShelf: return 11
        case .focus, .row: return 10
        case .todayQueue: return 9
        case .queue: return 8
        case .beat: return 6
        }
    }

    /// Only art large enough to read as an object earns a contact shadow.
    var shadow: ShadowToken {
        switch self {
        case .hero, .libraryHero: return .artHero
        case .focus, .shelfLarge, .shelfMedium, .todayShelf: return .art
        case .row, .todayQueue, .queue, .beat: return .none
        }
    }
}

/// Type tokens. Outfit SPEAKS — identity (wordmark, titles) and every word the app says in its
/// own voice (buttons, row/body copy, facts, link actions). SF Pro ANNOTATES — dense small
/// metadata, section labels, numerals/times (Outfit has no tabular figures; timers would jiggle),
/// and the one long-form reading paragraph (`prose`). The old split ("Outfit carries identity,
/// SF carries information") left Outfit such a thin slice that it read as the anomaly, not the
/// voice (user, 30 Aug: "paired with some secondary font that isn't going well").
/// Outfit scales with Dynamic Type through `relativeTo:`; SF tokens are system text styles.
/// Tracking follows the size ramp of the identity tokens: tighter as the cut gets bigger and
/// heavier, neutral by 13 pt.
struct TypeToken {
    let font: Font
    let tracking: CGFloat
}

enum ThemeType {
    static let brandWordmark = TypeToken(font: .custom("Outfit-SemiBold", size: 20, relativeTo: .headline), tracking: -0.30)
    static let displayXL = TypeToken(font: .custom("Outfit-Bold", size: 34, relativeTo: .largeTitle), tracking: -0.80)
    /// The name at display size, in the wordmark's own weight: where the brand is the subject (the
    /// launch and the sign-in gate), "Previously." is SemiBold like the header's `Wordmark`.
    static let brandDisplay = TypeToken(font: .custom("Outfit-SemiBold", size: 34, relativeTo: .largeTitle), tracking: -0.60)
    static let displayL = TypeToken(font: .custom("Outfit-Bold", size: 28, relativeTo: .title), tracking: -0.60)
    static let showTitleL = TypeToken(font: .custom("Outfit-SemiBold", size: 22, relativeTo: .title2), tracking: -0.35)
    static let showTitleM = TypeToken(font: .custom("Outfit-SemiBold", size: 17, relativeTo: .headline), tracking: -0.20)
    /// THE section header (2 Sep). Every shelf and list section in the app is headed by this —
    /// mixed case, the app's voice, with a trailing chevron when the header is the way into the
    /// section. It replaces the 11-pt small-caps `SectionLabel` as the header family: Apple TV,
    /// Netflix and Apple Music all head a shelf with a bold title the size of a row title plus a
    /// step, and the small-caps eyebrow read as a footnote above the shows it introduced. Small
    /// caps stay for EYEBROWS (`OverArtLabel`, a grouped list's header) — the two levels now
    /// split cleanly instead of one token doing both jobs.
    /// (`showTitleS` and `screenTitle` are gone, 30 Aug: no call sites.)
    static let sectionTitle = TypeToken(font: .custom("Outfit-SemiBold", size: 20, relativeTo: .title3), tracking: -0.30)
    static let body = TypeToken(font: .custom("Outfit-Regular", size: 17, relativeTo: .body), tracking: -0.10)
    static let bodyEmphasis = TypeToken(font: .custom("Outfit-SemiBold", size: 17, relativeTo: .body), tracking: -0.20)
    static let button = TypeToken(font: .custom("Outfit-SemiBold", size: 16, relativeTo: .callout), tracking: -0.15)
    static let callout = TypeToken(font: .custom("Outfit-Regular", size: 16, relativeTo: .callout), tracking: -0.10)
    static let metadata = TypeToken(font: .footnote, tracking: 0)
    static let metadataEmphasis = TypeToken(font: .system(.footnote, weight: .semibold), tracking: 0)
    static let sectionLabel = TypeToken(font: .system(.caption2, weight: .semibold), tracking: 1.0)
    /// The BILLBOARD's badge — "NEW EPISODE", "4 EPISODES BEHIND", "TRENDING" — the streaming
    /// apps' filled tag (Prime Video's and Disney+'s "NEW EPISODE"), 11-pt bold caps on an amber
    /// ground (`HeroBadge`, 4 Sep). A ground, so no amber word is drawn.
    static let heroBadge = TypeToken(font: .system(.caption2, weight: .bold), tracking: 0.6)
    static let caption = TypeToken(font: .caption2, tracking: 0)
    static let numberXL = TypeToken(font: .system(.largeTitle, weight: .bold).monospacedDigit(), tracking: -0.50)
    static let time = TypeToken(font: .system(.subheadline, weight: .semibold).monospacedDigit(), tracking: 0)
}

// MARK: - Type by context
//
// The tokens above are a PALETTE. This extension is the ASSIGNMENT: which token a thing gets
// because of where it sits. The shipped build set every title to `showTitleM` and every second
// line to `metadata`, at every altitude, which is why nothing on any screen was allowed to be the
// hero and nothing was allowed to be quiet.
//
//   HERO   (one per screen, the thing the screen is about)
//     title      heroTitle     Outfit Bold 28 / textPrimary
//     badge      heroBadge     SF 11 bold +0.6 / onAccent on an accent ground — the state, above
//                              the title, never below
//     meta       heroMeta      Outfit 15 / textSecondary
//
//   CARD   (the one card that carries an action)
//     title      showTitleL    Outfit SemiBold 22 / textPrimary
//     fact       cardFact      Outfit SemiBold 15 / textPrimary  ← the fact is NOT grey
//     support    metadata      SF 13 / textTertiary
//
//   ROW    (repeating, scannable)
//     title      rowTitle      Outfit SemiBold 17 / textPrimary, 1 line (2 at AX)
//     meta       rowMeta       SF 13 / textSecondary
//     forward    rowMetaLead   SF 13 semibold / accent — only a real next step earns amber
//
//   SHELF  (poster + caption)
//     title      shelfTitle    Outfit Medium 15 / textPrimary, exactly 2 reserved lines
//     caption    shelfCaption  SF 12 medium / textSecondary (accent when it is a next step)
//
//   SECTION
//     title      sectionTitle  Outfit SemiBold 20 / textPrimary, chevron when it navigates
//     count      metadata      SF 13 / textTertiary, on the title's baseline
//     eyebrow    sectionLabel  SF 11 semibold +1.0 — over art (`OverArtLabel`) and grouped lists only
//     action     listAction    Outfit SemiBold 13 / interactive  ← an inline link ("Clear"); never amber
extension ThemeType {
    /// Detail hero. Identity gets the biggest cut in the app after the wordmark.
    static let heroTitle = TypeToken(font: .custom("Outfit-Bold", size: 28, relativeTo: .title), tracking: -0.55)
    /// The genre/network/year line under a hero title.
    static let heroMeta = TypeToken(font: .custom("Outfit-Regular", size: 15, relativeTo: .subheadline), tracking: -0.05)
    /// Long-form reading text — Detail's synopsis, the one paragraph in the app. Subheadline, with
    /// the call site opening the leading (`lineSpacing(5)`). It was `body`: 17-pt default-leading
    /// grey — visually an unstyled SwiftUI `Text` — and TWO POINTS LARGER than the hero's own
    /// `heroMeta` line above it, so the type ladder inverted at exactly the step where it should
    /// step down (user device, 30 Aug: "the description font looks plain wrong").
    /// Deliberately still SF under the "Outfit speaks" rule: a synopsis is quoted CONTENT, not
    /// the app's voice, and SF reads better than a geometric sans over a full paragraph.
    static let prose = TypeToken(font: .system(.subheadline), tracking: 0)
    /// The single load-bearing fact on a card ("Season 7 · Episode 2"). Primary, not secondary:
    /// a fact the whole card exists to deliver may not be rendered in the same grey as its footnote.
    static let cardFact = TypeToken(font: .custom("Outfit-SemiBold", size: 15, relativeTo: .subheadline), tracking: -0.10)
    /// Repeating media row title.
    static let rowTitle = TypeToken(font: .custom("Outfit-SemiBold", size: 17, relativeTo: .headline), tracking: -0.20)
    /// Repeating media row metadata.
    static let rowMeta = TypeToken(font: .footnote, tracking: 0)
    /// A row's forward-looking fact — "Returns Oct 2", "Episode 19 next". Rendered in accent.
    static let rowMetaLead = TypeToken(font: .system(.footnote, weight: .semibold), tracking: 0)
    /// Shelf caption under a poster.
    static let shelfTitle = TypeToken(font: .custom("Outfit-Medium", size: 14, relativeTo: .subheadline), tracking: -0.10)
    static let shelfCaption = TypeToken(font: .system(.caption, weight: .medium), tracking: 0)
    /// An inline text action in a section header ("See all", "Clear"). Deliberately smaller than
    /// `button`: a 16-pt semibold word beside an 11-pt grey label wins a fight it should lose.
    /// Rendered in `ThemeColor.interactive` — a link is an action, and actions are not amber.
    static let listAction = TypeToken(font: .custom("Outfit-SemiBold", size: 13, relativeTo: .footnote), tracking: 0)
}

extension View {
    func type(_ token: TypeToken) -> some View {
        self.font(token.font).tracking(token.tracking)
    }
}

extension Text {
    func type(_ token: TypeToken) -> Text {
        self.font(token.font).tracking(token.tracking)
    }
}

/// Motion tokens (board 11). `uiBouncy` / `uiSmooth` from the older Theme are superseded.
enum ThemeMotion {
    /// Touch compression only.
    static let uiPress = Animation.easeOut(duration: 0.09)
    /// Checkmarks, icon replacement, chip selection, status change.
    static let uiMicro = Animation.spring(response: 0.22, dampingFraction: 0.88, blendDuration: 0)
    /// Fast local layout changes and user-requested expansion.
    static let uiSnappy = Animation.spring(response: 0.34, dampingFraction: 0.84, blendDuration: 0)
    /// Large but controlled card-to-card or source-to-destination motion.
    static let uiSettle = Animation.spring(response: 0.46, dampingFraction: 0.90, blendDuration: 0)
    /// One restrained overshoot for a meaningful milestone (series complete only).
    static let uiMilestone = Animation.spring(response: 0.38, dampingFraction: 0.74, blendDuration: 0)
    /// State fades, stale strips, error notices, NOW movement.
    static let uiGentle = Animation.easeInOut(duration: 0.22)
    /// Content that moves WITH the keyboard — the launchpad's recents unfolding as the field
    /// takes focus. The system's own keyboard timing: its duration as last reported by
    /// `keyboardWillShowNotification` (0.38 s on iOS 26, `KeyboardMotion.duration`) on the
    /// keyboard's curve, so what makes room for the keyboard lands in the frame the keyboard
    /// does. On `uiGentle` (0.22 s) the recents had settled while the keyboard was still
    /// rising — one tap, two beats (filmed 6 Sep).
    static var keyboard: Animation {
        Animation.timingCurve(0.38, 0.70, 0.125, 1.00, duration: KeyboardMotion.duration)
    }
    /// Initial content reveal.
    static let uiReveal = Animation.timingCurve(0.22, 1.00, 0.36, 1.00, duration: 0.28)
    /// Poster tint to final image.
    static let uiPoster = Animation.easeOut(duration: 0.18)
    /// Numeric content transition.
    static let uiNumeric = Animation.easeOut(duration: 0.22)
    /// Season-complete hairline, History rail.
    static let uiSweep = Animation.timingCurve(0.40, 0.00, 0.20, 1.00, duration: 0.52)
    /// Toast dismissal only.
    static let uiDismiss = Animation.easeIn(duration: 0.16)
    /// Wordmark live indicator.
    static let uiLiveBreath = Animation.easeInOut(duration: 1.80).repeatForever(autoreverses: true)
    /// Universal Reduce Motion fallback.
    static let uiReduced = Animation.easeOut(duration: 0.12)

    /// The token, or the Reduce Motion fallback when the setting is on.
    static func pick(_ token: Animation, reduceMotion: Bool) -> Animation {
        reduceMotion ? uiReduced : token
    }
}

// MARK: - The handoff
//
// One card is replaced by the next one on four surfaces — Today's Focus card after a mark, Detail's
// Next-up card, a Schedule row settling, Search's results replacing the launchpad. The build shipped
// four different answers: Today's (correct) asymmetric construction, a symmetric 460 ms crossfade on
// Detail that renders two show titles and two CTA labels superimposed for a quarter of a second, a
// 40 % scale pop on Schedule, and SwiftUI's default crossfade of two whole view trees on Search.

extension AnyTransition {
    /// The one handoff: the outgoing card **leaves first** (`uiDismiss`, 160 ms), the incoming one
    /// settles into the space it left (`uiSettle`, delayed past the removal). Asymmetry is the whole
    /// point — a symmetric crossfade superimposes two different sentences, which is what a smear is.
    ///
    /// Under Reduce Motion both halves collapse to `uiReduced` with no delay: still a handover,
    /// no travel.
    static func handoff(reduceMotion: Bool) -> AnyTransition {
        guard !reduceMotion else {
            return .opacity.animation(ThemeMotion.uiReduced)
        }
        return .asymmetric(
            insertion: .opacity.animation(ThemeMotion.uiSettle.delay(0.08)),
            removal: .opacity.animation(ThemeMotion.uiDismiss)
        )
    }

    /// The toast's own timing, owned by the toast rather than by whichever container happens to
    /// mount it: a 4-pt rise on `uiSnappy` in, `uiDismiss` out. `uiDismiss` was minted for exactly
    /// this moment and had one call site that was not this one — a toast leaving on the spring it
    /// arrived on reads as a bounce, not a dismissal.
    static func toast(reduceMotion: Bool) -> AnyTransition {
        guard !reduceMotion else {
            return .opacity.animation(ThemeMotion.uiReduced)
        }
        return .asymmetric(
            insertion: .opacity.combined(with: .offset(y: 4)).animation(ThemeMotion.uiSnappy),
            removal: .opacity.animation(ThemeMotion.uiDismiss)
        )
    }
}

/// The system keyboard's animation duration, read from its own notifications so
/// `ThemeMotion.keyboard` matches the keyboard on the OS it is running on. `install()` once at
/// launch; the unseen warm-up keyboard (`KeyboardWarmup`) delivers the first reading before any
/// field has been tapped.
enum KeyboardMotion {
    /// iOS 26's reported keyboard duration; older systems report 0.25 and update this on the
    /// first presentation. Written on the main thread only (the observer's queue); read from
    /// `ThemeMotion.keyboard`, which is not isolated — like the other cached tokens here.
    nonisolated(unsafe) private(set) static var duration: Double = 0.38
    nonisolated(unsafe) private static var installed = false

    @MainActor
    static func install() {
        guard !installed else { return }
        installed = true
        NotificationCenter.default.addObserver(forName: UIResponder.keyboardWillShowNotification, object: nil, queue: .main) { n in
            guard let d = n.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double, d > 0.1, d < 1 else { return }
            duration = d
        }
    }
}

/// Every haptic in the app goes through here. One-sentence justification per token (board 11).
enum FeedbackToken {
    case selection      // a discrete selected value changed
    case commitLight    // one watch fact recorded on this device
    case commitMedium   // a larger contiguous progress change recorded
    case success        // season/series complete · title added · rewatch started
    case destructive    // an irreversible deletion was accepted
    case refreshArmed   // releasing now will refresh
    case directError    // an explicit action failed
}

@MainActor
enum FeedbackCoordinator {
    /// Per token, as the floor is: one shared stamp meant adding two shows in quick succession
    /// buzzed once, an error inside 300 ms of the commit it belonged to was swallowed, and Undo
    /// tapped straight after a mark gave no selection tick at all.
    private static var lastFire: [FeedbackToken: TimeInterval] = [:]

    /// The minimum gap between two feedback events, **per token**.
    ///
    /// A blanket 300 ms floor is right for a commit — two marks 100 ms apart are one transaction
    /// and must buzz once. It is wrong for `.selection`, which is the token the A–Z index rail and
    /// the week strip use: UIKit's own `UITableViewIndex` fires per section, unthrottled, and at
    /// 300 ms an A→W drag yielded at most two taps out of twenty-odd. Selection is *tracking* a
    /// finger, not confirming a write.
    private static func floor(for token: FeedbackToken) -> TimeInterval {
        token == .selection ? 0.04 : 0.3
    }
    private static let light = UIImpactFeedbackGenerator(style: .light)
    private static let medium = UIImpactFeedbackGenerator(style: .medium)
    private static let notify = UINotificationFeedbackGenerator()
    private static let select = UISelectionFeedbackGenerator()

    /// Haptics: On / Off (Accessibility). System settings remain authoritative.
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "previously.haptics") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "previously.haptics") }
    }

    /// Fires at most one feedback event per token floor, never while the app is inactive.
    static func fire(_ token: FeedbackToken) {
        guard enabled, UIApplication.shared.applicationState == .active else { return }
        let now = Date().timeIntervalSinceReferenceDate
        guard now - (lastFire[token] ?? 0) >= floor(for: token) else { return }
        lastFire[token] = now
        switch token {
        case .selection: select.selectionChanged(); select.prepare()
        case .commitLight: light.impactOccurred(intensity: 0.65); light.prepare()
        case .commitMedium: medium.impactOccurred(intensity: 0.72); medium.prepare()
        case .success: notify.notificationOccurred(.success); notify.prepare()
        case .destructive: notify.notificationOccurred(.warning); notify.prepare()
        case .refreshArmed: light.impactOccurred(intensity: 0.50); light.prepare()
        case .directError: notify.notificationOccurred(.error); notify.prepare()
        }
    }
}
