import CoreImage
import ImageIO
import UIKit

/// Reuses one opaque, blurred still at the logical canvas size. The cover and
/// backdrop are shared by every sample until the artwork URL changes.
@MainActor
final class DesktopLyricsBackground {
    private let size: CGSize
    private var url: URL?
    private var loading: Task<Void, Never>?
    private var image: UIImage?
    private(set) var artwork: UIImage?
    private(set) var revision = 0

    init(size: CGSize) {
        self.size = size
    }

    deinit { loading?.cancel() }

    func update(artworkURL: URL?) {
        guard artworkURL != url else { return }
        url = artworkURL
        loading?.cancel()
        loading = nil
        artwork = nil
        image = nil
        revision &+= 1
        guard let artworkURL else { return }
        let size = self.size
        loading = Task { [weak self] in
            guard let data = try? await ArtworkImageData.load(artworkURL), !Task.isCancelled,
                  let result = await DesktopLyricsArtworkWorker.shared.makeBackdrop(from: data, size: size),
                  let self, !Task.isCancelled, url == artworkURL else { return }
            artwork = UIImage(cgImage: result.artwork)
            image = UIImage(cgImage: result.blurred)
            revision &+= 1
            loading = nil
        }
    }

    func draw(in bounds: CGRect) {
        if let image {
            image.draw(in: bounds, blendMode: .copy, alpha: 1)
        } else {
            UIColor(white: 0.065, alpha: 1).setFill()
            UIRectFill(bounds)
        }
    }

    nonisolated static func aspectFill(_ source: CGSize, in destination: CGRect) -> CGRect {
        guard source.width > 0, source.height > 0 else { return destination }
        let scale = max(destination.width / source.width, destination.height / source.height)
        let width = source.width * scale
        let height = source.height * scale
        return CGRect(x: destination.midX - width / 2, y: destination.midY - height / 2, width: width, height: height)
    }
}

private actor DesktopLyricsArtworkWorker {
    static let shared = DesktopLyricsArtworkWorker()

    struct Images: @unchecked Sendable {
        // Immutable CGImages can cross from the raster worker to UIKit.
        let artwork: CGImage
        let blurred: CGImage
    }

    private let context = CIContext(options: [.useSoftwareRenderer: true, .cacheIntermediates: false])

    func makeBackdrop(from data: Data, size: CGSize) -> Images? {
        guard !Task.isCancelled, size.width > 0, size.height > 0,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let artwork = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: Int(max(size.width, size.height) * 2),
                  kCGImageSourceShouldCacheImmediately: true,
              ] as CFDictionary), !Task.isCancelled else { return nil }
        let bounds = CGRect(origin: .zero, size: size)
        let cover = CIImage(cgImage: artwork)
        let frame = DesktopLyricsBackground.aspectFill(cover.extent.size, in: bounds)
        let scale = frame.width / cover.extent.width
        let fitted = cover.transformed(by: .init(scaleX: scale, y: scale))
            .transformed(by: .init(translationX: frame.minX, y: frame.minY))
        let base = CIImage(color: .init(red: 0.065, green: 0.065, blue: 0.065, alpha: 1)).cropped(to: bounds)
        let blurred = fitted.composited(over: base).cropped(to: bounds).clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: size.width * 0.075])
            .cropped(to: bounds)
        let scrim = CIImage(color: .init(red: 0, green: 0, blue: 0, alpha: 0.24)).cropped(to: bounds)
        guard let output = context.createCGImage(scrim.composited(over: blurred), from: bounds) else { return nil }
        return .init(artwork: artwork, blurred: output)
    }
}
