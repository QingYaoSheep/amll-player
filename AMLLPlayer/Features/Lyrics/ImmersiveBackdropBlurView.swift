import CoreGraphics
import Foundation
import ObjectiveC
import QuartzCore
import UIKit

/// Builds a compact 1×N RGBA8 alpha mask for `CAFilter("variableBlur")`.
/// Core Animation's variable blur reads the alpha channel (`inputMaskImage`),
/// so clear pixels produce 0 pt blur while opaque pixels receive the full radius.
enum ImmersiveVariableBlurMask {
    static func alpha(at y: CGFloat, profile: ImmersiveBackgroundBlurProfile,
                      topFeatherLength: CGFloat = ImmersiveArtworkPreset.topFeatherLength,
                      clearThroughY: CGFloat = 0) -> CGFloat {
        if clearThroughY > 0, y < clearThroughY {
            return 0
        }
        let radiusStrength = profile.strength(at: y)
        let feather = profile.topFeatherOpacity(at: y, length: topFeatherLength)
        return min(1, max(0, radiusStrength * feather))
    }

    static func make(profile: ImmersiveBackgroundBlurProfile,
                     topFeatherLength: CGFloat = ImmersiveArtworkPreset.topFeatherLength,
                     clearThroughY: CGFloat = 0,
                     sampleCount: Int = 256) -> CGImage? {
        guard profile.frame.width > 0, profile.frame.height > 0, sampleCount > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: sampleCount * 4)
        for row in 0 ..< sampleCount {
            let y = profile.frame.minY + (CGFloat(row) + 0.5) / CGFloat(sampleCount) * profile.frame.height
            let alphaValue = alpha(at: y, profile: profile, topFeatherLength: topFeatherLength,
                                   clearThroughY: clearThroughY)
            let byte = UInt8(clamping: Int((alphaValue * 255).rounded()))
            let offset = row * 4
            bytes[offset] = byte
            bytes[offset + 1] = byte
            bytes[offset + 2] = byte
            bytes[offset + 3] = byte
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(
            width: 1,
            height: sampleCount,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: 4,
            space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Big.rawValue
                | CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }
}

/// System WindowServer variable backdrop blur backed by UIVisualEffectView's
/// internal `CABackdropLayer`, eliminating per-frame CPU/CI/Metal readbacks.
@MainActor
final class ImmersiveBackdropBlurView: UIVisualEffectView {
    enum Mode: Equatable {
        case variableBlur
        case gaussianBlurFallback
        case systemMaterialFallback
    }

    private struct MaskKey: Equatable {
        let minY: Int
        let height: Int
        let fullStrengthY: Int
        let topFeatherLength: Int
        let clearThroughY: Int

        init(profile: ImmersiveBackgroundBlurProfile, topFeatherLength: CGFloat, clearThroughY: CGFloat) {
            minY = Int((profile.frame.minY * 2).rounded())
            height = Int((profile.frame.height * 2).rounded())
            fullStrengthY = Int((profile.fullStrengthY * 2).rounded())
            self.topFeatherLength = Int((topFeatherLength * 2).rounded())
            self.clearThroughY = Int((clearThroughY * 2).rounded())
        }
    }

    private(set) var activeMode: Mode = .systemMaterialFallback
    private(set) var currentProfile: ImmersiveBackgroundBlurProfile?
    private(set) var currentMaskImage: CGImage?
    private var blurRadius: CGFloat = ImmersiveArtworkPreset.blurRadius
    private var topFeatherLength: CGFloat = ImmersiveArtworkPreset.topFeatherLength
    private var clearThroughY: CGFloat = 0
    private var maskKey: MaskKey?
    private var appliedFilterRadius: CGFloat = -1

    init() {
        super.init(effect: UIBlurEffect(style: .regular))
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        backgroundColor = .clear
        isOpaque = false
        clipsToBounds = false
    }

    required init?(coder _: NSCoder) {
        nil
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        applyBackdropFilter(forceReassert: true)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        applyBackdropFilter(forceReassert: true)
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        applyBackdropFilter(forceReassert: true)
    }

    func configure(profile: ImmersiveBackgroundBlurProfile,
                   radius: CGFloat = ImmersiveArtworkPreset.blurRadius,
                   topFeatherLength: CGFloat = ImmersiveArtworkPreset.topFeatherLength,
                   clearThroughY: CGFloat = 0,
                   hidden: Bool) {
        self.blurRadius = radius.isFinite ? max(0, radius) : 0
        self.topFeatherLength = topFeatherLength.isFinite ? max(0, topFeatherLength) : 0
        self.clearThroughY = clearThroughY.isFinite ? max(0, clearThroughY) : 0
        currentProfile = profile
        isHidden = hidden
        alpha = 1
        if hidden {
            return
        }
        applyBackdropFilter(forceReassert: false)
    }

    func stop() {
        currentProfile = nil
        currentMaskImage = nil
        maskKey = nil
        appliedFilterRadius = -1
        mask = nil
        if let backdropLayer = findBackdropLayer(in: layer) {
            backdropLayer.filters = []
        }
    }

