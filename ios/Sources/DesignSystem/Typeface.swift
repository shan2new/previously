import SwiftUI
import UIKit

// THE TYPE SETS (19 Oct: "We probably need a different set of fonts for the content and at various
// places. Outfit isn't suited well everywhere, clearly. This will lead to a better typography too
// without losing the App's…", owner).
//
// Outfit is the app's identity and stays its DISPLAY face in every set — the wordmark, screen and
// section titles, the stage's names, the buttons. What a set changes is everything Outfit was never
// drawn for: a geometric face with round bowls and short descenders is a voice at 20 pt and up, and
// at 13–17 pt in a list of forty rows it is a texture — its numerals proportional, its tabular figures
// gappy ("1 4"), its Light cut thin on a dark ground. Every type token names a ROLE, and a set says
// which face each role is drawn in:
//   · display    — identity. Outfit, always.
//   · title      — the NAME of a thing: a show on a row, a card or a shelf, an episode line, a
//                  headline, a post's account. Outfit, always (19 Oct: "I think Titles should've
//                  kept Outfit", owner — the first Hanken pass had set them in the content face).
//   · text       — labels, controls' words, the lines under a title: the app's working voice.
//   · reading    — a post's words, a research note (SF Pro as shipped).
//   · paragraph  — the synopsis and the app's other long lines that shipped in Outfit Light.
//   · annotation — the small grey line under a row, a section's eyebrow, the time, a count.
//   · headline   — a news story's headline.
//
//   outfit     as shipped: Outfit text, SF Pro reading and annotation.
//   sf         Outfit display + SF Pro everywhere else — the platform's own text face.
//   hanken     Outfit display + Hanken Grotesk everywhere else — a grotesk with a little warmth,
//              closer to Outfit's shapes than SF, so the two read as one family.
// (An `editorial` set — Newsreader, a serif, for the news and the synopses — was photographed and
// rejected the same day: "What is this ugly piece of shit?", owner. No serif.)
//
// HANKEN SHIPS (19 Oct: "Ship Hanken Grotesk as the content font (Outfit stays display)", owner).
// DEBUG builds can still draw the others for a comparison with `-typeSet outfit|sf`. Read once, at
// launch: the tokens are built from it.
enum TypeSet: String, CaseIterable, Identifiable {
    case outfit, sf, hanken

    var id: String { rawValue }

    /// The set the app ships (19 Oct).
    static let chosen: TypeSet = .hanken

    static let current: TypeSet = {
        #if DEBUG
        if let raw = UserDefaults.standard.string(forKey: "typeSet"), let set = TypeSet(rawValue: raw) { return set }
        #endif
        return chosen
    }()
}

enum Typeface {
    enum Role { case display, title, text, reading, paragraph, annotation, headline }

    /// The font a role is drawn in, at `size` scaled with Dynamic Type from `style`.
    static func font(_ role: Role, _ weight: Font.Weight, _ size: CGFloat, _ style: Font.TextStyle) -> Font {
        let face = face(role)
        // Outfit's Light is a shipped look; no other face is drawn thin on the dark ground.
        let weight = face != .outfit && weight == .light ? .regular : weight
        switch face {
        case .outfit: return .custom(AppFont.name(weight), size: size, relativeTo: style)
        case .hanken: return .custom(hanken(weight), size: size, relativeTo: style)
        case .system:
            // SF at a text style's own size scales with it; any other size is the size asked for.
            return size == defaultSize(style) ? .system(style, weight: weight) : .system(size: size, weight: weight)
        }
    }

    /// A role's face at a FIXED size (no Dynamic Type) — for callers that scale it themselves.
    static func fixedFont(_ role: Role, _ weight: Font.Weight, _ size: CGFloat) -> Font {
        let face = face(role)
        let weight = face != .outfit && weight == .light ? .regular : weight
        switch face {
        case .outfit: return .custom(AppFont.name(weight), fixedSize: size)
        case .hanken: return .custom(hanken(weight), fixedSize: size)
        case .system: return .system(size: size, weight: weight)
        }
    }

    /// A role's tracking. Outfit's tokens carry tracking tuned for Outfit; the other faces are drawn
    /// at their own spacing (SF tracks itself optically), except caps, which keep their letter-space.
    static func tracking(_ role: Role, _ outfit: CGFloat) -> CGFloat {
        // As shipped, every token keeps the tracking it was given (SF's included).
        if TypeSet.current == .outfit || face(role) == .outfit || outfit > 0 { return outfit }
        return 0
    }

    private enum Face { case outfit, system, hanken }

    private static func face(_ role: Role) -> Face {
        switch (TypeSet.current, role) {
        case (_, .display), (_, .title), (_, .headline): return .outfit
        case (.outfit, .text), (.outfit, .paragraph): return .outfit
        case (.outfit, _): return .system
        case (.sf, _): return .system
        case (.hanken, _): return .hanken
        }
    }

    private static func hanken(_ w: Font.Weight) -> String {
        if w == .medium { return "HankenGrotesk-Medium" }
        if w == .semibold { return "HankenGrotesk-SemiBold" }
        if w == .bold || w == .heavy || w == .black { return "HankenGrotesk-Bold" }
        return "HankenGrotesk-Regular"
    }

    /// The text styles' sizes at the default content size.
    private static func defaultSize(_ style: Font.TextStyle) -> CGFloat {
        switch style {
        case .largeTitle: 34
        case .title: 28
        case .title2: 22
        case .title3: 20
        case .headline, .body: 17
        case .callout: 16
        case .subheadline: 15
        case .footnote: 13
        case .caption: 12
        case .caption2: 11
        default: 17
        }
    }
}

extension TypeToken {
    /// A token by role: the face its set draws the role in, its size scaled from `style`.
    init(_ role: Typeface.Role, _ weight: Font.Weight, _ size: CGFloat, _ style: Font.TextStyle,
         tracking: CGFloat = 0, monospacedDigits: Bool = false) {
        let font = Typeface.font(role, weight, size, style)
        self.init(font: monospacedDigits ? font.monospacedDigit() : font, tracking: Typeface.tracking(role, tracking))
    }
}
