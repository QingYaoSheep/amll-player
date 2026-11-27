@testable import AMLLPlayer
import SwiftUI
import AVFoundation
import UIKit
import CoreImage
import XCTest

@MainActor
final class LyricsPagePresentationTests: XCTestCase {
    func testRapidHideShowCannotRetireTheLiveCanvas() {
        let state = LyricsPagePresentationCoordinator()
        state.begin(.init(showsLyrics: true, immersive: false))
        state.begin(.init(showsLyrics: false, immersive: false))
        let hiding = state.revision
        XCTAssertTrue(state.rendersArtworkControls)
        XCTAssertTrue(state.rendersLyrics, "Keep the canvas rendering throughout its outgoing fade")
        state.begin(.init(showsLyrics: true, immersive: true))
        state.finish(hiding)
        XCTAssertTrue(state.rendersLyrics, "A stale removal callback cannot deactivate a reopened canvas")
        state.finish(state.revision)
        XCTAssertTrue(state.rendersLyrics)
        XCTAssertFalse(state.rendersArtworkControls, "Invisible footer controls must leave the accessibility tree after their fade")
        XCTAssertTrue(state.mode.immersive)
    }

    func testOnlyModeChangesCreateTransactionsAndHiddenCanvasSleeps() {
        let state = LyricsPagePresentationCoordinator()
        let mode = LyricsPagePresentationCoordinator.Mode(showsLyrics: true, immersive: false)
        state.update(mode, reduceMotion: false)
        let first = state.revision
        for _ in 0 ..< 120 { state.update(mode, reduceMotion: false) }
        XCTAssertEqual(state.revision, first, "Playback snapshot refreshes must not restart presentation")
        state.update(.init(showsLyrics: false, immersive: false), reduceMotion: true)
        state.finish(state.revision)
        XCTAssertFalse(state.rendersLyrics)
        state.update(mode, reduceMotion: true)
        XCTAssertTrue(state.rendersLyrics)
    }

