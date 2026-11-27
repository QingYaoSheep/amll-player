@testable import AMLLPlayer
import AVFoundation
import MetalKit
import SwiftUI
import UIKit
import XCTest

@MainActor
final class ImmersiveArtworkMediaTests: XCTestCase {
    func testImmersiveLyricStatusBarMaskPreservesTheOriginalFeatherBelowIt() throws {
        func alpha(_ image: CGImage, profile: ImmersiveBackgroundBlurProfile, at y: CGFloat) throws -> Int {
            let row = max(0, min(image.height - 1,
                Int(((y - profile.frame.minY) / profile.frame.height * CGFloat(image.height)).rounded(.down))))
            let data = try XCTUnwrap(image.dataProvider?.data as Data?)
            return Int(data[row * 4 + 3])
        }

        let transition = ImmersiveBackgroundBlurProfile(frame: CGRect(x: 0, y: 20, width: 100, height: 300), fullStrengthY: 180)
        for profile in [transition, transition.backgroundOnly(viewportHeight: 320)] {
            let original = try XCTUnwrap(ImmersiveVariableBlurMask.make(profile: profile, topFeatherLength: 66))
            let protected = try XCTUnwrap(ImmersiveVariableBlurMask.make(
                profile: profile,
                topFeatherLength: 66,
                clearThroughY: 62
            ))
            XCTAssertGreaterThan(try alpha(original, profile: profile, at: 50), 0)
            XCTAssertEqual(try alpha(protected, profile: profile, at: 50), 0)
            for y in [CGFloat(65), 85, 200] {
                XCTAssertEqual(
                    try alpha(protected, profile: profile, at: y),
                    try alpha(original, profile: profile, at: y),
                    accuracy: 1
                )
            }
        }
    }

