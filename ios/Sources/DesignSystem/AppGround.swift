import SwiftUI
import UIKit

/// The lights of each AUDIENCE — read from the "What you watch" pictures (4 Oct): the anime sky's
/// crimson and its gold, the street's teal and its steel blue. The chooser's ambient
/// (`AudienceAmbient`) and the app's ground (`AppGround`) draw from this one palette.
enum AudienceLight {
    static let crimson = Color(hex: 0xC2413F), gold = Color(hex: 0xE08A3A)
    static let teal = Color(hex: 0x1E8696), steel = Color(hex: 0x2F62AE)

    /// The two pools of light, leading and trailing: anime's warm pair, TV's cool one, and one of
    /// each for a viewer of both.
    static func pools(_ audience: Audience) -> (leading: Color, trailing: Color) {
        switch audience {
        case .anime: (crimson, gold)
        case .tv: (steel, teal)
        case .both: (crimson, teal)
        }
    }
}

/// The app's GROUND (19 Oct: "Let's add slight background gradient to add some character to the
/// app (anime mode different…)", owner): the canvas lit by the viewer's own kind — anime's crimson
/// and gold, TV's steel and teal, one of each for both — the "What you watch" pictures' lights.
///
/// Given PERSONALITY the same day ("the gradience needs more personality without competing with
/// everything", owner): the first cut was two round pools in the top corners, a light any app could
/// have. Now three things, each kept where the content is not:
///   · an AURORA across the top — a mesh of the two colours, the first deep at the leading corner,
///     the second at the trailing one, their blend between, its lower edge a curve rather than a
///     ring — behind the bar and the first section's title, spent before the page's first cards;
///   · FILM GRAIN in it, a fixed tile in overlay, so the light has a surface — on the near-black
///     canvas overlay leaves the dark as it is, so the grain lives only where the light is;
///   · a HORIZON — the second colour faintly at the foot, behind the tab bar, so the page is lit
///     at both ends and framed rather than lit from one corner.
/// Rows, shelves and posters sit on near-canvas through the middle. Fixed behind the scroll view of
/// Home, Schedule, Library, Discover and the News page, drawn once — nothing moves, nothing per
/// frame; content scrolls over it. It follows the account's answer as it changes. The show page
/// keeps its own ground, in the show's hue.
struct AppGround: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    /// The aurora's strength at its corners and its middle.
    static let lead: Double = 0.30
    static let trail: Double = 0.24
    static let middle: Double = 0.17
    /// How far down the screen the aurora reaches, as a share of the window.
    static let reach: CGFloat = 0.58
    /// The horizon's strength at the foot.
    static let horizon: Double = 0.10

    var body: some View {
        let pools = AudienceLight.pools(appModel.audience)
        let blend = pools.leading.mix(with: pools.trailing, by: 0.5)
        ZStack(alignment: .top) {
            ThemeColor.canvas
            // The aurora: a 3×3 mesh, its top row the light, its middle row a curve (lower at the
            // trailing edge, higher in the middle), its bottom row the canvas.
            MeshGradient(width: 3, height: 3, points: [
                [0, 0], [0.5, 0], [1, 0],
                [0, 0.40], [0.56, 0.30], [1, 0.52],
                [0, 1], [0.5, 1], [1, 1],
            ], colors: [
                pools.leading.opacity(Self.lead), blend.opacity(Self.middle), pools.trailing.opacity(Self.trail),
                pools.leading.opacity(Self.lead * 0.30), blend.opacity(Self.middle * 0.25), pools.trailing.opacity(Self.trail * 0.30),
                .clear, .clear, .clear,
            ], smoothsColors: true)
            .frame(height: ThemeMetrics.windowHeight * Self.reach)
            // The horizon: the second light, low and wide, behind the tab bar.
            EllipticalGradient(colors: [pools.trailing.opacity(Self.horizon), .clear],
                               center: .init(x: 0.78, y: 1.02), startRadiusFraction: 0, endRadiusFraction: 0.55)
            if !reduceTransparency {
                GroundGrain()
            }
        }
        // The grain's overlay blends with the ground and nothing else.
        .compositingGroup()
        .ignoresSafeArea()
        .animation(ThemeMotion.pick(.easeInOut(duration: 0.55), reduceMotion: reduceMotion), value: appModel.audience)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Film grain: one 128-pt tile of luminance noise, made once and tiled, in OVERLAY — over the
/// near-black canvas overlay changes almost nothing (2 × base × noise), so the grain shows only in
/// the lit parts of the ground, as grain does in a photograph's light.
private struct GroundGrain: View {
    static let tile: UIImage = {
        let side = 128
        var bytes = [UInt8](repeating: 0, count: side * side)
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        for i in bytes.indices {
            // SplitMix64: the same grain on every launch, no allocation per pixel.
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            z ^= z >> 31
            bytes[i] = UInt8(96 + Int(z % 64))
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        let image = CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: side,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        return UIImage(cgImage: image, scale: 1, orientation: .up)
    }()

    var body: some View {
        Image(uiImage: Self.tile)
            .resizable(resizingMode: .tile)
            .blendMode(.overlay)
            .opacity(0.55)
    }
}
