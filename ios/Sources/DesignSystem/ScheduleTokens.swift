import SwiftUI

// Tokens for the lit Schedule (26 Sep, `ScheduleLit.swift`): the Tonight card, the rows' colour, the
// arrival. Named here so the screens reference names, never numbers.

// MARK: - The lit card

enum ScheduleCardMetrics {
    /// Height ÷ width. Square: the agenda keeps its first rows on the landing screen.
    static let aspect: CGFloat = 1.0
    /// The share of the poster's height that shows above the words on a square card filled from
    /// the top (the card shows 2/3 of a 2:3 poster; the words cover its lower ~45 %). A poster's own
    /// lettering in this band names the show, so the logo stays off it (`PosterPick.billboardName`).
    static let clearBand: ClosedRange<Double> = 0.0...0.38
    /// The protection's run-in above the words — shorter than the billboard's 132: the card is a
    /// third of its height, and the art must read as a picture above the words.
    static let scrimLead: CGFloat = 84
    /// Where the scrim lands: the art's own hue at depth (OKLab L), so the foot of the card is the
    /// picture's colour deepened, never a black smear.
    static let groundLightness: Double = 0.16
    /// The logo's box height on the card.
    static let logoHeight: CGFloat = 60
    /// The words' height before they are measured (tag, logo, line, pill at the default size), so
    /// the first frame's protection is already where the words will be.
    static let copyEstimate: CGFloat = 190
    /// The glow: the art's colour as light (`ScheduleHue.glow`) under the card, drawn by the card's
    /// own shape (`cardShadow`'s rule — never a layer shadow, never a live blur).
    static let glowOpacity: Double = 0.62
    static let glowRadius: CGFloat = 30
    static let glowDrop: CGFloat = 14
    /// How long the card waits for the show's pick (`PosterPick`) on a first visit before it takes
    /// the catalogue's picture. Kept for good after, so this is a first visit's wait.
    static let pickPatience: Duration = .milliseconds(1600)
}

// MARK: - The row's colour

enum ScheduleWhisperMetrics {
    /// The glow under a row's face, and how much of it a watched row keeps.
    static let glowOpacity: Double = 0.5
    static let glowOpacityWatched: Double = 0.16
    static let glowRadius: CGFloat = 10
    static let glowDrop: CGFloat = 4
}

// MARK: - The arrival

enum ScheduleArrivalMetrics {
    /// A row rises this far into place.
    static let rise: CGFloat = 8
    /// The card's words rise this far over the picture (Home's billboard copy).
    static let wordsRise: CGFloat = 10
    /// Between two rows' starts, and the latest a row may start: the whole arrival is ≤ 0.3 s.
    static let rowStep: Double = 0.025
    static let rowCap: Double = 0.1
    /// Between two lines of the card's words.
    static let wordsStep: Double = 0.06
    /// The row's own rise.
    static let duration: Double = 0.2
}
