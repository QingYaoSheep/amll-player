import Foundation

enum LyricsSource: String, CaseIterable, Codable, Sendable, Identifiable {
    case apple, qq, netease
    var id: String {
        rawValue
    }

    var name: String {
        switch self { case .apple: "Apple Music"; case .qq: "QQ Music"; case .netease: "NetEase" }
    }
}

struct TrackIdentity: Codable, Equatable, Sendable {
    var spotifyID: String
    var title: String
    var artists: [String]
    var album: String
    var duration: Double
    var isrc: String?
    var query: String {
        ([title] + artists).joined(separator: " ")
    }

    init(spotifyID: String, title: String, artists: [String], album: String = "", duration: Double, isrc: String? = nil) {
        self.spotifyID = spotifyID; self.title = title; self.artists = artists
        self.album = album; self.duration = duration; self.isrc = isrc
    }

    init?(_ item: PlaybackItem?) {
        guard let item, !item.isEpisode, !item.isAdvertisement, !item.uri.isEmpty else { return nil }
        self.init(spotifyID: item.id ?? item.uri, title: item.title, artists: item.artists,
                  album: item.albumTitle ?? "", duration: item.duration, isrc: item.isrc)
    }
}

struct LyricCandidate: Codable, Equatable, Sendable, Identifiable {
    var source: LyricsSource
    var sourceID: String
    var numericID: String? = nil
    var title: String
    var artists: [String]
    var album: String = ""
    var duration: Double = 0
    var isrc: String? = nil
    var score: Int = 0
    var evidence: [String] = []
    var id: String {
        source.rawValue + ":" + sourceID
    }
}

/// A ruby annotation attached to one timed word. AMLL represents ruby as a
/// sequence because a single word can contain multiple annotations with
/// independent timings. `rubySegments` is additive to the legacy `ruby`
/// string on `LyricWord`, so cached documents from earlier parser versions
/// remain readable without throwing away annotation text.
struct LyricRuby: Codable, Equatable, Sendable {
    var text: String
    var start: Double?
    var end: Double?

    init(text: String, start: Double? = nil, end: Double? = nil) {
        self.text = text
        self.start = start
        self.end = end
    }
}

struct LyricWord: Codable, Equatable, Sendable {
    var text: String
    var start: Double
    var end: Double
    var romanWord: String? = nil
    /// Optional AMLL metadata retained by the renderer adapter. Providers may
    /// omit these fields when their source format has no equivalent.
    var ruby: String? = nil
    /// Lossless representation of AMLL's timed ruby segments. The optional
    /// legacy string above is retained for old cache payloads and providers
    /// which only expose an un-timed annotation.
    var rubySegments: [LyricRuby] = []
    var voice: String? = nil
    var isObscene = false

    init(text: String, start: Double, end: Double, romanWord: String? = nil, ruby: String? = nil,
         rubySegments: [LyricRuby] = [], voice: String? = nil, isObscene: Bool = false)
    {
        self.text = text
        self.start = start
        self.end = end
        self.romanWord = romanWord
        self.ruby = ruby
        self.rubySegments = rubySegments
        self.voice = voice
        self.isObscene = isObscene
    }

    private enum CodingKeys: String, CodingKey {
        case text, start, end, romanWord, ruby, rubySegments, voice, isObscene
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        text = try values.decode(String.self, forKey: .text)
        start = try values.decode(Double.self, forKey: .start)
        end = try values.decode(Double.self, forKey: .end)
        romanWord = try values.decodeIfPresent(String.self, forKey: .romanWord)
        ruby = try values.decodeIfPresent(String.self, forKey: .ruby)
        rubySegments = try values.decodeIfPresent([LyricRuby].self, forKey: .rubySegments) ?? []
        voice = try values.decodeIfPresent(String.self, forKey: .voice)
        // `isObscene` was introduced after the first semantic fixtures and
        // old cached payloads omit it. Missing metadata is the non-obscene
        // default used by the source renderer.
        isObscene = try values.decodeIfPresent(Bool.self, forKey: .isObscene) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(text, forKey: .text)
        try values.encode(start, forKey: .start)
        try values.encode(end, forKey: .end)
        try values.encodeIfPresent(romanWord, forKey: .romanWord)
        try values.encodeIfPresent(ruby, forKey: .ruby)
        try values.encode(rubySegments, forKey: .rubySegments)
        try values.encodeIfPresent(voice, forKey: .voice)
        try values.encode(isObscene, forKey: .isObscene)
    }
}

enum LyricsPrecision: String, Codable, Sendable { case line, word }

