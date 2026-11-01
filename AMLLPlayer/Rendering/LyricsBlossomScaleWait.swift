import Foundation

/// Absolute scale deadlines consume the part of a frame after the start event.
/// Repeated layout does not restart a wait or interrupt an existing spring.
struct LyricsBlossomScaleWait {
    var target: Double
    var start: Double

    static func retarget(_ spring: inout LyricsAnimationSpring, pending: inout Self?,
                         target: Double, at time: Double, delay: Double) {
        if pending?.target == target {
            if delay <= 0 { pending = nil; spring.setTarget(target) }
            return
        }
        if spring.target == target { pending = nil; return }
        if delay > 0, spring.arrived {
            pending = .init(target: target, start: time + delay)
        } else {
            pending = nil
            spring.setTarget(target)
        }
    }

    static func advance(_ spring: inout LyricsAnimationSpring, pending: inout Self?,
                        delta: Double, endingAt end: Double) {
        guard let wait = pending else { spring.update(delta); return }
        guard end >= wait.start else { spring.update(delta); return }
        let remainder = min(delta, max(0, end - wait.start))
        spring.update(delta - remainder)
        spring.setTarget(wait.target)
        pending = nil
        spring.update(remainder)
    }
}
