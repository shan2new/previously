import SwiftUI
import UIKit

// Schedule, lit (26 Sep: "Schedule UI/UX needs to feel more beautiful and delightful", owner; two
// directions were filmed on the owner's calendar and the owner chose POLISH — "but the horizontal
// timeline is distracting and irritating", so its NOW line is gone). The structure the owner chose on
// 25 Sep stays — ONE card for the next thing over a banner-free agenda where the date rides the row,
// the month grid behind the calendar glyph — and it comes alive:
//   · the card is Home's billboard at card scale (`ScheduleLitCard`): the show's best-looking poster
//     (`PosterPick`) as a PICTURE, protection only under the words and scaled to the art's lightness,
//     landing on the art's own hue at depth, the show's logo on clean art, a glow of the art's colour
//     around the card;
//   · each row's face sits in a breath of its show's colour, and today's next airing says how long is
//     left ("in 2h 14m", accent) where its clock was;
//   · the card's words and the rows rise in, once a visit, in under a third of a second — and the feed
//     LANDS on today from its first frame, holding there until the reader touches it (`reland`).
// Rejected with it: BOARD (each day's numeral on split-flap tiles turning from blank, a countdown on
// flaps — on-brand, and an effect), the NOW line (an amber hairline and time capsule across the
// agenda, Apple Calendar's), and the clock tinted in the show's hue (most posters here are warm: every
// time came out salmon). Deleted, not flagged.

// MARK: - The show's colour

/// The palette colour (`PaletteCache`) re-set as LIGHT — a glow on the canvas: OKLab L 0.60, chroma
/// up to 0.14 (a glow is colour or it is grey). The hue is the show's; the lightness is the job's.
enum ScheduleHue {
    static func glow(_ tint: Color?) -> Color? {
        guard let tint else { return nil }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard UIColor(tint).getRed(&r, green: &g, blue: &b, alpha: &a) else { return nil }
        var (_, ca, cb) = PaletteCache.oklab(r: Double(r), g: Double(g), b: Double(b))
        let c = (ca * ca + cb * cb).squareRoot()
        guard c > 0.0001 else { return nil }
        let k = min(max(c, 0.06), 0.14) / c
        ca *= k
        cb *= k
        let (sr, sg, sb) = PaletteCache.srgb(l: 0.60, a: ca, b: cb)
        return Color(.sRGB, red: sr, green: sg, blue: sb, opacity: 1)
    }
}

// MARK: - The arrival

/// Something arriving with the visit: `distance` below and clear, then in place on the reveal curve,
/// `delay` after the visit began. Under Reduce Motion it is simply there.
struct ScheduleRise: ViewModifier {
    let shown: Bool
    var delay: Double = 0
    var distance: CGFloat = ScheduleArrivalMetrics.rise
    var duration: Double = ScheduleArrivalMetrics.duration

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(shown || reduceMotion ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : distance)
            .animation(reduceMotion || !shown ? nil
                       : .timingCurve(0.22, 1, 0.36, 1, duration: duration).delay(delay),
                       value: shown)
    }
}

// MARK: - What a row wears

/// What a lit row wears, in one value so `ScheduleAgendaRow` keeps one signature for every caller
/// (Home's rows pass none).
struct ScheduleRowDecor {
    /// The art whose palette colour glows under the row's face.
    var hueURL: String? = nil
    /// The end of the caption drawn in accent — today's countdown ("in 2h 14m").
    var accentTail: String? = nil

    static let none = ScheduleRowDecor()
}

// MARK: - The card — Home's billboard, continued

