import CoreImage
import UIKit

enum LyricsAuxiliaryBlurSource: @unchecked Sendable {
    case coreText(AMLLCoreTextRasterSnapshot, hideRomanization: Bool)
    case raster(CGImage, scale: CGFloat, regions: [LyricsAuxiliaryKind: [CGRect]])

    var kinds: Set<LyricsAuxiliaryKind> {
        switch self {
        case let .coreText(snapshot, _): snapshot.auxiliaryKinds
        case let .raster(_, _, regions): Set(regions.filter { !$0.value.isEmpty }.keys)
        }
    }
}

struct LyricsAuxiliaryBlurParts: @unchecked Sendable {
    let body: AMLLPreparedBlurImages
    let auxiliary: [LyricsAuxiliaryKind: AMLLPreparedBlurImages]
    var estimatedBytes: Int { body.estimatedBytes + auxiliary.values.reduce(0) { $0 + $1.estimatedBytes } }
}

struct LyricsAuxiliaryBlurStarter {
    let parts: LyricsAuxiliaryBlurParts
    let size: CGSize
    let origin: CGPoint
    let alphas: [LyricsAuxiliaryKind: Double]
}

/// Re-rasterize only on a visibility change, then let Core Animation dissolve
/// the two textures. Identical primary glyph pixels are never opacity-masked.
actor LyricsAuxiliaryBlurDecoder {
    static let shared = LyricsAuxiliaryBlurDecoder()
    private let context = CIContext(options: [.cacheIntermediates: false])

    func split(_ source: LyricsAuxiliaryBlurSource, maximum: Double) -> LyricsAuxiliaryBlurParts? {
        guard !Task.isCancelled else { return nil }
        func part(_ kind: LyricsAuxiliaryKind?) -> AMLLPreparedBlurImages? {
            switch source {
            case let .coreText(snapshot, hideRomanization):
                return decode(.coreText(snapshot.onlyAuxiliary(kind), hideRomanization: hideRomanization), hidden: [], maximum: maximum)
            case let .raster(image, scale, regions):
                if kind == nil { return decode(source, hidden: Set(regions.keys), maximum: maximum) }
                let size = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
                let format = UIGraphicsImageRendererFormat(); format.scale = scale; format.opaque = false
                let isolated = UIGraphicsImageRenderer(size: size, format: format).image { renderer in
                    let path = CGMutablePath()
                    for rect in regions[kind!] ?? [] { path.addRect(rect) }
                    renderer.cgContext.addPath(path); renderer.cgContext.clip()
                    UIImage(cgImage: image, scale: scale, orientation: .up).draw(at: .zero)
                }
                guard let cg = isolated.cgImage else { return nil }
                return decode(.raster(cg, scale: scale, regions: [:]), hidden: [], maximum: maximum)
            }
        }
        guard let body = part(nil) else { return nil }
        var auxiliary: [LyricsAuxiliaryKind: AMLLPreparedBlurImages] = [:]
        for kind in source.kinds {
            guard !Task.isCancelled, let image = part(kind) else { return nil }
            auxiliary[kind] = image
        }
        return .init(body: body, auxiliary: auxiliary)
    }

    func decode(_ source: LyricsAuxiliaryBlurSource, hidden: Set<LyricsAuxiliaryKind>, maximum: Double) -> AMLLPreparedBlurImages? {
        guard !Task.isCancelled else { return nil }
        switch source {
        case let .coreText(snapshot, hideRomanization):
            return AMLLPreparedBlurImages(snapshot: snapshot.hidingAuxiliary(hidden), scale: 1,
                maximum: maximum, hideRomanization: hideRomanization)
        case let .raster(image, scale, regions):
            let size = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
            let format = UIGraphicsImageRendererFormat(); format.scale = scale; format.opaque = false
            let filtered = UIGraphicsImageRenderer(size: size, format: format).image { renderer in
                UIImage(cgImage: image, scale: scale, orientation: .up).draw(at: .zero)
                for kind in hidden { for rect in regions[kind] ?? [] { renderer.cgContext.clear(rect) } }
            }
            guard !Task.isCancelled, let cg = filtered.cgImage else { return nil }
            let input = CIImage(cgImage: cg)
            func blur(_ radius: Double) -> UIImage? {
                guard let output = context.createCGImage(input.clampedToExtent()
                    .applyingFilter("CIGaussianBlur", parameters: ["inputRadius": radius * scale]), from: input.extent) else { return nil }
                return UIImage(cgImage: output, scale: scale, orientation: .up)
            }
            guard let near = blur(2), !Task.isCancelled, let far = blur(maximum) else { return nil }
            return AMLLPreparedBlurImages(maximum: maximum, near: near, far: far)
        }
    }
}

