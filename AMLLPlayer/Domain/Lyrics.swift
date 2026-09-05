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

struct LyricWord: Codable, Equatable, Sendable {
    var text: String
    var start: Double
    var end: Double
    var romanWord: String? = nil
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
    static let parserVersion = 1
    var candidate: LyricCandidate
    var lines: [LyricLine]
    var language: String
    var selectionReason: String
    var isInstrumental = false
    var lyricAuthor: String? = nil
    var songwriters: [String] = []
    var precision: LyricsPrecision {
        lines.contains { $0.precision == .word } ? .word : .line
    }
}

struct LyricsPayload: Codable, Equatable, Sendable {
    enum Format: String, Codable, Sendable { case ttml, lrc }
    var format: Format
    var original: String
    var translation = ""
    var romanization = ""
    var language = ""
    var selectionReason = ""
    var isInstrumental = false

    func parse(candidate: LyricCandidate, duration: Double) throws -> LyricsDocument {
        let lines: [LyricLine]
        if isInstrumental {
            lines = []
        } else {
            switch format {
            case .ttml: lines = try TTMLLyricsParser.parse(original, preferredLanguage: language, duration: duration)
            case .lrc: lines = try LRCLyricsParser.parse(original, translation: translation, romanization: romanization, duration: duration)
            }
            guard !lines.isEmpty else { throw LyricsError.notFound }
        }
        return LyricsDocument(candidate: candidate, lines: lines, language: language,
                              selectionReason: selectionReason, isInstrumental: isInstrumental)
    }
}

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
    func lyrics(candidate: LyricCandidate, settings: LyricsSettings) async throws -> LyricsPayload
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
