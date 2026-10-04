import SwiftUI

// The feed's tokens (25 Sep build). The Today feed, the post page, Activity and the composer are set
// on X's measured iOS grid and palette, and the stories, the people's discs, the bursts and the rating
// track wear the Align film's five gels. The spike carried these as literals in four places; they
// live here now, and a screen references only these names (never a hex, never a point size).

// MARK: - Colour

extension ThemeColor {
    // The feed's GRID is X's, measured at 393 pt (25 Sep); its INK is the app's own (4 Oct:
    // "improve the design system and colours everywhere", owner). It wore X's palette too — a cool
    // white (#E7E9EA), a blue-grey (#7D8287), blue-black cards — one tab away from Home's warm
    // ivory and graphite: two temperatures in one app, and the feed's read as someone else's. The
    // roles and their contrast are X's still; the hues are this ramp's.
    static let feedText = ThemeColor.textPrimary
    /// The feed's grey: X's ROLE (stamps, handles, meta) at X's weight, in the app's warm grey.
    /// #8C8781 is 5.5:1 on the canvas and 4.9:1 on `feedCard` (X's own #71767B was 4.34 and 3.88
    /// here — under AA for the 13–16-pt lines it sets).
    static let feedSecondary = Color(hex: 0x8C8781)
    static let feedSeparator = Color(hex: 0x302F33)
    static let feedCard = ThemeColor.surfaceFlat
    static let feedField = Color(hex: 0x222225)
    /// A row's ground while pressed (X lifts the row a shade; no scale).
    static let feedPressed = Color.white.opacity(0.045)
    /// The like: the icon's rose gel — warmth, not news (red) and not a fact (amber).
    static let like = Color(hex: 0xF0467F)
    /// The rating sticker's ink on its white card.
    static let stickerInk = Color(hex: 0x16151A)
    static let stickerCard = Color.white
    /// Hairline around a show avatar.
    static let avatarEdge = Color.white.opacity(0.1)
    /// Hairline around a person's monogram disc.
    static let discEdge = Color.white.opacity(0.14)
    /// A story ring once its reel has been watched: a quiet grey circle where the gels were.
    static let storyRingSeen = Color.white.opacity(0.22)
    /// Instagram's double-tap heart over a picture — white, whatever the art.
    static let likeOverArt = Color.white
    /// The Activity bell's unread dot. The same red as NEWS (`ThemeColor.news`) because it says the
    /// same thing — something new is waiting — and it is that red's only use outside the NEW tags.
    /// Named for its role so `news` keeps its rule. The rows themselves mark unread with a ground
    /// (`accentSoft`, state), never with an amber glyph.
    static let unreadDot = ThemeColor.news
}

// MARK: - The five gels

/// The Align film's five gels (gold → amber → coral → rose → violet) — the stories ring, the
/// people's monogram discs, the bursts, the rating track, CaughtUpMarker. They are the brand's
/// light, and in the ring they still read as "stories" (Instagram's own ring runs the same way).
enum ThemeGel {
    static let gold = Color(hex: 0xFFCC57), amber = Color(hex: 0xFF8F33), coral = Color(hex: 0xFA5440)
    static let rose = Color(hex: 0xE63D85), violet = Color(hex: 0x8F4DF5)
    /// The five, in the icon's order.
    static let all: [Color] = [gold, amber, coral, rose, violet]
    /// The unseen story ring (and CaughtUpMarker's ring): the gels round the circle and back, so
    /// the seam at the top is gold meeting gold.
    static let ring = AngularGradient(colors: [gold, amber, coral, rose, violet, rose, amber, gold],
                                      center: .center, startAngle: .degrees(-40), endAngle: .degrees(320))
    /// The rating slider's track.
    static let track = LinearGradient(colors: all, startPoint: .leading, endPoint: .trailing)

    /// A person's disc colour: stable per user id (FNV-1a 32 of the id's UTF-8, mod 5). Not data —
    /// a colour, so the same person wears the same gel on every device and every launch.
    static func color(forUserId id: String) -> Color {
        var hash: UInt32 = 0x811C_9DC5
        for byte in id.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 0x0100_0193
        }
        return all[Int(hash % UInt32(all.count))]
    }
}

// MARK: - Metrics

