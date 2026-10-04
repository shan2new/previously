import SwiftUI

// A split-flap module that TURNS to its value — the brand's board ("P." on a departures board:
// what arrives next), as a live control rather than a picture. `PreviouslyMark` draws the board at
// rest and the launch film flips it once; this is the same object where its face is data: first
// run's lineup shows each show's "when" on one.
//
// The turn is a real flap's: the old top half falls toward the viewer about the seam and goes
// edge-on, the new bottom half swings down on its back and lands with one small bounce. Two
// transforms on two small layers, each driven by the render server; nothing per frame in a body.
// Under Reduce Motion the face changes with a short fade.
//
// A face is drawn once at full size and shown through two windows (its top half, its bottom half),
// so a face that sets one line in each half is never cut by the seam, and a numeral that spans
// both is cut exactly as a printed flap cuts it.

struct SplitFlap<Value: Hashable, Face: View>: View {
    let value: Value
    var size: CGSize
    var radius: CGFloat = 8
    /// The first appearance turns from a blank flap to the value (a board coming alive) instead
    /// of standing there already set. `delay` staggers a column of them.
    var arrives = false
    var delay: Double = 0
    @ViewBuilder var face: (Value) -> Face

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// What the flaps show at rest; nil is the blank flap an arrival turns from.
    @State private var shown: Value?
    /// The value being turned to, while a turn is in flight.
    @State private var incoming: Value?
    @State private var falling: Double = 0      // the old top half: 0 → -90
    @State private var landing: Double = 90     // the new bottom half: 90 → 0
    @State private var began = false

    private static var seam: CGFloat { 1.5 }
    private var half: CGFloat { (size.height - Self.seam) / 2 }

    var body: some View {
        ZStack(alignment: .top) {
            // At rest: the top of what is coming (it is uncovered as the old top falls), the
            // bottom of what is leaving (it is covered as the new bottom lands).
            VStack(spacing: Self.seam) {
                flap(incoming ?? shown, upper: true)
                flap(shown, upper: false)
            }
            if incoming != nil {
                flap(shown, upper: true)
                    .overlay(Color.black.opacity(-falling / 90 * 0.42).clipShape(shape(upper: true)))
                    .rotation3DEffect(.degrees(falling), axis: (x: 1, y: 0, z: 0), anchor: .bottom,
                                      perspective: 0.5)
                flap(incoming, upper: false)
                    .overlay(Color.black.opacity(landing / 90 * 0.36).clipShape(shape(upper: false)))
                    .rotation3DEffect(.degrees(landing), axis: (x: 1, y: 0, z: 0), anchor: .top,
                                      perspective: 0.5)
                    .offset(y: half + Self.seam)
            }
        }
        .frame(width: size.width, height: size.height)
        .onAppear {
            guard !began else { return }
            began = true
            if arrives, !reduceMotion {
                Task { @MainActor in
                    if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
                    turn(to: value)
                }
            } else {
                shown = value
            }
        }
        .onChange(of: value) { _, new in
            guard began, incoming == nil else { return }
            turn(to: new)
        }
    }

    private func turn(to new: Value) {
        guard new != shown else { return }
        if reduceMotion {
            withAnimation(ThemeMotion.uiReduced) { shown = new }
            return
        }
        falling = 0
        landing = 90
        incoming = new
        withAnimation(.easeIn(duration: 0.13)) {
            falling = -90
        } completion: {
            withAnimation(.spring(response: 0.26, dampingFraction: 0.62)) {
                landing = 0
            } completion: {
                shown = new
                incoming = nil
                // The value moved on while this turn was in the air: turn again, to where it is.
                if value != new { turn(to: value) }
            }
        }
    }

    private func shape(upper: Bool) -> UnevenRoundedRectangle {
        let small: CGFloat = 1.5
        return UnevenRoundedRectangle(
            topLeadingRadius: upper ? radius : small, bottomLeadingRadius: upper ? small : radius,
            bottomTrailingRadius: upper ? small : radius, topTrailingRadius: upper ? radius : small,
            style: .continuous)
    }

    /// One half: the board's graphite, lit along its top edge, with the face seen through it.
    private func flap(_ value: Value?, upper: Bool) -> some View {
        let shape = shape(upper: upper)
        return ZStack {
            shape.fill(LinearGradient(
                colors: upper ? [FlapGeometry.flapTopHigh, FlapGeometry.flapTopLow]
                              : [FlapGeometry.flapBottomHigh, FlapGeometry.flapBottomLow],
                startPoint: .top, endPoint: .bottom))
            if upper {
                shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.14), .clear],
                                                  startPoint: .top, endPoint: .bottom), lineWidth: 1)
            } else {
                // The top flap's shadow on the lower one, at the seam.
                LinearGradient(colors: [.black.opacity(0.30), .clear], startPoint: .top, endPoint: .center)
                    .clipShape(shape)
            }
            if let value {
                face(value)
                    .frame(width: size.width, height: size.height)
                    .frame(width: size.width, height: half, alignment: upper ? .top : .bottom)
                    .clipped()
            }
        }
        .frame(width: size.width, height: half)
    }
}
