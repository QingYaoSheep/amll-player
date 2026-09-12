import Foundation

/// Display-only copy. Acquisition documents and real word timing remain unchanged in the cache.
/// Port of core/src/utils/optimize-lyric.ts and dom/index.ts grouping.
struct AMLLDisplayDocument: Sendable {
    struct Group: Sendable {
        var main: Int
        var background: Int?
        var backgroundFirst: Bool
    }

    let lines: [LyricLine]
    let groups: [Group]
    let timings: [AMLLGroupTiming]

    init(lines source: [LyricLine]) {
        var lines = source
        for index in lines.indices {
            // Keep the display copy lossless. TTML's `xml:space="preserve"`
            // and QRC/TTML timed whitespace are part of the glyph and mask
            // cursor geometry; collapsing them here makes the Core Text
            // layout shorter than the timing stream and drops the final word.
            // Pretty-printing whitespace has already been removed by the
            // provider parser, so the renderer must never normalize it again.
            if lines[index].precision == .word, let first = lines[index].words.first, let last = lines[index].words.last {
                lines[index].start = first.start
                lines[index].end = last.end
                lines[index].text = lines[index].words.map(\.text).joined()
            }
        }
        // The source makes threshold decisions in milliseconds. Performing the
        // same subtraction in seconds makes e.g. 2.1 - 2 exceed 0.1 and changes
        // overlap classification, hence also the following visual start time.
        var starts = lines.map { $0.start * 1000 }
        var ends = lines.map { $0.end * 1000 }
        var backgroundCount = 0
        for index in lines.indices {
            if lines[index].isBackground {
                backgroundCount += 1
                if backgroundCount > 1 {
                    lines[index].isBackground = false
                }
            } else {
                backgroundCount = 0
            }
        }
        for index in lines.indices.reversed() where !lines[index].isBackground {
            guard index + 1 < lines.count, lines[index + 1].isBackground else { continue }
            let words = (lines[index].words + lines[index + 1].words).filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            if !words.isEmpty {
                let start = min(words.map { $0.start * 1000 }.min() ?? .infinity, starts[index], starts[index + 1])
                let end = max(words.map { $0.end * 1000 }.max() ?? 0, ends[index], ends[index + 1])
                starts[index] = start; starts[index + 1] = start
                ends[index] = end; ends[index + 1] = end
            }
        }
        for index in lines.indices where !lines[index].isBackground {
            guard let next = lines.indices.dropFirst(index + 1).first(where: { !lines[$0].isBackground }) else { continue }
            let overlap = ends[index] - starts[next]
            if overlap > 0, !(overlap > 100 && overlap > (ends[next] - starts[next]) * 0.1) {
                ends[index] = starts[next]
                if index + 1 < lines.count, lines[index + 1].isBackground {
                    ends[index + 1] = starts[next]
                }
            }
        }
        var previousStart = 0.0, previousEnd = 0.0, groupStart = 0.0, groupEnd = 0.0
        var hasPrevious = false
        for index in lines.indices where !lines[index].isBackground {
            let start = starts[index], end = ends[index]
            let gap = start >= previousEnd
            let advance = hasPrevious && !gap ? 400.0 : 600.0
            let boundary = hasPrevious ? (gap ? groupEnd : previousStart + (previousEnd - previousStart) * 0.3) : 0
            starts[index] = min(start, max(boundary, start - advance))
            if index + 1 < lines.count, lines[index + 1].isBackground {
                starts[index + 1] = starts[index]
            }
            if hasPrevious, start < groupEnd, end > groupStart {
                groupStart = min(groupStart, start); groupEnd = max(groupEnd, end)
            } else {
                groupStart = start; groupEnd = end
            }
            previousStart = start; previousEnd = end; hasPrevious = true
        }
        for index in lines.indices {
            lines[index].start = starts[index] / 1000
            lines[index].end = ends[index] / 1000
        }
        var groups: [Group] = []
        for index in lines.indices {
            if !lines[index].isBackground || groups.isEmpty {
                groups.append(.init(main: index, backgroundFirst: false))
            } else {
                let last = groups.count - 1
                let main = groups[last].main
                groups[last].background = index
                groups[last].backgroundFirst = (lines[index].words.first?.start ?? lines[index].start)
                    < (lines[main].words.first?.start ?? lines[main].start)
                lines[index].isDuet = lines[main].isDuet
            }
        }
        self.lines = lines
        self.groups = groups
        timings = groups.map { .init(startTime: starts[$0.main], endTime: ends[$0.main]) }
    }
}
