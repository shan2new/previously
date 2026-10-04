import SwiftUI
import UIKit

// The post, on X's measured anatomy (round 3, 393 pt; round 4 polish):
//   · ONE metadata line — the show as the account, its installment in the handle's slot, the time,
//     in grey. Nothing else competes with it.
//   · ONE text at reading weight — the sentence, then the research's note as its next paragraph —
//     drawn whole, as the post page draws it. No bold headline over a grey paragraph.
//   · The media is the picture and nothing more: no pill, no tag, no date printed on the art.
//   · A row of quiet outline icons.
//   · No colour in the post except STATE: a like is pink, a reminder you set rings the bell amber,
//     and the gold check says the news came from the studio or network itself (brief §13).
//
// The whole post is one press (X lifts the row's ground while the finger is down); the avatar and
// the name open the show, as an account's do; the picture opens the viewer — or, tapped twice,
// likes the post with Instagram's heart. Every post carries its menu on a long press (iD20).

/// X's measured spacings inside a post, in one place.
enum FeedPostLayout {
    /// The name line rises by Outfit's room above its capitals, so the name's top meets the
    /// avatar's top, as X's does (it sat 4⅓ pt under it).
    static let nameLift: CGFloat = 4
    /// Name line → words.
    static let sentenceTop: CGFloat = 1
    /// Words → media (or the rumour's note): 14 from the last baseline, X's 13½ — SF's line keeps
    /// 5 pt under its baseline where Outfit's kept 4.
    static let mediaTop: CGFloat = 9
    /// Media → action bar.
    static let barTop: CGFloat = 2
    /// Inside the name line.
    static let nameSpacing: CGFloat = 4
    /// The words' line, as a multiple of their point size (`readingLines`): X's 15 on 20 — in a post,
    /// a reply, a note and the composer's quote alike — and X's detail, 17 on 24, for the post page
    /// and for what you type.
    static let lineHeight: CGFloat = 20.0 / 15.0
    static let lineHeightLarge: CGFloat = 24.0 / 17.0
    /// The `···` sits 6 pt into the row's trailing inset, as X's does.
    static let menuTrailingPull: CGFloat = 6
    /// The For you "Add" capsule: 26 pt tall, 14 pt of side padding (X's follow pill). It rides the
    /// name line without growing it — 3 pt over it and under it — so a For you post's name, like a
    /// Following one's, meets the avatar's top and its words sit where theirs do (at 30 it pushed
    /// the line to 30 and both 5 and 10 pt down).
    static let addHeight: CGFloat = 26
    static let addPadding: CGFloat = 14
    /// The double-tap heart over a picture.
    static let bigHeart: CGFloat = 78
    /// The rumour note: its title's glyph → words (its words keep the post's line, X's note being
    /// 15 on 20 too).
    static let noteGlyphGap: CGFloat = 6
}

// MARK: - The row

/// One post in a list. `Equatable` on what it shows (the model and the tab), applied with
/// `.equatable()`, so a minute tick, a like elsewhere or the list re-composing does not rebuild a
/// row whose post did not change. The action bar inside reads the social overlay itself, so a like
/// re-evaluates one bar.
struct FeedPostRow: View, @MainActor Equatable {
    let model: FeedPostModel
    /// For you's posts are about shows you do not track: the name line offers Add instead of `···`.
    var tab: FeedTab = .following
    /// The feed's zoom namespace: the picture viewer and a trailer's full screen grow out of the post.
    var zoom: Namespace.ID? = nil
    let onOpen: () -> Void
    let onOpenShow: () -> Void
    /// Where no list plays trailers (Saved): a trailer's tap opens its post, where it plays.
    var onPlay: (() -> Void)? = nil
    let onViewMedia: () -> Void
    let onComment: () -> Void
    /// The first post's picture is on screen (the launch hands off on it).
    var onMediaLoaded: (() -> Void)? = nil

    static func == (a: Self, b: Self) -> Bool {
        a.model == b.model && a.tab == b.tab && a.zoom == b.zoom
    }

    var body: some View {
        Button(action: onOpen) { content }
            .buttonStyle(FeedRowPressStyle())
            .contextMenu { PostMenuItems(model: model, onOpenShow: onOpenShow) }
            .accessibilityElement(children: .contain)
    }

