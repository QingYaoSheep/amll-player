import AVFoundation
import CoreImage
import UIKit

/// Produces opaque video samples directly from the native lyric canvas. It
/// owns no player and never captures the foreground window or its controls.
@MainActor
final class DesktopLyricsFrames {
    let layer = AVSampleBufferDisplayLayer()
    let aspect: DesktopLyricsSettings.Aspect
    private let canvas = AMLLNativeCanvas()
    private let background: DesktopLyricsBackground
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private var pool: CVPixelBufferPool?
    private let bufferLimit = [kCVPixelBufferPoolAllocationThresholdKey: 4] as CFDictionary
    private var format: CMVideoFormatDescription?
    private(set) var pixelSize: CGSize
    private var pendingResize: (size: CGSize, changedAt: Double)?
    var hasSubmittedFrame: Bool { submitted != nil }
    private var lastFrameTime: Double?
    private var submitted: FrameKey?
    private var displayedTrack: String?
    private var singleLineTimeline: DesktopLyricsSingleLineTimeline?
    private var singleLineRevision: Int?
    private var singleLineTransition = DesktopLyricsSingleLineTransition()
    private var outgoingLine: UIImage?
    private lazy var transitionBlurContext = CIContext(options: [.useSoftwareRenderer: true, .cacheIntermediates: false])
    private(set) var isAnimating = false
    private(set) var needsPlaybackFrames = false

    private struct CanvasSettings: Equatable {
        var revision: Int?
        var offset: Double
        var configuration: LyricsRenderConfiguration
        var settings: DesktopLyricsSettings
        var reduceMotion: Bool
        var reduceTransparency: Bool
    }

    private struct FrameKey: Equatable {
        var item: PlaybackItem
        var canvas: CanvasSettings
        var seekRevision: Int
        var pendingSeek: UUID?
        var confirmedSeek: UUID?
        var position: Double
        var playing: Bool
        var backgroundRevision: Int
    }

    init(aspect: DesktopLyricsSettings.Aspect) {
        self.aspect = aspect
        background = DesktopLyricsBackground(size: aspect.canvasSize)
        pixelSize = aspect.outputSize(for: .zero)
        layer.videoGravity = .resizeAspect
        canvas.drivesFramesExternally = true
        canvas.clipsToBounds = false
        createPool()
    }

    func resize(_ dimensions: CMVideoDimensions, at now: Double = ProcessInfo.processInfo.systemUptime) {
        guard dimensions.width > 0, dimensions.height > 0 else { return }
        let size = aspect.outputSize(for: CGSize(width: Int(dimensions.width), height: Int(dimensions.height)))
        if size == pixelSize {
            pendingResize = nil
        } else if pendingResize?.size != size {
            pendingResize = (size, now)
        }
    }

    func applyPendingResize(at now: Double) {
        guard let request = pendingResize, now - request.changedAt >= 0.15 else { return }
        pendingResize = nil
        createPool(size: request.size)
    }

    private func createPool(size: CGSize? = nil) {
        let target = size ?? pixelSize
        let attrs: [CFString: Any] = [
            kCVPixelBufferWidthKey: Int(target.width),
            kCVPixelBufferHeightKey: Int(target.height),
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        var newPool: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs as CFDictionary, &newPool) == kCVReturnSuccess,
              let newPool else { return }
        pool = newPool
        pixelSize = target
        format = nil
        submitted = nil
    }

    func render(model: AppModel, frame: LyricsPlaybackFrame, animates: Bool) {
        render(frame: frame, lyrics: model.lyrics.document, revision: model.lyrics.documentRevision,
               offset: model.lyrics.effectiveOffset, configuration: model.renderPreferences.configuration,
               settings: model.desktopLyricsPreferences.settings, animates: animates)
    }

