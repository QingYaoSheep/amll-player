import UIKit

struct AMLLPreparedBlurImages: @unchecked Sendable {
    let maximum: Double
    let near: UIImage
    let far: UIImage

    init(snapshot: AMLLCoreTextRasterSnapshot, scale: CGFloat, maximum: Double,
         hideRomanization: Bool = false, overlay: Bool = false) {
        self.maximum = maximum
        let romanization: Bool? = overlay ? true : (hideRomanization ? false : nil)
        let ruby: Bool? = overlay ? true : nil
        near = snapshot.raster(scale: min(scale, 1), ruby: ruby, romanization: romanization,
                               blurRadius: LyricsAnimationBlur.near(maximum))
        far = snapshot.raster(scale: min(scale, 1), ruby: ruby, romanization: romanization, blurRadius: maximum)
    }

    var estimatedBytes: Int { rasterBytes(near) + rasterBytes(far) }

    @MainActor func install(near nearLayer: CALayer, far farLayer: CALayer, size: CGSize) {
        for (layer, image) in [(nearLayer, near), (farLayer, far)] {
            // Offset the padded raster to retain the original text origin.
            layer.frame = CGRect(x: (size.width - image.size.width) / 2,
                                 y: (size.height - image.size.height) / 2,
                                 width: image.size.width, height: image.size.height)
            layer.contents = image.cgImage
            layer.contentsScale = image.scale
        }
    }
}

private func rasterBytes(_ image: UIImage) -> Int {
    image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
}

/// Immutable off-main raster output. The Core Text lines and dimensions come
/// from one layout snapshot; CALayer and UIView installation stays on main.
struct AMLLPreparedRowImages: @unchecked Sendable {
    let sharp: UIImage
    let ruby: UIImage
    let auxiliary: UIImage
    fileprivate(set) var blur: AMLLPreparedBlurImages?

    init(snapshot: AMLLCoreTextRasterSnapshot, scale: CGFloat, hideRomanization: Bool = false,
         blurMaximum: Double? = 5) {
        sharp = snapshot.raster(scale: scale, auxiliary: false, ruby: false)
        ruby = snapshot.raster(scale: scale, auxiliary: false, ruby: true,
                              romanization: hideRomanization ? false : nil)
        auxiliary = snapshot.raster(scale: scale, auxiliary: true, ruby: false)
        blur = blurMaximum.map { AMLLPreparedBlurImages(snapshot: snapshot, scale: scale, maximum: $0,
                                                        hideRomanization: hideRomanization) }
    }

    var sharpBytes: Int { rasterBytes(sharp) + rasterBytes(ruby) + rasterBytes(auxiliary) }
    var estimatedBytes: Int {
        sharpBytes + (blur?.estimatedBytes ?? 0)
    }
}

struct AMLLPreparedOverlayImages: @unchecked Sendable {
    let sharp: UIImage
    fileprivate(set) var blur: AMLLPreparedBlurImages?

    init(snapshot: AMLLCoreTextRasterSnapshot, scale: CGFloat, blurMaximum: Double? = 5) {
        sharp = snapshot.raster(scale: scale, auxiliary: false, ruby: true, romanization: true)
        blur = blurMaximum.map { AMLLPreparedBlurImages(snapshot: snapshot, scale: scale, maximum: $0, overlay: true) }
    }

    var sharpBytes: Int { rasterBytes(sharp) }
    var estimatedBytes: Int { sharpBytes + (blur?.estimatedBytes ?? 0) }
}

struct AMLLPreparedCompositeImages: @unchecked Sendable {
    private(set) var original: AMLLPreparedRowImages
    private(set) var romanization: AMLLPreparedRowImages?
    private(set) var overlay: AMLLPreparedOverlayImages?

    func matchingBlur(maximum: Double?) -> Self {
        var copy = self
        if original.blur?.maximum != maximum { copy.original.blur = nil }
        if romanization?.blur?.maximum != maximum { copy.romanization?.blur = nil }
        if overlay?.blur?.maximum != maximum { copy.overlay?.blur = nil }
        return copy
    }

    var estimatedBytes: Int {
        original.estimatedBytes + (romanization?.estimatedBytes ?? 0) + (overlay?.estimatedBytes ?? 0)
    }
}
