import Foundation

/// Native state for core@0.5.2 PixiRenderer.onTick. Pixi delta is measured in 60 Hz ticks.
struct AMLLPixiState {
    var time: Double = 0
    var alpha: Double = 0
    var rotations: [Double]

    mutating func advance(seconds: Double, speed: Double = 1) {
        let delta = seconds * 60
        alpha = min(1, alpha + delta / 60)
        time += delta * speed
        for (index, divisor) in [1000.0, -500, 1000, -750].enumerated() {
            rotations[index] += delta / divisor * speed
        }
    }

    func sprites(width: Double, height: Double) -> [SIMD4<Float>] {
        let maximum = max(width, height)
        let third = width / 4 * cos(time / 1000 * 0.75)
        // The source's fourth sprite adds a one-pixel cosine, not a scaled orbit.
        let fourth = width / 4 * 0.1 + cos(time * 0.006 * 0.75)
        let centers = [(width / 2, height / 2), (width / 2.5, height / 2.5),
                       (width / 2 + third, height / 2 + third), (width / 2 + fourth, height / 2 + fourth)]
        return zip(centers, [sqrt(2.0), 0.8, 0.5, 0.25]).enumerated().map { index, value in
            SIMD4(Float(value.0.0), Float(value.0.1), Float(maximum * value.1), Float(rotations[index]))
        }
    }

    static func blurPasses(minimumBorder: Double) -> [(strength: Float, quality: Int)] {
        var result: [(Float, Int)] = [(5, 1), (10, 1), (20, 2), (40, 2), (80, 2)]
        if minimumBorder > 768 {
            result.append((160, 4))
        }
        if minimumBorder > 1536 {
            result.append((320, 4))
        }
        return result
    }
}
