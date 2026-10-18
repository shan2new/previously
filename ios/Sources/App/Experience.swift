import SwiftUI

// Which whole-app DIRECTION is drawn (16 Oct: "I want to see the directions. One cohesive
// interface, not 10 disparate islands. It has to feel like one complete unit as much as possible,
// one design system, one language, one motion", owner). Chosen in Profile › Settings › Version
// (DEBUG builds). 17 Oct: "4 tabs is good enough" (owner) — Four tabs is the default, and what a
// Release build draws; the others stay behind the switch until their paths are taken out.
//
// `current` is the app as it shipped on 16 Oct. The other three share ONE CONTRACT — one question
// per tab, one tab per fact — with the owner's three answers of the same day folded in (Schedule
// carries no marks, Home always ends on two shelves of shows for you, the feed has no story tray):
//   · Home — what you can watch NOW: what is out and unwatched, then shows for you. Nothing that
//     has not aired; caught up, one line points at Schedule.
//   · Schedule — what is COMING: today onward, then Later (returning seasons, announced ones). No
//     past days, no marks, no billboard of something already out.
//   · Library — every show you own, FINDABLE: the search field, the status, one grid.
//   · Discover — shows you do NOT own, behind a compass rather than a magnifier.
//   · Feed — news about your shows; episode alerts are Home's.
// They differ in their LANGUAGE and their TAB SET:
//   · `stage` — every root is led by a picture (Home's drop, Schedule's next airing, Discover's top
//     pick), the page in that picture's hue; one header row, one section header, one poster card,
//     one row and one arrival everywhere.
//   · `calm` — the same contract in one flat language: pictures live inside cards, no root opens
//     full bleed (the show page keeps its stage).
//   · `fourTabs` — CALM with the Feed folded into Home (its News section and the bell) and the
//     show pages (their Posts). It was Stage's language until 19 Oct: "I think we have made a
//     mistake making everything immersive in Home and Schedule screens. In the Details screen it
//     makes total sense… not an immersive view as it is very distracting on a day to day use"
//     (owner). The roots are the canvas, their pictures in cards; the full-bleed stage, the page in
//     the picture's hue and its glow are the show page's alone. The news is a shelf of cards on
//     Home and a reader's list on its page, led by the newest official announcement (`NewsCard`).
enum Experience: String, CaseIterable, Identifiable {
    case current, stage, calm, fourTabs

    var id: String { rawValue }

    var label: String {
        switch self {
        case .current:  "Current"
        case .stage:    "Stage"
        case .calm:     "Calm"
        case .fourTabs: "Four tabs"
        }
    }

    /// One line for the picker's menu.
    var summary: String {
        switch self {
        case .current:  "As shipped"
        case .stage:    "Pictures lead every screen"
        case .calm:     "Pictures stay inside cards"
        case .fourTabs: "Calm, with the Feed folded into Home"
        }
    }

    /// One question per tab, one tab per fact.
    var doors: Bool { self != .current }
    /// Roots led by a picture, full bleed, the page in its hue.
    var stage: Bool { self == .stage }
    /// Pictures inside cards; no full-bleed root, no root in a picture's hue (19 Oct: Four tabs too).
    var calm: Bool { self == .calm || self == .fourTabs }
    /// The Feed is not a tab: its news is a section of Home.
    var feedInHome: Bool { self == .fourTabs }

    /// The bar's tabs, in order.
    var tabs: [AppTab] {
        feedInHome ? [.home, .schedule, .library, .discover] : AppTab.allCases
    }

    static let defaultsKey = "previously.experience"

    /// The chosen direction (17 Oct).
    static let chosen: Experience = .fourTabs

    /// The persisted choice (or `-previously.experience stage` for a capture); Four tabs otherwise.
    static var stored: Experience {
        #if DEBUG
        return UserDefaults.standard.string(forKey: defaultsKey).flatMap(Experience.init(rawValue:)) ?? chosen
        #else
        return chosen
        #endif
    }
}

extension AppModel {
    /// Switch the whole app to another direction; the choice is kept across launches.
    func setExperience(_ next: Experience) {
        guard next != experience else { return }
        UserDefaults.standard.set(next.rawValue, forKey: Experience.defaultsKey)
        withAnimation(ThemeMotion.uiGentle) { experience = next }
    }
}

// MARK: - One motion

private struct RootActiveKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// This root's tab is the one on screen (`MainTabView`): a VISIT begins when it turns true.
    var rootActive: Bool {
        get { self[RootActiveKey.self] }
        set { self[RootActiveKey.self] = newValue }
    }
}

/// The directions' ONE arrival (`Experience.doors`): on every visit to a tab, its sections rise
/// into place — Schedule's rows' curve, rise and stagger (`ScheduleRise`, `ScheduleArrivalMetrics`),
/// now every root's, so a tab change feels the same wherever it lands. The whole arrival is under
/// 0.3 s; Reduce Motion has none. For a root's top-level blocks only — a lazy row given it would
/// rise again every time it scrolled back into being.
private struct RootArrival: ViewModifier {
    let order: Int
    @Environment(\.rootActive) private var active
    @Environment(AppModel.self) private var appModel
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .modifier(ScheduleRise(shown: shown || !appModel.experience.doors,
                                   delay: min(Double(order) * ScheduleArrivalMetrics.rowStep * 2,
                                              ScheduleArrivalMetrics.rowCap)))
            .onChange(of: active, initial: true) { _, on in
                guard on else { shown = false; return }
                shown = false
                Task { @MainActor in shown = true }
            }
    }
}

extension View {
    /// A root's top-level block, `order` beats into its arrival (`RootArrival`).
    func rootArrival(_ order: Int) -> some View { modifier(RootArrival(order: order)) }
}
