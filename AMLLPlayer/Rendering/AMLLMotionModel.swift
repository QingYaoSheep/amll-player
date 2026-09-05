import Foundation

/// Constants and equations ported from @applemusic-like-lyrics/core 0.5.2.
/// Layout coordinates deliberately live elsewhere: the native shell follows the supplied Apple Music screenshots.
enum AMLLMotionMetrics {
    static let sourcePackage = "@applemusic-like-lyrics/core@0.5.2"
    static let wordFadeWidthInEms = 0.5
    static let inactiveScale = 0.97
    static let inactiveBackgroundScale = 0.75
    static let backgroundLineScale = 0.7
    static let backgroundLineOpacity = 0.4
    static let auxiliaryLineScale = 0.5
    static let auxiliaryLineOpacity = 0.3
    static let alignPosition = 0.35
    static let browseTimeout = 5.0

    static func verticalSpring(lineInterval: TimeInterval?, seeking: Bool, interlude: Bool) -> AMLLSpringParameters {
        guard !seeking, !interlude, let lineInterval else { return .verticalDefault }
        let interval = min(0.8, max(0.1, lineInterval))
        let ratio = pow(1 - (interval - 0.1) / 0.7, 0.2)
        let stiffness = 170 + ratio * 50
        return AMLLSpringParameters(mass: 0.9, damping: sqrt(stiffness) * 2.2, stiffness: stiffness)
    }

    static func shouldEmphasize(text: String, duration: TimeInterval) -> Bool {
        guard duration >= 1 else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed.unicodeScalars.contains(where: { scalar in
            (0x3400 ... 0x9FFF).contains(scalar.value) || (0x3040 ... 0x30FF).contains(scalar.value) ||
                (0xAC00 ... 0xD7AF).contains(scalar.value)
        }) {
            return true
        }
        return trimmed.count > 1 && trimmed.count <= 7
    }
}

struct AMLLSpringParameters: Equatable, Sendable {
    var mass: Double
    var damping: Double
    var stiffness: Double

    static let verticalDefault = Self(mass: 0.9, damping: 15, stiffness: 90)
    static let scale = Self(mass: 2, damping: 25, stiffness: 100)
    static let backgroundScale = Self(mass: 1, damping: 20, stiffness: 50)
}

/// Analytic spring matching AMLL's solver. Retargeting starts from the current value and velocity.
struct AMLLSpring: Equatable, Sendable {
    private(set) var value: Double
    private(set) var velocity = 0.0
    var parameters = AMLLSpringParameters.verticalDefault

    init(value: Double, velocity: Double = 0) {
        self.value = value
        self.velocity = velocity
    }

    mutating func set(value: Double) {
        self.value = value
        velocity = 0
    }

    mutating func step(target: Double, delta: TimeInterval, immediate: Bool = false) -> Double {
        guard value.isFinite, velocity.isFinite, target.isFinite else {
            set(value: target.isFinite ? target : 0)
            return value
        }
        if immediate {
            set(value: target)
            return value
        }
        let elapsed = min(0.05, max(0, delta))
        guard elapsed > 0 else { return value }
        let mass = max(0.000_1, parameters.mass)
        let stiffness = max(0.000_1, parameters.stiffness)
        let damping = max(0, parameters.damping)
        let deltaValue = target - value

        if damping / (2 * sqrt(stiffness * mass)) >= 1 {
            // AMLL intentionally uses its critically damped branch for over-damped parameters too.
            let angularFrequency = -sqrt(stiffness / mass)
            let leftover = -angularFrequency * deltaValue - velocity
            let decay = exp(elapsed * angularFrequency)
            let next = target - (deltaValue + elapsed * leftover) * decay
            let nextVelocity = -(leftover + angularFrequency * (deltaValue + elapsed * leftover)) * decay
            value = next
            velocity = nextVelocity
        } else {
            let dampingFrequency = sqrt(4 * mass * stiffness - damping * damping)
            let leftover = (damping * deltaValue - 2 * mass * velocity) / dampingFrequency
            let frequency = 0.5 * dampingFrequency / mass
            let decayRate = -0.5 * damping / mass
            let cosine = cos(elapsed * frequency)
            let sine = sin(elapsed * frequency)
            let amplitude = cosine * deltaValue + sine * leftover
            let amplitudeVelocity = -frequency * sine * deltaValue + frequency * cosine * leftover
            let decay = exp(elapsed * decayRate)
            value = target - amplitude * decay
            velocity = -(amplitudeVelocity + decayRate * amplitude) * decay
        }
        if abs(target - value) < 0.01, abs(velocity) < 0.01 {
            set(value: target)
        }
        return value
    }
}

