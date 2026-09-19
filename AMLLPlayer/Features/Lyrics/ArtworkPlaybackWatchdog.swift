import Foundation

enum ArtworkPlaybackState: String, Equatable, Sendable {
    case preparing, displayed, buffering, paused, failed
}

/// Counts eligible foreground time, independently of the download deadline.
struct ArtworkPlaybackWatchdog {
    enum Failure: Equatable { case firstFrameTimeout, stalledPlayback }

    private(set) var hasDisplayedFrame = false
    private(set) var failure: Failure?
    private var waiting: TimeInterval = 0
    private var previousPosition: Double?

    mutating func advance(elapsed: TimeInterval, eligible: Bool, displayed: Bool,
                          position: Double) -> Failure?
    {
        guard failure == nil else { return failure }
        guard eligible else { return nil }
        let progress = position.isFinite && previousPosition.map { abs(position - $0) > 0.001 } == true
        if position.isFinite {
            previousPosition = position
        }
        if displayed, !hasDisplayedFrame {
            hasDisplayedFrame = true
            waiting = 0
        } else if hasDisplayedFrame, progress {
            // Includes loop wraparound; a backward position is still progress.
            waiting = 0
        } else if elapsed.isFinite, elapsed > 0 {
            waiting += elapsed
        }
        if waiting >= 30 {
            failure = hasDisplayedFrame ? .stalledPlayback : .firstFrameTimeout
        }
        return failure
    }
}
