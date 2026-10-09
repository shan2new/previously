import SwiftUI

// MARK: - Receipts (5 Sep)
//
// The transient confirmation, rebuilt from the toast. A receipt is drawn in ONE of two places,
// decided at the write:
//
//   • IN PLACE — under a compact ring whose result cannot carry its own wording (Schedule's rows,
//     the story viewer's mark — `ReceiptHost.story`, Receipts+Feed.swift). One quiet line,
//     "✓ Episode 19 watched · Undo", for the undo window. Hero capsules do not use it: their
//     drawn check and "Episode N watched" label are already the complete receipt, and repeating
//     the same fact underneath is jarring.
//   • THE LANE — a glass capsule floating just above the app's bar (`LaneFallback`; it was the
//     system bar's iOS 26.1 accessory until the app drew its own bar, 25 Sep): the poster, the
//     fact, the show, Undo. For everything whose object LEFT the
//     screen or never had a control to hold the receipt — a removal, a move, an add from Search,
//     a caught-up from a context menu — and for the two-second notices and the write failures.
//
// The shipped toast was one grey capsule for all of these, fading in with a 4-pt rise, spending
// two lines on the show's full name under a hero that already said it ("archaic", user, 5 Sep;
// directions A–D photographed on the simulator, B + C chosen).

/// Where a receipt is drawn. Set at the write site; `.lane` unless a host claims it.
enum ReceiptPlacement: Hashable {
    /// Under the control that was pressed. `host` names it (`ReceiptHost`).
    case inPlace(host: String)
    /// The tab bar's lane.
    case lane
}

/// The in-place hosts' names — one spelling per surface, so the write and the view agree.
enum ReceiptHost {
    static func episodes(_ mediaId: Int) -> String { "episodes/\(mediaId)" }
    static func schedule(_ mediaId: Int, _ episode: Int) -> String { "schedule/\(mediaId)/\(episode)" }
}

/// What the lane shows: the newest of a failure, a lane-placed undo, or a notice. One item at a
/// time — the lane is one lane.
enum LaneItem: Equatable {
    case error(String)
    case undo(UndoState)
    case notice(String)

    var key: String {
        switch self {
        case .error(let m): return "error/\(m)"
        case .undo(let u): return "undo/\(u.id)"
        case .notice(let m): return "notice/\(m)"
        }
    }
}

extension AppModel {
    var laneItem: LaneItem? {
        if let errorToast { return .error(errorToast) }
        if let undo, undo.placement == .lane { return .undo(undo) }
        if let notice { return .notice(notice) }
        return nil
    }
}

// MARK: - In place

/// The receipt IN the control: one line under the capsule or the row that was pressed.
///
/// Drawn only while `AppModel.undo` is placed at `host` (and, on a row, is about `episode`).
/// Full: centred, check + fact + Undo, a 44-pt row. Compact (rows): leading, at the row's own
/// metadata size.
struct ReceiptLine: View {
    let host: String
    var episode: Int? = nil
    var compact: Bool = false
    /// Drawn in a row's own meta slot: no reserved height, no top padding.
    var inline: Bool = false
    /// The drawn line's height in the full form (the hero's overlay hangs by it).
    static let height: CGFloat = 24

    @Environment(AppModel.self) private var appModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var live: UndoState? {
        guard let undo = appModel.undo, undo.placement == .inPlace(host: host) else { return nil }
        if let episode, undo.episode != episode { return nil }
        return undo
    }

    /// Whether a receipt is live for this host — for a row that draws the line IN its own second
    /// line instead of under itself (interactive review: a receipt as a layout child dropped
    /// every row beneath it 32–39 pt for six seconds).
    static func isLive(_ appModel: AppModel, host: String, episode: Int? = nil) -> Bool {
        guard let undo = appModel.undo, undo.placement == .inPlace(host: host) else { return false }
        if let episode, undo.episode != episode { return false }
        return true
    }

