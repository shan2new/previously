import SwiftUI

// The objects Search repeats everywhere, each of which the shipped build drew more than one way.
//
//  • `AddControl` — the primary action of the whole screen. It measured ~25 pt over artwork (below
//    the 44-pt minimum), 55×43 as a bordered `Add` in a row (1 pt under it), and **vanished
//    entirely** in the added state, replaced by a bare grey checkmark with no chrome, no target
//    and no way to undo — so the trailing column's edge was ragged down the list and the most
//    important control on the screen was its quietest object. One component, two states, one
//    44-pt frame, one visual width, in both states, on every surface.
//  • `FactLine` — "2018 · 11 parts", "2023 · 6 parts / Airing", "2004 · 12 parts · Airing": the
//    same data set rendered three ways in three places, truncating mid-word in the narrow ones
//    ("2026 ·" — an orphaned separator). Facts are supplied in priority order and the line prints
//    only as many as actually fit. A dropped fact beats a fragment.
//  • `RankGutter` — a chart position, in the row's own leading gutter. The over-art numeral is
//    gone: "03" painted straight over the poster's own title lockup on the first screen a new user
//    sees, so on the shelf the rank now leads the caption instead.

/// Sizes these controls need that have no token equivalent. Each says why it is the number it is.
private enum Metrics {
    /// The 44-pt minimum target (HIG), held by both placements in both states.
    static let hitTarget: CGFloat = 44
    /// The over-art disc: the smallest circle that still reads as a control inset in a 124-pt poster.
    static let overArtDisc: CGFloat = 26
    /// The owned ring's alpha over art — measured against the brightest chart posters so the ring
    /// reads on all of them without becoming a second amber object.
    static let ownedRingOverArt: Double = 0.45
    /// The owned ring's alpha on a surface, where the `accentSoft` fill already carries the state.
    static let ownedRingOnSurface: Double = 0.35
    /// X's Follow pill: 32 tall, and wide enough for "Added" so both states share one width.
    static let pillHeight: CGFloat = 32
    static let pillMinWidth: CGFloat = 78
}

// MARK: - Add / added

/// Where the control sits, which decides its shape.
enum AddControlPlacement {
    /// Inset into the corner of a poster.
    case overArt
    /// The trailing column of a row or card, on a surface rather than on art.
    case row
    /// Labeled action grouped with the facts on a scene card, never laid over poster lettering.
    case artwork
    /// X's Follow pill at a result row's trailing edge (the X pass, 25 Sep): "Add" in ink on white
    /// until the show is yours, then "Added" in an outline — the one-pixel ring, X's "Following".
    case pill
}

/// The one add control.
///
/// **The placement rule, written down, because "two shapes for one verb 12 pt apart" was a finding:**
/// a control that sits ON artwork is a 26-pt disc inset into the poster's corner (shelf cards, and
/// any future grid); a control that sits in a row or card's trailing column is a 44-pt rounded
/// square. Those are the only two, they are chosen by *what is underneath the control*, and neither
/// one ever appears in the other's context — including at accessibility sizes, where the shipped
/// build grew the card's square into a full-width capsule and so drew one verb three ways.
///
/// **Owned does not remove on tap.** A tick that unsubscribed on contact was the only destructive
/// one-tap in the app, 44 pt from the add it replaced — and it never said which shelf the show was
/// on. Owned now opens a menu: the same status options and the same Undo-carrying Remove the
/// Library row's long-press offers (`ownedMenu`). Unowned still adds on tap; its long-press shows
/// the one verb it performs, so the two states are one control with one gesture grammar.
///
/// Both placements are 44 pt of target and both keep the same footprint whether the show is in
/// the library or not.
struct AddControl<OwnedMenu: View>: View {
    let title: String
    let owned: Bool
    var placement: AddControlPlacement = .row
    /// The add ASKS first ("Where are you in X?", on the show page) — labelled "Add…", the
    /// ellipsis the platform uses for a command that needs more input (review i4: one "+ Add"
    /// label for an instant add and for one that opens a page and a question).
    var asks: Bool = false
    let add: () -> Void
    /// The menu behind an OWNED control: `FranchiseContextMenu` once the franchise is loaded, or
    /// the single Remove while the add is still pending.
    @ViewBuilder var ownedMenu: () -> OwnedMenu

    var body: some View {
        styled
            // Not `.isSelected`: the amber tick is ownership, not a selection state. The value
            // names which it is, and the hint says what the tap does in that state.
            .accessibilityLabel(title)
            .accessibilityValue(owned ? Copy.Search.inLibrary : Copy.Search.notInLibrary)
            .accessibilityHint(owned ? Copy.Search.ownedHint : Copy.Search.addHint)
    }