    /// X's social-context line: why this post is in For you, a small glyph under the avatar's
    /// column and the reason on the words' axis.
    @ViewBuilder private var contextLine: some View {
        if let line = model.contextLine {
            HStack(spacing: FeedMetrics.gap) {
                AppGlyph(systemName: isTaste ? "arrow.up.right" : "tv")
                    .font(ThemeType.feedSmall.font.weight(.semibold))
                    .frame(width: FeedMetrics.avatar, alignment: .trailing)
                Text(line)
                    .type(ThemeType.feedSmall)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(ThemeColor.feedSecondary)
            .padding(.horizontal, FeedMetrics.inset)
            .padding(.top, FeedMetrics.rowTop)
            // The name keeps its place under the line: the row's own top padding folds into it.
            .padding(.bottom, -FeedMetrics.rowTop + ThemeSpace.x1)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(line)
        }
    }

    private var isTaste: Bool {
        if case .taste = model.post.context { return true }
        return false
    }

    private var content: some View {
        VStack(spacing: 0) {
            contextLine
            HStack(alignment: .top, spacing: FeedMetrics.gap) {
                Button(action: onOpenShow) {
                    ShowAvatar(franchise: model.franchise)
                }
                .buttonStyle(OverArtPressStyle())
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 0) {
                    textColumn
                        .padding(.top, -FeedPostLayout.nameLift)
                    switch model.media {
                    case .none:
                        RumourNote(model: model)
                            .padding(.top, FeedPostLayout.mediaTop)
                    case .art, .trailer:
                        PostMediaButton(model: model, zoom: zoom, onPlay: onPlay, onViewMedia: onViewMedia,
                                        onLoaded: onMediaLoaded)
                            .padding(.top, FeedPostLayout.mediaTop)
                    }
                    PostActionBar(model: model, onComment: onComment)
                        .padding(.top, FeedPostLayout.barTop)
                    ReminderPrimerSlot(model: model)
                }
            }
            .padding(.horizontal, FeedMetrics.inset)
            .padding(.top, FeedMetrics.rowTop)
            .padding(.bottom, FeedMetrics.rowBottom)
            FeedHairline()
        }
        .contentShape(Rectangle())
        .onAppear {
            // A post with no picture is ready the moment it is drawn (its avatar is a 44-pt crop).
            if case .none = model.media { onMediaLoaded?() }
        }
    }

    /// The name line and the post's words — the sentence and the research's note, as the post page
    /// draws them (`FeedPostModel.body`), up to X's 280 characters: a longer post is cut at a word
    /// and ends on "Show more", as X's does, and the row (one press) opens it whole. ONE VoiceOver
    /// element, labelled with the WHOLE words, carrying the row's actions (the buttons below stay
    /// reachable by swiping too).
    private var textColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            PostNameLine(model: model, suggested: tab == .forYou, onOpenShow: onOpenShow)
            Text(model.clippedBody ?? model.body)
                .type(ThemeType.feedBody)
                .foregroundStyle(ThemeColor.feedText)
                .multilineTextAlignment(.leading)
                .readingLines(FeedPostLayout.lineHeight)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, FeedPostLayout.sentenceTop)
            if model.clippedBody != nil {
                // Not a button of its own: the whole row is the press that opens the post.
                Text(Copy.Feed.showMore)
                    .type(ThemeType.feedNoteTitle)
                    .foregroundStyle(ThemeColor.interactive)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.accessibilityLabel)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default) { onOpen() }
        .modifier(PostAccessibilityActions(model: model, suggested: tab == .forYou,
                                           onComment: onComment, onOpenShow: onOpenShow))
    }
}

/// The row's named VoiceOver actions (spec §5.5): Like/Unlike, Save, Remind me, Reply (comments
/// on), Share, Go to <show>, Not interested — and Add on a For you post.
private struct PostAccessibilityActions: ViewModifier {
    let model: FeedPostModel
    let suggested: Bool
    let onComment: () -> Void
    let onOpenShow: () -> Void

    @Environment(AppModel.self) private var appModel

