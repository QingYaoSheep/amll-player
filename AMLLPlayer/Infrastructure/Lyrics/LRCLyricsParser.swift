import Foundation

enum LRCLyricsParser {
    struct Row { var time: Double; var text: String }

    static func decodeField(_ value: String) throws -> String {
        guard value.utf8.count <= 2_000_000 else { throw LyricsError.tooLarge }
        if value.contains("[") || value.isEmpty {
            return value
        }
        guard let bytes = Data(base64Encoded: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              let decoded = String(data: bytes, encoding: .utf8) else { throw LyricsError.malformed }
        return decoded
    }

    static func rows(_ text: String) throws -> [Row] {
        guard text.utf8.count <= 2_000_000 else { throw LyricsError.tooLarge }
        let regex = try NSRegularExpression(pattern: #"\[(\d{1,4}):(\d{1,2})(?:[.:](\d{1,3}))?\]"#)
        let offsetRegex = try NSRegularExpression(pattern: #"(?i)\[offset:([+-]?\d+)\]"#)
        let ns = text as NSString
        let match = offsetRegex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length))
        let offset = match.flatMap { Double(ns.substring(with: $0.range(at: 1))) }.map { max(-60, min(60, $0 / 1000)) } ?? 0
        var result: [Row] = []
        for line in text.components(separatedBy: .newlines) {
            let source = line as NSString
            let matches = regex.matches(in: line, range: NSRange(location: 0, length: source.length))
            guard let last = matches.last else { continue }
            let content = source.substring(from: NSMaxRange(last.range)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { continue }
            for match in matches {
                let minutes = Double(source.substring(with: match.range(at: 1))) ?? 0
                let seconds = Double(source.substring(with: match.range(at: 2))) ?? 0
                guard seconds < 60 else { continue }
                let fraction = match.range(at: 3).location == NSNotFound ? 0 : Double("0." + source.substring(with: match.range(at: 3))) ?? 0
                result.append(Row(time: max(0, minutes * 60 + seconds + fraction + offset), text: content))
                guard result.count <= 20000 else { throw LyricsError.tooLarge }
            }
        }
        return result.enumerated().sorted { $0.element.time == $1.element.time ? $0.offset < $1.offset : $0.element.time < $1.element.time }.map(\.element)
    }

    static func parse(_ original: String, translation: String = "", romanization: String = "", duration: Double) throws -> [LyricLine] {
        let main = try rows(original), translations = try rows(translation), romans = try rows(romanization)
        func aligned(_ rows: [Row], _ time: Double) -> String {
            var low = 0, high = rows.count
            while low < high {
                let mid = (low + high) / 2; if rows[mid].time < time {
                    low = mid + 1
                } else {
                    high = mid
                }
            }
            return [low - 1, low].filter { rows.indices.contains($0) }.map { rows[$0] }
                .filter { abs($0.time - time) <= 0.250001 }.min { abs($0.time - time) < abs($1.time - time) }?.text ?? ""
        }
        var ends = Array(repeating: 0.0, count: main.count)
        var next: Double?
        for i in main.indices.reversed() {
            if i + 1 < main.count, main[i + 1].time > main[i].time {
                next = main[i + 1].time
            }
            ends[i] = next ?? (duration > main[i].time ? duration : main[i].time + 5)
        }
        return main.enumerated().map { index, row in
            LyricLine(id: "lrc-\(index)", text: row.text, start: row.time,
                      end: ends[index], translation: aligned(translations, row.time),
                      romanization: aligned(romans, row.time))
        }
    }
}
