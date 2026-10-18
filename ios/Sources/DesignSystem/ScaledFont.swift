import SwiftUI

// Dynamic Type-aware Outfit font (the app's brand typeface — weight maps to a bundled cut via
// AppFont). `@ScaledMetric` is exactly 1.0 at the default content size, so every existing layout
// stays pixel-identical to before; at larger accessibility sizes the text grows with the setting.
struct ScaledFont: ViewModifier {
    @ScaledMetric private var size: CGFloat
    private let weight: Font.Weight
    private let monospacedDigit: Bool

    init(size: CGFloat, weight: Font.Weight, monospacedDigit: Bool, relativeTo: Font.TextStyle) {
        _size = ScaledMetric(wrappedValue: size, relativeTo: relativeTo)
        self.weight = weight
        self.monospacedDigit = monospacedDigit
    }

    func body(content: Content) -> some View {
        // The content face (`Typeface`): Hanken Grotesk since 19 Oct, Outfit under `-typeSet outfit`.
        let font = Typeface.fixedFont(.text, weight, size)
        return content.font(monospacedDigit ? font.monospacedDigit() : font)
    }
}

extension View {
    /// Dynamic Type-scaled Outfit font. Pixel-identical at the default text size; grows at
    /// accessibility sizes. Pass `monospacedDigit: true` for ticking numbers.
    func scaledFont(_ size: CGFloat, weight: Font.Weight = .regular,
                    monospacedDigit: Bool = false,
                    relativeTo: Font.TextStyle = .body) -> some View {
        modifier(ScaledFont(size: size, weight: weight,
                            monospacedDigit: monospacedDigit, relativeTo: relativeTo))
    }
}
