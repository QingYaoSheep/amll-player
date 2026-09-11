import Foundation

/// core@0.5.2 DomLyricLine.updateMaskAlphaTargets / applyAlphaToDom.
/// Kept in the engine so recycling a raster never resets the attack/release envelope.
struct AMLLMaskAlpha: Sendable {
    private var currentBright = 1.0
    private var currentDark = 0.2
    private(set) var bright = 1.0
    private(set) var dark = 0.2

    mutating func update(scale: Double, gradient: Bool, delta: Double, force: Bool = false) {
        let factor = min(1, max(0, (scale - 0.97) / 0.03))
        let targetDark = factor * 0.2 + 0.2
        let targetBright = gradient ? factor * 0.8 + 0.2 : targetDark
        let dt = delta == 0 ? 0.016 : delta
        func advance(_ current: Double, to target: Double) -> Double {
            if force || abs(target - current) < 0.001 {
                return target
            }
            return current + (target - current) * (1 - exp(-(target > current ? 50 : 7) * dt))
        }
        currentBright = advance(currentBright, to: targetBright)
        currentDark = advance(currentDark, to: targetDark)
        // The DOM publishes toFixed(3), while retaining unrounded internal state.
        bright = force ? currentBright : (currentBright * 1000).rounded() / 1000
        dark = force ? currentDark : (currentDark * 1000).rounded() / 1000
    }
}