struct AMLLInterludePresentation: Equatable, Sendable {
    var scale: Double
    var dotOpacities: [Double]
}

enum AMLLInterludeMotion {
    static func presentation(time: TimeInterval, start: TimeInterval, end: TimeInterval, playing: Bool) -> AMLLInterludePresentation? {
        _ = playing // AMLL freezes the last dot frame while paused instead of removing the interlude.
        guard time >= start, time <= end, end > start else { return nil }
        let duration = (end - start) * 1_000
        let current = (time - start) * 1_000
        let breatheDuration = duration / ceil(duration / 1_500)
        var scale = sin(1.5 * .pi - current / breatheDuration * 2) / 20 + 1
        var opacity = 1.0
        if current < 2_000 {
            scale *= easeOutExpo(current / 2_000)
        }
        if current < 500 {
            opacity = 0
        } else if current < 1_000 {
            opacity *= (current - 500) / 500
        }
        let remaining = duration - current
        if remaining < 750 {
            scale *= 1 - easeInOutBack((750 - remaining) / 750 / 2)
        }
        if remaining < 375 {
            opacity *= clamp(remaining / 375)
        }
        let dotsDuration = max(0.000_1, duration - 750)
        let raw = [current, current - dotsDuration / 3, current - dotsDuration * 2 / 3]
        let dots = raw.map { opacity * min(1, max(0.25, $0 * 3 / dotsDuration * 0.75)) }
        return AMLLInterludePresentation(scale: max(0, scale) * 0.7, dotOpacities: dots.map(clamp))
    }

    private static func easeOutExpo(_ value: Double) -> Double {
        value == 1 ? 1 : 1 - pow(2, -10 * value)
    }

    private static func easeInOutBack(_ value: Double) -> Double {
        let coefficient = 1.70158 * 1.525
        if value < 0.5 {
            return pow(2 * value, 2) * ((coefficient + 1) * 2 * value - coefficient) / 2
        }
        return (pow(2 * value - 2, 2) * ((coefficient + 1) * (value * 2 - 2) + coefficient) + 2) / 2
    }

    private static func clamp(_ value: Double) -> Double {
        min(1, max(0, value))
    }
}

enum LyricsMotionMode: Equatable, Sendable {
    case following
    case browsing
    case returning
    case seeking
    case dismissing
}

enum LyricsInteraction: Equatable, Sendable {
    case beginBrowsing
    case resumeFollowing
    case seek(to: TimeInterval)
    case beginDismissal
    case cancelDismissal
}

struct LyricsMotionModel: Equatable, Sendable {
    private(set) var mode = LyricsMotionMode.following
    private(set) var pendingSeek: TimeInterval?
    private(set) var interactionTime: TimeInterval = 0

    mutating func handle(_ interaction: LyricsInteraction, at time: TimeInterval) {
        interactionTime = time
        switch interaction {
        case .beginBrowsing:
            mode = .browsing
        case .resumeFollowing:
            mode = .returning
        case let .seek(position):
            pendingSeek = position
            mode = .seeking
        case .beginDismissal:
            mode = .dismissing
        case .cancelDismissal:
            mode = .following
        }
    }

    mutating func settledFollowing() {
        pendingSeek = nil
        mode = .following
    }

    mutating func resumeIfBrowseTimedOut(at time: TimeInterval) -> Bool {
        guard mode == .browsing, time - interactionTime >= AMLLMotionMetrics.browseTimeout else { return false }
        mode = .returning
        return true
    }
}

