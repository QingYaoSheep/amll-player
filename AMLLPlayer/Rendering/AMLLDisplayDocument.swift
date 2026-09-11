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
            for word in lines[index].words.indices {
                lines[index].words[word].text = lines[index].words[word].text
                    .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            }
            if lines[index].precision == .word, let first = lines[index].words.first, let last = lines[index].words.last {
                lines[index].start = first.start
                lines[index].end = last.end
                lines[index].text = lines[index].words.map(\.text).joined()
            }
        }
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
                let start = min(words.map(\.start).min() ?? .infinity, lines[index].start, lines[index + 1].start)
                let end = max(words.map(\.end).max() ?? 0, lines[index].end, lines[index + 1].end)
                lines[index].start = start; lines[index + 1].start = start
                lines[index].end = end; lines[index + 1].end = end
            }
        }
        for index in lines.indices where !lines[index].isBackground {
            guard let next = lines.indices.dropFirst(index + 1).first(where: { !lines[$0].isBackground }) else { continue }
            let overlap = lines[index].end - lines[next].start
            if overlap > 0, !(overlap > 0.1 && overlap > (lines[next].end - lines[next].start) * 0.1) {
                lines[index].end = lines[next].start
                if index + 1 < lines.count, lines[index + 1].isBackground {
                    lines[index + 1].end = lines[next].start
                }
            }
        }
        var previousStart = 0.0, previousEnd = 0.0, groupStart = 0.0, groupEnd = 0.0
        var hasPrevious = false
        for index in lines.indices where !lines[index].isBackground {
            let start = lines[index].start, end = lines[index].end
            let gap = start >= previousEnd
            let advance = hasPrevious && !gap ? 0.4 : 0.6
            let boundary = hasPrevious ? (gap ? groupEnd : previousStart + (previousEnd - previousStart) * 0.3) : 0
            lines[index].start = min(start, max(boundary, start - advance))
            if index + 1 < lines.count, lines[index + 1].isBackground {
                lines[index + 1].start = lines[index].start
            }
            if hasPrevious, start < groupEnd, end > groupStart {
                groupStart = min(groupStart, start); groupEnd = max(groupEnd, end)
            } else {
                groupStart = start; groupEnd = end
            }
            previousStart = start; previousEnd = end; hasPrevious = true
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
        timings = groups.map { .init(startTime: lines[$0.main].start * 1000, endTime: lines[$0.main].end * 1000) }
    }
}
