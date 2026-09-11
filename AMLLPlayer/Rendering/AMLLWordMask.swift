import Foundation

/// Samples the source's connected word-mask travel, including holds between words.
/// Widths refer to shaped words, not character counts. All times are seconds.
enum AMLLWordMask {
    struct Word: Sendable {
        var start: Double
        var end: Double
        var width: Double
    }

    static func edge(time: Double, index: Int, words: [Word], feather: Double) -> Double {
        guard words.indices.contains(index) else { return 0 }
        let before = words.prefix(index).reduce(0) { $0 + $1.width }
        var position = 0.0
        for (otherIndex, word) in words.enumerated() {
            let movement = word.width + (otherIndex == 0 ? feather * 1.5 : 0) + (otherIndex == words.count - 1 ? feather * 0.5 : 0)
            if time < word.start {
                break
            }
            if word.end > word.start, time < word.end {
                position += movement * (time - word.start) / (word.end - word.start)
                break
            }
            position += movement
        }
        return position - before - feather * 2
    }
}
