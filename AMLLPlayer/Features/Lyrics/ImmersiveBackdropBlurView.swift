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

    static func topFeatherAlpha(at y: CGFloat, profile: ImmersiveBackgroundBlurProfile,
                                topFeatherLength: CGFloat = ImmersiveArtworkPreset.topFeatherLength,
                                opacity: CGFloat = 1,
                                clearThroughY: CGFloat = 0,
                                includeRadiusRamp: Bool = false) -> CGFloat {
        if clearThroughY > 0, y < clearThroughY {
            return 0
        }
        let clampedOpacity = opacity.isFinite ? min(1, max(0, opacity)) : 1
        let base: CGFloat
        if includeRadiusRamp {
            base = alpha(at: y, profile: profile, topFeatherLength: topFeatherLength, clearThroughY: clearThroughY)
        } else {
            base = min(1, max(0, profile.topFeatherOpacity(at: y, length: topFeatherLength)))
        }
        return min(1, max(0, base * clampedOpacity))
    }

    static func make(profile: ImmersiveBackgroundBlurProfile,
                     topFeatherLength: CGFloat = ImmersiveArtworkPreset.topFeatherLength,
                     clearThroughY: CGFloat = 0,
                     sampleCount: Int = 256) -> CGImage? {
        makeVerticalAlphaImage(sampleCount: sampleCount) { row in
            let y = profile.frame.minY + (CGFloat(row) + 0.5) / CGFloat(sampleCount) * profile.frame.height
            return alpha(at: y, profile: profile, topFeatherLength: topFeatherLength, clearThroughY: clearThroughY)
        }
    }

    static func makeTopFeatherMask(profile: ImmersiveBackgroundBlurProfile,
                                   topFeatherLength: CGFloat = ImmersiveArtworkPreset.topFeatherLength,
                                   opacity: CGFloat = 1,
                                   clearThroughY: CGFloat = 0,
                                   includeRadiusRamp: Bool = false,
                                   sampleCount: Int = 256) -> CGImage? {
        guard profile.frame.width > 0, profile.frame.height > 0, sampleCount > 0 else { return nil }
        let clampedOpacity = opacity.isFinite ? min(1, max(0, opacity)) : 1
        let hasStatusBarCutoff = clearThroughY > 0 && clearThroughY > profile.frame.minY
        let hasTopFeather = profile.effectiveTopFeatherLength(topFeatherLength) > 0
        let hasRadiusTransition = includeRadiusRamp
            && min(profile.frame.maxY, max(profile.frame.minY, profile.fullStrengthY)) > profile.frame.minY
        let hasOpacityFade = clampedOpacity < 0.999
        guard hasStatusBarCutoff || hasTopFeather || hasRadiusTransition || hasOpacityFade else { return nil }
        return makeVerticalAlphaImage(sampleCount: sampleCount) { row in
            let y = profile.frame.minY + (CGFloat(row) + 0.5) / CGFloat(sampleCount) * profile.frame.height
            return topFeatherAlpha(
                at: y,
                profile: profile,
                topFeatherLength: topFeatherLength,
                opacity: clampedOpacity,
                clearThroughY: clearThroughY,
                includeRadiusRamp: includeRadiusRamp
            )
        }
    }

    private static func makeVerticalAlphaImage(sampleCount: Int, sample: (Int) -> CGFloat) -> CGImage? {
        guard sampleCount > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: sampleCount * 4)
        for row in 0 ..< sampleCount {
            let byte = UInt8(clamping: Int((sample(row) * 255).rounded()))
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
        let opacity: Int
        let clearThroughY: Int

        init(profile: ImmersiveBackgroundBlurProfile, topFeatherLength: CGFloat, opacity: CGFloat, clearThroughY: CGFloat) {
            minY = Int((profile.frame.minY * 2).rounded())
            height = Int((profile.frame.height * 2).rounded())
            fullStrengthY = Int((profile.fullStrengthY * 2).rounded())
            self.topFeatherLength = Int((topFeatherLength * 2).rounded())
            self.opacity = Int((opacity * 1000).rounded())
            self.clearThroughY = Int((clearThroughY * 2).rounded())
        }
    }

    private(set) var activeMode: Mode = .systemMaterialFallback
    private(set) var currentProfile: ImmersiveBackgroundBlurProfile?
    private(set) var currentMaskImage: CGImage?
    private(set) var currentFeatherMaskImage: CGImage?
    private var blurRadius: CGFloat = ImmersiveArtworkPreset.blurRadius
    private var topFeatherLength: CGFloat = ImmersiveArtworkPreset.topFeatherLength
    private var blendOpacity: CGFloat = 1
    private var clearThroughY: CGFloat = 0
    private var maskKey: MaskKey?
    private var appliedFilterRadius: CGFloat = -1
    private var activeFilter: NSObject?
    private var appliedFeatherIncludeRadiusRamp: Bool?
    private var reassertScheduled = false

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
        scheduleDeferredReassert()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if let mask, !bounds.isEmpty, mask.frame != bounds {
            mask.frame = bounds
        }
        applyBackdropFilter(forceReassert: true)
        scheduleDeferredReassert()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        applyBackdropFilter(forceReassert: true)
        scheduleDeferredReassert()
    }

    func configure(profile: ImmersiveBackgroundBlurProfile,
                   radius: CGFloat = ImmersiveArtworkPreset.blurRadius,
                   topFeatherLength: CGFloat = ImmersiveArtworkPreset.topFeatherLength,
                   opacity: Double = 1.0,
                   clearThroughY: CGFloat = 0,
                   hidden: Bool) {
        self.blurRadius = radius.isFinite ? max(0, radius) : 0
        self.topFeatherLength = topFeatherLength.isFinite ? max(0, topFeatherLength) : 0
        self.blendOpacity = opacity.isFinite ? min(1, max(0, CGFloat(opacity))) : 1
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
        currentFeatherMaskImage = nil
        blendOpacity = 1
        maskKey = nil
        appliedFilterRadius = -1
        activeFilter = nil
        appliedFeatherIncludeRadiusRamp = nil
        reassertScheduled = false
        mask = nil
        if let backdropLayer = findBackdropLayer(in: layer) {
            backdropLayer.filters = []
        }
    }

    /// Exposed for tests verifying backdrop lookup without hardcoded subview indices.
    var resolvedBackdropLayer: CALayer? {
        findBackdropLayer(in: layer)
    }

    private func scheduleDeferredReassert() {
        guard !isHidden, window != nil, currentProfile != nil, !reassertScheduled else { return }
        reassertScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.reassertScheduled = false
            self.applyBackdropFilter(forceReassert: false)
        }
    }

    private func applyBackdropFilter(forceReassert: Bool) {
        guard !isHidden, let profile = currentProfile else { return }
        let nextKey = MaskKey(
            profile: profile,
            topFeatherLength: topFeatherLength,
            opacity: blendOpacity,
            clearThroughY: clearThroughY
        )
        let maskChanged = nextKey != maskKey
        let radiusChanged = abs(appliedFilterRadius - blurRadius) > 0.01

        guard let backdropLayer = findBackdropLayer(in: layer) else {
            activeFilter = nil
            activeMode = .systemMaterialFallback
            applyTopFeatherMask(profile: profile, includeRadiusRamp: true, forceRebuild: maskChanged)
            maskKey = nextKey
            appliedFilterRadius = blurRadius
            return
        }

        let currentFilters = backdropLayer.filters as? [NSObject] ?? []
        let filtersDrifted = blurRadius > 0
            && (activeMode == .variableBlur || activeMode == .gaussianBlurFallback)
            && (activeFilter == nil || currentFilters.count != 1 || currentFilters.first !== activeFilter)
        let overlaysDrifted = hasVisibleSystemOverlay(keeping: backdropLayer)
        let maskNeedsSync = (mask != nil && !bounds.isEmpty && mask?.frame != bounds)
            || (currentFeatherMaskImage != nil && mask == nil)

        guard forceReassert || maskChanged || radiusChanged || filtersDrifted || overlaysDrifted || maskNeedsSync else {
            return
        }

        neutralizeSystemOverlays(keeping: backdropLayer)

        if blurRadius <= 0 {
            backdropLayer.filters = []
            activeFilter = nil
            mask = nil
            currentMaskImage = nil
            currentFeatherMaskImage = nil
            appliedFeatherIncludeRadiusRamp = nil
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

        if let maskImage = currentMaskImage,
           let filter = resolvedFilter(type: "variableBlur", targetMode: .variableBlur, rebuild: maskChanged || radiusChanged)
        {
            filter.setValue(blurRadius as NSNumber, forKey: "inputRadius")
            filter.setValue(maskImage, forKey: "inputMaskImage")
            filter.setValue(true as NSNumber, forKey: "inputNormalizeEdges")
            backdropLayer.filters = [filter]
            if backdropLayer.responds(to: NSSelectorFromString("setScale:")) {
                backdropLayer.setValue(1.0 as NSNumber, forKey: "scale")
            }
            activeFilter = filter
            activeMode = .variableBlur
            appliedFilterRadius = blurRadius
            applyTopFeatherMask(profile: profile, includeRadiusRamp: false, forceRebuild: maskChanged)
            return
        }

        if let filter = resolvedFilter(type: "gaussianBlur", targetMode: .gaussianBlurFallback, rebuild: radiusChanged) {
            filter.setValue(blurRadius as NSNumber, forKey: "inputRadius")
            filter.setValue(true as NSNumber, forKey: "inputNormalizeEdges")
            backdropLayer.filters = [filter]
            activeFilter = filter
            activeMode = .gaussianBlurFallback
            appliedFilterRadius = blurRadius
            applyTopFeatherMask(profile: profile, includeRadiusRamp: true, forceRebuild: maskChanged)
            return
        }

        activeFilter = nil
        activeMode = .systemMaterialFallback
        applyTopFeatherMask(profile: profile, includeRadiusRamp: true, forceRebuild: maskChanged)
        appliedFilterRadius = blurRadius
    }

    private func resolvedFilter(type: String, targetMode: Mode, rebuild: Bool) -> NSObject? {
        if !rebuild, activeMode == targetMode, let existing = activeFilter {
            return existing
        }
        return Self.makeCAFilter(type: type)
    }

    private func applyTopFeatherMask(profile: ImmersiveBackgroundBlurProfile,
                                     includeRadiusRamp: Bool,
                                     forceRebuild: Bool) {
        let shouldRebuild = forceRebuild
            || appliedFeatherIncludeRadiusRamp != includeRadiusRamp
            || (currentFeatherMaskImage == nil && mask != nil)
        if shouldRebuild {
            currentFeatherMaskImage = ImmersiveVariableBlurMask.makeTopFeatherMask(
                profile: profile,
                topFeatherLength: topFeatherLength,
                opacity: blendOpacity,
                clearThroughY: clearThroughY,
                includeRadiusRamp: includeRadiusRamp
            )
            appliedFeatherIncludeRadiusRamp = includeRadiusRamp
        }

        guard let featherImage = currentFeatherMaskImage else {
            mask = nil
            return
        }

        let targetBounds = bounds.isEmpty ? CGRect(origin: .zero, size: profile.frame.size) : bounds
        let imageView = (mask as? UIImageView) ?? UIImageView()
        if shouldRebuild || imageView.image == nil {
            imageView.image = UIImage(cgImage: featherImage)
        }
        imageView.contentMode = .scaleToFill
        imageView.backgroundColor = .clear
        imageView.isOpaque = false
        imageView.isUserInteractionEnabled = false
        imageView.frame = targetBounds
        // Reassign `mask` whenever the image changes so UIVisualEffectView updates its internal backdrop mask.
        if shouldRebuild || mask !== imageView {
            mask = imageView
        }
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

    private func hasVisibleSystemOverlay(keeping backdropLayer: CALayer) -> Bool {
        subviews.contains { subview in
            !Self.layerTree(subview.layer, contains: backdropLayer) && (!subview.isHidden || subview.alpha > 0)
        }
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
        guard AMLLBuildCapabilities.supportsPrivateVariableBlur,
              let filterClass: AnyClass = NSClassFromString("CAFilter") else { return nil }
        let selector = NSSelectorFromString("filterWithType:")
        guard let method = class_getClassMethod(filterClass, selector) else { return nil }
        typealias FilterFactory = @convention(c) (AnyClass, Selector, NSString) -> Unmanaged<NSObject>?
        let impl = unsafeBitCast(method_getImplementation(method), to: FilterFactory.self)
        return impl(filterClass, selector, type as NSString)?.takeUnretainedValue()
    }
}
