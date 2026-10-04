import SwiftUI

// "What do you watch?" — the one question that decides whose app this is (`Audience`,
// AppModel+Audience.swift). Asked once, after the first sign-in, and kept in Profile.
//
// Three cards, each the PICTURE of its answer rather than a row of a form — pictures made for the
// question (4 Oct: "the assets shown ARE shit. When we have Codex available, why… are we reusing
// existing ones?", owner, of the Discover genre tiles the cards first borrowed: one-colour duotones
// made to sit under a genre's name, dim and flat as the first thing a new account sees). Anime is
// a drawn key visual, a lone swordfighter over a city under a burning sky; TV is a photographed
// frame, a figure in a long coat on a rain-lit street; both is ONE street, drawn on its left and
// photographed on its right, a single figure on the seam (design/onboarding-2026-10-04: the
// briefs, every candidate, `package-audience-art.py`).
//
// The chosen card is HELD, not outlined: the selection ring stands off it in the accent as a lit
// metal, its badge is a lit disc with the check drawn in, the picture settles a breath closer, and
// the other two step back under a veil (`SelectionRing`, `SelectedBadge`). The screen takes the
// chosen picture's light (`AudienceAmbient`). Amber is STATE here: this is what is on. In Profile a
// tap IS the change; at first run the answer is committed by Continue, so the suggestion the
// library makes can be looked at before it is taken.

struct AudienceChooser: View {
    enum Mode {
        /// The first answer: nothing is applied until Continue, and the sheet cannot be waved away.
        case firstRun
        /// Profile: a tap applies.
        case settings
    }

    let mode: Mode
    var onDone: () -> Void = {}

    @Environment(AppModel.self) private var appModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    /// The card in hand at first run (Profile reads the model's own).
    @State private var picked: Audience?

