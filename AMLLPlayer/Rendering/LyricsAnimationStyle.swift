import Foundation

/// Names describe selectable presentation styles, not an Apple implementation source.
enum LyricsAnimationStyle: String, Codable, CaseIterable, Sendable {
    case amll
    case appleMusic164

    var title: String { self == .amll ? "AMLL" : "Apple Music 16.4" }

    init(from decoder: Decoder) throws {
        self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .amll
    }
}

/// Only motion choices belong to a style; typography, time offsets and HDR are shared.
struct LyricsAnimationOptions: Codable, Equatable, Sendable {
    var enableSpring = true
    var enableScale = true
    var blurInactive = true
    var emphasizeWords = true
    var hidePassedLines = false
    var marquee = true
    var gradientWidth = AMLLMotionMetrics.wordFadeWidthInEms
    var advance = 0.3

    init() {}

    init(_ configuration: LyricsRenderConfiguration) {
        enableSpring = configuration.enableSpring; enableScale = configuration.enableScale
        blurInactive = configuration.blurInactive; emphasizeWords = configuration.emphasizeWords
        hidePassedLines = configuration.hidePassedLines; marquee = configuration.marquee
        gradientWidth = configuration.gradientWidth; advance = configuration.advance
    }

    func validated() -> Self {
        var copy = self
        copy.gradientWidth = gradientWidth.isFinite ? min(1, max(0, gradientWidth)) : AMLLMotionMetrics.wordFadeWidthInEms
        copy.advance = advance.isFinite ? min(1, max(0, advance)) : 0.3
        return copy
    }

    func apply(to configuration: inout LyricsRenderConfiguration) {
        configuration.enableSpring = enableSpring; configuration.enableScale = enableScale
        configuration.blurInactive = blurInactive; configuration.emphasizeWords = emphasizeWords
        configuration.hidePassedLines = hidePassedLines; configuration.marquee = marquee
        configuration.gradientWidth = gradientWidth; configuration.advance = advance
    }
}

struct LyricsAnimationProfiles: Codable, Equatable, Sendable {
    var selected = LyricsAnimationStyle.amll
    var amll: LyricsAnimationOptions?
    var appleMusic164: LyricsAnimationOptions?

    subscript(_ style: LyricsAnimationStyle) -> LyricsAnimationOptions? {
        get { style == .amll ? amll : appleMusic164 }
        set {
            switch style {
            case .amll: amll = newValue
            case .appleMusic164: appleMusic164 = newValue
            }
        }
    }
}

extension LyricsRenderConfiguration {
    var animationStyle: LyricsAnimationStyle { animationProfiles?.selected ?? .amll }

    mutating func selectAnimationStyle(_ style: LyricsAnimationStyle) {
        guard style != animationStyle else { return }
        var profiles = animationProfiles ?? .init()
        let current = LyricsAnimationOptions(self).validated()
        profiles[profiles.selected] = current
        let next = profiles[style] ?? current
        profiles.selected = style
        profiles[style] = next
        next.apply(to: &self)
        animationProfiles = profiles
    }

    mutating func restoreCurrentAnimationDefaults() {
        let defaults = LyricsAnimationOptions()
        defaults.apply(to: &self)
        if var profiles = animationProfiles {
            profiles[profiles.selected] = defaults
            animationProfiles = profiles
        }
    }
}
