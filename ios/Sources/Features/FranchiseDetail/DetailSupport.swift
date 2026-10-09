import SwiftUI
import UIKit

/// Episode context carried to Detail. It selects a season without changing the initial landing.
struct EpisodeFocus: Equatable, Hashable {
    let mediaId: Int
    let episode: Int
}

// MARK: - Metrics

enum DetailMetrics {
    /// The tab-bar clearance, plus room for the floating sync banner while one is presented.
    ///
    /// The banner is drawn OVER content rather than inset from it, so with a failure pending the
    /// last row of a scroll sits permanently sliced through its glyphs. Until the banner carries a
    /// presented-state content inset of its own — filed as a shared-file request — the screens
    /// that can show one make room for it.
    @MainActor static var bottomClearance: CGFloat {
        ThemeMetrics.tabBarClearance + (SyncCenter.shared.failedChanges.isEmpty ? 0 : bannerClearance)
    }

    /// The banner's own height plus the gap it keeps from the tab bar.
    private static let bannerClearance: CGFloat = 72

    /// The first line of a pushed screen's content starts BELOW the floating toolbar.
    ///
    /// These screens hide the navigation bar's background so the show's colour can reach the top,
    /// which also means the safe area stops at the status bar — and a screen header laid out at
    /// the top of it renders under the back button, permanently dimmed by the toolbar's own veil.
    static let toolbarClearance: CGFloat = 46
}

// MARK: - The last session this device created

/// Which watch session was created a moment ago, so Watch history can draw its arrival exactly once.
///
/// The rail's new-session choreography (`HistorySessionRow.isNew` — rail draw on `uiSweep`, then the
/// node settling on `uiMicro`) was specified, implemented in the design system and then called from
/// nothing but a `#Preview`: starting a rewatch and opening Watch history showed a fully drawn rail
/// with no arrival at all. The two surfaces are a push apart and neither owns the other's state, so
/// the hand-off is a one-shot token: `FranchiseDetailView.startRewatch` records the id, the first
/// `WatchHistoryView` that renders consumes it, and every later render draws a settled rail.
@MainActor
enum RewatchArrival {
    private static var pending: UUID?

    static func record(_ id: UUID) { pending = id }

    /// True exactly once, for the session that was just created.
    static func claim(_ id: UUID) -> Bool {
        guard pending == id else { return false }
        pending = nil
        return true
    }
}

// MARK: - Strings this round needs that `Copy` does not have yet

/// Detail's half of the round-2 copy fixes.
///
/// Every one of these belongs in `DesignSystem/Copy.swift` — that file is the only place a
/// user-facing string is allowed to live, and `Copy.Action.commands` is the table the ellipsis and
/// confirmation rules are checked against. The shared diff is filed; this is the local half, kept
/// in one enum rather than scattered as literals at call sites so the move is a rename.
enum DetailCopy {
    static let revealEpisodeTitle = Copy.Action.revealEpisodeTitle
    static let hideEpisodeTitle = Copy.Action.hideEpisodeTitle
    static let revealEpisodeTitlesAndStills = Copy.Action.revealEpisodeTitlesAndStills
    static let markSeriesWatched = Copy.Action.markSeriesWatched
    static let everything = Copy.Rewatch.everything
    static let markRewatchComplete = Copy.Action.markRewatchComplete
    static let stopRewatch = Copy.Action.stopRewatch
}

// MARK: - Episode title sanitising

enum EpisodeCopy {
    /// The catalogue's episode title, or `nil` when there isn't a real one.
    ///
    /// The flagship show's first row read `Episode 1 · Episode  - That Time I Got Reincarnated as
    /// a Slime…`: the word "Episode" twice, a double space, a dangling hyphen, the franchise's own
    /// title inside its episode title, and then ellipsised — because `rowTitle` concatenated
    /// `Copy.episode(n)` with whatever string the source stored and did no checking at all.
    ///
    /// AniList's episode-1 titles routinely embed the show name, and both sources emit
    /// `"Episode 1"`, `"Episode - "` and `"Episode 12 - Foo"` as *titles*. A title that repeats the
    /// label the row already prints, or repeats the show the hero already printed, is not a title.
    static func title(_ raw: String?, franchise: String) -> String? {
        guard let raw else { return nil }
        // Collapse every run of whitespace (the double space came from an empty numeral slot).
        var t = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        // Strip a leading "Episode", an optional number, and an optional separator.
        if let r = t.range(of: "^[Ee]pisode\\s*\\d*\\s*[-–—:·]?\\s*", options: .regularExpression) {
            t = String(t[r.upperBound...])
        }
        // A dangling separator at either end is what is left of "Episode - " once the show's name
        // was the only content.
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: " -–—:·"))
        guard !t.isEmpty else { return nil }
        let normalised = t.lowercased()
        // The franchise's own name is identity, not an episode title, and it is 400 pt above
        // already. Equality is not enough: AniList's episode-1 slot on the flagship show holds
        // "Episode  - That Time I Got Reincarnated as a Slime the Movie: Tears of the Azure Sea |
        // Trailer" — the show's name, then a *different work*, then a promo tag. Anything that
        // OPENS with the show's own name is a catalogue string, not the name of an episode.
        let show = franchise.lowercased()
        if !show.isEmpty, normalised.hasPrefix(show) { return nil }
        // Anything still starting "episode" is a numbering scheme, not a name.
        if normalised.hasPrefix("episode") { return nil }
        // Promotional material the catalogue files in the episode list. A trailer is not episode n.
        for tag in ["trailer", "teaser", "promo", " pv", "preview"] where normalised.hasSuffix(tag) {
            return nil
        }
        return t
    }
}

// MARK: - The episode image slot

