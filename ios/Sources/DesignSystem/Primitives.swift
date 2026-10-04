import SwiftUI

// Component primitives for the interaction system (spec board 10). Each has exact geometry,
// named states, and no local colour or radius values.

// MARK: - Surfaces

/// The surface hierarchy, as one decision instead of forty.
///
/// The shipped build gave every container the same treatment — `surfaceFlat` plus a 1-px
/// `stroke` — so a menu, a card, a row group and an error notice were the same object at four
/// sizes. Depth then had nowhere to go and the whole app read as a wireframe.
///
/// The rule from here: **tone separates, light describes, strokes are for things that float.**
///
/// | Level      | Fill               | Edge                  | Shadow     | Used by                              |
/// |------------|--------------------|-----------------------|------------|--------------------------------------|
/// | `.plate`   | `surfaceFlat`      | none                  | none       | grouped lists, section grounds, notices |
/// | `.raised`  | `surfaceRaised`    | top hairline          | `.card`    | a card that carries an action        |
/// | `.floating`| `surfaceFloating`  | `strokeStrong` all round | `.floating` | toast, sync banner, menu-like chrome |
/// | `.art`     | derived palette    | top hairline          | `.card`    | Focus / Recap / hero identity cards  |
///
/// Nothing else is a legal container. If a surface needs an outline to be visible, it is the wrong
/// level — move it up, do not draw a box around it.
enum SurfaceLevel: Equatable {
    /// Sits ON the canvas and holds rows. No edge at all: the fill is the whole statement.
    case plate
    /// Sits ABOVE a plate or the canvas and carries the screen's action.
    case raised
    /// Sits OVER content it must never be confused with.
    case floating
    /// Identity: the ground is derived from the artwork. `tint` is `PaletteCache`'s colour.
    case art(Color?)

    var fill: Color {
        switch self {
        case .plate: return ThemeColor.surfaceFlat
        case .raised: return ThemeColor.surfaceRaised
        case .floating: return ThemeColor.surfaceFloating
        case .art: return ThemeColor.surfaceFlat
        }
    }

    var shadow: ShadowToken {
        switch self {
        case .plate: return .none
        case .raised, .art: return .card
        case .floating: return .floating
        }
    }
}

private struct SurfaceModifier: ViewModifier {
    let level: SurfaceLevel
    let radius: CGFloat

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: radius, style: .continuous) }

    func body(content: Content) -> some View {
        content
            .background { ground }
            .clipShape(shape)
            .overlay { edge }
            .shadow(level.shadow)
    }

    /// `.plate` and `.raised` are a LIFT over whatever they sit on, not an absolute fill. Painting
    /// an opaque near-black over an ambient art wash is what turned every plate into a hole (SYS-3);
    /// white over the same ground always reads as a step up, wash or no wash.
    ///
    /// `.floating` stays opaque on purpose: it is the one level that covers content it must never
    /// be mistaken for, and a translucent toast with a shelf scrolling through it is worse than a
    /// flat one.
    @ViewBuilder
    private var ground: some View {
        switch level {
        case .art(let tint): ArtAdaptiveGround(tint: tint)
        case .plate: ThemeColor.plateLift
        case .raised: ThemeColor.raisedLift
        case .floating: level.fill
        }
    }

    /// A raised surface is lit from above, so its highlight lives on the TOP edge and dies by the
    /// vertical centre. A ring of uniform grey is the thing this replaces.
    @ViewBuilder
    private var edge: some View {
        switch level {
        case .plate:
            EmptyView()
        case .raised, .art:
            shape.strokeBorder(
                LinearGradient(colors: [.white.opacity(0.11), .clear],
                               startPoint: .top, endPoint: .center),
                lineWidth: 1
            )
            .allowsHitTesting(false)
        case .floating:
            shape.strokeBorder(ThemeColor.strokeStrong, lineWidth: 1)
                .allowsHitTesting(false)
        }
    }
}

extension View {
    /// Apply a surface level. This is the ONLY way a container gets a ground in this app.
    func surface(_ level: SurfaceLevel, radius: CGFloat = ThemeRadius.card) -> some View {
        modifier(SurfaceModifier(level: level, radius: radius))
    }

    /// The PERSISTENT ground behind a card that is being handed off to its successor.
    ///
    /// `AnyTransition.handoff` fades the outgoing card out and the incoming one in; if the ground
    /// belongs to the cards themselves, the canvas flashes through the gap between them. Put this
    /// on the container that survives the swap and the two cards trade places over one continuous
    /// surface — which is the difference between a handoff and two separate events.
    func handoffGround(tint: Color?, radius: CGFloat = ThemeRadius.focusCard) -> some View {
        background {
            ArtAdaptiveGround(tint: tint)
                .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        }
    }
}

// MARK: - Poster slot

/// Identity artwork, filling its slot.
///
/// The shipped build aspect-**fitted** every poster into a fixed 2:3 frame. AniList and TMDB
/// covers are ~0.708, so every single piece of artwork in the app carried a 5–6 pt bar of exact
/// `surfaceRaised` grey across its top and bottom — with the art's square corners sitting inside a
/// rounded frame, so dark wedges showed at all four corners too, and TMDB's true 2:3 posters
/// filled while AniList's matted, two art behaviours side by side in one grid. A 0.708 → 0.667
/// crop loses 4 % of image height and is invisible; a 6-pt grey bar is not.
///
/// The slot is the cached palette tint first (never grey), the poster cross-dissolves in over
/// 180 ms. Missing art keeps the tint with a centred `photo` symbol.
struct PosterSlot: View {
    let url: String?
    let width: CGFloat
    let height: CGFloat
    var radius: CGFloat = ThemeRadius.poster
    /// The contact shadow under the art. Defaults to the size-appropriate token — art at or above
    /// 88 pt on its long edge reads as a physical object and gets one; a 44-pt thumb does not.
    var shadow: ShadowToken

    @State private var tint: Color?

    init(url: String?, width: CGFloat, height: CGFloat,
         radius: CGFloat = ThemeRadius.poster, shadow: ShadowToken? = nil) {
        self.url = url
        self.width = width
        self.height = height
        self.radius = radius
        self.shadow = shadow ?? (max(width, height) >= 88 ? .art : .none)
    }

    /// The context form: `PosterSlot(url: cover, .row)`. Size, radius and shadow all come from the
    /// slot table so a screen never has to remember three numbers.
    init(url: String?, _ slot: PosterSize) {
        self.init(url: url, width: slot.size.width, height: slot.size.height,
                  radius: slot.radius, shadow: slot.shadow)
    }

    var body: some View {
        ZStack {
            // The ground under the art while it decodes: the show's own colour, never grey. With
            // the poster filling the slot this is only ever visible for the 180 ms before the
            // image lands, or on a title with no artwork at all.
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(ThemeColor.surfaceRaised)
            if let tint {
                // Strong enough that the letterbox band an aspect-fit leaves reads as the SHOW's
                // colour rather than as a grey mat. At 0.22 over `surfaceRaised` it was still grey.
                RoundedRectangle(cornerRadius: radius, style: .continuous).fill(tint.opacity(0.60))
            }
            if let url, !url.isEmpty {
                // `.fit`, over the show's own colour, and no blur backfill behind it. The blurred
                // second copy existed purely to disguise a grey mat — and it cost a second full
                // decode plus a blur pass on every slot ≥ 72 pt, i.e. 60 of each on a 30-title grid.
                //
                // `.fill` was the answer while the ground was grey; with the ground being the
                // artwork's own palette colour it is the wrong one. **Posters aspect-fit and stay
                // whole; backdrops fill and crop** — that is the direction's own rule, and `.fill`
                // here side-cropped every asset that is not 2:3: Wistoria's announcement lockup
                // rendered as "son 3 制作". A 0.708 cover loses 4 % of its height against the slot,
                // which lands as a 2-pt tinted band, not a grey bar.
                RemoteImageView(url: url, contentMode: .fit, maxPixel: max(width, height) * 3,
                                placeholderHidden: true,
                                // A cover that misses the slot's ratio by ≤5 % fills instead of
                                // leaving a 2-pt tinted sliver along one edge; a real mismatch
                                // (a lockup, a wide still) keeps the honest fit + palette mat.
                                fitSnapAspect: height > 0 ? width / height : nil)
                    .transition(.opacity.animation(ThemeMotion.uiPoster))
            } else {
                AppGlyph(systemName: "photo")
                    .font(.system(size: min(width, height) * 0.28, weight: .regular))
                    .foregroundStyle(ThemeColor.textTertiary)
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        // `posterEdge` (white 5 %), not `separator` (8 %): the job is to stop a dark poster
        // dissolving into a black canvas, NOT to draw a frame around every piece of artwork. The
        // shipped build's outline is visible ON the art at the top of a bright poster — a grey
        // hairline over someone's illustration is the definition of cheap.
        .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
            .strokeBorder(ThemeColor.posterEdge, lineWidth: 1))
        .cardShadow(shadow, shape: RoundedRectangle(cornerRadius: radius, style: .continuous))
        .task(id: url) {
            tint = await PaletteCache.shared.resolve(url: url, maxPixel: max(width, height) * 3)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Buttons

// MARK: Press feedback
//
// Board 11: Reduce Motion presses in OPACITY, never in scale. `CompactActionButtonStyle` was the
// only style in the shipped build that actually did it — every other style animated a raw
// `ThemeMotion.uiPress` and compressed unconditionally. This is that one pattern, written once.
private extension View {
    @ViewBuilder
    func pressFeedback(_ isPressed: Bool, reduceMotion: Bool, scale: CGFloat = 0.985) -> some View {
        self
            .opacity(reduceMotion && isPressed ? 0.72 : 1)
            .scaleEffect(reduceMotion ? 1 : (isPressed ? scale : 1))
            .animation(ThemeMotion.pick(ThemeMotion.uiPress, reduceMotion: reduceMotion),
                       value: isPressed)
    }
}

/// 48-pt capsule, the accent as a lit material, `onAccent` ink, disabled 0.38. Label comes from
/// the copy table.
///
/// It was a flat #F0A24E fill with one hairline of sheen — "an orange swatch" on a screen whose
/// one job is to be pressed (4 Oct, owner: "doesn't feel as premium"). Now it is an OBJECT: lit
/// from above (`ThemeGradient.accent`), a bright edge along its crown and a shaded one along its
/// foot, standing in a pool of its own light. Under the finger it darkens and sinks a hair. The
/// light is drawn by the capsule's own fill (`fill.shadow`), rasterised with the shape — never
/// `.shadow` on the composited label.
struct PrimaryButtonStyle2: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        configuration.label
            .type(ThemeType.button)
            .foregroundStyle(ThemeColor.onAccent)
            .frame(maxWidth: .infinity, minHeight: 48)
            .padding(.horizontal, 18)
            .background {
                Capsule().fill((pressed ? ThemeGradient.accentPressed : ThemeGradient.accent)
                    .shadow(.drop(color: ThemeColor.accent.opacity(isEnabled && !pressed ? 0.30 : 0),
                                  radius: 14, x: 0, y: 6)))
            }
            // The crown catches the light…
            .overlay(Capsule().strokeBorder(
                LinearGradient(colors: [.white.opacity(pressed ? 0.18 : 0.46), .clear],
                               startPoint: .top, endPoint: .center),
                lineWidth: 1))
            // …and the foot turns away from it.
            .overlay(Capsule().strokeBorder(
                LinearGradient(colors: [.clear, .black.opacity(0.16)],
                               startPoint: .center, endPoint: .bottom),
                lineWidth: 1))
            .opacity(isEnabled ? 1 : 0.38)
            .pressFeedback(pressed, reduceMotion: reduceMotion, scale: 0.975)
    }
}

/// 44-pt capsule on surfaceFloating with a stroke.
struct SecondaryButtonStyle2: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .type(ThemeType.button)
            .foregroundStyle(ThemeColor.textPrimary)
            .frame(maxWidth: .infinity, minHeight: 44)
            .padding(.horizontal, 18)
            // TRANSLUCENT white, not the blue-grey `surfaceFloating` (24 Sep): on a show page in
            // its own colour the opaque slab was a cold, disabled-looking button — rgb(44,46,54)
            // on Thrones' umber (critique). White at 0.13 takes whatever ground it sits on; over
            // the canvas it composites to the same depth the slab had.
            .background(ThemeColor.textPrimary.opacity(configuration.isPressed ? 0.20 : 0.13), in: Capsule())
            // `strokeBorder`, not `stroke`: a centred 1-pt line straddles the capsule's edge and
            // renders as a soft 2-px smear on the outside of the shape. A CONTROL is allowed a
            // full-perimeter edge (a container is not) — but it has to be a crisp one.
            .overlay(Capsule().strokeBorder(ThemeGradient.litEdge, lineWidth: 1))
            .pressFeedback(configuration.isPressed, reduceMotion: reduceMotion)
    }
}