struct LyricLine: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var text: String
    var start: Double
    var end: Double
    var words: [LyricWord] = []
    var translation: String = ""
    var romanization: String = ""
    var isBackground = false
    var isDuet = false
    var agent: String? = nil
    var isRTL = false
    var precision: LyricsPrecision = .line
}

struct LyricsDocument: Codable, Equatable, Sendable {
    // Bump when the TTML/LRC semantic mapping changes. Existing cached
    // documents are reparsed from their payload so provider fixes become
    // visible without asking the user to clear the lyric cache.
    static let parserVersion = 4
    var candidate: LyricCandidate
    var lines: [LyricLine]
    var language: String
    var selectionReason: String
    var isInstrumental = false
    var lyricAuthor: String? = nil
    var songwriters: [String] = []
    var degradationReason: String? = nil
    var precision: LyricsPrecision {
        lines.contains { $0.precision == .word } ? .word : .line
    }

    var wordTimedLineRatio: Double {
        guard !lines.isEmpty else { return 0 }
        return Double(lines.filter { $0.precision == .word && !$0.words.isEmpty }.count) / Double(lines.count)
    }

    var translationCoverage: Double {
        guard !lines.isEmpty else { return 0 }
        return Double(lines.filter { !$0.translation.isEmpty }.count) / Double(lines.count)
    }

    var romanizationCoverage: Double {
        guard !lines.isEmpty else { return 0 }
        return Double(lines.filter { !$0.romanization.isEmpty || $0.words.contains { $0.romanWord != nil } }.count) / Double(lines.count)
    }
}

struct LyricsAsset: Codable, Equatable, Sendable {
    enum Format: String, Codable, Sendable { case ttml, qrc, yrc, lrc }
    var format: Format
    var text: String
    var language: String = ""
    var origin: String = ""
}

struct LyricsAssetBundle: Codable, Equatable, Sendable {
    typealias Format = LyricsAsset.Format
    var primary: LyricsAsset
    var translationAssets: [LyricsAsset] = []
    var romanizationAssets: [LyricsAsset] = []
    var language = ""
    var selectionReason = ""
    var degradationReason: String? = nil
    var isInstrumental = false

    init(primary: LyricsAsset, translationAssets: [LyricsAsset] = [], romanizationAssets: [LyricsAsset] = [],
         language: String = "", selectionReason: String = "", degradationReason: String? = nil, isInstrumental: Bool = false)
    {
        self.primary = primary
        self.translationAssets = translationAssets
        self.romanizationAssets = romanizationAssets
        self.language = language
        self.selectionReason = selectionReason
        self.degradationReason = degradationReason
        self.isInstrumental = isInstrumental
    }

    /// Compatibility initializer for call sites and version-2 cache records.
    init(format: Format, original: String, translation: String = "", romanization: String = "", language: String = "",
         selectionReason: String = "", isInstrumental: Bool = false)
    {
        primary = LyricsAsset(format: format, text: original, language: language)
        translationAssets = translation.isEmpty ? [] : [LyricsAsset(format: LyricsFormatDetector.detect(translation, hint: .lrc), text: translation, language: language)]
        romanizationAssets = romanization.isEmpty ? [] : [LyricsAsset(format: LyricsFormatDetector.detect(romanization, hint: .lrc), text: romanization, language: language)]
        self.language = language
        self.selectionReason = selectionReason
        self.isInstrumental = isInstrumental
    }

    var format: Format {
        primary.format
    }

    var original: String {
        primary.text
    }

    var translation: String {
        translationAssets.first?.text ?? ""
    }

    var romanization: String {
        romanizationAssets.first?.text ?? ""
    }

    func parse(candidate: LyricCandidate, duration: Double) throws -> LyricsDocument {
        try LyricsParserPipeline.parse(self, candidate: candidate, duration: duration)
    }