/// One 96×54 rectangle for an episode — the still if the catalogue has one, the show's own artwork
/// if it does not.
///
/// The build this replaces drew ten to eighteen consecutive identical `play.rectangle` tiles on a
/// tint that resolved within ~4 % luminance of the card ground: a placeholder farm down the middle
/// of the flagship show's episode list. **A glyph is only honest where there is no art at all, and
/// there is always art — the season has a poster.** So the slot falls back to the season's own
/// cover, cropped from its top (posters are faces at the top and logotype at the bottom) under a
/// gradient dark enough that the tile never competes with a real still beside it.
///
/// The episode number is deliberately NOT drawn on the tile: the row's own text states it 8 pt
/// away, and an identifier printed twice in one row is exactly the defect `WithheldStillTile`'s
/// note records. What stops a season becoming a wall of one repeated poster is upstream, in
/// `SeasonEpisodesView.artPolicy`: a season the catalogue barely illustrated drops the art column
/// entirely rather than repeating one image eighteen times.
struct EpisodeStill: View {
    /// The episode's own still.
    let url: String?
    /// The season's (or the show's) TRUE 16:9 landscape (`FranchisePart.stillLandscape(within:)`)
    /// — the first fallback, because it fills a 16:9 tile the way a still does. An AniList banner
    /// is never passed here: its middle third in this tile is a pair of eyes.
    var landscape: String? = nil
    /// The season's (or the show's) poster — the fallback ART, never a glyph.
    let poster: String?
    /// The palette ground under both, so the slot is never grey.
    var tint: Color? = nil
    /// `nil` fills the width it is offered (the accessibility-size card); a number pins the slot.
    var width: CGFloat? = EpisodeArtwork.slot.width
    /// The episode's number, drawn on the FALLBACK tile only. A season the catalogue did not
    /// illustrate gets its own cover behind the numeral that is the episode's whole identity, so
    /// a column of tiles reads 11, 12, 13 instead of one poster eighteen times — which is what
    /// kept every anime season a wall of bare text rows. A real still is never labelled; the
    /// row's text is 8 pt away.
    var number: Int? = nil
    /// The list's NEXT episode — under `EpisodeTileStyle.focus` the one fallback tile that keeps
    /// the sharp picture.
    var featured: Bool = false
    /// A watched episode: its fallback chip sits a shade deeper.
    var dimmed: Bool = false

    @State private var stillTint: Color?

    private var hasStill: Bool { !(url ?? "").isEmpty }
    private var hasLandscape: Bool { !(landscape ?? "").isEmpty }
    private var hasPoster: Bool { !(poster ?? "").isEmpty }
    /// A tile with no still of its own, drawn as the season's colour field under a large numeral.
    private var frosted: Bool {
        guard !hasStill, number != nil, hasLandscape || hasPoster else { return false }
        switch EpisodeTileStyle.current {
        case .art: return false
        case .frosted: return true
        case .focus: return !featured
        }
    }

    /// Where episode `n`'s chip looks into its field: five columns across, three rows down.
    static func window(_ n: Int) -> UnitPoint {
        let columns: [CGFloat] = [0, 0.25, 0.5, 0.75, 1]
        let rows: [CGFloat] = [0.3, 0.7, 0.5]
        let i = max(0, n - 1)
        return UnitPoint(x: columns[i % 5], y: rows[(i / 5) % 3])
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: ThemeRadius.episodeStill, style: .continuous)
                .fill(stillTint ?? tint ?? ThemeColor.surfaceRaised)
            if hasStill {
                RemoteImageView(url: url, contentMode: .fill, maxPixel: (width ?? 400) * 3,
                                placeholderHidden: true)
            } else if frosted {
                // The season's picture as a FIELD of its colours (blurred once, off-main, cached
                // per URL — `BlurredArt`), not as a picture: one sharp image eighteen times down a
                // season read as a placeholder farm (24 Sep, "visuals"). The numeral is the tile.
                let tone = EpisodeTileStyle.frostTone
                // Each chip a different WINDOW of the field (critique, 24 Sep: ten identical blurred
                // chips are still one picture ten times, only softer). A zoom about an anchor that
                // walks the image — a transform on a cached bitmap, nothing per frame.
                BlurredArt(url: landscape ?? poster, sourceMaxPixel: 360, fraction: 0.18,
                           saturation: tone.saturation, brightness: tone.brightness)
                    .scaleEffect(2.4, anchor: Self.window(number ?? 0))
                LinearGradient(colors: [.black.opacity(tone.top), .black.opacity(tone.foot)],
                               startPoint: .top, endPoint: .bottom)
                // One soft light from the top-left corner, so the field has a surface.
                RadialGradient(colors: [.white.opacity(0.10), .clear], center: .topLeading,
                               startRadius: 0, endRadius: 96)
                    .blendMode(.plusLighter)
                // History steps back: a watched episode's chip sits a shade deeper than the ones
                // still to come, so the column reads as a timeline and not as a keypad.
                if dimmed { Color.black.opacity(0.24) }
            } else if hasLandscape {
                // A banner fills the tile the way a still does; the numeral still says which
                // episode, because one banner eighteen times is not eighteen episodes.
                RemoteImageView(url: landscape, contentMode: .fill, maxPixel: (width ?? 400) * 3,
                                alignment: .center, placeholderHidden: true)
                LinearGradient(colors: [.black.opacity(0.20), .black.opacity(0.46)],
                               startPoint: .top, endPoint: .bottom)
            } else if hasPoster {
                // A backdrop crop of the poster: `.top`, because a 2:3 cover carries the face in
                // its upper half and the logotype band in its lower one.
                RemoteImageView(url: poster, contentMode: .fill, maxPixel: (width ?? 400) * 3,
                                alignment: .top, placeholderHidden: true)
                LinearGradient(colors: [.black.opacity(0.25), .black.opacity(0.50)],
                               startPoint: .top, endPoint: .bottom)
            } else {
                // Genuinely no artwork anywhere for this show. The show's colour, and nothing else
                // — a play glyph here would claim a picture failed to load.
                LinearGradient(colors: [.black.opacity(0.10), .black.opacity(0.34)],
                               startPoint: .top, endPoint: .bottom)
            }
            if let number, !hasStill {
                if frosted {
                    // Display type at a FIXED size: the tile is 120×68 at every text size (the
                    // row says the episode in words beside it, and grows).
                    // 22 pt: at 28 the chip's numeral outweighed the 17-pt row title beside it and
                    // the column read as a keypad (critique, 24 Sep).
                    Text("\(number)")
                        .font(.custom("Outfit-Medium", fixedSize: number >= 1000 ? 18 : 22))
                        .monospacedDigit()
                        .tracking(-0.3)
                        .foregroundStyle(ThemeColor.textPrimary.opacity(dimmed ? 0.62 : 0.92))
                        .shadow(color: .black.opacity(0.30), radius: 6, y: 1)
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                } else {
                    Text("\(number)")
                        .font(.system(size: 17, weight: .bold).monospacedDigit())
                        .foregroundStyle(ThemeColor.textPrimary)
                        .shadow(color: .black.opacity(0.55), radius: 3, y: 1)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                        .padding(7)
                }
            }
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .frame(width: width)
        .frame(maxWidth: width == nil ? .infinity : nil)
        .clipShape(RoundedRectangle(cornerRadius: ThemeRadius.episodeStill, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: ThemeRadius.episodeStill, style: .continuous)
            .strokeBorder(ThemeColor.posterEdge, lineWidth: 1))
        .task(id: url ?? landscape ?? poster) {
            stillTint = DetailTint.quiet(await PaletteCache.shared.resolve(url: url ?? landscape ?? poster, maxPixel: 288))
        }
        .accessibilityHidden(true)
    }
}

