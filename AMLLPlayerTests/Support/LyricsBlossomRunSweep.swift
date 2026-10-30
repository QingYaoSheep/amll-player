import Foundation

/// Source-coordinate oracle, deliberately confined to the test target until
/// source-font/scale samples establish the conversion to native layout points.
/// FUN_1402fde90 builds timed cumulative distances; FUN_1402fe1f0 moves a run's
/// cursor. FUN_14031f940 then constructs one shader from its spatial window.
struct LyricsBlossomRunSweep {
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
