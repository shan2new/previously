import SwiftUI
import UserNotifications

// "Here's what's next" — first run's last screen: the viewer's own shows on the board.
//
// The brand is "P." on a departures board — what arrives next — and this is the one screen where
// the board is literal: each picked show with the next thing that happens to it, the WHEN on a
// split-flap that turns to its value as the row arrives (`SplitFlap`). What is out is first, then
// what airs soonest; a show saved for later or already finished closes the list. It is the payoff
// said before the app opens: the answers just given, already arranged into a schedule.
//
// ALERTS ARE OFFERED HERE, NOT ASKED FOR. The system's permission alert follows a tap on "Turn on"
// and nothing else (the app's rule since the Search primer; Apple's guidance is to ask after an
// action that shows why). The line names the show whose next episode it would announce, and exists
// only when there is one: a Watching anime with a timed airing ahead, and permission not yet
// answered. Go to Home is always there, beside it, and works whatever was tapped.

struct FirstRunLineupStep: View {
    let model: FirstRunModel
    var onDone: () -> Void

    @Environment(AppModel.self) private var appModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize

    /// The rows rise in once.
    @State private var arrived = false
    /// Notification permission, as the system has it (nil until read).
    @State private var alerts: UNAuthorizationStatus?
    @State private var asking = false

    private static let limit = 5

    var body: some View {
        let rows = model.lineup(now: appModel.nowMinute)
        let shown = Array(rows.prefix(Self.limit))
        // Something to wait for or to watch: the board. Every pick shelved or finished: said plainly.
        let lively = rows.contains { row in
            switch row.when {
            case .now, .at: true
            case .later, .done: false
            }
        }
        ScrollView {
            VStack(alignment: .leading, spacing: ThemeSpace.x5) {
                FirstRunHeading(title: lively ? Copy.FirstRun.lineupTitle : Copy.FirstRun.lineupQuietTitle,
                                lede: lively ? Copy.FirstRun.lineupLede : Copy.FirstRun.lineupQuietLede)
                VStack(spacing: ThemeSpace.x4) {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, row in
                        LineupRowView(row: row, now: appModel.nowMinute, index: index)
                            .opacity(arrived ? 1 : 0)
                            .offset(y: arrived || reduceMotion ? 0 : 14)
                            .animation(ThemeMotion.pick(ThemeMotion.uiSettle, reduceMotion: reduceMotion)
                                .delay(reduceMotion ? 0 : Double(index) * 0.07), value: arrived)
                    }
                    if rows.count > shown.count {
                        Text(Copy.FirstRun.more(rows.count - shown.count))
                            .type(ThemeType.metadata)
                            .foregroundStyle(ThemeColor.textTertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .opacity(arrived ? 1 : 0)
                    }
                }
                if alerts == .notDetermined || alerts == .authorized, let show = model.alertShow(now: appModel.nowMinute) {
                    alertsLine(show)
                        .opacity(arrived ? 1 : 0)
                        .animation(ThemeMotion.pick(ThemeMotion.uiSettle, reduceMotion: reduceMotion)
                            .delay(reduceMotion ? 0 : Double(shown.count) * 0.07 + 0.1), value: arrived)
                }
            }
            .padding(.horizontal, ThemeMetrics.gutter)
            .padding(.top, ThemeSpace.x5)
            .padding(.bottom, ThemeSpace.x6)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            FirstRunFoot {
                Button {
                    Task {
                        await model.leave()
                        onDone()
                    }
                } label: {
                    ZStack {
                        Text(Copy.FirstRun.goHome).opacity(model.leaving ? 0 : 1)
                        if model.leaving { ProgressView().tint(ThemeColor.onAccent) }
                    }
                }
                .buttonStyle(PrimaryButtonStyle2())
                .disabled(model.leaving)
            }
        }
        .task {
            let status = await EpisodeNotifications.shared.authorizationStatus()
            // Already allowed before first run (a reinstall): nothing to offer, nothing to say.
            alerts = status == .authorized ? nil : status
            try? await Task.sleep(for: .milliseconds(120))
            arrived = true
        }
    }