enum FeedMetrics {
    /// Row side inset. With the 44-pt avatar and the 8-pt gap, the text column starts at 62 (X's).
    static let inset: CGFloat = 10
    /// A show's or a person's avatar in a row.
    static let avatar: CGFloat = 44
    /// Avatar → text column.
    static let gap: CGFloat = 8
    static let rowTop: CGFloat = 12, rowBottom: CGFloat = 6
    /// A reply row's reply and like slots (a post's share their room equally — `PostActionBar`).
    static let actionSlot: CGFloat = 68
    /// A post's pinned save and share slots: glyphs 32 apart, as X's bookmark and share are (the hit
    /// area is still 44).
    static let actionSlotSmall: CGFloat = 32
    /// The pinned pair steps this far into the row's trailing inset, so the share glyph centres
    /// 6½ pt inside the text column's edge and the save glyph 32 pt before it — X's, measured.
    static let actionPinnedPull: CGFloat = 9.5
    /// Every action-bar target (the spike's were 36).
    static let actionHitHeight: CGFloat = 44
    /// Action glyphs; rows scale them with `@ScaledMetric(relativeTo: .footnote)`, capped at
    /// `actionGlyph * actionGlyphMaxScale` so the bar stays one row at the accessibility sizes.
    static let actionGlyph: CGFloat = 17, actionGlyphLarge: CGFloat = 19
    static let actionGlyphMaxScale: CGFloat = 1.6
    /// X's card corner, measured off the owner's X (26 Sep): the media, and the rumour's Community
    /// Note that stands in for it, at 16 inside the one-pixel `feedSeparator` edge.
    static let mediaRadius: CGFloat = 16
    static let noteRadius: CGFloat = 16
    /// A show wears a rounded square (X's organisation avatar), a person a circle.
    static let showCornerRatio: CGFloat = 0.22
    /// X's rule and border: one physical pixel (`ThemeMetrics.pixel`), never 0.5 pt or 1 pt — every
    /// separator, media edge, note box and capsule outline in the feed's surfaces uses it.
    static var hairline: CGFloat { ThemeMetrics.pixel }
    /// `FeedHeader.height` = headerRow + headerTabs + hairline.
    static let headerRow: CGFloat = 44, headerTabs: CGFloat = 44
    /// Instagram's tray, measured off the owner's screenshot at 393 pt (25 Sep): a 92-pt ring, a
    /// 3.4-pt stroke, a 2.4-pt gap, an 80-pt photo, 12 pt between rings. The build's 66 read as
    /// a row of badges ("Stories circle are much bigger and better", owner).
    static let storyBubble: CGFloat = 92, storyBubbleSpacing: CGFloat = 12, storyNameWidthExtra: CGFloat = 8
    /// The ring's NEW tag (Instagram's LIVE tag): 18 tall, a 4-pt corner, cut out of the ring by a
    /// 2-pt rim of the canvas, its middle on the ring's bottom edge.
    static let ringTagHeight: CGFloat = 18, ringTagRadius: CGFloat = 4, ringTagRim: CGFloat = 2
    static let pillHeight: CGFloat = 38, pillAvatar: CGFloat = 22
    static let caughtUpRing: CGFloat = 58
    static let composeAvatar: CGFloat = 40, replyBarAvatar: CGFloat = 34, replyFieldHeight: CGFloat = 36
    static let personDisc: CGFloat = 40
    static let storyFrameSeconds: Double = 6
    static let storyHoldDelay: Duration = .milliseconds(220)
    /// Discover's top pick card: h = w × aspect.
    static let topPickAspect: CGFloat = 1.02
    static let topPickLogoHeight: CGFloat = 64

    // Press feedback (FeedComponents' press styles).
    /// An action-bar icon's dip while the finger is down.
    static let iconPressScale: CGFloat = 0.86
    /// A story bubble's dip while the finger is down.
    static let bubblePressScale: CGFloat = 0.93
    /// A trailer still at or under this width is YouTube's grey "no frame" placeholder (120×90),
    /// served with a 200 for some uploads — `ChainedRemoteImage` moves on to the next candidate.
    static let stillPlaceholderMaxWidth: CGFloat = 120
    /// The pixel size an avatar's picture is decoded at for its subject crop (drawn at 22–66 pt).
    static let avatarDecodePixels: CGFloat = 480
}

// MARK: - Type