    /// Exposed for tests verifying backdrop lookup without hardcoded subview indices.
    var resolvedBackdropLayer: CALayer? {
        findBackdropLayer(in: layer)
    }

    private func applyBackdropFilter(forceReassert: Bool) {
        guard !isHidden, let profile = currentProfile else { return }
        let nextKey = MaskKey(profile: profile, topFeatherLength: topFeatherLength, clearThroughY: clearThroughY)
        let maskChanged = nextKey != maskKey
        let radiusChanged = abs(appliedFilterRadius - blurRadius) > 0.01
        guard forceReassert || maskChanged || radiusChanged else { return }

        guard let backdropLayer = findBackdropLayer(in: layer) else {
            activeMode = .systemMaterialFallback
            mask = makeFallbackMaskView(profile: profile)
            return
        }

        neutralizeSystemOverlays(keeping: backdropLayer)

        if blurRadius <= 0 {
            backdropLayer.filters = []
            mask = nil
            currentMaskImage = nil
            maskKey = nextKey
            appliedFilterRadius = 0
            return
        }

        if maskChanged || currentMaskImage == nil {
            currentMaskImage = ImmersiveVariableBlurMask.make(
                profile: profile,
                topFeatherLength: topFeatherLength,
                clearThroughY: clearThroughY
            )
            maskKey = nextKey
        }

        if let filter = Self.makeCAFilter(type: "variableBlur"), let maskImage = currentMaskImage {
            filter.setValue(blurRadius as NSNumber, forKey: "inputRadius")
            filter.setValue(maskImage, forKey: "inputMaskImage")
            filter.setValue(true as NSNumber, forKey: "inputNormalizeEdges")
            backdropLayer.filters = [filter]
            mask = nil
            activeMode = .variableBlur
            appliedFilterRadius = blurRadius
            return
        }

        if let filter = Self.makeCAFilter(type: "gaussianBlur") {
            filter.setValue(blurRadius as NSNumber, forKey: "inputRadius")
            filter.setValue(true as NSNumber, forKey: "inputNormalizeEdges")
            backdropLayer.filters = [filter]
            mask = makeFallbackMaskView(profile: profile)
            activeMode = .gaussianBlurFallback
            appliedFilterRadius = blurRadius
            return
        }

        activeMode = .systemMaterialFallback
        mask = makeFallbackMaskView(profile: profile)
        appliedFilterRadius = blurRadius
    }

    private func findBackdropLayer(in root: CALayer) -> CALayer? {
        if String(describing: type(of: root)).contains("BackdropLayer") {
            return root
        }
        for sublayer in root.sublayers ?? [] {
            if let found = findBackdropLayer(in: sublayer) {
                return found
            }
        }
        return nil
    }

    private func neutralizeSystemOverlays(keeping backdropLayer: CALayer) {
        for subview in subviews {
            let hostsBackdrop = Self.layerTree(subview.layer, contains: backdropLayer)
            subview.alpha = hostsBackdrop ? 1 : 0
            subview.isHidden = !hostsBackdrop
            subview.isUserInteractionEnabled = false
        }
    }

    private static func layerTree(_ root: CALayer, contains target: CALayer) -> Bool {
        if root === target { return true }
        return root.sublayers?.contains(where: { layerTree($0, contains: target) }) ?? false
    }

    private static func makeCAFilter(type: String) -> NSObject? {
        guard let filterClass: AnyClass = NSClassFromString("CAFilter") else { return nil }
        let selector = NSSelectorFromString("filterWithType:")
        guard let method = class_getClassMethod(filterClass, selector) else { return nil }
        typealias FilterFactory = @convention(c) (AnyClass, Selector, NSString) -> NSObject?
        let impl = unsafeBitCast(method_getImplementation(method), to: FilterFactory.self)
        return impl(filterClass, selector, type as NSString)
    }

    private func makeFallbackMaskView(profile: ImmersiveBackgroundBlurProfile) -> UIView? {
        guard profile.frame.width > 0, profile.frame.height > 0 else { return nil }
        let view = UIView(frame: CGRect(origin: .zero, size: profile.frame.size))
        view.isOpaque = false
        let gradient = CAGradientLayer()
        gradient.frame = view.bounds
        gradient.startPoint = CGPoint(x: 0.5, y: 0)
        gradient.endPoint = CGPoint(x: 0.5, y: 1)
        let steps = 32
        gradient.locations = (0 ... steps).map { NSNumber(value: Double($0) / Double(steps)) }
        gradient.colors = (0 ... steps).map { step in
            let y = profile.frame.minY + profile.frame.height * CGFloat(step) / CGFloat(steps)
            let alpha = ImmersiveVariableBlurMask.alpha(
                at: y,
                profile: profile,
                topFeatherLength: topFeatherLength,
                clearThroughY: clearThroughY
            )
            return UIColor(white: 1, alpha: alpha).cgColor
        }
        view.layer.addSublayer(gradient)
        return view
    }
}
