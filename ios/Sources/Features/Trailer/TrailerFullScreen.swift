import SwiftUI

// The trailer, FULL SCREEN — only when asked for (the full-screen switch on the controls, or the
// phone turned on its side while a trailer is being watched, YouTube's way): the SAME player zooms
// out of its post onto black (the system's zoom transition, so a swipe down carries it back), keeps
// playing with its sound, and turns with the phone. The controls are the inline ones' family, a
// size up: close and the video's name along the top, back ten · play/pause · forward ten in the
// middle, the scrubber with the time, the sound and the way back out along the foot. A tap brings
// them, and they leave on their own while it plays — the status bar and the home indicator with
// them.
//
// It replaced the "stage" (a blurred-art lockup that handed the video to the system's own player):
// "The full screen experience is utter trash" (owner, 25 Sep).

struct TrailerFullScreen: View {
    let playback: TrailerPlayback
    /// The show — the top line.
    let title: String
    /// The video's own name beneath ("Official Trailer · Season 2"), when it adds to the title.
    var subtitle: String?
    /// Opened by turning the phone: turning it back upright is the way out (YouTube's).
    var byRotation = false
    /// The cover has gone: the player goes back to its post.
    let onClosed: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The drag that closes it, the picture viewer's (`FeedMediaViewer`): the picture follows the
    /// finger, the black thins, the controls step aside; let go far enough and it goes home.
    @State private var drag: CGSize = .zero

    private enum Reach {
        static let closeDistance: CGFloat = 110
        static let closePredicted: CGFloat = 320
        static let awayDistance: CGFloat = 360
    }