/// The next thing to watch, as the show's STAGE (9 Oct — "The Schedule screen just feels poorly made
/// and not premium enough like the Home screen", owner): `ShowBillboard`, the one billboard Home and
/// the show page draw, FULL BLEED across the feed at half the window's height, with the moment on
/// its badge ("OUT NOW" — a quiet label for an airing still to come), the show's logo else its name,
/// the episode, and the mark once it is out. The page under it stands in the picture's hue
/// (`ScheduleView` draws `HomeGround` behind today's block, as Home does under its billboard).
///
/// What it replaced (`ScheduleLitCard`, 26 Sep): a square poster in a rounded box inside the
/// gutters — a thumbnail, not a stage — under a stranded month eyebrow.
struct ScheduleStageCard: View {
    let franchise: Franchise
    let eyebrow: String
    let line: String
    let state: AiringState
    let canToggle: Bool
    let markLabel: String
    /// The art's colour (the page is painted from it too) and the ground the frame lands on.
    var tint: Color? = nil
    var landing: Color = ThemeColor.canvas
    let onToggle: () -> Void
    let onOpen: () -> Void
    /// The picture the stage settled on — the page is painted from its colour.
    var onArt: ((String?) -> Void)? = nil

    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Half the window: the agenda keeps its first rows on the landing screen.
    static var height: CGFloat { (ThemeMetrics.windowHeight * 0.52).rounded() }
    /// The picture runs this far ABOVE the card's frame, under the status band and the bar's row,
    /// as Home's billboard does (16 Oct: "a lot of top and bottom BLACK bars which are taking
    /// visible space", owner): at the landing the bar's veil is over the art, not over a strip of
    /// canvas — or of yesterday's last row. The feed makes room for it (`ScheduleView.dayBlock`).
    static var bleed: CGFloat { ThemeMetrics.topSafeInset + FeedMetrics.headerRow }

    /// Out: the badge. Still to come: the moment as a quiet label (a tag is for news).
    private var isOut: Bool { state != .upcoming }

    var body: some View {
        ShowBillboard(franchise: franchise, height: Self.height + Self.bleed, band: Self.bleed,
                      tint: tint, landing: landing,
                      onOpen: onOpen, onArt: onArt,
                      accessibilityLabel: "\(eyebrow), \(franchise.displayTitle), \(line)",
                      accessibilityHint: Copy.Accessibility.opensTheShowHint,
                      pullStretch: false, visibleBand: ScheduleCardMetrics.clearBand) { name, arrival in
            lockup(name: name, arrival: arrival)
        }
        // Taller than the bleed by `overhang`: the picture is drawn a hair larger than its frame
        // (the lean, the arrival's settle), so its top edge stands above the frame's.
        .overlay(alignment: .top) {
            ScheduleCardTopFade(height: Self.bleed + ScheduleCardTopFade.overhang)
                .offset(y: -ScheduleCardTopFade.overhang)
        }
    }