    private var selection: Audience {
        mode == .settings ? appModel.audience : (picked ?? appModel.suggestedAudience)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ThemeSpace.x5) {
                VStack(alignment: .leading, spacing: ThemeSpace.x2) {
                    Text(Copy.Watching.question)
                        .type(ThemeType.displayXL)
                        .foregroundStyle(ThemeColor.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                    Text(Copy.Watching.lede)
                        .type(ThemeType.body)
                        .foregroundStyle(ThemeColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // x4 apart: the chosen card's ring stands off it into the gap.
                VStack(spacing: ThemeSpace.x4) {
                    ForEach(Audience.allCases, id: \.self) { audience in
                        AudienceCard(audience: audience, selected: selection == audience,
                                     compact: typeSize.isAccessibilitySize) { choose(audience) }
                    }
                }
                Text(mode == .firstRun ? Copy.Watching.changeLater : Copy.Watching.kept)
                    .type(ThemeType.metadata)
                    .foregroundStyle(ThemeColor.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, ThemeMetrics.gutter)
            .padding(.top, ThemeSpace.x8)
            .padding(.bottom, ThemeSpace.x6)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background { AudienceAmbient(audience: selection) }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button(mode == .firstRun ? Copy.Watching.continueWord : Copy.Action.done) { finish() }
                .buttonStyle(PrimaryButtonStyle2())
                .padding(.horizontal, ThemeMetrics.gutter)
                .padding(.top, ThemeSpace.x3)
                .padding(.bottom, ThemeSpace.x4)
        }
        .interactiveDismissDisabled(mode == .firstRun)
        .presentationDragIndicator(mode == .firstRun ? .hidden : .visible)
    }

    private func choose(_ audience: Audience) {
        switch mode {
        case .settings:
            appModel.setAudience(audience)
        case .firstRun:
            guard audience != selection else { return }
            FeedbackCoordinator.fire(.selection)
            withAnimation(ThemeMotion.pick(ThemeMotion.uiSnappy, reduceMotion: reduceMotion)) { picked = audience }
        }
    }

    private func finish() {
        // The first answer is the card in hand — said without a receipt: the app that opens behind
        // the sheet is the confirmation.
        if mode == .firstRun { appModel.setAudience(selection, announce: false) }
        onDone()
    }
}

/// One answer: its picture, its name, what it means — and whether it is the one that is on.
/// First run's opening question draws the same cards (`FirstRunAudienceStep`), taller where the
/// screen has the room.
struct AudienceCard: View {
    let audience: Audience
    let selected: Bool
    /// The accessibility sizes: the picture gives its height to the words.
    var compact = false
    var height: CGFloat = AudienceCard.height
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let height: CGFloat = 132

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: ThemeRadius.card, style: .continuous)
        Button(action: action) {
            ZStack(alignment: .bottomLeading) {
                Color.clear
                    .overlay {
                        Image(Self.art(audience))
                            .resizable()
                            .scaledToFill()
                            // Chosen, the picture settles a breath closer — toward its subject,
                            // which lives on the right.
                            .scaleEffect(selected && !reduceMotion ? 1.06 : 1, anchor: .trailing)
                    }
                    .clipped()
                    // The two not chosen step back — the PICTURE does; their names keep their ink
                    // (all three are still answers). The chosen one has the picture's full light.
                    .overlay(ThemeColor.canvas.opacity(selected ? 0 : 0.30))
                    .accessibilityHidden(true)
                // The name stands on the picture: shade from the reading edge and from the foot,
                // none of it over the subject.
                LinearGradient(stops: [.init(color: .black.opacity(0.70), location: 0),
                                       .init(color: .black.opacity(0.30), location: 0.40),
                                       .init(color: .clear, location: 0.68)],
                               startPoint: .leading, endPoint: .trailing)
                LinearGradient(stops: [.init(color: .clear, location: 0.38),
                                       .init(color: .black.opacity(0.66), location: 1)],
                               startPoint: .top, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 2) {
                    Text(Copy.Watching.name(audience))
                        .type(ThemeType.showTitleL)
                        .foregroundStyle(ThemeColor.textPrimary)
                    Text(Copy.Watching.detail(audience))
                        .type(ThemeType.metadata)
                        .foregroundStyle(ThemeColor.textPrimary.opacity(0.80))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .multilineTextAlignment(.leading)
                .padding(ThemeSpace.x4)
            }
            .frame(maxWidth: .infinity, minHeight: compact ? nil : height,
                   maxHeight: compact ? nil : height, alignment: .bottomLeading)
            .background(ThemeColor.surfaceRaised)
            .clipShape(shape)
            // Lit along its crown, like every raised thing in the app.
            .overlay(shape.strokeBorder(
                LinearGradient(colors: [.white.opacity(0.24), .white.opacity(0.05)],
                               startPoint: .top, endPoint: .bottom), lineWidth: 1))
            .overlay(alignment: .topTrailing) {
                if selected {
                    SelectedBadge(size: 28)
                        .padding(ThemeSpace.x3)
                        .transition(.scale(scale: 0.4).combined(with: .opacity))
                }
            }
            .selectionRing(selected, radius: ThemeRadius.card, gap: 4, width: 3, glow: true)
            .contentShape(shape)
        }
        .buttonStyle(OverArtPressStyle())
        .animation(ThemeMotion.pick(ThemeMotion.uiMilestone, reduceMotion: reduceMotion), value: selected)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(Copy.Watching.name(audience)). \(Copy.Watching.detail(audience))")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    /// The picture made for each answer (asset catalogue; sources in design/onboarding-2026-10-04).
    static func art(_ audience: Audience) -> String {
        switch audience {
        case .anime: "audience-anime-v1"
        case .tv: "audience-tv-v1"
        case .both: "audience-both-v1"
        }
    }
}

/// The screen takes the chosen picture's light: two soft pools at its head in that picture's own
/// colours — a burning sky for anime, rain-lit teal for TV, one of each for both — crossfading as
/// the choice moves. Static gradients on the canvas; nothing is blurred and nothing runs per frame.
struct AudienceAmbient: View {
    let audience: Audience

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The pictures' own lights (read from the art, 4 Oct): the anime sky's crimson and its gold,
    /// the street's teal and its steel blue.
    private static let crimson = Color(hex: 0xC2413F), gold = Color(hex: 0xE08A3A)
    private static let teal = Color(hex: 0x1E8696), steel = Color(hex: 0x2F62AE)

    private var pools: (leading: Color, trailing: Color) {
        switch audience {
        case .anime: (Self.crimson, Self.gold)
        case .tv: (Self.steel, Self.teal)
        case .both: (Self.crimson, Self.teal)
        }
    }

    var body: some View {
        ZStack {
            ThemeColor.canvas
            EllipticalGradient(colors: [pools.leading.opacity(0.30), .clear],
                               center: .init(x: 0.12, y: 0.02), startRadiusFraction: 0, endRadiusFraction: 0.62)
            EllipticalGradient(colors: [pools.trailing.opacity(0.26), .clear],
                               center: .init(x: 0.92, y: 0.10), startRadiusFraction: 0, endRadiusFraction: 0.58)
        }
        .ignoresSafeArea()
        .animation(ThemeMotion.pick(.easeInOut(duration: 0.55), reduceMotion: reduceMotion), value: audience)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