/// A bare text action, 44×44 target, no container. `ThemeColor.interactive`, never amber — see
/// that token for why a tappable word may not wear the colour a next step wears.
struct TertiaryButtonStyle2: ButtonStyle {
    var destructive = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .type(ThemeType.button)
            .foregroundStyle(destructive ? ThemeColor.destructive : ThemeColor.interactive)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

/// Press feedback for content cards and rows: surface overlay only, scale never below 0.985.
///
/// `radius` must match the surface being pressed. Left at the default, a pressed 24-pt Focus card
/// paints a 16-pt highlight inside its own corners — a 4-pt sliver of un-highlighted card at each
/// corner, visible on every single tap of the app's most important control.
struct RowPressStyle: ButtonStyle {
    var radius: CGFloat = ThemeRadius.row

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(ThemeColor.surfacePressed.opacity(configuration.isPressed ? 0.6 : 0)))
            .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? 0.992 : 1))
            .animation(ThemeMotion.pick(configuration.isPressed ? ThemeMotion.uiPress : ThemeMotion.uiMicro,
                                        reduceMotion: reduceMotion),
                       value: configuration.isPressed)
    }
}

/// Press feedback for the round mark control: compression only, no rounded-rect wash behind a
/// circle. Promoted out of `ScheduleView` — the episode-row controls and the Search add badge use
/// the same shape and had no press state at all.
struct MarkPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .pressFeedback(configuration.isPressed, reduceMotion: reduceMotion)
    }
}

/// The press state for a target that IS a photograph — the Today hero, the avatar, the recap card.
///
/// Those three are the largest targets on the home screen and had no press state whatsoever
/// (`.buttonStyle(.plain)`, or an `onTapGesture` with no button trait at all). They also may not
/// take `RowPressStyle`: a `surfacePressed` wash over artwork is a grey film over someone's
/// illustration. Art dips in brightness and compresses a hair instead.
struct OverArtPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? (reduceMotion ? 0.72 : 0.88) : 1)
            .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? 0.99 : 1))
            .animation(ThemeMotion.pick(ThemeMotion.uiPress, reduceMotion: reduceMotion),
                       value: configuration.isPressed)
    }
}

/// One half of a split control: the press darkens only the half under the finger, inside the
/// shared capsule, so the boundary the divider promises is real.
struct SplitHalfStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? ThemeColor.accentPressed : Color.clear)
            .animation(ThemeMotion.pick(ThemeMotion.uiPress, reduceMotion: reduceMotion),
                       value: configuration.isPressed)
    }
}

/// An inline text action beside a label — "See all", "Clear", "Read more". `interactive` ink,
/// footnote semibold, 44-pt target held by `contentShape` rather than by a frame, so it can sit on
/// a section header's baseline without shoving the header 12 pt taller.
struct InlineLinkButtonStyle: ButtonStyle {
    var destructive = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .type(ThemeType.listAction)
            // `interactive`, not `accent`: this style draws "See all" one line above the amber
            // "Returns Oct 2" captions it links to. The link is carried by the trailing slot it
            // sits in and by its weight; amber belongs to the fact underneath.
            .foregroundStyle(destructive ? ThemeColor.destructive : ThemeColor.interactive)
            // A footnote cap-height is ~13 pt, so 12 pt of vertical padding gives a ~37–40 pt
            // target, and leading-only padding ends the hit area at the last glyph — the user has
            // to hit the WORD. Symmetric padding plus a 44-pt floor, applied before `contentShape`
            // so the shape is the padded box and not the label. Affects `See all`, `Read more`,
            // `Clear`, `Sync now` and Detail's `Details`, at every type size.
            .padding(.vertical, 14)
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.55 : 1)
            .animation(ThemeMotion.pick(ThemeMotion.uiPress, reduceMotion: reduceMotion),
                       value: configuration.isPressed)
    }
}

// MARK: - Labels

/// Eyebrow / section label: caption2 semibold, +1.0 tracking, tertiary, uppercase via textCase.
/// The optional 4-pt leading dot means "newly changed" only.
struct SectionLabel: View {
    let text: String
    var dot = false
    // `textSecondary`, one step up from the `textTertiary` it shipped at: the label is the
    // section's IDENTITY, and at tertiary it was outweighed by its own trailing "See all" — the
    // utility link read as the header and the header read as a footnote.
    var tint: Color = ThemeColor.textSecondary
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if dot { Circle().fill(ThemeColor.accent).frame(width: 4, height: 4) }
            Text(text).type(ThemeType.sectionLabel).textCase(.uppercase)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(tint)
        .lineLimit(typeSize.isAccessibilitySize ? 2 : 1)
    }
}

// MARK: - The brand lockup

/// "Previously." — the icon's ribbon, then Outfit SemiBold with the icon's coral full stop.
///
/// Hoisted out of `TodayView` (the filed shared request): Profile's colophon had drifted into a
/// second drawing, so the logo had two versions inside one app. The full stop is `brandPeriod`
/// everywhere the name is set — the launch, this header, the sign-in gate, the colophon —
/// because the icon's two objects (ribbon, coral bead) ARE the wordmark's two objects.
struct Wordmark: View {
    /// The fine-print form Profile's colophon sets: a smaller mark, secondary ink, no shadow.
    var colophon = false

    var body: some View {
        HStack(alignment: .center, spacing: colophon ? 6 : ThemeSpace.x2) {
            PreviouslyMark(width: colophon ? 17 : 22)
            BrandWord(style: ThemeType.brandWordmark,
                      ink: colophon ? ThemeColor.textSecondary : ThemeColor.textPrimary)
        }
        .shadow(colophon ? .none : .art)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Previously")
    }
}

/// The name, set in two inks: the word in `ink`, the full stop in `brandPeriod`. The stop is the
/// font's own glyph — Outfit's period is a circle, the icon's bead at text size.
struct BrandWord: View {
    var style: TypeToken = ThemeType.brandWordmark
    var ink: Color = ThemeColor.textPrimary

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text("Previously")
                .type(style)
                .foregroundStyle(ink)
            Text(".")
                .type(style)
                .foregroundStyle(ThemeColor.brandPeriod)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Previously")
    }
}

// MARK: - Grouped list

/// Inset grouped list in the system grammar: radius 16, rows 52, leading 28-pt symbol tile,
/// trailing value / chevron / toggle / check; separators inset to the title.
struct GroupedList<Content: View>: View {
    var header: String? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: ThemeMetrics.labelGap) {
            if let header {
                SectionLabel(text: header).padding(.leading, ThemeSpace.x4)
                    // VoiceOver's heading rotor is how a grouped screen is skimmed; without the
                    // trait a five-section settings page had one stop. (Profile's private
                    // `ProfileSection` existed to add exactly this — folded back here.)
                    .accessibilityAddTraits(.isHeader)
            }
            // A plate, not a stroked box: this is the iOS grouped-table grammar, and a grouped
            // table has never had an outline. The fill IS the group.
            VStack(spacing: 0) { content() }
                .surface(.plate, radius: ThemeRadius.row)
        }
    }
}

enum GroupedTrailing {
    case chevron(String?)
    case value(String)
    case toggle(Binding<Bool>)
    case check(Bool)
    case none
}

struct GroupedRow: View {
    var symbol: String? = nil
    var symbolTint: Color = Color(hex: 0x3A3D45)
    let title: String
    var subtitle: String? = nil
    var warning = false
    var trailing: GroupedTrailing = .none
    var separator = true
    var action: (() -> Void)? = nil

    var body: some View {
        // A `Toggle` inside a `Button`'s label does not survive as an independent element:
        // VoiceOver announced "Unwatched only, button" with no switch trait and no On/Off value,
        // and the outer button's hit-test priority made the switch itself unreliable to hit. The
        // toggle case therefore renders a real `Toggle` whose LABEL is the row — one element, with
        // the switch trait, a spoken value, and the whole row as its target.
        if case .toggle(let binding) = trailing {
            Toggle(isOn: binding) { labelStack }
                .toggleStyle(.switch)
                .tint(ThemeColor.accent)
                .padding(.leading, 14).padding(.trailing, 16)
                .frame(minHeight: ThemeMetrics.rowCompact)
                .overlay(alignment: .bottom) { separatorLine }
        } else {
            Button { action?() } label: {
                HStack(spacing: 12) {
                    labelStack
                    Spacer(minLength: 8)
                    trailingView
                }
                .padding(.leading, 14).padding(.trailing, 16)
                .frame(minHeight: ThemeMetrics.rowCompact)
                .contentShape(Rectangle())
                .overlay(alignment: .bottom) { separatorLine }
            }
            .buttonStyle(GroupedRowPressStyle())
            .disabled(action == nil)
        }
    }

