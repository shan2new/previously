import SwiftUI

/// X's action bar, measured off the owner's X (26 Sep): reply, repost, like and views in equal
/// ~70-pt beats from the text column's start, then bookmark and share pinned to the trailing edge,
/// 32 pt apart. A post here has fewer: reply (while replies are on), like and remind share the room
/// before the pinned pair in EQUAL slots, each glyph at its slot's leading edge with its count
/// beside it — so the bar never has a hole where X's repost and views would be (the fixed 68-pt
/// slots left one of 180 pt with replies off). Outline glyphs and small counts in X's grey, 8 pt
/// from the glyph; a zero prints nothing, as X's does. A like fills pink and bursts; a
/// reminder rings the bell amber (STATE — the reminder is set — never an action colour); a save
/// fills and drops; share is the system's sheet. The post page spreads every item evenly.
///
/// Every item is a 44-pt target (the spike's were 36). The bar reads the social overlay itself
/// (`appModel.isLiked` …), so a like re-evaluates this bar and nothing else. No haptic here: the
/// model signs the write (`.selection` on the way ON, iD21). The reply item exists only while
/// replies are on (`feedCapabilities.comments`); its slot closes when they are off (§4.9).
struct PostActionBar: View {
    let model: FeedPostModel
    /// The post page's bar: the items spread evenly, larger glyphs and counts.
    let large: Bool
    /// Over a picture (the media viewer): white glyphs instead of X's grey.
    let onDark: Bool
    let onComment: () -> Void

    init(model: FeedPostModel, large: Bool = false, onDark: Bool = false, onComment: @escaping () -> Void) {
        self.model = model
        self.large = large
        self.onDark = onDark
        self.onComment = onComment
    }

