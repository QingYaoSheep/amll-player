import Foundation

/// Source-coordinate oracle, deliberately confined to the test target until
/// source-font/scale samples establish the conversion to native layout points.
/// FUN_1402fde90 builds timed cumulative distances; FUN_1402fe1f0 moves a run's
/// cursor. FUN_14031f940 then constructs one shader from its spatial window.
struct LyricsBlossomRunSweep {
    /// Raw run+0x18...0x34 state. Kept in the reference test target until the
    /// source layout/row flags and canvas coordinates have a native mapping.
    struct Cursor: Equatable {
        var value: Float = 0
        var from: Float = 0
        var to: Float = 0
        var elapsed: Float = 0
        var duration: Float = 1
        var active = false
        var lastIndex = -1
        var suppressed = false

        private mutating func advance(by delta: Float) {
            elapsed += delta
            let progress = min(1, max(0, elapsed / duration))
            value = from + (to - from) * progress
            if progress >= 1 { active = false }
        }

        private mutating func snap(to target: Float) {
            value = target; from = target; to = target
            elapsed = 0; duration = 1; active = false
        }

        /// FUN_1402fe1f0, including its distinct force/nonforce branches.
        mutating func step(now: Float, delta: Float, segments: [Segment], force: Bool) {
            guard now.isFinite, delta.isFinite, delta >= 0,
                  let first = segments.first, let last = segments.last else { return }
            if force {
                let destination = LyricsBlossomRunSweep.target(now: now, segments: segments)
                let fraction: Float = 1 - exp(-delta / 0.0833333358)
                let next = value + (destination - value) * fraction
                snap(to: next)
                suppressed = false; lastIndex = -2
                return
            }
            if now < first.start {
                if lastIndex == -2 {
                    from = value; to = 0; elapsed = 0; duration = 0.25
                    active = true; lastIndex = -1
                }
                if active { advance(by: delta) }
            } else if now >= last.end {
                let destination = last.distance + LyricsBlossomRunSweep.windowWidth
                if !active || destination < value { snap(to: destination) }
                else { advance(by: delta) } // Keep the already installed target.
                lastIndex = -1
            } else {
                let index = segments.lastIndex(where: { $0.start <= now }) ?? 0
                if active { advance(by: delta) } // Finishing here does not clear lastIndex.
                guard !suppressed, lastIndex != index else { return }
                if lastIndex == -1, index > 0 { snap(to: segments[index - 1].distance) }
                let segment = segments[index]
                let destination = segment.distance
                    + LyricsBlossomRunSweep.overshoot(segment, count: segments.count) * LyricsBlossomRunSweep.windowWidth
                var interval: Float
                if lastIndex == -2 {
                    interval = 0.25
                } else {
                    interval = segment.end - segment.start
                    if segment.final {
                        let remaining = segment.distance - value
                        let travel = destination - value
                        if remaining > 0, remaining < travel { interval *= min(3, travel / remaining) }
                    }
                    if interval <= 0 { interval = 1 }
                }
                if interval <= 0 { interval = 1 }
                from = value; to = destination; duration = interval
                elapsed = 0; active = true; lastIndex = index
            }
        }

        /// Cursor portion of FUN_14031f0f0. The caller owns row41 and run
        /// generation; effectiveTime already contains row40's source lookahead.
        mutating func resync(effectiveTime: Float, resetRuns: Bool, segments: [Segment]) {
            guard resetRuns, effectiveTime.isFinite else { return }
            self = .init()
            if let index = segments.lastIndex(where: { $0.start < effectiveTime }) {
                snap(to: segments[index].distance + LyricsBlossomRunSweep.windowWidth)
                lastIndex = index
            }
        }

        /// Raw FUN_14031ed40 gate; flag40 is not guessed from native focus.
        mutating func stepRow(now: Float, delta: Float, segments: [Segment],
                              flag40: Bool, flag41: Bool, force: Bool) {
            guard delta.isFinite, delta >= 0 else { return }
            if !flag40 || flag41 || force {
                step(now: now + (flag40 ? 0.1 : 0), delta: delta, segments: segments, force: force)
            } else if active {
                advance(by: delta)
            }
        }
    }

    struct Word {
        var start: Float
        var end: Float
        var width: Float
        var text: String
    }
    struct Segment {
        var start: Float
        var end: Float
        var distance: Float
        var nonSpaceByteCount: Int
        var final: Bool
    }
    struct Window {
        var start: Float
        var end: Float
        var alpha: Float
    }

    static let windowWidth: Float = 30
    static let endOffset: Float = 2

    /// Words passed here are already grouped by the source layout. This method
    /// does not equate a run to a CTLine/CTRun or redistribute source timings.
    static func segments(_ words: [Word]) -> [Segment] {
        var result: [Segment] = []
        var distance: Float = 0
        for word in words {
            distance += word.width
            let count = word.text.utf8.filter { $0 != 0x20 }.count
            if let last = result.last, last.start == word.start, last.end == word.end {
                result[result.count - 1].distance = distance
                result[result.count - 1].nonSpaceByteCount += count
            } else {
                result.append(.init(start: word.start, end: word.end, distance: distance,
                                    nonSpaceByteCount: count, final: false))
            }
        }
        if !result.isEmpty { result[result.count - 1].final = true }
        return result
    }

    /// The final record is marked by the constructor, not by a 0.9s word cutoff.
    static func overshoot(_ segment: Segment, count: Int) -> Float {
        if segment.final { return 1 }
        if count < 3 { return 0.5 }
        return segment.nonSpaceByteCount < 3 ? 0.25 : 0.12
    }

    /// Direct temporal target in the param_3 != 0 branch. The caller's
    /// exponential smoothing remains separate; no smoothing time is invented.
    static func target(now: Float, segments: [Segment]) -> Float {
        guard let first = segments.first, let last = segments.last, now >= first.start else { return 0 }
        if now >= last.end { return last.distance + windowWidth }
        guard let index = segments.lastIndex(where: { $0.start <= now }) else { return 0 }
        let segment = segments[index]
        let previous = index == 0 ? 0 : segments[index - 1].distance
        let fraction = segment.end > segment.start ? min(1, max(0, (now - segment.start) / (segment.end - segment.start))) : 1
        return previous + fraction * (segment.distance - previous + overshoot(segment, count: segments.count) * windowWidth)
    }

    static func window(cursor: Float, wordPositions: [Float], alpha: Float) -> Window? {
        // The raw function starts min at 10000, including empty index vectors.
        // Native use must reject an empty mapping rather than draw that sentinel.
        guard !wordPositions.isEmpty, cursor.isFinite, alpha.isFinite,
              wordPositions.allSatisfy(\.isFinite) else { return nil }
        let minimum = wordPositions.reduce(Float(10_000), min)
        let end = minimum - endOffset + max(0, cursor)
        return .init(start: end - windowWidth, end: end, alpha: min(1, max(0, alpha)))
    }
}
