import Foundation
import Observation

enum LyricsPresentationProfile: String, Codable, CaseIterable, Sendable {
    case appleMusic26
    case custom
}

struct LyricsRenderConfiguration: Codable, Equatable, Sendable {
    enum CoverLayout: String, Codable, CaseIterable { case automatic, normal, immersive }
    enum Credits: String, Codable, CaseIterable {
        case hidden, lyricAuthor, songwriters, preferLyricAuthor, preferSongwriters

        func content(in document: LyricsDocument) -> LyricsCreditContent? {
            let authors = [document.lyricAuthor].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            let writers = document.songwriters.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            let author: LyricsCreditContent? = authors.isEmpty ? nil : .init(kind: .lyricAuthor, names: authors)
            let writer: LyricsCreditContent? = writers.isEmpty ? nil : .init(kind: .songwriters, names: writers)
            switch self {
            case .hidden: return nil
            case .lyricAuthor: return author
            case .songwriters: return writer
            case .preferLyricAuthor: return author ?? writer
            case .preferSongwriters: return writer ?? author
            }
        }
    }

    var translation = true
    var romanization = true
    var romanizationFirst = false
    var fontSize: Double = 32
    var bold = true
    var tracking: Double = 0
    var blurInactive = true
    var emphasizeWords = true
    /// AMLL default: half of the main lyric font size (16 pt at the default 32 pt font).
    var gradientWidth: Double = 16
    var anchor: Double = 0.35
    var advance: Double = 0.3
    var showLyrics = true
    var coverLayout: CoverLayout = .automatic
    var showTitle = true
    var showArtist = true
    var showAlbum = false
    var showVolume = true
    var showControls = true
    var credits: Credits = .preferLyricAuthor
    var marquee = true
    var remainingTime = false
    var backgroundBlur: Double = 40

    func auxiliaryText(for line: LyricLine) -> [String] {
        let translationText = translation ? line.translation : ""
        let romanizationText = romanization ? line.romanization : ""
        return (romanizationFirst ? [romanizationText, translationText] : [translationText, romanizationText])
            .filter { !$0.isEmpty }
    }

    func validated() -> Self {
        var copy = self
        copy.fontSize = fontSize.isFinite ? min(52, max(24, fontSize)) : 32
        copy.tracking = tracking.isFinite ? min(3, max(-1, tracking)) : 0
        copy.gradientWidth = gradientWidth.isFinite ? min(32, max(0, gradientWidth)) : 16
        copy.anchor = anchor.isFinite ? min(0.7, max(0.2, anchor)) : 0.35
        copy.advance = advance.isFinite ? min(1, max(0, advance)) : 0.3
        copy.backgroundBlur = backgroundBlur.isFinite ? min(80, max(0, backgroundBlur)) : 40
        return copy
    }
}

@MainActor @Observable
final class LyricsRenderPreferences {
    var profile: LyricsPresentationProfile {
        didSet { persist() }
    }
    var configuration: LyricsRenderConfiguration {
        didSet { persist() }
    }
    private(set) var migratedCustomConfiguration: LyricsRenderConfiguration?

    @ObservationIgnored private let defaults: UserDefaults
    private static let key = "lyrics.render.v2"
    private static let legacyKey = "lyrics.render.v1"
    private struct Stored: Codable {
        var version: Int
        var profile: LyricsPresentationProfile
        var configuration: LyricsRenderConfiguration
        var migratedCustomConfiguration: LyricsRenderConfiguration?
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        profile = .appleMusic26
        configuration = .init()
        if let data = defaults.data(forKey: Self.key),
           let stored = try? JSONDecoder().decode(Stored.self, from: data), stored.version == 2
        {
            profile = stored.profile
            configuration = stored.configuration.validated()
            migratedCustomConfiguration = stored.migratedCustomConfiguration?.validated()
            return
        }
        guard let data = defaults.data(forKey: Self.legacyKey),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        // Fill newly added fields from defaults; retain settings written by the interrupted Plan 5 build.
        let values: [String: Any]
        if let version = object["version"] as? Int {
            guard version == 1, let stored = object["configuration"] as? [String: Any] else { return }
            values = stored
        } else {
            values = object
        }
        guard let baseline = try? JSONEncoder().encode(LyricsRenderConfiguration()),
              var merged = try? JSONSerialization.jsonObject(with: baseline) as? [String: Any] else { return }
        merged.merge(values) { _, saved in saved }
        if let mode = merged["credits"] as? String, ["visible", "preferred"].contains(mode) {
            merged["credits"] = LyricsRenderConfiguration.Credits.preferLyricAuthor.rawValue
        }
        if let mergedData = try? JSONSerialization.data(withJSONObject: merged),
           let decoded = try? JSONDecoder().decode(LyricsRenderConfiguration.self, from: mergedData)
        {
            // The replacement plan intentionally activates the new Apple Music layout for every upgrade.
            // Preserve the old values as an opt-in custom-layout backup without applying them automatically.
            migratedCustomConfiguration = decoded.validated()
            profile = .appleMusic26
            configuration = .init()
            persist()
        }
    }

    func activate(_ newProfile: LyricsPresentationProfile) {
        if newProfile == .custom, let migratedCustomConfiguration {
            configuration = migratedCustomConfiguration
        }
        profile = newProfile
    }

    func restoreAMLLDefaults() {
        profile = .appleMusic26
        configuration = .init()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(Stored(version: 2, profile: profile,
                                                          configuration: configuration.validated(),
                                                          migratedCustomConfiguration: migratedCustomConfiguration)) else { return }
        defaults.set(data, forKey: Self.key)
    }
}

struct LyricsCreditContent: Equatable {
    enum Kind: String { case lyricAuthor, songwriters }
    var kind: Kind
    var names: [String]
}

struct RenderQualityPolicy: Equatable, Sendable {
    var frameRate: Int
    var blur: Bool
    var emphasis: Bool
    static func resolve(maximumFPS: Int, reduceMotion: Bool) -> Self {
        Self(frameRate: reduceMotion ? 60 : max(60, min(120, maximumFPS)),
             blur: !reduceMotion, emphasis: !reduceMotion)
    }
}

struct AccessibilityLyricsSnapshot: Equatable {
    var current: [String]
    var previous: String?
    var next: String?
    var canSeek: Bool
}

struct LyricsViewport: Equatable {
    var width: Double
    var height: Double
    var offset: Double
}

@MainActor
protocol LyricsRendering: AnyObject {
    func resumeFollowing()
    func stop()
}
