import Foundation

enum LyricsFormatDetector {
    static func detect(_ text: String, hint: LyricsAsset.Format? = nil) -> LyricsAsset.Format {
        let sample = String(text.prefix(64000))
        if sample.range(of: #"<\s*(?:[A-Za-z0-9_-]+:)?tt(?:\s|>)"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return .ttml
        }
        if sample.range(of: #"\[\d+\s*,\s*\d+\]\s*\(\d+\s*,\s*\d+\s*,\s*\d+\)"#, options: .regularExpression) != nil {
            return .yrc
        }
        if sample.range(of: #"(?:LyricContent\s*=|^|\n)\s*\[\d+\s*,\s*\d+\].*?\(\d+\s*,\s*\d+\)"#,
                        options: [.regularExpression, .caseInsensitive]) != nil
        {
            return .qrc
        }
        if sample.range(of: #"\[\d{1,4}:\d{1,2}(?:[.:]\d{1,4})?\]"#, options: .regularExpression) != nil {
            return .lrc
        }
        return hint ?? .lrc
    }
}

enum LyricsParserPipeline {
    static func parse(_ bundle: LyricsAssetBundle, candidate: LyricCandidate, duration: Double) throws -> LyricsDocument {
        if bundle.isInstrumental {
            return LyricsDocument(candidate: candidate, lines: [], language: bundle.language,
                                  selectionReason: bundle.selectionReason, isInstrumental: true,
                                  degradationReason: bundle.degradationReason)
        }

        let primary = normalized(bundle.primary)
        var lines = try parse(primary, preferredLanguage: preferredLanguage(bundle), duration: duration)
        guard !lines.isEmpty else { throw LyricsError.notFound }

        if !bundle.translationAssets.isEmpty {
            let assets = ordered(bundle.translationAssets, preferredLanguage: preferredLanguage(bundle))
            if let auxiliary = firstUsable(assets, duration: duration) {
                merge(auxiliary, into: &lines, role: .translation)
            }
        }
        if !bundle.romanizationAssets.isEmpty {
            let assets = ordered(bundle.romanizationAssets, preferredLanguage: preferredLanguage(bundle))
            if let auxiliary = firstUsable(assets, duration: duration) {
                merge(auxiliary, into: &lines, role: .romanization)
            }
        }

        return LyricsDocument(candidate: candidate, lines: lines, language: bundle.language,
                              selectionReason: bundle.selectionReason, isInstrumental: false,
                              degradationReason: bundle.degradationReason)
    }

    private enum AuxiliaryRole { case translation, romanization }

    private static func normalized(_ asset: LyricsAsset) -> LyricsAsset {
        var result = asset
        result.format = LyricsFormatDetector.detect(asset.text, hint: asset.format)
        return result
    }

    private static func preferredLanguage(_ bundle: LyricsAssetBundle) -> String {
        bundle.language.isEmpty ? "zh-Hans-CN" : bundle.language
    }

    private static func parse(_ asset: LyricsAsset, preferredLanguage: String, duration: Double) throws -> [LyricLine] {
        switch asset.format {
        case .ttml:
            try TTMLLyricsParser.parse(asset.text, preferredLanguage: preferredLanguage, duration: duration)
        case .qrc:
            try QQRCDecoder.parse(asset.text, duration: duration)
        case .yrc:
            try YRCLyricsParser.parse(asset.text, duration: duration)
        case .lrc:
            try LRCLyricsParser.parse(asset.text, duration: duration)
        }
    }

    private static func firstUsable(_ assets: [LyricsAsset], duration: Double) -> [LyricLine]? {
        for asset in assets {
            do {
                let lines = try parse(normalized(asset), preferredLanguage: asset.language, duration: duration)
                if !lines.isEmpty {
                    return lines
                }
            } catch {}
        }
        return nil
    }

    private static func ordered(_ assets: [LyricsAsset], preferredLanguage: String) -> [LyricsAsset] {
        assets.enumerated().sorted { lhs, rhs in
            let a = languageRank(lhs.element.language, preferred: preferredLanguage)
            let b = languageRank(rhs.element.language, preferred: preferredLanguage)
            return a == b ? lhs.offset < rhs.offset : a > b
        }.map(\.element)
    }

