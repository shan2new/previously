import SwiftUI
import WebKit

// A trailer, PLAYED (25 Sep: "The trailer viewing experience is extremely offputting. It should
// not open full screen by a mere click, player should be inline. The full screen experience is
// utter trash", owner).
//
// One player per trailer — YouTube's, driven through its IFrame API from a page of our own — that a
// post, a show page's card and the full screen all SHOW: the web view is handed from one surface to
// the other (`TrailerSurface`), so going full screen and coming back never reloads, never
// rebuffers and never drops the sound. What it replaced: a tap zoomed into a "stage" of blurred
// art and a lockup, which then handed the video to the system's own full-screen player — two
// full-screen transitions and a reload for one tap, and a stage left behind on the way out.
//
// Its chrome is ours. YouTube draws a title bar, a channel, a logo and a "more videos" card along
// its player's top and bottom edges; the player is THREE frames tall behind a 16:9 window, so all
// of that falls outside it and only the picture is seen (filmed 25 Sep, `InlineTrailerSlot`'s
// first cut). Every surface is exactly 16:9 for that reason.

@MainActor
@Observable
final class TrailerPlayback: Identifiable {
    enum Phase: Equatable { case loading, playing, paused, buffering, ended, failed }

    /// Which slot this is: a post's id in the feed, the video's own id on a show page.
    nonisolated let key: String
    let video: FranchiseVideo
    nonisolated var id: String { key }

    private(set) var phase: Phase = .loading
    private(set) var current: Double
    private(set) var duration: Double = 0
    /// The picture is MOVING (past its first frames): the still can come down. Not the provider's
    /// first "playing", which is a buffering frame or a black one.
    private(set) var moving = false
    private(set) var muted: Bool
    /// Watching, not previewing: the reader asked for it — sound, controls.
    var engaged: Bool
    /// The controls are on the picture.
    private(set) var chromeVisible = false
    /// The full screen holds the player (its surface owns the web view).
    var presenting = false {
        didSet {
            #if PREVIOUSLY_QA
            publishQAEvidence()
            #endif
        }
    }
    /// A scrub in progress: the time the finger is on (the controls stay while it lasts).
    private(set) var scrubbing: Double?

    @ObservationIgnored let webView: WKWebView
    @ObservationIgnored private let bridge: Bridge
    @ObservationIgnored private var hideTask: Task<Void, Never>?
    @ObservationIgnored private var destroyed = false
    #if PREVIOUSLY_QA
    @ObservationIgnored private let qaInstance = UUID().uuidString
    @ObservationIgnored private var qaEmbedHost = ""
    @ObservationIgnored private var qaProviderState = -1
    @ObservationIgnored private var qaProviderTime: Double = 0
    @ObservationIgnored private var qaProviderDuration: Double = 0
    @ObservationIgnored private var qaProviderMuted: Bool?
    @ObservationIgnored private var qaProviderError: Int?
    @ObservationIgnored private var qaProviderReports = 0
    #endif

    /// Seconds of play before the picture replaces the still.
    private static let revealAfter: Double = 0.4
    /// The controls leave this long after the last touch while the trailer plays.
    private static let chromeHold: Duration = .milliseconds(2600)

    init(key: String, video: FranchiseVideo, start: Double, muted: Bool, engaged: Bool) {
        self.key = key
        self.video = video
        self.current = start
        self.muted = muted
        self.engaged = engaged
        let bridge = Bridge()
        self.bridge = bridge
        let config = WKWebViewConfiguration()
        // Trailer browsing does not keep provider cookies or website data between players.
        config.websiteDataStore = .nonPersistent()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsPictureInPictureMediaPlayback = false
        config.allowsAirPlayForMediaPlayback = false
        config.userContentController.add(bridge, name: Self.channel)
        let view = WKWebView(frame: .zero, configuration: config)
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.isScrollEnabled = false
        view.scrollView.backgroundColor = .clear
        // Every touch is SwiftUI's: the post's gestures, the controls, the full screen's taps.
        view.isUserInteractionEnabled = false
        // The native controls provide the accessible player. Hide WebKit's offscreen provider
        // controls at the UIKit boundary too; SwiftUI's representable wrapper is not sufficient.
        view.isAccessibilityElement = false
        view.accessibilityElementsHidden = true
        self.webView = view
        bridge.playback = self
        #if PREVIOUSLY_QA
        publishQAEvidence()
        #endif
        if let id = video.youtubeID {
            view.loadHTMLString(Self.page(videoId: id, start: start, muted: muted), baseURL: Self.origin)
        } else {
            phase = .failed
        }
        if engaged { showChrome() }
    }

