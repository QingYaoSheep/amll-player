import Foundation
import Observation

enum LyricsPresentationProfile: String, Codable, CaseIterable, Sendable {
    /// The native AMLL page and motion engine. It is kept selectable until
    /// reference-device sign-off promotes it to the production default.
    case amll
    case appleMusic26
    case custom
}

/// The seven responsive font presets exposed by AMLL's react-full player.
/// Values are evaluated in points (CSS px == pt in the reference harness).
enum AMLLLyricSizePreset: String, Codable, CaseIterable, Sendable {
    case tiny
    case extraSmall = "extra-small"
    case small
    case medium
    case large
    case extraLarge = "extra-large"
    case huge

    func pointSize(width: Double, height: Double) -> Double {
        let widthTerm: Double
        let heightTerm: Double
        let minimum: Double
        switch self {
        case .tiny:
            heightTerm = 0.025; widthTerm = 0.0125; minimum = 10
        case .extraSmall:
            heightTerm = 0.03; widthTerm = 0.015; minimum = 10
        case .small:
            heightTerm = 0.04; widthTerm = 0.02; minimum = 12
        case .medium:
            heightTerm = 0.05; widthTerm = 0.025; minimum = 14
        case .large:
            heightTerm = 0.06; widthTerm = 0.03; minimum = 16
        case .extraLarge:
            heightTerm = 0.07; widthTerm = 0.035; minimum = 18
        case .huge:
            heightTerm = 0.08; widthTerm = 0.04; minimum = 20
        }
        return max(minimum, max(max(0, height) * heightTerm, max(0, width) * widthTerm))
    }
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
    /// `nil` retains the explicit point-size setting used by the old native
    /// renderer. AMLL profiles can opt into one of the responsive presets;
    /// keeping this optional makes v1/v2 settings and hand-authored fixtures
    /// decode without changing their geometry.
    var sizePreset: AMLLLyricSizePreset? = nil
    var bold = true
    var tracking: Double = 0
    var blurInactive = true
    var emphasizeWords = true
    var enableSpring = true
    var enableScale = true
    var hidePassedLines = false
    var alwaysPostpositionBackground = false
    /// AMLL stores the feather width as an em value; 0.5 tracks the rendered font size.
    var gradientWidth: Double = AMLLMotionMetrics.wordFadeWidthInEms
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

    /// AMLL's source player chooses the medium responsive preset by default;
    /// the explicit point size remains as a compatibility fallback for the
    /// legacy renderer and hand-authored fixtures.
    static var amllDefault: Self {
        var value = Self()
        value.sizePreset = .medium
        return value
    }

    func auxiliaryText(for line: LyricLine) -> [String] {
        let translationText = translation ? line.translation : ""
        let wordRomanization = line.words.compactMap(\.romanWord).joined(separator: " ")
        let hasTimedRuby = line.words.contains { !$0.rubySegments.isEmpty }
        let rubyText = hasTimedRuby ? "" : line.words.compactMap(\.ruby).joined(separator: " ")
        let romanizationText = romanization
            ? (line.romanization.isEmpty ? (wordRomanization.isEmpty ? rubyText : wordRomanization) : line.romanization)
            : ""
        return (romanizationFirst ? [romanizationText, translationText] : [translationText, romanizationText])
            .filter { !$0.isEmpty }
    }

    func resolvedFontSize(width: Double, height: Double) -> Double {
        let base = sizePreset?.pointSize(width: width, height: height) ?? fontSize
        return base.isFinite ? max(10, base) : 32
    }

    func validated() -> Self {
        var copy = self
        copy.fontSize = fontSize.isFinite ? min(52, max(24, fontSize)) : 32
        copy.tracking = tracking.isFinite ? min(3, max(-1, tracking)) : 0
        copy.gradientWidth = gradientWidth.isFinite
            ? min(1, max(0, gradientWidth)) : AMLLMotionMetrics.wordFadeWidthInEms
        copy.anchor = anchor.isFinite ? min(0.7, max(0.2, anchor)) : 0.35
        copy.advance = advance.isFinite ? min(1, max(0, advance)) : 0.3
        copy.backgroundBlur = backgroundBlur.isFinite ? min(80, max(0, backgroundBlur)) : 40
        return copy
    }
}

@MainActor @Observable
final class LyricsRenderPreferences {
    var profile: LyricsPresentationProfile {
        didSet {
            if !switchingProfile {
                persist()
            }
        }
    }

    var configuration: LyricsRenderConfiguration {
        didSet {
            guard !switchingProfile else { return }
            if profile == .custom {
                migratedCustomConfiguration = configuration.validated()
            }
            persist()
        }
    }

    private(set) var migratedCustomConfiguration: LyricsRenderConfiguration?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var switchingProfile = false
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
            if stored.profile == .appleMusic26 || stored.profile == .amll {
                let baseline = stored.profile == .amll ? LyricsRenderConfiguration.amllDefault : .init()
                configuration = baseline
                migratedCustomConfiguration = stored.migratedCustomConfiguration?.validated()
                    ?? (stored.configuration == baseline ? nil : stored.configuration.validated())
            } else {
                configuration = stored.configuration.validated()
                migratedCustomConfiguration = configuration
            }
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
           var decoded = try? JSONDecoder().decode(LyricsRenderConfiguration.self, from: mergedData)
        {
            // The replacement plan intentionally activates the new Apple Music layout for every upgrade.
            // Preserve the old values as an opt-in custom-layout backup without applying them automatically.
            if values["gradientWidth"] != nil {
                decoded.gradientWidth /= max(1, decoded.fontSize)
            }
            migratedCustomConfiguration = decoded.validated()
            profile = .appleMusic26
            configuration = .init()
            persist()
        }
    }

    func activate(_ newProfile: LyricsPresentationProfile) {
        guard newProfile != profile else { return }
        if profile == .custom {
            migratedCustomConfiguration = configuration.validated()
        }
        switchingProfile = true
        profile = newProfile
        configuration = switch newProfile {
        case .amll: .amllDefault
        case .appleMusic26: .init()
        case .custom: migratedCustomConfiguration ?? .init()
        }
        switchingProfile = false
        persist()
    }

    func restoreAMLLDefaults() {
        switchingProfile = true
        profile = .amll
        configuration = .amllDefault
        switchingProfile = false
        persist()
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
