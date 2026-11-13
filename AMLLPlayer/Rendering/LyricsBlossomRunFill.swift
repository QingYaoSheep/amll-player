import Foundation

/// Family-2 captures draw a uniform base and one transparent-ended highlight.
/// Row opacity is applied by the parent; glyph coverage participates in each pass.
struct LyricsBlossomRunFill {
    let base: Double
    let overlay: Double

    init(bright: Double, dark: Double) {
        // Resolve the existing normalized focus channels into the two passes.
        // At rest bright == dark, so there is only the uniform native text.
        let focus = min(1, max(0, (bright - dark) / (1 - 0.3 / 0.85)))
        base = min(1, max(0, dark * (1 - 0.15 * focus)))
        overlay = 0.85 * focus
    }

    func alpha(coverage: Double, glyph: Double) -> Double {
        let underneath = glyph * base
        let foreground = glyph * overlay * coverage
        return foreground + underneath * (1 - foreground)
    }
}
