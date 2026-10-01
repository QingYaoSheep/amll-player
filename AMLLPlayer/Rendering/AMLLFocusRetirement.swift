import Foundation

/// A completed row's appearance exits at its own position deadline. Store
/// effective (row-opacity multiplied) alpha so independent layer fades cannot
/// dim the same text twice. This clock belongs to the engine, not the view.
struct AMLLFocusRetirement: Sendable {
    let startedAt: Double
    private let initialBright: Double
    private let initialDark: Double
    var targetOpacity: Double
    private var remaining = AMLLSourceTransition(1)
    private var blur: AMLLSourceTransition

    init(at time: Double, bright: Double, dark: Double, opacity: Double, blur: Double) {
        startedAt = time
        initialBright = bright * opacity
        initialDark = dark * opacity
        targetOpacity = opacity
        self.blur = AMLLSourceTransition(blur)
        remaining.setTarget(0, duration: 0.4)
    }

    var arrived: Bool { remaining.arrived && blur.arrived }

    mutating func setBlur(_ value: Double, immediately: Bool) {
        if immediately {
            blur.setPosition(value)
        } else {
            blur.setTarget(value, duration: 0.4)
        }
    }

    mutating func advance(_ delta: Double, immediately: Bool) {
        if immediately {
            remaining.setPosition(0)
        } else {
            remaining.update(delta)
            blur.update(delta)
        }
    }

    func presentation(opacity: Double) -> (bright: Double, dark: Double, blur: Double, state: AMLLFrameState.Row.Retirement) {
        let residual = remaining.value
        let target = 0.2 * targetOpacity
        let bright = target + (initialBright - target) * residual
        let dark = target + (initialDark - target) * residual
        let divisor = max(0.0001, opacity)
        // HDR excess follows the same envelope once: alpha * HDR weight is
        // the original effective alpha times residual, independent of SDR fade.
        let hdrWeight = bright > 0 ? min(1, max(0, initialBright * residual / bright)) : 0
        return (bright / divisor, dark / divisor, min(5, blur.value),
                .init(startedAt: startedAt, progress: 1 - residual, hdrWeight: hdrWeight))
    }
}
