import SwiftUI

// THE SHOW'S OWN SHEET — what the `···` opens on the show page (20 Oct: "We need to rethink the top
// right dots experience man. It's really really bad. It feels like a SaaS app from early 2000s not a
// consumer app UX. Not just the visuals, it needs to be rethought from the ground up", owner).
//
// It was the system menu: the status hidden one level down in a "Watching ›" submenu, then three
// database verbs that wrapped to two lines each ("Mark 1 episode as watched…", "Mark all 8 episodes
// as unwatched…", "Mark series as watched…"), a destructive reset beside the forward ones, and a red
// "Remove from Library" — no show, no context, no sense of what any of it would change.
//
// Now it is about YOU AND THIS SHOW, in the order a viewer reaches for it (Letterboxd's film sheet,
// Apple Music's and Spotify's ellipsis sheets):
//  • the show at its CROWN — its own picture blurred into the sheet's ground, its poster, its name,
//    where you are;
//  • its STATUS as five discs in one glyph family, the chosen one the amber disc a committed mark
//    wears (selection is the one place amber means "this one"), gliding to a new choice — the sheet
//    stays up, so the move is seen; a show you do not own gets the three that add it;
//  • ONE list of what you can do, in your own words, each with a quiet line saying exactly what it
//    changes — "I'm caught up", "I finished The Calamity", "Watch it again" — then, after one rule,
//    what undoes ("Start The Calamity over", "Stop rewatching") and Remove from Library, all in the
//    same row anatomy, the destructive one in its own ink. Each write is still confirmed with its
//    exact count, raised once the sheet has gone.
//
// The first build (same day) was "brilliant direction, absolutely trashy implementation" (owner):
// bordered tiles with an amber slab for the selection and five glyphs of three kinds, a 17-pt name
// on a flat brown ground, two eyebrows with a hole between their groups, Remove as orphaned red
// text, and dead space under it all.

struct ShowActionsSheet: View {
    struct Row: Identifiable {
        let id: String
        let glyph: String
        let title: String
        var detail: String? = nil
        /// Opens somewhere (a chevron), rather than doing something.
        var opens = false
        let perform: () -> Void
    }

    let franchise: Franchise
    let poster: String?
    /// The stage's picture, for the crown.
    let crownArt: String?
    /// Where you are: "Season 4 · Episode 5 next", "Watched · 85 episodes".
    let whereYouAre: String?
    /// The library status; nil for a show you do not own (the discs then add it).
    let status: WatchStatus?
    let statuses: [WatchStatus]
    let onStatus: (WatchStatus) -> Void
    /// What moves you forward — caught up, a season finished, watching it again, the history.
    let progress: [Row]
    /// What undoes — a season from the start, a rewatch stopped: after the rule, beside Remove.
    let undo: [Row]
    /// Remove from Library, for a show you own.
    let onRemove: (() -> Void)?
    /// The page's colour, for the sheet's ground.
    let tint: Color?

    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var contentHeight: CGFloat = 480
    @Namespace private var selection

