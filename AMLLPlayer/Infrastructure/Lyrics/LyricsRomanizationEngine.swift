import CryptoKit
import Foundation

struct RomanizationResult: Codable, Sendable {
    struct Line: Codable, Sendable {
        var index: Int
        var language: String
        var text: String
        var tokens: [RomanizationToken]
        var coverage: Double
    }

    var engineVersion: String
    var lines: [Line]
    var processedLineIndexes: [Int]
    var diagnostics: [String]

    func applying(to original: LyricsDocument) -> LyricsDocument {
        var document = original
        for line in lines where document.lines.indices.contains(line.index) {
            document.lines[line.index].generatedRomanization = line.tokens
            document.lines[line.index].generatedRomanizationLanguage = line.language
        }
        return document
    }
}

/// Native port of Mineradio's romanization-engine.js. It is an actor so the
/// dictionary is loaded once off the main actor and never in a render frame.
actor LyricsRomanizationEngine {
    static let shared = LyricsRomanizationEngine()
    static let ruleVersion: String = {
        let url = Bundle.main.url(forResource: "romanization-resources", withExtension: "json", subdirectory: "Romanization")
            ?? Bundle.main.url(forResource: "romanization-resources", withExtension: "json")
        guard let url, let data = try? Data(contentsOf: url) else { return "mineradio-2-missing" }
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return "mineradio-2-\(hash.prefix(12))"
    }()

    private let initials = ["g", "kk", "n", "d", "tt", "r", "m", "b", "pp", "s", "ss", "", "j", "jj", "ch", "k", "t", "p", "h"]
    private let vowels = ["a", "ae", "ya", "yae", "eo", "e", "yeo", "ye", "o", "wa", "wae", "oe", "yo", "u", "wo", "we", "wi", "yu", "eu", "ui", "i"]
    private let finals = ["", "k", "k", "k", "n", "n", "n", "t", "l", "k", "m", "p", "l", "l", "p", "l", "m", "p", "p", "t", "t", "ng", "t", "t", "k", "t", "p", "t"]
    private let liaison: [Int: Int] = [1: 0, 2: 1, 4: 2, 7: 3, 8: 5, 16: 6, 17: 7, 19: 9, 20: 10, 22: 12, 23: 14, 24: 15, 25: 16, 26: 17]
    private let complex: [Int: (Int, Int)] = [3: (1, 9), 5: (4, 12), 6: (4, 18), 9: (8, 0), 10: (8, 6), 11: (8, 7), 12: (8, 9), 13: (8, 16), 14: (8, 17), 15: (8, 18), 18: (17, 9)]
    private var dictionary: MineradioKuromoji?
    private var kanaMap: [String: String]?
    private var overrides: [String: [String: String]]?

    private struct Syllable {
        var initial: Int
        var vowel: Int
        var final: Int
    }

    static func version(overrides: [String: [String: String]]) -> String {
        let entries = ["ja", "ko"].flatMap { language in
            (overrides[language] ?? [:]).sorted { $0.key < $1.key }.map { [language, $0.key, $0.value] }
        }
        guard !entries.isEmpty, let bytes = try? JSONEncoder().encode(entries) else { return ruleVersion }
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        return "\(ruleVersion)-\(digest.prefix(10))"
    }

    private func directory(_ name: String) throws -> URL {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw CocoaError(.fileNoSuchFile)
        }
        let folder = base.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func configuredOverrides() -> [String: [String: String]] {
        if let overrides { return overrides }
        let url = try? directory("Romanization").appendingPathComponent("overrides.json")
        let decoded = url.flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode([String: [String: String]].self, from: $0) } ?? [:]
        let valid = Self.validateOverrides(decoded)
        overrides = valid
        return valid
    }

    private static func validateOverrides(_ raw: [String: [String: String]]) -> [String: [String: String]] {
        var result: [String: [String: String]] = [:]
        for language in ["ja", "ko"] {
            let entries = (raw[language] ?? [:]).compactMapValues { value -> String? in
                let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? nil : text
            }.filter { !$0.key.isEmpty }
            if !entries.isEmpty { result[language] = entries }
        }
        return result
    }

    func importOverrides(_ data: Data) throws {
        let decoded = try JSONDecoder().decode([String: [String: String]].self, from: data)
        let valid = Self.validateOverrides(decoded)
        let output = try JSONEncoder().encode(valid)
        let url = try directory("Romanization").appendingPathComponent("overrides.json")
        try output.write(to: url, options: .atomic)
        overrides = valid
    }

    func exportOverrides() throws -> Data {
        try JSONEncoder().encode(configuredOverrides())
    }

    func resetOverrides() throws {
        let url = try directory("Romanization").appendingPathComponent("overrides.json")
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        overrides = [:]
    }

    func clearGeneratedCache() throws {
        let folder = try directory("RomanizationCache")
        for url in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
            try FileManager.default.removeItem(at: url)
        }
    }

    func generateCached(document: LyricsDocument, force: Bool = false) -> RomanizationResult {
        let overrides = configuredOverrides()
        let version = Self.version(overrides: overrides)
        // Include exact source text, real word times and language. Generated
        // display fields are deliberately excluded from the source identity.
        struct Input: Encodable {
            var version: String
            var language: String
            var lines: [InputLine]
        }
        struct InputLine: Encodable {
            var text: String
            var start: Double
            var end: Double
            var words: [LyricWord]
        }
        let input = Input(version: version, language: document.language,
                          lines: document.lines.map { .init(text: $0.text, start: $0.start,
                                                             end: $0.end, words: $0.words) })
        let encoded = (try? JSONEncoder().encode(input)) ?? Data()
        let key = SHA256.hash(data: encoded).map { String(format: "%02x", $0) }.joined()
        let url = try? directory("RomanizationCache").appendingPathComponent(key + ".json")
        if !force, let url, let data = try? Data(contentsOf: url),
           let cached = try? JSONDecoder().decode(RomanizationResult.self, from: data),
           cached.engineVersion == version { return cached }
        let result = generate(document: document, overrides: overrides)
        if let url, let data = try? JSONEncoder().encode(result) {
            try? data.write(to: url, options: .atomic)
        }
        return result
    }

    private func japaneseDictionary() throws -> MineradioKuromoji {
        if let dictionary { return dictionary }
        let loaded = try MineradioKuromoji()
        dictionary = loaded
        return loaded
    }

    private func japaneseKanaMap() throws -> [String: String] {
        if let kanaMap { return kanaMap }
        guard let url = Bundle.main.url(forResource: "roman-kana-map", withExtension: "json", subdirectory: "Romanization")
                ?? Bundle.main.url(forResource: "roman-kana-map", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        let loaded = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))
        kanaMap = loaded
        return loaded
    }

    private func romanizeKana(_ reading: String, map: [String: String]) -> String {
        let characters = reading.unicodeScalars.map { String($0) }
        var result = ""
        var index = 0
        while index < characters.count {
            if characters[index] == "ー" {
                // WanaKana convertLongVowelMark extends the previous vowel.
                if let vowel = result.last(where: { "aeiou".contains($0) }) { result.append(vowel) }
                else { result += "-" }
                index += 1
                continue
            }
            var matched = false
            for length in stride(from: min(3, characters.count - index), through: 1, by: -1) {
                let key = characters[index ..< index + length].joined()
                // A terminal sokuon is silent in isolation, but must remain
                // available to double the following consonant when one exists.
                if index + length < characters.count, key.hasSuffix("っ") || key.hasSuffix("ッ") {
                    continue
                }
                guard let value = map[key] else { continue }
                result += value
                index += length
                matched = true
                break
            }
            if !matched { result += characters[index]; index += 1 }
        }
        return result.lowercased()
    }

    private func decompose(_ scalar: Unicode.Scalar) -> Syllable? {
        let offset = Int(scalar.value) - 0xAC00
        guard offset >= 0 && offset <= 11171 else { return nil }
        return Syllable(initial: offset / 588, vowel: offset % 588 / 28, final: offset % 28)
    }

    private func korean(_ text: String) -> String {
        let characters = Array(text.unicodeScalars)
        var result = ""
        var cursor = 0
        while cursor < characters.count {
            guard decompose(characters[cursor]) != nil else {
                result.unicodeScalars.append(characters[cursor])
                cursor += 1
                continue
            }
            var syllables: [Syllable] = []
            while cursor < characters.count, let syllable = decompose(characters[cursor]) {
                syllables.append(syllable)
                cursor += 1
            }
            if syllables.count > 1 {
                for index in 0 ..< syllables.count - 1 {
                    guard syllables[index].final != 0, syllables[index + 1].initial == 11 else { continue }
                    let final = syllables[index].final
                    if (final == 7 || final == 25) && syllables[index + 1].vowel == 20 {
                        syllables[index].final = 0
                        syllables[index + 1].initial = final == 7 ? 12 : 14
                    } else if final == 27 {
                        syllables[index].final = 0
                    } else if let change = complex[final] {
                        syllables[index].final = change.0
                        syllables[index + 1].initial = change.1
                    } else if let onset = liaison[final] {
                        syllables[index].final = 0
                        syllables[index + 1].initial = onset
                    }
                }
            }
            result += syllables.map { initials[$0.initial] + vowels[$0.vowel] + finals[$0.final] }.joined(separator: " ")
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func contains(_ text: String, range: ClosedRange<UInt32>) -> Bool {
        text.unicodeScalars.contains { range.contains($0.value) }
    }

    private static func nodes(for line: LyricLine, from start: Int, to end: Int) -> [Int] {
        var cursor = 0
        var result: [Int] = []
        guard line.words.map(\.text).joined() == line.text else { return [] }
        for (index, word) in line.words.enumerated() {
            let next = cursor + word.text.utf16.count
            if next > start && cursor < end { result.append(index) }
            cursor = next
        }
        return result
    }

    func generate(document: LyricsDocument, overrides: [String: [String: String]] = [:]) -> RomanizationResult {
        let corpus = document.lines.map(\.text).joined(separator: "\n")
        let japaneseCorpus = Self.contains(corpus, range: 0x3040 ... 0x30FF)
        let japaneseHint = document.language.lowercased().hasPrefix("ja")
        var lines: [RomanizationResult.Line] = []
        var processed: [Int] = []
        var diagnostics: [String] = []
        for (lineIndex, line) in document.lines.enumerated() {
            if Task.isCancelled { break }
            let hasKorean = Self.contains(line.text, range: 0xAC00 ... 0xD7A3)
            let hasKana = Self.contains(line.text, range: 0x3040 ... 0x30FF)
            let hasHan = Self.contains(line.text, range: 0x3400 ... 0x9FFF)
            let language = hasKorean ? "ko" : (hasKana || (hasHan && (japaneseHint || japaneseCorpus))) ? "ja" : ""
            guard !language.isEmpty else { continue }
            processed.append(lineIndex)
            let source = line.text as NSString
            var tokens: [RomanizationToken] = []
            var coverage = 1.0
            if language == "ko" {
                let regex = try? NSRegularExpression(pattern: #"\S+"#)
                let matches = regex?.matches(in: line.text, range: NSRange(location: 0, length: source.length)) ?? []
                for match in matches {
                    let text = source.substring(with: match.range)
                    let hangulCount = text.unicodeScalars.filter { (0xAC00 ... 0xD7A3).contains($0.value) }.count
                    let override = overrides["ko"]?[text]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let useOverride = !override.isEmpty && (hangulCount <= 1 || override.split(whereSeparator: \.isWhitespace).count == hangulCount)
                    let roman = useOverride ? override : korean(text)
                    tokens.append(.init(sourceText: text, romanized: roman,
                                        utf16Start: match.range.location, utf16End: NSMaxRange(match.range),
                                        sourceNodeIndexes: Self.nodes(for: line, from: match.range.location, to: NSMaxRange(match.range)),
                                        language: language))
                }
            } else {
                do {
                    let dictionary = try japaneseDictionary()
                    let map = try japaneseKanaMap()
                    let analyzed = dictionary.tokenize(line.text)
                    var targets = 0, converted = 0, unknownHan = false
                    for entry in analyzed {
                        let text = entry.surface
                        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
                        let count = text.unicodeScalars.filter {
                            (0x3040 ... 0x30FF).contains($0.value) || (0x3400 ... 0x9FFF).contains($0.value)
                        }.count
                        targets += count
                        let latin = text.range(of: #"^[\p{Latin}\p{M}\p{N}'’\-‐‑‒–—]+$"#, options: .regularExpression) != nil
                        let override = overrides["ja"]?[text]
                        let reading = override ?? entry.pronunciation ?? entry.reading
                        let roman: String
                        if latin { roman = text }
                        else if let reading, reading != "*" {
                            roman = override == nil ? romanizeKana(reading, map: map) : reading
                        } else if Self.contains(text, range: 0x3040 ... 0x30FF) && !Self.contains(text, range: 0x3400 ... 0x9FFF) {
                            roman = romanizeKana(text, map: map)
                        } else { roman = text }
                        if count > 0 && !roman.isEmpty && roman != text { converted += count }
                        if hasHan && !hasKana && Self.contains(text, range: 0x3400 ... 0x9FFF) &&
                            (!entry.known || entry.reading == nil || entry.reading == "*") { unknownHan = true }
                        let token = RomanizationToken(sourceText: text, romanized: roman,
                                                      utf16Start: entry.start, utf16End: entry.end,
                                                      sourceNodeIndexes: Self.nodes(for: line, from: entry.start, to: entry.end),
                                                      language: language)
                        if text.range(of: #"^[\p{P}\p{S}]+$"#, options: .regularExpression) != nil,
                           !tokens.isEmpty {
                            tokens[tokens.count - 1].sourceText += text
                            tokens[tokens.count - 1].romanized += roman
                            tokens[tokens.count - 1].utf16End = entry.end
                            tokens[tokens.count - 1].sourceNodeIndexes = Array(Set(tokens[tokens.count - 1].sourceNodeIndexes + token.sourceNodeIndexes)).sorted()
                        } else { tokens.append(token) }
                    }
                    coverage = targets == 0 ? 0 : Double(converted) / Double(targets)
                    if targets == 0 || coverage < (hasHan && !hasKana ? 1 : 0.7) || unknownHan {
                        diagnostics.append("line \(lineIndex): Japanese dictionary coverage insufficient")
                        continue
                    }
                } catch {
                    diagnostics.append("line \(lineIndex): Japanese dictionary unavailable")
                    continue
                }
            }
            guard !tokens.isEmpty else { continue }
            lines.append(.init(index: lineIndex, language: language,
                               text: tokens.map(\.romanized).joined(separator: " "),
                               tokens: tokens, coverage: coverage))
        }
        return .init(engineVersion: Self.version(overrides: overrides), lines: lines,
                     processedLineIndexes: processed, diagnostics: diagnostics)
    }
}
