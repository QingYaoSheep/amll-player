import Foundation

/// Port of chunkAndSplitLyricWords. Groups are indivisible layout children, while
/// their constituent timed syllables remain available to the mask generator.
enum AMLLWordSegmentation {
    static func isCJK(_ text: String) -> Bool {
        text.range(of: #"^[\p{Unified_Ideograph}\u0800-\u9FFC]+$"#, options: .regularExpression) != nil
    }

    static func chunks(_ words: [LyricWord]) -> [[LyricWord]] {
        var result: [[LyricWord]] = []
        var group: [LyricWord] = []
        func flush() {
            if !group.isEmpty {
                result.append(group); group = []
            }
        }
        func process(_ atom: LyricWord) {
            if !atom.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !isCJK(atom.text) {
                group.append(atom)
            } else {
                flush(); result.append([atom])
            }
        }
        for word in words {
            if word.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                process(word); continue
            }
            let ns = word.text as NSString
            let pattern = try? NSRegularExpression(pattern: #"\s+|\S+"#)
            let parts = pattern?.matches(in: word.text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) } ?? [word.text]
            let length = parts.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.reduce(0) { $0 + $1.utf16.count }
            let unit = (word.end - word.start) / Double(max(1, length))
            var offset = 0
            for part in parts {
                if part.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let time = word.start + Double(offset) * unit
                    process(.init(text: part, start: time, end: time))
                } else if isCJK(part), part.utf16.count > 1, (word.romanWord ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    // Keep surrogate pairs intact at the native shaping boundary. Times still
                    // advance in UTF-16 units, matching the source's offset convention.
                    for character in part {
                        let text = String(character)
                        let start = word.start + Double(offset) * unit
                        offset += text.utf16.count
                        process(.init(text: text, start: start, end: word.start + Double(offset) * unit))
                    }
                } else {
                    let start = word.start + Double(offset) * unit
                    offset += part.utf16.count
                    process(.init(text: part, start: start, end: word.start + Double(offset) * unit, romanWord: word.romanWord))
                }
            }
        }
        flush()
        return result
    }
}
