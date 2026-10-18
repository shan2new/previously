import Foundation

// The feed's capture launch arguments (spec §6.3) — the ONE place a feed screen reads them. They
// exist so QA can photograph a state the simulator cannot reach by touch: they may select, open,
// anchor or freeze; they never fabricate a count, a fresh mark or a social row.
//
// Every value is read once (a `static let` is initialised lazily, on first use) and compiled to its
// resting value outside DEBUG, so a call site needs no `#if` of its own and a Release build carries
// no launch-argument branch at all (the `PerfProbe.flag` pattern).
//
//   -feedAnchor top|stories|caughtup|trending|<post id prefix>
//                                       scroll the loaded feed there (1.5 s after content)
//   -feedSkeleton 1                     hold the skeleton
//   -feedPinHeader 1                    the header never slides
//   -feedStory first|<franchiseId>      open the story viewer on a reel, clock frozen
//   -feedStoryFrame N                   … on frame N
//   -feedMedia first                    open the first picture post's viewer
//   -feedTrailer inline|full            play the first trailer post in its post (then full screen)
//   -feedThread first|<postId>          push a post page
//   -feedThreadAnchor replies|sources   on that page, scroll to the replies / open the trail
//   -feedCompose "<text>"               on a pushed page, open the composer prefilled (never sends)
//   -feedActivity 1                     open the bell's sheet
//   -feedConstrained 1                  force the Low Data path (story art, §5.4)
//   -openProfile 1                      open Profile from the feed
//   -openSaved 1                        push Saved
//   -discoverGenre <key>                with -openTab discover, push that genre page

enum FeedCapture {
    // `-feedTab foryou` went with the feed's For you page (16 Oct): For you is Discover's.
    /// `-feedAnchor`: where the loaded feed scrolls for a capture.
    static let anchor: String? = string("feedAnchor")
    /// `-feedSkeleton 1`: the skeleton is held, whatever the feed's phase.
    static let holdSkeleton: Bool = flag("feedSkeleton")
    /// `-feedPinHeader 1`: captures that jump to a post keep the bar in shot.
    static let pinHeader: Bool = flag("feedPinHeader")
    /// `-feedStory first|<franchiseId>`: open the viewer on this reel.
    static let story: String? = string("feedStory")
    /// `-feedStoryFrame N`: … on this frame.
    static let storyFrame: Int = integer("feedStoryFrame")
    /// A capture opened the viewer: its clock holds still (StoryClock's pause reasons).
    static var storyFrozen: Bool { story != nil }
    /// `-feedMedia first`: open the first picture post's viewer.
    static let media: String? = string("feedMedia")
    /// `-feedTrailer inline|full`: scroll to the first trailer post and play it there, as a tap
    /// does (then, with `full`, open its full screen).
    static let trailer: String? = string("feedTrailer")
    /// `-feedThread first|<postId>`: push a post page.
    static let thread: String? = string("feedThread")
    /// `-feedThreadAnchor replies|sources`: where a pushed post page lands.
    static let threadAnchor: String? = string("feedThreadAnchor")
    /// `-feedCompose "<text>"`: a pushed post page opens its composer with this draft. Never sends.
    static let compose: String? = string("feedCompose")
    /// `-feedActivity 1`: open the bell's sheet.
    static let activity: Bool = flag("feedActivity")
    /// `-feedConstrained 1`: the story art's Low Data path (the simulator cannot set Low Data Mode).
    static let constrained: Bool = flag("feedConstrained")
    /// `-openProfile 1`: open Profile from the feed's header disc.
    static let openProfile: Bool = flag("openProfile")
    /// `-openSaved 1`: push Saved on Today.
    static let openSaved: Bool = flag("openSaved")
    /// `-discoverGenre <key>`: push that genre page on Discover.
    static let discoverGenre: String? = string("discoverGenre")

    /// How long after content lands a capture scrolls or opens (the lazy stack has laid out, the
    /// first pictures are in).
    static let landingDelay: Duration = .milliseconds(1500)
    /// How long after a pushed post page appears its capture anchor or composer lands.
    static let threadLandingDelay: Duration = .milliseconds(900)

    // MARK: - Reading

    private static func string(_ key: String) -> String? {
        #if DEBUG
        guard let value = UserDefaults.standard.string(forKey: key)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
        #else
        return nil
        #endif
    }

    private static func flag(_ key: String) -> Bool {
        #if DEBUG
        return UserDefaults.standard.bool(forKey: key)
        #else
        return false
        #endif
    }

    private static func integer(_ key: String) -> Int {
        #if DEBUG
        return max(0, UserDefaults.standard.integer(forKey: key))
        #else
        return 0
        #endif
    }
}
