import Foundation

/// Port of chunkAndSplitLyricWords. Groups are indivisible layout children, while
/// their constituent timed syllables remain available to the mask generator.
enum AMLLWordSegmentation {
    /// Stable provider-word ownership survives whitespace/CJK splitting. Ranges
    /// address the source word's UTF-16 text, never ruby syllables or timestamps.
    struct Atom {
        var word: LyricWord
        var sourceWordIndex: Int
        var sourceRange: NSRange
    }

    static func isCJK(_ text: String) -> Bool {
        text.range(of: #"^[\p{Unified_Ideograph}\u0800-\u9FFC]+$"#, options: .regularExpression) != nil
    }

    static func chunks(_ words: [LyricWord]) -> [[LyricWord]] {
        mappedChunks(words).map { $0.map(\.word) }
    }

    static func mappedChunks(_ words: [LyricWord]) -> [[Atom]] {
        var result: [[Atom]] = []
        var group: [Atom] = []
        var sourceWordIndex = 0
        var sourceOffset = 0
        func flush() {
            if !group.isEmpty {
                result.append(group); group = []
            }
        }
        func process(_ atom: LyricWord) {
            let mapped = Atom(word: atom, sourceWordIndex: sourceWordIndex,
                              sourceRange: NSRange(location: sourceOffset, length: atom.text.utf16.count))
            sourceOffset += mapped.sourceRange.length
            let hasRuby = !atom.rubySegments.isEmpty || !(atom.ruby?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            if !atom.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !isCJK(atom.text), !hasRuby {
                group.append(mapped)
            } else {
                flush(); result.append([mapped])
            }
        }
        for (index, word) in words.enumerated() {
            sourceWordIndex = index
            sourceOffset = 0
            // Provider pronunciation owns the whole word, including internal
            // spaces. Do not duplicate it or manufacture child timings.
            if !(word.romanWord?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) {
                let leading = String(word.text.prefix(while: \.isWhitespace))
                let withoutLeading = String(word.text.dropFirst(leading.count))
                let trailing = String(withoutLeading.suffix(while: \.isWhitespace))
                let body = String(withoutLeading.dropLast(trailing.count))
                if !leading.isEmpty {
                    process(.init(text: leading, start: word.start, end: word.start,
                                  voice: word.voice, isObscene: word.isObscene))
                }
                if !body.isEmpty {
                    process(.init(text: body, start: word.start, end: word.end,
                                  romanWord: word.romanWord, ruby: word.ruby, rubySegments: word.rubySegments,
                                  voice: word.voice, isObscene: word.isObscene,
                                  romanStart: word.romanStart, romanEnd: word.romanEnd))
                }
                if !trailing.isEmpty {
                    process(.init(text: trailing, start: word.end, end: word.end,
                                  voice: word.voice, isObscene: word.isObscene))
                }
                continue
            }
            let hasRuby = !word.rubySegments.isEmpty || !(word.ruby?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            if word.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || hasRuby {
                process(word); continue
            }
            let ns = word.text as NSString
            let pattern = try? NSRegularExpression(pattern: #"\s+|\S+"#)
            let parts = pattern?.matches(in: word.text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) } ?? [word.text]
            // A provider annotation belongs to its original word. Splitting a
            // phrase must not duplicate that annotation onto every child. The
            // layout retains the original word through sourceWordIndex and can
            // fall back to its single line-level annotation when ambiguous.
            let annotation = parts.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count == 1
                ? word.romanWord : nil
            let length = parts.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.reduce(0) { $0 + $1.utf16.count }
            let unit = (word.end - word.start) / Double(max(1, length))
            var offset = 0
            for part in parts {
                if part.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let time = word.start + Double(offset) * unit
                    process(.init(text: part, start: time, end: time, voice: word.voice, isObscene: word.isObscene))
                } else if isCJK(part), part.utf16.count > 1, (word.romanWord ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    // Keep surrogate pairs intact at the native shaping boundary. Times still
                    // advance in UTF-16 units, matching the source's offset convention.
                    for character in part {
                        let text = String(character)
                        let start = word.start + Double(offset) * unit
                        offset += text.utf16.count
                        process(.init(text: text, start: start, end: word.start + Double(offset) * unit,
                                      voice: word.voice, isObscene: word.isObscene))
                    }
                } else {
                    let start = word.start + Double(offset) * unit
                    offset += part.utf16.count
                    process(.init(text: part, start: start, end: word.start + Double(offset) * unit,
                                  romanWord: annotation, voice: word.voice, isObscene: word.isObscene))
                }
            }
        }
        flush()
        return result
    }
}
