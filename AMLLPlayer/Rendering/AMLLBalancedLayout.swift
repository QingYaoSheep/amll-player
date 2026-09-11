import Foundation

/// Source port: core/src/utils/lyric-line-break.ts. Measurement and segmentation are supplied by the text adapter.
enum AMLLBalancedLayout {
    struct Child: Codable, Equatable, Sendable {
        var text: String
        var width: Double
        var isSpace: Bool
    }

    static func breaks(children: [Child], width: Double, cjkBoundaries: Set<Int>) -> [Int] {
        let count = children.count
        guard count > 0, width.isFinite, width > 0,
              children.allSatisfy({ $0.width.isFinite && $0.width >= 0 }) else { return [] }
        var offsets = [0]
        var widths = [0.0]
        for child in children {
            offsets.append(offsets[offsets.count - 1] + child.text.utf16.count)
            widths.append(widths[widths.count - 1] + child.width)
        }
        guard widths[count] > width else { return [] }
        var cost = [Double](repeating: .infinity, count: count + 1)
        var next = [Int](repeating: -1, count: count + 1)
        cost[count] = 0
        let punctuation = Set(",.;:!?，。；：！？、）】》」』’”)]}>~…")
        for i in stride(from: count - 1, through: 0, by: -1) {
            for j in (i + 1) ... count {
                let occupied = widths[j] - widths[i]
                var lineCost = 0.0
                if occupied > width {
                    if j != i + 1 {
                        continue
                    }
                    lineCost = pow(occupied - width, 2) * 1000
                } else {
                    lineCost = pow(width - occupied, 2)
                }
                var penalty = 0.0
                if j < count {
                    let previous = children[j - 1]
                    if let last = previous.text.last, punctuation.contains(last) {
                        penalty = -pow(width * 0.6, 2)
                    } else if previous.isSpace {
                        penalty = -pow(width * 0.4, 2)
                    } else {
                        penalty = pow(width * (cjkBoundaries.contains(offsets[j]) ? 0.15 : 0.5), 2)
                    }
                }
                let candidate = lineCost + penalty + cost[j]
                if candidate < cost[i] {
                    cost[i] = candidate; next[i] = j
                }
            }
        }
        var result: [Int] = []
        var cursor = 0
        while cursor < count {
            let successor = next[cursor]
            guard successor > cursor else { break }
            cursor = successor
            if cursor < count {
                result.append(cursor)
            }
        }
        return result
    }
}
