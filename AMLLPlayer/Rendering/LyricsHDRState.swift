import Foundation

/// Brightness is relative to linear SDR white, independently of word glow.
struct LyricsHDRConfiguration: Codable, Equatable, Sendable {
    var enabled = false
    static let targetBrightness = 1.5
}

struct LyricsHDRCapabilities: Equatable, Sendable {
    var supportsEDR: Bool
    var headroom: Double

    func outputBrightness(configuration: LyricsHDRConfiguration, reduceTransparency: Bool) -> Double {
        guard configuration.enabled, supportsEDR, !reduceTransparency,
              headroom.isFinite, headroom > 1 else { return 1 }
        return min(LyricsHDRConfiguration.targetBrightness, headroom)
    }
}

/// Stateless sampling deliberately uses the actual lyric time, never the
/// visually advanced focus. Re-evaluating a paused time or seek cannot retain
/// the previous sentence's HDR eligibility.
struct LyricsHDRFrameState: Equatable, Sendable {
    var activeLineIndexes: Set<Int>
    var outputBrightness: Double

    static func sample(lines: [LyricLine], lyricTime: Double,
                       configuration: LyricsHDRConfiguration,
                       capabilities: LyricsHDRCapabilities,
                       reduceTransparency: Bool = false) -> Self
    {
        let active = lyricTime.isFinite ? Set(lines.indices.filter {
            let line = lines[$0]
            return line.start.isFinite && line.end.isFinite && line.end > line.start
                && lyricTime >= line.start && lyricTime < line.end
        }) : []
        return .init(activeLineIndexes: active, outputBrightness: capabilities.outputBrightness(
            configuration: configuration, reduceTransparency: reduceTransparency
        ))
    }

    /// The renderer supplies shaped widths and the same clock/feather used by
    /// the SDR mask. This is spatial coverage, not average character timing.
    func coverage(lineIndex: Int, time: Double, wordIndex: Int?,
                  words: [AMLLWordMask.Word], x: Double, fragmentAdvance: Double,
                  feather: Double) -> Double
    {
        guard activeLineIndexes.contains(lineIndex) else { return 0 }
        guard !words.isEmpty else { return 1 } // True line-timed lyrics.
        guard let wordIndex, words.indices.contains(wordIndex), time.isFinite,
              x.isFinite, fragmentAdvance.isFinite, feather.isFinite else { return 0 }
        let width = max(0.0001, feather)
        let edge = AMLLWordMask.edge(time: time, index: wordIndex, words: words, feather: max(0, feather))
        return min(1, max(0, (edge + width - fragmentAdvance - x) / width))
    }
}
