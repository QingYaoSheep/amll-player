import Foundation

/// Display-only counterpart of core processObsceneWord. Native grapheme
/// boundaries intentionally keep surrogate pairs and combining marks intact.
struct AMLLObsceneWordMask: Codable, Equatable, Sendable {
    enum Mode: String, Codable, CaseIterable, Sendable {
        case disabled, partial, full
    }

    var mode: Mode = .disabled
    var character = "*"

    func display(_ text: String, marked: Bool) -> String {
        guard marked, mode != .disabled else { return text }
        let characters = Array(text)
        let visible = characters.indices.filter { !characters[$0].isWhitespace }
        let replacement = character.isEmpty ? "*" : character
        return characters.indices.map { index in
            guard !characters[index].isWhitespace else { return String(characters[index]) }
            if mode == .partial, visible.count > 2,
               index == visible.first || index == visible.last
            {
                return String(characters[index])
            }
            return replacement
        }.joined()
    }

    func apply(to lines: [LyricLine]) -> [LyricLine] {
        guard mode != .disabled else { return lines }
        return lines.map { original in
            var line = original
            line.words = original.words.map { originalWord in
                var word = originalWord
                word.text = display(word.text, marked: word.isObscene)
                return word
            }
            // Do not replace plain line text unless its word mapping is exact.
            if original.text == original.words.map(\.text).joined() {
                line.text = line.words.map(\.text).joined()
            }
            return line
        }
    }
}