    var body: some View {
        // Conditional content at the top level: an empty `VStack` still took its parent's
        // stack spacing — 8 pt under every card and row for a six-second receipt (review i3).
        Group {
            if let undo = live {
                HStack(spacing: compact ? ThemeSpace.x1 : ThemeSpace.x2) {
                    DrawnCheck(on: true, size: compact ? 10 : 11, tint: ThemeColor.accent)
                    Text(undo.receipt)
                        .type(compact ? ThemeType.metadata : ThemeType.metadataEmphasis)
                        .foregroundStyle(ThemeColor.textSecondary)
                        .lineLimit(1)
                    Text("\u{00B7}")
                        .type(compact ? ThemeType.metadata : ThemeType.metadataEmphasis)
                        .foregroundStyle(ThemeColor.textTertiary)
                    // `interactive`, never amber: the mark this line confirms was committed by
                    // an amber control.
                    // Inline, the line is exactly the caption it stands in for — the Undo keeps
                    // its 44-pt target as a hit shape past the line instead of growing the row.
                    Button(Copy.Action.undo) { appModel.undoTapped(undo) }
                        .qaIdentifier("qa.undo")
                        .buttonStyle(.plain)
                        .type(ThemeType.metadataEmphasis)
                        .foregroundStyle(ThemeColor.interactive)
                        .frame(minHeight: inline ? nil : 44)
                        .contentShape(Rectangle().inset(by: inline ? -14 : 0))
                }
                .frame(maxWidth: .infinity, alignment: compact ? .leading : .center)
                // 24 pt of drawn line; the Undo's 44-pt target overflows it on purpose.
                .frame(height: inline ? nil : (compact ? 32 : Self.height))
                // Arrives the way the mark did — a beat under the capsule, rising and settling
                // on the app's snappy spring while the check draws itself — and LEAVES on the
                // dismiss ease, never on the spring it arrived on (review i3: a receipt that
                // bounces away undoes its own calm; `AnyTransition.toast` states the rule).
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .offset(y: -6)).combined(with: .scale(scale: 0.96))
                        .animation(reduceMotion ? ThemeMotion.uiReduced : ThemeMotion.uiSnappy),
                    removal: .opacity.animation(reduceMotion ? ThemeMotion.uiReduced : ThemeMotion.uiDismiss)))
                .accessibilityElement(children: .contain)
            }
        }
        .animation(ThemeMotion.pick(ThemeMotion.uiSnappy, reduceMotion: reduceMotion), value: appModel.undo?.id)
    }
}

// MARK: - The lane

/// The lane's content: the poster (or a glyph), the fact, the show, and the one action.
struct ReceiptLane: View {
    /// The lane's height with its margin — the clearance every scrolling root adds under its
    /// content while a lane is up (interactive review: the lane sat over the last result's disc,
    /// and a tap on Undo six seconds later added a show).
    static let height: CGFloat = 60
    let item: LaneItem
    var onUndo: () -> Void = {}

    @Environment(AppModel.self) private var appModel

    private var poster: String? {
        guard case .undo(let u) = item, let id = u.franchiseId else { return nil }
        return appModel.franchise(id: id)?.portraitArt ?? u.removedFranchise?.portraitArt
    }