/// Separate blurred contributions keep their own alpha/deadline. Whole-row
/// refreshes are held until separated planes are ready, so incoming or late
/// texture work cannot publish fully visible annotations during a fade.
@MainActor final class LyricsAuxiliaryBlurPresentation {
    private let near: CALayer
    private let far: CALayer
    private var normal: AMLLPreparedBlurImages?
    private var source: LyricsAuxiliaryBlurSource?
    private var sourceKinds = Set<LyricsAuxiliaryKind>()
    private var lastFadeRevision = -1
    private var size = CGSize.zero
    private weak var fade: LyricsAuxiliaryFade?
    private var task: Task<Void, Never>?
    private var generation = 0
    private var parts: LyricsAuxiliaryBlurParts?
    private var partsSize: CGSize?
    private var partsOrigin: CGPoint?
    private var children: [LyricsAuxiliaryKind: [CALayer]] = [:]
    private var starts: [LyricsAuxiliaryKind: Double] = [:]
    private var initialAlphas: [LyricsAuxiliaryKind: Double] = [:]
    private var normalPublished = false
    var didInstall: (Double, Int) -> Void = { _, _ in }
    var decode: (@MainActor (LyricsAuxiliaryBlurSource, Double) async -> LyricsAuxiliaryBlurParts?)?
    var isSeparated: Bool { parts != nil }
    var isPreparing: Bool { task != nil }

    init(near: CALayer, far: CALayer) { self.near = near; self.far = far }
    deinit { task?.cancel() }

    func snapshot(origin: CGPoint) -> LyricsAuxiliaryBlurStarter? {
        guard let body = parts?.body ?? normal else { return nil }
        let captured = parts ?? .init(body: body, auxiliary: [:])
        var alphas = initialAlphas
        if normalPublished { for kind in source?.kinds ?? [] { alphas[kind] = 1 } }
        for (kind, layers) in children {
            if let layer = layers.first { alphas[kind] = Double(layer.presentation()?.opacity ?? layer.opacity) }
        }
        return .init(parts: captured, size: partsSize ?? size, origin: partsOrigin ?? origin, alphas: alphas)
    }

    func showStarter(_ starter: LyricsAuxiliaryBlurStarter, origin: CGPoint) {
        removeChildren(); parts = starter.parts
        lastFadeRevision = -1
        partsSize = starter.size; partsOrigin = starter.origin
        initialAlphas = Dictionary(uniqueKeysWithValues: LyricsAuxiliaryKind.allCases.map { ($0, starter.alphas[$0] ?? 0) })
        starter.parts.body.install(near: near, far: far, size: starter.size, animated: false)
        let delta = CGPoint(x: origin.x - starter.origin.x, y: origin.y - starter.origin.y)
        near.frame = near.frame.offsetBy(dx: delta.x, dy: delta.y)
        far.frame = far.frame.offsetBy(dx: delta.x, dy: delta.y)
        for (kind, images) in starter.parts.auxiliary {
            children[kind] = [(near, images.near), (far, images.far)].map { parent, image -> CALayer in
                let child = CALayer(); child.frame = parent.bounds; child.contents = image.cgImage; child.contentsScale = image.scale
                child.name = "auxiliaryBlur." + String(describing: kind)
                child.opacity = Float(initialAlphas[kind] ?? 0); parent.addSublayer(child)
                return child
            }
        }
        didInstall(starter.parts.body.maximum, starter.parts.estimatedBytes)
    }

    func reset() {
        task?.cancel(); task = nil; generation &+= 1
        removeChildren(); normal = nil; source = nil; sourceKinds.removeAll(); lastFadeRevision = -1
        normalPublished = false; initialAlphas.removeAll()
        near.contents = nil; far.contents = nil
    }