struct AMLLWordPresentation: Equatable, Sendable {
    var scale = 1.0
    var offsetX = 0.0
    var offsetY = 0.0
    var glowRadius = 0.0
    var glowOpacity = 0.0
}

enum AMLLWordMotion {
    static func presentation(time: TimeInterval, wordStart: TimeInterval, wordEnd: TimeInterval,
                             characterIndex: Int, characterCount: Int, text: String,
                             isLastWord: Bool, isBackground: Bool, enabled: Bool) -> AMLLWordPresentation
    {
        guard enabled else { return .init() }
        let sourceDuration = max(0, wordEnd - wordStart)
        guard AMLLMotionMetrics.shouldEmphasize(text: text, duration: sourceDuration) else {
            let duration = max(1, sourceDuration)
            let progress = min(1, max(0, (time - wordStart) / duration))
            let lift = -0.05 * (isBackground ? 2 : 1) * easeOut(progress)
            return AMLLWordPresentation(offsetY: lift)
        }

        var duration = sourceDuration
        var amount = duration / 2
        amount = amount > 1 ? sqrt(amount) : pow(amount, 3)
        var glow = duration / 3
        glow = glow > 1 ? sqrt(glow) : pow(glow, 3)
        amount *= 0.6
        glow *= 0.5
        if isLastWord {
            amount *= 1.6
            glow *= 1.5
            duration *= 1.2
        }
        amount = min(1.2, amount)
        glow = min(0.8, glow)
        let count = max(1, characterCount)
        let index = min(max(0, characterIndex), count - 1)
        let characterDelay = duration / 2.5 / Double(count) * Double(index)
        let emphasisProgress = min(1, max(0, (time - wordStart - characterDelay) / duration))
        let emphasis = emphasisEasing(emphasisProgress)
        let floatProgress = min(1, max(0, (time - wordStart - characterDelay + 0.4) / (duration * 1.4)))
        let float = sin(floatProgress * .pi) * (isBackground ? 2 : 1)
        return AMLLWordPresentation(
            scale: 1 + emphasis * 0.1 * amount,
            offsetX: -emphasis * 0.03 * amount * (Double(count) / 2 - Double(index)),
            offsetY: -emphasis * 0.025 * amount - float * 0.05,
            glowRadius: min(0.3, glow * 0.3),
            glowOpacity: emphasis * glow
        )
    }

    private static func emphasisEasing(_ value: Double) -> Double {
        if value < 0.5 {
            return cubicBezier(value * 2, x1: 0.2, y1: 0.4, x2: 0.58, y2: 1)
        }
        return 1 - cubicBezier((value - 0.5) * 2, x1: 0.3, y1: 0, x2: 0.58, y2: 1)
    }

    private static func easeOut(_ value: Double) -> Double {
        cubicBezier(value, x1: 0, y1: 0, x2: 0.58, y2: 1)
    }

    /// Solves CSS cubic-bezier y for a normalized x.
    private static func cubicBezier(_ x: Double, x1: Double, y1: Double, x2: Double, y2: Double) -> Double {
        let target = min(1, max(0, x))
        var parameter = target
        for _ in 0 ..< 8 {
            let current = bezier(parameter, x1, x2) - target
            let derivative = bezierDerivative(parameter, x1, x2)
            if abs(derivative) < 0.000_001 { break }
            parameter = min(1, max(0, parameter - current / derivative))
        }
        return bezier(parameter, y1, y2)
    }

    private static func bezier(_ t: Double, _ point1: Double, _ point2: Double) -> Double {
        let inverse = 1 - t
        return 3 * inverse * inverse * t * point1 + 3 * inverse * t * t * point2 + t * t * t
    }

    private static func bezierDerivative(_ t: Double, _ point1: Double, _ point2: Double) -> Double {
        3 * pow(1 - t, 2) * point1 + 6 * (1 - t) * t * (point2 - point1) + 3 * t * t * (1 - point2)
    }
}