    // MARK: Commands

    func play() {
        if phase == .ended { replay(); return }
        run("cmd('play')")
        phase = phase == .loading ? .loading : .playing
        scheduleHide()
    }

    func pause() {
        run("cmd('pause')")
        if phase != .loading { phase = .paused }
        showChrome()
    }

    func togglePlay() {
        switch phase {
        case .playing, .buffering: pause()
        default: play()
        }
    }

    func setMuted(_ on: Bool) {
        guard on != muted else { return }
        muted = on
        run(on ? "cmd('mute')" : "cmd('unmute')")
    }

    /// Seconds from the start; clamped to the video.
    func seek(to seconds: Double) {
        let t = max(0, duration > 0 ? min(seconds, duration - 0.5) : seconds)
        current = t
        run("cmd('seek',\(t))")
        if phase == .ended { phase = .paused }
        scheduleHide()
    }

    func skip(_ seconds: Double) { seek(to: current + seconds) }

    func replay() {
        current = 0
        phase = .playing
        run("cmd('replay')")
        scheduleHide()
    }

    func beginScrub() {
        scrubbing = current
        hideTask?.cancel()
    }

    func scrub(to seconds: Double) {
        scrubbing = max(0, duration > 0 ? min(seconds, duration) : seconds)
    }

    func endScrub() {
        guard let target = scrubbing else { return }
        scrubbing = nil
        seek(to: target)
    }

    // MARK: Chrome

    func showChrome() {
        if !chromeVisible {
            withAnimation(Self.chromeMotion) { chromeVisible = true }
        }
        scheduleHide()
    }

    func hideChrome() {
        hideTask?.cancel()
        guard chromeVisible else { return }
        withAnimation(Self.chromeMotion) { chromeVisible = false }
    }

    func toggleChrome() {
        chromeVisible ? hideChrome() : showChrome()
    }

