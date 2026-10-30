import Foundation

/// Verified motion from LyricsBlossom's LineRenderState path. See the adoption
/// table in Docs/Lyrics-Animation-Styles.md; its 100/160ms button curves are excluded.
struct LyricsAnimationMotion: Sendable {
    var style: LyricsAnimationStyle
    var options: LyricsBlossomAnimationOptions? = nil

    // FUN_14030c9a0: stack template decoded from 1434dd9c0/1434dd330.
    private static let blossomLine = AMLLSpringParameters(mass: 1, damping: 18, stiffness: 100)

    var mainScale: AMLLSpringParameters {
        style == .appleMusic164 ? Self.blossomLine : .scale
    }

    var backgroundScale: AMLLSpringParameters {
        style == .appleMusic164 ? Self.blossomLine : .backgroundScale
    }

    func mainScale(focused: Bool) -> AMLLSpringParameters {
        // k=30,c=9 belongs to emphasis; it is not a selected-row scale preset.
        return mainScale
    }

    func vertical(lineInterval: TimeInterval?, gap: TimeInterval? = nil, seeking: Bool, interlude: Bool) -> AMLLSpringParameters {
        guard style == .appleMusic164 else {
            return AMLLMotionMetrics.verticalSpring(lineInterval: lineInterval, seeking: seeking, interlude: interlude)
        }
        // The gap uses source start minus previous source end, before advance
        // or offsets. Missing context keeps the constructor's fixed template.
        guard let gap, gap.isFinite, !seeking, !interlude else { return Self.blossomLine }
        return Self.adaptiveSpring(duration: gap)
    }

    static func adaptiveSpring(duration: Double) -> AMLLSpringParameters {
        let d = (min(0.75, max(0.2, duration)) - 0.2) / 0.55
        let response = 0.48 + 0.27 * d
        let dampingRatio = 0.90 - 0.12 * d
        let omega = 2 * Double.pi / response
        return .init(mass: 1, damping: 2 * dampingRatio * omega, stiffness: omega * omega)
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

/// The decoded light-up template drives focus opacity independently of scale.
/// Existing SDR endpoints remain app policy; no unknown style slots are used.
struct LyricsBlossomFocusAlpha: Sendable {
    private var bright = LyricsBlossomSpring(1)
    private var dark = LyricsBlossomSpring(0.2)
    var arrived: Bool { bright.arrived && dark.arrived }
    var value: (bright: Double, dark: Double) {
        (min(1, max(0, bright.position)), min(1, max(0, dark.position)))
    }

    mutating func resume(bright: Double, dark: Double) {
        self.bright.resume(position: bright, velocity: 0, target: bright)
        self.dark.resume(position: dark, velocity: 0, target: dark)
    }

    mutating func update(focused: Bool, delta: Double, force: Bool) {
        let brightTarget = focused ? 1.0 : 0.2, darkTarget = focused ? 0.4 : 0.2
        if force {
            resume(bright: brightTarget, dark: darkTarget)
        } else {
            if bright.target != brightTarget {
                bright.resume(position: bright.position, velocity: bright.velocity, target: brightTarget)
                dark.resume(position: dark.position, velocity: dark.velocity, target: darkTarget)
            }
            bright.update(delta); dark.update(delta)
        }
    }
}