extension ThemeType {
    // The feed's type is the APP'S — OUTFIT (25 Sep: "our app's font is Outfit not whatever X has.
    // Don't change the damn identity of the app", owner): names, handles, stamps, tabs, buttons,
    // titles. X's anatomy, X's sizes, our face. Outfit's lowercase is shorter than Chirp's (x-height
    // ≈ 0.48 against ≈ 0.53), so Outfit 16 reads as X's 15: the name and the handle line sit at 16.
    // Text styles (`relativeTo:`), so everything scales with Dynamic Type. Point sizes are the
    // default content size's.
    //
    // The WORDS of a post are SF (26 Sep: "I don't think Outfit is the right font for reading the
    // tweet text", owner) — `prose`'s rule: what a post or a reply says is content, not the app's
    // voice, and a geometric display face with a short x-height tires the eye over a paragraph that
    // SF Text, drawn for reading, carries. X's sizes on X's lines: 15 on 20 in the timeline
    // (measured off the owner's X), 17 on the post page, 15 in a note. Regular, tracking 0 — SF
    // tracks itself by size. The Outfit Light that parted the words from the SemiBold name (25 Sep:
    // "X's ones are lighter") went with them: SF Regular a point under the name is already the
    // lighter line, in the same ink. A glyph sized to the text reads `feedMeta.font`, never the body's.
    static let feedName = TypeToken(font: .custom("Outfit-SemiBold", size: 16, relativeTo: .callout), tracking: -0.15)
    static let feedMeta = TypeToken(font: .custom("Outfit-Regular", size: 16, relativeTo: .callout), tracking: -0.10)
    /// The name over a post's or a reply's words — X's 15, the words' own size (26 Sep: at 16 the
    /// Outfit name read "chunky" beside X's bold 15 — a cap 7 % taller, a line ~15 % wider). Its
    /// grey installment and stamp are `feedSubhead`, X's 15 as well.
    static let feedPostName = TypeToken(font: .custom("Outfit-SemiBold", size: 15, relativeTo: .subheadline), tracking: -0.10)
    /// A post's words — in a row, a pinned post, a reply, the composer's quote: SF 15.
    static let feedBody = TypeToken(font: .system(.subheadline), tracking: 0)
    /// The post page's words (X's detail sets its text a size up): SF 17.
    static let feedBodyLarge = TypeToken(font: .system(.body), tracking: 0)
    /// A Community Note's words, a reply quoted in Activity, a headline in the story's trail, a post's
    /// words under its picture: SF 15. The note's title is the app speaking (`feedNoteTitle`).
    static let feedNote = TypeToken(font: .system(.subheadline), tracking: 0)
    static let feedNoteTitle = TypeToken(font: .custom("Outfit-SemiBold", size: 15, relativeTo: .subheadline), tracking: -0.10)
    /// The app's own 15-pt line — a folded post, "Replying to @…", a stamp, the likes line, an empty
    /// or locked state — and the glyphs sized to it: `feedNote`'s Outfit, kept when the words left.
    static let feedSubhead = TypeToken(font: .custom("Outfit-Regular", size: 15, relativeTo: .subheadline), tracking: -0.05)
    /// The app's own sentences on the feed's surfaces — the rules, a report's reasons, a show's bio,
    /// the caught-up and discussion headings — keep the Outfit Light the post words wore until 26 Sep.
    static let feedLight = TypeToken(font: .custom("Outfit-Light", size: 16, relativeTo: .callout), tracking: -0.05)
    static let feedLightLarge = TypeToken(font: .custom("Outfit-Light", size: 18, relativeTo: .body), tracking: -0.10)
    static let feedSmall = TypeToken(font: .custom("Outfit-Regular", size: 13, relativeTo: .footnote), tracking: 0)
    static let feedCount = TypeToken(font: .custom("Outfit-Regular", size: 13, relativeTo: .footnote).monospacedDigit(), tracking: 0)
    static let feedCountLarge = TypeToken(font: .custom("Outfit-Regular", size: 15, relativeTo: .subheadline).monospacedDigit(), tracking: 0)
    /// X's tabs, measured (round 3): the same weight in BOTH states — only the ink says which is
    /// selected, so the word never reflows under the sliding underline.
    static let feedTab = TypeToken(font: .custom("Outfit-SemiBold", size: 16, relativeTo: .callout), tracking: -0.15)
    static let feedModuleTitle = TypeToken(font: .custom("Outfit-SemiBold", size: 20, relativeTo: .title3), tracking: -0.30)
    static let feedPill = TypeToken(font: .custom("Outfit-SemiBold", size: 14, relativeTo: .subheadline), tracking: 0)
    static let storyName = TypeToken(font: .custom("Outfit-Regular", size: 12, relativeTo: .caption), tracking: 0)
    /// The ring's NEW tag: Instagram's LIVE tag, heavy caps at a fixed size (the tag is part of the
    /// ring, which does not grow with Dynamic Type).
    static let storyRingTag = TypeToken(font: .custom("Outfit-Bold", fixedSize: 10), tracking: 0.6)
    /// The reply bar at rest and the story's reply row: the app inviting a reply, so Outfit.
    static let storyReply = TypeToken(font: .custom("Outfit-Regular", size: 15, relativeTo: .subheadline), tracking: -0.05)
    /// What you type in the composer or the open reply bar is a post's words: SF 17, the post page's
    /// size. (Choosing a name or a username is not — `IdentitySetupView` sets `ThemeType.body`.)
    static let composeField = TypeToken(font: .system(.body), tracking: 0)
    /// Schedule's caps — a weekday over its date, the card's moment ("TONIGHT AT 7:30 PM"), the
    /// month the agenda crosses into, "LATER" — in the app's face: the system's small caps beside
    /// Outfit names read as a second font on every row (the feed's own lesson, 25 Sep).
    static let feedEyebrow = TypeToken(font: .custom("Outfit-SemiBold", size: 12, relativeTo: .caption), tracking: 0.9)
    /// Schedule's date numeral — the rows' date column and the month grid's cells, one instrument.
    static let feedDate = TypeToken(font: .custom("Outfit-SemiBold", size: 18, relativeTo: .subheadline).monospacedDigit(), tracking: 0)
    /// A chart row's rank numeral (Discover's Trending).
    static let trendRank = TypeToken(font: .custom("Outfit-SemiBold", size: 20, relativeTo: .title3).monospacedDigit(), tracking: 0)
    /// A genre tile's name. SemiBold 17, not Bold 18: Outfit's Bold is rounder and heavier than
    /// SF's, and at 18 the names read chunky, like a template ("genre card copy text font needs
    /// rework, it's poorly built", owner, 26 Sep; four treatments compared on the real art).
    static let genreName = TypeToken(font: .custom("Outfit-SemiBold", size: 17, relativeTo: .headline), tracking: -0.15)
    /// A show page's name — X's profile name, a step above the page title.
    static let feedProfileName = TypeToken(font: .custom("Outfit-Bold", size: 22, relativeTo: .title2), tracking: -0.35)
    /// X's page title beside its back arrow ("Post").
    static let feedPageTitle = TypeToken(font: .custom("Outfit-SemiBold", size: 20, relativeTo: .title3), tracking: -0.30)
    /// A person's monogram at the 40-pt disc (`FeedMetrics.personDisc`). Other discs use
    /// `discMonogram(diameter:)`, which keeps the same letter-to-disc proportion. FIXED size, as
    /// `AccountDisc`'s is: the disc does not grow with Dynamic Type, so a letter that did would
    /// spill past its circle at the accessibility sizes.
    static let discMonogram = TypeToken(font: .custom("Outfit-SemiBold", fixedSize: discMonogramSize), tracking: 0)
    static let stickerQuestion = TypeToken(font: .custom("Outfit-SemiBold", size: 19, relativeTo: .headline), tracking: 0)

    /// `discMonogram` scaled to a disc of `diameter` points (`size / 40` ≈ 0.42 × the disc), so a
    /// 22-pt pill face and a 44-pt comment author carry the same proportion as the 40-pt disc.
    static func discMonogram(diameter: CGFloat) -> TypeToken {
        let size = discMonogramSize * max(diameter, 1) / FeedMetrics.personDisc
        return TypeToken(font: .custom("Outfit-SemiBold", fixedSize: size), tracking: 0)
    }

    private static let discMonogramSize: CGFloat = 17
}

// MARK: - Motion and elevation

extension ThemeMotion {
    /// X's row press: the ground appears at once under the finger and fades on release.
    static let feedPressRelease = Animation.easeOut(duration: 0.28)
    /// A story ring while its reel loads: dashes turning once every 1.1 s (Instagram's wait).
    /// Never under Reduce Motion — the dashes hold still there.
    static let feedRingSpin = Animation.linear(duration: 1.1).repeatForever(autoreverses: false)
}

extension ShadowToken {
    /// The double-tap heart's contact shadow over a picture (a transient glyph, not a card).
    static let likeOverArt = ShadowToken(color: .black.opacity(0.28), radius: 14, y: 4)
}
