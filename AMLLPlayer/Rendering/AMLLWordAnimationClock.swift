import Foundation

/// Models the word animation clocks shared by a line's WAAPI animations.
/// Enable/seek anchors to lyrics; ordinary frames advance with elapsed wall time.
struct AMLLWordAnimationClock: Codable, Sendable {
    private(set) var time = 0.0
    private(set) var reverseElapsed = 0.0
    private(set) var enabled = false

    mutating func enable(at time: Double) {
        self.time = max(0, time)
        reverseElapsed = 0
        enabled = true
    }

    mutating func disable() {
        enabled = false
        reverseElapsed = 0
    }

    mutating func advance(_ delta: Double, playing: Bool) {
        if enabled {
            if playing {
                time += delta
            }
        } else {
            reverseElapsed += delta
        }
    }

    func floatElapsed(wordStart: Double, duration: Double) -> Double {
        if enabled {
            return time - wordStart
        }
        // Finished animations reverse from their own end, not the end of the line.
        let end = wordStart + max(1, duration)
        return max(0, min(time, end) - reverseElapsed) - wordStart
    }
}