    func body(content: Content) -> some View {
        let id = model.id
        content
            .accessibilityAction(named: appModel.isLiked(id) ? Copy.Feed.unlike : Copy.Feed.like) {
                appModel.toggleLike(id, franchiseId: model.post.franchiseId)
            }
            .accessibilityAction(named: appModel.isSaved(id) ? Copy.Feed.unsave : Copy.Feed.save) {
                appModel.toggleSave(model)
            }
            .modifier(OptionalAction(name: appModel.isReminded(id) ? Copy.Feed.reminderOn : Copy.Feed.remindMe,
                                     enabled: model.post.kind != .episode, action: { appModel.toggleRemind(model) }))
            .modifier(OptionalAction(name: Copy.Feed.replies(appModel.commentCount(id)),
                                     enabled: appModel.feedCapabilities.comments, action: onComment))
            .accessibilityAction(named: Copy.Feed.share) {
                SystemShare.present(model.shareURL.map { [$0 as Any, model.shareText as Any] } ?? [model.shareText as Any])
            }
            .modifier(OptionalAction(name: Copy.Search.add,
                                     enabled: suggested && !appModel.isInLibrary(model.post.franchiseId)) {
                addFromFeed(model, appModel: appModel, onOpenShow: onOpenShow)
            })
            .accessibilityAction(named: Copy.Feed.goTo(model.showName), onOpenShow)
            .accessibilityAction(named: Copy.Feed.notInterested) { appModel.hidePost(model) }
    }
}

/// For you's Add and its VoiceOver action open the same library choices as Search and Detail.
@MainActor
func addFromFeed(_ model: FeedPostModel, appModel: AppModel, onOpenShow: () -> Void) {
    let id = model.post.franchiseId
    guard !appModel.isInLibrary(id) else { return }
    appModel.pendingAddPrompt = id
    onOpenShow()
}

/// A named accessibility action that exists only when it can do something — conditional inside
/// the actions builder, so the element keeps its identity when the condition flips.
private struct OptionalAction: ViewModifier {
    let name: String
    let enabled: Bool
    let action: () -> Void

    func body(content: Content) -> some View {
        content.accessibilityActions {
            if enabled { Button(name, action: action) }
        }
    }
}

/// The feed's rule between rows: X's separator grey, a hairline.
struct FeedHairline: View {
    var body: some View {
        Rectangle().fill(ThemeColor.feedSeparator).frame(height: FeedMetrics.hairline)
    }
}

// MARK: - The name line

/// "Black Clover ✓ Season 2 · 2h  ···" — X's line: the account in bold, its mark, the grey slot X
/// uses for the handle (here the installment), the time, the overflow, all at X's 15. With room:
/// all of it. Without: the show's shorter name keeps the installment beside it; then the whole name
/// alone; then the shorter name alone — X drops the handle before it cuts anything, and never the
/// time. Only past all four does the name end in an ellipsis. At the accessibility sizes it is two
/// lines: the name, then installment · time.
struct PostNameLine: View {
    let model: FeedPostModel
    /// A For you post: a trailing Add capsule instead of the `···` menu (iD20 — the menu stays on
    /// the long press).
    let suggested: Bool
    let onOpenShow: () -> Void

    @Environment(AppModel.self) private var appModel
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        HStack(alignment: typeSize.isAccessibilitySize ? .top : .center, spacing: FeedPostLayout.nameSpacing) {
            Button(action: onOpenShow) {
                if typeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 0) {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: FeedPostLayout.nameSpacing) {
                                name(model.showName)
                                mark
                            }
                            if shortens {
                                HStack(spacing: FeedPostLayout.nameSpacing) {
                                    name(model.shortName)
                                    mark
                                }
                            }
                        }
                        Text(Copy.Feed.separated([model.post.installment, model.stamp]))
                            .type(ThemeType.feedSubhead)
                            .foregroundStyle(ThemeColor.feedSecondary)
                    }
                    .contentShape(Rectangle())
                } else {
                    ViewThatFits(in: .horizontal) {
                        line(model.showName, installment: true)
                        if shortens { line(model.shortName, installment: true) }
                        line(model.showName, installment: false)
                        if shortens { line(model.shortName, installment: false) }
                    }
                }
            }
            .buttonStyle(.plain)
            .layoutPriority(1)
            Spacer(minLength: FeedPostLayout.nameSpacing)
            if suggested {
                ShowAddCapsule(model: model, onOpenShow: onOpenShow)
            } else {
                // Hosted: in a list that installs `postMenuHost` the `···` is a plain button and
                // the list presents the one menu.
                PostMenuButton(model: model, onOpenShow: onOpenShow, hosted: true)
                    .padding(.trailing, -FeedPostLayout.menuTrailingPull)
            }
        }
    }

    /// The title has an identity half shorter than itself ("Demon Slayer").
    private var shortens: Bool { model.shortName != model.showName }

    private func name(_ text: String) -> some View {
        Text(text)
            .type(ThemeType.feedPostName)
            .foregroundStyle(ThemeColor.feedText)
            .lineLimit(1)
    }

    @ViewBuilder private var mark: some View {
        if model.showsOfficialMark { ConfirmedMark() }
    }

    private func line(_ title: String, installment: Bool) -> some View {
        HStack(alignment: .center, spacing: FeedPostLayout.nameSpacing) {
            name(title).layoutPriority(2)
            mark
            if installment, !model.post.installment.isEmpty {
                Text(model.post.installment)
                    .type(ThemeType.feedSubhead)
                    .foregroundStyle(ThemeColor.feedSecondary)
                    .lineLimit(1)
                    .fixedSize()
            }
            Text(Copy.Feed.afterDot(model.stamp))
                .type(ThemeType.feedSubhead)
                .foregroundStyle(ThemeColor.feedSecondary)
                .lineLimit(1)
                .fixedSize()
        }
        .contentShape(Rectangle())
    }
}

