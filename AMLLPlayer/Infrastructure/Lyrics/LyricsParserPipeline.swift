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
                if primary[index].romanization.isEmpty {
                    primary[index].romanization = auxiliary[best].text
                }
                mergeRomanizedWords(auxiliary[best].words, into: &primary[index].words)
            }
        }
    }

    private static func mergeRomanizedWords(_ romanized: [LyricWord], into primary: inout [LyricWord]) {
        guard !romanized.isEmpty, !primary.isEmpty else { return }
        var cursor = 0
        for index in primary.indices {
            var best: Int?
            var bestOverlap = 0.0
            for candidate in romanized.indices.dropFirst(cursor) {
                let overlap = max(0, min(primary[index].end, romanized[candidate].end) - max(primary[index].start, romanized[candidate].start))
                if overlap > bestOverlap {
                    best = candidate
                    bestOverlap = overlap
                }
                if romanized[candidate].start > primary[index].end {
                    break
                }
            }
            if let best, bestOverlap > 0 {
                primary[index].romanWord = romanized[best].text.trimmingCharacters(in: .whitespacesAndNewlines)
                cursor = best + 1
            }
        }
    }
}
