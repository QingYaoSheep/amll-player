import UIKit

/// Immutable off-main raster output. The Core Text lines and dimensions come
/// from one layout snapshot; CALayer and UIView installation stays on main.
struct AMLLPreparedRowImages: @unchecked Sendable {
    let sharp: UIImage
    let ruby: UIImage
    let auxiliary: UIImage
    let nearBlur: UIImage
    let farBlur: UIImage

    init(snapshot: AMLLCoreTextRasterSnapshot, scale: CGFloat, hideRomanization: Bool = false) {
        sharp = snapshot.raster(scale: scale, auxiliary: false, ruby: false)
        ruby = snapshot.raster(scale: scale, auxiliary: false, ruby: true,
                              romanization: hideRomanization ? false : nil)
        auxiliary = snapshot.raster(scale: scale, auxiliary: true, ruby: false)
        nearBlur = snapshot.raster(scale: min(scale, 1), romanization: hideRomanization ? false : nil,
                                   blurRadius: 2)
        farBlur = snapshot.raster(scale: min(scale, 1), romanization: hideRomanization ? false : nil,
                                  blurRadius: 5)
    }

    var estimatedBytes: Int {
        func bytes(_ image: UIImage) -> Int { image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0 }
        return bytes(sharp) + bytes(ruby) + bytes(auxiliary) + bytes(nearBlur) + bytes(farBlur)
    }
}

struct AMLLPreparedOverlayImages: @unchecked Sendable {
    let sharp: UIImage
    let nearBlur: UIImage
    let farBlur: UIImage

    init(snapshot: AMLLCoreTextRasterSnapshot, scale: CGFloat) {
        sharp = snapshot.raster(scale: scale, auxiliary: false, ruby: true, romanization: true)
        nearBlur = snapshot.raster(scale: min(scale, 1), ruby: true, romanization: true, blurRadius: 2)
        farBlur = snapshot.raster(scale: min(scale, 1), ruby: true, romanization: true, blurRadius: 5)
    }

    var estimatedBytes: Int {
        func bytes(_ image: UIImage) -> Int { image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0 }
        return bytes(sharp) + bytes(nearBlur) + bytes(farBlur)
    }
}

struct AMLLPreparedCompositeImages: @unchecked Sendable {
    let original: AMLLPreparedRowImages
    let romanization: AMLLPreparedRowImages?
    let overlay: AMLLPreparedOverlayImages?

    var estimatedBytes: Int {
        original.estimatedBytes + (romanization?.estimatedBytes ?? 0) + (overlay?.estimatedBytes ?? 0)
    }
}