/// How an episode tile with no still of its own is drawn.
///  • `art` — the season's sharp picture under a small numeral (2 Sep): honest, but on a season
///    the catalogue did not illustrate (every airing anime) it is one picture down the whole list.
///  • `frosted` — the season's picture as a blurred field of its colours under a large numeral:
///    a designed episode chip rather than a repeated photograph.
///  • `focus` — frosted, except the NEXT episode, which keeps the sharp picture: the one row the
///    eye should land on is the one that is lit.
/// `-episodeTile art|frosted|focus` (DEBUG) photographs the three side by side.
enum EpisodeTileStyle {
    case art, frosted, focus

    static var current: EpisodeTileStyle {
        #if DEBUG
        switch UserDefaults.standard.string(forKey: "episodeTile") {
        case "art": return .art
        case "focus": return .focus
        case "frosted": return .frosted
        default: return .focus
        }
        #else
        return .focus
        #endif
    }

    /// The frosted field's exposure: baked into the blurred bitmap (`BlurredArt`), then a veil.
    struct FrostTone {
        let saturation: Double
        let brightness: Double
        let top: Double
        let foot: Double

        static let deep = FrostTone(saturation: 1.4, brightness: -0.20, top: 0.22, foot: 0.55)
        static let mid = FrostTone(saturation: 1.3, brightness: -0.10, top: 0.16, foot: 0.46)
    }

    /// `-episodeFrost deep|mid` (DEBUG).
    static var frostTone: FrostTone {
        #if DEBUG
        return UserDefaults.standard.string(forKey: "episodeFrost") == "mid" ? .mid : .deep
        #else
        return .deep
        #endif
    }
}

// MARK: - The floating toolbar's own edge
//
// `FloatingToolbarVeil` folded into the shared primitive (cohesion pass, 30 Aug):
// `ScrollEdgeChrome(holdHeight:)` is the parameter it existed to change,
// and Detail now calls it directly.

// MARK: - Art-derived colour, made fit to be a ground

/// Detail's quiet form of a palette colour.
///
/// `PaletteCache` clamps the extracted colour to OKLab C ≤ 0.12, which on a warm poster is still a
/// fully saturated brown: composited through `ArtAdaptiveGround` it landed at rgb(37,20,11) —
/// R:B 3.4:1, i.e. an orange block — and on a magenta-and-cyan show it was *also* an orange block,
/// so the colour said nothing about the show it came from. The ground wants the show's HUE, not
/// its saturation.
///
/// Two moves, in OKLab so they are perceptual rather than channel arithmetic:
/// chroma to ≤ 0.045 and lightness held in 0.40…0.46 (desaturating a colour darkens it, and a
/// card with no body is the defect the last pass was fixing), then 20 % toward `surfaceRaised` so
/// every ground shares a little of the app's own neutral. The composite lands near rgb(41,31,28)
/// on the warm poster above — R:B 1.46 — with `textPrimary` at 15.8:1 on it.
///
/// This is a LOCAL workaround: the same transform belongs at the end of `PaletteCache.resolve`,
/// where every screen would inherit it. Filed as a shared-file request.
enum DetailTint {
    private static let maxChroma = 0.045
    private static let minLightness = 0.40
    private static let maxLightness = 0.46
    private static let towardNeutral = 0.20

    /// The card / tile ground form of an art-derived colour.
    static func quiet(_ color: Color?) -> Color? {
        guard let color, let (r, g, b) = components(color) else { return color }
        var (l, ca, cb) = PaletteCache.oklab(r: r, g: g, b: b)
        let chroma = (ca * ca + cb * cb).squareRoot()
        if chroma > maxChroma, chroma > 0 {
            ca *= maxChroma / chroma
            cb *= maxChroma / chroma
        }
        l = min(max(l, minLightness), maxLightness)
        let (qr, qg, qb) = PaletteCache.srgb(l: l, a: ca, b: cb)
        guard let (nr, ng, nb) = components(ThemeColor.surfaceRaised) else {
            return Color(.sRGB, red: qr, green: qg, blue: qb, opacity: 1)
        }
        let m = towardNeutral
        return Color(.sRGB,
                     red: qr * (1 - m) + nr * m,
                     green: qg * (1 - m) + ng * m,
                     blue: qb * (1 - m) + nb * m,
                     opacity: 1)
    }

    /// The hardened bar's ink for a show page: the art colour kept as a HUE, dark enough to be a
    /// bar (OKLab lightness 0.26–0.32 — canvas is ~0.10, `quiet` sits at 0.40–0.46 for a tile), a
    /// little more chroma than a tile so the colour survives the material. Painted at
    /// `chromeBarOpacity` over the blur it is the show's own glass; the flat canvas veil read as a
    /// black slab over the picture ("too blackish anyway, should be glassish", user, 4 Sep).
    ///
    /// A breath ABOVE the page's own ground (24 Sep): at 0.26–0.32 over a ground toned down to
    /// 0.17 the bar was a lighter lid across the top of every scrolled frame — a grey-violet or
    /// brown header slab (the critique measured L 0.31 over 0.17). Glass in the show's colour, a
    /// shade lifted, is what the owner asked for ("glassish").
    static func chrome(_ color: Color?) -> Color? {
        guard let color, let (r, g, b) = components(color) else { return color }
        var (_, ca, cb) = PaletteCache.oklab(r: r, g: g, b: b)
        let chroma = (ca * ca + cb * cb).squareRoot()
        let maxChroma = GroundSpec.current.barChroma
        if chroma > maxChroma, chroma > 0 {
            ca *= maxChroma / chroma
            cb *= maxChroma / chroma
        }
        let l = GroundSpec.current.top + 0.05
        let (qr, qg, qb) = PaletteCache.srgb(l: l, a: ca, b: cb)
        return Color(.sRGB, red: qr, green: qg, blue: qb, opacity: 1)
    }

    /// The opacity at which `quiet` sits over the card ground to read as that ground lifted ~6 %
    /// in luminance — the no-still tile's fill. Composited rather than computed, so the tile
    /// tracks the ground's own gradient and radial highlight instead of guessing one value for it.
    static let tileOverGround: Double = 0.35

    /// The show page's GROUND (6 Sep): the art colour as a HUE at canvas depth, so the whole page
    /// sits in the show's atmosphere instead of stepping from the billboard onto #09090B. OKLab
    /// lightness pinned to `lightness` — `groundTopLightness` under the hero, about `surfaceFlat`'s
    /// depth; `groundFootLightness` at the foot, a breath above canvas (≈ 0.14) so the bottom
    /// chrome's canvas veil lands on it without a step — and chroma ≤ 0.06: a deep navy for a blue
    /// show, a deep umber for a warm one, never a coloured slab. Nil (art still loading) is canvas.
    ///
    /// TONED DOWN (24 Sep, owner: "a bit too shouting… tone it down so the rest of the content is
    /// properly visible without losing the immersive nature"): the hue stays, the voice drops —
    /// less chroma, a ground nearer the canvas, a fainter pool of light. `-detailGround strong |
    /// medium | subtle` (DEBUG) photographs the three strengths side by side; `medium` ships.
    struct GroundSpec {
        let maxChroma: Double
        let top: Double
        let foot: Double
        let pool: Double
        let barChroma: Double