    var body: some View {
        HStack(spacing: ThemeSpace.x3) {
            leading
            // Vibrant ink on the material (review i2): a fixed grey vanished over the first
            // bright card the lane crossed.
            VStack(alignment: .leading, spacing: 1) {
                Text(fact)
                    .type(ThemeType.metadataEmphasis)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    // The longest fact ("Series finished · Moved to Watched") is a few points wider
                    // than the lane beside a poster and Undo on a 393-pt phone: it closes up before
                    // it loses its last word ("Moved to Watc…", 4 Oct).
                    .minimumScaleFactor(0.88)
                if let title {
                    // ONE line (review i5: two lines orphaned "a Slime" under a poster that already
                    // says which show); the head of a long name is enough beside its poster.
                    Text(title)
                        .type(ThemeType.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: ThemeSpace.x2)
            if case .undo = item {
                Button(Copy.Action.undo, action: onUndo)
                    .qaIdentifier("qa.undo")
                    .buttonStyle(.plain)
                    .type(ThemeType.metadataEmphasis)
                    .foregroundStyle(ThemeColor.interactive)
                    .padding(.horizontal, ThemeSpace.x3)
                    .frame(minHeight: 44)
                    .contentShape(Capsule())
            }
        }
        .padding(.leading, ThemeSpace.x3)
        .padding(.trailing, ThemeSpace.x1)
        .frame(minHeight: 52)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var leading: some View {
        if let poster {
            PosterSlot(url: poster, width: 26, height: 39, radius: 4)
        } else {
            ZStack {
                Circle().fill(ThemeColor.surfaceFloating)
                switch item {
                case .error:
                    AppGlyph(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(ThemeColor.warning)
                default:
                    DrawnCheck(on: true, size: 12, tint: ThemeColor.accent)
                }
            }
            .frame(width: 28, height: 28)
        }
    }

    private var fact: String {
        switch item {
        case .error(let m), .notice(let m): return m
        case .undo(let u): return u.receipt
        }
    }

    /// The show, under the fact, when the fact does not already name it — by `displayTitle`,
    /// as every row and shelf names it ("That Time I Got Reincarnated as a Sli…" was the full
    /// title truncated mid-word, review 5 Sep).
    private var title: String? {
        if case .undo(let u) = item, let subtitle = u.subtitle { return subtitle }
        guard case .undo(let u) = item, !u.title.isEmpty, !u.added else { return nil }
        if let id = u.franchiseId, let f = appModel.franchise(id: id) ?? u.removedFranchise { return f.title.shelfShortened(fitting: 30) }
        return u.title.shelfShortened(fitting: 30)
    }
}

/// The lane: the receipt's content in a glass capsule floating just above the app's bar.
struct LaneFallback: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            if let item = appModel.laneItem {
                ReceiptLane(item: item) {
                    if case .undo(let u) = item { appModel.undoTapped(u) }
                }
                .chromeGlass(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .shadow(.floating)
                .transition(.asymmetric(
                    insertion: .move(edge: .bottom).combined(with: .opacity)
                        .animation(reduceMotion ? ThemeMotion.uiReduced : ThemeMotion.uiSnappy),
                    removal: .opacity.animation(reduceMotion ? ThemeMotion.uiReduced : ThemeMotion.uiDismiss)))
                .id(item.key)
            }
        }
        .animation(ThemeMotion.pick(ThemeMotion.uiSnappy, reduceMotion: reduceMotion), value: appModel.laneItem?.key)
    }
}

#if DEBUG
/// `-toastDemo mark|lane|notice`: a receipt that writes nothing, once the library has loaded —
/// the only way to photograph one without moving the test account's progress. `mark` and `lane`
/// use the bottom lane; `notice` is "Episode alerts on". (`upnext`, the in-place receipt on
/// Today's Up next card, went with that card when Today became the feed, 25 Sep.)
@MainActor
enum ToastDemo {
    static func arm(_ appModel: AppModel) {
        guard let mode = UserDefaults.standard.string(forKey: "toastDemo"), !mode.isEmpty else { return }
        Task { @MainActor in
            for _ in 0..<60 where appModel.library.isEmpty {
                try? await Task.sleep(for: .milliseconds(250))
            }
            try? await Task.sleep(for: .milliseconds(1200))
            let wanted = UserDefaults.standard.string(forKey: "toastDemoFranchise")
                ?? UserDefaults.standard.string(forKey: "openDetail")
            guard let f = wanted.flatMap({ appModel.franchise(id: $0) }) ?? appModel.library.first else { return }
            switch mode {
            case "lane":
                appModel.presentUndo(UndoState(mediaId: nil, franchiseId: f.id, prevProgress: 0, title: f.title,
                                               episode: 0, removed: true, removedFranchise: f, undoAction: {}))
            case "notice":
                appModel.showNotice(Copy.Toast.alertsOn)
            default:
                appModel.presentUndo(UndoState(mediaId: nil, franchiseId: f.id, prevProgress: 18,
                                               title: f.title, episode: 19, undoAction: {}))
            }
        }
    }
}
#endif

extension View {
    /// Bottom clearance for the receipt lane while one is up: content scrolls out from under it.
    func laneClearance(_ appModel: AppModel, base: CGFloat = 0) -> some View {
        contentMargins(.bottom, base + (appModel.laneItem != nil ? ReceiptLane.height + ThemeSpace.x3 : 0), for: .scrollContent)
    }
}