    func testVideoFirstFrameReplacesStillFallbackWithoutRestartingPlayer() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "artwork-layer-order", withExtension: "mp4"))
        let window = try playbackWindow()
        let surface = ImmersiveArtworkMedia.Surface()
        surface.frame = CGRect(x: 0, y: 0, width: 128, height: 400)
        window.rootViewController?.view.addSubview(surface)
        let stillURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        let image = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32)).image { context in
            UIColor.green.setFill(); context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        }
        try XCTUnwrap(image.pngData()).write(to: stillURL)
        defer { surface.stop(); surface.removeFromSuperview(); window.isHidden = true; try? FileManager.default.removeItem(at: stillURL) }
        let decoded = await ImmersiveStillArtworkCache().load(stillURL)
        let still = try XCTUnwrap(decoded)
        let cover = CGRect(x: 0, y: 0, width: 128, height: 200)
        func layout(_ ready: Bool) -> ImmersiveArtworkMedia.Layout {
            .immersive(cover: cover, viewport: CGSize(width: 128, height: 400),
                       presentsFrame: ready, reduceTransparency: false)
        }
        var presented = false
        let video = AnimatedArtwork(url: url, active: true, onFirstFrame: { _, _ in presented = true })
        surface.configure(video: video, layout: layout(false), still: still)
        surface.layoutIfNeeded()
        XCTAssertFalse(surface.stillSurface.isHidden)
        try await waitUntil { presented }
        let player = try XCTUnwrap((surface.videoSurface.layer as? AVPlayerLayer)?.player)
        let item = try XCTUnwrap(player.currentItem)
        XCTAssertTrue(surface.reflectionVideoView.playerLayer.player === player,
            "Reflection must reuse the single active AVPlayer instance")

        surface.configure(video: video, layout: layout(true), still: still)
        XCTAssertFalse(surface.stillSurface.isHidden, "Keep the poster while it fades over the first video frame")
        try await waitUntil { surface.stillSurface.isHidden }
        XCTAssertTrue((surface.videoSurface.layer as? AVPlayerLayer)?.player === player)
        XCTAssertTrue(surface.reflectionVideoView.playerLayer.player === player)
        XCTAssertEqual((player.currentItem?.asset as? AVURLAsset)?.url, (item.asset as? AVURLAsset)?.url,
            "A looper may advance its item during the fade, but the same player and resource must continue")

        surface.configure(video: nil, layout: layout(false), still: still)
        try await waitUntil { !surface.hasVideoPlayer }
        XCTAssertFalse(surface.hasVideoPlayer)
        XCTAssertNil(surface.reflectionVideoView.playerLayer.player)
        XCTAssertFalse(surface.stillSurface.isHidden)
        XCTAssertTrue(surface.reflectionStillView.image?.cgImage === still.image)
    }

    func testNativeBackdropBlurUsesCABackdropLayerAndNeutralizesSystemTint() async throws {
        let window = try playbackWindow()
        let blurView = ImmersiveBackdropBlurView()
        let profile = ImmersiveBackgroundBlurProfile(
            frame: CGRect(x: 0, y: 180, width: 200, height: 470),
            fullStrengthY: 400
        )
        blurView.frame = profile.frame
        window.rootViewController?.view.addSubview(blurView)
        defer {
            blurView.stop()
            blurView.removeFromSuperview()
            window.isHidden = true
        }

        blurView.configure(profile: profile, radius: ImmersiveArtworkPreset.blurRadius,
                           topFeatherLength: ImmersiveArtworkPreset.topFeatherLength, hidden: false)
        blurView.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(50))

        let backdropLayer = try XCTUnwrap(blurView.resolvedBackdropLayer,
            "UIVisualEffectView must expose an internal CABackdropLayer dynamically")
        for subview in blurView.subviews {
            let hostsBackdrop = Self.layerTree(subview.layer, contains: backdropLayer)
            if !hostsBackdrop {
                XCTAssertTrue(subview.isHidden, "Non-backdrop system tint overlays must be hidden")
                XCTAssertEqual(subview.alpha, 0, accuracy: 0.001)
            }
        }
        XCTAssertTrue(blurView.activeMode == .variableBlur || blurView.activeMode == .gaussianBlurFallback,
            "Expected CAFilter-driven blur mode on iOS Simulator/Device, got \(blurView.activeMode)")
        if blurView.activeMode == .variableBlur {
            XCTAssertNotNil(blurView.currentMaskImage)
            XCTAssertNil(blurView.mask)
        }

        blurView.stop()
        XCTAssertNil(blurView.currentMaskImage)
        XCTAssertTrue((backdropLayer.filters ?? []).isEmpty)
    }

    func testImmersiveSurfaceUsesFixedCalibratedFiveLayerOrderAnd60FPSBackground() async throws {
        _ = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let window = try playbackWindow()
        let surface = ImmersiveArtworkMedia.Surface()
        surface.frame = CGRect(x: 0, y: 0, width: 200, height: 430)
        window.rootViewController?.view.addSubview(surface)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        let coverImage = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32)).image { context in
            UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        }
        try XCTUnwrap(coverImage.pngData()).write(to: url)
        defer {
            surface.stop()
            surface.removeFromSuperview()
            window.isHidden = true
            try? FileManager.default.removeItem(at: url)
        }

        let still = try XCTUnwrap(await ImmersiveStillArtworkCache().load(url))
        let cover = CGRect(x: 0, y: 0, width: 200, height: 200)
        let layout = ImmersiveArtworkMedia.Layout.immersive(
            cover: cover,
            viewport: surface.bounds.size,
            presentsFrame: false,
            reduceTransparency: false
        )
        surface.configure(
            video: nil,
            layout: layout,
            background: AMLLBackground(artworkURL: url, active: true, blur: 40, mode: .mesh, preferredFramesPerSecond: 60),
            still: still
        )
        surface.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(surface.subviews.count, 5)
        XCTAssertTrue(surface.subviews[0] === surface.backgroundSurface)
        XCTAssertTrue(surface.subviews[1] === surface.dimmingSurface)
        XCTAssertTrue(surface.subviews[2] === surface.videoPlane)
        XCTAssertTrue(surface.subviews[3] === surface.reflectionPlane)
        XCTAssertTrue(surface.subviews[4] === surface.transitionSurface)

        XCTAssertFalse(surface.dimmingSurface.isHidden)
        XCTAssertEqual(surface.dimmingSurface.backgroundColor?.cgColor.alpha ?? 0,
            CGFloat(ImmersiveArtworkPreset.dimmingOpacity), accuracy: 0.01)
        XCTAssertFalse(surface.reflectionPlane.isHidden)
        XCTAssertEqual(surface.reflectionPlane.alpha, CGFloat(ImmersiveArtworkPreset.reflectionOpacity), accuracy: 0.01)
        XCTAssertTrue(surface.reflectionPlane.layer.mask is CAGradientLayer)
        XCTAssertEqual(surface.reflectionVideoView.transform.d, -1, accuracy: 0.001)
        XCTAssertEqual(surface.reflectionStillView.transform.d, -1, accuracy: 0.001)
        XCTAssertFalse(surface.transitionSurface.isHidden)

        let meshView = try XCTUnwrap(Self.findMetalView(in: surface.backgroundSurface))
        XCTAssertTrue(meshView.framebufferOnly, "Dynamic background must remain framebufferOnly=true without CPU texture copies")
        XCTAssertEqual(meshView.preferredFramesPerSecond, 60)
    }

    func testStaticCoverSuppliesReflectionAndNativeBlurWithoutCreatingAPlayer() async throws {
        let window = try playbackWindow()
        let surface = ImmersiveArtworkMedia.Surface()
        surface.frame = CGRect(x: 0, y: 0, width: 120, height: 320)
        window.rootViewController?.view.addSubview(surface)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        let image = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64)).image { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 64, height: 32))
            UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 32, width: 64, height: 32))
        }
        try XCTUnwrap(image.pngData()).write(to: url)
        defer { surface.stop(); surface.removeFromSuperview(); window.isHidden = true; try? FileManager.default.removeItem(at: url) }

        let cache = ImmersiveStillArtworkCache()
        let still = try XCTUnwrap(await cache.load(url))
        let cached = await cache.load(url)
        XCTAssertTrue(still.image === cached?.image, "Repeated updates reuse the decoded cover")

        let cover = CGRect(x: 0, y: 0, width: 120, height: 120)
        let layout = ImmersiveArtworkMedia.Layout.immersive(
            cover: cover,
            viewport: surface.bounds.size,
            presentsFrame: false,
            reduceTransparency: false
        )
        surface.configure(video: nil, layout: layout, still: still)
        surface.layoutIfNeeded()
        XCTAssertFalse(surface.hasVideoPlayer)
        XCTAssertTrue(surface.stillSurface.image?.cgImage === still.image)
        XCTAssertTrue(surface.reflectionStillView.image?.cgImage === still.image)
        XCTAssertFalse(surface.reflectionPlane.isHidden)
        XCTAssertFalse(surface.transitionSurface.isHidden)

        let upper = try backdropPixel(window, at: CGPoint(x: 60, y: 20))
        XCTAssertGreaterThan(upper[0], upper[2] + 100)
        let lower = try backdropPixel(window, at: CGPoint(x: 60, y: 100))
        XCTAssertGreaterThan(lower[2], lower[0] + 40)

        surface.configure(video: nil, layout: layout, still: still)
        XCTAssertFalse(surface.hasVideoPlayer)
        XCTAssertTrue(surface.stillSurface.image?.cgImage === still.image)
    }

    func testReduceTransparencyAndInlineLayoutHideImmersiveOnlyLayers() throws {
        let window = try playbackWindow()
        let surface = ImmersiveArtworkMedia.Surface()
        surface.frame = CGRect(x: 0, y: 0, width: 200, height: 400)
        window.rootViewController?.view.addSubview(surface)
        defer { surface.stop(); surface.removeFromSuperview(); window.isHidden = true }

        let cover = CGRect(x: 0, y: 0, width: 200, height: 200)
        surface.configure(
            video: nil,
            layout: .immersive(cover: cover, viewport: surface.bounds.size, presentsFrame: true, reduceTransparency: true)
        )
        surface.layoutIfNeeded()
        XCTAssertTrue(surface.transitionSurface.isHidden, "Reduce Transparency must disable the native variable blur surface")

        surface.configure(
            video: nil,
            layout: .inline(frame: cover, visible: true, presentsFrame: false, radius: 12)
        )
        surface.layoutIfNeeded()
        XCTAssertTrue(surface.reflectionPlane.isHidden)
        XCTAssertTrue(surface.transitionSurface.isHidden)
    }

    private static func layerTree(_ root: CALayer, contains target: CALayer) -> Bool {
        if root === target { return true }
        return root.sublayers?.contains(where: { layerTree($0, contains: target) }) ?? false
    }

    private static func findMetalView(in root: UIView) -> MTKView? {
        if let metal = root as? MTKView { return metal }
        for subview in root.subviews {
            if let found = findMetalView(in: subview) { return found }
        }
        return nil
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
        XCTFail("Condition did not complete within six seconds")
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
