import SwiftUI

// "Where are you?" — first run's third question, asked once per picked show.
//
// This is the step the trackers get wrong. Added bare, an airing show arrives as "12 EPISODES
// BEHIND" and a long one as a thousand (the reason the show page asks the same thing on an add);
// imported, a history comes back half-marked and is re-ticked by hand (the spike's complaint about
// every TV Time importer). So each show is ONE tap: caught up (every released episode, the
// story's films with it), part-way (the episode, on a dial), just starting, or saved for later.
// The answers are the show page's own (`WatchedBatch`), so the library that results is the one
// the same person would have built there, one show at a time.
//
// One show per screen, on its own colour, its poster the subject. The tapped answer holds its lit
// state for a beat, then the next show arrives; Back returns to the one before, its answer free
// to change — nothing is written until the last one is answered (`FirstRunModel.commit`).

struct FirstRunPlaceStep: View {
    let model: FirstRunModel

    @Environment(AppModel.self) private var appModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize

    /// The answer just tapped, lit for the beat before the next show arrives.
    @State private var lit: Choice?
    /// The part-way dial is up.
    @State private var dialing = false
    @State private var seasonId: Int?
    @State private var episode = 1
    /// Each show's colour, as its poster resolves.
    @State private var tints: [String: Color] = [:]

    enum Choice: Hashable { case caughtUp, partWay, starting, later }

    /// The beat a tapped answer holds before the page turns (the mark controls' own).
    private static let beat: Duration = .milliseconds(260)

    var body: some View {
        ZStack {
            if let show = model.current {
                VStack(spacing: 0) {
                    heading
                    Spacer(minLength: ThemeSpace.x3)
                    card(show)
                        .id(show.id)
                        .transition(cardTransition)
                    Spacer(minLength: ThemeSpace.x3)
                    Group {
                        if dialing {
                            dial(show)
                                .transition(.opacity.combined(with: .offset(y: 12)))
                        } else {
                            answers(show)
                                .transition(.opacity)
                        }
                    }
                    .padding(.horizontal, ThemeMetrics.gutter)
                    .padding(.bottom, ThemeSpace.x3)
                }
            }
        }
        .onChange(of: model.current?.id) { _, _ in
            lit = nil
            dialing = false
        }
        .task(id: model.current?.id) { await resolveTint() }
    }

    // MARK: The ground

    /// The show's colour goes to the flow's ground (`FirstRunGround`, which runs under the bar).
    private func resolveTint() async {
        guard let show = model.current else { return }
        if let known = tints[show.id] {
            model.ambient = known
            return
        }
        guard let url = show.portraitArt else { model.ambient = nil; return }
        let tint = await PaletteCache.shared.resolveIfAvailable(url: url, maxPixel: 420)
        guard model.current?.id == show.id else { return }
        tints[show.id] = tint
        model.ambient = tint
    }

    // MARK: The show

    private var heading: some View {
        VStack(spacing: ThemeSpace.x1) {
            if model.queue.count > 1 {
                Text(Copy.FirstRun.showOf(model.placeIndex + 1, model.queue.count).uppercased())
                    .type(ThemeType.sectionLabel)
                    .foregroundStyle(ThemeColor.textSecondary)
                    .contentTransition(.numericText())
            }
            Text(Copy.FirstRun.placeTitle)
                .type(ThemeType.displayL)
                .foregroundStyle(ThemeColor.textPrimary)
                .accessibilityAddTraits(.isHeader)
        }
        .padding(.top, ThemeSpace.x4)
        .padding(.horizontal, ThemeMetrics.gutter)
    }

