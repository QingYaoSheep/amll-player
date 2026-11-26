import AVFoundation
import CoreImage
import UIKit

/// Produces opaque video samples directly from the native lyric canvas. It
/// owns no player and never captures the foreground window or its controls.
@MainActor
final class DesktopLyricsFrames {
    let layer = AVSampleBufferDisplayLayer()
    private let canvas = AMLLNativeCanvas()
    private let background = DesktopLyricsBackground()
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private var pool: CVPixelBufferPool?
    private let bufferLimit = [kCVPixelBufferPoolAllocationThresholdKey: 4] as CFDictionary
    private var format: CMVideoFormatDescription?
    private var pixelSize = CGSize(width: 640, height: 360)
    private var lastFrameTime: Double?
    private var submitted: FrameKey?
    private var displayedTrack: String?
    private(set) var isAnimating = false

    private struct FrameKey: Equatable {
        var item: PlaybackItem
        var size: CGSize
        var revision: Int
        var seekRevision: Int
        var position: Double
        var offset: Double
        var playing: Bool
        var configuration: LyricsRenderConfiguration
        var backgroundRevision: Int
        var reduceMotion: Bool
        var reduceTransparency: Bool
    }

    init() {
        layer.videoGravity = .resizeAspect
        canvas.drivesFramesExternally = true
        canvas.clipsToBounds = false
        createPool()
    }

    func resize(_ dimensions: CMVideoDimensions) {
        guard dimensions.width > 0, dimensions.height > 0 else { return }
        // AVKit controls the window. Preserve the feed aspect ratio while
        // rounding and bounding raster resolution to limit reallocations.
        let longest = max(dimensions.width, dimensions.height)
        let width = min(768, max(320, ((Int(longest) + 63) / 64) * 64))
        let size = CGSize(width: width, height: width * 9 / 16)
        guard size != pixelSize else { return }
        pixelSize = size
        createPool()
    }

    private func createPool() {
        let attrs: [CFString: Any] = [
            kCVPixelBufferWidthKey: Int(pixelSize.width),
            kCVPixelBufferHeightKey: Int(pixelSize.height),
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        pool = nil
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs as CFDictionary, &pool)
        format = nil
        submitted = nil
    }

    func render(model: AppModel, frame: LyricsPlaybackFrame, immersive: Bool, animates: Bool) {
        guard let item = frame.snapshot?.item, let pool else {
            if submitted != nil {
                layer.flushAndRemoveImage()
                submitted = nil
            }
            isAnimating = false
            return
        }

        let duration = frame.snapshot?.duration ?? 0
        let advancing = frame.playing && (duration <= 0 || frame.position < duration)
        let bounds = CGRect(x: 0, y: 0, width: 320, height: 180)
        var configuration = model.renderPreferences.configuration.validated()
        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        let reduceTransparency = UIAccessibility.isReduceTransparencyEnabled
        background.update(item: item, configuration: configuration, immersive: immersive,
                          reduceTransparency: reduceTransparency, size: bounds.size,
                          usesAlbumBackground: model.renderPreferences.profile == .custom)

        let scale = pixelSize.width / bounds.width
        let font = configuration.resolvedFontSize(width: bounds.width, height: bounds.height)
        configuration.sizePreset = nil
        configuration.fontSize = min(28, max(17, font * 0.65))
        configuration.horizontalPadding = 16
        configuration.anchor = 0.29
        configuration.tabletTypography = nil
        configuration.hdr = nil // Opaque sRGB PiP samples carry SDR output.
        let lyrics = model.lyrics.document
        let offset = model.lyrics.effectiveOffset
        let key = FrameKey(item: item, size: pixelSize, revision: model.lyrics.documentRevision,
                           seekRevision: frame.seekRevision, position: animates ? frame.position : (frame.position * 2).rounded(.down) / 2, offset: offset,
                           playing: advancing, configuration: configuration, backgroundRevision: background.revision,
                           reduceMotion: reduceMotion, reduceTransparency: reduceTransparency)
        let renderer = layer.sampleBufferRenderer
        if renderer.requiresFlushToResumeDecoding || renderer.status == .failed {
            layer.flush()
            submitted = nil
        }
        guard submitted != key || (animates && isAnimating), renderer.isReadyForMoreMediaData else { return }
        var output: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, pool, bufferLimit, &output) == kCVReturnSuccess,
              let output else { return }