        static let strong = GroundSpec(maxChroma: 0.06, top: 0.19, foot: 0.155, pool: 0.14, barChroma: 0.06)
        static let medium = GroundSpec(maxChroma: 0.038, top: 0.172, foot: 0.148, pool: 0.07, barChroma: 0.04)
        static let subtle = GroundSpec(maxChroma: 0.026, top: 0.162, foot: 0.144, pool: 0.04, barChroma: 0.03)

        static var current: GroundSpec {
            #if DEBUG
            switch UserDefaults.standard.string(forKey: "detailGround") {
            case "strong": return .strong
            case "subtle": return .subtle
            default: return .medium
            }
            #else
            return .medium
            #endif
        }
    }

    static var groundTopLightness: Double { GroundSpec.current.top }
    static var groundFootLightness: Double { GroundSpec.current.foot }
    static var groundPool: Double { GroundSpec.current.pool }

    static func ground(_ color: Color?, lightness: Double) -> Color {
        guard let color, let (r, g, b) = components(color) else { return ThemeColor.canvas }
        var (_, ca, cb) = PaletteCache.oklab(r: r, g: g, b: b)
        let chroma = (ca * ca + cb * cb).squareRoot()
        let maxChroma = GroundSpec.current.maxChroma
        if chroma > maxChroma, chroma > 0 {
            ca *= maxChroma / chroma
            cb *= maxChroma / chroma
        }
        let (qr, qg, qb) = PaletteCache.srgb(l: lightness, a: ca, b: cb)
        return Color(.sRGB, red: qr, green: qg, blue: qb, opacity: 1)
    }

    private static func components(_ color: Color) -> (Double, Double, Double)? {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a) else { return nil }
        return (Double(r), Double(g), Double(b))
    }
}

// MARK: - Withheld still

/// The 96×54 rectangle that stands in for a still the app is deliberately NOT showing.
///
/// The tile it replaces printed an identifier — `S7 · E2` — built from `sequence`, the raw ordinal
/// among all parts, where OVAs and films occupy slots. On every AniList franchise with an OVA it
/// disagreed with the fact line 8 pt away ("Season 4 · Episode 19" beside "S5 · E19"), broke the
/// copy table's own notation rule twice over, and was the screenshot attached to the one-star
/// review. A string that cannot contradict its neighbour is the one that does not exist: the
/// episode's identity is stated once, in the row's text, and the rectangle says only what it is
/// doing — withholding a picture.
///
/// Distinct from the shared `EpisodeGlyphTile` (`play.rectangle` = there is no still at all): a
/// withheld still is a choice the user can reverse, and `eye.slash` is the glyph on the control
/// that reverses it.
struct WithheldStillTile: View {
    /// Already quieted — this sits over a `.art` ground and must not out-shout it.
    let tint: Color?

    var body: some View {
        RoundedRectangle(cornerRadius: ThemeRadius.episodeStill, style: .continuous)
            .fill(tint ?? ThemeColor.surfaceRaised)
            .frame(width: EpisodeArtwork.slot.width, height: EpisodeArtwork.slot.height)
            .overlay {
                LinearGradient(colors: [.black.opacity(0.10), .black.opacity(0.34)],
                               startPoint: .top, endPoint: .bottom)
            }
            .overlay {
                AppGlyph(systemName: "eye.slash")
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(ThemeColor.textPrimary.opacity(0.62))
            }
            .clipShape(RoundedRectangle(cornerRadius: ThemeRadius.episodeStill, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: ThemeRadius.episodeStill, style: .continuous)
                .strokeBorder(ThemeColor.posterEdge, lineWidth: 1))
            .accessibilityHidden(true)
    }
}


// MARK: - The episode rows