    /// The poster takes the height the screen can spare; the name and what is out sit under it.
    private func card(_ show: Franchise) -> some View {
        let width: CGFloat = {
            if typeSize.isAccessibilitySize { return 110 }
            let h = ThemeMetrics.windowHeight
            if dialing { return h < 760 ? 96 : 128 }
            return h < 700 ? 132 : (h < 800 ? 164 : 196)
        }()
        let shape = RoundedRectangle(cornerRadius: ThemeRadius.poster + 2, style: .continuous)
        return VStack(spacing: ThemeSpace.x3) {
            Color.clear
                .frame(width: width, height: width * 1.5)
                .overlay { RemoteImageView(url: show.portraitArt, maxPixel: 640) }
                .clipShape(shape)
                .overlay(shape.strokeBorder(ThemeColor.posterEdge, lineWidth: 1))
                .cardShadow(.artHero, shape: shape)
                .accessibilityHidden(true)
            VStack(spacing: ThemeSpace.x1) {
                Text(show.displayTitle)
                    .type(ThemeType.showTitleL)
                    .foregroundStyle(ThemeColor.textPrimary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                Text(facts(show))
                    .type(ThemeType.heroMeta)
                    .foregroundStyle(ThemeColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(1)
            }
            .padding(.horizontal, ThemeSpace.x8)
            .accessibilityElement(children: .combine)
        }
        .animation(ThemeMotion.pick(ThemeMotion.uiSettle, reduceMotion: reduceMotion), value: dialing)
    }

    private var cardTransition: AnyTransition {
        if reduceMotion { return .opacity }
        let enter: Edge = model.forward ? .trailing : .leading
        let exit: Edge = model.forward ? .leading : .trailing
        return .asymmetric(insertion: .move(edge: enter).combined(with: .opacity),
                           removal: .move(edge: exit).combined(with: .opacity))
    }

    /// "3 seasons · 62 episodes · Airing now" — what is out, which is what the answers are about.
    private func facts(_ show: Franchise) -> String {
        let batch = WatchedBatch(franchise: show, now: appModel.now)
        let seasons = released(show)
        let episodes = seasons.reduce(0) { $0 + $1.markTarget(now: appModel.now) }
        let out = Copy.FirstRun.released(seasons: seasons.count, episodes: episodes, films: batch.filmCount)
        return show.isReleasing ? [out, Copy.FirstRun.airingNow].filter { !$0.isEmpty }.joined(separator: " \u{00B7} ") : out
    }

    /// The story's seasons with something out.
    private func released(_ show: Franchise) -> [FranchisePart] {
        show.seasonPartsInOrder.filter { !$0.isUpcoming && $0.markTarget(now: appModel.now) > 0 }
    }

    // MARK: The answers

    private func choices(_ show: Franchise) -> [Choice] {
        // Part-way needs somewhere to be part-way through: more than one season, or a season of
        // more than two episodes.
        let seasons = released(show)
        let roomy = seasons.count > 1 || (seasons.first?.markTarget(now: appModel.now) ?? 0) > 2
        return roomy ? [.caughtUp, .partWay, .starting, .later] : [.caughtUp, .starting, .later]
    }

    private func answers(_ show: Franchise) -> some View {
        let all = choices(show)
        let stacked = typeSize.isAccessibilitySize
        return Grid(horizontalSpacing: ThemeSpace.x2 + 2, verticalSpacing: ThemeSpace.x2 + 2) {
            if stacked {
                ForEach(all, id: \.self) { choice in GridRow { tile(choice, show) } }
            } else {
                GridRow {
                    tile(all[0], show)
                    tile(all[1], show)
                }
                GridRow {
                    if all.count > 3 {
                        tile(all[2], show)
                        tile(all[3], show)
                    } else {
                        tile(all[2], show).gridCellColumns(2)
                    }
                }
            }
        }
        // A tapped answer is the screen's last word until the next show arrives.
        .allowsHitTesting(lit == nil)
    }

    private func tile(_ choice: Choice, _ show: Franchise) -> some View {
        let on = lit == choice || (lit == nil && isAnswered(choice, show))
        let shape = RoundedRectangle(cornerRadius: ThemeRadius.row, style: .continuous)
        return Button { tap(choice, show) } label: {
            HStack(spacing: ThemeSpace.x3) {
                AppGlyph(systemName: glyph(choice), decorative: true)
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(on ? ThemeColor.onAccent : ThemeColor.textPrimary)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title(choice, show))
                        .type(ThemeType.cardFact)
                        .foregroundStyle(on ? ThemeColor.onAccent : ThemeColor.textPrimary)
                    Text(detail(choice, show))
                        .type(ThemeType.metadata)
                        .foregroundStyle(on ? ThemeColor.onAccent.opacity(0.72) : ThemeColor.textSecondary)
                }
                .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
                .minimumScaleFactor(0.85)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, ThemeSpace.x3 + 2)
            .frame(maxWidth: .infinity, minHeight: 62, alignment: .leading)
            // Translucent white, so the tile takes the show's colour through it (the secondary
            // button's ground); lit, it is the amber of a committed mark.
            .background(on ? AnyShapeStyle(ThemeGradient.accent) : AnyShapeStyle(ThemeColor.textPrimary.opacity(0.10)),
                        in: shape)
            // Lit along its crown: a tile is an object too.
            .overlay(shape.strokeBorder(
                LinearGradient(colors: [.white.opacity(on ? 0.45 : 0.16), .white.opacity(on ? 0 : 0.04)],
                               startPoint: .top, endPoint: .bottom), lineWidth: 1))
            .contentShape(shape)
        }
        .buttonStyle(OverArtPressStyle())
        .animation(ThemeMotion.pick(ThemeMotion.uiMicro, reduceMotion: reduceMotion), value: on)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    }