/// X's follow pill, for a show: ink on white until it is yours, then an outline. Every generic
/// Add opens the show's library choices, on a post's name line and on its author row alike.
struct ShowAddCapsule: View {
    let model: FeedPostModel
    let onOpenShow: () -> Void

    @Environment(AppModel.self) private var appModel

    var body: some View {
        let owned = appModel.isInLibrary(model.post.franchiseId)
        Button {
            addFromFeed(model, appModel: appModel, onOpenShow: onOpenShow)
        } label: {
            Text(owned ? Copy.Search.added : Copy.Search.addAsks)
                .type(ThemeType.feedSmall)
                .fontWeight(.bold)
                .foregroundStyle(owned ? ThemeColor.feedText : ThemeColor.onAccent)
                .contentTransition(.interpolate)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, FeedPostLayout.addPadding)
                .frame(minHeight: FeedPostLayout.addHeight)
                .background(owned ? AnyShapeStyle(Color.clear) : AnyShapeStyle(ThemeGradient.ivory), in: Capsule())
                .overlay(Capsule().strokeBorder(owned ? ThemeColor.feedSeparator : .clear, lineWidth: FeedMetrics.hairline))
                .frame(minHeight: FeedMetrics.actionHitHeight)
                .contentShape(Rectangle())
                // The line's own height, as the `···` holds it (`PostMenuButton`).
                .padding(.vertical, -ThemeSpace.x3)
        }
        .buttonStyle(FeedIconPressStyle())
        .disabled(owned)
        .accessibilityHint(owned ? "" : Copy.Feed.addHint)
        .fixedSize()
        .layoutPriority(3)
        .animation(ThemeMotion.uiMicro, value: owned)
    }
}

// MARK: - The menu

/// The post's `···`: X's menu for a news account in a 44×44 target that does not grow the line.
struct PostMenuButton: View {
    let model: FeedPostModel
    let onOpenShow: () -> Void
    /// Over a picture (the media viewer): white instead of X's grey.
    var tint: Color = ThemeColor.feedSecondary
    /// In a text line (the name line): the 44-pt target does not make the line 44 tall. Off where
    /// the button stands alone (the media viewer's corner).
    var insideLine = true
    /// A row of a list: when the list installs `postMenuHost`, a plain button that names the post
    /// to the list's one menu instead of a `Menu` of its own. A page's single `···` (the post
    /// page, the media viewer) keeps its own `Menu`.
    var hosted = false

    @Environment(\.postMenuRequest) private var request