    func render(frame: LyricsPlaybackFrame, lyrics: LyricsDocument?, revision: Int, offset: Double,
                configuration source: LyricsRenderConfiguration, settings: DesktopLyricsSettings, animates: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        applyPendingResize(at: now)
        guard let item = frame.snapshot?.item, let pool else {
            if submitted != nil {
                layer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
                submitted = nil
            }
            isAnimating = false
            needsPlaybackFrames = false
            return
        }

        let document = lyrics.flatMap { !$0.isInstrumental && !$0.lines.isEmpty ? $0 : nil }
        let duration = frame.snapshot?.duration ?? 0
        let advancing = frame.playing && (duration <= 0 || frame.position < duration)
        needsPlaybackFrames = advancing && document != nil
        background.update(artworkURL: item.artworkURL)

        var presentation = settings
        presentation.mode = aspect == .singleLine ? .singleLine : .scrolling
        if aspect != .singleLine { presentation.aspect = aspect }
        let appearance = CanvasSettings(revision: document == nil ? nil : revision, offset: offset, configuration: source, settings: presentation,
                                        reduceMotion: UIAccessibility.isReduceMotionEnabled,
                                        reduceTransparency: UIAccessibility.isReduceTransparencyEnabled)
        let position = animates ? frame.position : (frame.position * 2).rounded(.down) / 2
        let key = FrameKey(item: item, canvas: appearance, seekRevision: frame.seekRevision,
                           pendingSeek: frame.pending?.id, confirmedSeek: frame.confirmation?.requestID,
                           position: document == nil ? 0 : position, playing: needsPlaybackFrames,
                           backgroundRevision: background.revision)
        let renderer = layer.sampleBufferRenderer
        if renderer.requiresFlushToResumeDecoding || renderer.status == .failed {
            renderer.flush()
            submitted = nil
        }
        guard submitted != key || (animates && isAnimating), renderer.isReadyForMoreMediaData else { return }
        var output: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, pool, bufferLimit, &output) == kCVReturnSuccess,
              let output else { return }

