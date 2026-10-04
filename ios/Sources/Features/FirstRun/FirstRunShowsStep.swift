import SwiftUI

// "Pick your shows" — first run's second question, and the screen the empty Home opens.
//
// A wall of posters to tap, because a new account's library should be built by recognising, not
// by typing: the catalogue's best-known shows first (`GET /franchises/starter` — the season's chart
// held titles a newcomer had never heard of), what is airing now, then the genres; the field finds
// anything else. A tap picks (the poster is ringed, its check drawn); a second tap takes it back.
//
// NOTHING IS REQUIRED. The spike's one consistent complaint about pickers was a forced minimum
// (Hobi's three shows); with none picked the foot says "Skip for now" and the app opens.

struct FirstRunShowsStep: View {
    let model: FirstRunModel
    /// Out to the app with nothing picked.
    var onLeave: () -> Void

    @Environment(AppModel.self) private var appModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @FocusState private var fieldFocused: Bool

    private static let columnGap: CGFloat = ThemeSpace.x3
    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: Self.columnGap, alignment: .top),
              count: typeSize.isAccessibilitySize ? 2 : 3)
    }

    private var state: FirstRunModel.ListState { model.lists[model.list] ?? .init() }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                FirstRunHeading(title: Copy.FirstRun.showsTitle, lede: Copy.FirstRun.showsLede)
                    .padding(.horizontal, ThemeMetrics.gutter)
                    .padding(.top, ThemeSpace.x5)
                    .padding(.bottom, ThemeSpace.x2)
                Section {
                    content
                        .padding(.horizontal, ThemeMetrics.gutter)
                        .padding(.top, ThemeSpace.x2)
                        .padding(.bottom, ThemeSpace.x8)
                } header: {
                    controls
                }
            }
        }
        .scrollDismissesKeyboard(.immediately)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // With nothing picked the foot is only the way out — not offered over the keyboard
            // (it sat on the results), nor on the picker-only run (its × is the way out).
            if !(model.picks.isEmpty && (fieldFocused || model.entry == .shows)) { foot }
        }
    }

    // MARK: The field and the lists

    /// The field, then the lists' chips — pinned, on the canvas, so the wall scrolls under them.
    private var controls: some View {
        VStack(spacing: ThemeSpace.x1) {
            field
                .padding(.horizontal, ThemeMetrics.gutter)
            if !model.searchingText {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: ThemeSpace.x2) {
                        chip(Copy.FirstRun.popular, .popular)
                        chip(Copy.FirstRun.airing, .airing)
                        ForEach(model.genres) { genre in chip(genre.name, .genre(genre.key)) }
                    }
                    .padding(.horizontal, ThemeMetrics.gutter)
                }
                .transition(.opacity)
            }
        }
        .padding(.top, ThemeSpace.x2)
        .padding(.bottom, ThemeSpace.x1)
        .background(ThemeColor.canvas)
        .animation(ThemeMotion.pick(ThemeMotion.uiGentle, reduceMotion: reduceMotion), value: model.searchingText)
    }

    private var field: some View {
        @Bindable var model = model
        return HStack(spacing: ThemeSpace.x2) {
            AppGlyph(systemName: "magnifyingglass", decorative: true)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(ThemeColor.textTertiary)
            TextField("", text: $model.query,
                      prompt: Text(Copy.Search.prompt(for: appModel.audience.filter))
                        .foregroundStyle(ThemeColor.textTertiary))
                .type(ThemeType.body)
                .foregroundStyle(ThemeColor.textPrimary)
                .tint(ThemeColor.interactive)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($fieldFocused)
            if !model.query.isEmpty {
                Button { model.query = "" } label: {
                    AppGlyph(systemName: "xmark.circle.fill", decorative: true)
                        .font(.system(size: 17))
                        .foregroundStyle(ThemeColor.textTertiary)
                        .frame(width: 32, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(Copy.Action.clear)
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, model.query.isEmpty ? 14 : 4)
        .frame(minHeight: 44)
        .background(ThemeColor.surfaceRaised, in: Capsule())
        .contentShape(Capsule())
        .onTapGesture { fieldFocused = true }
    }

    private func chip(_ name: String, _ key: FirstRunModel.ListKey) -> some View {
        Button(name) {
            guard model.list != key else { return }
            FeedbackCoordinator.fire(.selection)
            model.list = key
        }
        .buttonStyle(ChipButtonStyle(selected: model.list == key))
        .accessibilityAddTraits(model.list == key ? .isSelected : [])
    }

    // MARK: The wall

    @ViewBuilder private var content: some View {
        if model.searchingText {
            if model.searching && model.results.isEmpty {
                skeleton
            } else if model.results.isEmpty {
                EmptyState(model.searchFailed ? .searchFailed : .noSearchResults(query: model.query),
                           prominence: .section)
                    .padding(.top, ThemeSpace.x10)
            } else {
                wall(model.results)
            }
        } else if state.items.isEmpty && state.failed {
            InlineNotice(Copy.FirstRun.couldNotLoad) { Task { await model.load(model.list, force: true) } }
                .padding(.top, ThemeSpace.x6)
        } else if state.items.isEmpty {
            skeleton
        } else {
            wall(state.items)
        }
    }

    private func wall(_ items: [FranchiseSummary]) -> some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: ThemeSpace.x4) {
            ForEach(items) { item in
                FirstRunPosterTile(item: item, picked: model.isPicked(item.id)) { model.toggle(item) }
                    .equatable()
            }
        }
    }

    private var skeleton: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: ThemeSpace.x4) {
            ForEach(0..<12, id: \.self) { _ in
                VStack(alignment: .leading, spacing: ThemeSpace.x2) {
                    RoundedRectangle(cornerRadius: ThemeRadius.poster, style: .continuous)
                        .fill(ThemeColor.skeleton)
                        .aspectRatio(2 / 3, contentMode: .fit)
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(ThemeColor.skeleton)
                        .frame(height: 12)
                        .padding(.trailing, ThemeSpace.x6)
                }
            }
        }
        .accessibilityHidden(true)
    }

    // MARK: The foot

    private var foot: some View {
        FirstRunFoot {
            if model.picks.isEmpty {
                Button(Copy.FirstRun.skipForNow, action: onLeave)
                    .buttonStyle(TertiaryButtonStyle2())
                    .frame(minHeight: 48)
            } else {
                Button {
                    fieldFocused = false
                    Task { await model.continueFromShows() }
                } label: {
                    Text(Copy.FirstRun.continueWith(model.picks.count))
                        .contentTransition(.numericText(value: Double(model.picks.count)))
                }
                .buttonStyle(PrimaryButtonStyle2())
                .disabled(model.preparing)
            }
        }
        .animation(ThemeMotion.pick(ThemeMotion.uiSnappy, reduceMotion: reduceMotion), value: model.picks.count)
    }
}

