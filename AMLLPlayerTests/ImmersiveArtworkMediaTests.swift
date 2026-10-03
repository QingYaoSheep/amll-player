@testable import AMLLPlayer
import AVFoundation
import UIKit
import XCTest

@MainActor
final class ImmersiveArtworkMediaTests: XCTestCase {
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
        XCTAssertNil(surface.reflectionSurface.layer.contents)
        surface.reflectionPlane.addSubview(surface.reflectionSurface)
        surface.layoutIfNeeded()
        try await waitUntil { surface.reflectionSurface.layer.contents != nil }
        XCTAssertEqual(frames.receivedFrames, received)
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
        XCTAssertNotNil(surface.transitionSurface.mask)
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

        // No new video-frame renderer is invoked when the underlying color changes.
        surface.backgroundSurface.backgroundColor = .blue
        try await Task.sleep(nanoseconds: 300_000_000)
        let blue = try backdropPixel(window, at: CGPoint(x: 64, y: 460))
        XCTAssertGreaterThan(blue[2], blue[0] + 30, "Live blur must follow the currently visible background")
        XCTAssertTrue(playerLayer.player === player)
        XCTAssertNil(surface.transitionSurface.layer.contents, "The live blur owns no retained video bitmap")

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

    private func backdropPixel(_ window: UIWindow, at point: CGPoint) throws -> [Int] {
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
        let attachment = XCTAttachment(image: image)
        attachment.name = "Live backdrop visibility and color"
        attachment.lifetime = .keepAlways
        add(attachment)
        return bytes.map(Int.init)
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0 ..< 600 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Actual video playback did not present its first frame within six seconds")
    }
}
