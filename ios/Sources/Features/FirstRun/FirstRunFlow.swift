import SwiftUI

// First run, on screen: four questions, one per screen, then Home (the why is in
// `AppModel+FirstRun.swift`; the state in `FirstRunModel`).
//
// The frame every step shares is the bar — back, how far along, Skip where skipping is honest —
// over the question, with the step's one action at the foot. A step arrives from the side it is
// going to (forward from the right, Back from the left); under Reduce Motion it fades.
//
// Two ways in: a new account's whole run (`.account`, in place of the app until it is done), and
// the picker alone (`.shows`, a cover over the app — the empty Home's button), which starts at the
// second question and closes with an ×.

struct FirstRunFlow: View {
    /// The lineup is up: the caller may build Home beneath the flow, so leaving has nothing to
    /// wait for.
    var onLineup: () -> Void = {}
    /// Over — finished, or left with nothing picked.
    var onFinished: () -> Void

    @State private var model: FirstRunModel
    /// A step is still arriving: it takes no taps yet. Each step's action sits where the last
    /// one's did, so the second tap of a double-tap on "Continue" landed on the next screen's
    /// "Skip for now" and ended the run with nothing picked.
    @State private var settling = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(appModel: AppModel, entry: FirstRunModel.Entry,
         onLineup: @escaping () -> Void = {}, onFinished: @escaping () -> Void) {
        _model = State(initialValue: FirstRunModel(appModel: appModel, entry: entry))
        self.onLineup = onLineup
        self.onFinished = onFinished
    }

