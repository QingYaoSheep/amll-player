import Foundation

/// react-full TextMarquee: 95% usable width, 32 points/s each way,
/// one outward and one returning iteration, without an invented repeat loop.
struct AMLLMarqueeMotion: Equatable {
    let distance: Double
    let legDuration: Double

    init(textWidth: Double, viewportWidth: Double) {
        guard textWidth.isFinite, viewportWidth.isFinite, viewportWidth > 0 else {
            distance = 0; legDuration = 0; return
        }
        distance = max(0, textWidth - viewportWidth * 0.95)
        legDuration = distance / 32
    }

    func offset(elapsed: Double) -> Double {
        guard elapsed.isFinite, elapsed > 0, legDuration > 0,
              elapsed < legDuration * 2 else { return 0 }
        return elapsed <= legDuration ? -elapsed * 32 : -(legDuration * 2 - elapsed) * 32
    }
}