    /// The CONCRETE style per placement (5 Sep): the erased `AnyButtonStyle` boxed every
    /// `makeBody` in an `AnyView`, and on Search that box was built once per result row per
    /// answer — the leaf of the typing stalls. A placement never changes at runtime, so the
    /// branch costs the control nothing.
    @ViewBuilder
    private var styled: some View {
        if placement == .overArt {
            control.menuStyle(.button).buttonStyle(MarkPressStyle())
        } else if placement == .artwork {
            control.menuStyle(.button).buttonStyle(ArtworkActionStyle(filled: false))
        } else if placement == .pill {
            control.menuStyle(.button).buttonStyle(FeedIconPressStyle())
        } else {
            control.menuStyle(.button).buttonStyle(CompactSquareStyle(owned: owned))
        }
    }

    /// A `Menu` only once OWNED (tap opens the status menu); unowned, a plain `Button` (tap
    /// adds). It used to be one `Menu` in both states, so the glyph's symbol replacement could
    /// animate across the flip without the control being rebuilt — and every result row paid
    /// for a UIKit menu interaction it would never open: measured 5 Sep (typing at human speed,
    /// the stall sampler on), the menus were 40 % of what an answer landing cost. The flip now
    /// crossfades the control; the tap-to-add and the long-press-for-status are unchanged.
    @ViewBuilder
    private var control: some View {
        let glyph = AddGlyph(owned: owned, placement: placement, asks: asks)
        if owned {
            Menu(content: { AddMenuContent(owned: owned, add: add, ownedMenu: ownedMenu) }, label: { glyph })
        } else {
            Button(action: add) { glyph }
        }
    }
}

/// What the menu holds: the owner's status options, or the one verb an unowned control performs.
private struct AddMenuContent<OwnedMenu: View>: View {
    let owned: Bool
    let add: () -> Void
    let ownedMenu: () -> OwnedMenu

    var body: some View {
        if owned {
            ownedMenu()
        } else {
            Button(action: add) { AppGlyphLabel(Copy.Search.addToLibrary, systemName: "plus") }
        }
    }
}

/// `plus` and `checkmark` at the same size, in the same shape, so the state change is a symbol
/// replacement rather than a crossfade between two differently-shaped objects.
///
/// Added is drawn in `accent`; unadded in `textPrimary`. The two states were previously
/// separated by the glyph's *colour alone* inside identical grey chrome, so "in your library"
/// and "not in your library" both read as live grey buttons.
private struct AddGlyph: View {
    let owned: Bool
    let placement: AddControlPlacement
    var asks: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if placement == .pill {
            Text(owned ? Copy.Search.added : (asks ? Copy.Search.addAsks : Copy.Search.add))
                .type(ThemeType.feedNoteTitle)
                .foregroundStyle(owned ? ThemeColor.feedText : ThemeColor.canvas)
                .lineLimit(1)
                .fixedSize()
                .contentTransition(.opacity)
                .animation(ThemeMotion.pick(ThemeMotion.uiMicro, reduceMotion: reduceMotion), value: owned)
                .modifier(AddControlShape(placement: placement, owned: owned))
        } else if placement == .artwork {
            // Labelled on the art (20 Sep); an owned show's check is amber — ownership is STATE.
            Label {
                Text(owned ? Copy.Search.added : (asks ? Copy.Search.addAsks : Copy.Search.add))
            } icon: {
                AppGlyph(systemName: owned ? "checkmark" : "plus", decorative: true)
                    .foregroundStyle(owned ? ThemeColor.accent : ThemeColor.textPrimary)
            }
            .fixedSize(horizontal: true, vertical: false)
        } else {
        AppGlyph(systemName: owned ? "checkmark" : "plus")
            // Text styles, not point sizes: caption (12) in the disc, subheadline (15) in the
            // square, so the glyph tracks Dynamic Type with the row it sits in.
            .font(.system(placement == .overArt ? .caption : .subheadline, weight: .bold))
            .foregroundStyle(owned ? ThemeColor.accent : ThemeColor.textPrimary)
            // A Tabler picture, not an SF Symbol: the plus crossfades to the check.
            .contentTransition(.opacity)
            .animation(ThemeMotion.pick(ThemeMotion.uiMicro, reduceMotion: reduceMotion), value: owned)
            .modifier(AddControlShape(placement: placement, owned: owned))
        }
    }
}

