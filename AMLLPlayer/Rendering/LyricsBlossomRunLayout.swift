import Foundation

/// Immutable layout-group mapping. Source timestamps are retained on the document;
/// only fragments crossing groups receive width-proportional subintervals.
struct LyricsBlossomRunLayout {
    struct Piece {
        var range: NSRange
        var width: Double
        var start: Double
        var end: Double
        var group: Int = 0
        var source: Int? = nil
        var origin: Double? = nil
    }
    struct Placement {
        var range: NSRange
        var group: Int
        var origin: Double
    }
    private struct Fragment: Equatable { var record: Int; var advance: Double }
    let identity = UUID()
    private let placements: [NSRange: Fragment]
    let records: [[LyricsBlossomRunSweep.Segment]]
    let pixelsPerPoint: Double
    var feather: Double { 30 / pixelsPerPoint }
    var recordCount: Int { records.count }
    let fallbackCount: Int

    // Native source drawing space is the untransformed raster surface. Row scale
    // and the layer's point conversion are applied afterwards, equally to glyphs
    // and window endpoints. This is an explicit native coordinate convention,
    // not a claim that every source canvas has a universal physical-pixel unit.
    init(text: String, pieces: [Piece], pixelsPerPoint: Double,
         fragmentRanges: [NSRange]? = nil, fragments: [Placement]? = nil) {
        self.pixelsPerPoint = pixelsPerPoint.isFinite && pixelsPerPoint > 0 ? pixelsPerPoint : 1
        let ns = text as NSString
        let valid = pieces.filter {
            $0.width.isFinite && $0.width >= 0 && $0.start.isFinite && $0.end.isFinite
                && $0.end >= $0.start && $0.range.location >= 0 && $0.range.length > 0
                && NSMaxRange($0.range) <= ns.length && ($0.origin?.isFinite ?? true)
        }.sorted { $0.range.location < $1.range.location }
        let groups = Array(Set(valid.map(\.group))).sorted()
        let bySource = Dictionary(grouping: valid.indices, by: { valid[$0].source ?? valid[$0].range.location })
        var adjusted = valid
        for indexes in bySource.values {
            let sourceGroups = groups.filter { group in indexes.contains { valid[$0].group == group } }
            guard sourceGroups.count > 1, let first = indexes.first else { continue }
            let start = valid[first].start, end = valid[first].end
            guard indexes.allSatisfy({ valid[$0].start == start && valid[$0].end == end }) else { continue }
            let total = indexes.reduce(0.0) { $0 + max(0, valid[$1].width) }
            var used = 0.0
            for (ordinal, group) in sourceGroups.enumerated() {
                let members = indexes.filter { valid[$0].group == group }
                let lower = total > 0 ? start + (end - start) * used / total : start
                used += members.reduce(0.0) { $0 + max(0, valid[$1].width) }
                let upper = ordinal == sourceGroups.count - 1 ? end
                    : (total > 0 ? start + (end - start) * used / total : start)
                for index in members { adjusted[index].start = lower; adjusted[index].end = upper }
            }
        }
        var records: [[LyricsBlossomRunSweep.Segment]] = []
        var mapping: [NSRange: Fragment] = [:]
        var failures = pieces.count - valid.count
        for group in groups {
            let entries = adjusted.filter { $0.group == group }
            // Bidi groups are supplied separately by the layout adapter.
            let ordered = entries.sorted { $0.range.location < $1.range.location }
            let x0 = ordered.compactMap(\.origin).min() ?? 0
            var advance = 0.0
            var words: [LyricsBlossomRunSweep.Word] = []
            var invalidGroup = false
            for piece in ordered {
                let x = piece.origin.map { $0 - x0 } ?? advance
                // Include layout spacing in the cumulative distance.
                let right = x + piece.width
                guard right >= advance else { failures += 1; invalidGroup = true; continue }
                words.append(.init(start: Float(piece.start), end: Float(piece.end),
                                   width: Float((right - advance) * self.pixelsPerPoint),
                                   text: ns.substring(with: piece.range)))
                mapping[piece.range] = .init(record: records.count, advance: x)
                advance = right
            }
            let segments = LyricsBlossomRunSweep.segments(words)
            if invalidGroup || !zip(segments, segments.dropFirst()).allSatisfy({ $0.start <= $1.start }) {
                mapping = mapping.filter { $0.value.record != records.count }
                records.append([]); failures += entries.count
            } else { records.append(segments) }
        }
        if let fragments {
            for fragment in fragments {
                guard let record = groups.firstIndex(of: fragment.group), !records[record].isEmpty else { continue }
                let x0 = adjusted.filter { $0.group == fragment.group }.compactMap(\.origin).min() ?? 0
                mapping[fragment.range] = .init(record: record, advance: fragment.origin - x0)
            }
        } else {
            for range in fragmentRanges ?? pieces.map(\.range) {
                let owners = adjusted.filter { NSIntersectionRange($0.range, range).length > 0 }
                if let first = owners.first, owners.allSatisfy({ $0.group == first.group }), let found = mapping[first.range] {
                    mapping[range] = found
                }
            }
        }
        placements = mapping; self.records = records; fallbackCount = failures
    }

    /// Accurate reconstruction is the selected native seek policy. It does not
    /// use the source's forced resync snapshot to the end of a started segment.
    static func cursor(at time: Double, segments: [LyricsBlossomRunSweep.Segment]) -> Float {
        guard time.isFinite else { return 0 }
        return LyricsBlossomRunSweep.target(now: Float(time), segments: segments)
    }
    struct Sample: Equatable { var starts: [Double]; var feather: Double }
    func sample(cursors: [LyricsBlossomRunSweep.Cursor]) -> Sample {
        .init(starts: cursors.map { Double(max(0, $0.value) - 2) / pixelsPerPoint - feather }, feather: feather)
    }
    func sample(time: Double, featherMultiplier: Double = 1) -> Sample {
        // Kept for deterministic reconstruction tests; production holds cursors.
        .init(starts: records.map { Double(Self.cursor(at: time, segments: $0) - 2) / pixelsPerPoint - feather }, feather: feather)
    }
    func equivalent(to other: Self) -> Bool {
        pixelsPerPoint == other.pixelsPerPoint && records == other.records && placements == other.placements
    }
    func edge(for range: NSRange, sample: Sample) -> Double? {
        guard let fragment = placements[range], sample.starts.indices.contains(fragment.record),
              !records[fragment.record].isEmpty else { return nil }
        return sample.starts[fragment.record] - fragment.advance
    }
}
