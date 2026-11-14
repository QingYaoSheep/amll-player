@testable import AMLLPlayer
import SwiftUI
import AVFoundation
import UIKit
import XCTest

@MainActor
final class LyricsPagePresentationTests: XCTestCase {
    func testRapidHideShowCannotRetireTheLiveCanvas() {
        let state = LyricsPagePresentationCoordinator()
        state.update(.init(showsLyrics: true, immersive: false), reduceMotion: false)
        state.update(.init(showsLyrics: false, immersive: false), reduceMotion: false)
        let hiding = state.revision
        XCTAssertTrue(state.rendersLyrics, "Keep the canvas rendering throughout its outgoing fade")
        state.update(.init(showsLyrics: true, immersive: true), reduceMotion: false)
        state.finish(hiding)
        XCTAssertTrue(state.rendersLyrics, "A stale removal callback cannot deactivate a reopened canvas")
        state.finish(state.revision)
        XCTAssertTrue(state.rendersLyrics)
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
        let surface = ImmersiveArtworkMedia.Surface(frames: ArtworkReflectionFrames())
        surface.frame = window.bounds; controller.view.addSubview(surface)
        defer { surface.stop(); window.isHidden = true; previous?.makeKey() }
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "artwork-layer-order", withExtension: "mp4"))
        let video = AnimatedArtwork(url: url, active: false)
        let start = CGRect(x: 20, y: 80, width: 100, height: 100)
        let end = CGRect(x: 0, y: 0, width: 300, height: 400)
        surface.configure(video: video, layout: .inline(frame: start, visible: true, presentsFrame: false, radius: 12))
        let player = (surface.videoSurface.layer as? AVPlayerLayer)?.player
        XCTAssertNotNil(player)
        surface.configure(video: video, layout: .inline(frame: end, visible: true, presentsFrame: false, radius: 0),
            animation: LyricsPageMotion.geometry)
        try await Task.sleep(for: .milliseconds(70))
        let mid = try XCTUnwrap(surface.videoPlane.layer.presentation()?.frame)
        XCTAssertGreaterThan(mid.width, start.width)
        XCTAssertLessThan(mid.width, end.width)
        XCTAssertTrue((surface.videoSurface.layer as? AVPlayerLayer)?.player === player)
        // Reverse before completion: it starts from the visible intermediate value.
        surface.configure(video: video, layout: .inline(frame: start, visible: true, presentsFrame: false, radius: 12),
            animation: LyricsPageMotion.geometry)
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(surface.videoPlane.frame, start)
        XCTAssertTrue((surface.videoSurface.layer as? AVPlayerLayer)?.player === player)
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
    }
}
