import Foundation

enum ArtworkPlaybackState: String, Equatable, Sendable {
    case preparing, displayed, buffering, paused, failed
}

/// Output starvation follows the displayed resource, not an individual loop
/// item's readiness or transient network buffering. Only decoded pixels reset it.
struct ArtworkFrameOutputWatchdog {
    private(set) var waiting: TimeInterval = 0
    private var lastSample: TimeInterval?
    var timedOut: Bool { waiting >= 30 }

    mutating func sample(now: TimeInterval, eligible: Bool) -> Bool {
        guard eligible, now.isFinite else { suspend(); return false }
        if let lastSample { waiting += max(0, now - lastSample) }
        lastSample = now
        return waiting >= 1
    }

    mutating func receivedFrame(now: TimeInterval) {
        waiting = 0
        lastSample = now.isFinite ? now : nil
    }

    mutating func suspend() { lastSample = nil }
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