    var body: some View {
        Group {
            if hosted, let request {
                Button { request.target = model } label: { glyph }
                    .buttonStyle(FeedIconPressStyle())
            } else {
                Menu {
                    PostMenuItems(model: model, onOpenShow: onOpenShow)
                } label: {
                    glyph
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, insideLine ? -ThemeSpace.x3 : 0)
        .accessibilityLabel(Copy.Feed.more)
    }

    private var glyph: some View {
        AppGlyph(systemName: "ellipsis")
            .font(ThemeType.feedSubhead.font.weight(.medium))
            .foregroundStyle(tint)
            .frame(width: FeedMetrics.actionHitHeight, height: FeedMetrics.actionHitHeight)
            .contentShape(Rectangle())
    }
}

/// The feed's ONE post menu (craft review, iD20). A `Menu` per realised row is a UIKit menu
/// interaction per row, and a lazy feed realises rows continuously — Search measured one per
/// result row at 40 % of an answer landing, which is why its unowned add became a plain button.
/// A list installs this (`postMenuHost`); its rows' `···` write the post here and the list presents
/// one dialog. The long-press `.contextMenu` stays on the row, as it stays on Search's rows.
@MainActor
@Observable
final class PostMenuRequest {
    var target: FeedPostModel?
}

extension EnvironmentValues {
    @Entry var postMenuRequest: PostMenuRequest? = nil
}

extension View {
    /// Installs the list's one post menu: the rows below find `request` in the environment, and
    /// the menu opens as one dialog over the list.
    func postMenuHost(_ request: PostMenuRequest,
                      onOpenShow: @escaping (FeedPostModel) -> Void) -> some View {
        modifier(PostMenuHost(request: request, onOpenShow: onOpenShow))
    }
}

private struct PostMenuHost: ViewModifier {
    let request: PostMenuRequest
    let onOpenShow: (FeedPostModel) -> Void

    func body(content: Content) -> some View {
        content
            .environment(\.postMenuRequest, request)
            .confirmationDialog(Copy.Feed.more, isPresented: presented, titleVisibility: .hidden,
                                presenting: request.target) { m in
                PostMenuItems(model: m, onOpenShow: { onOpenShow(m) }, divided: false)
            }
    }

    private var presented: Binding<Bool> {
        Binding(get: { request.target != nil }, set: { if !$0 { request.target = nil } })
    }
}

/// Every item does what it says: less of this, none of this show (or its news back), copy, the
/// source (an https link only), the show.
struct PostMenuItems: View {
    let model: FeedPostModel
    let onOpenShow: () -> Void
    /// A menu draws its rule between the curation items and the rest; a dialog has none to draw.
    var divided = true

    @Environment(AppModel.self) private var appModel
    @Environment(\.openURL) private var openURL

    var body: some View {
        let franchiseId = model.post.franchiseId
        Button { appModel.hidePost(model) } label: {
            AppGlyphLabel(Copy.Feed.notInterested, systemName: "hand.thumbsdown")
        }
        if appModel.mutedShowIds.contains(franchiseId) {
            Button { appModel.unmuteShow(franchiseId: franchiseId) } label: {
                AppGlyphLabel(Copy.Feed.unmute(model.showName), systemName: "speaker.wave.2")
            }
        } else {
            Button {
                appModel.muteShow(franchiseId: franchiseId, showName: model.showName, fromPostId: model.id)
            } label: {
                AppGlyphLabel(Copy.Feed.mute(model.showName), systemName: "speaker.slash")
            }
        }
        if divided { Divider() }
        Button { UIPasteboard.general.string = model.shareText } label: {
            AppGlyphLabel(Copy.Feed.copyText, systemName: "doc.on.doc")
        }
        if let source = model.readOn, let url = SafeURL.https(source.url?.absoluteString) {
            Button { openURL(url) } label: {
                AppGlyphLabel(Copy.Feed.readOn(source.publisher), systemName: "safari")
            }
        }
        Button(action: onOpenShow) {
            AppGlyphLabel(Copy.Feed.goTo(model.showName), systemName: "play.rectangle.on.rectangle")
        }
    }
}

// MARK: - Folded

/// X's inline answer to Not interested and Mute: the post folds into one grey line with Undo,
/// where it was — the feed never jumps under your thumb.
struct FoldedPostRow: View {
    let fold: FeedFold
    let onUndo: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: ThemeSpace.x3) {
                Text(text)
                    .type(ThemeType.feedSubhead)
                    .foregroundStyle(ThemeColor.feedSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button(action: onUndo) {
                    Text(Copy.Action.undo)
                        .type(ThemeType.feedNoteTitle)
                        .foregroundStyle(ThemeColor.interactive)
                        .frame(minWidth: FeedMetrics.actionHitHeight, minHeight: FeedMetrics.actionHitHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(FeedIconPressStyle())
            }
            .padding(.leading, ThemeMetrics.gutter)
            .padding(.trailing, ThemeSpace.x2)
            .padding(.vertical, ThemeSpace.x1)
            FeedHairline()
        }
        .transition(.opacity)
    }

    private var text: String {
        switch fold {
        case .notInterested: Copy.Feed.foldNotInterested
        case .muted(let show): Copy.Feed.foldMuted(show)
        }
    }
}

// MARK: - The rumour's note

/// X's Community Note, for a rumour: a bordered card — the reason in bold, what was reported, and
/// how many reports, none official. Whole wherever it is drawn, as X's note is in the timeline.
struct RumourNote: View {
    let model: FeedPostModel

    var body: some View {
        VStack(alignment: .leading, spacing: ThemeSpace.x2) {
            Label {
                Text(Copy.Feed.rumourNoteTitle).type(ThemeType.feedNoteTitle)
            } icon: {
                AppGlyph(systemName: "person.2.fill", decorative: true).font(ThemeType.feedSmall.font)
            }
            .labelStyle(RumourNoteTitleStyle())
            .foregroundStyle(ThemeColor.feedText)
            if let note = model.post.note, !note.isEmpty {
                Text(note)
                    .type(ThemeType.feedNote)
                    .foregroundStyle(ThemeColor.feedText)
                    .readingLines(FeedPostLayout.lineHeight)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(Copy.Feed.rumourNoteReports(model.post.sources.count))
                .type(ThemeType.feedSmall)
                .foregroundStyle(ThemeColor.feedSecondary)
        }
        .padding(ThemeSpace.x3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: FeedMetrics.noteRadius, style: .continuous)
            .strokeBorder(ThemeColor.feedSeparator, lineWidth: FeedMetrics.hairline))
    }
}

private struct RumourNoteTitleStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: FeedPostLayout.noteGlyphGap) {
            configuration.icon
            configuration.title
        }
    }
}