/// The disc / square the glyph sits in. Split out so the two placements cannot drift apart.
private struct AddControlShape: ViewModifier {
    let placement: AddControlPlacement
    let owned: Bool

    func body(content: Content) -> some View {
        switch placement {
        case .overArt:
            // A 26-pt disc centred in a 44-pt target. Scrim-filled in BOTH states with a hairline
            // ring, so the reading never depends on what the poster happens to be doing behind it —
            // measured 7.0:1 / 16.6:1 / 14.8:1 against the brightest posters in the chart. The
            // added state warms the fill so the two states differ in more than the glyph's colour.
            content
                .frame(width: Metrics.overArtDisc, height: Metrics.overArtDisc)
                .background(ThemeColor.scrimStrong, in: Circle())
                .background(owned ? ThemeColor.accentSoft : .clear, in: Circle())
                .overlay(Circle().strokeBorder(owned ? ThemeColor.accent.opacity(Metrics.ownedRingOverArt)
                                                     : ThemeColor.posterEdge,
                                               lineWidth: 1))
                .frame(width: Metrics.hitTarget, height: Metrics.hitTarget)
                .contentShape(Circle())
        case .row:
            // Square, not a text capsule: "Add" and "✓" are different widths, and a trailing
            // column that changes width between rows is why the list's right edge was ragged.
            content
                .frame(width: Metrics.hitTarget, height: Metrics.hitTarget)
                .contentShape(Rectangle())
        case .artwork:
            content
        case .pill:
            // X's Follow pill: 32 tall, one width in both states (the column stays straight), in a
            // 44-pt target.
            content
                .padding(.horizontal, ThemeSpace.x4)
                .frame(minWidth: Metrics.pillMinWidth, minHeight: Metrics.pillHeight)
                .background(owned ? AnyShapeStyle(Color.clear) : AnyShapeStyle(ThemeGradient.ivory), in: Capsule())
                .overlay(Capsule().strokeBorder(owned ? ThemeColor.feedSeparator : .clear, lineWidth: FeedMetrics.hairline))
                .frame(minHeight: Metrics.hitTarget)
                .contentShape(Rectangle())
        }
    }
}

/// `CompactActionButtonStyle`'s chrome at a fixed 44×44. The style itself pads to a label's width,
/// which is exactly what the ragged column needed to stop doing.
///
/// **Unadded is a stroke, not a fill.** Four identical filled grey tiles running down the right
/// edge of the one screen whose job is showing artwork made the trailing column the heaviest thing
/// in every row. The fill is now what *ownership* looks like — `accentSoft`, which is also the only
/// state that is a settled fact rather than an offer.
private struct CompactSquareStyle: ButtonStyle {
    let owned: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: ThemeRadius.compactControl, style: .continuous)
    }

    private func fill(pressed: Bool) -> Color {
        if pressed { return ThemeColor.surfacePressed }
        return owned ? ThemeColor.accentSoft : .clear
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(fill(pressed: configuration.isPressed), in: shape)
            .overlay(shape.strokeBorder(owned ? ThemeColor.accent.opacity(Metrics.ownedRingOnSurface)
                                              : ThemeColor.stroke,
                                        lineWidth: 1))
            .opacity(reduceMotion && configuration.isPressed ? 0.72 : 1)
            .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? 0.985 : 1))
            .animation(ThemeMotion.pick(ThemeMotion.uiPress, reduceMotion: reduceMotion),
                       value: configuration.isPressed)
    }
}


// MARK: - Metadata

/// One metadata line, built from facts in priority order, printing only what fits.
///
/// The rule the direction states and the shipped build broke on every card: **drop a fact rather
/// than print a fragment.** `.truncationMode(.tail)` on a joined metadata string is how "2026 ·"
/// and "2018 · 11 parts · Friday…" reached the screen.
///
/// `lead` is the one fact that is allowed to be amber: a real next step, always printed first and
/// never dropped. Everything else is `textSecondary`. The shipped line set "29 Aug 2:00 PM" in the
/// same grey as the year and the season count, so the only time-sensitive fact on the screen read
/// as trivia — the inverse of the rule Today, Library and Schedule follow.
struct FactLine: View {
    let facts: [String]
    /// The forward-looking fact, in `rowMetaLead` accent. Printed before the grey facts.
    var lead: String? = nil
    var token: TypeToken = ThemeType.rowMeta
    var tint: Color = ThemeColor.textSecondary

    @Environment(\.dynamicTypeSize) private var typeSize