/// One show on the wall: its poster, its name, and whether it is picked.
///
/// Equatable on what it draws, so a pick re-renders the tile that changed and not the wall (the
/// toggle closure is why SwiftUI cannot prove a tile unchanged — Search's rows, 5 Sep).
struct FirstRunPosterTile: View, Equatable {
    let item: FranchiseSummary
    let picked: Bool
    let toggle: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.item.id == b.item.id && a.picked == b.picked
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: ThemeRadius.poster, style: .continuous)
        Button(action: toggle) {
            VStack(alignment: .leading, spacing: ThemeSpace.x2) {
                Color.clear
                    .aspectRatio(2 / 3, contentMode: .fit)
                    .overlay {
                        RemoteImageView(url: item.portraitArt, maxPixel: 420)
                    }
                    .clipShape(shape)
                    .background(ThemeColor.surfaceRaised, in: shape)
                    // Picked: the app's selection ring standing off the poster, and its badge
                    // (`SelectionRing` — no glow: this wall scrolls). The rest of the wall keeps
                    // its full light — a dimmed wall reads as disabled.
                    .overlay(shape.strokeBorder(ThemeColor.posterEdge, lineWidth: 1))
                    .overlay(alignment: .topTrailing) {
                        if picked {
                            SelectedBadge(size: 24)
                                .padding(ThemeSpace.x2 - 2)
                                .transition(.scale(scale: 0.4).combined(with: .opacity))
                        }
                    }
                    .selectionRing(picked, radius: ThemeRadius.poster, gap: 2.5, width: 2.5)
                Text(item.title.shelfShortened)
                    .type(ThemeType.shelfTitle)
                    .foregroundStyle(picked ? ThemeColor.textPrimary : ThemeColor.textSecondary)
                    .lineLimit(2, reservesSpace: true)
                    .multilineTextAlignment(.leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(OverArtPressStyle())
        .animation(ThemeMotion.pick(ThemeMotion.uiMilestone, reduceMotion: reduceMotion), value: picked)
        // The tap is felt in the poster itself: pressed in a hair, then sprung back.
        .phaseAnimator([0, 1, 2], trigger: picked) { tile, phase in
            tile.scaleEffect(phase == 1 && !reduceMotion ? 0.95 : 1)
        } animation: { phase in
            phase == 1 ? .easeOut(duration: 0.07) : ThemeMotion.uiMilestone
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Copy.FirstRun.tile(item.title, picked: picked))
        .accessibilityAddTraits(picked ? [.isButton, .isSelected] : .isButton)
    }
}