    var body: some View {
        VStack(spacing: 0) {
            FirstRunBar(model: model, onClose: model.entry == .shows ? onFinished : nil)
            ZStack {
                switch model.step {
                case .audience:
                    FirstRunAudienceStep(model: model)
                        .transition(stepTransition)
                case .shows:
                    FirstRunShowsStep(model: model, onLeave: onFinished)
                        .transition(stepTransition)
                case .place:
                    FirstRunPlaceStep(model: model)
                        .transition(stepTransition)
                case .lineup:
                    FirstRunLineupStep(model: model, onDone: onFinished)
                        .transition(stepTransition)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(!settling)
        }
        .background {
            ZStack {
                FirstRunGround(tint: model.step == .place ? model.ambient : nil)
                // The first question sits in the chosen picture's light.
                if model.step == .audience {
                    AudienceAmbient(audience: model.audienceChoice)
                        .transition(.opacity)
                }
            }
            .animation(ThemeMotion.pick(.easeInOut(duration: 0.4), reduceMotion: reduceMotion), value: model.step)
        }
        .tint(ThemeColor.interactive)
        .task {
            // Opened on the picker (a resumed run, or the empty Home's button): its lists.
            if model.step == .shows { await model.prepareLists() }
            #if DEBUG
            await capture()
            #endif
        }
        .onChange(of: model.step) { _, step in
            if step == .lineup { onLineup() }
            Announce.screenChanged()
            settling = true
        }
        .task(id: model.step) {
            // As long as the step takes to arrive, and a beat: then it is the reader's.
            try? await Task.sleep(for: .milliseconds(600))
            settling = false
        }
    }

    #if DEBUG
    /// Capture flags, for a simulator that cannot be touched: `-firstRunPick N` picks the list's
    /// first N; `-firstRunAdvance place` goes on to the questions (nothing is written there);
    /// `-firstRunAdvance lineup` answers them all "Just starting" and reaches the lineup — which
    /// WRITES the picks, so it runs against a local backend only.
    private func capture() async {
        let n = UserDefaults.standard.integer(forKey: "firstRunPick")
        guard n > 0, model.step == .shows else { return }
        model.pickFirst(n)
        guard let advance = UserDefaults.standard.string(forKey: "firstRunAdvance") else { return }
        try? await Task.sleep(for: .seconds(2))
        await model.continueFromShows()
        guard advance == "lineup", AppConfig.isLocalBackend else { return }
        while model.step == .place {
            try? await Task.sleep(for: .milliseconds(700))
            model.answer(.starting)
        }
    }
    #endif

    private var stepTransition: AnyTransition {
        if reduceMotion { return .opacity }
        let enter: Edge = model.forward ? .trailing : .leading
        let exit: Edge = model.forward ? .leading : .trailing
        return .asymmetric(insertion: .move(edge: enter).combined(with: .opacity),
                           removal: .move(edge: exit).combined(with: .opacity))
    }
}

/// The flow's bar: Back (or × on the picker-only run), the progress, Skip.
private struct FirstRunBar: View {
    let model: FirstRunModel
    var onClose: (() -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let slot: CGFloat = 52

    var body: some View {
        HStack(spacing: ThemeSpace.x2) {
            Color.clear
                .frame(width: Self.slot, height: 44)
                .overlay(alignment: .leading) { leading }
            ProgressBar(value: model.progress,
                        spoken: Copy.FirstRun.step((model.steps.firstIndex(of: model.step) ?? 0) + 1,
                                                   of: model.steps.count))
                .animation(ThemeMotion.pick(ThemeMotion.uiSettle, reduceMotion: reduceMotion), value: model.progress)
            // At least the slot; wider when Skip is (the accessibility sizes), never truncated.
            ZStack(alignment: .trailing) {
                Color.clear.frame(width: Self.slot, height: 44)
                trailing.fixedSize()
            }
        }
        .padding(.horizontal, ThemeMetrics.gutter)
        .padding(.top, ThemeSpace.x1)
    }

    @ViewBuilder private var leading: some View {
        if model.canGoBack {
            Button { model.back() } label: {
                AppGlyph(systemName: "arrow.left", decorative: true)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(ThemeColor.interactive)
                    .frame(width: 44, height: 44, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(Copy.Action.back)
            .transition(.opacity)
        } else if let onClose, model.step == .shows {
            Button(action: onClose) {
                AppGlyph(systemName: "xmark", decorative: true)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(ThemeColor.interactive)
                    .frame(width: 44, height: 44, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(Copy.FirstRun.close)
        }
    }

    @ViewBuilder private var trailing: some View {
        // Skipping is offered where it is honest: the questions about each show can be left
        // unasked (the shows are still added). The picker's own way out is its button.
        if model.step == .place {
            Button(Copy.FirstRun.skip) { model.skipRest() }
                .buttonStyle(TertiaryButtonStyle2())
                .transition(.opacity)
        }
    }
}

/// The flow's ground: canvas — and, while a show is being asked about, that show's own colour at
/// the show page's depth, easing to canvas, with one faint pool of it behind the poster. Drawn by
/// the flow rather than the step, so the colour runs under the bar (the step sits below it, and a
/// ground of its own ended on a straight edge at the bar's foot).
private struct FirstRunGround: View {
    let tint: Color?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            ThemeColor.canvas
            if let tint {
                LinearGradient(colors: [DetailTint.ground(tint, lightness: 0.21), ThemeColor.canvas],
                               startPoint: .top, endPoint: .bottom)
                    .transition(.opacity)
                EllipticalGradient(colors: [tint.opacity(0.22), .clear], center: .init(x: 0.5, y: 0.38),
                                   startRadiusFraction: 0, endRadiusFraction: 0.62)
                    .blendMode(.plusLighter)
                    .transition(.opacity)
            }
        }
        .ignoresSafeArea()
        .animation(ThemeMotion.pick(.easeInOut(duration: 0.45), reduceMotion: reduceMotion), value: tint)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Signed in, and not yet known to be a new account or a returning one: the brand holds — never
/// an empty Home that a moment later turns into a questionnaire.
///
/// Where it holds depends on where the viewer came from, so nothing jumps: straight from the gate
/// (they just signed in) it is the gate itself with its button gone; at a launch it is the launch's
/// own lockup, where the film left the mark.
struct FirstRunHold: View {
    /// The gate was on screen a moment ago.
    var fromGate = false

    var body: some View {
        Group {
            if fromGate {
                SignInView(holding: true)
            } else {
                GeometryReader { geo in
                    let frame = LaunchLockup.markFrame(in: geo.size, signedIn: true)
                    ZStack {
                        LaunchLockup.Bloom()
                            .position(x: frame.midX, y: frame.midY)
                        LaunchLockup.mark
                            .position(x: frame.midX, y: frame.midY)
                        LaunchLockup.name
                            .position(x: geo.size.width / 2, y: frame.maxY + LaunchLockup.nameGap + 20)
                    }
                }
                .ignoresSafeArea()
                .background(ThemeColor.canvas.ignoresSafeArea())
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - What do you watch?

/// The first question, with Profile's own cards (`AudienceCard`): the picture of each answer.
struct FirstRunAudienceStep: View {
    let model: FirstRunModel

    @Environment(AppModel.self) private var appModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    private var selection: Audience { model.audienceChoice }

    /// The three cards share the room the screen has under the question and over the button, so
    /// all three answers are on screen at once on every phone (an SE drew the third under the
    /// button): shorter than Profile's 132 on a small one, taller on a tall one.
    private func cardHeight(in height: CGFloat) -> CGFloat {
        let room = height - 280          // the question, the gaps, the foot
        return min(176, max(100, (room / 3).rounded(.down)))
    }

    var body: some View {
        GeometryReader { geo in
            content(cardHeight: cardHeight(in: geo.size.height))
        }
    }

    private func content(cardHeight: CGFloat) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ThemeSpace.x5) {
                FirstRunHeading(title: Copy.Watching.question, lede: Copy.FirstRun.audienceLede)
                // x4 apart: the chosen card's ring stands off it into the gap.
                VStack(spacing: ThemeSpace.x4) {
                    ForEach(Audience.allCases, id: \.self) { audience in
                        AudienceCard(audience: audience, selected: selection == audience,
                                     compact: typeSize.isAccessibilitySize, height: cardHeight) {
                            guard audience != selection else { return }
                            FeedbackCoordinator.fire(.selection)
                            withAnimation(ThemeMotion.pick(ThemeMotion.uiSnappy, reduceMotion: reduceMotion)) {
                                model.audienceChoice = audience
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, ThemeMetrics.gutter)
            .padding(.top, ThemeSpace.x5)
            .padding(.bottom, ThemeSpace.x6)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            FirstRunFoot {
                Button(Copy.FirstRun.continueWord) { model.chose(selection) }
                    .buttonStyle(PrimaryButtonStyle2())
            }
        }
    }
}

// MARK: - Shared pieces

/// A step's question and the one sentence under it.
struct FirstRunHeading: View {
    let title: String
    var lede: String?

    var body: some View {
        VStack(alignment: .leading, spacing: ThemeSpace.x2) {
            Text(title)
                .type(ThemeType.displayXL)
                .foregroundStyle(ThemeColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            if let lede {
                Text(lede)
                    .type(ThemeType.body)
                    .foregroundStyle(ThemeColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A step's foot: its action on the gutter, over a ground that eases out of the content above
/// it (the list scrolls under the button, never behind a hard edge).
struct FirstRunFoot<Content: View>: View {
    var ground: Color = ThemeColor.canvas
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: ThemeSpace.x1) { content() }
            .padding(.horizontal, ThemeMetrics.gutter)
            .padding(.top, ThemeSpace.x3)
            .padding(.bottom, ThemeSpace.x3)
            .frame(maxWidth: .infinity)
            .background {
                VStack(spacing: 0) {
                    LinearGradient(colors: [ground.opacity(0), ground], startPoint: .top, endPoint: .bottom)
                        .frame(height: 28)
                        .offset(y: -28)
                        .frame(height: 0, alignment: .top)
                    ground
                }
                .ignoresSafeArea(edges: .bottom)
                .allowsHitTesting(false)
            }
    }
}