    /// While it plays and nothing is being touched, the controls leave on their own; paused,
    /// ended or mid-scrub, they stay.
    private func scheduleHide() {
        hideTask?.cancel()
        guard chromeVisible, phase == .playing || phase == .loading || phase == .buffering, scrubbing == nil else { return }
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: Self.chromeHold)
            guard !Task.isCancelled, let self, self.scrubbing == nil,
                  self.phase == .playing || self.phase == .buffering else { return }
            withAnimation(Self.chromeMotion) { self.chromeVisible = false }
        }
    }

    private static var chromeMotion: Animation {
        ThemeMotion.pick(ThemeMotion.uiGentle, reduceMotion: UIAccessibility.isReduceMotionEnabled)
    }

    // MARK: Life

    /// The web view goes: its page is emptied and its bridge let go. Only the owner calls this.
    func destroy() {
        guard !destroyed else { return }
        destroyed = true
        #if PREVIOUSLY_QA
        publishQAEvidence()
        #endif
        hideTask?.cancel()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: Self.channel)
        webView.stopLoading()
        webView.loadHTMLString("", baseURL: nil)
        webView.removeFromSuperview()
    }

    private func run(_ script: String) {
        guard !destroyed else { return }
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    // MARK: The provider's reports

    fileprivate func received(_ body: [String: Any]) {
        guard let kind = body["t"] as? String else { return }
        #if PREVIOUSLY_QA
        defer { publishQAEvidence() }
        #endif
        switch kind {
        case "ready":
            if let d = (body["d"] as? NSNumber)?.doubleValue, d > 0 { duration = d }
            #if PREVIOUSLY_QA
            if let raw = body["h"] as? String { qaEmbedHost = URL(string: raw)?.host ?? "" }
            qaProviderDuration = duration
            #endif
        case "state":
            #if PREVIOUSLY_QA
            qaProviderState = body["s"] as? Int ?? -1
            #endif
            // YouTube's states: 1 playing, 2 paused, 3 buffering, 0 ended, 5 cued, -1 unstarted.
            switch body["s"] as? Int {
            case 1:
                if phase != .playing { phase = .playing }
                scheduleHide()
            case 2:
                if phase != .paused { phase = .paused }
                if engaged { showChrome() }
            case 3:
                if phase == .playing || phase == .paused { phase = .buffering }
            case 0:
                phase = .ended
                moving = false
                if engaged { showChrome() }
            default:
                break
            }
        case "time":
            let c = (body["c"] as? NSNumber)?.doubleValue ?? current
            let d = (body["d"] as? NSNumber)?.doubleValue ?? 0
            #if PREVIOUSLY_QA
            qaProviderReports += 1
            if c.isFinite { qaProviderTime = c }
            if d.isFinite, d > 0 { qaProviderDuration = d }
            qaProviderMuted = body["m"] as? Bool
            if let state = body["s"] as? Int { qaProviderState = state }
            #endif
            if d > 0, abs(d - duration) > 0.5 { duration = d }
            if scrubbing == nil { current = c }
            if !moving, phase == .playing || phase == .buffering, c >= Self.revealAfter { moving = true }
        case "error":
            #if PREVIOUSLY_QA
            qaProviderError = body["c"] as? Int
            #endif
            phase = .failed
        default:
            break
        }
    }

    #if PREVIOUSLY_QA
    /// Read-only diagnostics are published from real IFrame API callbacks, rather than the
    /// optimistic state the native controls draw before a provider acknowledges a command.
    private func publishQAEvidence() {
        struct Snapshot: Encodable {
            let instance: String
            let key: String
            let host: String
            let persistent: Bool
            let providerState: Int
            let current: Double
            let duration: Double
            let muted: Bool?
            let moving: Bool
            let presenting: Bool
            let destroyed: Bool
            let error: Int?
            let providerReports: Int
        }
        let snapshot = Snapshot(instance: qaInstance, key: key, host: qaEmbedHost,
            persistent: webView.configuration.websiteDataStore.isPersistent,
            providerState: qaProviderState, current: qaProviderTime, duration: qaProviderDuration,
            muted: qaProviderMuted, moving: moving, presenting: presenting, destroyed: destroyed,
            error: qaProviderError, providerReports: qaProviderReports)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(snapshot), let value = String(data: data, encoding: .utf8) {
            TrailerPlaybackQAEvidence.shared.publish(value)
        }
    }
    #endif

    /// WebKit keeps its message handlers strongly; the bridge keeps the playback weakly, so a
    /// playback that is let go is not kept alive by its own page.
    @MainActor
    private final class Bridge: NSObject, WKScriptMessageHandler {
        weak var playback: TrailerPlayback?

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any] else { return }
            playback?.received(body)
        }
    }

    // MARK: The page

    private static let channel = "yt"
    /// The page's own origin — the referrer the provider sees, and the API's `origin`. A bare embed
    /// URL is refused ("Video player configuration error"), and so is one that claims to BE
    /// youtube.com ("unavailable · 152-4") — both captured 3 Sep.
    private static let origin = URL(string: "https://previously.local/trailer")

    /// The player in a black page: no controls of its own, no related wall, no captions or cards; it
    /// reports its time four times a second while it plays and at every change of state. Three
    /// frames TALL, centred on the frame — see the file's header.
    private static func page(videoId: String, start: Double, muted: Bool) -> String {
        let id = videoId.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        let from = max(0, Int(start))
        #if PREVIOUSLY_QA
        let qaTimeFields = ",m:player.isMuted(),s:player.getPlayerState()"
        let qaReadyFields = ",h:e.target.getIframe().src"
        let tickerCondition = "player&&player.getPlayerState"
        #else
        let qaTimeFields = ""
        let qaReadyFields = ""
        let tickerCondition = "player&&player.getPlayerState&&player.getPlayerState()===1"
        #endif
        return """
        <!doctype html><html><head><meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
        <style>html,body{margin:0;padding:0;background:#000;height:100%;overflow:hidden}#p{position:absolute;left:0;top:-100%;width:100%;height:300%;border:0}</style></head>
        <body><iframe id="p" width="100%" height="100%" title="YouTube trailer"
          src="https://www.youtube-nocookie.com/embed/\(id)?enablejsapi=1&amp;autoplay=1&amp;mute=1&amp;playsinline=1&amp;controls=0&amp;rel=0&amp;iv_load_policy=3&amp;disablekb=1&amp;fs=0&amp;modestbranding=1&amp;cc_load_policy=0&amp;start=\(from)&amp;origin=https%3A%2F%2Fpreviously.local"
          allow="autoplay; encrypted-media"></iframe>
        <script>
        var player;
        function post(m){try{window.webkit.messageHandlers.\(channel).postMessage(m)}catch(e){}}
        function tick(){if(!player||!player.getCurrentTime)return;post({t:'time',c:player.getCurrentTime(),d:player.getDuration()\(qaTimeFields)});}
        function onYouTubeIframeAPIReady(){
          // Bind the existing privacy-enhanced iframe; creating one here uses youtube.com.
          player=new YT.Player('p',{
            events:{
              onReady:function(e){\(muted ? "e.target.mute();" : "e.target.unMute();e.target.setVolume(100);")e.target.playVideo();post({t:'ready',d:e.target.getDuration()\(qaReadyFields)});},
              onStateChange:function(e){post({t:'state',s:e.data});tick();},
              onError:function(e){post({t:'error',c:e.data});}
            }});
          setInterval(function(){if(\(tickerCondition)){tick();}},250);
        }
        function cmd(n,a){if(!player||!player.playVideo)return;
          if(n==='play'){player.playVideo();}
          else if(n==='pause'){player.pauseVideo();}
          else if(n==='seek'){player.seekTo(a,true);tick();}
          else if(n==='mute'){player.mute();}
          else if(n==='unmute'){player.unMute();player.setVolume(100);}
          else if(n==='replay'){player.seekTo(0,true);player.playVideo();}
        }
        </script>
        <script src="https://www.youtube.com/iframe_api"></script>
        </body></html>
        """
    }
}