    static let crownHeight: CGFloat = 250
    static let well: CGFloat = 38

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.bottom, ThemeSpace.x6)
            if status == nil {
                // What the discs do, where nothing says it: a show you do not own.
                Text(Copy.ShowSheet.addAsEyebrow)
                    .type(ThemeType.metadata)
                    .foregroundStyle(ThemeColor.textTertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, ThemeSpace.x3)
            }
            statusRow
                .padding(.bottom, ThemeSpace.x5)
            if !progress.isEmpty || !undo.isEmpty || onRemove != nil {
                Rectangle().fill(ThemeColor.hairline).frame(height: ThemeMetrics.pixel)
                    .padding(.bottom, ThemeSpace.x2)
                actions
            }
        }
        .padding(.horizontal, ThemeMetrics.gutter)
        .padding(.top, ThemeSpace.x8)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        .frame(maxHeight: .infinity, alignment: .top)
        .presentationDetents(typeSize.isAccessibilitySize ? [.large] : [.height(contentHeight)])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(32)
        .presentationBackground { ground }
    }

    // MARK: The show

    private var header: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        return HStack(alignment: .bottom, spacing: ThemeSpace.x4) {
            RemoteImageView(url: poster, contentMode: .fill, maxPixel: 260, placeholderHidden: true)
                .frame(width: 64, height: 96)
                .background(ThemeColor.surfaceRaised)
                .clipShape(shape)
                .overlay(shape.strokeBorder(ThemeColor.posterEdge, lineWidth: 1))
                .cardShadow(.art, shape: shape, fill: ThemeColor.canvas)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: ThemeSpace.x1) {
                Text(franchise.displayTitle)
                    .type(ThemeType.showTitleL)
                    .foregroundStyle(ThemeColor.textPrimary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                if let whereYouAre {
                    Text(whereYouAre)
                        .type(ThemeType.metadata)
                        .foregroundStyle(ThemeColor.textSecondary)
                        .lineLimit(2)
                }
            }
            .padding(.bottom, ThemeSpace.x1)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    // MARK: Status

    private var statusRow: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 0),
                            count: typeSize.isAccessibilitySize ? 3 : max(statuses.count, 1))
        return LazyVGrid(columns: columns, spacing: ThemeSpace.x4) {
            ForEach(statuses, id: \.self) { s in
                StatusDisc(status: s, selected: s == status, adds: status == nil, selection: selection) {
                    // In an animated transaction, so the chosen disc glides to its new place.
                    withAnimation(ThemeMotion.pick(ThemeMotion.uiSettle, reduceMotion: reduceMotion)) { onStatus(s) }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(status == nil ? Copy.ShowSheet.addAsEyebrow : Copy.ShowSheet.statusEyebrow)
    }

    // MARK: Actions

    private var actions: some View {
        VStack(spacing: 0) {
            ForEach(progress) { row in actionRow(row) }
            if !undo.isEmpty || onRemove != nil {
                if !progress.isEmpty {
                    Rectangle().fill(ThemeColor.hairline).frame(height: ThemeMetrics.pixel)
                        .padding(.leading, Self.well + ThemeSpace.x3)
                        .padding(.vertical, ThemeSpace.x2)
                }
                ForEach(undo) { row in actionRow(row, quiet: true) }
                if let onRemove {
                    actionRow(Row(id: "remove", glyph: "trash", title: Copy.Action.removeFromLibrary,
                                  detail: Copy.ShowSheet.removeKeeps, perform: onRemove),
                              destructive: true)
                }
            }
        }
    }

    /// One action: its glyph in a round well, the words beside it — what it is, then what it changes.
    private func actionRow(_ row: Row, quiet: Bool = false, destructive: Bool = false) -> some View {
        let ink = destructive ? ThemeColor.destructive : (quiet ? ThemeColor.textSecondary : ThemeColor.textPrimary)
        return Button(action: row.perform) {
            HStack(spacing: ThemeSpace.x3) {
                AppGlyph(systemName: row.glyph)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(ink)
                    .frame(width: Self.well, height: Self.well)
                    .background(destructive ? ThemeColor.destructive.opacity(0.14)
                                : ThemeColor.textPrimary.opacity(quiet ? 0.05 : 0.09), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title)
                        .type(ThemeType.bodyEmphasis)
                        .foregroundStyle(ink)
                        .lineLimit(2)
                    if let detail = row.detail {
                        Text(detail)
                            .type(ThemeType.metadata)
                            .foregroundStyle(ThemeColor.textTertiary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: ThemeSpace.x2)
                if row.opens {
                    AppGlyph(systemName: "chevron.forward")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(ThemeColor.textTertiary)
                        .accessibilityHidden(true)
                }
            }
            .padding(.vertical, ThemeSpace.x2)
            .frame(minHeight: 60)
            .contentShape(Rectangle())
        }
        .buttonStyle(GroupedRowPressStyle())
        .accessibilityHint(row.detail ?? "")
    }

    // MARK: Ground

    /// The show's own ground, with its own picture at the crown: the stage's art blurred into a
    /// field of its colours (once, off-main, cached — `BlurredArt`), sinking into the page's hue.
    private var ground: some View {
        let base = DetailTint.ground(tint, lightness: DetailTint.groundTopLightness)
        return ZStack(alignment: .top) {
            base
            // Lifted enough to be the show's colour, not a vignette: the first cut sat the name on
            // near-black with a red rim (Bleach). The field sinks into the ground by the discs.
            BlurredArt(url: crownArt, sourceMaxPixel: 420, fraction: 0.14, saturation: 1.35, brightness: 0)
                .frame(height: Self.crownHeight)
                .clipped()
                .overlay {
                    LinearGradient(stops: [.init(color: base.opacity(0.18), location: 0),
                                           .init(color: base.opacity(0.5), location: 0.45),
                                           .init(color: base.opacity(0.86), location: 0.78),
                                           .init(color: base, location: 1)],
                                   startPoint: .top, endPoint: .bottom)
                }
        }
        .ignoresSafeArea()
    }
}

/// One status as a DISC: its glyph in a circle, its word under it. The chosen disc is the amber a
/// committed mark wears, lit from above (`ThemeGradient.accent`), and it GLIDES to a new choice
/// (one shape, `matchedGeometryEffect`); the rest are a breath of the page's light. One glyph family
/// — the bare symbol, never a symbol in its own ring inside the disc.
private struct StatusDisc: View {
    let status: WatchStatus
    let selected: Bool
    /// A show you do not own: the disc adds it, so no disc is chosen.
    let adds: Bool
    let selection: Namespace.ID
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let size: CGFloat = 56

    private var glyph: String {
        switch status {
        case .watching: return "play.fill"
        case .planned: return selected ? "bookmark.fill" : "bookmark"
        case .completed: return "checkmark"
        case .paused: return "pause.fill"
        case .dropped: return "xmark"
        }
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: ThemeSpace.x2) {
                ZStack {
                    Circle().fill(ThemeColor.textPrimary.opacity(0.08))
                    if selected {
                        Circle().fill(ThemeGradient.accent)
                            .overlay(Circle().strokeBorder(ThemeGradient.litEdgeStrong, lineWidth: 1))
                            .matchedGeometryEffect(id: "chosen", in: selection)
                    }
                    AppGlyph(systemName: glyph)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(selected ? ThemeColor.onAccent : ThemeColor.textPrimary.opacity(0.82))
                        .scaleEffect(selected ? 1 : 0.94)
                        // A play triangle's mass sits left of its box: the optical centre is 1.5 pt
                        // to the right (every player's play button is nudged).
                        .offset(x: status == .watching ? 1.5 : 0)
                }
                .frame(width: Self.size, height: Self.size)
                Text(status.displayName)
                    .type(selected ? ThemeType.metadataEmphasis : ThemeType.metadata)
                    .foregroundStyle(selected ? ThemeColor.textPrimary : ThemeColor.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .animation(ThemeMotion.pick(ThemeMotion.uiSettle, reduceMotion: reduceMotion), value: selected)
        }
        .buttonStyle(OverArtPressStyle())
        .accessibilityLabel(adds ? Copy.ShowSheet.addAs(status.displayName) : status.displayName)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}
