import SwiftUI
import CoreImage
import Vision

// Cover/banner image with the legacy gradient fallback. Poster art is the star — no glass here.
// Backed by CachedAsyncImage (decoded-image cache + off-main downsampling) so grids scroll without
// flicker or hitches. `maxPixel` bounds the decode to the display size — posters need far less than
// AniList's extraLarge source.
struct RemoteImageView: View {
    let url: String?
    var contentMode: ContentMode = .fill
    var maxPixel: CGFloat = 700
    /// Where a `.fill` image anchors inside its frame (`.top` keeps faces in a tall crop).
    var alignment: Alignment = .center
    /// Hosts that draw their own ground (palette tint, art backdrop) hide the opaque placeholder.
    var placeholderHidden: Bool = false
    /// Frame aspect a near-matching `.fit` image snaps to fill against — see `CachedAsyncImage`.
    var fitSnapAspect: CGFloat? = nil
    /// A contact shadow under a `.fit` image — see `CachedAsyncImage.fitShadow`.
    var fitShadow: ShadowToken? = nil
    /// Called once the image is on screen (the launch waits for the hero's picture).
    var onLoaded: (() -> Void)? = nil

    var body: some View {
        CachedAsyncImage(url: parsedURL, maxPixel: maxPixel, contentMode: contentMode,
                         alignment: alignment, placeholderHidden: placeholderHidden,
                         fitSnapAspect: fitSnapAspect, fitShadow: fitShadow, onLoaded: onLoaded)
    }

    private var parsedURL: URL? {
        guard let url, !url.isEmpty else { return nil }
        return URL(string: url)
    }
}