    /// The offer: the bell, what it would do for THIS viewer, and the tap that turns it on.
    private func alertsLine(_ show: Franchise) -> some View {
        let on = alerts == .authorized
        return HStack(spacing: ThemeSpace.x3) {
            Image("first-run-alert-bell-v1")
                .resizable()
                .scaledToFit()
                .frame(width: 44, height: 44)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(on ? Copy.FirstRun.alertsOn : Copy.Search.primerTitle)
                    .type(ThemeType.cardFact)
                    .foregroundStyle(ThemeColor.textPrimary)
                if !on {
                    Text(Copy.FirstRun.alertsBody(show.displayTitle))
                        .type(ThemeType.metadata)
                        .foregroundStyle(ThemeColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: ThemeSpace.x2)
            if on {
                SelectedBadge(size: 28)
                    .transition(.scale(scale: 0.5).combined(with: .opacity))
            } else {
                Button(Copy.Search.primerTurnOn) { turnOn() }
                    .buttonStyle(SecondaryButtonStyle2())
                    .fixedSize()
                    .disabled(asking)
            }
        }
        .padding(ThemeSpace.x3 + 2)
        .background(ThemeColor.surfaceFlat, in: RoundedRectangle(cornerRadius: ThemeRadius.row, style: .continuous))
        .animation(ThemeMotion.pick(ThemeMotion.uiMilestone, reduceMotion: reduceMotion), value: on)
        .accessibilityElement(children: .contain)
    }

    private func turnOn() {
        asking = true
        Task {
            let granted = await EpisodeNotifications.shared.requestPermissionIfNeeded()
            asking = false
            if granted {
                FeedbackCoordinator.fire(.success)
                alerts = .authorized
                Announce.status(Copy.FirstRun.alertsOn)
                // Armed now, from the library already in hand — not at the next reload.
                await appModel.alertsWereAllowed()
            } else {
                // Declined: the line leaves. Profile › Notifications keeps the way back.
                withAnimation(ThemeMotion.pick(ThemeMotion.uiGentle, reduceMotion: reduceMotion)) { alerts = .denied }
            }
        }
    }
}

/// One show on the board: when (the flap), whose (its face), what.
private struct LineupRowView: View {
    let row: FirstRunModel.LineupRow
    let now: Int64
    let index: Int

    private static let flap = CGSize(width: 58, height: 54)

    var body: some View {
        HStack(spacing: ThemeSpace.x3) {
            SplitFlap(value: face, size: Self.flap, arrives: true, delay: 0.28 + Double(index) * 0.14) { face in
                FlapFace(face: face, size: Self.flap)
            }
            .accessibilityHidden(true)
            // The poster the picker and the question showed — in hand already, so the row is whole
            // when it arrives (a face crop takes seconds to find on a first visit).
            Thumb(cover: row.franchise.portraitArt, width: 36, height: Self.flap.height, radius: 6)
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(ThemeColor.posterEdge, lineWidth: 1))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                // Budgeted like a shelf's caption: "Demon Slayer", not "Demon Slayer: Kimetsu no…".
                Text(row.franchise.title.shelfShortened(fitting: 24))
                    .type(ThemeType.rowTitle)
                    .foregroundStyle(ThemeColor.textPrimary)
                    .lineLimit(1)
                Text(row.detail)
                    .type(ThemeType.rowMeta)
                    .foregroundStyle(ThemeColor.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(row.franchise.title). \(spoken)")
    }

    /// The flap's two lines: the day over the time, or a word over its sign.
    private var face: FlapFace.Value {
        let source = row.franchise.source
        let anchor = source.timeAnchor
        switch row.when {
        case .now:
            return .init(top: Copy.FirstRun.now, bottom: nil, glyph: "play.fill", lit: true)
        case .later:
            return .init(top: Copy.FirstRun.laterWord, bottom: nil, glyph: "bookmark", lit: false)
        case .done:
            return .init(top: Copy.FirstRun.doneWord, bottom: nil, glyph: "checkmark", lit: false)
        case .at(let ts):
            let days = Formatting.dayDiff(ts: ts, now: now, anchor: anchor)
            // Inside the week: the weekday over the clock (a date-only release has no clock —
            // its day of the month instead). Further out: the month over the day.
            if days <= 6 {
                let day = days == 0 ? "Today" : Formatting.formatted(ts, skeleton: "EEE", anchor: anchor)
                let under = source == .anilist ? Formatting.fmtTime(ts, anchor: anchor)
                                               : Formatting.formatted(ts, skeleton: "dMMM", anchor: anchor)
                return .init(top: day, bottom: under, glyph: nil, lit: true)
            }
            return .init(top: Formatting.formatted(ts, skeleton: "MMM", anchor: anchor),
                         bottom: Formatting.formatted(ts, skeleton: "d", anchor: anchor), glyph: nil, lit: true)
        }
    }

    private var spoken: String {
        switch row.when {
        case .now: "\(row.detail), \(Copy.Schedule.outNow)"
        case .at(let ts): "\(row.detail), \(TemporalCopy.airsSentence(at: ts, now: now, source: row.franchise.source))"
        case .later, .done: row.detail
        }
    }
}

/// What a lineup flap prints: a word (or day) on the top half, a time or a sign on the bottom —
/// one line per half, so the seam cuts nothing.
private struct FlapFace: View {
    struct Value: Hashable {
        let top: String
        let bottom: String?
        let glyph: String?
        /// A real next step (out now, or a time ahead) wears the accent; a settled word is quiet.
        let lit: Bool
    }

    let face: Value
    let size: CGSize

    var body: some View {
        VStack(spacing: 0) {
            Text(face.top.uppercased())
                .font(.system(size: 10.5, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(face.lit ? ThemeColor.accent : ThemeColor.textSecondary)
                .frame(width: size.width, height: size.height / 2)
            Group {
                if let glyph = face.glyph {
                    AppGlyph(systemName: glyph, decorative: true)
                        .font(.system(size: 13, weight: .semibold))
                } else {
                    Text(face.bottom ?? "")
                        .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                }
            }
            .foregroundStyle(FlapGeometry.ink.opacity(face.lit ? 1 : 0.6))
            .frame(width: size.width, height: size.height / 2)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }
}
