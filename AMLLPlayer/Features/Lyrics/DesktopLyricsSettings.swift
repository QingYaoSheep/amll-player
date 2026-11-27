import Foundation
import Observation

struct DesktopLyricsSettings: Codable, Equatable, Sendable {
    enum DisplayMode: String, CaseIterable, Codable, Sendable {
        case scrolling, singleLine

        var label: String { "desktopLyrics.mode." + rawValue }
    }

    enum Aspect: String, CaseIterable, Codable, Sendable {
        case wide, standard, tall, singleLine

        static let scrollingOptions: [Self] = [.wide, .standard, .tall]

        var label: String { "desktopLyrics.aspect." + rawValue }

        var ratio: Double {
            switch self {
            case .wide: 2
            case .standard: 16.0 / 9
            case .tall: 4.0 / 3
            case .singleLine: 2.5
            }
        }

        var canvasSize: CGSize { CGSize(width: 320, height: 320 / ratio) }

        var pixelSizes: [CGSize] {
            let widths: [Int]
            switch self {
            case .tall: widths = [960, 1104]
            case .singleLine: widths = [960, 1120, 1280]
            default: widths = [960, 1152, 1280]
            }
            return widths.map { CGSize(width: Double($0), height: (Double($0) / ratio).rounded()) }
        }

        func outputSize(for renderedPixels: CGSize) -> CGSize {
            let requiredWidth = min(renderedPixels.width, renderedPixels.height * ratio)
            let sizes = pixelSizes
            return sizes.first { $0.width >= requiredWidth } ?? sizes.last!
        }
    }

    enum Alignment: String, CaseIterable, Codable, Sendable {
        case reading, centered

        var label: String { "desktopLyrics.alignment." + rawValue }
    }

    enum Transition: String, CaseIterable, Codable, Sendable {
        case blur, fade, instant

        var label: String { "desktopLyrics.transition." + rawValue }
    }

    static let fontRange = 16.0 ... 36.0
    static let blurRange = 0.0 ... 5.0

    var fontSize = 22.0
    var blurStrength = 1.0
    var wordHighlight = true
    var plusLighter = true
    var aspect: Aspect = .standard
    var transition: Transition = .blur
    var mode: DisplayMode = .scrolling
    var singleLineTranslation = true
    var singleLineRomanization = true
    var fitsContent = false
    var alignment: Alignment = .reading

    var outputAspect: Aspect { mode == .singleLine ? .singleLine : aspect }

    var fitsSingleLine: Bool { mode == .singleLine && fitsContent }

    func blendsAdditively(reduceTransparency: Bool) -> Bool {
        plusLighter && !reduceTransparency
    }

    func validated() -> Self {
        var value = self
        let defaults = Self()
        if value.aspect == .singleLine { value.aspect = defaults.aspect }
        value.fontSize = fontSize.isFinite ? min(Self.fontRange.upperBound, max(Self.fontRange.lowerBound, fontSize.rounded())) : defaults.fontSize
        value.blurStrength = blurStrength.isFinite
            ? min(Self.blurRange.upperBound, max(Self.blurRange.lowerBound, (blurStrength * 2).rounded() / 2))
            : defaults.blurStrength
        return value
    }

    func rendererConfiguration(_ source: LyricsRenderConfiguration) -> LyricsRenderConfiguration {
        var configuration = source.validated()
        configuration.sizePreset = nil
        configuration.fontSize = fontSize
        configuration.horizontalPadding = 16
        configuration.anchor = 0.29
        configuration.tabletTypography = nil
        configuration.hdr = nil
        if mode == .singleLine {
            configuration.blurInactive = false
            configuration.translation = singleLineTranslation
            configuration.romanization = singleLineRomanization
        }
        return configuration
    }

    init() {}

    private enum CodingKeys: String, CodingKey {
        case fontSize, blurStrength, wordHighlight, aspect, transition, mode, singleLineTranslation, singleLineRomanization
        case fitsContent, alignment, plusLighter
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        fontSize = (try? values.decode(Double.self, forKey: .fontSize)) ?? fontSize
        blurStrength = (try? values.decode(Double.self, forKey: .blurStrength)) ?? blurStrength
        wordHighlight = (try? values.decode(Bool.self, forKey: .wordHighlight)) ?? wordHighlight
        aspect = (try? values.decode(Aspect.self, forKey: .aspect)) ?? aspect
        transition = (try? values.decode(Transition.self, forKey: .transition)) ?? transition
        mode = (try? values.decode(DisplayMode.self, forKey: .mode)) ?? mode
        singleLineTranslation = (try? values.decode(Bool.self, forKey: .singleLineTranslation)) ?? singleLineTranslation
        singleLineRomanization = (try? values.decode(Bool.self, forKey: .singleLineRomanization)) ?? singleLineRomanization
        fitsContent = (try? values.decode(Bool.self, forKey: .fitsContent)) ?? fitsContent
        alignment = (try? values.decode(Alignment.self, forKey: .alignment)) ?? alignment
        plusLighter = (try? values.decode(Bool.self, forKey: .plusLighter)) ?? plusLighter
        self = validated()
    }
}

@MainActor
@Observable
final class DesktopLyricsPreferences {
    private static let key = "desktopLyrics.appearance"
    @ObservationIgnored private let defaults: UserDefaults
    var settings: DesktopLyricsSettings {
        didSet {
            let value = settings.validated()
            if value != settings { settings = value }
            if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: Self.key) }
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        settings = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(DesktopLyricsSettings.self, from: $0) } ?? .init()
    }
}