#if PREVIOUSLY_QA
@MainActor
@Observable
final class TrailerPlaybackQAEvidence {
    static let shared = TrailerPlaybackQAEvidence()
    private(set) var value = "{}"
    private init() {}
    fileprivate func publish(_ value: String) { self.value = value }
}
#endif

extension View {
    /// The modal's picture intentionally hides WebKit from accessibility. QA reads the provider
    /// report beside the native controls; production keeps its existing accessibility tree.
    @MainActor @ViewBuilder
    func qaTrailerEvidence() -> some View {
        #if PREVIOUSLY_QA
        overlay(alignment: .topLeading) {
            Text("QA trailer provider")
                .accessibilityIdentifier("qa.trailer.state")
                .accessibilityValue(TrailerPlaybackQAEvidence.shared.value)
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .allowsHitTesting(false)
        }
        #else
        self
        #endif
    }
}

// MARK: - The surface

/// Where a playback is SEEN: a host view that holds the playback's one web view while this surface
/// is the one that owns it — the inline surface unless the full screen is up, the full screen's
/// while it is. Handing over is a re-parent, so the picture and the sound never stop.
struct TrailerSurface: UIViewRepresentable {
    enum Role { case inline, fullScreen }

    let playback: TrailerPlayback
    let role: Role
    /// `playback.presenting`, passed in so a change reaches `updateUIView`.
    let presenting: Bool

    func makeUIView(context: Context) -> TrailerHostView {
        let host = TrailerHostView()
        host.backgroundColor = .clear
        host.clipsToBounds = true
        claim(host)
        return host
    }

    func updateUIView(_ host: TrailerHostView, context: Context) {
        claim(host)
    }

    /// The web view is the playback's: a surface that goes away leaves it where it is.
    static func dismantleUIView(_ host: TrailerHostView, coordinator: ()) {}

    private func claim(_ host: TrailerHostView) {
        let owns = (role == .fullScreen) == presenting
        guard owns, playback.webView.superview !== host else { return }
        host.adopt(playback.webView)
    }
}

final class TrailerHostView: UIView {
    func adopt(_ view: UIView) {
        view.removeFromSuperview()
        view.frame = bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(view)
    }
}
