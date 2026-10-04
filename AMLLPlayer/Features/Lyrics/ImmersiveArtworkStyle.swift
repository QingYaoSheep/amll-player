import CoreGraphics
import Foundation
import Observation

struct ImmersiveArtworkStyle: Codable, Equatable, Sendable {
    var blurStartOffset = -96.0
    var blurLength = 144.0
    var blurRadius = 32.0
    var reflectionLength = 1.0
    var reflectionOpacity = 1.0
    var videoFadeEnabled = true

    func validated() -> Self {
        var result = self
        func bound(_ value: Double, _ fallback: Double, _ range: ClosedRange<Double>) -> Double {
            value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : fallback
        }
        result.blurStartOffset = bound(blurStartOffset, -96, -320 ... 160)
        result.blurLength = bound(blurLength, 144, 16 ... 400)
        result.blurRadius = bound(blurRadius, 32, 0 ... 80)
        result.reflectionLength = bound(reflectionLength, 1, 0.1 ... 1)
        result.reflectionOpacity = bound(reflectionOpacity, 1, 0 ... 1)
        return result
    }

    /// Exactly the legacy CAGradientLayer's stops and linear interpolation.
    func videoAlpha(at fraction: Double) -> Double {
        guard videoFadeEnabled else { return 1 }
        let stops = AMLLImmersiveArtworkGeometry.videoFadeStops
        for index in 1 ..< stops.count where fraction <= stops[index].location {
            let a = stops[index - 1], b = stops[index]
            let t = min(1, max(0, (fraction - a.location) / (b.location - a.location)))
            return a.alpha + (b.alpha - a.alpha) * t
        }
        return 0
    }
}

extension ImmersiveArtworkStyle {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        blurStartOffset = try c.decodeIfPresent(Double.self, forKey: .blurStartOffset) ?? -96
        blurLength = try c.decodeIfPresent(Double.self, forKey: .blurLength) ?? 144
        blurRadius = try c.decodeIfPresent(Double.self, forKey: .blurRadius) ?? 32
        reflectionLength = try c.decodeIfPresent(Double.self, forKey: .reflectionLength) ?? 1
        reflectionOpacity = try c.decodeIfPresent(Double.self, forKey: .reflectionOpacity) ?? 1
        videoFadeEnabled = try c.decodeIfPresent(Bool.self, forKey: .videoFadeEnabled) ?? true
        self = validated()
    }
}

@MainActor @Observable
final class ImmersiveArtworkStyleStore {
    static let shared = ImmersiveArtworkStyleStore()
    private static let key = "AMLL.immersiveArtworkStyle.v2"
    var style: ImmersiveArtworkStyle {
        didSet {
            if let data = try? JSONEncoder().encode(style.validated()) {
                UserDefaults.standard.set(data, forKey: Self.key)
            }
        }
    }
    private init() {
        style = UserDefaults.standard.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode(ImmersiveArtworkStyle.self, from: $0) }?.validated() ?? .init()
    }
    func reset() { style = .init() }
    var exported: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(style.validated())).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }
}

struct ImmersivePlayerLayoutMetrics: Equatable, Sendable {
    var metadataTop: CGFloat
    var progressCenter: CGFloat
    var transportCenter: CGFloat
    var volumeCenter: CGFloat
    var actionsCenter: CGFloat
    var inset: CGFloat
    var needsScrolling: Bool

    static func make(viewport: CGSize, bottomInset: CGFloat, contentScale: CGFloat = 1) -> Self {
        let scale = max(1, contentScale)
        let actions = viewport.height - max(0, bottomInset) - 27
        let spacingScale = min(1, max(0.65, (viewport.height - bottomInset - 120) / 720))
        let gap = spacingScale * scale
        let volume = actions - 57 * gap
        let transport = volume - 90 * gap
        let progress = transport - 92 * gap
        let metadata = progress - 77 * gap
        return .init(metadataTop: metadata, progressCenter: progress, transportCenter: transport,
                     volumeCenter: volume, actionsCenter: actions,
                     inset: max(20, min(40, viewport.width * 32 / 402)),
                     needsScrolling: metadata < 160 || scale > 1.4)
    }

    func blurProfile(style: ImmersiveArtworkStyle, viewport: CGSize) -> ImmersiveBackgroundBlurProfile {
        let style = style.validated()
        let top = min(viewport.height, max(0, metadataTop + style.blurStartOffset))
        return .init(frame: CGRect(x: 0, y: top, width: viewport.width, height: max(1, viewport.height - top)),
                     fullStrengthY: min(viewport.height, top + style.blurLength))
    }
}