        if displayedTrack != item.uri {
            displayedTrack = item.uri
            singleLineRevision = nil
            isAnimating = false
            lastFrameTime = nil
        }
        let delta = lastFrameTime.map { min(0.1, max(0, now - $0)) } ?? 0
        guard draw(output, document: document, frame: frame, key: key, delta: delta,
                   now: now, animates: animates) else { return }
        if let sample = sample(for: output, at: now) {
            renderer.enqueue(sample)
            submitted = key
            lastFrameTime = now
        }
    }

    private func draw(_ buffer: CVPixelBuffer, document: LyricsDocument?, frame: LyricsPlaybackFrame,
                      key: FrameKey, delta: Double, now: Double, animates: Bool) -> Bool
    {
        guard CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else { return false }
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let address = CVPixelBufferGetBaseAddress(buffer),
              let context = CGContext(data: address, width: CVPixelBufferGetWidth(buffer),
                                      height: CVPixelBufferGetHeight(buffer), bitsPerComponent: 8,
                                      bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: colorSpace,
                                      bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue)
        else { return false }
        let bounds = CGRect(origin: .zero, size: aspect.canvasSize)
        let scale = pixelSize.width / bounds.width
        context.translateBy(x: 0, y: pixelSize.height)
        context.scaleBy(x: scale, y: -scale)
        UIGraphicsPushContext(context)
        defer { UIGraphicsPopContext() }
        background.draw(in: bounds)

        if let document {
            let appearance = key.canvas
            if canvas.frame != bounds { canvas.frame = bounds }
            canvas.exportRasterScale = scale
            if submitted?.canvas != appearance || submitted?.item.uri != key.item.uri
                || submitted?.item.artworkURL != key.item.artworkURL
            {
                let configuration = appearance.settings.rendererConfiguration(appearance.configuration)
                let input = AMLLPlayerInput(position: frame.position, offset: appearance.offset, playing: frame.playing,
                                            seekRevision: frame.seekRevision, seekPosition: frame.legacySeekPosition,
                                            document: document, playbackSnapshot: frame.snapshot,
                                            artworkURL: key.item.artworkURL, configuration: configuration, event: .snapshot)
                canvas.configure(document: document, documentVersion: appearance.revision, configuration: configuration,
                                 input: input, active: true, reduceMotion: appearance.reduceMotion,
                                 reduceTransparency: appearance.reduceTransparency, canSeek: false,
                                 desktopSettings: appearance.settings)
            }
            // Playback and seek transactions are applied by advanceExportFrame on every lyric sample.
            if appearance.settings.mode == .singleLine {
                drawSingleLine(in: context, document: document, frame: frame, key: key, delta: delta,
                               now: now, animates: animates)
            } else {
                isAnimating = canvas.drawExportFrame(in: context, sample: frame, delta: delta,
                                                      additive: !appearance.reduceTransparency)
            }
        } else {
            outgoingLine = nil
            singleLineTimeline = nil
            singleLineRevision = nil
            isAnimating = false
            drawMetadata(key.item, bounds: bounds)
        }
        return true
    }

    private func drawSingleLine(in context: CGContext, document: LyricsDocument, frame: LyricsPlaybackFrame,
                                key: FrameKey, delta: Double, now: Double, animates: Bool) {
        let appearance = key.canvas
        if singleLineRevision != appearance.revision {
            singleLineTimeline = DesktopLyricsSingleLineTimeline(document: document)
            singleLineRevision = appearance.revision
        }
        let time = DesktopLyricsSingleLineTimeline.lyricTime(position: frame.position, offset: appearance.offset)
        let target = singleLineTimeline?.line(at: time)
        let immediate = !animates || singleLineNeedsRebase(to: key)
        let presentation = singleLineTransition.frame(target: target?.index, now: now, immediate: immediate,
                                                       blurs: !appearance.reduceMotion && !appearance.reduceTransparency)
        if let capture = presentation.capture {
            // Keep only the old transparent lyric pixels. The shared engine
            // advances the incoming lyric below, even while it remains hidden.
            outgoingLine = canvas.snapshotExportLine(capture)
        }
        let moving = canvas.advanceExportFrame(sample: frame, delta: delta, singleLine: target)
        switch presentation.layer {
        case .empty:
            outgoingLine = nil
        case let .live(index, alpha):
            outgoingLine = nil
            canvas.drawExportLine(index, in: context, opacity: alpha, additive: !appearance.reduceTransparency)
        case let .outgoing(alpha, blur):
            drawOutgoingLine(in: canvas.bounds, alpha: alpha, blur: blur, additive: !appearance.reduceTransparency)
        }
        isAnimating = moving || singleLineTransition.isAnimating
    }

    private func singleLineNeedsRebase(to frame: FrameKey) -> Bool {
        guard let previous = submitted else { return true }
        return frame.item.uri != previous.item.uri || frame.canvas != previous.canvas
            || frame.position < previous.position - 0.5
            || (frame.pendingSeek == nil && (frame.seekRevision != previous.seekRevision
                    || frame.confirmedSeek != previous.confirmedSeek || previous.pendingSeek != nil))
    }

    private func drawOutgoingLine(in bounds: CGRect, alpha: Double, blur: Double, additive: Bool) {
        guard alpha > 0, let outgoingLine else { return }
        let bitmap: UIImage
        if blur > 0, let pixels = outgoingLine.cgImage {
            // Keep the sharp snapshot at the output resolution. The soft
            // exit layer needs fewer pixels, and the blur radius stays in points.
            let scale = min(2, outgoingLine.scale)
            let ratio = scale / outgoingLine.scale
            let input = CIImage(cgImage: pixels).transformed(by: .init(scaleX: ratio, y: ratio))
            let softened = input.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: blur * scale])
            bitmap = transitionBlurContext.createCGImage(softened, from: input.extent)
                .map { UIImage(cgImage: $0, scale: scale, orientation: .up) } ?? outgoingLine
        } else {
            bitmap = outgoingLine
        }
        bitmap.draw(in: bounds, blendMode: additive ? .plusLighter : .normal, alpha: alpha)
    }

    private func drawMetadata(_ item: PlaybackItem, bounds: CGRect) {
        let rect = CGRect(x: 18, y: bounds.midY - 26, width: 52, height: 52)
        if let image = background.artwork {
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