    private var labelStack: some View {
        HStack(spacing: 12) {
            if let symbol {
                AppGlyph(systemName: symbol)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(ThemeColor.textPrimary)
                    .frame(width: 28, height: 28)
                    .background(symbolTint, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 8) {
                    Text(title).type(ThemeType.body).foregroundStyle(ThemeColor.textPrimary)
                    if warning { Circle().fill(ThemeColor.warning).frame(width: 8, height: 8) }
                }
                if let subtitle {
                    Text(subtitle).type(ThemeType.metadata).foregroundStyle(ThemeColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var separatorLine: some View {
        if separator {
            // `separatorQuiet`: eight of these down one plate at 8 % white is a grid.
            Rectangle().fill(ThemeColor.separatorQuiet).frame(height: 1)
                .padding(.leading, symbol == nil ? 14 : 54)
        }
    }

    @ViewBuilder
    private var trailingView: some View {
        switch trailing {
        case .chevron(let value):
            HStack(spacing: 6) {
                if let value { Text(value).type(ThemeType.body).foregroundStyle(ThemeColor.textTertiary) }
                AppGlyph(systemName: "chevron.forward").font(.system(size: 13, weight: .semibold)).foregroundStyle(ThemeColor.textTertiary)
            }
        case .value(let v):
            Text(v).type(ThemeType.body).foregroundStyle(ThemeColor.textTertiary)
        case .toggle:
            // Handled by the `Toggle` branch in `body` — a switch is never drawn inside a Button.
            EmptyView()
        case .check(let on):
            AppGlyph(systemName: "checkmark").font(.system(size: 15, weight: .semibold))
                .foregroundStyle(ThemeColor.accent).opacity(on ? 1 : 0).frame(width: 22)
        case .none:
            EmptyView()
        }
    }
}

struct GroupedRowPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? ThemeColor.surfacePressed : .clear)
            // The shipped style had NO animation at all: the pressed ground snapped on and off in
            // one frame, in both directions, on the densest grouped-row screens in the app.
            .animation(ThemeMotion.pick(configuration.isPressed ? ThemeMotion.uiPress : ThemeMotion.uiMicro,
                                        reduceMotion: reduceMotion),
                       value: configuration.isPressed)
    }
}

// MARK: - Media row

/// The canonical repeating row: artwork, an identity title, one fact, one optional forward-looking
/// fact in accent, and a trailing control. Library, Schedule, Search and Detail all render this
/// shape; the shipped build hand-rolled it four times at four sizes with four different poster
/// slots, which is most of why the app read as four apps.
///
/// It sits on the CANVAS with a hairline under it — not inside a stroked box. A list of shows is
/// not a form.
extension EnvironmentValues {
    /// Width a list reserves along its trailing edge for chrome that floats over it — today that is
    /// Library's A–Z index rail, which lives in the same 16-pt gutter every row ends in.
    ///
    /// Set it once on the list; every `MediaRow` inside stops short of the reserved strip. Without
    /// it a fixed trailing chevron and a rail letter can land on the same 4 pt of screen, which is
    /// what an indexed list looks like when nobody reserved the gutter (Contacts reserves it).
    @Entry var listTrailingInset: CGFloat = 0
}

struct MediaRow<Trailing: View>: View {
    let title: String
    var meta: String? = nil
    /// A forward fact appended to `meta` in accent, on the same line.
    var metaLead: String? = nil
    /// The forward-looking fact: "Returns Oct 2", "Episode 19 next". Amber, because a real next
    /// step is exactly what amber is for. Never use it for a status that has already happened.
    var lead: String? = nil
    var poster: String? = nil
    var slot: PosterSize = .row
    /// The disclosure indicator, in a FIXED trailing column.
    ///
    /// It was concatenated into the title so it would sit beside the words it belongs to. That
    /// traded one defect for a worse one: the glyph's x became a function of title length, and it
    /// was measured at 370 / 418 / 520 / 600 / 712 down a single list — five different right edges
    /// in one column of a list whose whole job is to be scanned. A disclosure indicator is chrome,
    /// and chrome holds still; the gutter between the text and it is what every iOS list has.
    var chevron: Bool = true
    var dimmed: Bool = false
    var separator: Bool = true
    /// What tapping this row does, for VoiceOver. Schedule's and Detail's rows carry one; Today's
    /// did not, so the same control was self-describing on two screens and mute on a third.
    var hint: String? = nil
    /// Registers the row's artwork as the zoom-transition source, so pushing Detail from it grows
    /// out of this poster instead of sliding in from the right.
    var zoomID: String? = nil
    /// Where you are, 0…1, drawn as a 3-pt bar under the text column — the wordless form of
    /// "11 of 24 watched". A row that carries one says in words only what is COMING.
    var progress: Double? = nil
    /// The bar's count, for VoiceOver ("11 of 24 watched"); the bar itself is silent.
    var progressSpoken: String? = nil
    @ViewBuilder var trailing: () -> Trailing
    let action: () -> Void

    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.listTrailingInset) private var trailingInset
    private var isAX: Bool { typeSize.isAccessibilitySize }
    private var minimumRowHeight: CGFloat {
        switch slot {
        case .queue, .todayQueue: ThemeMetrics.rowStandard
        default: ThemeMetrics.rowMedia
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: ThemeMetrics.artGap) {
                if poster != nil {
                    if let zoomID {
                        PosterSlot(url: poster, slot).zoomSource(zoomID)
                    } else {
                        PosterSlot(url: poster, slot)
                    }
                }
                VStack(alignment: .leading, spacing: ThemeMetrics.titleGap) {
                    titleText
                        .lineLimit(isAX ? nil : 2)
                        .fixedSize(horizontal: false, vertical: true)
                    if let lead {
                        Text(lead)
                            .type(ThemeType.rowMetaLead)
                            .foregroundStyle(ThemeColor.accent)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let meta {
                        // `metaLead`: a forward fact riding the grey line in accent, one line.
                        (Text(meta).foregroundStyle(ThemeColor.textSecondary)
                         // The separator binds to the fact it introduces (no dangling "Planned ·").
                         + (metaLead.map { Text(" \u{00B7}\u{00A0}").foregroundStyle(ThemeColor.textSecondary) + Text($0).foregroundStyle(ThemeColor.accent) } ?? Text("")))
                            .type(ThemeType.rowMeta)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let progress {
                        ProgressBar(value: progress)
                            .padding(.top, ThemeSpace.x1)
                            .padding(.trailing, ThemeSpace.x6)
                    }
                }
                Spacer(minLength: ThemeSpace.x3)
                trailing()
                if chevron {
                    AppGlyph(systemName: "chevron.forward")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(ThemeColor.textDisabled)
                        // A fixed column, so every chevron in a list shares one x.
                        .frame(width: 11, alignment: .trailing)
                        .accessibilityHidden(true)
                }
            }
            .padding(.trailing, trailingInset)
            .padding(.vertical, ThemeSpace.x2)
            // Catalogue rows keep the heavier height. Purpose-built compact slots preserve the
            // same 44-pt controls inside a denser reading rhythm.
            .frame(minHeight: minimumRowHeight, alignment: .leading)
            .contentShape(Rectangle())
            // Past / already-handled rows recede as a GROUP rather than each element being given
            // its own grey — one opacity keeps the artwork's colour relationship intact.
            //
            // 0.45 was not "recessed", it was unreadable: `textSecondary` at 0.45 over the canvas
            // composites to ≈#515151, i.e. 2.64:1, and it was applied to exactly the rows being
            // scanned for a date (Schedule's past week, Detail's unaired episodes). 0.72 lands at
            // ≈5.4:1 and still reads as a group that has stepped back.
            .opacity(dimmed ? 0.72 : 1)
            .overlay(alignment: .bottom) {
                if separator {
                    Rectangle().fill(ThemeColor.separatorQuiet)
                        .frame(height: 1)
                        .padding(.leading, poster == nil ? 0 : slot.size.width + ThemeMetrics.artGap)
                }
            }
        }
        .buttonStyle(RowPressStyle())
        .accessibilityElement(children: .combine)
        // Spelled out rather than left to `.combine`, so the trailing chevron is never spoken.
        .accessibilityLabel([title, lead, meta, progress == nil ? nil : progressSpoken]
            .compactMap { $0 }.joined(separator: ", "))
        .accessibilityHint(hint ?? "")
    }

    private var titleText: Text {
        Text(title)
            .type(ThemeType.rowTitle)
            .foregroundStyle(ThemeColor.textPrimary)
    }
}

extension MediaRow where Trailing == EmptyView {
    init(title: String, meta: String? = nil, metaLead: String? = nil, lead: String? = nil, poster: String? = nil,
         slot: PosterSize = .row, chevron: Bool = true, dimmed: Bool = false,
         separator: Bool = true, hint: String? = nil, zoomID: String? = nil,
         progress: Double? = nil, action: @escaping () -> Void) {
        self.init(title: title, meta: meta, metaLead: metaLead, lead: lead, poster: poster, slot: slot,
                  chevron: chevron, dimmed: dimmed, separator: separator, hint: hint,
                  zoomID: zoomID, progress: progress, trailing: { EmptyView() }, action: action)
    }
}

/// The one progress bar: a 3-pt track in `strokeStrong`, the watched share in accent, a 3-pt
/// minimum so a started season is never a zero-width fill. Wordless on purpose — it replaces
/// "11 of 24 watched" wherever a row or header can show it instead of saying it. Callers carry
/// the count in their accessibility label.
struct ProgressBar: View {
    let value: Double
    /// What VoiceOver reads for the bar ("4 episodes behind"). Without it the bar is decoration
    /// and hidden; a label set on a hidden element from outside was silently dropped, which is
    /// how Today's hero came to say its count to nobody.
    var spoken: String? = nil
    /// Laid on ARTWORK (a billboard's lockup): white on a white track, the way every streaming
    /// app draws progress over a picture — amber stays the action's there.
    var onArt: Bool = false

    var body: some View {
        GeometryReader { proxy in
            let ratio = min(1, max(0, value))
            ZStack(alignment: .leading) {
                Capsule().fill(onArt ? ThemeColor.textPrimary.opacity(0.22) : ThemeColor.strokeStrong)
                Capsule().fill(onArt ? AnyShapeStyle(ThemeColor.textPrimary.opacity(0.92))
                                     : AnyShapeStyle(ThemeGradient.accentBar))
                    .frame(width: max(3, proxy.size.width * ratio))
            }
        }
        .frame(height: 3)
        .accessibilityHidden(spoken == nil)
        .accessibilityLabel(spoken ?? "")
    }
}

// MARK: - Shelf card

/// One poster on a horizontal shelf. Two things the shipped build got wrong and this fixes:
/// the caption block reserves **two lines whether or not the title needs them**, so a shelf of
/// mixed-length titles keeps one baseline instead of a staircase; and the forward-looking caption
/// is allowed to be accent, because "Returns Oct 2" is the reason the shelf exists.
struct ShelfCard: View {
    let title: String
    /// A GRID reserves two title lines so every row shares one caption baseline (review,
    /// 5 Sep: Search's 3-up grid zigzagged, one card's meta line 26 px above its neighbours');
    /// a SHELF keeps the caption directly under a one-line name (user, 24 Aug).
    var reserveTitleLines: Bool = false
    var caption: String? = nil
    var captionIsLead: Bool = false
    /// The show has a season ON AIR. Drawn as a `LiveDot` before the caption — the cue a
    /// poster alone cannot give ("no visual cue to clarify a series has a current airing
    /// season", user, 6 Sep). Colour states it; the beat only draws the eye to it.
    var airing: Bool = false
    /// An episode of that season is out now and unwatched — the dot takes the finite beat.
    var airingFresh: Bool = false
    var poster: String? = nil
    var slot: PosterSize = .shelfLarge
    /// Zoom-transition source id for the push into Detail.
    var zoomID: String? = nil
    let action: () -> Void

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: ThemeSpace.x2) {
                if let zoomID {
                    PosterSlot(url: poster, slot).zoomSource(zoomID)
                } else {
                    PosterSlot(url: poster, slot)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title.shelfShortened(fitting: reserveTitleLines ? 26 : 24))
                        .type(ThemeType.shelfTitle)
                        .foregroundStyle(ThemeColor.textPrimary)
                        // NOTHING reserved: the caption sits directly under the title, one line
                        // or two. Reserving a second line put an empty band between every
                        // one-line name and its date (user, 24 Aug); a two-line name simply
                        // carries its caption one line lower. Never truncated (DIRECTION §3).
                        // A third line costs 16 pt and is the only honest answer for a name
                        // with no separator (review i3).
                        .lineLimit(typeSize.isAccessibilitySize ? 1...6 : (reserveTitleLines ? 2...3 : 1...3))
                        .minimumScaleFactor(0.8)
                        .allowsTightening(true)
                        .multilineTextAlignment(.leading)
                        // The title takes its WRAPPED height, whatever the shelf proposes. On
                        // Today's Watching shelf a two-line name was photographed scaled down and
                        // cut to one line with an ellipsis ("The Beginning After…", 2 Sep) — the
                        // horizontal scroller had handed the card a one-line height budget and
                        // the range limit obeyed it. The rule is the identity title never
                        // ellipsizes; a fixed vertical size is what makes the range mean "up to
                        // two" rather than "whatever fits".
                        .fixedSize(horizontal: false, vertical: true)
                    // In a GRID the row gives every card the tallest card's height; the spacer
                    // takes the difference, so every caption in the row sits on one line under
                    // the tallest title — a third title line used to push only its own caption
                    // 16 pt down (review, 23 Sep).
                    if reserveTitleLines { Spacer(minLength: 0) }
                    if let caption {
                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                            if airing { LiveDot(fresh: airingFresh) }
                            Text(caption)
                            .type(ThemeType.shelfCaption)
                            .foregroundStyle(captionIsLead ? ThemeColor.accent : ThemeColor.textSecondary)
                            // ONE line (review i2: "3 episodes / behind" on a 100-pt card grew
                            // the card four rows tall with "behind" orphaned): a caption
                            // compresses a step before it wraps.
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .allowsTightening(true)
                            .truncationMode(.tail)
                        }
                        // Its own height, always: in Search's grid a three-line title's card was
                        // squeezed and the caption took the squeeze through its scale floor —
                        // "Anime · 2026" a size smaller than its neighbours' (review, 23 Sep). The
                        // scale floor is for WIDTH only.
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                // The poster's width, at every size: every ShelfCard now sits in a horizontal
                // shelf (grids fold to rows at the accessibility sizes), and an unfixed width
                // spread Today's AX shelf 88 pt apart, each card as wide as its unwrapped title
                // (review, 23 Sep). The title wraps inside the poster's width instead.
                .frame(width: slot.size.width, alignment: .leading)
            }
            .frame(maxHeight: reserveTitleLines ? .infinity : nil, alignment: .top)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowPressStyle(radius: slot.radius))
        .accessibilityElement(children: .combine)
        // The spoken title is the WHOLE title, never the shortened one.
        .accessibilityLabel([title, caption].compactMap { $0 }.joined(separator: ", "))
    }
}

extension String {
    /// Identity titles as a shelf caption can carry them.
    ///
    /// Source titles arrive wrapped in subtitle punctuation — "Re:ZERO -Starting Life in Another
    /// World-" — and a line that opens on a hyphen reads as a hyphenation bug, not as a title.
    /// Stripping the dashes is lossless; what follows the em/en dash or the colon is a subtitle the
    /// shelf never had room for anyway.
    var shelfShortened: String {
        var s = trimmingCharacters(in: .whitespacesAndNewlines)
        // A trailing "-…-" subtitle wrapper.
        if s.hasSuffix("-"), let open = s.range(of: " -") {
            s = String(s[s.startIndex..<open.lowerBound])
        }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: " -\u{2013}\u{2014}:"))
        // A long "Title: Subtitle" keeps its identity half rather than an ellipsis mid-word.
        return s.shortened(fitting: 40, minHead: 12)
    }

    /// The identity half of a "Title: Subtitle" when the whole exceeds `budget` characters and
    /// the head is at least `minHead` long — a shelf passes 24, a grid 26, the lane 30 (review
    /// i3: "Bleach: Thousand-Year Blood War" wrapped and "HELL MODE: The Hardcore Gamer Do…" cut
    /// mid-word under the 40-character gate).
    func shelfShortened(fitting budget: Int, minHead: Int = 5) -> String {
        shelfShortened.shortened(fitting: budget, minHead: minHead)
    }

    private func shortened(fitting budget: Int, minHead: Int) -> String {
        guard count > budget else { return self }
        for sep in [": ", " – ", " — ", " - ", " ("] {
            if let r = range(of: sep), distance(from: startIndex, to: r.lowerBound) >= minHead {
                return String(self[startIndex..<r.lowerBound])
            }
        }
        return self
    }
}

