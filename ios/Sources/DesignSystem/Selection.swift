import SwiftUI

// "This one" — the app's selected state for a PICTURE you choose: an audience card, a poster on
// first run's wall (4 Oct 2026).
//
// It was a 2-pt flat amber stroke on the picture's own edge with a rosette in the corner, and it
// read as a debug outline ("the selection ring doesn't feel as premium", owner). What a chosen
// thing wears in the apps people handle all day is a RING THAT STANDS OFF IT: Instagram's story
// ring, the watch-face picker, the appearance picker in Settings — a band of light with air
// between it and the picture, so the picture is held, not outlined. This is that ring, in the
// accent as a lit metal (`ThemeGradient.ring`), drawn round the picture as it is chosen, with a
// soft pool of its own light where the screen is still enough to afford one.
//
// And the badge: a lit disc with the check DRAWN into it (`DrawnCheck`), in place of the rosette
// (which is the feed's "official source" mark, and says that to VoiceOver).

/// The ring. An overlay that stands `gap` points outside its picture; it is drawn round on
/// selection and lets go quickly. `glow` adds its light — for a still screen, not a scrolling wall
/// (a blurred shadow per tile is a pass per tile per frame).
struct SelectionRing: View {
    let selected: Bool
    /// The picture's own corner radius.
    let radius: CGFloat
    var gap: CGFloat = 3
    var width: CGFloat = 2.5
    var glow = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let outset = gap + width / 2
        let shape = RoundedRectangle(cornerRadius: radius + outset, style: .continuous)
        ZStack {
            if glow {
                // Its light: the same band, blurred once and held in a bitmap.
                shape.stroke(ThemeColor.accent, lineWidth: width + 2)
                    .blur(radius: 9)
                    .opacity(selected ? 0.55 : 0)
                    .padding(-18)
                    .drawingGroup()
                    .padding(18)
            }
            shape
                .trim(from: 0, to: selected || reduceMotion ? 1 : 0)
                .stroke(ThemeGradient.ring, style: StrokeStyle(lineWidth: width, lineCap: .round))
                .opacity(selected ? 1 : 0)
        }
        .padding(-outset)
        .animation(reduceMotion ? ThemeMotion.uiReduced
                   : (selected ? .easeOut(duration: 0.38) : .easeIn(duration: 0.14)), value: selected)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

extension View {
    /// Wears the selection ring (`SelectionRing`) when `selected`.
    func selectionRing(_ selected: Bool, radius: CGFloat, gap: CGFloat = 3, width: CGFloat = 2.5,
                       glow: Bool = false) -> some View {
        overlay { SelectionRing(selected: selected, radius: radius, gap: gap, width: width, glow: glow) }
    }
}

/// The badge of a chosen picture: a lit accent disc, the check drawn into it.
struct SelectedBadge: View {
    var size: CGFloat = 26

    var body: some View {
        Circle()
            .fill(ThemeGradient.accent.shadow(.drop(color: .black.opacity(0.40), radius: 5, x: 0, y: 2)))
            .overlay(Circle().strokeBorder(
                LinearGradient(colors: [.white.opacity(0.55), .clear], startPoint: .top, endPoint: .center),
                lineWidth: 1))
            .overlay { DrawnCheck(on: true, size: size * 0.46) }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