struct GradientPlaceholder: View {
    var body: some View {
        LinearGradient(
            colors: [Color(hex: 0x27272F), Color(hex: 0x141418)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

/// Normalized, top-origin bounds of the poster's existing title. This is layout metadata only:
/// no source pixels are cropped, painted out, blurred or replaced.
struct PosterTitleRegion: Equatable, Sendable, Codable {
    let top: CGFloat
    let bottom: CGFloat

    static let lowerTitle = PosterTitleRegion(top: 0.62, bottom: 0.89)
    /// Vision read no lettering at all: the picture does NOT carry the name, so the lockup sets
    /// it. A text-free key visual used to be trusted as titled, and the show had no name anywhere
    /// on its billboard (Mushoku Tensei's panel poster, 23 Sep).
    static let untitled = PosterTitleRegion(top: 1, bottom: 1)
    var isUntitled: Bool { top >= 1 }
}

/// One reading of a poster: where its title is printed, and the picture's true aspect.
struct PosterAnalysis: Equatable, Sendable, Codable {
    let region: PosterTitleRegion
    let aspect: CGFloat?
}

/// Reads a decoded poster once — the OCR off the main actor — and REMEMBERS it across launches.
/// A billboard holds its lockup until the reading is known (placed on a guess first, it jumped
/// to the title's real place a beat after the poster landed), so a relaunch must know at once:
/// `cached` answers synchronously for the first frame. A language tag tells us that lettering
/// exists, but not WHERE: a fixed lower-third overlay covered Percy's logo while Re:ZERO's is at
/// the top.
@MainActor
final class PosterTitleCache {
    static let shared = PosterTitleCache()
    private var analyses: [String: PosterAnalysis]
    private var inFlight: [String: Task<PosterAnalysis?, Never>] = [:]
    private static let fileURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("poster-titles.json")

    private init() {
        analyses = (try? Data(contentsOf: Self.fileURL))
            .flatMap { try? JSONDecoder().decode([String: PosterAnalysis].self, from: $0) } ?? [:]
    }

    private static func key(_ url: String, _ title: String) -> String { url + "|" + title }

    /// The remembered reading, if this poster has been read before.
    func cached(url: String?, title: String) -> PosterAnalysis? {
        guard let url else { return nil }
        return analyses[Self.key(url, title)]
    }

    /// The reading, from memory or from the picture. A failed read is retryable, so it is never
    /// remembered; the caller gets the lower-third guess for this appearance.
    func analysis(url: String?, title: String) async -> PosterAnalysis {
        let fallback = PosterAnalysis(region: .lowerTitle, aspect: nil)
        guard let url, let source = URL(string: url) else { return fallback }
        let key = Self.key(url, title)
        if let known = analyses[key] { return known }
        let task = inFlight[key] ?? Task<PosterAnalysis?, Never> {
            // 1024 px is plenty to find a title (`minimumTextHeight` is relative) and reads in
            // a fraction of the time a 2048 decode does — the billboard waits on this reading.
            guard let image = try? await ImageLoader.shared.image(for: source, maxPixel: 1024),
                  let cgImage = image.cgImage else { return nil }
            let aspect = image.size.height > 0 ? image.size.width / image.size.height : nil
            let region = await Task.detached(priority: .userInitiated) {
                PosterTitleCache.read(cgImage, title: title)
            }.value
            return region.map { PosterAnalysis(region: $0, aspect: aspect) }
        }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        guard let result else { return fallback }
        // Bounds are tiny; still keep the remembered set bounded.
        if analyses.count >= 300 { analyses.removeAll(keepingCapacity: true) }
        analyses[key] = result
        persist()
        return result
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(analyses) else { return }
        let url = Self.fileURL
        Task.detached(priority: .utility) { try? data.write(to: url, options: .atomic) }
    }

    /// The OCR itself; nil only when Vision could not run.
    nonisolated static func read(_ cgImage: CGImage, title: String) -> PosterTitleRegion? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0.02
        do { try VNImageRequestHandler(cgImage: cgImage).perform([request]) } catch { return nil }
        let lines = (request.results ?? []).compactMap { observation -> (String, CGRect)? in
            guard let text = observation.topCandidates(1).first, text.confidence >= 0.2 else { return nil }
            let box = observation.boundingBox
            let rect = CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)
            // Ignore credits and edge marks rather than treating them as the series title.
            guard rect.height >= 0.022, rect.minY >= 0.04, rect.maxY <= 0.95 else { return nil }
            return (text.string, rect)
        }
        return titleRegion(lines: lines, title: title) ?? .untitled
    }

    /// The printed title's bounds: the lines that share a word with the title, else the largest
    /// lettering (a stylised logo often reads as nothing like its name). Nil when there is no
    /// lettering at all — the picture does not carry the name.
    nonisolated static func titleRegion(lines: [(String, CGRect)], title: String) -> PosterTitleRegion? {
        let words = Set(title.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .filter { $0.count >= 3 }.map(String.init))
        let matching = lines.filter { line in
            let tokens = Set(line.0.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
            return !words.isDisjoint(with: tokens)
        }
        guard let seed = matching.max(by: { $0.1.height < $1.1.height })?.1
                ?? lines.max(by: { $0.1.height < $1.1.height })?.1 else { return nil }
        // Include adjacent lines of a graphic wordmark (Disney / Percy / Jackson / subtitle),
        // but not an unrelated quote at the opposite end of the image.
        var bounds = seed
        for _ in lines.indices {
            let old = bounds
            for (_, rect) in lines where rect.minY <= bounds.maxY + 0.045 && rect.maxY >= bounds.minY - 0.045 {
                bounds = bounds.union(rect)
            }
            if old == bounds { break }
        }
        return PosterTitleRegion(top: bounds.minY, bottom: bounds.maxY)
    }
}

/// ONE corner for every mark on a ROW (review i5, U-N16: on Search's wall Re:ZERO's check sat at
/// its foot while its neighbours' sat top-trailing). The row is the URLs of its tiles that carry a
/// mark; once `PosterCornerCache` knows every one, ALL the marks go to the foot if any one needs it.
/// Marks wait for the row's answer — never placed on a guess and then moved.
struct CornerRow: Equatable {
    let urls: [String]

    @MainActor var foot: Bool? {
        let known = PosterCornerCache.shared.known
        var any = false
        for url in urls {
            guard let answer = known[url] else { return nil }
            any = any || answer
        }
        return any
    }
}

extension EnvironmentValues {
    @Entry var cornerRow: CornerRow? = nil
}

/// Where a tile's corner mark may sit: at the art's foot when the poster letters its TOP-trailing
/// corner (Re:ZERO's title runs across its top) and not its bottom one; else top-trailing. Text
/// RECTANGLES only — detection, no recognition — on the tile's own decode, off the main actor, once
/// per URL per launch.
@MainActor
@Observable
final class PosterCornerCache {
    static let shared = PosterCornerCache()
    /// Observed: a row of marks waits on every one of its tiles' answers.
    private(set) var known: [String: Bool] = [:]
    @ObservationIgnored private var inFlight: [String: Task<Bool, Never>] = [:]

    /// A tile whose picture could not be read keeps the default corner — and says so, so its row
    /// is not left waiting.
    func settleDefault(_ url: String) {
        if known[url] == nil { known[url] = false }
    }

    func footPlacement(url: String, image: UIImage) async -> Bool {
        if let answer = known[url] { return answer }
        guard let cgImage = image.cgImage else { return false }
        let task = inFlight[url] ?? Task.detached(priority: .utility) { Self.detect(cgImage) }
        inFlight[url] = task
        let answer = await task.value
        inFlight[url] = nil
        if known.count >= 400 { known.removeAll(keepingCapacity: true) }
        known[url] = answer
        return answer
    }

    nonisolated static func detect(_ cgImage: CGImage) -> Bool {
        let request = VNDetectTextRectanglesRequest()
        do { try VNImageRequestHandler(cgImage: cgImage).perform([request]) } catch { return false }
        let boxes = (request.results ?? []).map { o in
            CGRect(x: o.boundingBox.minX, y: 1 - o.boundingBox.maxY,
                   width: o.boundingBox.width, height: o.boundingBox.height)
        }
        // The mark's own footprint in each corner (a 26-pt disc and its inset on a 100–150-pt
        // tile), not a quarter of the poster: Re:ZERO's art has text-like shapes low in its middle
        // that a wide foot zone counted as lettering, and the check sat on the "O" again.
        let top = CGRect(x: 0.7, y: 0, width: 0.3, height: 0.2)
        let foot = CGRect(x: 0.7, y: 0.8, width: 0.3, height: 0.2)
        let lettering = boxes.filter { $0.height >= 0.012 }
        return lettering.contains { $0.intersects(top) } && !lettering.contains { $0.intersects(foot) }
    }
}

/// Authored posters keep their own aspect ratio. A soft artwork wash continues behind the controls,
/// so metadata belongs to the artwork without covering a logo or introducing a black footer.
/// Where a poster tile's words go — the one switch every poster shelf reads (see
/// `ArtworkPoster.body`: BELOW the picture on the canvas since 24 Sep).
enum PosterCaption {
    enum Style { case below, centered, band }

    static var style: Style {
        #if DEBUG
        switch UserDefaults.standard.string(forKey: "posterCaption") {
        case "band": return .band
        case "centered": return .centered
        default: return .below
        }
        #else
        return .below
        #endif
    }

    static var textAlignment: TextAlignment { style == .below ? .leading : .center }
    static var alignment: HorizontalAlignment { style == .below ? .leading : .center }
    /// Under the picture on the canvas the caption is the page's type (the name in white, the fact
    /// in grey); on the legacy band it is white on the blurred plate.
    static var factInk: Color { style == .band ? ThemeColor.textPrimary : ThemeColor.textSecondary }
}

/// A tile's caption on the canvas: the show's NAME, then its one fact (grey; amber for a date that
/// is a real next step). Never truncated mid-name: two lines for the name, two for the fact.
struct PosterCaptionText: View {
    let title: String?
    let fact: String?
    var lead: Bool = false
    /// A grey head on the fact's line ("Season 3 · ") before an amber date.
    var factHead: String? = nil

    var body: some View {
        VStack(alignment: PosterCaption.alignment, spacing: 2) {
            if let title {
                Text(title)
                    .type(ThemeType.shelfTitle)
                    .foregroundStyle(ThemeColor.textPrimary)
                    .lineLimit(2)
                    .allowsTightening(true)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let fact, !fact.isEmpty {
                (Text(factHead.map { $0 + "\u{00A0}\u{00B7} " } ?? "").foregroundStyle(PosterCaption.factInk)
                 + Text(fact).foregroundStyle(lead ? ThemeColor.accent : PosterCaption.factInk))
                    .type(ThemeType.caption)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .multilineTextAlignment(PosterCaption.textAlignment)
        .frame(maxWidth: .infinity, alignment: PosterCaption.style == .below ? .leading : .center)
    }
}

struct ArtworkPoster<Details: View>: View {
    let url: String?
    var name: BillboardName = .type
    let title: String
    var detailInset: CGFloat = ThemeSpace.x4
    var showsDetails = true
    /// The details in the band UNDER the poster even when the show has a logo on the art. A shelf
    /// that put the fact on the art for one show and under the poster for the next was ragged —
    /// two caption positions and two card heights in one row (review i3, Today's Planned shelf).
    var detailsInBand = false
    /// A STATE on the art's foot ("AIRING") — the `OverArtLabel` pill with its amber dot, the
    /// streaming apps' tag on a tile. Never a fact the band already carries.
    var artLabel: String? = nil
    /// A small control or mark on the art's corner (an owned check, an add +). It sits
    /// top-trailing — unless the poster PRINTS its title in its top third (Re:ZERO), where it
    /// moves to the art's foot: pinned top-trailing, the owned disc sat on Re:ZERO's last "O"
    /// (review i4, N5). The reading is `PosterTitleCache`'s, run only for tiles that carry a mark.
    var cornerMark: AnyView? = nil
    /// A shelf that must hold ONE card height: the art drawn whole inside a fixed frame (2:3)
    /// on its own blurred ground, instead of each poster at its native aspect — AniList covers
    /// vary, and the For you shelf's tiles ended 10 pt apart (review i5, N12).
    var fixedAspect: CGFloat? = nil
    var onOpen: (() -> Void)? = nil
    /// What VoiceOver says for the open target, where the card means more than its name (For
    /// you's tile carries why it is recommended). The name otherwise.
    var openLabel: String? = nil
    var onLoaded: (() -> Void)? = nil
    @ViewBuilder var details: () -> Details

    @State private var image: UIImage?
    @State private var failed = false
    @State private var renderedWidth: CGFloat = 0
    /// Where the corner mark goes, once known (nil: not yet — the mark waits).
    @State private var markAtFoot: Bool?
    @Environment(\.cornerRow) private var cornerRow

    /// The row's answer where the tile is on one (and in it), else its own.
    private var placedAtFoot: Bool? {
        if let cornerRow, let url, cornerRow.urls.contains(url) { return cornerRow.foot }
        return markAtFoot
    }

    private var aspect: CGFloat {
        guard let image, image.size.height > 0 else { return 2 / 3 }
        return image.size.width / image.size.height
    }

    private var showsBand: Bool { showsDetails && (!name.hasGraphicLogo || detailsInBand) }

    /// How a poster tile carries its caption. BELOW (24 Sep, owner: "I just hate the way vertical
    /// posters cards look in the bottom area… implemented extremely poorly"): the poster is a
    /// clean picture — its whole art, a hairline edge, its contact shadow — and the words sit on
    /// the CANVAS under it, on the gutter's axis, as Apple TV and the App Store set them. The band
    /// it replaced was a card of muddy blurred art under a poster faded into it, each tile a
    /// different colour of mush. `-posterCaption band | centered` (DEBUG) photographs the band and
    /// a centred variant beside it.
    typealias CaptionStyle = PosterCaption.Style
    static var captionStyle: CaptionStyle { PosterCaption.style }
    static var captionAlignment: HorizontalAlignment { PosterCaption.alignment }

    private var cornerRadius: CGFloat {
        renderedWidth > 0 ? min(ThemeRadius.row, max(ThemeRadius.poster, renderedWidth * 0.1)) : ThemeRadius.poster
    }

    var body: some View {
        if Self.captionStyle == .band || !showsBand {
            bandBody
        } else {
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            VStack(alignment: Self.captionAlignment, spacing: ThemeSpace.x2) {
                artFrame(fade: false)
                    .background { ThemeColor.surfaceRaised }
                    .clipShape(shape)
                    .overlay(shape.strokeBorder(ThemeColor.posterEdge, lineWidth: 1))
                    .cardShadow(.art, shape: shape)
                details()
                    .frame(maxWidth: .infinity, alignment: Self.captionStyle == .below ? .leading : .center)
                    // The caption opens the show too — the NAME is where people tap (review i5).
                    .contentShape(Rectangle())
                    .onTapGesture { onOpen?() }
            }
            .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { renderedWidth = $0 }
            .task(id: url) { await loadAndPlaceMark() }
        }
    }

    /// The picture: the art in its frame with its tags, its open target and its corner mark.
    /// `fade` is the legacy band's 16-pt dissolve into it.
    private func artFrame(fade: Bool) -> some View {
        Color.clear
            // An aspect-ratio proposal can shrink inside a flexible vertical stack. Use
            // the card's measured width so a 250pt poster never collapses to 175pt.
            .frame(height: renderedWidth > 0 ? renderedWidth / (fixedAspect ?? aspect) : 180)
            .overlay(alignment: .top) {
                if let image {
                    // In a fixed frame the poster FILLS it (a 2:3 slot crops a 0.70 cover by a
                    // few points a side) — crisp, one height along the shelf, no letterbox.
                    Group {
                        if fixedAspect != nil {
                            Image(uiImage: image).resizable().scaledToFill()
                        } else {
                            Image(uiImage: image).resizable().scaledToFit()
                        }
                    }
                    .mask {
                        VStack(spacing: 0) {
                            Color.white
                            LinearGradient(colors: [.white, .clear],
                                           startPoint: .top, endPoint: .bottom)
                                .frame(height: fade ? 16 : 0)
                        }
                    }
                } else {
                    GradientPlaceholder()
                    if failed || url == nil {
                        Text(title)
                            .type(ThemeType.rowTitle)
                            .foregroundStyle(ThemeColor.textPrimary)
                            .multilineTextAlignment(.center)
                            .padding()
                    }
                }
            }
            .clipped()
            .accessibilityHidden(true)
            // Bottom-leading on the art; top-leading when a logo owns the art's foot (the tag
            // used to vanish from logo tiles — review i5, U-N13).
            .overlay(alignment: name.hasGraphicLogo ? .topLeading : .bottomLeading) {
                if let artLabel, image != nil {
                    OverArtLabel(text: artLabel, dot: true)
                        .padding(.leading, ThemeSpace.x2)
                        .padding(.bottom, ThemeSpace.x2)
                        .padding(.top, name.hasGraphicLogo ? ThemeSpace.x2 : 0)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .overlay {
                if let onOpen {
                    Button(action: onOpen) { Color.clear.contentShape(Rectangle()) }
                        .buttonStyle(.plain)
                        .accessibilityLabel(openLabel ?? title)
                        .accessibilityHint(Copy.Accessibility.opensTheShowHint)
                }
            }
            .overlay(alignment: placedAtFoot == true ? .bottomTrailing : .topTrailing) {
                // Only once the placement is known — never placed on a guess and then moved.
                if let cornerMark, let foot = placedAtFoot {
                    cornerMark
                        .padding(.bottom, foot && fade ? ThemeSpace.x2 : 0)
                        .transition(.opacity)
                }
            }
            .overlay(alignment: .bottom) {
                if name.hasGraphicLogo {
                    VStack(spacing: ThemeSpace.x3) {
                        ArtworkLogo(name: name, title: title)
                            .allowsHitTesting(false)
                        if showsDetails && !detailsInBand { details() }
                    }
                    .padding(.horizontal, detailInset)
                    .padding(.top, ThemeSpace.x6)
                    .padding(.bottom, ThemeSpace.x5)
                    .frame(maxWidth: .infinity)
                    .background {
                        LinearGradient(colors: [.clear, .black.opacity(0.78)],
                                       startPoint: .top, endPoint: .bottom)
                    }
                    // This decorative sibling sits ABOVE the full-poster open button.
                    // With no actual detail controls it must not swallow taps on the logo.
                    .allowsHitTesting(showsDetails && !detailsInBand)
                }
            }
    }

    /// The legacy band — and every poster with no caption (Search's wall, the first-run shelf).
    private var bandBody: some View {
        VStack(spacing: 0) {
            artFrame(fade: showsBand)

            if showsBand {
                details()
                    .padding(.horizontal, detailInset)
                    .padding(.top, ThemeSpace.x3)
                    // x3, the band's top: x4 under a one-line caption read as an empty plate (i4).
                    .padding(.bottom, ThemeSpace.x3)
                    .frame(maxWidth: .infinity)
                    // The band opens the show too — the NAME is where people tap, and it did
                    // nothing (review i5, U-N6). The art's button carries the spoken label.
                    .contentShape(Rectangle())
                    .onTapGesture { onOpen?() }
            }
        }
        .background {
            ThemeColor.surfaceRaised
            BlurredArt(url: url, sourceMaxPixel: 1200, fraction: 0.14, alignment: .bottom)
            Color.black.opacity(0.60)
        }
        // A poster's corner in proportion to the poster (tokens at the ends): 18 on a 100-pt
        // tile read as a swollen chip beside the app's other posters (review i3).
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { renderedWidth = $0 }
        .task(id: url) { await loadAndPlaceMark() }
    }

    private func loadAndPlaceMark() async {
        await load()
        guard cornerMark != nil else { return }
        // A cheap question of the picture ALREADY decoded for the tile — is there lettering
        // in the top-trailing corner? — not the billboard's full OCR: twelve accurate
        // recognitions at once starved the image pipeline and a tile's poster had not landed
        // fifteen seconds in (24 Sep).
        guard let url, let image else {
            markAtFoot = false
            if let url { PosterCornerCache.shared.settleDefault(url) }
            return
        }
        markAtFoot = await PosterCornerCache.shared.footPlacement(url: url, image: image)
    }

    private func load() async {
        image = nil
        failed = false
        guard let url, let source = URL(string: url) else { return }
        do {
            let loaded = try await ImageLoader.shared.image(for: source, maxPixel: 1200)
            guard !Task.isCancelled else { return }
            image = loaded
            onLoaded?()
        } catch {
            guard !Task.isCancelled else { return }
            failed = true
            onLoaded?()
        }
    }
}

/// Only actual catalogue artwork supplies the visible series name.
struct ArtworkLogo: View {
    let name: BillboardName
    let title: String
    var height: CGFloat = 66
    var alignment: Alignment = .center
    /// A soft halo of the logo's own light (`LogoImage.halo`) — the billboard's.
    var halo: Double = 0

    var body: some View {
        if case .logo(let logo) = name, name.hasGraphicLogo {
            LogoImage(url: logo.url, alignment: alignment, halo: halo)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: alignment)
                .frame(height: height)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(title)
                .accessibilityAddTraits(.isImage)
        }
    }
}

/// A show's logo, legible on the dark grounds this app always draws logos on (a billboard's scrim,
/// a tile's foot gradient, a scene card's shade): a DARK logo — black ink; The Eminence in Shadow's
/// only English logo is black type on nothing, and on its dark poster it was a shadow of a word
/// (26 Sep) — is drawn as a white silhouette of itself. A light or coloured logo is drawn as it is.
struct LogoImage: View {
    let url: String
    var alignment: Alignment = .center
    /// A soft halo of the logo's own light behind it (0 = none) — Home's billboard (GLOW).
    var halo: Double = 0

    @State private var image: UIImage?
    @State private var dark: Bool
    @State private var glow: LogoHalo.Glow?

    static let decodePixels: CGFloat = 800

    init(url: String, alignment: Alignment = .center, halo: Double = 0) {
        self.url = url
        self.alignment = alignment
        self.halo = halo
        // A logo decoded earlier this session is on screen from the first frame, in its final ink.
        let hit = URL(string: url).flatMap { ImageCache.shared.image(for: $0, atLeast: Self.decodePixels) }
        _image = State(initialValue: hit)
        let dark = LogoInk.known(url) ?? hit.map { LogoInk.measure(url, $0) } ?? false
        _dark = State(initialValue: dark)
        _glow = State(initialValue: halo > 0 ? LogoHalo.cached(url, dark: dark) : nil)
    }

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .renderingMode(dark ? .template : .original)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .foregroundStyle(Color.white)
                    .background {
                        if halo > 0, let glow {
                            GeometryReader { g in
                                Image(uiImage: glow.image)
                                    .resizable()
                                    .frame(width: g.size.width * glow.scale.width, height: g.size.height * glow.scale.height)
                                    .position(x: g.size.width / 2, y: g.size.height / 2)
                                    .opacity(halo)
                            }
                            .allowsHitTesting(false)
                            .transition(.opacity)
                        }
                    }
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
        .task(id: url) { await load() }
    }

    private func load() async {
        guard let address = URL(string: url) else { return }
        let picture: UIImage
        if let image {
            picture = image
        } else {
            guard let loaded = try? await ImageLoader.shared.image(for: address, maxPixel: Self.decodePixels) else { return }
            picture = loaded
        }
        let key = url
        let isDark = await Task.detached(priority: .userInitiated) { LogoInk.measure(key, picture) }.value
        dark = isDark
        if image == nil { withAnimation(ThemeMotion.uiPoster) { image = picture } }
        if halo > 0, glow == nil {
            let made = await Task.detached(priority: .utility) { LogoHalo.make(key, picture, dark: isDark) }.value
            withAnimation(ThemeMotion.uiPoster) { glow = made }
        }
    }
}

/// A logo's halo: its own light — the logo, or its white silhouette where it is drawn white —
/// blurred ONCE into a bitmap with room around it (a blur is a property of the image, never of a
/// layer: the performance rule of 5 Sep), kept beside the decodes.
enum LogoHalo {
    struct Glow {
        let image: UIImage
        /// The halo's size over the logo's: the blur's room on each side.
        let scale: CGSize
    }

    /// Room around the logo for the blur to spread into, as a share of its longer side.
    private static let room: CGFloat = 0.22

    private static func key(_ url: String, dark: Bool) -> String { "logo-halo|\(dark ? "w" : "c")|\(url)" }

    static func cached(_ url: String, dark: Bool) -> Glow? {
        guard let image = ImageCache.shared.derived(key(url, dark: dark)), let cg = image.cgImage else { return nil }
        return glow(image, cg.width, cg.height)
    }

    private static func glow(_ image: UIImage, _ width: Int, _ height: Int) -> Glow {
        // The stored bitmap is the logo plus `pad` pixels a side; `pad` follows from its size.
        let long = CGFloat(max(width, height)) / (1 + 2 * room)
        let pad = long * room
        let w = CGFloat(width) - 2 * pad, h = CGFloat(height) - 2 * pad
        return Glow(image: image, scale: CGSize(width: CGFloat(width) / max(1, w), height: CGFloat(height) / max(1, h)))
    }

    static func make(_ url: String, _ picture: UIImage, dark: Bool) -> Glow? {
        guard let cg = picture.cgImage else { return nil }
        // Small: a halo is soft by nature, and a 256-px bitmap blurs in a moment.
        let fit = min(1, 256 / CGFloat(max(cg.width, cg.height)))
        let w = max(1, Int(CGFloat(cg.width) * fit)), h = max(1, Int(CGFloat(cg.height) * fit))
        let pad = Int(CGFloat(max(w, h)) * room)
        let W = w + 2 * pad, H = h + 2 * pad
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let rect = CGRect(x: pad, y: pad, width: w, height: h)
        if dark {
            // Its white silhouette, as the logo itself is drawn.
            ctx.clip(to: rect, mask: cg)
            ctx.setFillColor(UIColor.white.cgColor)
            ctx.fill(rect)
        } else {
            ctx.draw(cg, in: rect)
        }
        guard let drawn = ctx.makeImage() else { return nil }
        let input = CIImage(cgImage: drawn)
        let blurred = input.applyingGaussianBlur(sigma: Double(max(w, h)) * 0.045).cropped(to: input.extent)
        guard let out = CIContext(options: [.useSoftwareRenderer: false]).createCGImage(blurred, from: input.extent) else { return nil }
        let image = UIImage(cgImage: out)
        ImageCache.shared.storeDerived(image, key: key(url, dark: dark))
        return glow(image, out.width, out.height)
    }
}

/// Whether a logo's ink is too dark for the dark grounds it is drawn on: less than a third of its
/// opaque pixels are LEGIBLE there — OKLab L 0.6 and up, or a saturated colour from L 0.45 (chroma
/// 0.12 and up: One Punch Man's red). Black type (The Eminence in Shadow) and Mushoku Tensei's
/// bronze lettering fail it and are drawn white; Slime's blue bubble letters — dark-outlined, but
/// mostly bright — keep their colour. Measured once per logo (a 32×32 sample), remembered.
enum LogoInk {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var answers: [String: Bool] = [:]

    static func known(_ url: String) -> Bool? { lock.withLock { answers[url] } }

    static func measure(_ url: String, _ image: UIImage) -> Bool {
        if let known = known(url) { return known }
        let dark = isDark(image)
        lock.withLock { answers[url] = dark }
        return dark
    }

    static func isDark(_ image: UIImage) -> Bool {
        guard let cg = image.cgImage else { return false }
        let w = 32, h = 32
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return false }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var bright = 0.0, n = 0.0
        for i in stride(from: 0, to: px.count, by: 4) {
            let a = Double(px[i + 3]) / 255
            guard a > 0.5 else { continue }
            // The context is premultiplied: undo it before reading the colour.
            let (l, ca, cb) = PaletteCache.oklab(r: min(1, Double(px[i]) / 255 / a),
                                                 g: min(1, Double(px[i + 1]) / 255 / a),
                                                 b: min(1, Double(px[i + 2]) / 255 / a))
            if l >= 0.6 || (l >= 0.45 && (ca * ca + cb * cb).squareRoot() >= 0.12) { bright += 1 }
            n += 1
        }
        guard n >= 8 else { return false }
        return bright / n < 0.33
    }
}

/// A real landscape always fills the card, whether or not a separate graphic logo is available.
/// The portrait panel is only a fallback for a catalogue entry with no landscape and no logo.
struct ArtworkScene: View {
    let art: WideArt
    let poster: String?
    let name: BillboardName
    let title: String

    var body: some View {
        ZStack {
            if !art.portraitSource || name.hasGraphicLogo {
                LandscapeArt(url: art.url, portraitSource: art.portraitSource,
                             maxPixel: art.ultraWide ? 1900 : 1000, ultraWide: art.ultraWide)
                LinearGradient(stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .clear, location: 0.35),
                    .init(color: .black.opacity(0.18), location: 0.6),
                    .init(color: .black.opacity(0.8), location: 1),
                ], startPoint: .top, endPoint: .bottom)
            } else if let poster {
                BlurredArt(url: poster, sourceMaxPixel: 700, fraction: 0.14)
                Color.black.opacity(0.48)
                GeometryReader { geometry in
                    HStack(spacing: 0) {
                        RemoteImageView(url: poster, contentMode: .fit, maxPixel: 700,
                                        placeholderHidden: true)
                            .frame(width: geometry.size.width * 0.42)
                        Spacer(minLength: 0)
                    }
                }
            } else {
                Text(title).type(ThemeType.rowTitle).padding()
            }
        }
        .accessibilityHidden(true)
    }
}

/// Landscape identity and actions share the lower band rather than stacking over the subject.
/// The graphic stays bottom-leading even when a watched action adds height to the facts.
struct ArtworkSceneCaption<Content: View, Actions: View>: View {
    let name: BillboardName
    let title: String
    var contentMinWidth: CGFloat = 0
    /// How hard the caption's local scrim is drawn (`HeroProtection.strength` of the scene's art):
    /// full over bright art, lighter over dark — at a fixed 0.5/0.74 it halved the luminance of
    /// every dark card's lower half for facts that measured twice the contrast they need (review
    /// i5, U-N10).
    var protection: Double = HeroProtection.full
    /// With no logo over a real landscape, the scene set the show's NAME nowhere — a result or a
    /// shelf card that could be any show (iteration 2). True sets it in type in the logo's place;
    /// a composited poster already carries its printed title, so its caller passes false.
    var typedName: Bool = false
    @ViewBuilder var content: () -> Content
    @ViewBuilder var actions: () -> Actions

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                // Stacked: the name, then the facts at the card's full width, then the action.
                // Beside the logo the facts had a sliver of the card — "Airs / Wednesday /
                // Watchi… / · Anime" one word a line over the art, "7:30 P" over "M" (review i3;
                // the 20 Sep card did the same).
                VStack(alignment: .leading, spacing: ThemeSpace.x3) {
                    logo
                    content().frame(maxWidth: .infinity, alignment: .leading)
                    // Large-text actions must not squeeze into half a landscape card.
                    actions().frame(maxWidth: .infinity)
                }
                // Its OWN scrim, measured to the stacked caption: at these sizes the caption
                // climbs to ~40 % of the card, above where the scene's gradient has any strength,
                // and "Airs Wednesday" sat on Subaru's face at 2.3:1 (review i3). Clear 28 pt above
                // the caption, to 0.8 at the card's foot.
                .background(alignment: .bottom) {
                    LinearGradient(stops: [.init(color: .black.opacity(0), location: 0),
                                           .init(color: .black.opacity(0.62), location: 0.3),
                                           .init(color: .black.opacity(0.8), location: 1)],
                                   startPoint: .top, endPoint: .bottom)
                        .padding(.top, -28)
                        .padding(.horizontal, -ThemeSpace.x4)
                        .padding(.bottom, -ThemeSpace.x4)
                        .allowsHitTesting(false)
                }
            } else {
                HStack(alignment: .bottom, spacing: ThemeSpace.x3) {
                    logo
                    // A caller's floor makes the column EXACTLY that wide — the least flexible
                    // child, so the HStack sizes it first and the logo takes what is left. As a
                    // greedy floor it lost the first split to the logo (~150 pt) and then insisted
                    // on its 196, and the row overflowed the card by ~22 pt on BOTH sides —
                    // "3LEACH", "PERC / ACKSON" (review i5, N1).
                    VStack(spacing: ThemeSpace.x3) {
                        content()
                        actions()
                    }
                    .frame(minWidth: contentMinWidth,
                           maxWidth: contentMinWidth > 0 ? contentMinWidth : .infinity)
                }
                // The default size gets its own measured scrim too: the scene's fixed gradient is
                // 0.18–0.45 where the facts sit, and "Watching · TV" over a sunset measured 1.46:1,
                // "E18 · 6:30 PM" over Emilia's hair 1.8:1 (review i4, N1). Clear 28 pt above the
                // caption, a local shade under it — the picture above stays whole.
                .background(alignment: .bottom) {
                    LinearGradient(stops: [.init(color: .black.opacity(0), location: 0),
                                           .init(color: .black.opacity(max(0.18, 0.42 * protection)), location: 0.32),
                                           .init(color: .black.opacity(max(0.36, 0.62 * protection)), location: 1)],
                                   startPoint: .top, endPoint: .bottom)
                        .padding(.top, -28)
                        .padding(.horizontal, -ThemeSpace.x4)
                        .padding(.bottom, -ThemeSpace.x4)
                        .allowsHitTesting(false)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var logo: some View {
        if name.hasGraphicLogo {
            ArtworkLogo(name: name, title: title, height: 56, alignment: .bottomLeading)
                .frame(minWidth: 0, maxWidth: 224, alignment: .leading)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        } else if typedName {
            Text(title.shelfShortened)
                .type(ThemeType.rowTitle)
                .foregroundStyle(ThemeColor.textPrimary)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
                .multilineTextAlignment(.leading)
                .shadow(.art)
                .frame(minWidth: 0, maxWidth: 224, alignment: .bottomLeading)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

/// A middot-joined fact in a narrow column: one line when it fits, else one fact per line and no
/// dots ("Season 4" over "Episode 16"). Left to wrap, the scene card printed "Season 4 ·" with
/// the dot dangling at the end of the line like a full stop (review i3).
struct SeparatedFact: View {
    let text: String
    @Environment(\.multilineTextAlignment) private var textAlignment

    /// Facts are joined " · " — or " ·\u{00A0}" where the dot must not start a line (`ReturnFact`);
    /// both are separators here (review i4, UX-N15: "Planned · Season 2 / returns late 2026" broke
    /// inside the fact because the no-break join was never split).
    private var facts: [String] {
        text.replacingOccurrences(of: " \u{00B7}\u{00A0}", with: " \u{00B7} ")
            .replacingOccurrences(of: "\u{00A0}\u{00B7} ", with: " \u{00B7} ")
            .components(separatedBy: " \u{00B7} ")
    }
    private var alignment: HorizontalAlignment {
        switch textAlignment {
        case .leading: return .leading
        case .trailing: return .trailing
        default: return .center
        }
    }

    /// Candidates, most compact first: one line; then two lines split as late as fits ("Watching
    /// · TV" over "3 seasons") — dots only BETWEEN facts on a line; then one fact per line. Every
    /// fact on its own line was the first fallback and stacked "Watching / TV / 3 seasons" over
    /// the art where two lines would do (review i3).
    var body: some View {
        let facts = self.facts
        ViewThatFits(in: .horizontal) {
            Text(text).lineLimit(1)
            if facts.count > 2 {
                ForEach(Array(stride(from: facts.count - 1, through: 1, by: -1)), id: \.self) { k in
                    VStack(alignment: alignment, spacing: 0) {
                        Text(facts[..<k].joined(separator: " \u{00B7} ")).lineLimit(1)
                        Text(facts[k...].joined(separator: " \u{00B7} ")).lineLimit(1)
                    }
                }
            }
            Text(facts.joined(separator: "\n"))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Shared landscape shelf/result composition. Metadata stays in the scene; no title caption.
struct ArtworkSceneCard<Actions: View>: View {
    let art: WideArt
    let poster: String?
    let name: BillboardName
    let title: String
    var fact: String? = nil
    var detail: String? = nil
    /// The detail is a forward-looking fact ("Sunday at 8:30 PM") — amber, the rows' grammar.
    var detailIsLead: Bool = false
    /// A forward fact UNDER the detail, in accent — "Watched" over "Returns 3 Oct" (All titles'
    /// `metaLead`, which the scene card had nowhere to draw: the soonest date was the one row in
    /// the list without one, review i4).
    var detailLead: String? = nil
    /// Drawn in the detail's place while it is set — an in-place receipt takes the card's own
    /// line rather than growing the card (Today's Up next).
    var detailReplacement: AnyView? = nil
    var progress: Double? = nil
    var aspect: CGFloat = 1.55
    /// The facts column's floor beside the logo (the Schedule card holds 164): without one a wide
    /// logo left the facts and the Add a ~90-pt sliver (review i3).
    var contentMinWidth: CGFloat = 0
    let onOpen: () -> Void
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        Color.clear.aspectRatio(aspect, contentMode: .fit)
            .overlay {
                GeometryReader { geometry in
                    ZStack(alignment: .bottom) {
                        Button(action: onOpen) {
                            ArtworkScene(art: art, poster: poster, name: name, title: title)
                        }
                        .buttonStyle(OverArtPressStyle())
                        .accessibilityLabel([title, fact, detail].compactMap { $0 }.joined(separator: ", "))
                        .accessibilityHint(Copy.Accessibility.opensTheShowHint)

                        ArtworkSceneCaption(name: name, title: title, contentMinWidth: contentMinWidth,
                                            protection: HeroProtection.strength(lightness: PaletteCache.shared.lightness(for: art.url)),
                                            typedName: !art.portraitSource) {
                            VStack(spacing: ThemeSpace.x2) {
                                if let fact {
                                    SeparatedFact(text: fact).type(ThemeType.cardFact)
                                        .foregroundStyle(ThemeColor.textPrimary)
                                        .multilineTextAlignment(.center)
                                }
                                if let detailReplacement {
                                    detailReplacement
                                } else if let detail {
                                    // White on art, like the lockup's lines on a poster: a grey
                                    // "Watching" over a sunset sky was ~2:1 (review i3). The
                                    // hierarchy is the size and weight.
                                    SeparatedFact(text: detail)
                                        .type(detailIsLead ? ThemeType.metadataEmphasis : ThemeType.metadata)
                                        .foregroundStyle(detailIsLead ? ThemeColor.accent : ThemeColor.textPrimary)
                                        .multilineTextAlignment(.center)
                                }
                                if let detailLead, detailReplacement == nil {
                                    SeparatedFact(text: detailLead)
                                        .type(ThemeType.metadataEmphasis)
                                        .foregroundStyle(ThemeColor.accent)
                                        .multilineTextAlignment(.center)
                                }
                                if let progress {
                                    // The app's one where-you-are bar, in its amber (the 20 Sep
                                    // scene card drew a white system bar).
                                    ProgressBar(value: min(1, max(0, progress)), spoken: nil)
                                }
                            }
                            // Type on a photograph carries the contact shadow the hero's lockup
                            // does: a grey "Watched" over Eren's white-blue hair all but vanished
                            // into the lightest part of the scrim (review i3).
                            .shadow(.art)
                        } actions: {
                            actions()
                        }
                        .padding(ThemeSpace.x4)
                        .padding(.leading, art.portraitSource && !name.hasGraphicLogo
                                 ? geometry.size.width * 0.38 : 0)
                        .frame(maxWidth: .infinity)
                    }
                }
            }
            .background(ThemeColor.surfaceRaised)
                .clipShape(RoundedRectangle(cornerRadius: ThemeRadius.card, style: .continuous))
    }
}

/// The action on artwork, in the app's grammar (20 Sep's white-on-black was the rejected neutral
/// style): FILLED is the amber ground with `onAccent` ink — the mark capsule's — and the quiet
/// form is glass-white on the art.
struct ArtworkActionStyle: ButtonStyle {
    var filled = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .type(ThemeType.button)
            .foregroundStyle(filled ? ThemeColor.onAccent : ThemeColor.textPrimary)
            .padding(.horizontal, ThemeSpace.x5)
            .padding(.vertical, ThemeSpace.x2)
            .frame(minHeight: 44)
            .background(filled ? AnyShapeStyle(ThemeGradient.accent) : AnyShapeStyle(Color.white.opacity(0.14)),
                        in: Capsule())
            .overlay(Capsule().strokeBorder(filled ? ThemeGradient.litEdgeStrong : ThemeGradient.litEdge, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.76 : 1)
    }
}

// A fixed-size rounded thumbnail (the legacy `Thumb`).
struct Thumb: View {
    let cover: String?
    let width: CGFloat
    let height: CGFloat
    var radius: CGFloat = 10

    var body: some View {
        // Bound the decode to the thumbnail's display size (3x = max device scale) instead of the
        // poster-grid default — a 160pt thumb needs ~480px, not 700.
        RemoteImageView(url: cover, maxPixel: max(width, height) * 3)
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .background(ThemeColor.surfaceRaised)
    }
}