// MARK: - Banner card

/// A wide art card that sells a show: banner art on top, the title and one caption beneath.
///
/// This object existed three times before the cohesion pass (30 Aug) — Library's shelf card
/// (104 pt, radius 13), Library's status feature card (176 pt, radius 18) and Search's browse tile
/// (radius 22) — three geometries and three title treatments for one job, two of the radii in no
/// token table. The radius is `ThemeRadius.card` (Search's tile already used it, and keeps its
/// title-on-art anatomy for the browse grid); the two below-the-art variants are one component now.
///
/// The caption rule is `ShelfCard`'s, enforced here so a screen cannot opt out of it again: a
/// forward-looking fact ("Returns today") is accent, a plain fact is grey. Library hard-coded grey
/// and rendered the identical class of fact Today draws amber — the app's central colour rule
/// answered two ways one tab apart.
struct BannerCard: View {
    /// One geometry. A `.feature` variant (176 pt) existed for the status tabs' lead card and
    /// died with them (30 Aug).
    static let height: CGFloat = 104
    /// Banner decode budget at the width the card actually renders.
    private static let maxPixel: CGFloat = 560

    let title: String
    /// The forward-looking fact, in accent — same contract as `MediaRow.lead`.
    var lead: String? = nil
    var meta: String? = nil
    var art: String? = nil
    /// `art` is a portrait COVER (the catalogue has no banner). Composited whole rather than
    /// cropped to a horizontal slice of itself — see `LandscapeArt`.
    var portraitSource: Bool = false
    /// See `LandscapeArt.ultraWide`.
    var ultraWide: Bool = false
    var zoomID: String? = nil
    let action: () -> Void

    private var caption: String? { lead ?? meta }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: ThemeSpace.x2) {
                banner
                VStack(alignment: .leading, spacing: ThemeSpace.x0_5) {
                    Text(title.shelfShortened)
                        .type(ThemeType.shelfTitle)
                        .foregroundStyle(ThemeColor.textPrimary)
                        // Never truncated (DIRECTION §3) — the compact card shipped `lineLimit(1)`
                        // and amputated the identity titles the rule exists for.
                        .lineLimit(1...2)
                        .minimumScaleFactor(0.82)
                        .allowsTightening(true)
                        .multilineTextAlignment(.leading)
                    if let caption {
                        Text(caption)
                            .type(ThemeType.shelfCaption)
                            .foregroundStyle(lead != nil ? ThemeColor.accent : ThemeColor.textSecondary)
                            .lineLimit(2)
                            .truncationMode(.tail)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(OverArtPressStyle())
        .accessibilityElement(children: .combine)
        // The spoken title is the WHOLE title, never the shortened one.
        .accessibilityLabel([title, caption].compactMap { $0 }.joined(separator: ", "))
        .accessibilityHint(Copy.Accessibility.opensTheShowHint)
    }

    private var banner: some View {
        let shape = RoundedRectangle(cornerRadius: ThemeRadius.card, style: .continuous)
        return ZStack {
            shape.fill(ThemeColor.surfaceRaised)
            LandscapeArt(url: art, portraitSource: portraitSource, maxPixel: BannerCard.maxPixel,
                         ultraWide: ultraWide)
        }
        .frame(maxWidth: .infinity)
        .frame(height: BannerCard.height)
        .clipShape(shape)
        .overlay(shape.strokeBorder(ThemeColor.posterEdge, lineWidth: 1))
        .cardShadow(.art, shape: shape)
        .modifier(OptionalZoomSource(id: zoomID))
    }
}

/// `zoomSource` with an optional id, so a card can be composed once whether or not its screen
/// registers it as a transition source.
private struct OptionalZoomSource: ViewModifier {
    let id: String?
    func body(content: Content) -> some View {
        if let id { content.zoomSource(id) } else { content }
    }
}

extension View {
    /// The horizontal-shelf scroller: art may run off the trailing edge, TYPE may not.
    ///
    /// Every shelf's last card had its title and caption sliced mid-glyph by the hard screen edge
    /// with no fade and no content margin ("Solo L", "Return…", "HELL… / Hardc…"). Apple's shelves
    /// clip *artwork* at the viewport and never leave a title amputated. The trailing margin means
    /// a partial card always shows a poster rather than a fragment of a word, and the mask fades
    /// what does reach the edge. At accessibility sizes the shelf is already a vertical list, so
    /// the mask is skipped.
    /// `trailingMargin` 40, not 28: at 28 the peeking card's caption still reached the bezel and
    /// sheared mid-word ("Avatar:", "Caught u", "So", "Re") because the fade only covered the last
    /// 7 % (~30 pt) of the viewport. 40 pt of margin plus a 14 % fade means a partial card always
    /// shows artwork and its type has dissolved before the edge — verified against the longest
    /// caption in the app, "No date announced".
    func shelfScroller(trailingMargin: CGFloat = 40, masked: Bool = true) -> some View {
        modifier(ShelfScroller(trailingMargin: trailingMargin, masked: masked))
    }
}

private struct ShelfScroller: ViewModifier {
    let trailingMargin: CGFloat
    let masked: Bool

    @Environment(\.dynamicTypeSize) private var typeSize

    func body(content: Content) -> some View {
        let fade = masked && !typeSize.isAccessibilitySize && !PerfProbe.flag("perfNoShelfMask")
        return content
            .contentMargins(.trailing, trailingMargin, for: .scrollContent)
            .mask {
                Group {
                    if fade {
                        LinearGradient(stops: [
                            .init(color: .black, location: 0),
                            .init(color: .black, location: 0.86),
                            .init(color: .black.opacity(0.45), location: 0.95),
                            .init(color: .black.opacity(0), location: 1),
                        ], startPoint: .leading, endPoint: .trailing)
                    } else {
                        Rectangle()
                    }
                }
                // Vertically oversized on purpose. A mask is clipped to its own bounds, so a mask
                // exactly the scroller's height would undo `.scrollClipDisabled()` and shear the
                // posters' `.art` shadow into a hard line along each card's edge — trading one
                // clipping artefact for another.
                .padding(.vertical, -24)
            }
    }
}

// MARK: - Recap strip

// MARK: - Toast

/// The canonical toast: a content-width glass **capsule**, centred over the tab bar's own margin.
///
/// The shipped shape — a full-width rounded rectangle with a 1-px perimeter stroke and a trailing
/// amber "Undo" — is an Android Material snackbar in shape, position and construction, and it put
/// a second amber object beside the amber CTA it had just been used to confirm. A capsule that
/// hugs its own text is the iOS grammar (the AirPods / silent-switch HUDs, the Photos "Copied"
/// pill), and hugging means it stops spanning the screen over content the user is reading.
struct ToastView: View {
    let message: String
    var actionLabel: String? = nil
    var failure = false
    var action: (() -> Void)? = nil

    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: ThemeSpace.x3) {
            if failure {
                AppGlyph(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(ThemeColor.warning)
            }
            Text(message)
                .type(ThemeType.metadataEmphasis)
                .foregroundStyle(ThemeColor.textPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            if let actionLabel, let action {
                // Not accent: the mark this toast is confirming was committed by an amber control,
                // and a second amber word 6 pt away competes with it. Weight carries the action.
                Button(actionLabel, action: action)
                    .buttonStyle(ToastActionStyle())
            }
        }
        .padding(.leading, ThemeSpace.x4)
        .padding(.trailing, actionLabel == nil ? ThemeSpace.x4 : ThemeSpace.x1)
        .frame(minHeight: 48)
        // Hugs its content — but never past the screen, and never at accessibility sizes where the
        // message legitimately needs the width.
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: 420)
        .chromeGlass(in: Capsule())
        .shadow(.floating)
        // The toast owns its own timing. Its host used to declare three `uiSnappy` animations and
        // the toast a bare `.opacity`, so it arrived and LEFT on the same spring — a bounce out,
        // not a dismissal.
        .transition(.toast(reduceMotion: reduceMotion))
    }
}

/// The toast's own action. A 44-pt target inside a 48-pt capsule, no container of its own.
private struct ToastActionStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .type(ThemeType.metadataEmphasis)
            .foregroundStyle(ThemeColor.textPrimary)
            .padding(.horizontal, ThemeSpace.x4)
            .frame(minHeight: 44)
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.55 : 1)
            .animation(ThemeMotion.pick(ThemeMotion.uiPress, reduceMotion: reduceMotion),
                       value: configuration.isPressed)
    }
}

// MARK: - Scroll offset

/// A screen's scroll offset, as an object rather than view state.
///
/// `set` clamps and de-duplicates (`ThemeMetrics.scrollSample`), so nothing publishes once the
/// chrome has settled; and because only the small views that draw the veils (and stretch a
/// hero) read `y` inside their bodies, a scroll frame invalidates those views alone. As `@State`
/// on the screen it re-ran the screen's whole body — Today's stack, queue, shelf and every row —
/// on every frame of the first swipe (user, 2 Sep, twice).
@Observable @MainActor
final class ScrollOffset {
    private(set) var y: CGFloat = 0

    /// Today's docking facts (5 Sep, "halfway through it just halts"): the hero copy is passing
    /// under the wordmark band; the lockup has cleared the bar's ramp. As `@State` on the screen
    /// each flip re-ran Today's whole body at the one moment the veils and the header were also
    /// changing; here only the two small views that draw them observe them.
    private(set) var heroCopyUnderBand = false
    private(set) var heroUnderBand = false

    func setCopyUnderBand(_ v: Bool) { if v != heroCopyUnderBand { heroCopyUnderBand = v } }
    func setHeroUnderBand(_ v: Bool) { if v != heroUnderBand { heroUnderBand = v } }

    /// Past this the offset changes nothing on screen (`ThemeMetrics.scrollSample`). A screen
    /// whose wash TRAVELS with the content (Profile) raises it to the wash's own height.
    var ceiling: CGFloat = 240

    func set(_ raw: CGFloat) {
        let v = ThemeMetrics.scrollSample(raw, ceiling: ceiling)
        if v != y { y = v }
    }

    /// 0 while a hero owns the status bar, 1 once anything is close enough to touch the clock.
    var veilOpacity: Double { Double(min(1, max(0, (y - 16) / 64))) }
    /// The pull-down, as extra art height.
    var stretch: CGFloat { max(0, -y) }
}

// MARK: - Chrome edges

/// The scroll edge.
///
/// The single most damaging detail in the shipped build is invisible in a design tool and obvious
/// on a device: **content scrolls straight through the status bar**. On Schedule a poster and a
/// truncated show title sit on top of the clock; on Library a poster crosses the Dynamic Island.
/// No shipping media app does this, and no amount of card polish survives it.
///
/// The fix is one veil per root screen: full canvas through the status-bar band, gone 22 pt below
/// it. Content does not slide under a grey bar — it dissolves into the app. `.ultraThinMaterial`
/// rides along, masked to the same band, so what is dissolving also softens; under Reduce
/// Transparency the material is dropped and the canvas veil does the whole job.
///
/// The top edge only: the BOTTOM of every screen is the app's own opaque bar (`AppTabBar`, 25 Sep),
/// a safe-area inset that content stops above and never passes under — there is no bottom edge
/// left to veil. (The bottom band, its 64-pt ramp and its 180-pt underfill were the ground the
/// system's glass tab bar needed; they went with it.)
struct ScrollEdgeChrome: View {
    /// Total height, safe area included.
    var height: CGFloat = ThemeMetrics.topChromeHeight
    /// NO solid hold over the status bar — the art runs to the top edge of the screen
    /// under a gradient that only softens it (Apple Music's Search, the user's reference). The
    /// default keeps the opaque status-bar band for screens whose rows pass under the clock.
    var soft = false
    /// How far down the full-canvas hold reaches before the ramp starts. Defaults to the
    /// status bar. Detail's floating toolbar passes the toolbar's own bottom edge — this parameter
    /// is what `FloatingToolbarVeil` existed to change, and that private copy folded into it.
    var holdHeight: CGFloat? = nil
    /// The bar's ink, when it is not the canvas — a show page passes its art colour
    /// (`DetailTint.chrome`) so the hardened bar is the show's own glass, not a black slab over
    /// the picture ("too blackish anyway, should be glassish", user, 4 Sep). Ignored under Reduce
    /// Transparency, where there is no blur for a colour to be glass over.
    var color: Color? = nil

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    /// What the top veil is painted with.
    private var ink: Color { (reduceTransparency ? nil : color) ?? ThemeColor.chromeVeil }

