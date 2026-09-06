import Foundation

enum YRCLyricsParser {
    static func parse(_ source: String, duration _: Double) throws -> [LyricLine] {
        guard source.utf8.count <= 2_000_000 else { throw LyricsError.tooLarge }
        var result: [LyricLine] = []
        for rawLine in source.components(separatedBy: .newlines) {
            guard let parsed = try parseLine(rawLine) else { continue }
            result.append(LyricLine(id: "yrc-\(result.count)", text: parsed.words.map(\.text).joined(),
                                    start: parsed.start, end: parsed.end, words: parsed.words,
                                    isBackground: parsed.isBackground, isRTL: containsRTL(parsed.words.map(\.text).joined()),
                                    precision: .word))
            guard result.count <= 20000 else { throw LyricsError.tooLarge }
        }
        guard !result.isEmpty else { throw LyricsError.notFound }
        return result
    }

    private struct ParsedLine {
        var start: Double
        var end: Double
        var words: [LyricWord]
        var isBackground: Bool
    }

    private static func parseLine(_ rawLine: String) throws -> ParsedLine? {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.first == "[", let close = line.firstIndex(of: "]") else { return nil }
        let header = line[line.index(after: line.startIndex) ..< close].split(separator: ",", omittingEmptySubsequences: false)
        guard header.count >= 2, let lineStart = Double(String(header[0]).trimmingCharacters(in: .whitespaces)),
              let lineDuration = Double(String(header[1]).trimmingCharacters(in: .whitespaces)), lineStart >= 0, lineDuration >= 0 else { throw LyricsError.malformed }

        var cursor = line.index(after: close)
        var words: [LyricWord] = []
        var lastStart = -Double.infinity
        while cursor < line.endIndex {
            guard line[cursor] == "(", let marker = timedMarker(in: line, at: cursor) else {
                if !words.isEmpty {
                    words[words.count - 1].text.append(line[cursor])
                }
                cursor = line.index(after: cursor)
                continue
            }
            guard marker.start >= lastStart else { throw LyricsError.malformed }
            let textStart = marker.end
            let next = nextTimedMarker(in: line, after: textStart) ?? line.endIndex
            let text = String(line[textStart ..< next])
            if !text.isEmpty {
                let start = marker.start / 1000
                words.append(LyricWord(text: text, start: start, end: start + marker.duration / 1000))
                lastStart = marker.start
            }
            cursor = next
        }
        guard !words.isEmpty else { return nil }
        let isBackground = stripBackgroundBrackets(from: &words)
        let start = lineStart / 1000
        return ParsedLine(start: start, end: max(start, start + lineDuration / 1000), words: words, isBackground: isBackground)
    }

    private struct Marker {
        var start: Double
        var duration: Double
        var end: String.Index
    }

    private static func timedMarker(in line: String, at start: String.Index) -> Marker? {
        guard line[start] == "(", let close = line[start...].firstIndex(of: ")") else { return nil }
        let fields = line[line.index(after: start) ..< close].split(separator: ",", omittingEmptySubsequences: false)
        guard fields.count >= 3, let wordStart = Double(String(fields[0]).trimmingCharacters(in: .whitespaces)),
              let wordDuration = Double(String(fields[1]).trimmingCharacters(in: .whitespaces)), wordStart >= 0, wordDuration >= 0 else { return nil }
        return Marker(start: wordStart, duration: wordDuration, end: line.index(after: close))
    }

    private static func nextTimedMarker(in line: String, after start: String.Index) -> String.Index? {
        var cursor = start
        while cursor < line.endIndex {
            if line[cursor] == "(", timedMarker(in: line, at: cursor) != nil {
                return cursor
            }
            cursor = line.index(after: cursor)
        }
        return nil
    }

    private static func stripBackgroundBrackets(from words: inout [LyricWord]) -> Bool {
        guard let first = words.first?.text.first, let last = words.last?.text.last,
              (first == "(" && last == ")") || (first == "（" && last == "）") else { return false }
        words[0].text.removeFirst()
        words[words.count - 1].text.removeLast()
        return true
    }

    private static func containsRTL(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (0x0590 ... 0x08FF).contains(scalar.value) || (0xFB1D ... 0xFEFC).contains(scalar.value)
        }
    }
}
