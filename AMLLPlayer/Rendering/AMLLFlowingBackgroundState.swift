import Foundation

struct FlowingBackgroundConfiguration: Codable, Equatable, Sendable {
    var rotationSpeed = 1.5 // Clockwise degrees per second.
    var distortion = 3.0 // Maximum combined displacement, percent of the short side.
    var blur = 40.0 // Gaussian sigma in viewport points.

    init(rotationSpeed: Double = 1.5, distortion: Double = 3, blur: Double = 40) {
        self.rotationSpeed = rotationSpeed
        self.distortion = distortion
        self.blur = blur
    }

    private enum CodingKeys: String, CodingKey { case rotationSpeed, distortion, blur }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        rotationSpeed = try values.decodeIfPresent(Double.self, forKey: .rotationSpeed) ?? 1.5
        distortion = try values.decodeIfPresent(Double.self, forKey: .distortion) ?? 3
        blur = try values.decodeIfPresent(Double.self, forKey: .blur) ?? 40
        self = validated()
    }

    func validated() -> Self {
        .init(rotationSpeed: rotationSpeed.isFinite ? min(6, max(0, rotationSpeed)) : 1.5,
              distortion: distortion.isFinite ? min(8, max(0, distortion)) : 3,
              blur: blur.isFinite ? min(80, max(0, blur)) : 40)
    }
}

/// Background time is independent of music time. Configuration and cover
/// changes preserve phase; callers advance only while the page is visible.
struct AMLLFlowingBackgroundState: Sendable {
    private(set) var configuration = FlowingBackgroundConfiguration()
    private(set) var angle = 0.0
    private(set) var phaseTime = 0.0
    private(set) var artworkProgress = 1.0
    private var distortionTransition = AMLLSourceTransition(3)
    private var blurTransition = AMLLSourceTransition(40)

    var distortion: Double { distortionTransition.value }
    var blur: Double { blurTransition.value }
    var phase18: Double { phaseTime * 2 * .pi / 18 }
    var phase27: Double { phaseTime * 2 * .pi / 27 }

    mutating func configure(_ value: FlowingBackgroundConfiguration, immediately: Bool = false) {
        configuration = value.validated()
        if immediately {
            distortionTransition.setPosition(configuration.distortion)
            blurTransition.setPosition(configuration.blur)
        } else {
            distortionTransition.setTarget(configuration.distortion, duration: 0.3)
            blurTransition.setTarget(configuration.blur, duration: 0.3)
        }
    }

    mutating func beginArtworkTransition(hasPrevious: Bool, immediately: Bool = false) {
        artworkProgress = hasPrevious && !immediately ? 0 : 1
    }

    mutating func advance(seconds: Double, running: Bool = true) {
        guard running, seconds.isFinite, seconds > 0 else { return }
        angle = (angle + seconds * configuration.rotationSpeed * .pi / 180).truncatingRemainder(dividingBy: 2 * .pi)
        // 54 seconds is the shared period of both waves. Avoid long-running
        // Float shader precision loss without restarting either wave.
        phaseTime = (phaseTime + seconds).truncatingRemainder(dividingBy: 54)
        distortionTransition.update(seconds)
        blurTransition.update(seconds)
        artworkProgress = min(1, artworkProgress + seconds)
    }

    /// The shortest image edge exceeds the viewport diagonal plus maximum
    /// warp displacement. Coverage remains safe through every rotation.
    static func coverExtent(width: Double, height: Double, imageAspect: Double) -> (width: Double, height: Double) {
        let side = hypot(width, height) + 0.16 * min(width, height)
        let aspect = imageAspect.isFinite && imageAspect > 0 ? imageAspect : 1
        return aspect >= 1 ? (side * aspect, side) : (side, side / aspect)
    }
}
