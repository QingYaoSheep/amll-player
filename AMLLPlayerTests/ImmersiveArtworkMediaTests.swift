@testable import AMLLPlayer
import AVFoundation
import UIKit
import XCTest

@MainActor
final class ImmersiveArtworkMediaTests: XCTestCase {
    func testActualPlayerAndBlurUseTheSameOrderedNativeHierarchy() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "artwork-layer-order", withExtension: "mp4"))
        let frames = ArtworkReflectionFrames()
        let surface = ImmersiveArtworkMedia.Surface(frames: frames)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 128, height: 650))
        let controller = UIViewController()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        surface.frame = window.bounds
        controller.view.addSubview(surface)
        defer { surface.stop(); surface.removeFromSuperview(); window.isHidden = true }
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
        try await waitUntil { firstFrame && surface.transitionSurface.layer.contents != nil }
        let playerLayer = try XCTUnwrap(surface.videoSurface.layer as? AVPlayerLayer)
        XCTAssertTrue(playerLayer.isReadyForDisplay)
        XCTAssertTrue(surface.transitionSurface.superview === surface)
        XCTAssertTrue(surface.videoPlane.superview === surface)
        XCTAssertTrue(surface.reflectionSurface.superview === surface)
        XCTAssertTrue(surface.videoSurface.superview === surface.videoPlane)
        XCTAssertGreaterThan(surface.transitionSurface.layer.zPosition, surface.videoPlane.layer.zPosition)
        XCTAssertEqual(surface.reflectionSurface.layer.zPosition, surface.videoPlane.layer.zPosition)
        XCTAssertNotNil(surface.layer.mask)
        XCTAssertNil(playerLayer.mask, "The final fade must be on the common media parent")
        XCTAssertFalse(surface.transitionSurface.isHidden)
        let player = playerLayer.player
        configure(reflects: true)
        try await waitUntil { surface.reflectionSurface.layer.contents != nil && surface.transitionSurface.layer.contents != nil }
        XCTAssertTrue(playerLayer.player === player, "Toggling reflection must keep the one existing player")
        XCTAssertFalse(surface.transitionSurface.isHidden)
        tuning[.video].enabled = false
        configure(reflects: true)
        XCTAssertTrue(surface.videoPlane.isHidden)
        XCTAssertFalse(surface.transitionSurface.isHidden)
        tuning[.video].enabled = true
        configure(reflects: true)
        XCTAssertFalse(surface.videoPlane.isHidden)
        XCTAssertGreaterThan(surface.transitionSurface.layer.zPosition, surface.videoPlane.layer.zPosition)
        tuning[.bottomFade].enabled = false
        configure(reflects: true)
        XCTAssertNil(surface.layer.mask)
        XCTAssertNotNil(surface.transitionSurface.layer.contents)
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0 ..< 600 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Actual video playback did not deliver a blur frame within six seconds")
    }
}