    /// Back on a show already answered: its answer is the lit one.
    private func isAnswered(_ choice: Choice, _ show: Franchise) -> Bool {
        switch (model.placements[show.id], choice) {
        case (.caughtUp, .caughtUp), (.partWay, .partWay), (.starting, .starting), (.later, .later): true
        default: false
        }
    }

    private func glyph(_ choice: Choice) -> String {
        switch choice {
        case .caughtUp: "checkmark.circle"
        case .partWay: "pause.circle"
        case .starting: "play.circle"
        case .later: "bookmark"
        }
    }

    private func title(_ choice: Choice, _ show: Franchise) -> String {
        switch choice {
        case .caughtUp: show.isReleasing ? Copy.FirstRun.caughtUp : Copy.FirstRun.seenItAll
        case .partWay: Copy.FirstRun.partWay
        case .starting: Copy.FirstRun.starting
        case .later: Copy.FirstRun.later
        }
    }

    private func detail(_ choice: Choice, _ show: Franchise) -> String {
        switch choice {
        case .caughtUp:
            let batch = WatchedBatch(franchise: show, now: appModel.now)
            return batch.episodeCount > 0 ? Copy.FirstRun.caughtUpDetail(batch.episodeCount)
                                          : Copy.plural(batch.filmCount, "film", "films")
        case .partWay: return Copy.FirstRun.partWayDetail
        case .starting: return Copy.FirstRun.startingDetail
        case .later: return Copy.FirstRun.laterDetail
        }
    }

    private func tap(_ choice: Choice, _ show: Franchise) {
        if choice == .partWay {
            openDial(show)
            return
        }
        FeedbackCoordinator.fire(.selection)
        lit = choice
        let placement: FirstRunPlacement = switch choice {
        case .caughtUp: .caughtUp
        case .starting: .starting
        case .later: .later
        case .partWay: .starting
        }
        Task {
            try? await Task.sleep(for: Self.beat)
            model.answer(placement)
        }
    }

    // MARK: Part-way

    private func openDial(_ show: Franchise) {
        let seasons = released(show)
        // Where a part-way viewer most likely is: an airing show's current season, a finished
        // show's first. A previous answer is where the dial reopens.
        if case .partWay(let id, let n) = model.placements[show.id], seasons.contains(where: { $0.mediaId == id }) {
            seasonId = id
            episode = n
        } else {
            let season = show.isReleasing ? (seasons.last ?? seasons.first) : seasons.first
            seasonId = season?.mediaId
            let out = season?.markTarget(now: appModel.now) ?? 1
            episode = show.isReleasing ? max(1, out - 1) : 1
        }
        FeedbackCoordinator.fire(.selection)
        withAnimation(ThemeMotion.pick(ThemeMotion.uiSettle, reduceMotion: reduceMotion)) { dialing = true }
    }