/// One season's episodes, as rows — on the show page and, for the run an extra opens, on the
/// season screen. One row anatomy, one mark control, one spoiler model, defined once.
///
/// **The list OPENS WHERE YOU ARE** (6 Sep, chosen from three photographed directions after
/// "what about the most recent episode? … otherwise it's a bigger scroll", user): a season of
/// more than `wholeBelow` rows opens on the next episode with `windowBefore` watched rows above
/// it for context and `windowAfter` ahead, and everything earlier is one in-place tap up
/// ("Show earlier episodes", `growBy` a tap — Mail's "Load Earlier Messages"). Measured before
/// the change: Slime S4 (21 of 24 watched) put the next episode 1,842 pt down the list, 2.2
/// screens of watched rows and 3.1 from the top of the page. Plex users file the same thing as a
/// bug when a long season fails to advance to the on-deck episode (plex-media-player #914).
/// Two directions were built, photographed and rejected: a whole season from Episode 1 with an
/// in-page "Jump to episode 22" link (NN/g's in-page link — the reader keeps control, but the
/// season's first twenty rows are still the first thing on the screen), and newest-first (Apple
/// Podcasts' EPISODIC order — but Apple itself puts the first episode at the top for SERIAL
/// shows, and a TV season is serial, so the numbers counted down as you read).
///
/// Rebuilt on 6 Sep ("built extremely poorly… causes a lot of confusion rather than solving the
/// problem", user). The show page drew six rows from the next episode with an "All 24 episodes ›"
/// door to a second screen: a list that began at Episode 19 with the season's first eighteen on
/// another page was the tangent, not the season. The rules now:
///  • **The row opens, the ring marks.** Tapping a row never writes progress — Apple TV's tile
///    plays and its description opens the episode, Podcasts keeps "Mark as Played" off the row,
///    Reminders completes on the circle alone — so a viewer curious about an episode cannot mark
///    it by accident. A row with something to show (an overview, a withheld title) expands in
///    place; a bare row is inert.
///  • **The control is the receipt.** A mark fills its own ring — accent, the check drawn, one
///    pulse — and settles into the show's colour while the accent ring moves to the next row
///    (HIG: status feedback belongs beside the item it describes; confirmations are for the
///    significant). No "✓ Episode 7 watched · Undo" line: the ring says it, and its undo is the
///    ring itself — the last watched episode toggles back with one tap. Batch marks and batch
///    unmarks confirm with their exact count and take their Undo to the lane.
///  • **No numeral in the ring.** The row states the episode 14 pt away.
struct EpisodeList: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    let franchise: Franchise
    let part: FranchisePart
    /// The whole-list spoiler switch (the season screen's overflow owns it).
    var revealAll: Bool = false
    /// The show's colour, already quieted (`DetailTint.quiet`), under the still tiles and on the
    /// watched discs.
    var tint: Color? = nil
    /// The episode a route asked for (a Schedule card): the window opens on it.
    var focusEpisode: Int? = nil

    /// A season this short is ALWAYS drawn whole: six to twelve rows is a screen and a half, and
    /// folding three of Thrones' six episodes to save half a screen is a fold for its own sake.
    /// Above it the list opens on a window around the next episode — `windowBefore` rows of
    /// history for context, `windowAfter` ahead — and grows in place by `growBy` a tap, Mail's
    /// "Load Earlier Messages": the list gets longer where it is, nothing is pushed.
    static let wholeBelow = 12
    static let windowBefore = 3
    static let windowAfter = 8
    static let growBy = 12

    @State private var revealed: Set<Int> = []
    @State private var expanded: Set<Int> = []
    @State private var prompt: FranchiseDetailView.WritePrompt?
    /// The row whose ring is in its commit beat (accent, the check drawing) before it settles.
    @State private var committing: Int?
    @State private var committingTask: Task<Void, Never>?
    /// A batch mark plays its discs in order: rows above this number are drawn unmarked until the
    /// cascade reaches them (the model has already moved).
    @State private var cascadeThrough: Int?
    @State private var cascadeTask: Task<Void, Never>?
    /// The rows a long run shows; nil until the first expander is tapped.
    @State private var shown: ClosedRange<Int>?

    private var now: Int64 { appModel.now }

    /// How many rows a season has: what the catalogue lists, what has aired, or what the user has
    /// marked — whichever is largest.
    static func count(_ part: FranchisePart, now: Int64) -> Int {
        if part.isUpcoming { return part.announcedEpisodeNumbers.last ?? 0 }
        return max(part.renderableEpisodeCount(now: now), part.progress, part.episodes.map(\.number).max() ?? 0)
    }

    private var total: Int { Self.count(part, now: now) }

    /// The episode the list is ABOUT: the one a route asked for, else the next to watch, else —
    /// on a season with nothing left — its beginning (a finished season is a browse, not a queue).
    private var anchorEpisode: Int {
        if let focusEpisode { return focusEpisode }
        return part.progress < total ? part.progress + 1 : 1
    }

    /// The row that wears NEW: the newest AIRED episode, while it is still unwatched, on a season
    /// that is actually running and whose latest drop is recent. All three conditions are load-
    /// bearing — without the last two, The Witcher's finished 2023 season tagged its Episode 8
    /// "NEW" (captured 6 Sep), which is a label for news, not for the end of a list.
    private var freshEpisode: Int? {
        guard part.isReleasing else { return nil }
        let aired = min(max(part.provenAiredCount(now: now), part.airedEpisodes), total)
        guard aired > part.progress, aired >= 1 else { return nil }
        guard let at = part.lastAired(now: now, anchor: franchise.timeAnchor),
              now - at <= Self.freshWindow else { return nil }
        return aired
    }

    /// How long a drop stays news: the deck's window (`AppModel.outNowWindow`, a week) — ONE
    /// freshness everywhere (review i4: the list tagged NEW for 14 days, the deck held a drop for 7
    /// and the hero named it for one calendar day). A weekly show's newest episode wears it until
    /// the next lands; a show that stopped mid-cour does not wear it for months.
    static let freshWindow: Int64 = AppModel.outNowWindow

    /// The rows to draw: the whole season when it is short, else the window around the anchor —
    /// grown by whatever the reader has opened.
    private var range: ClosedRange<Int>? {
        let total = total
        guard total > 0 else { return nil }
        if part.isUpcoming { return 1...total }
        if let shown { return Self.clamp(shown, total: total) }
        if total <= Self.wholeBelow { return 1...total }
        return Self.initialWindow(anchor: anchorEpisode, total: total)
    }

    static func initialWindow(anchor: Int, total: Int) -> ClosedRange<Int> {
        let a = min(max(1, anchor), total)
        return clamp((a - windowBefore)...(a + windowAfter), total: total)
    }

    static func clamp(_ r: ClosedRange<Int>, total: Int) -> ClosedRange<Int> {
        let lower = min(max(1, r.lowerBound), total)
        return lower...min(total, max(lower, r.upperBound))
    }

    var body: some View {
        // A plain stack: the window keeps a long run to a dozen rows, and an eager stack is what
        // lets `scrollTo("ep-n")` land on a row that has not been on screen yet (a Schedule card).
        VStack(spacing: 0) {
            if let range {
                if range.lowerBound > 1 {
                    expander(Copy.Action.showEarlierEpisodes, glyph: "chevron.up") { grow(earlier: true) }
                }
                ForEach(part.isUpcoming ? part.announcedEpisodeNumbers : Array(range), id: \.self) { n in
                    row(franchise, part: part, n: n, isLast: n == range.upperBound)
                        .id("ep-\(n)")
                }
                if range.upperBound < total {
                    expander(Copy.Action.showMoreEpisodes, glyph: "chevron.down") { grow(earlier: false) }
                }
            } else {
                Text(part.isUpcoming ? Copy.Release.episodesNotAnnounced : Copy.Release.episodesUnavailable)
                    .type(ThemeType.metadata)
                    .foregroundStyle(ThemeColor.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, ThemeSpace.x4)
            }
        }
        // An alert with Cancel, as every write confirmation (review i4).
        .alert(prompt?.title ?? "", isPresented: Binding(get: { prompt != nil }, set: { if !$0 { prompt = nil } }),
               presenting: prompt) { p in
            Button(p.confirm, role: p.destructive ? .destructive : nil) { p.perform() }
            Button(Copy.Confirm.cancel, role: .cancel) {}
        } message: { p in
            Text(p.message)
        }
        .onDisappear {
            committingTask?.cancel()
            cascadeTask?.cancel()
        }
    }

    /// The newest aired episode's tag: amber, the app's one colour for state, at the eyebrow's
    /// size. A tag rather than a coloured title — the row's ink means watched / not watched.
    private var newTag: some View {
        // NEWS red, like the hero's NEW EPISODE (24 Sep).
        Text(Copy.Label.newTag)
            .type(ThemeType.sectionLabel)
            .fixedSize()
            .foregroundStyle(ThemeColor.onNews)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(ThemeColor.news, in: RoundedRectangle(cornerRadius: 3, style: .continuous))
    }

    /// A long run's in-place door: a quiet centred link in `interactive` ink, like "Read more".
    private func expander(_ title: String, glyph: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                AppGlyph(systemName: glyph).font(.system(size: 11, weight: .semibold))
            }
        }
        .buttonStyle(InlineLinkButtonStyle())
        // On the gutter, like "Mark all N episodes as watched…" directly above it and every other
        // inline link on the page: centred, the two adjacent links sat on two axes (review i2).
        .padding(.leading, -12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func grow(earlier: Bool) {
        guard let current = range else { return }
        let next = earlier ? (current.lowerBound - Self.growBy)...current.upperBound
                           : current.lowerBound...(current.upperBound + Self.growBy)
        withAnimation(ThemeMotion.pick(ThemeMotion.uiSnappy, reduceMotion: reduceMotion)) {
            shown = Self.clamp(next, total: total)
        }
    }

    // MARK: Row

    private func row(_ f: Franchise, part: FranchisePart, n: Int, isLast: Bool) -> some View {
        let episode = part.episodes.first { $0.number == n }
        let progress = part.progress
        let watched = n <= progress
        // A batch plays its discs one after another; a row the cascade has not reached is still
        // drawn unmarked (the model has already moved).
        let drawnWatched = watched && (cascadeThrough.map { n <= $0 } ?? true)
        let aired = !part.isUpcoming
            && (!part.isReleasing || n <= part.provenAiredCount(now: now) || n <= part.airedEpisodes)
        let isNext = n == progress + 1 && aired
        let spoilerSafe = watched || isNext || revealAll || revealed.contains(n)
        let interactive = appModel.isInLibrary(f.id) && aired
        let cleanTitle = EpisodeCopy.title(episode?.title, franchise: f.title)
        let canReveal = !spoilerSafe && (cleanTitle != nil || episode?.still != nil)
        let overview = Formatting.stripHtml(episode?.overview)
        // A row OPENS when it has something to show: an overview to read, or a withheld title to
        // reveal. A bare "Episode 12" row is inert — a tap that does nothing is honest; a tap
        // that marks is a trap.
        let opens = !overview.isEmpty || canReveal
        let isOpen = expanded.contains(n) && spoilerSafe && !overview.isEmpty
        let isAX = typeSize.isAccessibilitySize
        let layout = isAX ? AnyLayout(VStackLayout(alignment: .leading, spacing: ThemeSpace.x2))
                          : AnyLayout(HStackLayout(alignment: .center, spacing: ThemeMetrics.artGap))
        let content = layout {
            tile(f, part: part, n: n, episode: episode, spoilerSafe: spoilerSafe, aired: aired, isNext: isNext)
            VStack(alignment: .leading, spacing: ThemeMetrics.titleGap) {
                HStack(alignment: .firstTextBaseline, spacing: ThemeSpace.x2) {
                    VStack(alignment: .leading, spacing: 2) {
                        if let t = cleanTitle, spoilerSafe {
                            // Apple TV's row: the number is an EYEBROW over the title, never
                            // "Episode 10 · Mhysa" on one line (user, 4 Sep). The newest aired
                            // episode you have not watched wears NEW on that eyebrow — amber for
                            // STATE, the one thing on the row that is news.
                            HStack(spacing: ThemeSpace.x1) {
                                Text(Copy.episode(n))
                                    .type(ThemeType.sectionLabel)
                                    .textCase(.uppercase)
                                    .foregroundStyle(ThemeColor.textTertiary)
                                if n == freshEpisode { newTag }
                            }
                            Text(t)
                                .type(ThemeType.rowTitle)
                                .foregroundStyle(drawnWatched ? ThemeColor.textSecondary : ThemeColor.textPrimary)
                                .lineLimit(isOpen ? nil : 2)
                                // An identity title never ellipsises.
                                .minimumScaleFactor(0.92)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            HStack(spacing: ThemeSpace.x2) {
                                Text(Copy.episode(n))
                                    .type(ThemeType.rowTitle)
                                    .foregroundStyle(drawnWatched ? ThemeColor.textSecondary : ThemeColor.textPrimary)
                                    .lineLimit(isAX ? nil : 1)
                                    .fixedSize(horizontal: false, vertical: true)
                                    // The title keeps its characters; the tag and the reveal glyph
                                    // give way ("Episo… NEW", captured 6 Sep).
                                    .layoutPriority(1)
                                if n == freshEpisode { newTag }
                            }
                        }
                    }
                    // The spoiler control belongs to the TITLE it is hiding, not to the trailing
                    // control column — a row has one control column, not a toolbar.
                    if canReveal { revealGlyph(n) }
                }
                if let sub = rowSubtitle(f, part: part, episode: episode, n: n, aired: aired, isNext: isNext, watched: drawnWatched) {
                    Text(sub.text)
                        .type(sub.accent ? ThemeType.rowMetaLead : ThemeType.rowMeta)
                        .foregroundStyle(sub.accent ? ThemeColor.accent : ThemeColor.textSecondary)
                        .lineLimit(isAX ? nil : 1)
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity)
                }
            }
            if !isAX { Spacer(minLength: 0) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        // The title dims and "Next up" moves on with the mark, on the settle spring.
        .animation(ThemeMotion.pick(ThemeMotion.uiSettle, reduceMotion: reduceMotion), value: drawnWatched)
        .animation(ThemeMotion.pick(ThemeMotion.uiSettle, reduceMotion: reduceMotion), value: isNext)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: ThemeSpace.x2) {
                if opens {
                    Button { open(n, reveal: canReveal, hasOverview: !overview.isEmpty) } label: { content }
                        .buttonStyle(RowPressStyle())
                        .accessibilityHint(isOpen ? Copy.Accessibility.hidesEpisodeDetails : Copy.Accessibility.showsEpisodeDetails)
                } else {
                    content
                }
                if aired {
                    mark(f, part: part, n: n, watched: watched, drawnWatched: drawnWatched, isNext: isNext, interactive: interactive)
                        // The ring is centred in its 44-pt target; pulled 9 pt out so the column of
                        // discs ends on the content edge, under the season pill and the rules
                        // (critique, 24 Sep: rings at 366, everything else at 377).
                        .padding(.trailing, -9)
                }
            }
            .padding(.vertical, 6)
            // One pitch down the column: the tile's own height.
            .frame(minHeight: ThemeMetrics.rowEpisode, alignment: .center)
            if isOpen {
                details(episode, overview: overview, watched: watched)
                    .transition(.opacity.combined(with: .offset(y: -6)))
            }
        }
        // Unaired rows recede as a GROUP, one opacity (0.72 ≈ 5.4:1 and still steps back).
        .opacity(aired ? 1 : 0.72)
        .overlay(alignment: .bottom) {
            if !isLast {
                Rectangle().fill(ThemeColor.separatorQuiet).frame(height: 1)
                    .padding(.leading, isAX ? 0 : EpisodeArtwork.slot.width + ThemeMetrics.artGap)
            }
        }
    }

    /// EVERY row carries a tile: the episode's still, a withheld still, or the season's own cover
    /// under the episode's number. The list used to drop the art column for any season under a
    /// third illustrated — most anime — and became a column of bare "Episode 12 / Aired 3 Jul"
    /// text (user, 2 Sep: "not there yet"). The numbered cover is the episode's face where the
    /// catalogue gave it none.
    @ViewBuilder
    private func tile(_ f: Franchise, part: FranchisePart, n: Int, episode: Episode?, spoilerSafe: Bool, aired: Bool,
                      isNext: Bool) -> some View {
        if spoilerSafe {
            EpisodeStill(url: episode?.still, landscape: part.stillLandscape(within: f),
                         poster: part.portraitArt ?? f.portraitArt, tint: tint, number: n, featured: isNext,
                         dimmed: n <= part.progress)
        } else if aired, episode?.still?.isEmpty == false {
            // Withheld, and it says so: `eye.slash`, the glyph on the control that reverses it.
            WithheldStillTile(tint: tint)
        } else {
            EpisodeStill(url: nil, landscape: part.stillLandscape(within: f),
                         poster: part.portraitArt ?? f.portraitArt, tint: tint, number: n)
        }
    }

    /// The ONE mark control, in its list form (`MarkRing.Style.settled`): history as discs in the
    /// show's colour, the next episode the one accent ring, no numeral.
    private func mark(_ f: Franchise, part: FranchisePart, n: Int, watched: Bool, drawnWatched: Bool,
                      isNext: Bool, interactive: Bool) -> some View {
        let last = n == part.progress
        let hint: String = {
            guard interactive else { return "" }
            if watched { return last ? "Marks as unwatched" : "Marks this and the episodes after it as unwatched" }
            return isNext ? "Marks as watched" : "Marks the episodes up to this one as watched"
        }()
        return MarkRing(marked: drawnWatched, style: .settled, lead: isNext, fill: tint,
                        committing: committing == n,
                        label: Copy.Action.markEpisodeWatched(n),
                        markedLabel: Copy.Progress.episodeWatched(n)) {
            if interactive { tapped(f, part: part, n: n, watched: watched) }
        }
        .disabled(!interactive)
        .accessibilityValue(watched ? "Watched" : "Not watched")
        .qaIdentifier(isNext ? "qa.progress.increment.\(part.mediaId)" : "qa.episode.\(part.mediaId).\(n)")
        .accessibilityHint(hint)
    }

    /// What a row opens to: the overview, with the runtime and — on a watched row, whose second
    /// line is empty by rule — the air date. Set under the title column, clear of the ring.
    private func details(_ episode: Episode?, overview: String, watched: Bool) -> some View {
        var facts: [String] = []
        if let r = episode?.runtime, r > 0 { facts.append(Copy.minutes(r)) }
        if watched, let d = episode?.airDateLabel { facts.append(d) }
        return VStack(alignment: .leading, spacing: ThemeSpace.x1) {
            if !facts.isEmpty {
                Text(facts.joined(separator: " \u{00B7} "))
                    .type(ThemeType.metadata)
                    .foregroundStyle(ThemeColor.textTertiary)
            }
            Text(overview)
                .type(ThemeType.prose)
                .lineSpacing(4)
                .foregroundStyle(ThemeColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, typeSize.isAccessibilitySize ? 0 : EpisodeArtwork.slot.width + ThemeMetrics.artGap)
        .padding(.trailing, 44 + ThemeSpace.x2)
        .padding(.bottom, ThemeSpace.x3)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func open(_ n: Int, reveal: Bool, hasOverview: Bool) {
        withAnimation(ThemeMotion.pick(ThemeMotion.uiSnappy, reduceMotion: reduceMotion)) {
            if reveal { revealed.insert(n) }
            guard hasOverview else { return }
            if expanded.contains(n) { expanded.remove(n) } else { expanded = [n] }
        }
    }

    private func revealGlyph(_ n: Int) -> some View {
        Button {
            _ = withAnimation(ThemeMotion.pick(ThemeMotion.uiMicro, reduceMotion: reduceMotion)) { revealed.insert(n) }
        } label: {
            AppGlyph(systemName: "eye")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(ThemeColor.textTertiary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(MarkPressStyle())
        // The 44-pt target is held by the frame; the row is pulled back optically so a hidden
        // title does not sit 30 pt taller than the row beneath it.
        .padding(.vertical, -14)
        .accessibilityLabel(DetailCopy.revealEpisodeTitle)
    }

    private func rowSubtitle(_ f: Franchise, part: FranchisePart, episode: Episode?, n: Int, aired: Bool,
                             isNext: Bool, watched: Bool) -> (text: String, accent: Bool)? {
        // One rule per row. A WATCHED row says nothing: the disc says it, and its air date is a
        // fact about the past (it returns in the row's details). The show page's window used to
        // mix four grammars in six rows (4 Sep).
        if watched { return nil }
        if isNext { return (Copy.Label.nextUp, true) }
        if !aired {
            if n == part.airedEpisodes + 1, let at = part.scheduledAiring(now: now, anchor: f.source.timeAnchor) {
                return (TemporalCopy.airsSentence(at: at, now: now, source: f.source), false)
            }
            // Nothing: "Upcoming" says only what the row's position below the dated ones says.
            return nil
        }
        if let d = episode?.airDate { return (TemporalCopy.aired(at: d, now: now, source: .tmdb), false) }
        // DERIVED, because the app demonstrably knows: the part's own air window plus the weekly
        // cadence. Where neither anchor exists the row prints nothing — an invented date is worse
        // than a blank.
        if let at = derivedAirDate(part, n: n) {
            return (TemporalCopy.aired(at: at, now: now, source: f.source), false)
        }
        return nil
    }

    /// One week per episode, anchored on whichever real instant the part carries. Conservative:
    /// never runs forward past an anchor, never fires without one.
    private func derivedAirDate(_ part: FranchisePart, n: Int) -> Int64? {
        let week: Int64 = 7 * 24 * 60 * 60 * 1000
        if let next = part.nextAiringAt, let nextNumber = part.nextEpisodeNumber, nextNumber > n {
            return next - Int64(nextNumber - n) * week
        }
        if let last = part.lastAiredAt, part.airedEpisodes >= n {
            return last - Int64(part.airedEpisodes - n) * week
        }
        return nil
    }

    // MARK: Marks

    private func tapped(_ f: Franchise, part: FranchisePart, n: Int, watched: Bool) {
        if watched {
            if n == part.progress {
                // The ring's own undo: the last watched episode toggles back — the disc opens
                // into the accent ring again. No confirmation, no receipt.
                endCommit()
                appModel.setProgress(franchiseId: f.id, mediaId: part.mediaId, episodes: n - 1)
            } else {
                promptUnmark(f, part: part, to: n - 1)
            }
        } else if n == part.progress + 1 {
            let completes = n >= part.markTarget(now: now) && !part.isReleasing && part.totalEpisodes > 0
            guard let undo = appModel.markNext(franchiseId: f.id, mediaId: part.mediaId,
                                               haptic: completes ? .success : .commitLight) else { return }
            beginCommit(n)
            // The one receipt a single mark still earns: the series finishing ("Series finished ·
            // Moved to Watched") — a milestone, said once, in the lane.
            if undo.customMessage != nil { appModel.presentUndo(undo) }
        } else {
            promptMark(f, part: part, through: n)
        }
    }

    /// The commit beat: THIS ring is accent with its check drawing for ~0.55 s (0.25 s under
    /// Reduce Motion), then settles into the show's colour on the settle spring.
    private func beginCommit(_ n: Int) {
        committingTask?.cancel()
        withAnimation(ThemeMotion.pick(ThemeMotion.uiMicro, reduceMotion: reduceMotion)) { committing = n }
        committingTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(reduceMotion ? 250 : 550))
            guard !Task.isCancelled else { return }
            withAnimation(ThemeMotion.pick(ThemeMotion.uiSettle, reduceMotion: reduceMotion)) { committing = nil }
        }
    }

    private func endCommit() {
        committingTask?.cancel()
        committing = nil
    }

    /// A batch plays its discs in order — a row every ~40 ms, the whole run inside 0.6 s, the
    /// accent beat travelling down the column — so twelve checks read as twelve marks made, not a
    /// list re-rendered.
    private func cascade(from: Int, through: Int) {
        cascadeTask?.cancel()
        committingTask?.cancel()
        guard through >= from, !reduceMotion else { cascadeThrough = nil; committing = nil; return }
        let count = through - from + 1
        let step = max(1, Int((Double(count) / 14).rounded(.up)))
        cascadeThrough = from - 1
        cascadeTask = Task { @MainActor in
            var n = from - 1
            while n < through {
                try? await Task.sleep(for: .milliseconds(42))
                guard !Task.isCancelled else { return }
                n = min(through, n + step)
                withAnimation(ThemeMotion.uiMicro) {
                    cascadeThrough = n
                    committing = n
                }
            }
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            withAnimation(ThemeMotion.uiSettle) {
                cascadeThrough = nil
                committing = nil
            }
        }
    }

    private func promptMark(_ f: Franchise, part: FranchisePart, through: Int) {
        let count = through - part.progress
        guard count > 0 else { return }
        prompt = .init(title: Copy.Confirm.batchMarkTitle(count), message: Copy.Confirm.batchMarkMessage(title: f.displayTitle, season: part.canonicalLabel, from: part.progress, to: through),
                       confirm: Copy.Confirm.batchMarkConfirm(count)) {
            let prev = part.progress
            let shelvedAs = appModel.resumableStatus(f, part: part)
            appModel.setProgress(franchiseId: f.id, mediaId: part.mediaId, episodes: through)
            cascade(from: prev + 1, through: through)
            // A batch's Undo rides the lane: the rows are busy being the receipt.
            var receipt = UndoState(mediaId: part.mediaId, franchiseId: f.id, prevProgress: prev, title: f.title, episode: through, count: count)
            appModel.resume(shelvedAs, franchiseId: f.id, mediaId: part.mediaId, prevProgress: prev, receipt: &receipt)
            appModel.presentUndo(receipt)
        }
    }

    private func promptUnmark(_ f: Franchise, part: FranchisePart, to: Int) {
        let count = part.progress - to
        guard count > 0 else { return }
        let message = to == 0 ? Copy.Confirm.resetSeason(label: part.canonicalLabel, total: count)
                              : Copy.Confirm.batchMarkMessage(title: f.displayTitle, season: part.canonicalLabel, from: part.progress, to: to)
        prompt = .init(title: to == 0 ? Copy.Confirm.resetSeasonTitle(count) : "Mark \(Copy.episodes(count)) as unwatched?",
                       message: message, confirm: to == 0 ? Copy.Confirm.resetSeasonConfirm(count) : "Mark \(Copy.episodes(count)) as unwatched",
                       destructive: true) {
            let prev = part.progress
            endCommit()
            appModel.setProgress(franchiseId: f.id, mediaId: part.mediaId, episodes: to)
            appModel.presentUndo(UndoState(mediaId: part.mediaId, franchiseId: f.id, prevProgress: prev, title: f.title, episode: to, count: count,
                                           customMessage: to == 0 ? Copy.Toast.seasonUnmarked(part.canonicalLabel) : Copy.Toast.batchUnmarked(count)))
        }
    }
}

// MARK: - The season pill · the folded watched row

/// The season as a capsule menu — "Season 4 ⌄" — the ONE control that chooses a season, on the
/// show page's Episodes header and on the season screen. The same capsule family as the bar's
/// status menu, drawn on the canvas: `surfaceFloating` ground, a crisp stroke, `metadataEmphasis`.
/// It lists SEASONS (`Franchise.seasonPartsInOrder`), never the catalogue. The season's name used
/// to BE the section title, set in the section face with a small stacked chevron, and did not
/// read as a control (4 Sep); every streaming app draws the selector as a pill beside "Episodes".
struct SeasonPill: View {
    let current: FranchisePart
    let seasons: [FranchisePart]
    let onPick: (Int) -> Void

    /// The source's own label, else the part's title. Never derived from `sequence`.
    static func name(_ part: FranchisePart) -> String {
        part.canonicalLabel.isEmpty ? part.title : part.canonicalLabel
    }

    var body: some View {
        Menu {
            ForEach(seasons) { season in
                Button { onPick(season.mediaId) } label: {
                    if season.mediaId == current.mediaId {
                        AppGlyphLabel(Self.name(season), systemName: "checkmark")
                    } else {
                        Text(Self.name(season))
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                // The short form on the pill ("The Calamity", "Season 5"); the menu keeps the
                // full names. The whole label made a 261-pt pill cut to "…The Ca…" (review, 23 Sep).
                Text(Copy.compactPartLabel(Self.name(current)))
                    .type(ThemeType.metadataEmphasis)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .contentTransition(.opacity)
                AppGlyph(systemName: "chevron.down").font(.system(.caption2, weight: .semibold))
            }
            .foregroundStyle(ThemeColor.textPrimary)
            .padding(.horizontal, 14)
            .frame(maxWidth: 190)
            // Hugging: min(ideal, 190) — as a flexible frame beside a Spacer it took all 190 and
            // centred "Season 4" in a wide capsule (iteration 2).
            .fixedSize(horizontal: true, vertical: false)
            .frame(minHeight: 34)
            // A translucent ground that takes the page's colour, not the blue-grey floating
            // surface — it sat on purple and maroon show pages as an off-palette slab.
            .background(ThemeColor.textPrimary.opacity(0.10), in: Capsule())
            // `strokeBorder`: a centred stroke straddles the edge and smears (see
            // `SecondaryButtonStyle2`).
            .overlay(Capsule().strokeBorder(ThemeColor.stroke, lineWidth: 1))
            .contentShape(Capsule())
            .frame(minHeight: 44)
        }
        .accessibilityLabel("Season, \(Self.name(current))")
        .accessibilityHint("Chooses another season")
    }
}