    private enum CodingKeys: String, CodingKey {
        case primary, translationAssets, romanizationAssets, language, selectionReason, degradationReason, isInstrumental
        case format, original, translation, romanization
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        language = try values.decodeIfPresent(String.self, forKey: .language) ?? ""
        selectionReason = try values.decodeIfPresent(String.self, forKey: .selectionReason) ?? ""
        degradationReason = try values.decodeIfPresent(String.self, forKey: .degradationReason)
        isInstrumental = try values.decodeIfPresent(Bool.self, forKey: .isInstrumental) ?? false
        if let primary = try values.decodeIfPresent(LyricsAsset.self, forKey: .primary) {
            self.primary = primary
            translationAssets = try values.decodeIfPresent([LyricsAsset].self, forKey: .translationAssets) ?? []
            romanizationAssets = try values.decodeIfPresent([LyricsAsset].self, forKey: .romanizationAssets) ?? []
        } else {
            let format = try values.decode(Format.self, forKey: .format)
            let original = try values.decode(String.self, forKey: .original)
            primary = LyricsAsset(format: format, text: original, language: language)
            let translation = try values.decodeIfPresent(String.self, forKey: .translation) ?? ""
            let romanization = try values.decodeIfPresent(String.self, forKey: .romanization) ?? ""
            translationAssets = translation.isEmpty ? [] : [LyricsAsset(format: LyricsFormatDetector.detect(translation, hint: .lrc), text: translation, language: language)]
            romanizationAssets = romanization.isEmpty ? [] : [LyricsAsset(format: LyricsFormatDetector.detect(romanization, hint: .lrc), text: romanization, language: language)]
        }
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(primary, forKey: .primary)
        try values.encode(translationAssets, forKey: .translationAssets)
        try values.encode(romanizationAssets, forKey: .romanizationAssets)
        try values.encode(language, forKey: .language)
        try values.encode(selectionReason, forKey: .selectionReason)
        try values.encodeIfPresent(degradationReason, forKey: .degradationReason)
        try values.encode(isInstrumental, forKey: .isInstrumental)
    }
}

@available(*, deprecated, renamed: "LyricsAssetBundle")
typealias LyricsPayload = LyricsAssetBundle

enum LyricsError: Error, LocalizedError, Equatable, Sendable {
    case notFound, malformed, tooLarge, transport, credentials, bearer, account, permission, cache
    case http(Int)
    var errorDescription: String? {
        let key: String
        switch self {
        case .notFound: key = "lyrics.error.notFound"
        case .malformed: key = "lyrics.error.malformed"
        case .tooLarge: key = "lyrics.error.tooLarge"
        case .transport: key = "lyrics.error.transport"
        case .credentials: key = "lyrics.error.credentials"
        case .bearer: key = "lyrics.error.bearer"
        case .account: key = "lyrics.error.account"
        case .permission: key = "lyrics.error.permission"
        case .cache: key = "lyrics.error.cache"
        case let .http(code): return "HTTP \(code)"
        }
        return NSLocalizedString(key, comment: "")
    }
}

@MainActor
protocol LyricsProvider {
    var source: LyricsSource { get }
    func search(track: TrackIdentity, query: String, settings: LyricsSettings) async throws -> [LyricCandidate]
    func lyrics(candidate: LyricCandidate, settings: LyricsSettings) async throws -> LyricsAssetBundle
}

enum LyricsMatcher {
    static func normalized(_ text: String) -> String {
        String(String.UnicodeScalarView(text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }))
    }

    static func similarity(_ lhs: String, _ rhs: String) -> Double {
        let a = Array(normalized(lhs).prefix(256)), b = Array(normalized(rhs).prefix(256))
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        if a == b {
            return 1
        }
        var row = Array(0 ... b.count)
        for (i, x) in a.enumerated() {
            var next = [i + 1] + Array(repeating: 0, count: b.count)
            for (j, y) in b.enumerated() {
                next[j + 1] = min(next[j] + 1, row[j + 1] + 1, row[j] + (x == y ? 0 : 1))
            }
            row = next
        }
        return 1 - Double(row[b.count]) / Double(max(a.count, b.count))
    }

    static func scored(_ candidate: LyricCandidate, against track: TrackIdentity) -> LyricCandidate {
        var result = candidate
        if let isrc = track.isrc, !isrc.isEmpty, isrc.uppercased() == candidate.isrc?.uppercased() {
            result.score = 100; result.evidence = ["ISRC"]; return result
        }
        let title = similarity(track.title, candidate.title)
        let artist = track.artists.flatMap { a in candidate.artists.map { similarity(a, $0) } }.max() ?? 0
        let album = similarity(track.album, candidate.album)
        let delta = abs(track.duration - candidate.duration)
        let duration: Double = candidate.duration > 0 && track.duration > 0 ? (delta <= 1.5 ? 15 : delta <= 4 ? 9 : delta <= 8 ? 3 : -15) : 0
        result.score = max(0, min(100, Int((title * 55 + artist * 30 + album * 5 + duration).rounded())))
        result.evidence = ["title=\(Int(title * 100))%", "artist=\(Int(artist * 100))%", "album=\(Int(album * 100))%", "durationΔ=\(Int(delta))s"]
        return result
    }
}