    private func dial(_ show: Franchise) -> some View {
        let seasons = released(show)
        let season = seasons.first { $0.mediaId == seasonId } ?? seasons.first
        let count = max(1, season?.markTarget(now: appModel.now) ?? 1)
        return VStack(spacing: ThemeSpace.x3) {
            Text(Copy.FirstRun.lastWatched.uppercased())
                .type(ThemeType.sectionLabel)
                .foregroundStyle(ThemeColor.textSecondary)
            if seasons.count > 1 {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: ThemeSpace.x2) {
                            ForEach(seasons, id: \.mediaId) { part in
                                Button(part.canonicalLabel.isEmpty ? part.title : Copy.compactPartLabel(part.canonicalLabel)) {
                                    guard seasonId != part.mediaId else { return }
                                    FeedbackCoordinator.fire(.selection)
                                    seasonId = part.mediaId
                                    episode = min(episode, max(1, part.markTarget(now: appModel.now)))
                                }
                                .buttonStyle(ChipButtonStyle(selected: part.mediaId == season?.mediaId))
                                .id(part.mediaId)
                            }
                        }
                        .padding(.horizontal, ThemeMetrics.gutter)
                    }
                    .padding(.horizontal, -ThemeMetrics.gutter)
                    .onAppear { if let id = season?.mediaId { proxy.scrollTo(id, anchor: .center) } }
                }
            }
            EpisodeDial(value: $episode, count: count)
                .id(season?.mediaId)
            HStack(spacing: ThemeSpace.x2 + 2) {
                Button(Copy.Action.back) {
                    withAnimation(ThemeMotion.pick(ThemeMotion.uiSettle, reduceMotion: reduceMotion)) { dialing = false }
                }
                .buttonStyle(SecondaryButtonStyle2())
                .frame(maxWidth: 120)
                Button(Copy.FirstRun.done) {
                    guard let season else { return }
                    FeedbackCoordinator.fire(.selection)
                    model.answer(.partWay(seasonId: season.mediaId, episode: min(episode, count)))
                }
                .buttonStyle(PrimaryButtonStyle2())
            }
            .padding(.top, ThemeSpace.x1)
        }
    }
}

/// A ruler of episodes under a fixed needle: drag it, and the number over it is where you are.
/// One tick per episode, a longer one and its number every fifth; each tick is a detent, felt.
/// VoiceOver adjusts it a step at a time.
struct EpisodeDial: View {
    @Binding var value: Int
    let count: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var position: Int?

    private static let tick: CGFloat = 14
    private static let height: CGFloat = 46

    var body: some View {
        VStack(spacing: ThemeSpace.x2) {
            HStack(alignment: .firstTextBaseline, spacing: ThemeSpace.x2) {
                Text(Copy.episode(value))
                    .type(ThemeType.displayL)
                    .foregroundStyle(ThemeColor.textPrimary)
                    .contentTransition(.numericText(value: Double(value)))
                Text("of \(count.formatted(.number))")
                    .type(ThemeType.heroMeta)
                    .foregroundStyle(ThemeColor.textSecondary)
            }
            .animation(ThemeMotion.pick(ThemeMotion.uiNumeric, reduceMotion: reduceMotion), value: value)
            GeometryReader { geo in
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .top, spacing: 0) {
                            ForEach(1...count, id: \.self) { n in
                                let major = n == 1 || n % 5 == 0 || n == count
                                VStack(spacing: 5) {
                                    Capsule()
                                        .fill(ThemeColor.textPrimary.opacity(major ? 0.72 : 0.30))
                                        .frame(width: 2, height: major ? 20 : 11)
                                    if major {
                                        Text("\(n)")
                                            .font(.system(.caption2, weight: .medium).monospacedDigit())
                                            .foregroundStyle(ThemeColor.textTertiary)
                                            .fixedSize()
                                    }
                                }
                                .frame(width: Self.tick, height: Self.height, alignment: .top)
                                .id(n)
                            }
                        }
                        .scrollTargetLayout()
                    }
                    .contentMargins(.horizontal, max(0, (geo.size.width - Self.tick) / 2), for: .scrollContent)
                    .scrollTargetBehavior(.viewAligned)
                    .scrollPosition(id: $position, anchor: .center)
                    .onAppear {
                        position = value
                        // `scrollPosition(id:)` does not place a lazy row on its first layout.
                        DispatchQueue.main.async { proxy.scrollTo(value, anchor: .center) }
                    }
                }
            }
            .frame(height: Self.height)
            // The needle: the one accent on the control — it marks where you are.
            .overlay(alignment: .top) {
                Capsule().fill(ThemeColor.accent)
                    .frame(width: 3, height: 28)
                    .offset(y: -4)
                    .allowsHitTesting(false)
            }
            // The ruler runs out at the edges rather than ending on them.
            .mask {
                LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.16),
                                       .init(color: .black, location: 0.84), .init(color: .clear, location: 1)],
                               startPoint: .leading, endPoint: .trailing)
            }
        }
        .onChange(of: position) { _, new in
            guard let new, new != value, (1...count).contains(new) else { return }
            value = new
            FeedbackCoordinator.fire(.selection)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Copy.FirstRun.lastWatched)
        .accessibilityValue(Copy.FirstRun.dialValue(value, of: count))
        .accessibilityAdjustableAction { direction in
            let next = direction == .increment ? min(count, value + 1) : max(1, value - 1)
            guard next != value else { return }
            value = next
            position = next
        }
    }
}