    private static func languageRank(_ language: String, preferred: String) -> Int {
        let language = language.lowercased(), preferred = preferred.lowercased()
        if !language.isEmpty, language == preferred {
            return 4
        }
        let base = preferred.split(separator: "-").first.map(String.init) ?? preferred
        if !language.isEmpty, language == base || language.hasPrefix(base + "-") {
            return 3
        }
        if language.hasPrefix("zh-hans") {
            return 2
        }
        return language.isEmpty ? 1 : 0
    }

    private static func merge(_ auxiliary: [LyricLine], into primary: inout [LyricLine], role: AuxiliaryRole) {
        if case .romanization = role {
            LyricsRomanizationAlignment.mergeLines(auxiliary, into: &primary)
            return
        }
        let auxiliary = auxiliary.sorted { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start }
        var cursor = 0
        for index in primary.indices {
            var best: Int?
            var bestDistance = Double.infinity
            var candidate = cursor
            while candidate < auxiliary.count, auxiliary[candidate].start <= primary[index].start + 0.250_001 {
                let distance = abs(auxiliary[candidate].start - primary[index].start)
                if distance <= 0.250_001, distance < bestDistance {
                    best = candidate
                    bestDistance = distance
                }
                candidate += 1
            }
            guard let best else { continue }
            cursor = best + 1
            switch role {
            case .translation:
                if primary[index].translation.isEmpty {
                    primary[index].translation = auxiliary[best].text
                }
            case .romanization:
                break // Handled by the voice-aware, mutual match above.
            }
        }
    }
}

/// Require a unique mutual match. A whole-line pronunciation overlapping many
/// words must remain line-level, not become an arbitrary first-word annotation.
enum LyricsRomanizationAlignment {
    static func mergeLines(_ annotations: [LyricLine], into lines: inout [LyricLine]) {
        func candidates(for line: LyricLine, among others: [LyricLine]) -> [Int] {
            let eligible = others.indices.filter {
                let other = others[$0]
                return abs(line.start - other.start) <= 0.250001 &&
                    line.isBackground == other.isBackground && line.isDuet == other.isDuet &&
                    (line.agent == nil || other.agent == nil || line.agent == other.agent)
            }
            guard let nearest = eligible.map({ abs(line.start - others[$0].start) }).min() else { return [] }
            return eligible.filter { abs(abs(line.start - others[$0].start) - nearest) < 0.000001 }
        }
        let original = lines
        for index in lines.indices {
            let matches = candidates(for: original[index], among: annotations)
            guard matches.count == 1, let match = matches.first,
                  candidates(for: annotations[match], among: original) == [index] else { continue }
            if lines[index].romanization.isEmpty {
                lines[index].romanization = annotations[match].text
            }
            merge(annotations[match].words, into: &lines[index].words)
        }
    }

    static func merge(_ annotations: [LyricWord], into words: inout [LyricWord]) {
        func score(_ a: LyricWord, _ b: LyricWord) -> Double {
            guard a.start.isFinite, a.end.isFinite, b.start.isFinite, b.end.isFinite else { return 0 }
            if abs(a.start - b.start) <= 0.003, abs(a.end - b.end) <= 0.003 {
                return 2
            }
            let overlap = max(0, min(a.end, b.end) - max(a.start, b.start))
            return overlap / max(0.001, max(a.end, b.end) - min(a.start, b.start))
        }
        func uniqueBest(_ scores: [Double]) -> Int? {
            guard let maximum = scores.max(), maximum >= 0.5 else { return nil }
            let matches = scores.indices.filter { abs(scores[$0] - maximum) < 0.000001 }
            return matches.count == 1 ? matches[0] : nil
        }
        let matrix = words.map { word in annotations.map { score(word, $0) } }
        for index in words.indices where words[index].romanWord?.isEmpty ?? true {
            guard let candidate = uniqueBest(matrix[index]),
                  uniqueBest(matrix.map { $0[candidate] }) == index else { continue }
            let annotation = annotations[candidate]
            // Reject unequal-length whole-line annotations too: choosing the
            // longest overlap would otherwise attach the entire phrase to one
            // word. Only tolerate the parser's 3 ms boundary precision.
            let overlaps = words.indices.filter {
                min(words[$0].end, annotation.end) - max(words[$0].start, annotation.start) > 0.003
            }
            guard overlaps.count <= 1 else { continue }
            let text = annotation.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            words[index].romanWord = text
            // Equal timing is already represented by the body timestamps;
            // preserve old cache/golden values without redundant metadata.
            words[index].romanStart = annotation.start == words[index].start ? nil : annotation.start
            words[index].romanEnd = annotation.end == words[index].end ? nil : annotation.end
        }
    }
}