    /// The one separator every joined fact line on this screen uses — `MediaRow`'s `meta` and the
    /// shelf caption are joined with it too, so a row and a card never punctuate differently.
    static let separator = " \u{00B7} "

    private func greyText(_ n: Int) -> String {
        facts.prefix(n).joined(separator: FactLine.separator)
    }

    /// One line: the amber lead, then as many grey facts as fit after it.
    ///
    /// `fixed` is what makes the ladder work — a candidate that reports its IDEAL width is one
    /// `ViewThatFits` can reject. The floor candidate is the only flexible one.
    private func line(_ n: Int, fixed: Bool = true) -> some View {
        HStack(spacing: 0) {
            if let lead {
                Text(lead)
                    .type(ThemeType.rowMetaLead)
                    .foregroundStyle(ThemeColor.accent)
                if n > 0 { Text(FactLine.separator).type(token).foregroundStyle(tint) }
            }
            if n > 0 {
                Text(greyText(n))
                    .type(token)
                    .foregroundStyle(tint)
            }
        }
        .lineLimit(1)
        .fixedSize(horizontal: fixed, vertical: false)
    }

    var body: some View {
        // ONE joined line at every size, dropping facts to fit — including at accessibility sizes,
        // where the shipped build broke the same data into three stacked lines and so showed MORE
        // information at AX than at the default size.
        ViewThatFits(in: .horizontal) {
            line(facts.count)
            line(3)
            line(2)
            line(1)
            line(0)
            // The floor. `ViewThatFits` renders its LAST candidate whether or not it fits, so this
            // one must be able to give: without it a lead that outgrew a 124-pt shelf caption kept
            // its ideal width and ran clean across the card beside it. Shrunk, then truncated —
            // never spilled.
            line(0, fixed: false)
                .minimumScaleFactor(0.75)
                .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - The rank numeral

/// A chart position at row altitude: in the row's own leading gutter, beside the poster rather
/// than burned into it.
///
/// At 60 pt wide a numeral covers roughly a quarter of the thumbnail, and "06" landed on a bright
/// character with nothing protecting it — the rank competing with the identity art it is supposed
/// to be labelling. A chart's numerals are chrome; chrome goes in a gutter and holds one x.
struct RankGutter: View {
    /// The lane the numerals hold at the default text size, so a row's separator and its art can be
    /// inset from one number.
    static let width: CGFloat = 24

    let rank: Int

    /// The lane grows with the type in it. Held at 24 pt, the numeral rendered as a bare "…" at
    /// AX1 — a chart with no numbers in its rank column.
    @ScaledMetric(relativeTo: .caption2) private var lane: CGFloat = RankGutter.width

    var body: some View {
        Text(Copy.Search.rank(rank))
            .type(ThemeType.sectionLabel)
            .monospacedDigit()
            .foregroundStyle(ThemeColor.textDisabled)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .fixedSize(horizontal: true, vertical: false)
            .frame(width: lane, alignment: .leading)
            .accessibilityHidden(true)
    }
}

// MARK: - The scope, at rest

/// All · Anime · TV — the scope as a RESTING selector at the top of Discover's launchpad and of a
/// genre page (brief §17: the chips filter every section — the top pick, Recommended, the genres
/// and the chart). It replaces the removable token both surfaces drew only once a scope was
/// already on, which left no way to choose one at rest: the system scope bar
/// (`.searchScopes(.onTextEntry)`) exists only while there is text, and it still governs the
/// results.
///
/// Bound to the app's one `mediaFilter`, so a genre page and the launchpad can never disagree.
/// The selected chip is amber as STATE (the filter that is on — `ChipButtonStyle(selected:)`); the
/// others are tone only. Choosing a scope is not a write, so it plays no haptic.
struct ScopeChips: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // One audience has one scope and nothing to choose (`Audience`).
        if !appModel.audience.isSingle { chips }
    }

    private var chips: some View {
        let current = appModel.mediaFilter
        return HStack(spacing: ThemeSpace.x2) {
            ForEach(MediaFilter.allCases, id: \.self) { filter in
                let selected = filter == current
                Button {
                    guard !selected else { return }
                    withAnimation(ThemeMotion.pick(ThemeMotion.uiSnappy, reduceMotion: reduceMotion)) {
                        appModel.mediaFilter = filter
                    }
                } label: {
                    Text(Copy.Search.scopeWord(filter))
                        .lineLimit(1)
                }
                .buttonStyle(ChipButtonStyle(selected: selected))
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, ThemeMetrics.gutter)
    }
}
