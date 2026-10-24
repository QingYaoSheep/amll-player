import Foundation

/// Verified motion from LyricsBlossom's LineRenderState path. See the adoption
/// table in Docs/Lyrics-Animation-Styles.md; its 100/160ms button curves are excluded.
struct LyricsAnimationMotion: Sendable {
    var style: LyricsAnimationStyle

    // FUN_140303510 installs these at LineRenderState +0x1f8 (y) and +0x370
    // (scale) in its fixed-parameter branch. FUN_1403014c0 consumes both, and
    // FUN_1403165c0 renders their y and scale outputs. No duration is inferred.
    private static let blossomLine = AMLLSpringParameters(mass: 1, damping: 18, stiffness: 100)

    var mainScale: AMLLSpringParameters {
        style == .appleMusic164 ? Self.blossomLine : .scale
    }

    func vertical(lineInterval: TimeInterval?, seeking: Bool, interlude: Bool) -> AMLLSpringParameters {
        style == .appleMusic164 ? Self.blossomLine
            : AMLLMotionMetrics.verticalSpring(lineInterval: lineInterval, seeking: seeking, interlude: interlude)
    }

    var initialVertical: AMLLSpringParameters {
        style == .appleMusic164 ? Self.blossomLine : .verticalDefault
    }
}

extension AMLLSpringParameters {
    var sourceParameters: AMLLSourceSpring.Parameters {
        .init(mass: mass, damping: damping, stiffness: stiffness)
    }
}