    var body: some View {
        let away = min(1, abs(drag.height) / Reach.awayDistance)
        ZStack {
            Color.black
                .opacity(1 - away * 0.75)
                .ignoresSafeArea()
            // The picture, 16:9, as large as the screen allows — the black is the letterbox.
            picture
                .scaleEffect(1 - away * 0.18)
                .offset(drag)
                .ignoresSafeArea()
            // Anywhere that is not a control brings the controls or sends them away, and a drag
            // from it carries the picture home.
            Color.clear
                .contentShape(Rectangle())
                .ignoresSafeArea()
                .onTapGesture { playback.toggleChrome() }
                .gesture(dragToClose)
                .accessibilityHidden(true)
            if playback.chromeVisible {
                controls
                    .opacity(1 - away * 1.6)
                    .transition(.opacity)
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(!playback.chromeVisible)
        .persistentSystemOverlays(playback.chromeVisible ? .automatic : .hidden)
        .onAppear {
            OrientationGate.set(allowsLandscape: true)
            if byRotation { OrientationGate.follow(UIDevice.current.orientation) }
            // Full screen is watching: the sound comes on and the controls say where it is.
            playback.engaged = true
            playback.setMuted(false)
            if playback.phase == .paused { playback.play() }
            playback.showChrome()
        }
        .onDisappear {
            OrientationGate.set(allowsLandscape: false)
            onClosed()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            guard byRotation, UIDevice.current.orientation == .portrait else { return }
            dismiss()
        }
        .accessibilityAction(.escape) { dismiss() }
        .qaTrailerEvidence()
    }

    private var dragToClose: some Gesture {
        DragGesture(minimumDistance: ThemeSpace.x2)
            .onChanged { drag = $0.translation }
            .onEnded { v in
                if abs(v.translation.height) > Reach.closeDistance
                    || abs(v.predictedEndTranslation.height) > Reach.closePredicted {
                    dismiss()
                } else {
                    withAnimation(ThemeMotion.pick(ThemeMotion.uiSnappy, reduceMotion: reduceMotion)) { drag = .zero }
                }
            }
    }

    // MARK: The picture

    private var picture: some View {
        let holds = playback.presenting
        return ZStack {
            Color.black
            TrailerSurface(playback: playback, role: .fullScreen, presenting: playback.presenting)
                .opacity(holds && playback.moving ? 1 : 0)
            // The still while the picture is not moving: loading, ended, or refused.
            if !(holds && playback.moving) {
                RemoteImageView(url: playback.video.thumbnailURL, contentMode: .fill, maxPixel: 1600,
                                placeholderHidden: true)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(ThemeMotion.pick(ThemeMotion.uiGentle, reduceMotion: false), value: playback.moving)
        .accessibilityHidden(true)
    }

    // MARK: The controls

    private var controls: some View {
        VStack(spacing: 0) {
            top
            Spacer(minLength: 0)
            HStack(spacing: ThemeSpace.x10) {
                TrailerGlyphButton(systemName: "gobackward.10", label: Copy.Video.back10, size: 26) {
                    playback.skip(-10)
                    playback.showChrome()
                }
                TrailerPlayPauseButton(playback: playback, size: 72)
                TrailerGlyphButton(systemName: "goforward.10", label: Copy.Video.forward10, size: 26) {
                    playback.skip(10)
                    playback.showChrome()
                }
            }
            Spacer(minLength: 0)
            foot
        }
        .padding(.horizontal, ThemeSpace.x2)
        .background {
            // Over a landscape picture the words need a floor; over portrait's black they are on it.
            VStack(spacing: 0) {
                LinearGradient(colors: [.black.opacity(0.6), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: 140)
                Spacer(minLength: 0)
                LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 170)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
        }
    }

    private var top: some View {
        HStack(alignment: .center, spacing: ThemeSpace.x2) {
            TrailerGlyphButton(systemName: "chevron.down", label: Copy.Video.close, size: 19) { dismiss() }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .type(ThemeType.feedName)
                    .foregroundStyle(TrailerStyle.ink)
                    .lineLimit(1)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .type(ThemeType.feedSmall)
                        .foregroundStyle(TrailerStyle.ink.opacity(0.72))
                        .lineLimit(1)
                }
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
            if let url = playback.video.watchURL {
                TrailerGlyphButton(systemName: "arrow.up.right", label: playback.video.youtubeID != nil
                                   ? Copy.Action.openOnYouTube : Copy.Action.openInBrowser, size: 17) {
                    playback.pause()
                    openURL(url)
                }
            }
        }
        .padding(.top, ThemeSpace.x1)
    }

    private var foot: some View {
        VStack(spacing: 0) {
            TrailerScrubber(playback: playback, track: 3, knob: 14, hitHeight: 32)
                .padding(.horizontal, ThemeSpace.x2)
            HStack(spacing: 0) {
                Text(Copy.Video.clockPair(playback.scrubbing ?? playback.current, playback.duration))
                    .type(ThemeType.feedCount)
                    .foregroundStyle(TrailerStyle.ink)
                    .padding(.leading, ThemeSpace.x2)
                    .accessibilityHidden(true)
                Spacer(minLength: 0)
                TrailerGlyphButton(systemName: playback.soundGlyph, label: playback.soundLabel) {
                    playback.setMuted(!playback.muted)
                    playback.showChrome()
                }
                TrailerGlyphButton(systemName: "arrow.down.right.and.arrow.up.left", label: Copy.Video.exitFullScreen) {
                    dismiss()
                }
            }
        }
        .padding(.bottom, ThemeSpace.x1)
    }
}

extension TrailerFullScreen {
    /// "Official Trailer · Season 2" — the video's own name (its kind, where the name is only the
    /// show's), then the part it belongs to.
    static func subtitle(_ video: FranchiseVideo, show: String) -> String? {
        var bits: [String] = []
        let kind = Copy.Video.kind(video.kind)
        if let name = video.title(cleanedFor: show), name.caseInsensitiveCompare(kind) != .orderedSame {
            bits.append(name)
        } else {
            bits.append(kind)
        }
        if let part = video.partLabel, !bits.contains(part) { bits.append(part) }
        return bits.joined(separator: " \u{00B7} ")
    }
}