// MARK: - Media

/// One tap plays a trailer WHERE IT IS (its sound, its controls — then shows or hides them) or
/// opens a picture's viewer; two like the post with Instagram's heart. The single tap waits out the
/// double, as Instagram's does.
struct PostMediaButton: View {
    let model: FeedPostModel
    let zoom: Namespace.ID?
    /// Where no list plays trailers (Saved): a trailer's tap opens its post instead.
    var onPlay: (() -> Void)? = nil
    let onViewMedia: () -> Void
    var onLoaded: (() -> Void)? = nil
    /// The post page shows a poster whole, the timeline its 4:5 crop (`PostMedia.posterAspect`).
    var posterAspect: CGFloat = PostMedia.posterInFeed
    /// The media's width, for its decode budget (the feed's column by default).
    var width: CGFloat = PostMedia.columnWidth

    @Environment(AppModel.self) private var appModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.feedAutoplay) private var autoplay
    @State private var hearts = 0

    private var isTrailer: Bool { trailer != nil }

    private var trailer: FranchiseVideo? {
        if case .trailer(_, let video) = model.media { return video }
        return nil
    }

    /// This post's trailer, while it is the one playing in place.
    private var playback: TrailerPlayback? {
        guard isTrailer, let current = autoplay?.current, current.key == model.id else { return nil }
        return current
    }

    var body: some View {
        PostMedia(model: model, onLoaded: onLoaded, width: width, posterAspect: posterAspect)
            .overlay { BigHeartPop(trigger: hearts, size: FeedPostLayout.bigHeart) }
            .modifier(ZoomSourceIfAny(id: FeedZoom.media(model.id), namespace: zoom))
            .contentShape(RoundedRectangle(cornerRadius: FeedMetrics.mediaRadius, style: .continuous))
            .gesture(
                TapGesture(count: 2).onEnded { likeByDoubleTap() }
                    .exclusively(before: TapGesture().onEnded { open() })
            )
            // A trailer's buttons ride ABOVE the post's taps, never inside them.
            .overlay {
                if isTrailer, let autoplay {
                    InlineTrailerControlsLayer(postId: model.id, autoplay: autoplay)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(isTrailer ? Copy.Feed.playTrailer : Copy.Feed.viewPicture)
            .accessibilityValue(accessibilityValue)
            .accessibilityAction(.default) { open() }
            .accessibilityAction(named: Copy.Feed.likePost) { likeByDoubleTap() }
            .modifier(TrailerActions(playback: playback, autoplay: autoplay))
    }

    private var accessibilityValue: String {
        guard let playback else { return "" }
        if !playback.engaged { return autoplay?.muted == false ? "" : Copy.Feed.trailerPlaying }
        return Copy.Video.positionValue(playback.current, of: playback.duration)
    }

    private func open() {
        guard let trailer else { return onViewMedia() }
        if let autoplay {
            autoplay.tap(model.id, video: trailer)
        } else {
            onPlay?()
        }
    }

    /// Instagram's double tap only ever LIKES — it never takes a like back.
    private func likeByDoubleTap() {
        if !reduceMotion { hearts += 1 }
        appModel.like(model.id, franchiseId: model.post.franchiseId)
    }
}

/// The inline trailer's controls as named VoiceOver actions on the media (its buttons are inside
/// an element VoiceOver reads as one): the sound while it previews; play/pause, full screen and the
/// sound while it is watched. Conditional INSIDE the actions builder, never an `if` around
/// `content`: a branch there gives the media a new identity when a trailer starts, which tears the
/// player down the moment it mounts.
private struct TrailerActions: ViewModifier {
    let playback: TrailerPlayback?
    let autoplay: FeedAutoplay?

    func body(content: Content) -> some View {
        content.accessibilityActions {
            if let playback, let autoplay {
                if playback.engaged {
                    let playing = playback.phase == .playing || playback.phase == .buffering
                    Button(playing ? Copy.Video.pause : Copy.Video.play) { playback.togglePlay() }
                    Button(Copy.Video.fullScreen) { autoplay.openFullScreen(playback) }
                    Button(playback.soundLabel) { playback.setMuted(!playback.muted) }
                } else {
                    Button(autoplay.muted ? Copy.Feed.soundOn : Copy.Feed.soundOff) { autoplay.muted.toggle() }
                }
            }
        }
    }
}

/// The zoom's source ids, one spelling for the row, the post page and the covers.
enum FeedZoom {
    static func media(_ postId: String) -> String { "media/\(postId)" }
}

/// X's media: the column's width, radius 12 and X's one-pixel border — nothing on it but a play
/// glyph. A trailer's still is tried in order (iD10) at 16:9, and so is a true landscape. A POSTER
/// is shown as the tall picture it is (the X pass, 25 Sep — "why does this not look like X?"): X
/// draws a tall image tall, cropped in the timeline (4:5 here, around where a key visual's faces
/// sit) and whole on the post page (2:3). The 16:9 frame with the poster composited small on its own
/// blurred ground read as a picture in a box — nothing X or Instagram draws.
struct PostMedia: View {
    let model: FeedPostModel
    var onLoaded: (() -> Void)? = nil
    /// The frame's width — the post's text column by default.
    var width: CGFloat = PostMedia.columnWidth
    /// A poster's frame, width ÷ height: the timeline's crop by default; the post page passes the
    /// whole poster (`posterWhole`).
    var posterAspect: CGFloat = PostMedia.posterInFeed

    /// X's timeline crop of a tall picture, and the whole poster on the post page.
    static let posterInFeed: CGFloat = 4.0 / 5.0
    static let posterWhole: CGFloat = 2.0 / 3.0
    /// A key visual's faces sit about a third of the way down: the timeline's crop centres there.
    static let posterFocus: CGFloat = 0.36

    @Environment(\.displayScale) private var displayScale
    /// X's inline video, where the list installs it (the feed, the post page).
    @Environment(\.feedAutoplay) private var autoplay

    /// The feed's text column: the window less the row's insets, the avatar and the gap.
    static var columnWidth: CGFloat {
        ThemeMetrics.windowWidth - 2 * FeedMetrics.inset - FeedMetrics.avatar - FeedMetrics.gap
    }

    /// The decode budget: the frame's pixels, at most 1280 (900 on a constrained or expensive path).
    private var decodePixels: CGFloat {
        let constrained = SyncCenter.shared.isConstrained || SyncCenter.shared.isExpensive
        return min(constrained ? PostMedia.constrainedPixels : PostMedia.maxPixels, width * displayScale)
    }

    static let maxPixels: CGFloat = 1280
    static let constrainedPixels: CGFloat = 900

    /// A poster's budget is its LONG side: 1.5 × the width, up to 1800 px (1200 constrained).
    private var posterPixels: CGFloat {
        let constrained = SyncCenter.shared.isConstrained || SyncCenter.shared.isExpensive
        return min(constrained ? 1200 : 1800, width * 1.5 * displayScale)
    }

    /// The frame's shape: a poster's own, else X's 16:9.
    private var aspect: CGFloat {
        if case .art(let art) = model.media, art.portraitSource { return posterAspect }
        return 16.0 / 9.0
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: FeedMetrics.mediaRadius, style: .continuous)
        ZStack {
            shape.fill(ThemeColor.surfaceRaised)
            switch model.media {
            case .trailer(let stills, let video):
                ChainedRemoteImage(urls: stills, contentMode: .fill, maxPixel: decodePixels, onLoaded: onLoaded)
                if let autoplay, video.youtubeID != nil {
                    InlineTrailerSlot(postId: model.id, video: video, autoplay: autoplay)
                } else {
                    PlayGlyph()
                }
            case .art(let art):
                if art.portraitSource {
                    // The poster itself, filling its tall frame (the launch still signals on the
                    // picture's decode, never on the grey ground under it).
                    PostPoster(url: art.url, maxPixel: posterPixels, focus: Self.posterFocus, onLoaded: onLoaded)
                } else {
                    // `LandscapeArt`'s own landscape branch, with the load callback the launch needs.
                    RemoteImageView(url: art.url, contentMode: .fill,
                                    maxPixel: art.ultraWide ? max(decodePixels, LandscapeArt.ultraWidePixels) : decodePixels,
                                    alignment: .top, placeholderHidden: true, onLoaded: onLoaded)
                }
            case .none:
                EmptyView()
            }
        }
        .aspectRatio(aspect, contentMode: .fit)
        .clipShape(shape)
        .overlay(shape.strokeBorder(ThemeColor.feedSeparator, lineWidth: FeedMetrics.hairline))
    }
}

