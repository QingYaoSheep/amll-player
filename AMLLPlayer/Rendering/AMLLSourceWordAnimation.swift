import Foundation

/// core@0.5.2 initEmphasizeAnimation. These are the source's 32 keyframes,
/// including matrix rounding, rather than continuous approximations of the curve.
enum AMLLSourceWordAnimation {
    struct Keyframe: Codable, Sendable {
        var offset: Double
        var scale: Double
        var x: Double
        var y: Double
        var glowRadius: Double
        var glowOpacity: Double
        var floatY: Double
    }

    struct CharacterAnimation: Sendable {
        var delay: Double
        var duration: Double
        var floatDelay: Double
        var floatDuration: Double
        var frames: [Keyframe]

        /// The source leaves offset 0 implicit (underlying identity), then uses
        /// linear interpolation between explicit frames. Distances are in em.
        func sample(lineTime: Double) -> AMLLWordPresentation {
            func interpolate(_ progress: Double, _ value: (Keyframe) -> Double, initial: Double) -> Double {
                let position = min(1, max(0, progress)) * 32
                let upper = min(31, Int(ceil(position)) - 1)
                guard upper >= 0 else { return initial }
                let lowerValue = upper == 0 ? initial : value(frames[upper - 1])
                let fraction = position - Double(upper)
                return lowerValue + (value(frames[upper]) - lowerValue) * fraction
            }
            let progress = (lineTime - delay) / duration
            let scale = interpolate(progress, { $0.scale }, initial: 1)
            let x = interpolate(progress, { $0.x }, initial: 0)
            let y = interpolate(progress, { $0.y }, initial: 0)
            let floating = interpolate((lineTime - floatDelay) / floatDuration, { $0.floatY }, initial: 0)
            // matrix3d(scale) translate(...) followed by an additive translateY.
            return .init(scale: scale, offsetX: x * scale, offsetY: (y + floating) * scale,
                         glowRadius: interpolate(progress, { $0.glowRadius }, initial: 0),
                         glowOpacity: interpolate(progress, { $0.glowOpacity }, initial: 0))
        }
    }

    /// Exact predicate used by `LyricLineBase.shouldEmphasize` in core 0.5.2.
    /// Short words stay on the ordinary float path; long notes and CJK words
    /// receive the per-character 32-frame emphasis animation.
    static func shouldEmphasize(_ word: LyricWord) -> Bool {
        let duration = word.end - word.start
        guard duration.isFinite, duration >= 1 else { return false }
        let trimmed = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if AMLLWordSegmentation.isCJK(trimmed) {
            return true
        }
        let count = trimmed.count
        return count > 1 && count <= 7
    }

    static func emphasis(duration: Double, delay: Double, characterCount: Int, rubyCount: Int = 0,
                         isLastWord: Bool, isBackground: Bool) -> [CharacterAnimation]
    {
        guard duration.isFinite, delay.isFinite, characterCount > 0 else { return [] }
        // Keep source arithmetic in milliseconds, convert only the returned timing.
        var du = max(1000, duration * 1000)
        let de = max(0, delay * 1000)
        let anchorCount = rubyCount > 0 ? rubyCount : max(1, characterCount)
        var amount = du / 2000
        amount = (amount > 1 ? sqrt(amount) : pow(amount, 3)) * 0.6
        var blur = du / 3000
        blur = (blur > 1 ? sqrt(blur) : pow(blur, 3)) * 0.5
        if isLastWord {
            amount *= 1.6; blur *= 1.5; du *= 1.2
        }
        amount = min(1.2, amount); blur = min(0.8, blur)
        return (0 ..< characterCount).map { index in
            let wordDelay = de + du / 2.5 / Double(anchorCount) * Double(index)
            let frames = (1 ... 32).map { step in
                let offset = Double(step) / 32
                let value = offset < 0.5
                    ? bezier(offset * 2, x1: 0.2, y1: 0.4, x2: 0.58, y2: 1)
                    : 1 - bezier((offset - 0.5) * 2, x1: 0.3, y1: 0, x2: 0.58, y2: 1)
                return Keyframe(offset: offset, scale: ((1 + value * 0.1 * amount) * 10000).rounded() / 10000,
                                x: -value * 0.03 * amount * (Double(characterCount) / 2 - Double(index)),
                                y: -value * 0.025 * amount, glowRadius: min(0.3, blur * 0.3),
                                glowOpacity: value * blur, floatY: -sin(offset * .pi) * (isBackground ? 2 : 1) * 0.05)
            }
            return CharacterAnimation(delay: wordDelay / 1000, duration: du / 1000,
                                      floatDelay: (wordDelay - 400) / 1000, floatDuration: du * 1.4 / 1000, frames: frames)
        }
    }

    static func wordFloat(elapsed: Double, duration: Double, isBackground: Bool) -> Double {
        -0.05 * (isBackground ? 2 : 1) * bezier(elapsed / max(1, duration), x1: 0, y1: 0, x2: 0.58, y2: 1)
    }

    private static func bezier(_ input: Double, x1: Double, y1: Double, x2: Double, y2: Double) -> Double {
        let x = min(1, max(0, input))
        func cubic(_ t: Double, _ a: Double, _ b: Double) -> Double {
            3 * (1 - t) * (1 - t) * t * a + 3 * (1 - t) * t * t * b + t * t * t
        }
        var low = 0.0, high = 1.0
        for _ in 0 ..< 40 {
            let t = (low + high) / 2
            if cubic(t, x1, x2) < x {
                low = t
            } else {
                high = t
            }
        }
        return cubic((low + high) / 2, y1, y2)
    }
}