    private var hold: CGFloat {
        max(0, min(1, (holdHeight ?? ThemeMetrics.topSafeInset) / max(height, 1)))
    }

    /// Canvas opacity from the screen edge inward: the BAR's canvas (`ThemeMetrics.chromeBarOpacity`,
    /// over a full-strength blur) across the whole hold, then a fast fall-off.
    ///
    /// Under Reduce Transparency there is no blur to carry the bar, so it is opaque there — a
    /// 74 % veil with nothing softening what is under it is the half-lit row under "Library"
    /// that the hardened bar was built to end.
    private var veil: LinearGradient {
        if soft {
            return LinearGradient(stops: [
                .init(color: ThemeColor.chromeVeil.opacity(0.55), location: 0),
                .init(color: ThemeColor.chromeVeil.opacity(0.30), location: 0.5),
                .init(color: ThemeColor.chromeVeil.opacity(0), location: 1),
            ], startPoint: .top, endPoint: .bottom)
        }
        let bar = reduceTransparency ? 1
            : (color != nil ? ThemeMetrics.chromeBarTintedOpacity : ThemeMetrics.chromeBarOpacity)
        return LinearGradient(stops: [
            .init(color: ink.opacity(bar), location: 0),
            .init(color: ink.opacity(bar), location: hold),
            .init(color: ink.opacity(bar * 0.45), location: hold + (1 - hold) * 0.45),
            .init(color: ink.opacity(0), location: 1),
        ], startPoint: .top, endPoint: .bottom)
    }

    /// The blur runs out on exactly the same ramp as the veil, and reaches zero at the same
    /// place. A mask that terminates while the veil is still at a third leaves a visible seam
    /// straight across the screen — which is precisely what a hand-rolled scroll edge looks like.
    private var blurMask: LinearGradient {
        if soft {
            return LinearGradient(stops: [
                .init(color: .black.opacity(0.6), location: 0),
                .init(color: .black.opacity(0.3), location: 0.5),
                .init(color: .clear, location: 1),
            ], startPoint: .top, endPoint: .bottom)
        }
        // Full strength through the WHOLE hold: the bar is translucent now, so the blur is
        // what keeps a row title under it from reading as a row title.
        return LinearGradient(stops: [
            .init(color: .black, location: 0),
            .init(color: .black, location: hold),
            .init(color: .black.opacity(0.42), location: hold + (1 - hold) * 0.45),
            .init(color: .clear, location: 1),
        ], startPoint: .top, endPoint: .bottom)
    }

    private var band: some View {
        ZStack {
            if !reduceTransparency && !PerfProbe.flag("perfNoMaterial") {
                Rectangle().fill(.ultraThinMaterial).mask(blurMask)
            }
            veil
        }
    }