/// A poster filling a tall frame: laid out at its 2:3 and moved up so the frame's crop is centred
/// `focus` of the way down it. A 2:3 frame shows it whole.
private struct PostPoster: View {
    let url: String?
    let maxPixel: CGFloat
    let focus: CGFloat
    var onLoaded: (() -> Void)? = nil

    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            let tall = max(g.size.height, w / PostMedia.posterWhole)
            RemoteImageView(url: url, contentMode: .fill, maxPixel: maxPixel, alignment: .top,
                            placeholderHidden: true, onLoaded: onLoaded)
                .frame(width: w, height: tall)
                .offset(y: -(tall - g.size.height) * focus)
        }
        .clipped()
    }
}

extension LandscapeArt {
    /// An AniList banner's native width (`LandscapeArt.ultraWide`'s decode).
    static let ultraWidePixels: CGFloat = 1900
}

/// The platforms' play button: a white triangle in a dark translucent disc, nothing more.
struct PlayGlyph: View {
    private static let disc: CGFloat = 52
    private static let edge: CGFloat = 1.5

    var body: some View {
        AppGlyph(systemName: "play.fill")
            .font(.title3.weight(.bold))
            .foregroundStyle(FeedStage.ink)
            .offset(x: Self.edge)
            .frame(width: Self.disc, height: Self.disc)
            .background(FeedStage.glyphGround, in: Circle())
            .overlay(Circle().strokeBorder(FeedStage.ink.opacity(0.9), lineWidth: Self.edge))
            .accessibilityHidden(true)
    }
}

