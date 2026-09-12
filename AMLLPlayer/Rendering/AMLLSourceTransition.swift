import Foundation

/// CSS transition fallback used when the AMLL spring option is disabled.
/// The source uses a fast ease-out curve for line transforms; keeping this as
/// an engine-owned value avoids letting SwiftUI choose a different curve.
struct AMLLSourceTransition: Sendable {
    private(set) var value: Double
    private(set) var target: Double
    private var from: Double
    private var elapsed = 0.0
    private var duration = 0.32

    init(_ value: Double = 0) {
        self.value = value
        target = value
        from = value
    }

    var arrived: Bool {
        abs(value - target) < 0.001
    }

    mutating func setPosition(_ value: Double) {
        self.value = value
        target = value
        from = value
        elapsed = duration
    }

    mutating func setTarget(_ value: Double, duration: Double = 0.32) {
        guard value.isFinite else { return }
        guard abs(value - target) > 0.001 else { return }
        from = self.value
        target = value
        elapsed = 0
        self.duration = max(0.001, duration)
    }

    mutating func update(_ delta: Double) {
        guard delta.isFinite, delta > 0 else { return }
        if arrived {
            // Snap the last sub-pixel remainder. Without this, a CSS
            // transition can remain at 0.399998 for the rest of its life;
            // that is visually harmless but makes frame traces and settled
            // state disagree with the source's exact target.
            value = target
            return
        }
        elapsed = min(duration, elapsed + delta)
        let progress = min(1, max(0, elapsed / duration))
        let eased = 1 - pow(1 - progress, 3)
        value = from + (target - from) * eased
        if progress >= 1 {
            value = target
        }
    }
}