    @Environment(AppModel.self) private var appModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .footnote) private var glyphScaled: CGFloat = FeedMetrics.actionGlyph
    @ScaledMetric(relativeTo: .footnote) private var glyphLargeScaled: CGFloat = FeedMetrics.actionGlyphLarge
    /// The bell rings and the bookmark drops only on the way IN — undoing is quiet.
    @State private var rings = 0
    @State private var drops = 0

    /// Glyph → count: 8 pt from the glyph's ink, X's.
    private static let countGap: CGFloat = 6

    var body: some View {
        let id = model.id
        let comments = appModel.feedCapabilities.comments
        HStack(spacing: 0) {
            if comments {
                reply(count: appModel.commentCount(id))
                    .frame(maxWidth: large ? nil : .infinity, alignment: .leading)
                if large { Spacer(minLength: 0) }
            }
            like(liked: appModel.isLiked(id), count: appModel.likeCount(id))
                .frame(maxWidth: large ? nil : .infinity, alignment: .leading)
            if large { Spacer(minLength: 0) }
            // Nothing to be reminded of once the episode is out.
            if model.post.kind != .episode {
                remind(on: appModel.isReminded(id))
                    .frame(maxWidth: large ? nil : .infinity, alignment: .leading)
                if large { Spacer(minLength: 0) }
            } else if !large {
                Spacer(minLength: 0)
            }
            save(on: appModel.isSaved(id))
                .frame(width: large ? nil : FeedMetrics.actionSlotSmall * pinnedScale)
            if large { Spacer(minLength: 0) }
            share
                .frame(width: large ? nil : FeedMetrics.actionSlotSmall * pinnedScale)
        }
        // The pinned pair's glyphs centre in their slots, and the pair steps into the row's inset
        // to sit where X's bookmark and share do.
        .padding(.trailing, large ? 0 : -FeedMetrics.actionPinnedPull * pinnedScale)
        .frame(minHeight: FeedMetrics.actionHitHeight)
    }

    // MARK: Metrics

    /// Scaled with Dynamic Type, capped so the bar stays one row at the accessibility sizes.
    private var glyph: CGFloat {
        let base = large ? FeedMetrics.actionGlyphLarge : FeedMetrics.actionGlyph
        return min(large ? glyphLargeScaled : glyphScaled, base * FeedMetrics.actionGlyphMaxScale)
    }

    /// The pinned pair's slots and step grow with the glyphs (Dynamic Type), so at the accessibility
    /// sizes the bookmark and the share keep X's air between them and the share stays inside the
    /// column.
    private var pinnedScale: CGFloat { glyph / FeedMetrics.actionGlyph }

    private var ink: Color { onDark ? FeedStage.ink.opacity(0.92) : ThemeColor.feedSecondary }

    // MARK: Items

    private func reply(count: Int) -> some View {
        Button(action: onComment) {
            HStack(spacing: Self.countGap) {
                AppGlyph(systemName: "bubble.left")
                    .font(FeedGlyph.font(glyph))
                    .foregroundStyle(ink)
                countText(count, tint: ink)
            }
            .modifier(ActionTarget())
        }
        .buttonStyle(FeedIconPressStyle())
        .accessibilityLabel(Copy.Feed.replies(count))
    }

    private func like(liked: Bool, count: Int) -> some View {
        Button {
            appModel.toggleLike(model.id, franchiseId: model.post.franchiseId)
        } label: {
            HStack(spacing: Self.countGap) {
                LikeGlyph(liked: liked, size: glyph, idle: ink)
                countText(count, tint: liked ? ThemeColor.like : ink)
            }
            .modifier(ActionTarget())
        }
        .buttonStyle(FeedIconPressStyle())
        .accessibilityLabel(liked ? Copy.Feed.unlike : Copy.Feed.like)
        .accessibilityValue(Copy.Feed.likes(count))
    }

    private func remind(on: Bool) -> some View {
        Button {
            let turningOn = !appModel.isReminded(model.id)
            appModel.toggleRemind(model)
            if turningOn, !reduceMotion { rings += 1 }
        } label: {
            AppGlyph(systemName: on ? "bell.fill" : "bell")
                .font(FeedGlyph.font(glyph))
                .foregroundStyle(on ? ThemeColor.accent : ink)
                // A Tabler picture, not an SF Symbol: the ring is a transform, the swap a fade.
                .glyphRing(trigger: rings)
                .contentTransition(.opacity)
                .modifier(ActionTarget())
        }
        .buttonStyle(FeedIconPressStyle())
        .accessibilityLabel(on ? Copy.Feed.reminderOn : Copy.Feed.remindMe)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func save(on: Bool) -> some View {
        Button {
            let turningOn = !appModel.isSaved(model.id)
            appModel.toggleSave(model)
            if turningOn, !reduceMotion { drops += 1 }
        } label: {
            AppGlyph(systemName: on ? "bookmark.fill" : "bookmark")
                .font(FeedGlyph.font(glyph))
                .foregroundStyle(on ? (onDark ? FeedStage.ink : ThemeColor.feedText) : ink)
                .glyphDrop(trigger: drops)
                .modifier(ActionTarget(minWidth: FeedMetrics.actionHitHeight, alignment: .center))
        }
        .buttonStyle(FeedIconPressStyle())
        .accessibilityLabel(on ? Copy.Feed.unsave : Copy.Feed.save)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    @ViewBuilder private var share: some View {
        let label = AppGlyph(systemName: "square.and.arrow.up")
            .font(FeedGlyph.font(glyph))
            .foregroundStyle(ink)
            .modifier(ActionTarget(minWidth: FeedMetrics.actionHitHeight, alignment: .center))
        if let url = model.shareURL {
            ShareLink(item: url, subject: Text(model.showName), message: Text(model.shareText)) { label }
                .buttonStyle(FeedIconPressStyle())
                .accessibilityLabel(Copy.Feed.share)
        } else {
            ShareLink(item: model.shareText) { label }
                .buttonStyle(FeedIconPressStyle())
                .accessibilityLabel(Copy.Feed.share)
        }
    }

    /// X prints no numeral at zero: the count appears with the first like or reply, never before.
    @ViewBuilder
    private func countText(_ n: Int, tint: Color) -> some View {
        if n > 0 {
            Text(FeedCount.text(n))
                .type(large ? ThemeType.feedCountLarge : ThemeType.feedCount)
                .foregroundStyle(tint)
                .lineLimit(1)
                .fixedSize()
                .contentTransition(reduceMotion ? .opacity : .numericText(value: Double(n)))
                .animation(ThemeMotion.pick(ThemeMotion.uiNumeric, reduceMotion: reduceMotion), value: n)
        }
    }
}

/// Every action-bar item: a 44-pt-tall target (and 44 wide where the slot is narrower) whose whole
/// box takes the touch.
private struct ActionTarget: ViewModifier {
    var minWidth: CGFloat? = nil
    var alignment: Alignment = .leading

    func body(content: Content) -> some View {
        content
            .frame(minWidth: minWidth, minHeight: FeedMetrics.actionHitHeight, alignment: alignment)
            .contentShape(Rectangle())
    }
}
