import Foundation

/// Source records are whitespace-delimited text, not Core Text runs. Measured
/// glyph pieces retain their UTF-16 ownership and their original provider time.
/// This mapping is built once with layout, never by the display-link callback.
struct LyricsBlossomRunLayout {
    struct Piece {
        var range: NSRange
        var width: Double
        var start: Double
        var end: Double
    }
    private struct Fragment {
        var range: NSRange
        var record: Int
        var advance: Double
    }
    private let placements: [NSRange: Fragment]
    private let records: [[LyricsBlossomRunSweep.Segment]]
    let pixelsPerPoint: Double
    var feather: Double { Double(LyricsBlossomRunSweep.windowWidth) / pixelsPerPoint }
    var recordCount: Int { records.count }

    init(text: String, pieces: [Piece], pixelsPerPoint: Double, fragmentRanges: [NSRange]? = nil) {
        self.pixelsPerPoint = pixelsPerPoint.isFinite && pixelsPerPoint > 0 ? pixelsPerPoint : 1
        let ns = text as NSString
        var ranges: [NSRange] = []
        var offset = 0
        var beginning: Int?
        for character in text {
            if character.isWhitespace {
                if let beginning { ranges.append(NSRange(location: beginning, length: offset - beginning)) }
                beginning = nil
            } else if beginning == nil {
                beginning = offset
            }
            offset += String(character).utf16.count
        }
        if let beginning { ranges.append(NSRange(location: beginning, length: offset - beginning)) }
        var words = [[LyricsBlossomRunSweep.Word]](repeating: [], count: ranges.count)
        var widths = [Double](repeating: 0, count: ranges.count)
        var mapping: [Fragment] = []
        for piece in pieces.sorted(by: { $0.range.location < $1.range.location }) {
            guard piece.width.isFinite, piece.width >= 0, piece.start.isFinite, piece.end.isFinite,
                  piece.end >= piece.start, piece.range.location >= 0, piece.range.length > 0,
                  NSMaxRange(piece.range) <= ns.length,
                  let record = ranges.firstIndex(where: {
                      $0.location <= piece.range.location && NSMaxRange(piece.range) <= NSMaxRange($0)
                  }) else { continue }
            mapping.append(.init(range: piece.range, record: record, advance: widths[record]))
            words[record].append(.init(start: Float(piece.start), end: Float(piece.end),
                                      width: Float(piece.width * self.pixelsPerPoint),
                                      text: ns.substring(with: piece.range)))
            widths[record] += piece.width
        }
        var placements: [NSRange: Fragment] = [:]
        for range in fragmentRanges ?? pieces.map(\.range) {
            let owned = mapping.filter { NSIntersectionRange($0.range, range).length > 0 }
            if let first = owned.first, owned.allSatisfy({ $0.record == first.record }) {
                placements[range] = first
            }
        }
        self.placements = placements
        records = words.map(LyricsBlossomRunSweep.segments)
    }

    /// Integrate between actual segment boundaries, so reconstruction after a
    /// seek, eviction or font change has the same result as uninterrupted play.
    /// Native playback supplies time directly; no source `force` event is guessed.
    /// The source force/resync variants remain available in the shared cursor.
    static func cursor(at time: Double, segments: [LyricsBlossomRunSweep.Segment]) -> Float {
        guard time.isFinite, let first = segments.first, Float(time) >= first.start else { return 0 }
        let now = Float(time)
        var cursor = LyricsBlossomRunSweep.Cursor()
        var previous = first.start
        var previousBoundary: Float?
        for segment in segments where segment.start <= now {
            // Same-start segments are handled by the source's lastIndex lookup.
            guard previousBoundary != segment.start else { continue }
            cursor.step(now: segment.start, delta: max(0, segment.start - previous),
                        segments: segments, force: false)
            previous = segment.start
            previousBoundary = segment.start
        }
        if now > previous {
            cursor.step(now: now, delta: now - previous, segments: segments, force: false)
        }
        return cursor.value
    }

    struct Sample {
        fileprivate var starts: [Double]
        var feather: Double
    }

    func sample(time: Double, featherMultiplier: Double = 1) -> Sample {
        let adjustedFeather = feather * (featherMultiplier.isFinite ? max(0, featherMultiplier) : 1)
        return
        .init(starts: records.map {
            let cursor = Self.cursor(at: time, segments: $0)
            return Double(max(0, cursor) - LyricsBlossomRunSweep.endOffset) / pixelsPerPoint - adjustedFeather
        }, feather: adjustedFeather)
    }

    /// Converts a logical record window to a shaped fragment's local origin.
    /// Direction is applied by the existing SDR/HDR fragment renderers. A
    /// fragment spanning independent records uses the existing mask fallback.
    func edge(for range: NSRange, sample: Sample) -> Double? {
        guard let first = placements[range],
              sample.starts.indices.contains(first.record) else { return nil }
        return sample.starts[first.record] - first.advance
    }
}