        if displayedTrack != item.uri {
            canvas.resetExportTransition()
            displayedTrack = item.uri
            isAnimating = false
            lastFrameTime = nil
        }
        let now = ProcessInfo.processInfo.systemUptime
        let delta = lastFrameTime.map { min(0.1, max(0, now - $0)) } ?? 0
        guard draw(output, bounds: bounds, scale: scale, item: item, document: lyrics, configuration: configuration,
                   frame: frame, revision: key.revision, offset: offset, delta: delta,
                   reduceMotion: reduceMotion, reduceTransparency: reduceTransparency) else { return }
        if let sample = sample(for: output, at: now) {
            renderer.enqueue(sample)
            submitted = key
            lastFrameTime = now
        }
    }

    private func draw(_ buffer: CVPixelBuffer, bounds: CGRect, scale: CGFloat, item: PlaybackItem,
                      document: LyricsDocument?, configuration: LyricsRenderConfiguration,
                      frame: LyricsPlaybackFrame, revision: Int, offset: Double, delta: Double,
                      reduceMotion: Bool, reduceTransparency: Bool) -> Bool
    {
        guard CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else { return false }
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let address = CVPixelBufferGetBaseAddress(buffer),
              let context = CGContext(data: address, width: CVPixelBufferGetWidth(buffer),
                                      height: CVPixelBufferGetHeight(buffer), bitsPerComponent: 8,
                                      bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: colorSpace,
                                      bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue)
        else { return false }
        context.translateBy(x: 0, y: pixelSize.height)
        context.scaleBy(x: scale, y: -scale)
        UIGraphicsPushContext(context)
        defer { UIGraphicsPopContext() }
        background.draw(in: bounds)

        if let document, !document.isInstrumental, !document.lines.isEmpty {
            canvas.frame = bounds
            canvas.exportRasterScale = scale
            // Forward one trusted clock transaction to the shared engine.
            let input = AMLLPlayerInput(position: frame.position, offset: offset, playing: frame.playing,
                                        seekRevision: frame.seekRevision, seekPosition: frame.legacySeekPosition,
                                        document: document, playbackSnapshot: frame.snapshot,
                                        artworkURL: item.artworkURL, configuration: configuration, event: .snapshot)
            canvas.configure(document: document, documentVersion: revision, configuration: configuration,
                             input: input, active: true, reduceMotion: reduceMotion,
                             reduceTransparency: reduceTransparency, canSeek: false)
            isAnimating = canvas.drawExportFrame(in: context, sample: frame, delta: delta,
                                                  additive: !reduceTransparency)
        } else {
            isAnimating = false
            drawMetadata(item, bounds: bounds)
        }
        return true
    }

    private func drawMetadata(_ item: PlaybackItem, bounds: CGRect) {
        let rect = CGRect(x: 18, y: bounds.midY - 26, width: 52, height: 52)
        if let artwork = background.artwork {
            let image = UIImage(cgImage: artwork)
            let clip = UIBezierPath(roundedRect: rect, cornerRadius: 8)
            let context = UIGraphicsGetCurrentContext()
            context?.saveGState()
            clip.addClip()
            image.draw(in: DesktopLyricsBackground.aspectFill(image.size, in: rect))
            context?.restoreGState()
        } else {
            UIImage(systemName: "music.note", withConfiguration: UIImage.SymbolConfiguration(pointSize: 23))?
                .withTintColor(.white, renderingMode: .alwaysOriginal).draw(in: rect.insetBy(dx: 12, dy: 12))
        }

        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let x = rect.maxX + 13
        let width = bounds.width - x - 18
        (item.title as NSString).draw(in: CGRect(x: x, y: bounds.midY - 22, width: width, height: 25),
            withAttributes: [.font: UIFont.systemFont(ofSize: 19, weight: .semibold),
                             .foregroundColor: UIColor.white, .paragraphStyle: style])
        (item.artistLine as NSString).draw(in: CGRect(x: x, y: bounds.midY + 5, width: width, height: 22),
            withAttributes: [.font: UIFont.systemFont(ofSize: 14), .foregroundColor: UIColor.white.withAlphaComponent(0.78),
                             .paragraphStyle: style])
    }

    private func sample(for buffer: CVPixelBuffer, at now: Double) -> CMSampleBuffer? {
        CVBufferSetAttachment(buffer, kCVImageBufferCGColorSpaceKey, colorSpace, .shouldPropagate)
        if format == nil {
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer,
                                                         formatDescriptionOut: &format)
        }
        guard let format else { return nil }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 60),
                                       presentationTimeStamp: CMTime(seconds: now, preferredTimescale: 60_000),
                                       decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer,
                       formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample) == noErr,
              let sample, let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
              let entry = CFArrayGetValueAtIndex(attachments, 0) else { return nil }
        let flags = Unmanaged<CFMutableDictionary>.fromOpaque(entry).takeUnretainedValue()
        CFDictionarySetValue(flags, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                             Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        return sample
    }
}