    func install(_ images: AMLLPreparedBlurImages, source: LyricsAuxiliaryBlurSource, size: CGSize, fade: LyricsAuxiliaryFade?) {
        normal = images; self.source = source; self.size = size; self.fade = fade
        sourceKinds = source.kinds; lastFadeRevision = -1
        if let fade, parts == nil {
            initialAlphas = Dictionary(uniqueKeysWithValues: source.kinds.map { ($0, normalPublished ? 1 : fade.value($0)) })
        }
        task?.cancel(); generation &+= 1
        if let fade, !source.kinds.isEmpty, fade.isAnimating || !source.kinds.isDisjoint(with: fade.hiddenKinds) { prepare() }
        else { restore(animated: true) }
    }

    func update(_ fade: LyricsAuxiliaryFade) {
        guard lastFadeRevision != fade.revision else { return }
        lastFadeRevision = fade.revision
        self.fade = fade
        if parts != nil {
            applyVisibility(fade)
            if !fade.isAnimating, sourceKinds.isDisjoint(with: fade.hiddenKinds) { restore(animated: false) }
        } else if task == nil, !sourceKinds.isEmpty,
                  fade.isAnimating || !sourceKinds.isDisjoint(with: fade.hiddenKinds) { prepare() }
    }

    private func prepare() {
        guard let source, let normal else { return }
        let ticket = generation, maximum = normal.maximum
        let decode = decode
        task = Task { [weak self] in
            let result: LyricsAuxiliaryBlurParts?
            if let decode { result = await decode(source, maximum) }
            else { result = await LyricsAuxiliaryBlurDecoder.shared.split(source, maximum: maximum) }
            guard !Task.isCancelled, let self, self.generation == ticket, let result, let fade = self.fade else { return }
            self.task = nil
            CATransaction.begin(); CATransaction.setDisableActions(true)
            let replacing = self.parts != nil
            var initial = self.initialAlphas
            for (kind, layers) in self.children {
                if let layer = layers.first { initial[kind] = Double(layer.presentation()?.opacity ?? layer.opacity) }
            }
            self.removeChildren(); self.parts = result; self.partsSize = self.size
            result.body.install(near: self.near, far: self.far, size: self.size, animated: replacing)
            for (kind, images) in result.auxiliary {
                let pair = [(self.near, images.near), (self.far, images.far)].map { parent, image -> CALayer in
                    let layer = CALayer(); layer.frame = parent.bounds
                    layer.name = "auxiliaryBlur." + String(describing: kind)
                    layer.contents = image.cgImage; layer.contentsScale = image.scale
                    parent.addSublayer(layer)
                    return layer
                }
                self.children[kind] = pair
            }
            self.applyVisibility(fade, initial: initial)
            self.lastFadeRevision = -1
            CATransaction.commit()
            self.didInstall(maximum, result.estimatedBytes + normal.estimatedBytes)
        }
    }

    private func applyVisibility(_ fade: LyricsAuxiliaryFade, initial: [LyricsAuxiliaryKind: Double]? = nil) {
        let now = CACurrentMediaTime()
        for (kind, layers) in children where starts[kind] != fade.start(kind) {
            starts[kind] = fade.start(kind)
            for layer in layers {
                let current = initial?[kind].map(Float.init) ?? layer.presentation()?.opacity ?? Float(fade.value(kind, now: now))
                layer.opacity = Float(fade.target(kind))
                layer.removeAnimation(forKey: "auxiliaryVisibility")
                let duration = fade.deadline(kind) - now
                if duration > 0 {
                    let animation = CABasicAnimation(keyPath: "opacity")
                    animation.fromValue = current; animation.toValue = layer.opacity
                    animation.duration = duration; animation.timingFunction = LyricsPageMotion.contentTimingFunction
                    layer.add(animation, forKey: "auxiliaryVisibility")
                }
            }
        }
    }

    private func removeChildren() {
        children.values.flatMap { $0 }.forEach { $0.removeFromSuperlayer() }
        children.removeAll(); starts.removeAll(); parts = nil; partsSize = nil; partsOrigin = nil
    }

    private func restore(animated: Bool) {
        guard let normal else { return }
        task?.cancel(); task = nil; generation &+= 1
        removeChildren()
        normal.install(near: near, far: far, size: size, animated: animated)
        normalPublished = true
        didInstall(normal.maximum, normal.estimatedBytes)
    }
}