    var body: some View {
        band
            .frame(height: height)
            .frame(maxWidth: .infinity)
            .ignoresSafeArea(edges: .top)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

private struct TabBarReserve: ViewModifier {
    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom, spacing: 0) {
            Color.clear
                .frame(height: KeyboardPresence.shared.covering ? 0 : AppTabBar.reservedHeight)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

/// Reads the accessibility environment so `chromeGlass` can branch on it.
struct ChromeGlassBox<S: Shape, Content: View>: View {
    let shape: S
    let interactive: Bool
    @ViewBuilder var content: () -> Content

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        if reduceTransparency {
            content()
                .background(ThemeColor.surfaceFloating, in: shape)
                .overlay(shape.stroke(ThemeColor.strokeStrong, lineWidth: 1))
        } else {
            content().glassChrome(in: shape, interactive: interactive)
        }
    }
}

extension View {
    /// Today's bar on a root (25 Sep: "remove the header gradient from every other screen (except
    /// details) to remain visually consistent with today", owner): the canvas itself from the
    /// screen's top edge down to the bar's bottom (`hold`: status band + title bar, plus a search
    /// drawer where there is one) — flush with the page, no wash under it, no ramp out of it, no
    /// material in it. Content scrolls under it and is simply gone, as it is under the feed's
    /// header. The show page keeps its tinted glass.
    func flushTopBar(_ hold: CGFloat) -> some View {
        overlay(alignment: .top) {
            ThemeColor.canvas
                .frame(height: hold)
                .frame(maxWidth: .infinity)
                .ignoresSafeArea(edges: .top)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    /// The breathing room under a scroll view's last row (`ThemeMetrics.tabBarClearance`), as a
    /// scroll-content MARGIN — padding inside a stack shorter than the viewport changes no layout
    /// at all, and a margin is also where the scroll indicator stops.
    ///
    /// It is not a clearance for the bar any more: the bar (`AppTabBar`) is a safe-area inset, so
    /// every scroll view already ends above it.
    ///
    /// Applied to the *scroll view* (or any ancestor of it), never inside the stack.
    func tabBarContentMargin(extra: CGFloat = 0) -> some View {
        contentMargins(.bottom, ThemeMetrics.tabBarClearance + extra, for: .scrollContent)
    }

    /// The scaffold of a PUSHED screen: the same breathing room under its last row as a root's,
    /// room for the app's bar at its foot, and the system tab bar held hidden, so no push can
    /// bring its pill back over the app's bar. Lives on the navigation destinations
    /// (`RootView.detailDestinations`), so every future push inherits it.
    func pushedScreenChrome() -> some View {
        contentMargins(.bottom, ThemeMetrics.tabBarClearance, for: .scrollContent)
            .tabBarReserve()
            .systemTabBarHidden()
    }

    /// Room for the app's bar at the foot of a page (`AppTabBar`, drawn once over the tabs): an
    /// empty safe-area inset of the bar's height, so the page's content — and its own bottom
    /// bars, like the post page's reply field — end above the bar instead of under it. It folds
    /// to nothing while the keyboard covers the bar, so a reply field sits on the keyboard, not a
    /// bar's height above it. Every tab root carries it (`MainTabView`) and every push
    /// (`pushedScreenChrome`); a sheet or a cover has no bar and no reserve.
    func tabBarReserve() -> some View {
        modifier(TabBarReserve())
            .chromeScrollEdgeHidden(.bottom)
            .modifier(TabBarGroundReporter())
    }

    /// Native Liquid Glass for chrome, with the Reduce Transparency fallback the spec requires
    /// (`surfaceFloating` + `strokeStrong`, no refraction). `glassChrome` alone keeps refracting
    /// when the user has asked it not to.
    func chromeGlass(in shape: some Shape, interactive: Bool = false) -> some View {
        ChromeGlassBox(shape: shape, interactive: interactive) { self }
    }
}

// MARK: - Full-bleed art

/// The vertical scrim over full-bleed artwork: it protects the status bar at the top and hands the
/// image over to the canvas at the bottom, in one gradient with a transparent middle so the art is
/// never uniformly greyed.
///
/// The shipped build has no full-bleed art anywhere, which is why it lost the atmosphere the
/// original had. Anything that puts art behind text uses this — nobody hand-rolls a black overlay.
struct ArtScrim: View {
    /// Protection at the top, for the status bar and any floating toolbar.
    var top: Double = 1
    /// The handover to the canvas at the bottom.
    var bottom: Double = 1

    var body: some View {
        LinearGradient(stops: [
            .init(color: .black.opacity(0.55 * top), location: 0.00),
            .init(color: .black.opacity(0.16 * top), location: 0.22),
            .init(color: .clear, location: 0.46),
            .init(color: ThemeColor.canvas.opacity(0.55 * bottom), location: 0.80),
            .init(color: ThemeColor.canvas.opacity(1.00 * bottom), location: 1.00),
        ], startPoint: .top, endPoint: .bottom)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// How hard a billboard's protection is drawn, from the art's own mean lightness
/// (`PaletteCache.lightness(for:)`): full over a bright cover, half over a dark one. A veil and
/// a scrim tuned for the palest poster buried the dark ones ("the overlay on hero is too dark
/// as the new images are themselves dark", user, 5 Sep) — a dark picture needs less taking
/// away from it for the type to read, and every tenth of veil over it is atmosphere lost.
enum HeroProtection {
    static let full: Double = 1
    static let least: Double = 0.35

    /// OKLab compresses the darks: a poster that reads as dark (mean sRGB ≈ 40/255, Thrones)
    /// measures L ≈ 0.28, Wednesday's purple-black ≈ 0.35, a mid poster ≈ 0.45–0.55, a bright
    /// one ≥ 0.6. So: L 0.30 → 0.35, L 0.60 → full, linear between.
    static func strength(lightness: Double?) -> Double {
        guard let l = lightness else { return full }
        return min(full, max(least, least + (l - 0.30) / 0.30 * (full - least)))
    }

    /// The ground dim behind a composited cover, at this strength.
    static func groundDim(_ strength: Double) -> Double { 0.28 * strength }

    /// The local scrim under a WHOLE poster's lockup: `scrim` over dark art, rising to
    /// `scrimStrong` over bright art (review i2: "Season 4 · Episode 16" measured 3.1:1 over
    /// Emilia's white dress under the fixed 0.56 — every filled billboard already scaled its
    /// protection with the picture; the poster stage did not).
    static func posterScrim(_ strength: Double) -> Color {
        let t = max(0, min(1, (strength - least) / (full - least)))
        return Color.black.opacity(0.56 + (0.72 - 0.56) * t)
    }
}

/// A cinematic, edge-to-edge art header with content laid over its lower third.
///
/// This is the shape the ORIGINAL Today and Detail screens had and the rebuild replaced with a
/// 78-pt thumbnail beside a 20-pt title. Identity art is this product's only real material; when
/// it is 78 pt wide inside a stroked box there is nothing left for the design to be made of.
///
/// The art fills and crops (a hero is a backdrop, not a poster — `PosterSlot` is for artwork that
/// must stay whole). Everything the caller passes is bottom-aligned inside the gutter.
struct ArtHeader<Overlay: View>: View {
    let url: String?
    /// Full height of the art, safe area included. 0.44–0.52 × screen height is the cinematic band.
    var height: CGFloat
    /// Palette colour, used as the ground until the image decodes so the header never flashes black.
    var tint: Color? = nil
    var scrimTop: Double = 1
    var scrimBottom: Double = 1
    /// Where the crop anchors. `.top` keeps faces in a tall band; a key-art lockup that lives in
    /// the lower third needs `.bottom`, and a centred composition needs `.center`. Hard-coding
    /// `.top` is why one hero was a forehead and another was a logo.
    ///
    /// (`Alignment`, not `UnitPoint`: it is handed straight to `RemoteImageView(alignment:)`, the
    /// one place in this app where a crop anchor is applied.)
    var focus: Alignment = .top
    /// The source is a PORTRAIT cover, not a landscape banner.
    ///
    /// A 2:3 cover `.fill`ed into a 0.46-screen band is upscaled ~2.5× and cropped to a horizontal
    /// slice of itself — the app's largest piece of artwork rendered as its worst. When there is no
    /// banner the cover is composited instead: a blurred, opaque copy of itself as the ground, the
    /// whole cover fitted over it. Nothing is upscaled and nothing is lost.
    var portraitSource: Bool = false
    /// The portrait FILLS the frame from its top — its sides give — where the frame is much taller
    /// than a poster (Home's billboard, 0.53 w/h against a poster's 0.67): fitted to the width, the
    /// poster ended four fifths of the way down, on a straight edge behind the lockup, with the
    /// copy in a void under it (4 Oct).
    var portraitFill: Bool = false
    /// A slow breath on the sharp layer — Today's billboard. ~7 % over 24 s, eased, reversing:
    /// under the threshold where it reads as motion, over the one where the frame reads as a
    /// still pinned to a wall. Off under Reduce Motion. It is one transform animation on one
    /// layer, so no body re-evaluates for it (the scroll-lag rule of 2 Sep still holds).
    var drift: Bool = false
    /// The landscape is an AniList 1900×400 banner (`WideArt.ultraWide`): decode it at its native
    /// width, since the frame shows only a slice of it. A decode budget, not a choice of asset.
    var ultraWide: Bool = false
    /// The sharp layer is on screen (the launch waits for it).
    var onArtLoaded: (() -> Void)? = nil
    /// The picture starts THIS far below the frame's top, on the composited path: the blurred
    /// ground alone fills the chrome band. Today passes its wordmark band (review i3: a poster's
    /// own logotype in its top quarter is INK, and a veil cannot remove ink — Re:ZERO's read as
    /// "Previously.ZERO" under a 0.82 veil). Zero on Detail, whose bar is glyph capsules.
    var topInset: CGFloat = 0
    /// How much the blurred ground behind a composited cover is dimmed (`HeroProtection`
    /// scales it with the art's lightness; 0.28 over a bright cover).
    var groundDim: Double = 0.28
    @ViewBuilder var overlay: () -> Overlay

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drifting = false

    private var driftScale: CGFloat { drifting ? 1.07 : 1 }
    private var driftAnchor: UnitPoint { focus == .top ? .top : (focus == .bottom ? .bottom : .center) }

    var body: some View {
        ZStack(alignment: .bottom) {
            (tint ?? PaletteCache.fallback)
            if let url, !url.isEmpty {
                if portraitSource {
                    // Derived from the sharp layer's OWN decode (`BlurredArt`, 5 Sep): one
                    // fetch, one decode, both layers in one transaction — and a bitmap the
                    // compositor merely scales, where `.blur(radius: 48)` on this layer was a
                    // Gaussian pass over a screen-sized texture on every frame of the drift.
                    BlurredArt(url: url, sourceMaxPixel: 2048, fraction: 0.12)
                        .overlay(Color.black.opacity(groundDim))
                    // With a `topInset` the poster keeps its width, starts at the band's bottom
                    // edge and loses its bottom ~13 % — the part already under the copy scrim —
                    // and its top edge is BLENDED into the blurred ground over 56 pt rather than
                    // cut: a hard line where every poster began read as a header plate over an
                    // image (i4 first look), the opposite of a billboard.
                    // One transform on one layer, and NO mask unless the picture is inset: a mask is an
                    // offscreen pass, and under the drift `.mask { Color.black }` cost one per frame on a
                    // 2048-px layer — Today lagged to a standstill (5 Sep).
                    let sharp = RemoteImageView(url: url, contentMode: topInset > 0 || portraitFill ? .fill : .fit, maxPixel: 2048,
                                                alignment: focus, placeholderHidden: true, onLoaded: onArtLoaded)
                        .padding(.top, topInset)
                    if topInset > 0 {
                        // The ramp is 150, not 56 (6 Sep, "the top blur looks shit"): over 56 pt
                        // the blurred ground and the sharp poster meet inside one band the eye
                        // can find, so the top of the billboard reads as a picture that failed
                        // to focus rather than as a picture arriving. Eased in the middle, too —
                        // a straight ramp still shows its ends. Nothing else changes: the poster
                        // keeps its inset (a titled poster's own logotype stays clear of the
                        // wordmark), and this remains the only branch that carries a mask.
                        let blend: CGFloat = 150
                        sharp
                            .mask {
                                LinearGradient(stops: [
                                    .init(color: .clear, location: 0),
                                    .init(color: .black.opacity(0.35), location: 0.45),
                                    .init(color: .black.opacity(0.85), location: 0.78),
                                    .init(color: .black, location: 1),
                                ], startPoint: .top, endPoint: .bottom)
                                .frame(height: blend)
                                .padding(.top, topInset)
                                .frame(maxHeight: .infinity, alignment: .top)
                                .background(alignment: .bottom) { Color.black.padding(.top, topInset + blend) }
                            }
                            .scaleEffect(driftScale, anchor: driftAnchor)
                            .transition(.opacity)
                    } else {
                        sharp.scaleEffect(driftScale, anchor: driftAnchor)
                            .transition(.opacity)
                    }
                } else {
                    RemoteImageView(url: url, contentMode: .fill, maxPixel: ultraWide ? 1900 : 1536,
                                    alignment: focus, placeholderHidden: true, onLoaded: onArtLoaded)
                        .scaleEffect(driftScale, anchor: driftAnchor)
                        .transition(.opacity)
                }
            }
            ArtScrim(top: scrimTop, bottom: scrimBottom)
            overlay()
                .padding(.horizontal, ThemeMetrics.gutter)
                .padding(.bottom, ThemeSpace.x5)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .clipped()
        .task(id: drift && !reduceMotion) {
            guard drift, !reduceMotion, !PerfProbe.flag("perfNoDrift") else { drifting = false; return }
            // A beat after insertion: an animation started in the same transaction as the
            // view's own appearance is folded into it and never repeats.
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 24).repeatForever(autoreverses: true)) { drifting = true }
        }
    }
}

/// An eyebrow that sits ON artwork — "CONTINUE", "NEW EPISODE", "AIRED 10H AGO".
///
/// Over a photograph, plain tertiary-grey caps are unreadable half the time and washed out the
/// rest. A dark capsule makes it legible over anything and reads as a label rather than as text
/// that happens to be floating.
struct OverArtLabel: View {
    let text: String
    var dot: Bool = false
    var tint: Color = ThemeColor.textPrimary

    var body: some View {
        HStack(spacing: 6) {
            if dot { Circle().fill(ThemeColor.accent).frame(width: 5, height: 5) }
            Text(text).type(ThemeType.sectionLabel).textCase(.uppercase)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(ThemeColor.scrimStrong, in: Capsule())
        .overlay(Capsule().strokeBorder(ThemeColor.hairline, lineWidth: 1))
    }
}

/// The billboard's BADGE — "NEW EPISODE", "4 EPISODES BEHIND", "13 EPISODES LEFT", "CAUGHT UP",
/// "TRENDING", "WHILE YOU WERE AWAY" — the state as a small filled tag above the title.
///
/// The streaming apps' signal, chosen from three directions photographed side by side (4 Sep):
/// Prime Video overlays a "NEW EPISODE" badge on cover art and Disney+ tags tiles "Season
/// Finale" / "New Series"; the signal is one or two words on a ground, never a sentence. Amber
/// ground, `onAccent` ink, `heroBadge` (11-pt bold caps, +0.6), a 4-pt corner — a ground, so
/// no amber WORD is drawn and the one accent object on the block stays the capsule. Under it
/// the title, then ONE line ("Today at 7:30 PM · Season 4 · Episode 21").
///
/// It replaced, in one day: a scrimmed capsule pill over a 34-pt amber clock ("like a 3rd grade
/// app"), then a bare small-caps eyebrow with a 20-pt live moment row beneath the title ("text
/// heavy and cognitively overloaded"). Detail's state block, the trending billboard and the
/// recap wear the same badge; `OverArtLabel` stays the pill for a moment or an episode on CARD
/// art.
struct HeroBadge: View {
    let text: String
    /// A drop that is OUT NOW and unwatched — the badge arrives instead of merely appearing.
    var attention: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var lift = false
    @State private var ring = false
    @State private var sheen = false

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 4, style: .continuous) }

    /// The NEWS family — a new episode, season or series — wears red; every other state amber.
    private var isNews: Bool { text.lowercased().hasPrefix("new ") }
    private var fill: Color { isNews ? ThemeColor.news : ThemeColor.accent }
    private var fillDeep: Color { isNews ? ThemeColor.newsDeep : ThemeColor.accentPressed }

    var body: some View {
        Text(text)
            .type(ThemeType.heroBadge)
            .textCase(.uppercase)
            .foregroundStyle(isNews ? ThemeColor.onNews : ThemeColor.onAccent)
            // Grows with the type: a fixed 20-pt strip let AX-XL capitals stand out of the tag
            // above and below it (review, 23 Sep). Two lines at the accessibility sizes, never a
            // truncated state.
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .frame(minHeight: 20)
            // A CHIP, not a swatch: the fill carries a top-lit gradient and a hairline rim, so
            // the tag reads as a struck object at rest. This is where the prominence lives —
            // motion cannot be the carrier, because motion has to stop (see `AttentionBeat`).
            .background {
                shape.fill(isNews ? AnyShapeStyle(LinearGradient(colors: [fill, fillDeep],
                                                                 startPoint: .top, endPoint: .bottom))
                                  : AnyShapeStyle(ThemeGradient.accent))
                .overlay(shape.strokeBorder(.white.opacity(0.28), lineWidth: 0.5))
            }
            // The sheen rides ON the tag, clipped to it: one light band crossing a metallic
            // surface. `plusLighter` over an opaque fill, so it brightens rather than washes.
            .overlay {
                if attention && !reduceMotion {
                    GeometryReader { g in
                        LinearGradient(stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .white.opacity(0.30), location: 0.34),
                            .init(color: .white.opacity(0.85), location: 0.5),
                            .init(color: .white.opacity(0.30), location: 0.66),
                            .init(color: .clear, location: 1),
                        ], startPoint: .leading, endPoint: .trailing)
                            .frame(width: g.size.width * 0.8)
                            .offset(x: sheen ? g.size.width * 1.4 : -g.size.width * 1.0)
                            .blendMode(.plusLighter)
                    }
                    .clipShape(shape)
                    .allowsHitTesting(false)
                }
            }
            // One ring leaving the tag — an edge, not a wash. An amber GLOW behind an amber tag
            // was invisible on film (6 Sep); an expanding stroke has its own contrast.
            .overlay {
                if attention && !reduceMotion {
                    shape.strokeBorder(fill, lineWidth: 2)
                        .opacity(ring ? 0 : 0.9)
                        .scaleEffect(ring ? 1.55 : 1)
                        .allowsHitTesting(false)
                }
            }
            .scaleEffect(lift ? 1 : 0.9)
            .shadow(color: fill.opacity(attention ? 0.5 : 0), radius: 12, y: 2)
            .task(id: attention) { await choreograph() }
    }

    /// The arrival, then a slow shimmer that keeps coming back.
    ///
    /// The tag settles, one ring leaves its edge, and from then on a band of light crosses the
    /// chip every few seconds — the sweep slow enough to read as light on a surface rather than a
    /// blink. Two passes and stop was the first cut and the user's verdict was the brief for this
    /// one: "it shimmered just once and too fast. That doesn't draw attention" (6 Sep).
    ///
    /// **Accessibility.** Motion that runs past five seconds beside other content is the case
    /// WCAG 2.2.2 asks to be stoppable, and this now runs for as long as the badge is on screen.
    /// The stop is **Reduce Motion**, honoured here completely: no sweep, no ring, no settle, and
    /// the chip's resting form (gradient, rim, glow) carries the prominence on its own — as it
    /// does for everyone once a sweep has passed. `.task` is torn down with the view, so the loop
    /// never outlives what it decorates, and the sweep is one small clipped gradient over a 20-pt
    /// tag: no offscreen pass over anything the size of the billboard (the 5 Sep lag rule).
    @MainActor
    private func choreograph() async {
        guard attention, !reduceMotion else { lift = true; return }
        try? await Task.sleep(for: .milliseconds(90))
        guard !Task.isCancelled else { lift = true; return }
        withAnimation(ThemeMotion.uiMilestone) { lift = true }
        withAnimation(.easeOut(duration: 0.85)) { ring = true }
        try? await Task.sleep(for: .milliseconds(220))
        while !Task.isCancelled {
            sheen = false
            withAnimation(.easeInOut(duration: HeroBadge.sweep)) { sheen = true }
            try? await Task.sleep(for: .seconds(HeroBadge.sweep + HeroBadge.rest))
        }
    }

    /// How long the light takes to cross the chip. 0.72 s read as a flicker.
    private static let sweep: Double = 1.35
    /// The dark between passes. Long enough that the chip is a still object most of the time,
    /// short enough that a glance a few seconds later still catches one.
    private static let rest: Double = 2.6
}

/// The app's ONE attention beat: a short, FINITE entrance for something that is out now.
///
/// Three breaths at 0.55 s, 3.3 s in all, then still. Deliberately not `ThemeMotion.uiLiveBreath`
/// (`repeatForever`): WCAG 2.2.2 requires a pause/stop/hide control for auto-starting movement
/// that runs **longer than five seconds** alongside other content, and an indicator breathing
/// forever in a scrolling list is precisely that — it would oblige the app to ship a control for
/// a decoration. Under five seconds and finite, no control is required, and the thing still
/// catches the eye on arrival, which is the whole job.
///
/// Apple's rule bounds it from the other side: movement may never be the ONLY way information is
/// conveyed, so every user of this beat also states its fact in colour and in words. Reduce
/// Motion drops the beat and keeps both.
enum AttentionBeat {
    static let period: Double = 0.55
    static let breaths: Int = 3
    /// `repeatCount` counts out-and-back pairs when `autoreverses` is on, so this is
    /// `breaths × 2 × period` = 3.3 s. It was `breaths * 2` repetitions (6.6 s) for an hour on
    /// 6 Sep — over the five-second threshold the doc above cites, i.e. the very rule it quotes.
    static var animation: Animation {
        .easeInOut(duration: period).repeatCount(breaths, autoreverses: true)
    }

    /// Start the beat OFF the first frame.
    ///
    /// `withAnimation` inside `onAppear` is folded into the view's first frame and never plays —
    /// the same fault the launch ident was rebuilt around (see CLAUDE.md, "every value is a pure
    /// function of live time"). One yielded runloop turn is enough to make it an animation.
    /// Filmed at 8 fps on 6 Sep the badge was pixel-identical across the whole 3.3 s window
    /// before this; that is how the bug was found.
    @MainActor
    static func run(_ enabled: Bool, _ apply: @MainActor @escaping () -> Void) async {
        guard enabled else { return }
        try? await Task.sleep(for: .milliseconds(120))
        guard !Task.isCancelled else { return }
        withAnimation(animation) { apply() }
    }
}

/// A season that is ON AIR — there is more of this coming.
///
/// The device is AniList's: a small dot on the list entry, which its users care about enough to
/// script (a popular user script recolours the dot when you are *behind* on aired episodes). The
/// dot is amber because "still airing" is STATE, which is what amber is for here — never an
/// action. `fresh` means an episode is out now and unwatched, and adds the finite beat.
///
/// Jellyfin's issue #706 is the counter-example this exists to avoid: one blue circle for both
/// "all watched" and "new episodes waiting" produced "that small moment of excitement… upon
/// closer inspection it's just the same blue circle with a check mark". The states must differ in
/// COLOUR, not only in glyph.
struct LiveDot: View {
    /// An unwatched episode is out now (not merely "the season is running").
    var fresh: Bool = false
    var size: CGFloat = 6

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var beat = false

    var body: some View {
        Circle()
            // ALWAYS accent. "This season is on air" is STATE, which is exactly what amber is
            // for here — and a grey dot beside grey caption text is not a signal, it is lint
            // (measured on the Continue-watching shelf, 6 Sep). `fresh` changes the MOTION, not
            // the colour, so the resting picture stays one fact in one hue.
            .fill(ThemeColor.accent)
            .frame(width: size, height: size)
            .background {
                if fresh && !reduceMotion {
                    Circle()
                        .fill(ThemeColor.accent)
                        .opacity(beat ? 0 : 0.7)
                        .scaleEffect(beat ? 2.6 : 1)
                        .allowsHitTesting(false)
                }
            }
            .task(id: fresh) { await AttentionBeat.run(fresh && !reduceMotion) { beat = true } }
            .accessibilityHidden(true)   // the caption beside it already says the fact
    }
}

/// Protection over the status bar and the chrome band at the top of a billboard hero, ramping
/// out with no discernible knee.
///
/// One gradient for Today's wordmark band and Detail's floating toolbar. A ramp that holds flat
/// and then falls reads, over bright key art, as a hard-edged plate laid on the picture right
/// where the brand mark (or the back button) is; a veil that can be *seen* is not protection, it
/// is a smudge. This holds only as far as the band's own bottom edge and then eases out over the
/// rest on enough stops that no single step is visible.
struct HeroTopVeil: View {
    /// The chrome band's bottom edge, safe area included.
    let band: CGFloat
    /// How far below the band the veil takes to reach clear.
    var ramp: CGFloat = 100
    /// `HeroProtection.strength(lightness:)`: 1 over a bright cover, down to 0.5 over a dark one.
    var strength: Double = 1

    var body: some View {
        let total = band + ramp
        let mark = band / total
        let s = strength
        // 0.72 / 0.66 / 0.52. A tenth darker was tried for a poster's own logotype under the
        // wordmark (i2) and reverted (i3): the logotype was dark INK on a bright sky, and a veil
        // subtracts light from the ground — it raised the contrast. Today puts the picture
        // under the band instead (`ArtHeader(topInset:)`).
        LinearGradient(stops: [
            .init(color: .black.opacity(0.72 * s), location: 0),
            .init(color: .black.opacity(0.66 * s), location: mark * 0.72),
            .init(color: .black.opacity(0.52 * s), location: mark),
            .init(color: .black.opacity(0.30 * s), location: mark + (1 - mark) * 0.30),
            .init(color: .black.opacity(0.12 * s), location: mark + (1 - mark) * 0.62),
            .init(color: .clear, location: 1),
        ], startPoint: .top, endPoint: .bottom)
        .frame(height: total)
        .frame(maxWidth: .infinity)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Artwork in a LANDSCAPE frame — a shelf card, a browse tile.
///
/// A banner fills it. A portrait cover does not: `.fill`ed into a 1.6–2.1:1 frame, a 2:3 poster
/// shows the middle third of itself — a forehead, a white slab, a fragment of a lockup — which is
/// what the Library's Announced shelf and Search's trending wall did for every show the catalogue
/// has no banner for (about a third of them). Those are composited instead: a blurred, opaque
/// copy of the cover as the ground, the whole cover fitted over it. Nothing upscaled, nothing
/// lost — the same treatment `ArtHeader` gives a billboard, at card scale.
struct LandscapeArt: View {
    let url: String?
    var portraitSource: Bool = false
    var maxPixel: CGFloat = 560
    /// The banner is an AniList 1900×400 (`WideArt.ultraWide`): decode it at its native width.
    /// A 16:9 frame shows only the middle ~37 % of a 4.75:1 banner, so a decode budgeted for
    /// the frame's longest edge (900–1100) was drawn at ~2.5× — every anime card on Today,
    /// Schedule and the Library was soft while TMDB's 16:9 backdrops beside them were sharp
    /// ("the image quality used for Anime is not at par", user, 4 Sep). 1900 is a 3 MB decode.
    /// The crop itself stays: compositing the cover on the blurred banner was tried the same
    /// day and reverted ("the images were just fine").
    var ultraWide: Bool = false
    /// Where a banner's crop anchors.
    var alignment: Alignment = .top
    /// The sharp picture is on screen (the feed's launch hands off on its first post's art).
    var onLoaded: (() -> Void)? = nil

    var body: some View {
        if portraitSource {
            ZStack {
                // The ground is a pre-blurred bitmap of the same decode the cover draws from
                // (`BlurredArt`): a `.blur` here was one Gaussian pass per composited card per
                // scroll frame — five of them on a Schedule day.
                BlurredArt(url: url, sourceMaxPixel: maxPixel, fraction: 0.09)
                    .overlay(Color.black.opacity(0.32))
                // A contact shadow separates the sharp cover from its own blurred ground —
                // without it the two read as one badly-decoded image. Drawn by a shape under
                // the fitted picture (`fitShadow`), not by `.shadow` on the image layer.
                RemoteImageView(url: url, contentMode: .fit, maxPixel: maxPixel,
                                alignment: .center, placeholderHidden: true,
                                fitShadow: ShadowToken(color: .black.opacity(0.45), radius: 8, y: 4),
                                onLoaded: onLoaded)
                    .padding(.vertical, ThemeSpace.x2)
            }
        } else {
            RemoteImageView(url: url, contentMode: .fill, maxPixel: ultraWide ? max(maxPixel, 1900) : maxPixel,
                            alignment: alignment, placeholderHidden: true, onLoaded: onLoaded)
        }
    }
}

// MARK: - Progress banner

/// One wide piece of art with where-you-are drawn ON it: a 16:9 card, the progress bar inset over
/// a short scrim at its foot — Apple TV's Up Next card. Library's Continue watching cards and the
/// season screen's header are this one view; a numeral, where a screen wants one, sits on the
/// title's baseline beneath, never in the picture.
struct ProgressBanner: View {
    let url: String?
    /// `url` is a portrait cover: composited whole on its own blurred ground (`LandscapeArt`).
    var portraitSource: Bool = false
    /// 0…1; nil while there is nothing to measure.
    var progress: Double? = nil
    /// The EPISODE on the art — "EPISODE 21" as a pill in the BOTTOM-leading corner, above the
    /// bar when there is one (4 Sep: "the episode number can be fitted right into the image
    /// itself … otherwise it's tough to read", then "move the episode pill to the bottom-left so
    /// it stops covering faces" — faces live in the upper part of a banner's crop). The ONE pill
    /// a card wears; what it says beneath is the moment or the season.
    var episode: String? = nil
    /// See `LandscapeArt.ultraWide`.
    var ultraWide: Bool = false
    var maxPixel: CGFloat = 900
    var zoomID: String? = nil

    /// The bar's inset from the art's edges.
    static let inset: CGFloat = ThemeSpace.x3

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: ThemeRadius.card, style: .continuous)
        ZStack(alignment: .bottom) {
            shape.fill(ThemeColor.surfaceRaised)
            LandscapeArt(url: url, portraitSource: portraitSource, maxPixel: maxPixel, ultraWide: ultraWide)
            // The bar reads on any art: a short scrim under it, never a plate.
            LinearGradient(colors: [.clear, ThemeColor.scrim], startPoint: .top, endPoint: .bottom)
                .frame(height: 56)
                .allowsHitTesting(false)
            if let progress {
                ProgressBar(value: progress)
                    .padding(.horizontal, Self.inset)
                    .padding(.bottom, Self.inset)
            }
            if let episode {
                OverArtLabel(text: episode)
                    .padding(.horizontal, Self.inset)
                    // Above the bar (3 pt) by a step when the card carries one.
                    .padding(.bottom, progress == nil ? Self.inset : Self.inset + 3 + ThemeSpace.x2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .clipShape(shape)
        .overlay(shape.strokeBorder(ThemeColor.posterEdge, lineWidth: 1))
        .cardShadow(.art, shape: shape)
        .modifier(OptionalZoomSource(id: zoomID))
    }
}

// MARK: - Chips

/// A selectable chip — search scope, a recent query, a filter value.
///
/// An ACTIVE filter chip: `accentSoft` ground, `accent` label, removable. Distinct from
/// `ChipButtonStyle`, whose selected state is a solid accent capsule meant for a primary choice (a
/// search scope) — four solid amber capsules above a list is louder than anything on the screen
/// they are filtering. Library and Schedule each carried a private copy of this (Schedule's without
/// the pressed ground); this is the one.
struct FilterChipStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .type(ThemeType.metadataEmphasis)
            .foregroundStyle(ThemeColor.accent)
            .padding(.horizontal, ThemeSpace.x3)
            .frame(minHeight: 32)
            .background {
                Capsule().fill(configuration.isPressed ? ThemeColor.surfacePressed : ThemeColor.accentSoft)
            }
            .contentShape(Capsule())
            .frame(minHeight: 44)
            .pressFeedback(configuration.isPressed, reduceMotion: reduceMotion)
    }
}

/// The label of a removable filter chip: the criterion and an ×. Pair with `FilterChipStyle`.
struct FilterChipLabel: View {
    let text: String
    var body: some View {
        HStack(spacing: 5) {
            Text(text)
            AppGlyph(systemName: "xmark").font(.system(size: 10, weight: .bold))
        }
    }
}

/// Unselected chips carry NO stroke. The shipped Search screen draws a grey-outlined pill for
/// every scope and every recent query, so eight outlined objects compete with the three posters
/// underneath them. Tone alone separates an unselected chip from the canvas; the selected one is
/// the only chip allowed to use colour, which is what makes the selection readable at a glance.
struct ChipButtonStyle: ButtonStyle {
    var selected: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .type(ThemeType.metadataEmphasis)
            .foregroundStyle(selected ? ThemeColor.onAccent : ThemeColor.textSecondary)
            .padding(.horizontal, 14)
            .frame(minHeight: 34)
            .background {
                if selected {
                    Capsule().fill(configuration.isPressed ? ThemeGradient.accentPressed : ThemeGradient.accent)
                } else {
                    Capsule().fill(configuration.isPressed ? ThemeColor.surfacePressed : ThemeColor.surfaceRaised)
                }
            }
            .overlay {
                Capsule().strokeBorder(selected ? ThemeGradient.litEdgeStrong
                                                : LinearGradient(colors: [.white.opacity(0.12), .clear],
                                                                 startPoint: .top, endPoint: .center),
                                       lineWidth: 1)
            }
            .contentShape(Capsule())
            .frame(minHeight: 44)
            .pressFeedback(configuration.isPressed, reduceMotion: reduceMotion)
    }
}

// MARK: - Account

/// The account disc, drawn once for every surface that shows one.
///
/// The shipped build had two: Today derived a letter from `auth.displayName` (the raw Clerk id
/// `user_…` → "U") and Profile derived one from its own fallback label "Your account" (→ "Y") —
/// one user, two meaningless letters, one tap apart, while `AuthManager` already carried a helper
/// neither called. Both now read `AuthManager.identity`.
///
/// **It never draws `person.fill`.** Both call sites were rendering the system's generic account
/// glyph inside a brand-coloured ring — the app spending its one accent on a placeholder, on the
/// element whose entire job is to be *this person*. On Profile the disc also cut a hole straight
/// through the poster fan behind it. The chain is: the real initial → the first letter of the label
/// the account is shown under → the Previously. mark. Only the first two are letters, so a wrong
/// initial is still never invented; the third is the app's own identity, which is never wrong.
///
/// `accentSoft` ground with the monogram in `accent`, and the ring at `posterEdge` — the same 9 %
/// white every piece of artwork in the app is bounded with, so the disc sits in the same material
/// world as the posters beside it instead of glowing.
struct AccountDisc: View {
    let identity: AuthManager.AccountIdentity
    var diameter: CGFloat = 56
    /// Neutral ground and ink instead of the accent pair. Today's header wears this: the amber
    /// budget above the fold belongs to the hero's fact and its one action, and an amber monogram
    /// disc 12 pt from the wordmark was a second brand-coloured object spending it on chrome.
    /// Profile — where the disc IS the subject — keeps the accent form.
    var quiet = false

    var body: some View {
        ZStack {
            Circle().fill(quiet ? ThemeColor.surfaceRaised : ThemeColor.accentSoft)
            Circle().strokeBorder(ThemeColor.posterEdge, lineWidth: 1)
            if let monogram = identity.monogram {
                Text(monogram)
                    .font(.system(size: diameter * 0.42, weight: .semibold))
                    .foregroundStyle(quiet ? ThemeColor.textSecondary : ThemeColor.accent)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
            } else {
                PreviouslyMark(width: diameter * 0.40, style: .glyph)
            }
        }
        .frame(width: diameter, height: diameter)
        .accessibilityHidden(true)
    }
}

// MARK: - The mark
//
// One verb, one control grammar. The shipped build had FOUR dialects — a labelled amber capsule on
// Today, the same capsule with the batch hidden behind a long-press-only `Menu(primaryAction:)` on
// Detail, a bare `textTertiary` checkmark pixel-identical to `PassiveTick` in the episode list, and
// an unlabelled 34-pt accent disc on Schedule — two of which used the same glyph to mean opposite
// things. The grammar from here, in a 44-pt target around a 22-pt ring:
//
//   hollow `strokeStrong` ring     unmarked, tappable
//   accent fill + `onAccent` check the commit frame
//   bare `textTertiary` check      settled, non-interactive (`PassiveTick`, Seasons only)

/// The check DRAWS. Nowhere in the shipped build did it: every tick was an opacity crossfade or a
/// scale pop, so the one moment the product exists to deliver had no signature motion. The mark is
/// masked left-to-right as it lands, which is what a hand-drawn tick does — and under Reduce Motion
/// it is simply there, at full width, with no animation to suppress.
struct DrawnCheck: View {
    /// `true` once the write has committed.
    var on: Bool
    var size: CGFloat = 14
    var tint: Color = ThemeColor.onAccent

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var progress: CGFloat = 0

    var body: some View {
        AppGlyph(systemName: "checkmark")
            .font(.system(size: size, weight: .bold))
            .foregroundStyle(tint)
            .mask(alignment: .leading) {
                GeometryReader { geo in
                    Rectangle().frame(width: geo.size.width * progress)
                }
            }
            .onChange(of: on, initial: true) { _, on in
                guard on else { progress = 0; return }
                if reduceMotion {
                    progress = 1
                } else {
                    withAnimation(ThemeMotion.uiMicro) { progress = 1 }
                }
            }
            .accessibilityHidden(true)
    }
}

/// The round mark control: a 44-pt target holding a 22-pt ring. Used by Schedule's rows, the Up
/// next cards and the episode list, so the same gesture has the same shape everywhere it is not a
/// labelled capsule.
struct MarkRing: View {
    /// How loudly the marked state is drawn. The geometry, the target and the motion are identical
    /// in every style — only the ink changes, so there is still exactly ONE mark control in the app.
    enum Style {
        /// Accent fill, `onAccent` check — the louder form, for a control that stands alone.
        case filled
        /// Accent ring, accent check, no fill. For a dense repeating list of cards (Schedule).
        case quiet
        /// The list form (6 Sep): a WATCHED episode is a disc in the show's colour (`fill`) with
        /// the check on it — Reminders fills the circle with the list's colour — the NEXT episode
        /// is the one accent ring (`lead`), and the rest are idle rings. The marked state used to
        /// be a bare 12-pt tertiary check with no body in a 44-pt column ("the tick mark feels
        /// cheap", user); before that, eleven amber rings down one column.
        case settled
    }

    var marked: Bool
    var style: Style = .filled
    /// The unmarked ring is the next step: the only accent in a settled column.
    var lead: Bool = false
    /// The episode the tap will write, drawn inside the idle ring where no row names it
    /// (Schedule's cards, the Up next cards). The episode list passes nil: its row states the
    /// episode 14 pt away, and the numeral was the same fact twice ("why does it need to show the
    /// episode number on the CTA?", user, 6 Sep).
    var episode: Int? = nil
    /// `.settled`: the watched disc's colour — the show's quiet tint (`DetailTint.quiet`);
    /// `surfaceFloating` without one.
    var fill: Color? = nil
    /// The beat right after THIS control committed a mark: accent fill, the check drawing in
    /// `onAccent`, one pulse — then the disc settles into `fill` when the parent lets go (~0.55 s).
    /// The control is the receipt; nothing under the row says "Episode 7 watched" again.
    var committing: Bool = false
    /// Accessibility label for the unmarked state; the marked state speaks `markedLabel`.
    var label: String = Copy.Action.markAsWatched
    var markedLabel: String? = nil
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse: CGFloat = 1
    /// The ring grows with the text it sits beside (review i2: at AX-XL Schedule's "18" was the
    /// one control on the screen that did not). The numeral has an 11-pt floor — it was 9, and 7
    /// for a three-digit episode, below any legible size — and a three-digit episode draws no
    /// numeral at all: the row names it, and the label speaks it.
    @ScaledMetric(relativeTo: .body) private var diameter: CGFloat = 22
    @ScaledMetric(relativeTo: .caption2) private var numeralSize: CGFloat = 11

    private var disc: Color {
        if committing { return ThemeColor.accent }
        switch (marked, style) {
        case (true, .filled):  return ThemeColor.accent
        case (true, .settled): return fill ?? ThemeColor.surfaceFloating
        default:               return .clear
        }
    }

    private var ring: Color {
        if committing || (marked && style != .quiet) { return .clear }
        if marked { return ThemeColor.accent }
        return lead ? ThemeColor.accent : ThemeColor.markRingIdle
    }

    private var ink: Color {
        if committing { return ThemeColor.onAccent }
        switch style {
        case .filled:  return ThemeColor.onAccent
        case .quiet:   return ThemeColor.accent
        case .settled: return ThemeColor.textPrimary
        }
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                // The amber disc is the accent as a MATERIAL (lit from above, as the primary
                // capsule is); a settled disc keeps its show's flat colour.
                Circle().fill(disc == ThemeColor.accent ? AnyShapeStyle(ThemeGradient.accent) : AnyShapeStyle(disc))
                    .frame(width: diameter, height: diameter)
                Circle().strokeBorder(ring, lineWidth: 1.5).frame(width: diameter, height: diameter)
                if let episode, !marked, !committing, episode < 100 {
                    Text("\(episode)")
                        .font(.system(size: min(numeralSize, diameter * 0.5), weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(lead ? ThemeColor.accent : ThemeColor.textSecondary)
                        .transition(.opacity)
                }
                // Mounted unconditionally: a conditional insert re-creates `DrawnCheck` and hands
                // SwiftUI an implicit opacity transition ON TOP of the mask, so the app's signature
                // motion rendered as a smear instead of a stroke. The mask IS the animation.
                DrawnCheck(on: marked, size: diameter * 12 / 22, tint: ink)
            }
            .scaleEffect(pulse)
            .frame(width: max(44, diameter + 22), height: max(44, diameter + 22))
            .contentShape(Circle())
            .animation(ThemeMotion.pick(ThemeMotion.uiMicro, reduceMotion: reduceMotion), value: marked)
            // The settle out of the commit beat, and the accent ring arriving on the next row,
            // ride the settle spring rather than the micro one: a hand-off, not a flick.
            .animation(ThemeMotion.pick(ThemeMotion.uiSettle, reduceMotion: reduceMotion), value: committing)
            .animation(ThemeMotion.pick(ThemeMotion.uiSettle, reduceMotion: reduceMotion), value: lead)
        }
        .buttonStyle(MarkPressStyle())
        .onChange(of: committing) { _, on in
            guard on, !reduceMotion else { pulse = 1; return }
            // One pulse on the commit — a hair down, then home on the milestone spring, which
            // overshoots — the way Reminders' circle pops as it fills.
            pulse = 0.84
            withAnimation(ThemeMotion.uiMilestone) { pulse = 1 }
        }
        .accessibilityLabel(marked ? (markedLabel ?? Copy.Accessibility.complete) : label)
        .accessibilityAddTraits(marked ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - Colour is never the only carrier

/// The shape carrier for a state that is otherwise encoded in colour alone.
///
/// `accessibilityDifferentiateWithoutColor` had **zero** references in the whole of `Sources/`, so
/// every colour-only encoding in the app — Schedule's "today", an accent caption that means "this
/// is your next step" — was invisible to a user who has asked the system for shapes instead of
/// hues. This draws nothing at all until that setting is on, at which point the state also carries
/// a glyph. It is not an accessibility fallback bolted beside the design; it is the second carrier
/// the design should have had.
struct DifferentiateMark: View {
    var symbol: String = "circle.fill"
    var size: CGFloat = 6
    var tint: Color = ThemeColor.textPrimary

    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiate

    var body: some View {
        if differentiate {
            AppGlyph(systemName: symbol)
                .font(.system(size: size, weight: .bold))
                .foregroundStyle(tint)
                .accessibilityHidden(true)
        }
    }
}

extension View {
    /// A 2-pt rule under an element whose selected/current state is otherwise only a colour.
    /// Unconditional when Differentiate Without Color is on, absent otherwise.
    func differentiatingUnderline(_ active: Bool, tint: Color = ThemeColor.textPrimary) -> some View {
        modifier(DifferentiatingUnderline(active: active, tint: tint))
    }
}

private struct DifferentiatingUnderline: ViewModifier {
    let active: Bool
    let tint: Color

    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiate

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if active && differentiate {
                Capsule().fill(tint).frame(height: 2).padding(.horizontal, 4).offset(y: 3)
                    .accessibilityHidden(true)
            }
        }
    }
}

// MARK: - Skeleton

/// Structural skeleton: static, no shimmer (spec: shimmer is refused).
struct SkeletonBlock: View {
    var width: CGFloat? = nil
    /// nil: the block takes the height it is proposed (a 16:9 card via `aspectRatio`).
    var height: CGFloat? = 12
    var radius: CGFloat = 6
    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(ThemeColor.skeleton)
            .frame(width: width, height: height)
    }
}

/// "In your library", on a poster: an amber disc with the check in `onAccent` — the committed-mark
/// colours, so owned reads as the same kind of fact as watched. 20 pt, never a control.
struct OwnedMark: View {
    @ScaledMetric(relativeTo: .caption) private var size: CGFloat = 20

    var body: some View {
        ZStack {
            Circle().fill(ThemeColor.accent)
            AppGlyph(systemName: "checkmark")
                .font(.system(size: size * 0.5, weight: .bold))
                .foregroundStyle(ThemeColor.onAccent)
        }
        .frame(width: size, height: size)
        .shadow(.art)
        .accessibilityHidden(true)
    }
}