    private func lockup(name: BillboardName, arrival: BillboardArrival) -> some View {
        VStack(spacing: ThemeSpace.x3) {
            VStack(spacing: ThemeSpace.x2) {
                if isOut {
                    HeroBadge(text: eyebrow, attention: true)
                        .modifier(arrival.line(0))
                } else {
                    Text(eyebrow)
                        .type(ThemeType.feedEyebrow)
                        .textCase(.uppercase)
                        .foregroundStyle(ThemeColor.textPrimary.opacity(0.72))
                        .lineLimit(2)
                        .shadow(.art)
                        .modifier(arrival.line(0))
                }
                if case .logo = name, name.hasGraphicLogo, !typeSize.isAccessibilitySize {
                    ArtworkLogo(name: name, title: franchise.displayTitle, height: 72, halo: 0.55, hug: true)
                        .padding(.horizontal, ThemeSpace.x8)
                        .padding(.vertical, ThemeSpace.x1)
                        .modifier(arrival.logo)
                } else if name != .embedded || typeSize.isAccessibilitySize {
                    Text(franchise.displayTitle)
                        .type(ThemeType.displayXL)
                        .foregroundStyle(ThemeColor.textPrimary)
                        .multilineTextAlignment(.center)
                        .lineLimit(typeSize.isAccessibilitySize ? 3 : 2)
                        .minimumScaleFactor(0.82)
                        .shadow(.art)
                        .modifier(arrival.line(1))
                }
                Text(line)
                    .type(ThemeType.heroMeta)
                    .foregroundStyle(ThemeColor.textPrimary.opacity(0.88))
                    .lineLimit(typeSize.isAccessibilitySize ? 2 : 1)
                    .shadow(.art)
                    .modifier(arrival.line(2))
            }
            .multilineTextAlignment(.center)
            .allowsHitTesting(false)
            if canToggle {
                ScheduleMarkPill(watched: state.isWatched, label: markLabel, action: onToggle)
                    .modifier(arrival.line(3))
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
    }
}

/// The card's top edge, once the past is in view above it (16 Oct: "That is not a smooth
/// experience at all", owner — the picture that runs up under the bar at the landing began on a
/// hard straight edge an inch under yesterday's row once the reader scrolled back to it). At the
/// landing the card's top IS the screen's top and the picture runs up whole; as the card comes
/// down the screen, its bleed melts into the canvas the row above sits on. Read in the render pass
/// (`visualEffect`): a scroll frame re-runs nothing.
private struct ScheduleCardTopFade: View {
    let height: CGFloat
    /// How far the picture can stand above the card's frame: 3.5 % oversize for the lean, ±6 pt of
    /// lean, and the arrival's 5 % settle, on a ~540-pt picture.
    static let overhang: CGFloat = 32

    var body: some View {
        // Read here: the effect's closure runs off the main actor.
        let reach = max(ThemeMetrics.topSafeInset, 1)
        let solid = Self.overhang / max(height, 1)
        LinearGradient(stops: [
            .init(color: ThemeColor.canvas, location: 0),
            .init(color: ThemeColor.canvas, location: solid),
            .init(color: ThemeColor.canvas.opacity(0.72), location: solid + (1 - solid) * 0.3),
            .init(color: ThemeColor.canvas.opacity(0.22), location: solid + (1 - solid) * 0.7),
            .init(color: ThemeColor.canvas.opacity(0), location: 1),
        ], startPoint: .top, endPoint: .bottom)
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .visualEffect { content, proxy in
            // The CARD's top: the fade itself starts `overhang` above it.
            let below = proxy.frame(in: .global).minY + Self.overhang
            return content.opacity(Double(min(1, max(0, below / reach))))
        }
    }
}

/// A row of the agenda fades as it passes under the bar, instead of printing through the bar's
/// veil (16 Oct). The bar's veil is light over Schedule (`EdgeVeil(overArt:)`) so the stage's art
/// shows at the landing; without this, yesterday's rows read through it behind "Schedule". The
/// edge follows the bar as it slides away (the state's `awayFraction`, read here and nowhere in the
/// row), and the fade itself is a render-pass effect.
struct ScheduleUnderBarFade: ViewModifier {
    let chrome: RootChromeState
    /// What hangs under the bar's row and stays when the row has gone — the week strip.
    var extra: CGFloat = 0

    /// A row is whole until its top is this far under the bar's foot…
    private static let start: CGFloat = 4
    /// …and gone this far under it.
    private static let length: CGFloat = 40

    func body(content: Content) -> some View {
        let foot = ThemeMetrics.topSafeInset + FeedMetrics.headerRow * (1 - min(1, max(0, chrome.awayFraction))) + extra
        let start = Self.start, length = Self.length
        content.visualEffect { c, proxy in
            let under = foot - proxy.frame(in: .global).minY - start
            return c.opacity(Double(1 - min(1, max(0, under / length))))
        }
    }
}

// MARK: - Coming back

/// One show on Coming back's shelf (19 Oct): the Library's poster card, its name and its window —
/// "Returns 3 Oct" in the accent inside the horizon (a step you can take soon), "Jan 2027" grey past
/// it (`ReturnFact`). No mark, no progress: nothing here can be watched yet.
struct ScheduleComingBackTile: View {
    let franchise: Franchise
    let fact: ReturnFact
    let onOpen: () -> Void

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let f = franchise
        let pick = PosterPick.shared.choice(for: f)
        ArtworkPoster(url: pick?.url ?? f.portraitArt, name: pick?.tileName(for: f) ?? .type, title: f.displayTitle,
                      detailsInBand: true, fixedAspect: 2.0 / 3.0, onOpen: onOpen,
                      openLabel: "\(f.displayTitle), \(fact.sentence.isEmpty ? fact.text : fact.sentence)") {
            PosterCaptionText(title: f.displayTitle.shelfShortened(fitting: 26), fact: fact.text, lead: fact.soon)
        }
        .frame(width: ForYouShelves.tileWidth(typeSize))
    }
}
