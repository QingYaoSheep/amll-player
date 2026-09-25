import Foundation

/// Writes a second, song-absolute timeline from Mineradio's pronunciation
/// choices. Every timed span uses a real provider node; a line without safe
/// node correspondence remains a line-timed TTML paragraph.
enum RomanizationTTMLWriter {
    private struct Segment {
        var text: String
        var start: Double
        var end: Double
    }

    static func make(source: LyricsDocument, lines: [RomanizationResult.Line]) -> String {
        guard !lines.isEmpty else { return "" }
        var paragraphs: [String] = []
        for generated in lines where source.lines.indices.contains(generated.index) {
            let original = source.lines[generated.index]
            guard original.start.isFinite, original.end.isFinite, original.end > original.start else { continue }
            let bounds = "begin=\"\(time(original.start))\" end=\"\(time(original.end))\""
            let body: String
            if original.precision == .word,
               let segments = timedSegments(generated.tokens, words: original.words),
               segments.map(\.text).joined() == generated.text
            {
                body = segments.map { segment in
                    if segment.end > segment.start {
                        return "<span begin=\"\(time(segment.start))\" end=\"\(time(segment.end))\">\(escape(segment.text))</span>"
                    }
                    return escape(segment.text)
                }.joined()
            } else {
                body = escape(generated.text)
            }
            paragraphs.append("<p xml:id=\"generated-roman-\(generated.index)\" \(bounds)>\(body)</p>")
        }
        guard !paragraphs.isEmpty else { return "" }
        return "<tt xmlns=\"http://www.w3.org/ns/ttml\" xml:lang=\"en\" xml:space=\"preserve\"><body><div>\(paragraphs.joined())</div></body></tt>"
    }

    private static func timedSegments(_ tokens: [RomanizationToken], words: [LyricWord]) -> [Segment]? {
        var result: [Segment] = []
        for (index, token) in tokens.enumerated() {
            let nodes = token.sourceNodeIndexes
            guard !nodes.isEmpty, nodes.allSatisfy({ words.indices.contains($0) }) else { return nil }
            let timed = nodes.map { words[$0] }
            guard timed.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.end > $0.start }) else { return nil }
            if index > 0 {
                // TTML's preserved text node belongs between timed spans; it
                // never creates a timing node for a sung space.
                result.append(.init(text: " ", start: 0, end: 0))
            }
            let parts = token.romanized.split(separator: " ", omittingEmptySubsequences: true)
            if token.language == "ko", parts.count == nodes.count {
                for (partIndex, part) in parts.enumerated() {
                    if partIndex > 0 { result.append(.init(text: " ", start: 0, end: 0)) }
                    result.append(.init(text: String(part), start: timed[partIndex].start, end: timed[partIndex].end))
                }
            } else {
                result.append(.init(text: token.romanized,
                                    start: timed.map(\.start).min() ?? 0,
                                    end: timed.map(\.end).max() ?? 0))
            }
        }
        return result
    }

    private static func time(_ seconds: Double) -> String {
        String(format: "%.6fs", locale: Locale(identifier: "en_US_POSIX"), max(0, seconds))
    }

    private static func escape(_ text: String) -> String {
        let valid = String(String.UnicodeScalarView(text.unicodeScalars.filter { scalar in
            let value = scalar.value
            return value == 9 || value == 10 || value == 13 || (32 ... 0xD7FF).contains(value)
                || (0xE000 ... 0xFFFD).contains(value) || (0x10000 ... 0x10FFFF).contains(value)
        }))
        return valid.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}