    func testLayoutAnimationKeepsTheOnePlayerAndHasIntermediateFrames() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        window.rootViewController = controller; window.frame = scene.coordinateSpace.bounds
        window.makeKeyAndVisible()
        let surface = ImmersiveArtworkMedia.Surface()
        surface.frame = window.bounds; controller.view.addSubview(surface)
        defer { surface.stop(); window.isHidden = true; previous?.makeKey() }
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "artwork-layer-order", withExtension: "mp4"))
        var presented = false
        let video = AnimatedArtwork(url: url, active: false, onFirstFrame: { _, _ in presented = true })
        let start = CGRect(x: 20, y: 80, width: 100, height: 100)
        let end = CGRect(x: 0, y: 0, width: 300, height: 400)
        surface.configure(video: video, layout: .inline(frame: start, visible: true, presentsFrame: false, radius: 12))
        for _ in 0 ..< 100 {
            if surface.window != nil, surface.videoPlane.frame == start { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        for _ in 0 ..< 200 {
            if (surface.videoSurface.layer as? AVPlayerLayer)?.isReadyForDisplay == true { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(30))
        let player = (surface.videoSurface.layer as? AVPlayerLayer)?.player
        XCTAssertNotNil(player)
        surface.configure(video: video, layout: .inline(frame: end, visible: true, presentsFrame: false, radius: 0),
            animation: LyricsPageMotion.geometry)
        try await Task.sleep(for: .milliseconds(70))
        let mid = try XCTUnwrap(surface.videoPlane.layer.presentation()?.frame)
        XCTAssertGreaterThan(mid.width, start.width)
        XCTAssertLessThan(mid.width, end.width)
        let mediaMid = try XCTUnwrap(surface.videoSurface.layer.presentation()?.bounds)
        XCTAssertEqual(mediaMid.width, mid.width, accuracy: 2,
            "The actual player image must scale with the animated plane instead of jumping to its destination bounds")
        XCTAssertTrue((surface.videoSurface.layer as? AVPlayerLayer)?.player === player)
        // Reverse before completion: it starts from the visible intermediate value.
        surface.configure(video: video, layout: .inline(frame: start, visible: true, presentsFrame: false, radius: 12),
            animation: LyricsPageMotion.geometry)
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(surface.videoPlane.frame, start)
        XCTAssertTrue((surface.videoSurface.layer as? AVPlayerLayer)?.player === player)
        surface.configure(video: video, layout: .inline(frame: end, visible: true, presentsFrame: false, radius: 0),
            animation: LyricsPageMotion.geometry, reduceMotion: true)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(try XCTUnwrap(surface.videoPlane.layer.presentation()?.frame).width, end.width, accuracy: 0.1,
            "Reduce Motion must not animate geometry through the content-fade fallback")

        for _ in 0 ..< 200 {
            if presented { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(presented)
        let poster = try solidFrame(red: 1, green: 0, blue: 0)
        surface.configure(video: video, layout: .immersive(cover: end, viewport: window.bounds.size,
            presentsFrame: true, reduceTransparency: false), still: poster)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(surface.reflectionVideoView.playerLayer.player === player,
            "The hardware reflection layer must share the single player instance")
        XCTAssertNotNil(surface.transitionSurface.resolvedBackdropLayer)
        XCTAssertFalse(surface.dimmingSurface.isHidden)
        XCTAssertEqual(surface.dimmingSurface.backgroundColor?.cgColor.alpha ?? 0,
            CGFloat(ImmersiveArtworkPreset.dimmingOpacity), accuracy: 0.01)
    }

    func testPageRequestsReuseReadyMediaButExplicitReloadStillChangesGeneration() async throws {
        let loader = AnimatedArtworkLoader()
        let asset = ArtworkAsset(kind: .portraitVideo, url: URL(string: "https://example.invalid/video.mp4")!, albumID: "1", storefront: "us")
        let local = URL(fileURLWithPath: "/tmp/page-video.mp4")
        await loader.load(trackID: "one", kind: .portraitVideo, assets: { [asset] }, download: { _ in local })
        let token = loader.requestToken
        loader.firstFramePresented(token: token, url: local, size: CGSize(width: 9, height: 16))
        await loader.load(trackID: "one", kind: .portraitVideo, reuseReadyResource: true,
            assets: { XCTFail("A layout change must not rediscover the same asset"); return [] }, download: { _ in local })
        XCTAssertEqual(loader.requestToken, token)
        XCTAssertTrue(loader.hasPresentedFrame)
        await loader.load(trackID: "one", kind: .portraitVideo, assets: { [asset] }, download: { _ in local })
        XCTAssertNotEqual(loader.requestToken, token)
        var discoveries = 0
        for candidate in ["first", "first", "corrected"] {
            await loader.load(trackID: "one", kind: .portraitVideo, reuseReadyResource: true,
                discoveryIdentity: .init(candidateID: candidate, storefront: "us", language: "en"),
                assets: { discoveries += 1; return [asset] }, download: { _ in local })
        }
        XCTAssertEqual(discoveries, 2, "A changed manual match must not reuse the old discovery")
    }

    func testCompatibilityModeToggleChangesTheActualArtworkTaskIdentity() {
        let defaults = UserDefaults(suiteName: "page-artwork-" + UUID().uuidString)!
        let model = AppModel(environment: .make(configuration: .preview),
            renderPreferences: LyricsRenderPreferences(defaults: defaults))
        let item = PlaybackItem(id: "one", uri: "fixture:one", title: "One", artists: [], albumTitle: nil,
            artworkURL: nil, duration: 30, isEpisode: false, isAdvertisement: false)
        let view = ImmersiveLyricsArtworkBackdrop(model: model, item: item, layout: nil,
            viewport: CGSize(width: 402, height: 874), active: true, artworkSource: { _ in })
        model.renderPreferences.configuration.immersiveLyrics = false
        let ordinary = view.requestKey
        model.renderPreferences.configuration.immersiveLyrics = true
        XCTAssertNotEqual(view.requestKey, ordinary, "The always-mounted compatibility backdrop must restart discovery when enabled")
    }

    func testDelayedSnapshotCannotCoverAnAlreadyPresentedNewSong() async throws {
        let red = try solidFrame(red: 1, green: 0, blue: 0)
        let blue = try solidFrame(red: 0, green: 0, blue: 1)
        let green = try solidFrame(red: 0, green: 1, blue: 0)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds; window.rootViewController = UIViewController(); window.makeKeyAndVisible()
        let surface = ImmersiveArtworkMedia.Surface()
        surface.frame = window.bounds; window.rootViewController?.view.addSubview(surface)
        defer { surface.stop(); window.isHidden = true; previous?.makeKey() }
        let start = CGRect(x: 20, y: 20, width: 100, height: 100)
        let end = CGRect(x: 0, y: 0, width: 180, height: 240)
        surface.configure(video: nil, layout: .inline(frame: start, visible: true, presentsFrame: false, radius: 0), still: red)
        try await Task.sleep(for: .milliseconds(50))
        let imageView = surface.stillSurface
        surface.configure(video: nil, layout: .inline(frame: end, visible: true, presentsFrame: false, radius: 0),
            still: green, animation: LyricsPageMotion.geometry)
        surface.configure(video: nil, layout: .inline(frame: end, visible: true, presentsFrame: false, radius: 0),
            still: blue, animation: LyricsPageMotion.geometry)
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertTrue(surface.stillSurface === imageView)
        XCTAssertTrue(surface.stillSurface.image?.cgImage === blue.image)
        XCTAssertTrue(surface.reflectionStillView.image?.cgImage === blue.image)
        XCTAssertEqual(surface.outgoingFrameCount, 0)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let presented = UIGraphicsImageRenderer(size: window.bounds.size, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let pixel = try rgb(XCTUnwrap(presented.cgImage?.cropping(to: CGRect(x: 50, y: 50, width: 1, height: 1))))
        XCTAssertGreaterThan(pixel[2], pixel[0] + 100, "Rapid track changes must settle on the latest blue cover")
    }

    private func solidFrame(red: CGFloat, green: CGFloat, blue: CGFloat) throws -> ImmersiveStillFrame {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let image = CIImage(color: CIColor(red: red, green: green, blue: blue)).cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8))
        let context = CIContext()
        let cgImage = try XCTUnwrap(context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: space))
        return .init(image: cgImage)
    }

    private func rgb(_ image: CGImage) throws -> [Double] {
        var bytes = [UInt8](repeating: 0, count: 4)
        try bytes.withUnsafeMutableBytes { storage in
            let context = try XCTUnwrap(CGContext(data: storage.baseAddress, width: 1, height: 1,
                bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return bytes.prefix(3).map(Double.init)
    }
}