/// `matchedTransitionSource` when there is a namespace to register in (the feed's zoom), else
/// nothing (Saved and the other hosts that present no viewer).
struct ZoomSourceIfAny: ViewModifier {
    let id: String
    let namespace: Namespace.ID?

    func body(content: Content) -> some View {
        if let namespace {
            content.matchedTransitionSource(id: id, in: namespace) {
                $0.clipShape(RoundedRectangle(cornerRadius: FeedMetrics.mediaRadius, style: .continuous))
            }
        } else {
            content
        }
    }
}

// MARK: - The reminder primer slot

/// The alerts primer under the one post whose reminder is waiting on notification permission
/// (§4.4). Its own view, so only it observes `reminderPrimerPostId`, not every row.
private struct ReminderPrimerSlot: View {
    let model: FeedPostModel
    @Environment(AppModel.self) private var appModel

    var body: some View {
        if appModel.reminderPrimerPostId == model.id {
            AlertsPrimerLine(model: model)
                .padding(.top, ThemeSpace.x1)
                .padding(.bottom, ThemeSpace.x2)
                .transition(.opacity)
        }
    }
}

// MARK: - Share, from an accessibility action

/// The system share sheet, presented from the frontmost controller — for the row's "Share"
/// VoiceOver action (a `ShareLink` cannot be triggered from an action).
@MainActor
enum SystemShare {
    static func present(_ items: [Any]) {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first,
              let root = scene.windows.first(where: \.isKeyWindow)?.rootViewController else { return }
        var top = root
        while let presented = top.presentedViewController { top = presented }
        let sheet = UIActivityViewController(activityItems: items, applicationActivities: nil)
        sheet.popoverPresentationController?.sourceView = top.view
        top.present(sheet, animated: true)
    }
}

// MARK: - Glyph sizes

/// A symbol at an exact point size — the action bar's glyph, scaled with Dynamic Type and capped
/// (`@ScaledMetric` from `FeedMetrics.actionGlyph`). SF's own weights; no text is set with it.
enum FeedGlyph {
    static func font(_ size: CGFloat, weight: UIFont.Weight = .regular) -> Font {
        Font(UIFont.systemFont(ofSize: size, weight: weight))
    }
}
