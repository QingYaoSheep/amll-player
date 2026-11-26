import CoreImage
import UIKit

/// Bakes a small, opaque artwork backdrop when its inputs change. Animated
/// background styles use a still composition so no Metal drawable or video
/// player is needed when the application is in the background.
@MainActor
final class DesktopLyricsBackground {
    private struct Style: Equatable {
        let mode: LyricsRenderConfiguration.BackgroundMode
        let start: LyricsRenderConfiguration.BackgroundColor
        let end: LyricsRenderConfiguration.BackgroundColor
        let blur: Double
        let immersive: Bool
        let dimming: Double
        let feather: Double
        let opaque: Bool
        let usesAlbumBackground: Bool
        let size: CGSize
    }

    private(set) var artwork: CGImage?
    private(set) var revision = 0
    private var style: Style?
    private var track: String?
    private var url: URL?
    private var loading: Task<Void, Never>?
    private var image: UIImage?
    private let ci = CIContext(options: [.useSoftwareRenderer: true, .cacheIntermediates: false])

    deinit { loading?.cancel() }

    func update(item: PlaybackItem, configuration: LyricsRenderConfiguration, immersive: Bool,
                reduceTransparency: Bool, size: CGSize, usesAlbumBackground: Bool) {
        let tuning = ImmersiveArtworkDebugStore.shared.configuration
        let mode = usesAlbumBackground && !immersive ? .meshColorMode2 : (configuration.backgroundMode ?? .mesh)
        let blur: Double
        if immersive { blur = tuning.validatedBlur }
        else if mode == .flowing { blur = (configuration.flowingBackground ?? .init()).validated().blur }
        else { blur = configuration.backgroundBlur }

        let next = Style(mode: mode, start: configuration.backgroundColor ?? .sourceDefault,
                         end: configuration.backgroundGradientEnd ?? .sourceDefault,
                         blur: blur.isFinite ? min(80, max(0, blur)) : 40, immersive: immersive,
                         dimming: immersive ? tuning[.dimming].opacity : 0,
                         feather: tuning.validatedTopFeatherLength,
                         opaque: reduceTransparency, usesAlbumBackground: usesAlbumBackground, size: size)
        let changed = next != style
        style = next
        if track != item.uri || url != item.artworkURL {
            track = item.uri
            url = item.artworkURL
            artwork = nil
            loading?.cancel()
            rebuild()
            if let url {
                let track = item.uri
                loading = Task { [weak self] in
                    let loaded = await ImmersiveStillArtworkCache.shared.load(url)
                    guard let self, !Task.isCancelled, self.track == track, self.url == url else { return }
                    artwork = loaded?.image
                    rebuild()
                }
            }
        } else if changed {
            rebuild()
        }
    }

    func draw(in bounds: CGRect) {
        if let image { image.draw(in: bounds) }
        else { UIColor(white: 0.065, alpha: 1).setFill(); UIRectFill(bounds) }
    }

    private func rebuild() {
        guard let style else { return }
        let bounds = CGRect(origin: .zero, size: style.size)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let source = artwork.map { UIImage(cgImage: $0) }
        var soft: UIImage?
        if let source, style.immersive || [.mesh, .meshColorMode2, .pixi, .flowing].contains(style.mode) {
            soft = soften(source, bounds: bounds, style: style, format: format)
        }
        image = UIGraphicsImageRenderer(size: style.size, format: format).image { output in
            let context = output.cgContext
            UIColor(style.start.swiftUIColor).setFill()
            context.fill(bounds)
            if style.mode == .gradient && !style.opaque {
                Self.gradient(in: context, bounds: bounds,
                              colors: [UIColor(style.start.swiftUIColor), UIColor(style.end.swiftUIColor)])
            }
            if !style.opaque {
                soft?.draw(in: bounds)
                if style.immersive, let source { drawImmersiveTop(source, in: bounds, style: style) }
                let scrim = style.immersive ? 0.32 + style.dimming * 0.45
                    : (style.usesAlbumBackground ? 0.48 : (soft == nil ? 0 : 0.22))
                UIColor.black.withAlphaComponent(scrim).setFill()
                context.fill(bounds)
            }
        }
        revision &+= 1
    }

    private func soften(_ source: UIImage, bounds: CGRect, style: Style,
                        format: UIGraphicsImageRendererFormat) -> UIImage? {
        let base = UIGraphicsImageRenderer(size: bounds.size, format: format).image { _ in
            source.draw(in: Self.aspectFill(source.size, in: bounds))
        }
        guard let decoded = base.cgImage else { return nil }
        var pixels = CIImage(cgImage: decoded)
        let extent = pixels.extent
        if !style.immersive && style.mode == .mesh {
            // Match the original mesh texture's contrast and saturation
            // before freezing its cover colors at the PiP viewport size.
            pixels = pixels.applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 2.04, kCIInputContrastKey: 0.51, kCIInputBrightnessKey: -0.12
            ])
        }
        let blur = style.mode == .pixi && !style.immersive ? max(18, style.blur) : style.blur
        if blur > 0 {
            pixels = pixels.clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: blur * 0.65])
                .cropped(to: extent)
        }
        return ci.createCGImage(pixels, from: extent).map { UIImage(cgImage: $0) }
    }

    private func drawImmersiveTop(_ source: UIImage, in bounds: CGRect, style: Style) {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let cover = UIGraphicsImageRenderer(size: bounds.size, format: format).image { output in
            var coverRect = Self.aspectFill(source.size, in: bounds)
            coverRect.origin.y = 0
            source.draw(in: coverRect)
            let context = output.cgContext
            context.setBlendMode(.destinationIn)
            Self.gradient(in: context, bounds: bounds,
                colors: [.white, .white, .clear], locations: [0, max(0, 0.5 - style.feather / 400), 0.92])
        }
        cover.draw(in: bounds)
    }

    private static func gradient(in context: CGContext, bounds: CGRect, colors: [UIColor],
                                 locations: [CGFloat]? = nil) {
        let locations = locations ?? colors.indices.map { CGFloat($0) / CGFloat(max(1, colors.count - 1)) }
        guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                        colors: colors.map(\.cgColor) as CFArray, locations: locations) else { return }
        context.drawLinearGradient(gradient, start: CGPoint(x: bounds.midX, y: bounds.minY),
                                   end: CGPoint(x: bounds.midX, y: bounds.maxY), options: [])
    }

    static func aspectFill(_ source: CGSize, in destination: CGRect) -> CGRect {
        guard source.width > 0, source.height > 0 else { return destination }
        let scale = max(destination.width / source.width, destination.height / source.height)
        let width = source.width * scale
        let height = source.height * scale
        return CGRect(x: destination.midX - width / 2, y: destination.midY - height / 2, width: width, height: height)
    }
}
