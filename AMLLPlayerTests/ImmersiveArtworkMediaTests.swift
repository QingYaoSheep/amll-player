@testable import AMLLPlayer
import AVFoundation
import CoreImage
import MetalKit
import SwiftUI
import UIKit
import XCTest

@MainActor
final class ImmersiveArtworkMediaTests: XCTestCase {
    func testImmersiveMeshFeedsLiveBlurWithoutRecurringBackgroundReadbacks() async throws {
        _ = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let window = try playbackWindow()
        let frames = ArtworkReflectionFrames()
        let surface = ImmersiveArtworkMedia.Surface(frames: frames)
        surface.frame = CGRect(x: 0, y: 0, width: 120, height: 240)
        window.rootViewController?.view.addSubview(surface)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        let cover = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32)).image { context in
            UIColor.green.setFill(); context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        }
        try XCTUnwrap(cover.pngData()).write(to: url)
        defer {
            surface.stop(); surface.removeFromSuperview(); window.isHidden = true
            try? FileManager.default.removeItem(at: url)
        }
        var tuning = ImmersiveArtworkDebugConfiguration()
        for kind in [ImmersiveArtworkLayer.video, .reflection, .dimming, .bottomFade] { tuning[kind].enabled = false }
        tuning.blurRadius = 24
        surface.configure(video: AnimatedArtwork(url: URL(fileURLWithPath: "/unused.mp4"), active: false),
            layout: .init(video: .zero, reflection: .zero, transition: surface.bounds, bottomFade: .zero,
                tuning: tuning, presentsFrame: false, reflectionEnabled: false, reduceTransparency: false),
            background: AMLLBackground(artworkURL: url, active: true, blur: 40, mode: .mesh))
        surface.layoutIfNeeded()
        try await Task.sleep(for: .seconds(1))
        try await waitUntil { surface.transitionSurface.renderedFrames > 3 }
        let before = surface.backgroundReadbacks
        let completed = surface.transitionSurface.renderedFrames
        try await waitUntil { surface.transitionSurface.renderedFrames > completed + 5 }
        XCTAssertEqual(surface.backgroundReadbacks, before,
            "A live native Mesh frame must enter blur on the GPU instead of reading the hosted background back every tick")
        XCTAssertGreaterThan(surface.nativeBackgroundCaptures, 5)
        XCTAssertLessThanOrEqual(surface.backgroundFrameStatistics.textures, 4)
        let timing = XCTAttachment(string: "backgroundReadbacksAfterWarmup=\(surface.backgroundReadbacks - before)\nnativeCaptures=\(surface.nativeBackgroundCaptures)\ntextures=\(surface.backgroundFrameStatistics.textures)\n\(surface.transitionSurface.diagnosticText)")
        timing.name = "Immersive Mesh background capture after warmup"
        timing.lifetime = .keepAlways
        add(timing)
        let pixel = try backdropPixel(window, at: CGPoint(x: 60, y: 200))
        XCTAssertGreaterThan(pixel[1], pixel[0] + 20, "The actual blur drawable must still contain the green live Mesh cover")
        XCTAssertGreaterThan(pixel[1], pixel[2] + 20)
        XCTAssertLessThanOrEqual(surface.transitionSurface.maximumInFlight, 2)
    }

    func testConfigurationChangedDuringCaptureCannotCommitRetiredInput() async throws {
        _ = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let window = try playbackWindow()
        let surface = ImmersiveLiveBlurSurface()
        surface.frame = CGRect(x: 0, y: 0, width: 32, height: 64)
        window.rootViewController?.view.addSubview(surface)
        defer { surface.stop(); surface.removeFromSuperview(); window.isHidden = true }
        let scale = min(1.5, window.screen.scale)
        func input(_ color: CIColor) -> ImmersiveBlurInput {
            .init(region: surface.frame, profile: .init(frame: surface.frame, fullStrengthY: 0),
                scale: scale, planes: [.solid(color, frame: surface.frame)])
        }
        surface.capture = {
            // Hierarchy capture may deliver UIKit changes before returning its
            // image. That image belongs to the generation at capture entry.
            surface.capture = { input(.blue) }
            surface.configure(amount: 1 / 80.0, mask: nil)
            return input(.red)
        }
        surface.configure(amount: 1 / 80.0, mask: nil)
        surface.layoutIfNeeded()
        surface.requestOutputSnapshot()
        try await waitUntil { surface.capturedOutput != nil }
        let output = try XCTUnwrap(surface.capturedOutput)
        var bytes = [UInt8](repeating: 0, count: 4)
        bytes.withUnsafeMutableBytes {
            CIContext().render(CIImage(cgImage: output), toBitmap: $0.baseAddress!, rowBytes: 4,
                bounds: CGRect(x: 8, y: 8, width: 1, height: 1), format: .RGBA8,
                colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        }
        XCTAssertGreaterThan(bytes[2], 240, "A capture retired during UIKit updates must never be presented")
        XCTAssertLessThan(bytes[0], 10)
        XCTAssertLessThanOrEqual(surface.maximumInFlight, 2)
        surface.stop()
        try await waitUntil { surface.inFlightSubmissionCount == 0 }
    }

    func testSharedMeshColorsMatchTheOriginalCaptureAtTheSameCoordinates() async throws {
        _ = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let window = try playbackWindow()
        let surface = ImmersiveArtworkMedia.Surface(frames: ArtworkReflectionFrames())
        surface.frame = CGRect(x: 0, y: 0, width: 120, height: 240)
        window.rootViewController?.view.addSubview(surface)
        var files: [URL] = []
        defer {
            surface.stop(); surface.removeFromSuperview(); window.isHidden = true
            for file in files { try? FileManager.default.removeItem(at: file) }
        }
        let colors = [UIColor(red: 0.72, green: 0.42, blue: 0.28, alpha: 1),
                      UIColor(red: 0.12, green: 0.55, blue: 0.63, alpha: 1),
                      UIColor(red: 0.42, green: 0.37, blue: 0.62, alpha: 1)]
        var tuning = ImmersiveArtworkDebugConfiguration()
        for kind in [ImmersiveArtworkLayer.video, .reflection, .bottomFade] { tuning[kind].enabled = false }
        tuning.blurRadius = 24
        tuning.topFeatherLength = 0
        let originalCapture = try XCTUnwrap(surface.transitionSurface.capture)
        func meshView(in view: UIView) -> MTKView? {
            if let mesh = view as? MTKView { return mesh }
            return view.subviews.lazy.compactMap { meshView(in: $0) }.first
        }
        for mode in [LyricsRenderConfiguration.BackgroundMode.mesh, .meshColorMode2] {
            for color in colors {
                let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
                let image = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32)).image { context in
                    color.setFill(); context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
                }
                try XCTUnwrap(image.pngData()).write(to: url); files.append(url)
                surface.transitionSurface.capture = originalCapture
                surface.configure(video: AnimatedArtwork(url: URL(fileURLWithPath: "/unused.mp4"), active: false),
                    layout: .init(video: .zero, reflection: .zero,
                        transition: surface.bounds, bottomFade: .zero,
                        tuning: tuning, presentsFrame: false, reflectionEnabled: false, reduceTransparency: false),
                    background: AMLLBackground(artworkURL: url, active: true, blur: 40, mode: mode))
                surface.layoutIfNeeded()
                // Keep the real shader's vignette and dither. Freeze its last
                // completed drawable, then compare both capture paths at the
                // same coordinates with identical blur, alpha and dimming.
                try await Task.sleep(for: .milliseconds(1200))
                let mesh = try XCTUnwrap(meshView(in: surface.backgroundSurface))
                mesh.isPaused = true
                try await Task.sleep(for: .milliseconds(200))
                let native = try XCTUnwrap(originalCapture())
                let format = UIGraphicsImageRendererFormat()
                format.scale = native.scale; format.opaque = false
                let legacy = UIGraphicsImageRenderer(size: native.region.size, format: format).image { context in
                    context.cgContext.translateBy(x: surface.backgroundSurface.frame.minX - native.region.minX,
                        y: surface.backgroundSurface.frame.minY - native.region.minY)
                    surface.backgroundSurface.drawHierarchy(in: surface.backgroundSurface.bounds, afterScreenUpdates: false)
                }
                let bitmap = try XCTUnwrap(legacy.cgImage)
                var sharedPlanes = 0
                let planes = native.planes.map { plane -> ImmersiveBlurInput.Plane in
                    if case .background = plane { sharedPlanes += 1; return .bitmap(bitmap) }
                    return plane
                }
                XCTAssertEqual(sharedPlanes, 1, "The comparison must exercise the shared native Mesh frame")
                let captured = ImmersiveBlurInput(region: native.region, profile: native.profile,
                    scale: native.scale, planes: planes)
                let points = [CGPoint(x: 24, y: 48), CGPoint(x: 60, y: 120), CGPoint(x: 96, y: 192)]
                func pixels(for input: ImmersiveBlurInput) async throws -> [[Int]] {
                    surface.transitionSurface.capture = { input }
                    surface.transitionSurface.configure(amount: 24 / 80.0, mask: nil)
                    let completed = surface.transitionSurface.renderedFrames
                    try await waitUntil { surface.transitionSurface.renderedFrames > completed + 3 }
                    return try points.map { try backdropPixel(window, at: $0) }
                }
                let filtered = try await pixels(for: native)
                let original = try await pixels(for: captured)
                for point in points.indices {
                    for channel in 0 ..< 3 {
                        XCTAssertEqual(Double(filtered[point][channel]), Double(original[point][channel]), accuracy: 3,
                            "The shared frame must match original hierarchy capture at the same coordinate; feather must not hide a color mismatch")
                    }
                }
                XCTAssertGreaterThan(surface.nativeBackgroundCaptures, 0)
            }
        }
    }

    func testBlurTopFeatherHidesACloneColorSeamWithoutFadingTheWholeOutput() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "artwork-layer-order", withExtension: "mp4"))
        let window = try playbackWindow()
        let frames = ArtworkReflectionFrames()
        let surface = ImmersiveArtworkMedia.Surface(frames: frames)
        surface.frame = CGRect(x: 0, y: 0, width: 200, height: 650)
        window.rootViewController?.view.addSubview(surface)
        defer { surface.stop(); surface.removeFromSuperview(); window.isHidden = true }
        surface.backgroundSurface.backgroundColor = UIColor(red: 0.4, green: 0.23, blue: 0.12, alpha: 1)
        var tuning = ImmersiveArtworkDebugConfiguration()
        for kind in [ImmersiveArtworkLayer.reflection, .dimming, .bottomFade] { tuning[kind].enabled = false }
        tuning[.video].opacity = 0.65
        tuning.blurRadius = 40
        let video = AnimatedArtwork(url: url, active: false)
        let profile = ImmersiveBackgroundBlurProfile(frame: CGRect(x: 0, y: 180, width: 200, height: 470), fullStrengthY: 400)
        func apply() {
            surface.configure(video: video, layout: .init(video: CGRect(x: 0, y: 0, width: 128, height: 400),
                reflection: .zero, transition: profile.frame, bottomFade: .zero, tuning: tuning,
                presentsFrame: true, reflectionEnabled: false, reduceTransparency: false, blurProfile: profile))
            surface.layoutIfNeeded()
        }
        tuning[.transition].enabled = false
        apply()
        try await waitUntil { frames.hasFrame && frames.primaryFrameReady }
        // Decoder/layer readiness can precede the compositor's first visible
        // frame. This fixture's red column must actually be on screen before
        // recording an unfiltered baseline (the brown backdrop is only 102).
        try await waitUntil {
            guard let pixel = try? backdropPixel(window, at: CGPoint(x: 12, y: 180), attach: false) else { return false }
            return pixel[0] > 180
        }
        let player = try XCTUnwrap((surface.videoSurface.layer as? AVPlayerLayer)?.player)
        let originalCapture = try XCTUnwrap(surface.transitionSurface.capture)
        // A controlled clone-color mismatch makes a boundary discontinuity
        // reproducible regardless of the decoder's color tags. The independent
        // color-parity tests still exercise the unmodified production input.
        surface.transitionSurface.capture = {
            guard let input = originalCapture() else { return nil }
            return .init(region: input.region, profile: input.profile, scale: input.scale,
                planes: input.planes + [.solid(CIColor(red: 1, green: 1, blue: 1, alpha: 0.12), frame: input.region)])
        }
        let beforeVideo = try backdropPixel(window, at: CGPoint(x: 12, y: 180))
        let beforeBackground = try backdropPixel(window, at: CGPoint(x: 160, y: 180))
        let beforeLower = try backdropPixel(window, at: CGPoint(x: 160, y: 220))
        tuning[.transition].enabled = true
        apply()
        try await waitUntil { surface.transitionSurface.renderedFrames > 3 }
        let afterVideo = try backdropPixel(window, at: CGPoint(x: 12, y: 180))
        let afterBackground = try backdropPixel(window, at: CGPoint(x: 160, y: 180))
        let afterLower = try backdropPixel(window, at: CGPoint(x: 160, y: 220))
        for channel in 0 ..< 3 {
            XCTAssertEqual(Double(afterVideo[channel]), Double(beforeVideo[channel]), accuracy: 1,
                "The very top must reveal the real video instead of a mismatched clone")
            XCTAssertEqual(Double(afterBackground[channel]), Double(beforeBackground[channel]), accuracy: 1,
                "The feather must also join the real background without a horizontal brightness step")
        }
        XCTAssertGreaterThan(afterLower[1], beforeLower[1] + 12,
            "The local feather must not fade away the entire filtered output")
        XCTAssertTrue((surface.videoSurface.layer as? AVPlayerLayer)?.player === player)
        XCTAssertEqual(player.rate, 0, "Updating the effect cannot restart a paused video")
    }

    func testLiveFeatherTuningKeepsMediaOwnershipAndFullBlurBelowTheLocalBand() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "artwork-layer-order", withExtension: "mp4"))
        let window = try playbackWindow()
        let frames = ArtworkReflectionFrames()
        let surface = ImmersiveArtworkMedia.Surface(frames: frames)
        surface.frame = CGRect(x: 0, y: 0, width: 200, height: 650)
        window.rootViewController?.view.addSubview(surface)
        defer { surface.stop(); surface.removeFromSuperview(); window.isHidden = true }
        var tuning = ImmersiveArtworkDebugConfiguration()
        for kind in [ImmersiveArtworkLayer.dimming, .bottomFade] { tuning[kind].enabled = false }
        tuning[.video].opacity = 0.65
        tuning.blurRadius = 40
        let video = AnimatedArtwork(url: url, active: false)
        var profile = ImmersiveBackgroundBlurProfile(frame: CGRect(x: 0, y: 180, width: 200, height: 470), fullStrengthY: 400)
        var reflects = false
        func apply() {
            surface.configure(video: video, layout: .init(video: CGRect(x: 0, y: 0, width: 128, height: 400),
                reflection: CGRect(x: 0, y: 400, width: 128, height: 250), transition: profile.frame,
                bottomFade: .zero, tuning: tuning, presentsFrame: true, reflectionEnabled: reflects,
                reduceTransparency: false, blurProfile: profile))
            surface.layoutIfNeeded()
        }
        tuning[.transition].enabled = false
        apply()
        try await waitUntil { frames.hasFrame && frames.primaryFrameReady }
        let player = try XCTUnwrap((surface.videoSurface.layer as? AVPlayerLayer)?.player)
        let source = frames.sessionDiagnostic
        let producer = try XCTUnwrap(frames.producerIdentifier)
        let capture = try XCTUnwrap(surface.transitionSurface.capture)
        surface.transitionSurface.capture = {
            guard let input = capture() else { return nil }
            return .init(region: input.region, profile: input.profile, scale: input.scale,
                planes: input.planes + [.solid(CIColor(red: 1, green: 1, blue: 1, alpha: 0.12), frame: input.region)])
        }
        let colors: [UIColor] = [.white, .black, .blue, UIColor(red: 0.72, green: 0.45, blue: 0.3, alpha: 1)]
        for (index, color) in colors.enumerated() {
            reflects = index % 2 == 1
            surface.backgroundSurface.backgroundColor = color
            tuning[.transition].enabled = false
            apply()
            let before = try backdropPixel(window, at: CGPoint(x: 12, y: 180))
            tuning[.transition].enabled = true
            tuning.topFeatherLength = 0
            var submitted = surface.transitionSurface.renderedFrames
            apply()
            try await waitUntil { surface.transitionSurface.renderedFrames > submitted + 3 }
            let fullBlur = try backdropPixel(window, at: CGPoint(x: 160, y: 500))
            for length in [24.0, 80.0] {
                tuning.topFeatherLength = length
                submitted = surface.transitionSurface.renderedFrames
                let itemBeforeAdjustment = player.currentItem
                apply()
                XCTAssertTrue(player.currentItem === itemBeforeAdjustment,
                    "A tuning update cannot replace the current item; the looper may replace its initial replica asynchronously")
                try await waitUntil { surface.transitionSurface.renderedFrames > submitted + 3 }
                let after = try backdropPixel(window, at: CGPoint(x: 12, y: 180))
                let lower = try backdropPixel(window, at: CGPoint(x: 160, y: 500))
                for channel in 0 ..< 3 {
                    XCTAssertEqual(Double(after[channel]), Double(before[channel]), accuracy: 1)
                    XCTAssertEqual(Double(lower[channel]), Double(fullBlur[channel]), accuracy: 1,
                        "Changing only the local feather cannot change the filtered body")
                }
                let mask = try XCTUnwrap(surface.transitionSurface.mask)
                apply()
                XCTAssertTrue(surface.transitionSurface.mask === mask,
                    "Identical layout updates must reuse the mask rather than allocate each video frame")
                XCTAssertTrue((surface.videoSurface.layer as? AVPlayerLayer)?.player === player)
                XCTAssertEqual(frames.producerIdentifier, producer)
                XCTAssertEqual(frames.sessionDiagnostic, source,
                    "Ordinary tuning must preserve the resource and frame-source session, including asynchronous loop-item preparation")
                XCTAssertEqual(player.rate, 0)
            }
        }
        profile = .init(frame: CGRect(x: 0, y: 390, width: 200, height: 260), fullStrengthY: 400)
        apply()
        XCTAssertTrue(frames.blurLayoutDiagnostic.contains("实际 10.0 pt"))
        XCTAssertEqual(surface.transitionSurface.mask?.bounds.size, profile.frame.size)
        tuning[.video].enabled = false
        apply()
        XCTAssertNil(surface.transitionSurface.mask, "A full-background blur has no top junction feather")
        XCTAssertTrue(frames.blurLayoutDiagnostic.contains("实际 0.0 pt"))
        XCTAssertLessThanOrEqual(surface.transitionSurface.maximumInFlight, 2)
    }

    func testBlurTopMatchesTheUnfilteredTranslucentVideo() async throws {
        try await checkBlurTopMatchesTheUnfilteredTranslucentVideo(playerLevel: false)
    }

    func testPlayerLevelBlurTopMatchesTheUnfilteredTranslucentVideo() async throws {
        try await checkBlurTopMatchesTheUnfilteredTranslucentVideo(playerLevel: true)
    }

    func testExplicitLegacyColorVideoMatchesItsUnfilteredPlane() async throws {
        try await checkBlurTopMatchesTheUnfilteredTranslucentVideo(playerLevel: false, resource: "artwork-layer-order-tagged")
    }

    func testExplicitLegacyColorPlayerOutputMatchesItsUnfilteredPlane() async throws {
        try await checkBlurTopMatchesTheUnfilteredTranslucentVideo(playerLevel: true, resource: "artwork-layer-order-tagged")
    }

    private func checkBlurTopMatchesTheUnfilteredTranslucentVideo(playerLevel: Bool, resource: String = "artwork-layer-order") async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: resource, withExtension: "mp4"))
        let window = try playbackWindow()
        let frames = ArtworkReflectionFrames()
        let surface = ImmersiveArtworkMedia.Surface(frames: frames)
        surface.frame = CGRect(x: 0, y: 0, width: 200, height: 650)
        window.rootViewController?.view.addSubview(surface)
        defer { surface.stop(); surface.removeFromSuperview(); window.isHidden = true }
        surface.backgroundSurface.backgroundColor = UIColor(red: 0.65, green: 0.5, blue: 0.85, alpha: 1)
        var tuning = ImmersiveArtworkDebugConfiguration()
        for kind in [ImmersiveArtworkLayer.reflection, .dimming, .bottomFade] { tuning[kind].enabled = false }
        tuning[.video].opacity = 0.65
        tuning.blurRadius = 80
        tuning.topFeatherLength = 0 // Keep the independent color check unmasked.
        var video = AnimatedArtwork(url: url, active: playerLevel)
        let rect = CGRect(x: 0, y: 0, width: 128, height: 400)
        let profile = ImmersiveBackgroundBlurProfile(frame: CGRect(x: 0, y: 180, width: 200, height: 470), fullStrengthY: 400)
        func apply() {
            surface.configure(video: video, layout: .init(video: rect, reflection: .zero,
                transition: profile.frame, bottomFade: .zero, tuning: tuning, presentsFrame: true,
                reflectionEnabled: false, reduceTransparency: false, blurProfile: profile))
            surface.layoutIfNeeded()
        }
        tuning[.transition].enabled = false
        apply()
        try await waitUntil { frames.hasFrame && frames.primaryFrameReady }
        if playerLevel {
            let received = frames.receivedFrames
            surface.videoSurface.usePlayerLevelFrameOutput()
            try await waitUntil {
                surface.videoSurface.refreshReflectionFrame(hostTime: CACurrentMediaTime())
                return frames.receivedFrames > received
            }
            video.active = false
            apply()
            try await Task.sleep(for: .milliseconds(100))
        }
        // Layer readiness precedes the first screen composite on some runs.
        // Do not compare the purple fallback against the later video frame.
        // The fixture's red column must be visible before capturing its color;
        // the unmodified color-parity assertion below still uses accuracy 3.
        try await waitUntil {
            guard let pixel = try? backdropPixel(window, at: CGPoint(x: 12, y: 181), attach: false) else { return false }
            return pixel[0] > 180
        }
        let before = try backdropPixel(window, at: CGPoint(x: 12, y: 181))
        tuning[.transition].enabled = true
        apply()
        try await waitUntil { surface.transitionSurface.renderedFrames > 3 }
        let after = try backdropPixel(window, at: CGPoint(x: 12, y: 181))
        let buffer = try XCTUnwrap(frames.currentBuffer)
        let sourceDiagnostic = "fixture=\(resource), format=\(CVPixelBufferGetPixelFormatType(buffer)), imported=\(String(describing: ArtworkReflectionImage.decodedVideoSource(buffer).colorSpace)), default=\(String(describing: CIImage(cvPixelBuffer: buffer).colorSpace)), space=\(String(describing: CVBufferCopyAttachment(buffer, kCVImageBufferCGColorSpaceKey, nil))), ICC=\(CVBufferCopyAttachment(buffer, kCVImageBufferICCProfileKey, nil) != nil), primaries=\(String(describing: CVBufferCopyAttachment(buffer, kCVImageBufferColorPrimariesKey, nil))), transfer=\(String(describing: CVBufferCopyAttachment(buffer, kCVImageBufferTransferFunctionKey, nil))), gamma=\(String(describing: CVBufferCopyAttachment(buffer, kCVImageBufferGammaLevelKey, nil)))"
        for channel in 0 ..< 3 {
            XCTAssertEqual(Double(after[channel]), Double(before[channel]), accuracy: 3,
                "The zero-strength upper edge must preserve the real lower-plane color, without an opaque seam; \(sourceDiagnostic)")
        }
        let preferredRate = try XCTUnwrap(surface.transitionSurface.preferredRefreshRate)
        XCTAssertGreaterThanOrEqual(preferredRate, Float(60),
            "The backdrop must not be capped to the previous 30Hz sampling loop")
    }

    func testGPUOutputPreservesTopBottomOrientationAndBoundsSubmissions() async throws {
        _ = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let window = try playbackWindow()
        let surface = ImmersiveLiveBlurSurface()
        surface.frame = CGRect(x: 0, y: 0, width: 100, height: 120)
        window.rootViewController?.view.addSubview(surface)
        defer { surface.stop(); surface.removeFromSuperview(); window.isHidden = true }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let bitmap = try XCTUnwrap(UIGraphicsImageRenderer(size: surface.bounds.size, format: format).image { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 100, height: 60))
            UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 60, width: 100, height: 60))
        }.cgImage)
        let scale = min(1.5, window.screen.scale)
        let resizedImage = CIImage(cgImage: bitmap).transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let resized = try XCTUnwrap(CIContext().createCGImage(resizedImage, from: resizedImage.extent))
        surface.capture = {
            return .init(region: surface.frame, profile: .init(frame: surface.frame, fullStrengthY: 120),
                scale: scale, planes: [.bitmap(resized)])
        }
        surface.configure(amount: 1 / 80.0, mask: nil)
        surface.layoutIfNeeded()
        surface.requestOutputSnapshot()
        try await waitUntil { surface.capturedOutput != nil && surface.gpuCompletedFrames > 3 }
        let image = try XCTUnwrap(surface.capturedOutput)
        let exported = CIImage(cgImage: image)
        let context = CIContext()
        func pixel(topY: CGFloat) -> [Int] {
            var bytes = [UInt8](repeating: 0, count: 4)
            bytes.withUnsafeMutableBytes {
                context.render(exported, toBitmap: $0.baseAddress!, rowBytes: 4,
                    bounds: CGRect(x: CGFloat(image.width) / 2, y: CGFloat(image.height) - topY * scale - 1,
                        width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            }
            return bytes.map(Int.init)
        }
        XCTAssertGreaterThan(pixel(topY: 10)[0], 240, "Read the actual GPU drawable, not a separate Core Image re-render")
        XCTAssertGreaterThan(pixel(topY: 110)[2], 240)
        let visibleTop = try backdropPixel(window, at: CGPoint(x: 50, y: 10))
        let visibleBottom = try backdropPixel(window, at: CGPoint(x: 50, y: 110))
        XCTAssertGreaterThan(visibleTop[0], 240)
        XCTAssertGreaterThan(visibleBottom[2], 240)
        XCTAssertLessThanOrEqual(surface.maximumInFlight, 2)
        XCTAssertGreaterThan(surface.maximumInFlight, 0)
        XCTAssertTrue(surface.hasRenderedOutput)
        XCTAssertNil(surface.layer.contents, "Production display must avoid a per-frame CPU image roundtrip")
        XCTAssertTrue(surface.diagnosticText.contains("Metal 直出"))
        let completed = surface.renderedFrames
        surface.stop()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(surface.renderedFrames, completed)
        XCTAssertFalse(surface.hasRenderedOutput)
    }

    func testEncodedBlurDoesNotWaitForTheMainActorToSubmit() async throws {
        _ = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let window = try playbackWindow()
        let surface = ImmersiveLiveBlurSurface()
        surface.frame = CGRect(x: 0, y: 0, width: 32, height: 64)
        window.rootViewController?.view.addSubview(surface)
        defer { surface.stop(); surface.removeFromSuperview(); window.isHidden = true }
        let scale = min(1.5, window.screen.scale)
        func input(_ color: CIColor) -> ImmersiveBlurInput {
            .init(region: surface.frame, profile: .init(frame: surface.frame, fullStrengthY: 0),
                scale: scale, planes: [.solid(color, frame: surface.frame)])
        }
        surface.capture = { input(.red) }
        surface.configure(amount: 1 / 80.0, mask: nil)
        surface.layoutIfNeeded()
        try await waitUntil { surface.gpuCompletedFrames > 3 }
        let completed = surface.gpuCompletedFrames
        var sampled = false
        surface.capture = {
            guard !sampled else { return nil }
            sampled = true
            // Occupy the main actor only after the immutable input is captured.
            // A tiny real GPU render must be able to submit on its serial worker,
            // even while UIKit is temporarily busy with unrelated work.
            DispatchQueue.main.async { Thread.sleep(forTimeInterval: 0.3) }
            return input(.green)
        }
        surface.requestOutputSnapshot()
        try await waitUntil { surface.gpuCompletedFrames > completed && surface.capturedOutput != nil }
        let timing = XCTAttachment(string: "encodedToCommitMilliseconds=\(surface.lastCommitWaitMilliseconds)\nmaximumInFlight=\(surface.maximumInFlight)")
        timing.name = "Blur GPU submission under main-actor load"
        timing.lifetime = .keepAlways
        add(timing)
        XCTAssertLessThan(surface.lastCommitWaitMilliseconds, 200,
            "An encoded blur must not wait behind a 300ms main-actor task before GPU submission")
        let output = try XCTUnwrap(surface.capturedOutput)
        var bytes = [UInt8](repeating: 0, count: 4)
        bytes.withUnsafeMutableBytes {
            CIContext().render(CIImage(cgImage: output), toBitmap: $0.baseAddress!, rowBytes: 4,
                bounds: CGRect(x: 8, y: 8, width: 1, height: 1), format: .RGBA8,
                colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        }
        XCTAssertGreaterThan(bytes[1], 240, "Verify the actual submitted GPU frame, rather than only a timing counter")
        XCTAssertLessThan(bytes[0], 10)
        XCTAssertLessThanOrEqual(surface.maximumInFlight, 2)
    }

    func testReconfigurationKeepsSubmittedBlurAvailableWhenBackgrounding() async throws {
        _ = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let window = try playbackWindow()
        let surface = ImmersiveLiveBlurSurface()
        surface.frame = CGRect(x: 0, y: 0, width: 32, height: 64)
        window.rootViewController?.view.addSubview(surface)
        defer { surface.stop(); surface.removeFromSuperview(); window.isHidden = true }
        let scale = min(1.5, window.screen.scale)
        func input(_ color: CIColor) -> ImmersiveBlurInput {
            .init(region: surface.frame, profile: .init(frame: surface.frame, fullStrengthY: 0),
                scale: scale, planes: [.solid(color, frame: surface.frame)])
        }
        surface.capture = { input(.red) }
        surface.configure(amount: 1 / 80.0, mask: nil)
        surface.layoutIfNeeded()
        try await waitUntil { surface.gpuCompletedFrames > 3 }
        var sampled = false
        var backgrounded = false
        surface.capture = {
            guard !sampled else { return nil }
            sampled = true
            DispatchQueue.main.async {
                // Let the real worker submit while completion delivery waits
                // behind UIKit. Reconfiguration must not forget that command.
                Thread.sleep(forTimeInterval: 0.3)
                surface.configure(amount: 2 / 80.0, mask: nil)
                NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)
                XCTAssertGreaterThan(surface.lastBackgroundScheduledSubmissionCount, 0,
                    "Backgrounding must schedule committed work even after configuration invalidates its output")
                XCTAssertFalse(surface.hasRenderedOutput, "Retired composition must stay hidden")
                NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
                backgrounded = true
            }
            return input(.green)
        }
        try await waitUntil { backgrounded }
        // Resume through the same production capture and GPU output boundary.
        surface.capture = { input(.blue) }
        surface.requestOutputSnapshot()
        try await waitUntil { surface.capturedOutput != nil && surface.hasRenderedOutput }
        let output = try XCTUnwrap(surface.capturedOutput)
        var bytes = [UInt8](repeating: 0, count: 4)
        bytes.withUnsafeMutableBytes {
            CIContext().render(CIImage(cgImage: output), toBitmap: $0.baseAddress!, rowBytes: 4,
                bounds: CGRect(x: 8, y: 8, width: 1, height: 1), format: .RGBA8,
                colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        }
        XCTAssertGreaterThan(bytes[2], 240, "Resume must present the current input, never the retired green frame")
        XCTAssertLessThan(bytes[1], 10)
        XCTAssertLessThanOrEqual(surface.maximumInFlight, 2)
    }

    func testUnattachedConfigurationCannotRetireVisibleImmersivePlayer() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "artwork-layer-order", withExtension: "mp4"))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previousKeyWindow = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        let frames = ArtworkReflectionFrames()
        let visible = ImmersiveArtworkMedia.Surface(frames: frames)
        visible.frame = window.bounds
        window.rootViewController?.view.addSubview(visible)
        let preflight = ImmersiveArtworkMedia.Surface(frames: frames)
        defer {
            preflight.stop(); visible.stop(); visible.removeFromSuperview()
            window.isHidden = true; previousKeyWindow?.makeKey()
        }
        var tuning = ImmersiveArtworkDebugConfiguration()
        tuning[.transition].enabled = false
        tuning[.bottomFade].enabled = false
        let rect = CGRect(x: 0, y: 0, width: 128, height: 400)
        let layout = ImmersiveArtworkMedia.Layout(video: rect,
            reflection: ArtworkReflectionGeometry.frame(cover: rect, viewportHeight: window.bounds.height),
            transition: .zero, bottomFade: .zero, tuning: tuning,
            presentsFrame: true, reflectionEnabled: true, reduceTransparency: false)
        let video = AnimatedArtwork(url: url, active: true)
        visible.configure(video: video, layout: layout)
        visible.layoutIfNeeded()
        try await waitUntil { frames.hasFrame && frames.primaryFrameReady }
        let player = try XCTUnwrap((visible.videoSurface.layer as? AVPlayerLayer)?.player)
        let source = frames.sessionDiagnostic
        let received = frames.receivedFrames
        // SwiftUI configures native views before attachment. A size/preflight
        // instance sharing this page's frame hub must not become its producer.
        preflight.configure(video: video, layout: layout)
        ImmersiveArtworkMedia.dismantleUIView(preflight, coordinator: ())
        visible.configure(video: video, layout: layout)
        XCTAssertEqual(frames.sessionDiagnostic, source)
        XCTAssertTrue(frames.primaryFrameReady, frames.diagnosticText)
        XCTAssertTrue(frames.outputAttached, frames.diagnosticText)
        XCTAssertTrue(frames.surface === visible.reflectionSurface)
        XCTAssertNotNil(player.currentItem, "The on-screen video must not be stopped by an unattached view")
        XCTAssertEqual(player.rate, 1)
        try await waitUntil {
            frames.receivedFrames > received + 3 && visible.reflectionSurface.layer.contents != nil
        }
        XCTAssertNotNil(visible.reflectionSurface.layer.contents)
    }

    func testConfigurationBeforeAttachmentStartsAfterLayoutWithoutAnotherUpdate() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "artwork-layer-order", withExtension: "mp4"))
        let frames = ArtworkReflectionFrames()
        let surface = ImmersiveArtworkMedia.Surface(frames: frames)
        let window = try playbackWindow()
        defer { surface.stop(); surface.removeFromSuperview(); window.isHidden = true }
        var firstFrame = false
        var tuning = ImmersiveArtworkDebugConfiguration()
        tuning[.transition].enabled = false
        tuning[.bottomFade].enabled = false
        let rect = CGRect(x: 0, y: 0, width: 128, height: 400)
        let layout = ImmersiveArtworkMedia.Layout(video: rect,
            reflection: ArtworkReflectionGeometry.frame(cover: rect, viewportHeight: window.bounds.height),
            transition: .zero, bottomFade: .zero, tuning: tuning,
            presentsFrame: true, reflectionEnabled: true, reduceTransparency: false)
        surface.configure(video: AnimatedArtwork(url: url, active: false), layout: layout)
        surface.configure(video: AnimatedArtwork(url: url, active: true,
            onFirstFrame: { _, _ in firstFrame = true }), layout: layout)
        XCTAssertNil(frames.producerIdentifier)
        XCTAssertFalse(frames.outputAttached)
        window.rootViewController?.view.addSubview(surface)
        XCTAssertNil(frames.producerIdentifier, "A zero-size view is still a pending presentation")
        surface.frame = window.bounds
        surface.layoutIfNeeded()
        try await waitUntil { firstFrame && frames.hasFrame && surface.reflectionSurface.layer.contents != nil }
        XCTAssertTrue(frames.primaryFrameReady)
        XCTAssertTrue(frames.producerBindingValid)
        let player = try XCTUnwrap((surface.videoSurface.layer as? AVPlayerLayer)?.player)
        XCTAssertEqual(player.rate, 1, "Attachment must commit the latest active input, not the earlier paused input")
    }

    func testDismantledPreflightCannotStartWhenAttachedLater() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "artwork-layer-order", withExtension: "mp4"))
        let frames = ArtworkReflectionFrames()
        let surface = ImmersiveArtworkMedia.Surface(frames: frames)
        let window = try playbackWindow()
        defer { surface.stop(); surface.removeFromSuperview(); window.isHidden = true }
        let rect = CGRect(x: 0, y: 0, width: 128, height: 400)
        let layout = ImmersiveArtworkMedia.Layout(video: rect, reflection: .zero,
            transition: .zero, bottomFade: .zero, tuning: .init(), presentsFrame: false,
            reflectionEnabled: false, reduceTransparency: false)
        surface.configure(video: AnimatedArtwork(url: url, active: true), layout: layout)
        ImmersiveArtworkMedia.dismantleUIView(surface, coordinator: ())
        surface.frame = window.bounds
        window.rootViewController?.view.addSubview(surface)
        surface.configure(video: AnimatedArtwork(url: url, active: true), layout: layout)
        surface.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNil((surface.videoSurface.layer as? AVPlayerLayer)?.player?.currentItem)
        XCTAssertFalse(frames.outputAttached)
        XCTAssertNil(frames.producerIdentifier)
        XCTAssertNil(frames.surface)
    }

    func testVisibleVideoReportsFirstFrameAndKeepsPlayingWithoutAuxiliaryFrameSession() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "artwork-layer-order", withExtension: "mp4"))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previousKeyWindow = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        let frames = ArtworkReflectionFrames()
        let surface = ImmersiveArtworkMedia.Surface(frames: frames)
        surface.frame = window.bounds
        window.rootViewController?.view.addSubview(surface)
        defer {
            surface.stop(); surface.removeFromSuperview(); window.isHidden = true
            previousKeyWindow?.makeKey()
        }
        var firstFrame = false
        var states: [ArtworkPlaybackState] = []
        var tuning = ImmersiveArtworkDebugConfiguration()
        tuning[.transition].enabled = false
        tuning[.bottomFade].enabled = false
        let rect = CGRect(x: 0, y: 0, width: 128, height: 400)
        surface.configure(video: AnimatedArtwork(url: url, active: true,
            onState: { _, state in states.append(state) }, onFirstFrame: { _, _ in firstFrame = true }),
            layout: .init(video: rect, reflection: .zero, transition: .zero, bottomFade: .zero,
                tuning: tuning, presentsFrame: false, reflectionEnabled: false, reduceTransparency: false))
        // Inject an auxiliary receiver-generation gap before readiness. The
        // current native presentation and its real AVPlayer remain unchanged.
        _ = frames.begin()
        let layer = try XCTUnwrap(surface.videoSurface.layer as? AVPlayerLayer)
        let player = try XCTUnwrap(layer.player)
        try await waitUntil { layer.isReadyForDisplay }
        try await waitUntil { firstFrame && states.contains(.displayed) && player.currentTime().seconds > 0 }
        XCTAssertTrue(firstFrame, "A failed reflection source must not block the page's real video-first-frame callback")
        XCTAssertTrue(states.contains(.displayed))
        XCTAssertTrue(frames.primaryFrameReady)
        XCTAssertFalse(frames.producerBindingValid)
        XCTAssertFalse(frames.hasFrame, "This case deliberately leaves the auxiliary source invalid")
        XCTAssertEqual(player.rate, 1)
        XCTAssertGreaterThan(player.currentTime().seconds, 0)
    }

    func testExplicitConfigurationRestoresPausedReflectionWithoutRestartingVideo() async throws {
        try await verifyPausedReflectionRecovery(playerOutput: true)
    }

    func testExplicitConfigurationPreservesItemOutputAfterProlongedReceiverLoss() async throws {
        try await verifyPausedReflectionRecovery(playerOutput: false)
    }

    private func verifyPausedReflectionRecovery(playerOutput: Bool) async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "artwork-layer-order", withExtension: "mp4"))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previousKeyWindow = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        let frames = ArtworkReflectionFrames()
        let surface = ImmersiveArtworkMedia.Surface(frames: frames)
        surface.frame = window.bounds
        window.rootViewController?.view.addSubview(surface)
        defer {
            surface.stop(); surface.removeFromSuperview(); window.isHidden = true
            previousKeyWindow?.makeKey()
        }
        var tuning = ImmersiveArtworkDebugConfiguration()
        tuning[.transition].enabled = false
        tuning[.bottomFade].enabled = false
        let rect = CGRect(x: 0, y: 0, width: 128, height: 400)
        let layout = ImmersiveArtworkMedia.Layout(video: rect,
            reflection: ArtworkReflectionGeometry.frame(cover: rect, viewportHeight: 650),
            transition: .zero, bottomFade: .zero, tuning: tuning, presentsFrame: true,
            reflectionEnabled: true, reduceTransparency: false)
        let video = AnimatedArtwork(url: url, active: false)
        surface.configure(video: video, layout: layout)
        if playerOutput { surface.videoSurface.usePlayerLevelFrameOutput() }
        surface.layoutIfNeeded()
        try await waitUntil { frames.primaryFrameReady && frames.videoDisplayed
            && frames.hasFrame && surface.reflectionSurface.layer.contents != nil }
        let playerLayer = try XCTUnwrap(surface.videoSurface.layer as? AVPlayerLayer)
        let player = try XCTUnwrap(playerLayer.player)
        let item = try XCTUnwrap(player.currentItem)
        let output = player.videoOutput
        let itemOutput = item.outputs.first
        XCTAssertTrue(playerOutput ? output != nil : itemOutput != nil)
        let displayedBeforeInvalidation = frames.videoDisplayed
        _ = frames.begin()
        XCTAssertFalse(frames.hasFrame)
        XCTAssertFalse(frames.producerBindingValid, "A paused source invalidation must be visible without another display tick")
        XCTAssertEqual(frames.videoDisplayed, displayedBeforeInvalidation,
            "Invalidating auxiliary pixels must preserve primary display metadata; live layer readiness updates asynchronously")
        if !playerOutput {
            // This interval is receiver downtime, not decoder starvation.
            // Restoring it must not replace the healthy item-level output.
            try await Task.sleep(for: .milliseconds(1200))
        }
        surface.configure(video: video, layout: layout)
        try await waitUntil { frames.receivedFrames > 0 && surface.reflectionSurface.layer.contents != nil }
        XCTAssertTrue(player.currentItem === item, "Repair the receiver binding without rebuilding the video queue")
        XCTAssertTrue(player.videoOutput === output, "Reuse the existing decoder output")
        if !playerOutput {
            XCTAssertTrue(item.outputs.first === itemOutput)
            XCTAssertEqual(frames.frameOutputSwitches, 0)
        }
        XCTAssertEqual(player.rate, 0, "Recovering a paused reflection cannot start the video")
        XCTAssertTrue(frames.hasFrame)
        XCTAssertTrue(frames.producerBindingValid)
        XCTAssertEqual(frames.rejectedFrames, 0)
    }

    func testFailureStateCallbackCanReplaceResourceWithoutClearingNewSession() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "artwork-layer-order", withExtension: "mp4"))
        let cachedURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        try FileManager.default.copyItem(at: url, to: cachedURL)
        defer { try? FileManager.default.removeItem(at: cachedURL) }
        let frames = ArtworkReflectionFrames()
        let surface = ImmersiveArtworkMedia.Surface(frames: frames)
        let window = try playbackWindow()
        surface.frame = window.bounds
        window.rootViewController?.view.addSubview(surface)
        defer { surface.stop(); surface.removeFromSuperview(); window.isHidden = true }
        let rect = CGRect(x: 0, y: 0, width: 128, height: 400)
        let layout = ImmersiveArtworkMedia.Layout(video: rect, reflection: .zero,
            transition: .zero, bottomFade: .zero, tuning: .init(), presentsFrame: false,
            reflectionEnabled: false, reduceTransparency: false)
        var replacementConfigured = false
        var oldFailures = 0
        var replacementFailures = 0
        surface.videoSurface.prepareAudio = { throw NSError(domain: "AMLL.Test.AudioPreparation", code: 1) }
        surface.configure(video: AnimatedArtwork(url: url, active: false,
            onFailure: { _, _ in oldFailures += 1 }, onState: { _, state in
                guard state == .failed else { return }
                surface.videoSurface.prepareAudio = {}
                surface.configure(video: AnimatedArtwork(url: cachedURL, active: false,
                    onFailure: { _, _ in replacementFailures += 1 }), layout: layout)
                replacementConfigured = true
            }), layout: layout)
        try await waitUntil { replacementConfigured }
        XCTAssertTrue(frames.outputAttached, "The obsolete failure must not clear the replacement output")
        XCTAssertTrue(frames.surface === surface.reflectionSurface)
        XCTAssertEqual(oldFailures, 0)
        XCTAssertEqual(replacementFailures, 0, "An old URL must not be sent to the replacement failure handler")
        let player = try XCTUnwrap((surface.videoSurface.layer as? AVPlayerLayer)?.player)
        XCTAssertNotNil(player.currentItem)
        XCTAssertEqual(player.rate, 0)
    }

    func testRetiredAudioSetupFailureCannotInvalidateReplacementPresentation() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "artwork-layer-order", withExtension: "mp4"))
        let frames = ArtworkReflectionFrames()
        let retired = ImmersiveArtworkMedia.Surface(frames: frames)
        let current = ImmersiveArtworkMedia.Surface(frames: frames)
        let window = try playbackWindow()
        retired.frame = window.bounds
        current.frame = window.bounds
        window.rootViewController?.view.addSubview(retired)
        window.rootViewController?.view.addSubview(current)
        defer {
            retired.stop(); current.stop(); retired.removeFromSuperview(); current.removeFromSuperview()
            window.isHidden = true
        }
        let rect = CGRect(x: 0, y: 0, width: 128, height: 400)
        let layout = ImmersiveArtworkMedia.Layout(video: rect, reflection: .zero,
            transition: .zero, bottomFade: .zero, tuning: .init(), presentsFrame: false,
            reflectionEnabled: false, reduceTransparency: false)
        var oldFailures = 0
        var oldStates: [ArtworkPlaybackState] = []
        let error = NSError(domain: "AMLL.Test.AudioPreparation", code: 1)
        retired.videoSurface.prepareAudio = { throw error }
        retired.configure(video: AnimatedArtwork(url: url, active: false,
            onFailure: { _, _ in oldFailures += 1 }, onState: { _, state in oldStates.append(state) }), layout: layout)
        // Take over before the main-actor setup-failure callback can execute.
        current.configure(video: AnimatedArtwork(url: url, active: false), layout: layout)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(oldFailures, 0)
        XCTAssertFalse(oldStates.contains(.failed))
        XCTAssertTrue(frames.liveBlurSurface === current.transitionSurface)
        XCTAssertTrue(frames.outputAttached)

        var currentFailures = 0
        var currentStates: [ArtworkPlaybackState] = []
        current.stop()
        current.videoSurface.prepareAudio = { throw error }
        current.configure(video: AnimatedArtwork(url: url, active: false,
            onFailure: { _, _ in currentFailures += 1 }, onState: { _, state in currentStates.append(state) }), layout: layout)
        try await waitUntil { currentFailures == 1 }
        XCTAssertTrue(currentStates.contains(.failed), "The active presentation must still report a real setup failure")
    }

    func testRetiredPresentationCannotInvalidateCurrentPlayersReflection() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "artwork-layer-order", withExtension: "mp4"))
        let cachedURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        try FileManager.default.copyItem(at: url, to: cachedURL)
        defer { try? FileManager.default.removeItem(at: cachedURL) }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previousKeyWindow = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        let controller = UIViewController()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        let frames = ArtworkReflectionFrames()
        let retired = ImmersiveArtworkMedia.Surface(frames: frames)
        let current = ImmersiveArtworkMedia.Surface(frames: frames)
        retired.frame = window.bounds
        current.frame = window.bounds
        controller.view.addSubview(retired)
        defer {
            retired.stop(); current.stop()
            retired.removeFromSuperview(); current.removeFromSuperview()
            window.isHidden = true; previousKeyWindow?.makeKey()
        }
        let rect = CGRect(x: 0, y: 0, width: 128, height: 400)
        var tuning = ImmersiveArtworkDebugConfiguration()
        tuning[.transition].enabled = false
        tuning[.bottomFade].enabled = false
        let layout = ImmersiveArtworkMedia.Layout(video: rect,
            reflection: ArtworkReflectionGeometry.frame(cover: rect, viewportHeight: 650),
            transition: AMLLImmersiveArtworkGeometry.transitionFrame(video: rect, viewportHeight: 650),
            bottomFade: .zero, tuning: tuning, presentsFrame: true,
            reflectionEnabled: true, reduceTransparency: false)
        retired.configure(video: AnimatedArtwork(url: url, active: true), layout: layout)
        retired.layoutIfNeeded()
        try await waitUntil { frames.hasFrame }
        controller.view.addSubview(current)
        current.configure(video: AnimatedArtwork(url: url, active: true), layout: layout)
        current.layoutIfNeeded()
        let playerLayer = try XCTUnwrap(current.videoSurface.layer as? AVPlayerLayer)
        try await waitUntil { playerLayer.isReadyForDisplay && frames.hasFrame && current.reflectionSurface.layer.contents != nil }
        let accepted = frames.receivedFrames
        XCTAssertTrue(playerLayer.isReadyForDisplay)

        // A retired SwiftUI presentation can receive the cached resource update
        // before its delayed dismantle. It must not steal the current session.
        retired.configure(video: AnimatedArtwork(url: cachedURL, active: true), layout: layout)
        retired.stop()
        retired.removeFromSuperview()
        XCTAssertTrue(frames.hasFrame, "Retired resource updates must preserve the current video pixels")
        XCTAssertTrue(frames.outputAttached, "Retired teardown must not clear the current output state")
        XCTAssertTrue(frames.liveBlurSurface === current.transitionSurface, "Retired teardown cannot detach the current blur receiver")
        try await waitUntil { frames.receivedFrames > accepted + 3 }
        XCTAssertTrue(playerLayer.isReadyForDisplay, "The real player can remain visible while its frames are rejected")
        XCTAssertNotNil(current.reflectionSurface.layer.contents, frames.diagnosticText)
        XCTAssertTrue(frames.surface === current.reflectionSurface)
        XCTAssertEqual(frames.rejectedFrames, 0)
        let session = frames.sessionDiagnostic
        tuning[.transition].enabled = true
        current.configure(video: AnimatedArtwork(url: url, active: true), layout: .init(video: rect,
            reflection: layout.reflection, transition: layout.transition, bottomFade: .zero,
            tuning: tuning, presentsFrame: true, reflectionEnabled: true, reduceTransparency: false))
        current.layoutIfNeeded()
        try await waitUntil { current.transitionSurface.renderedFrames > 0 && frames.blurInputs.contains("完整视频") }
        XCTAssertEqual(frames.sessionDiagnostic, session, "Changing effect settings must preserve the frame session")
        XCTAssertFalse(frames.blurWaitingForVideoFrame)

        // The current presentation may legitimately replace an online identity
        // with its cached identity. Only that replacement gets a new source.
        current.configure(video: AnimatedArtwork(url: cachedURL, active: false), layout: layout)
        current.layoutIfNeeded()
        try await waitUntil { playerLayer.isReadyForDisplay && frames.hasFrame && current.reflectionSurface.layer.contents != nil }
        XCTAssertNotEqual(frames.sessionDiagnostic, session)
        XCTAssertEqual(playerLayer.player?.rate, 0)
        retired.configure(video: AnimatedArtwork(url: url, active: true), layout: layout)
        retired.stop()
        XCTAssertTrue(frames.hasFrame)
        XCTAssertTrue(frames.outputAttached)
        XCTAssertEqual(frames.rejectedFrames, 0)
    }

    func testRealVideoAndBackgroundAreBothBlurredAtTheirJunction() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "artwork-layer-order", withExtension: "mp4"))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previousKeyWindow = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        let frames = ArtworkReflectionFrames()
        let surface = ImmersiveArtworkMedia.Surface(frames: frames)
        surface.frame = CGRect(x: 0, y: 0, width: 200, height: 650)
        window.rootViewController?.view.addSubview(surface)
        defer {
            surface.stop(); surface.removeFromSuperview(); window.isHidden = true
            previousKeyWindow?.makeKey()
        }
        surface.backgroundSurface.backgroundColor = .blue
        var tuning = ImmersiveArtworkDebugConfiguration()
        for kind in [ImmersiveArtworkLayer.reflection, .dimming, .bottomFade] { tuning[kind].enabled = false }
        tuning.blurRadius = 24
        let video = AnimatedArtwork(url: url, active: false)
        let rect = CGRect(x: 0, y: 0, width: 128, height: 400)
        let transition = AMLLImmersiveArtworkGeometry.transitionFrame(video: rect, viewportHeight: 650)
        func configure() {
            surface.configure(video: video, layout: .init(video: rect, reflection: .zero, transition: transition,
                bottomFade: .zero, tuning: tuning, presentsFrame: true, reflectionEnabled: false, reduceTransparency: false))
            surface.layoutIfNeeded()
        }
        configure()
        try await waitUntil { frames.hasFrame && surface.transitionSurface.renderedFrames > 3 }
        surface.transitionSurface.requestOutputSnapshot()
        try await waitUntil { surface.transitionSurface.capturedOutput != nil }
        let image = try XCTUnwrap(surface.transitionSurface.capturedOutput)
        let filtered = CIImage(cgImage: image)
        let context = CIContext()
        func pixel(x: CGFloat, y: CGFloat) -> [Int] {
            let scale = CGFloat(image.width) / transition.width
            var bytes = [UInt8](repeating: 0, count: 4)
            bytes.withUnsafeMutableBytes { storage in
                context.render(filtered, toBitmap: storage.baseAddress!, rowBytes: 4,
                    bounds: CGRect(x: x * scale, y: CGFloat(image.height) - (y - transition.minY) * scale - 1,
                        width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            }
            return bytes.map(Int.init)
        }
        let videoPixel = pixel(x: 12, y: 360)
        XCTAssertGreaterThan(videoPixel[0], 60, "The blurred image must contain the actual red video stripe, not only blue background")
        let junction = pixel(x: 12, y: 404)
        XCTAssertGreaterThan(junction[0], 10, "Video color must soften into the background across the junction")
        XCTAssertGreaterThan(junction[2], 10, "The junction must also include the blue background")
        XCTAssertLessThanOrEqual(surface.transitionSurface.maximumInFlight, 2)
        let screenVideo = try backdropPixel(window, at: CGPoint(x: 12, y: 360))
        let screenBackground = try backdropPixel(window, at: CGPoint(x: 12, y: 620))
        XCTAssertGreaterThan(screenVideo[0], 60, "The actual GPU view must keep the video above its background")
        XCTAssertGreaterThan(screenBackground[2], screenBackground[0] + 30)
        // Reproduce an output-generation gap while the actual AVPlayerLayer
        // still displays its frame. A partial background clone is not a blur.
        _ = frames.begin()
        let before = surface.transitionSurface.renderedFrames
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(frames.hasFrame)
        XCTAssertEqual(surface.transitionSurface.renderedFrames, before)
        XCTAssertNil(surface.transitionSurface.layer.contents,
            "Never publish a background-only image over a visible video whose pixels are missing")
        XCTAssertFalse(surface.transitionSurface.hasRenderedOutput)
    }

    func testUpwardFadeReducesBlurRadiusWithoutFadingTheLayer() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previousKeyWindow = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        let surface = ImmersiveArtworkMedia.Surface(frames: ArtworkReflectionFrames())
        surface.frame = CGRect(x: 0, y: 0, width: 200, height: 650)
        window.rootViewController?.view.addSubview(surface)
        defer {
            surface.stop(); surface.removeFromSuperview(); window.isHidden = true
            previousKeyWindow?.makeKey()
        }
        for index in 0 ..< 25 {
            let stripe = UIView(frame: CGRect(x: index * 8, y: 0, width: 8, height: 650))
            stripe.backgroundColor = index.isMultiple(of: 2) ? .white : .black
            surface.backgroundSurface.addSubview(stripe)
        }
        var tuning = ImmersiveArtworkDebugConfiguration()
        for kind in [ImmersiveArtworkLayer.reflection, .dimming, .bottomFade] { tuning[kind].enabled = false }
        tuning.blurRadius = 40
        tuning.topFeatherLength = 0 // This case isolates the radius-only gradient.
        let video = AnimatedArtwork(url: URL(fileURLWithPath: "/no-video-required.mp4"), active: false)
        func apply() {
            surface.configure(video: video, layout: .init(video: CGRect(x: 0, y: 0, width: 128, height: 400),
                reflection: .zero, transition: CGRect(x: 0, y: 180, width: 200, height: 470), bottomFade: .zero,
                tuning: tuning, presentsFrame: true, reflectionEnabled: false, reduceTransparency: false))
            surface.layoutIfNeeded()
        }
        apply()
        XCTAssertEqual(surface.transitionSurface.alpha, 1)
        XCTAssertNil(surface.transitionSurface.mask, "The radius gradient must not also fade the image's opacity")
        try await waitUntil { surface.transitionSurface.renderedFrames > 3 }
        let upper = try backdropVariance(window, y: 190)
        let middle = try backdropVariance(window, y: 290)
        XCTAssertGreaterThan(upper, 1000)
        XCTAssertLessThan(middle, upper * 0.15,
            "The middle must be the radius-blurred backdrop, without sharp pixels from a second opacity ramp")
        tuning[.transition].opacity = 0.4
        apply()
        let opacityMask = try XCTUnwrap((surface.transitionSurface.mask as? UIImageView)?.image)
        let context = CIContext()
        let mask = try XCTUnwrap(CIImage(image: opacityMask))
        func alpha(y: CGFloat) -> Int {
            var bytes = [UInt8](repeating: 0, count: 4)
            bytes.withUnsafeMutableBytes { storage in
                context.render(mask, toBitmap: storage.baseAddress!, rowBytes: 4,
                    bounds: CGRect(x: 64, y: y, width: 1, height: 1), format: .RGBA8,
                    colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            }
            return Int(bytes[3])
        }
        XCTAssertEqual(Double(alpha(y: 10)), 102, accuracy: 1)
        XCTAssertEqual(Double(alpha(y: 400)), 102, accuracy: 1,
            "The explicit debug opacity is uniform and independent of the blur fade")
    }

    func testLiveBlurSamplesEveryVisibleLowerPlaneAndKeepsHigherPlanesSharp() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previousKeyWindow = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        let surface = ImmersiveArtworkMedia.Surface(frames: ArtworkReflectionFrames())
        surface.frame = CGRect(x: 0, y: 0, width: 200, height: 650)
        window.rootViewController?.view.addSubview(surface)
        defer {
            surface.stop(); surface.removeFromSuperview(); window.isHidden = true
            previousKeyWindow?.makeKey()
        }
        surface.backgroundSurface.backgroundColor = .blue
        var tuning = ImmersiveArtworkDebugConfiguration()
        for kind in [ImmersiveArtworkLayer.video, .reflection, .dimming, .bottomFade] { tuning[kind].enabled = false }
        tuning.blurRadius = 24
        surface.configure(video: AnimatedArtwork(url: URL(fileURLWithPath: "/unused.mp4"), active: false),
            layout: .init(video: .zero, reflection: .zero, transition: surface.bounds, bottomFade: .zero,
                tuning: tuning, presentsFrame: false, reflectionEnabled: false, reduceTransparency: false))
        surface.layoutIfNeeded()
        // These are actual additional sibling planes, not preselected background/video inputs.
        let lower = UIView(frame: surface.bounds)
        for index in 0 ..< 25 {
            let stripe = UIView(frame: CGRect(x: index * 8, y: 0, width: 8, height: 650))
            stripe.backgroundColor = index.isMultiple(of: 2) ? .white : .black
            lower.addSubview(stripe)
        }
        lower.layer.zPosition = surface.transitionSurface.layer.zPosition - 0.5
        surface.insertSubview(lower, belowSubview: surface.transitionSurface)
        try await waitUntil { surface.transitionSurface.renderedFrames > 3 }
        let blurred = try backdropPixel(window, at: CGPoint(x: 64, y: 460))
        XCTAssertGreaterThan(blurred[0], 60)
        XCTAssertLessThan(blurred[0], 200)
        XCTAssertEqual(Double(blurred[0]), Double(blurred[1]), accuracy: 3)
        XCTAssertEqual(Double(blurred[0]), Double(blurred[2]), accuracy: 3,
            "The new lower plane must participate; a blue background-only snapshot is incorrect")
        XCTAssertLessThan(try backdropVariance(window, y: 460), 500)
        let above = UIView(frame: CGRect(x: 0, y: 400, width: 200, height: 100))
        for index in 0 ..< 25 {
            let stripe = UIView(frame: CGRect(x: index * 8, y: 0, width: 8, height: 100))
            stripe.backgroundColor = index.isMultiple(of: 2) ? .white : .black
            above.addSubview(stripe)
        }
        above.layer.zPosition = surface.transitionSurface.layer.zPosition + 0.5
        surface.addSubview(above)
        let before = surface.transitionSurface.renderedFrames
        try await waitUntil { surface.transitionSurface.renderedFrames > before + 3 }
        XCTAssertGreaterThan(try backdropVariance(window, y: 460), 1000,
            "Content above the blur must stay sharp")
        above.layer.zPosition = surface.transitionSurface.layer.zPosition - 0.25
        let moved = surface.transitionSurface.renderedFrames
        try await waitUntil { surface.transitionSurface.renderedFrames > moved + 3 }
        XCTAssertLessThan(try backdropVariance(window, y: 460), 500,
            "Reordering real planes must affect the next live sample without rebuilding the player")
        above.isHidden = true
        lower.subviews.forEach { $0.removeFromSuperview() }
        lower.backgroundColor = .red
        let changed = surface.transitionSurface.renderedFrames
        try await waitUntil { surface.transitionSurface.renderedFrames > changed + 3 }
        let red = try backdropPixel(window, at: CGPoint(x: 64, y: 460))
        XCTAssertGreaterThan(red[0], 240)
        XCTAssertLessThan(red[2], 10, "Live updates cannot retain the hidden or previous plane's image")
    }

    func testBackgroundRemainsBlurredToTheBottomWhileTheUpperExtensionBecomesClear() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previousKeyWindow = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        let surface = ImmersiveArtworkMedia.Surface(frames: ArtworkReflectionFrames())
        surface.frame = CGRect(x: 0, y: 0, width: 200, height: 650)
        window.rootViewController?.view.addSubview(surface)
        defer {
            surface.stop(); surface.removeFromSuperview(); window.isHidden = true
            previousKeyWindow?.makeKey()
        }
        for index in 0 ..< 25 {
            let stripe = UIView(frame: CGRect(x: index * 8, y: 0, width: 8, height: 650))
            stripe.backgroundColor = index.isMultiple(of: 2) ? .white : .black
            surface.backgroundSurface.addSubview(stripe)
        }
        var tuning = ImmersiveArtworkDebugConfiguration()
        tuning[.reflection].enabled = false
        tuning[.dimming].enabled = false
        tuning.blurRadius = 24
        let videoRect = CGRect(x: 0, y: 0, width: 128, height: 400)
        let transition = CGRect(x: 0, y: 180, width: 200, height: 470)
        let video = AnimatedArtwork(url: URL(fileURLWithPath: "/no-video-required.mp4"), active: false)
        func apply(showsVideo: Bool, finalFade: Bool) {
            tuning[.video].enabled = showsVideo
            tuning[.bottomFade].enabled = finalFade
            surface.configure(video: video, layout: .init(video: videoRect, reflection: .zero,
                transition: transition, bottomFade: CGRect(x: 0, y: 300, width: 200, height: 350), tuning: tuning,
                presentsFrame: true, reflectionEnabled: false, reduceTransparency: false))
            surface.layoutIfNeeded()
        }
        apply(showsVideo: true, finalFade: true)
        try await Task.sleep(for: .milliseconds(600))
        let upper = try backdropVariance(window, y: 190)
        let background = try backdropVariance(window, y: 440)
        let bottom = try backdropVariance(window, y: 630)
        XCTAssertGreaterThan(upper, 1000, "The extension must approach the original detail at its upper edge")
        XCTAssertLessThan(background, upper * 0.15)
        XCTAssertLessThan(bottom, upper * 0.15, "Final media fade must not reveal a sharp background at the bottom")
        apply(showsVideo: true, finalFade: false)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(try backdropVariance(window, y: 630), bottom, accuracy: 100,
            "Bottom blur is independent of the media fade toggle")
        apply(showsVideo: false, finalFade: true)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(surface.transitionSurface.frame.minY, 0,
            "Without a visible video the background starts at the top and is fully blurred")
        XCTAssertLessThan(try backdropVariance(window, y: 50), upper * 0.15)
    }

    func testPureBlurCapturesTheActualMetalBackgroundWithoutTint() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previousKeyWindow = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        let surface = ImmersiveArtworkMedia.Surface(frames: ArtworkReflectionFrames())
        surface.frame = window.bounds
        window.rootViewController?.view.addSubview(surface)
        defer {
            surface.stop(); surface.removeFromSuperview(); window.isHidden = true
            previousKeyWindow?.makeKey()
        }
        let metal = MTKView(frame: surface.bounds, device: device)
        metal.framebufferOnly = true
        metal.clearColor = MTLClearColor(red: 0.15, green: 0.6, blue: 0.3, alpha: 1)
        let delegate = SolidMetalBackdrop(device: device)
        metal.delegate = delegate
        surface.backgroundSurface.addSubview(metal)
        var tuning = ImmersiveArtworkDebugConfiguration()
        for kind in [ImmersiveArtworkLayer.video, .reflection, .dimming, .bottomFade] { tuning[kind].enabled = false }
        tuning.blurRadius = 60
        surface.configure(video: AnimatedArtwork(url: URL(fileURLWithPath: "/unused.mp4"), active: false),
            layout: .init(video: .zero, reflection: .zero, transition: CGRect(x: 0, y: 100, width: 128, height: 500),
                bottomFade: .zero, tuning: tuning, presentsFrame: false, reflectionEnabled: false, reduceTransparency: false))
        metal.draw()
        try await waitUntil { surface.transitionSurface.renderedFrames > 3 }
        let raw = try backdropPixel(window, at: CGPoint(x: 160, y: 460))
        let blurred = try backdropPixel(window, at: CGPoint(x: 64, y: 460))
        XCTAssertGreaterThan(raw[1], raw[0] + 30, "The fixture must present an actual green Metal drawable")
        for channel in 0 ..< 3 { XCTAssertEqual(Double(blurred[channel]), Double(raw[channel]), accuracy: 3) }
        withExtendedLifetime(delegate) {}
    }

    private final class SolidMetalBackdrop: NSObject, MTKViewDelegate {
        let queue: any MTLCommandQueue
        init(device: any MTLDevice) { queue = device.makeCommandQueue()! }
        func mtkView(_: MTKView, drawableSizeWillChange _: CGSize) {}
        func draw(in view: MTKView) {
            guard let descriptor = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
                  let command = queue.makeCommandBuffer(), let encoder = command.makeRenderCommandEncoder(descriptor: descriptor) else { return }
            encoder.endEncoding()
            command.present(drawable)
            command.commit()
        }
    }

    func testTransitionPreservesBackdropColorAndRespondsToRepeatedStrengthChanges() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previousKeyWindow = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        let surface = ImmersiveArtworkMedia.Surface(frames: ArtworkReflectionFrames())
        surface.frame = window.bounds
        window.rootViewController?.view.addSubview(surface)
        defer {
            surface.stop(); surface.removeFromSuperview(); window.isHidden = true
            previousKeyWindow?.makeKey()
        }
        var tuning = ImmersiveArtworkDebugConfiguration()
        tuning[.video].enabled = false
        tuning[.reflection].enabled = false
        tuning[.bottomFade].enabled = false
        tuning[.dimming].enabled = false
        let video = AnimatedArtwork(url: URL(fileURLWithPath: "/no-video-needed.mp4"), active: false)
        func apply(strength: Double, enabled: Bool = true, videoEnd: CGFloat = 400) {
            tuning.blurRadius = strength
            tuning[.transition].enabled = enabled
            surface.configure(video: video, layout: .init(video: CGRect(x: 0, y: 0, width: 128, height: videoEnd),
                reflection: .zero, transition: CGRect(x: 0, y: 100, width: 128, height: 500), bottomFade: .zero,
                tuning: tuning, presentsFrame: false, reflectionEnabled: false, reduceTransparency: false))
            surface.layoutIfNeeded()
        }
        surface.backgroundSurface.backgroundColor = UIColor(red: 0.15, green: 0.6, blue: 0.3, alpha: 1)
        apply(strength: 80, enabled: false)
        try await Task.sleep(for: .milliseconds(200))
        let plain = try backdropPixel(window, at: CGPoint(x: 64, y: 460))
        apply(strength: 80)
        try await Task.sleep(for: .milliseconds(500))
        let blurredColor = try backdropPixel(window, at: CGPoint(x: 64, y: 460))
        for channel in 0 ..< 3 {
            XCTAssertEqual(Double(blurredColor[channel]), Double(plain[channel]), accuracy: 3,
                "Pure blur must not add a material tint, darkening, or saturation to uniform colors")
        }

        // A hidden video's geometry must not create a ramp in the fully blurred background.
        let firstFrame = surface.transitionSurface.frame
        XCTAssertNil(surface.transitionSurface.mask)
        apply(strength: 80, videoEnd: 160)
        XCTAssertNil(surface.transitionSurface.mask)
        XCTAssertEqual(firstFrame, surface.transitionSurface.frame, "Hidden video geometry cannot change full background blur")

        for index in 0 ..< 16 {
            let stripe = UIView(frame: CGRect(x: index * 8, y: 0, width: 8, height: 650))
            stripe.backgroundColor = index.isMultiple(of: 2) ? .white : .black
            surface.backgroundSurface.addSubview(stripe)
        }
        apply(strength: 2)
        try await Task.sleep(for: .milliseconds(500))
        let weak = try backdropVariance(window, y: 460)
        apply(strength: 60)
        try await Task.sleep(for: .milliseconds(500))
        let strong = try backdropVariance(window, y: 460)
        apply(strength: 2)
        try await Task.sleep(for: .milliseconds(500))
        let weakAgain = try backdropVariance(window, y: 460)
        XCTAssertGreaterThan(weak, strong + 300, "The live strength slider must change rendered detail")
        XCTAssertGreaterThan(weakAgain, strong + 300, "Lowering strength must undo the blur without remounting")
        XCTAssertEqual(weakAgain, weak, accuracy: max(100, weak * 0.1))
        apply(strength: 0)
        XCTAssertTrue(surface.transitionSurface.isHidden)
    }

    func testPlayerLevelOutputProducesReflectionAcrossActualLoopItems() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "artwork-layer-order", withExtension: "mp4"))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previousKeyWindow = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        let controller = UIViewController()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        let frames = ArtworkReflectionFrames()
        let surface = ImmersiveArtworkMedia.Surface(frames: frames)
        surface.frame = window.bounds
        controller.view.addSubview(surface)
        defer {
            surface.stop(); surface.removeFromSuperview(); window.isHidden = true
            previousKeyWindow?.makeKey()
        }
        let videoFrame = CGRect(x: 0, y: 0, width: 128, height: 400)
        let layout = ImmersiveArtworkMedia.Layout(video: videoFrame,
            reflection: ArtworkReflectionGeometry.frame(cover: videoFrame, viewportHeight: 650),
            transition: AMLLImmersiveArtworkGeometry.transitionFrame(video: videoFrame, viewportHeight: 650),
            bottomFade: .zero, tuning: .init(), presentsFrame: true,
            reflectionEnabled: true, reduceTransparency: false)
        surface.configure(video: AnimatedArtwork(url: url, active: false), layout: layout)
        surface.videoSurface.usePlayerLevelFrameOutput()
        surface.configure(video: AnimatedArtwork(url: url, active: false), layout: layout)
        surface.layoutIfNeeded()
        let player = try XCTUnwrap((surface.videoSurface.layer as? AVPlayerLayer)?.player)
        XCTAssertNotNil(player.videoOutput)
        XCTAssertTrue(player.currentItem?.outputs.isEmpty == true, "Keep only one frame-output path")
        try await waitUntil { frames.receivedFrames > 0 && surface.reflectionSurface.layer.contents != nil }
        XCTAssertEqual(player.rate, 0, "Player-level output must also provide a paused cover's reflection")
        let session = frames.sessionDiagnostic
        surface.configure(video: AnimatedArtwork(url: url, active: true), layout: layout)
        let firstItem = player.currentItem
        try await waitUntil { player.currentItem != nil && player.currentItem !== firstItem }
        let receivedAfterLoop = frames.receivedFrames
        try await waitUntil { frames.receivedFrames > receivedAfterLoop + 5 }
        XCTAssertGreaterThan(surface.reflectionSurface.presentedFrames, 0)
        XCTAssertNotNil(player.videoOutput, "A loop must retain the player-level output")
        XCTAssertEqual(frames.sessionDiagnostic, session, "Loop replicas must retain the resource's frame session")
        XCTAssertEqual(frames.rejectedFrames, 0)
    }

    func testPausedVideoAttachesOutputBeforePlayingAndReflectionSurvivesRemount() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "artwork-layer-order", withExtension: "mp4"))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previousKeyWindow = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        let controller = UIViewController()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        let frames = ArtworkReflectionFrames()
        let surface = ImmersiveArtworkMedia.Surface(frames: frames)
        surface.frame = window.bounds
        controller.view.addSubview(surface)
        defer {
            surface.stop(); surface.removeFromSuperview(); window.isHidden = true
            previousKeyWindow?.makeKey()
        }
        let videoFrame = CGRect(x: 0, y: 0, width: 128, height: 400)
        var tuning = ImmersiveArtworkDebugConfiguration()
        tuning[.transition].enabled = false
        tuning[.bottomFade].enabled = false
        let video = AnimatedArtwork(url: url, active: false)
        surface.configure(video: video, layout: .init(video: videoFrame,
            reflection: ArtworkReflectionGeometry.frame(cover: videoFrame, viewportHeight: 650),
            transition: AMLLImmersiveArtworkGeometry.transitionFrame(video: videoFrame, viewportHeight: 650),
            bottomFade: .zero, tuning: tuning, presentsFrame: true,
            reflectionEnabled: true, reduceTransparency: false))
        surface.layoutIfNeeded()
        let player = try XCTUnwrap((surface.videoSurface.layer as? AVPlayerLayer)?.player)
        XCTAssertEqual(player.rate, 0, "A paused cover must not start playing to obtain its reflection")
        XCTAssertEqual(player.currentItem?.outputs.compactMap { $0 as? AVPlayerItemVideoOutput }.count, 1,
            "Install the output before playback, rather than waiting for a playing display-link tick")
        try await waitUntil { frames.hasFrame && surface.reflectionSurface.layer.contents != nil }
        XCTAssertGreaterThan(frames.receivedFrames, 0)
        XCTAssertGreaterThan(surface.reflectionSurface.presentedFrames, 0)

        // A paused page may attach after its cached frame was received. It
        // must render that frame even though no more player ticks occur.
        surface.reflectionSurface.removeFromSuperview()
        surface.reflectionSurface.clear()
        let received = frames.receivedFrames
        frames.replayLatest() // Retains the frame while detached; no render yet.
        XCTAssertEqual(frames.receivedFrames, received, "Replaying the retained frame does not acquire a new decoder frame")
        XCTAssertNil(surface.reflectionSurface.layer.contents)
        surface.reflectionPlane.addSubview(surface.reflectionSurface)
        surface.layoutIfNeeded()
        try await waitUntil { surface.reflectionSurface.layer.contents != nil }
        XCTAssertEqual(player.rate, 0)
    }

    func testActualPlayerAndLiveBlurFollowSavedOrderingAndVisibility() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "artwork-layer-order", withExtension: "mp4"))
        let frames = ArtworkReflectionFrames()
        let surface = ImmersiveArtworkMedia.Surface(frames: frames)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previousKeyWindow = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        let controller = UIViewController()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        surface.frame = window.bounds
        controller.view.addSubview(surface)
        defer {
            surface.stop(); surface.removeFromSuperview(); window.isHidden = true
            previousKeyWindow?.makeKey()
        }
        let videoFrame = CGRect(x: 0, y: 0, width: 128, height: 400)
        let transition = AMLLImmersiveArtworkGeometry.transitionFrame(video: videoFrame, viewportHeight: 650)
        let reflection = ArtworkReflectionGeometry.frame(cover: videoFrame, viewportHeight: 650)
        var firstFrame = false
        let video = AnimatedArtwork(url: url, active: true, onFirstFrame: { _, _ in firstFrame = true })
        var tuning = ImmersiveArtworkDebugConfiguration()
        func configure(reflects: Bool) {
            surface.configure(video: video, layout: .init(video: videoFrame, reflection: reflection,
                transition: transition, bottomFade: AMLLImmersiveArtworkGeometry.bottomFadeFrame(video: videoFrame, viewport: window.bounds.size),
                tuning: tuning, presentsFrame: true, reflectionEnabled: reflects, reduceTransparency: false))
            surface.layoutIfNeeded()
        }
        configure(reflects: false)
        try await waitUntil { firstFrame }
        let playerLayer = try XCTUnwrap(surface.videoSurface.layer as? AVPlayerLayer)
        XCTAssertTrue(playerLayer.isReadyForDisplay)
        XCTAssertTrue(surface.transitionSurface.superview === surface)
        XCTAssertTrue(surface.videoPlane.superview === surface)
        XCTAssertTrue(surface.reflectionPlane.superview === surface)
        XCTAssertTrue(surface.reflectionSurface.superview === surface.reflectionPlane)
        XCTAssertTrue(surface.videoSurface.superview === surface.videoPlane)
        XCTAssertGreaterThan(surface.transitionSurface.layer.zPosition, surface.videoPlane.layer.zPosition)
        XCTAssertGreaterThan(surface.transitionSurface.layer.zPosition, surface.reflectionPlane.layer.zPosition)
        XCTAssertNil(surface.layer.mask, "A live backdrop must not be placed under an ancestor mask")
        XCTAssertNil(playerLayer.mask)
        XCTAssertNotNil(surface.videoPlane.mask)
        XCTAssertNotNil(surface.transitionSurface.mask, "The local upper feather must be installed without changing media fades")
        XCTAssertEqual(surface.transitionSurface.alpha, 1)
        let player = playerLayer.player
        configure(reflects: true)
        try await waitUntil { surface.reflectionSurface.layer.contents != nil }
        XCTAssertTrue(playerLayer.player === player, "Effect toggles must keep the one existing player")

        // Verify presented pixels, not just a decoded bitmap that might be
        // outside the viewport or multiplied away by several fade masks.
        tuning[.transition].enabled = false
        tuning[.bottomFade].enabled = false
        tuning[.dimming].enabled = false
        surface.backgroundSurface.backgroundColor = .black
        configure(reflects: false)
        try await Task.sleep(nanoseconds: 200_000_000)
        let withoutReflection = try backdropPixel(window, at: CGPoint(x: 64, y: 440))
        configure(reflects: true)
        try await waitUntil { surface.reflectionSurface.layer.contents != nil }
        try await Task.sleep(nanoseconds: 200_000_000)
        let withReflection = try backdropPixel(window, at: CGPoint(x: 64, y: 440))
        XCTAssertGreaterThan(zip(withReflection.prefix(3), withoutReflection.prefix(3))
            .reduce(0) { $0 + abs($1.0 - $1.1) }, 10, "Enabling reflection must change visible pixels below the video")
        tuning[.transition].enabled = true
        tuning[.bottomFade].enabled = true

        tuning.order = [.bottomFade, .video, .transition, .reflection, .dimming, .background]
        configure(reflects: true)
        XCTAssertGreaterThan(surface.videoPlane.layer.zPosition, surface.transitionSurface.layer.zPosition)
        XCTAssertTrue(surface.subviews.firstIndex(of: surface.videoPlane)! > surface.subviews.firstIndex(of: surface.transitionSurface)!)
        tuning.order = [.video, .bottomFade, .transition, .reflection, .dimming, .background]
        configure(reflects: true)
        XCTAssertNil(surface.videoPlane.mask, "Moving above the fade removes that layer's fade")
        XCTAssertNotNil(surface.reflectionPlane.mask)

        // Exercise actual compositor pixels: a hidden video and reflection must
        // not keep supplying their old colors to the visible blur.
        tuning.order = nil
        tuning[.video].enabled = false
        tuning[.reflection].enabled = false
        tuning[.dimming].enabled = false
        tuning[.bottomFade].enabled = false
        tuning.blurRadius = 80
        surface.backgroundSurface.backgroundColor = .red
        configure(reflects: false)
        XCTAssertTrue(surface.videoPlane.isHidden)
        XCTAssertTrue(surface.reflectionSurface.isHidden)
        XCTAssertFalse(surface.transitionSurface.isHidden)
        try await Task.sleep(nanoseconds: 300_000_000)
        let red = try backdropPixel(window, at: CGPoint(x: 64, y: 460))
        XCTAssertGreaterThan(red[0], red[2] + 30, "Hidden video must not leak into the red backdrop")

        // A paused/hidden video cannot prevent changes to the live background.
        surface.backgroundSurface.backgroundColor = .blue
        try await Task.sleep(nanoseconds: 300_000_000)
        let blue = try backdropPixel(window, at: CGPoint(x: 64, y: 460))
        XCTAssertGreaterThan(blue[2], blue[0] + 30, "Live blur must follow the currently visible background")
        XCTAssertTrue(playerLayer.player === player)
        XCTAssertGreaterThan(surface.transitionSurface.renderedFrames, 0, "Pure blur must render the current visible composite")

        // Pixel colors alone could pass if the effect were invisible. Verify
        // visible backdrop detail is actually blurred by the production view.
        for index in 0 ..< 16 {
            let stripe = UIView(frame: CGRect(x: index * 8, y: 0, width: 8, height: 650))
            stripe.backgroundColor = index.isMultiple(of: 2) ? .white : .black
            surface.backgroundSurface.addSubview(stripe)
        }
        tuning[.transition].enabled = false
        configure(reflects: false)
        try await Task.sleep(nanoseconds: 300_000_000)
        let sharp = try backdropVariance(window, y: 460)
        tuning[.transition].enabled = true
        configure(reflects: false)
        try await Task.sleep(nanoseconds: 300_000_000)
        let blurred = try backdropVariance(window, y: 460)
        XCTAssertGreaterThan(sharp, 1000)
        XCTAssertLessThan(blurred, sharp * 0.5, "The live effect must visibly blur the underlying stripes")
    }

    private func backdropVariance(_ window: UIWindow, y: Int) throws -> Double {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: window.bounds.size, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let cg = try XCTUnwrap(image.cgImage?.cropping(to: CGRect(x: 24, y: y, width: 80, height: 1)))
        var bytes = [UInt8](repeating: 0, count: 80 * 4)
        try bytes.withUnsafeMutableBytes { storage in
            let context = try XCTUnwrap(CGContext(data: storage.baseAddress, width: 80, height: 1, bitsPerComponent: 8,
                bytesPerRow: 80 * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(cg, in: CGRect(x: 0, y: 0, width: 80, height: 1))
        }
        let values = (0 ..< 80).map { Double(bytes[$0 * 4]) }
        let mean = values.reduce(0, +) / Double(values.count)
        return values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
    }

    private func backdropPixel(_ window: UIWindow, at point: CGPoint, attach: Bool = true) throws -> [Int] {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: window.bounds.size, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let cg = try XCTUnwrap(image.cgImage?.cropping(to: CGRect(origin: point, size: CGSize(width: 1, height: 1))))
        var bytes = [UInt8](repeating: 0, count: 4)
        try bytes.withUnsafeMutableBytes { storage in
            let context = try XCTUnwrap(CGContext(data: storage.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        if attach {
            let attachment = XCTAttachment(image: image)
            attachment.name = "Live backdrop visibility and color"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        return bytes.map(Int.init)
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0 ..< 600 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Actual video playback did not present its first frame within six seconds")
    }

    private func playbackWindow() throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = UIViewController()
        window.isHidden = false
        return window
    }
}
