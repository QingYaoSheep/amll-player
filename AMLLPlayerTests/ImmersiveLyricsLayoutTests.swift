@testable import AMLLPlayer
import XCTest

final class ImmersiveLyricsLayoutTests: XCTestCase {
    @MainActor func testLyricsBackdropKeepsTheCalibratedArtworkPageJunction() {
        let viewport = CGSize(width: 402, height: 874)
        let cover = AMLLImmersiveArtworkGeometry.frame(viewport: viewport, video: CGSize(width: 3, height: 4))
        var tuning = ImmersiveArtworkDebugConfiguration()
        tuning[.video].y = 18
        tuning[.transition].y = 36
        tuning[.transition].height = 0.8
        tuning[.reflection].y = 12
        tuning[.background].width = 1.2
        let visible = AMLLImmersiveArtworkGeometry.fittedFrame(container: tuning[.video].frame(cover), source: cover.size)
        let expected = ImmersiveBackgroundBlurProfile.extendingBackground(video: visible, viewport: viewport,
            adjustment: tuning[.transition])
        let actual = ImmersiveArtworkMedia.Layout.lyrics(cover: cover, viewport: viewport,
            configuration: .init(), tuning: tuning, presentsFrame: true, reduceTransparency: false)
        XCTAssertEqual(actual.video, visible)
        XCTAssertEqual(actual.transition, expected.frame, "Opening lyrics must not lift the calibrated blur region")
        XCTAssertEqual(actual.blurProfile, expected)
        XCTAssertEqual(actual.reflection, tuning[.reflection].frame(ArtworkReflectionGeometry.frame(cover: visible, viewportHeight: viewport.height)))
        XCTAssertEqual(actual.background, tuning[.background].frame(CGRect(origin: .zero, size: viewport)))
    }

    func testSquareCoverAndInformationLeaveAnIndependentLyricViewport() {
        let layout = ImmersiveLyricsLayout.resolve(viewport: CGSize(width: 402, height: 874),
            artwork: CGSize(width: 1000, height: 1000), informationHeight: 64, bottomInset: 34)
        XCTAssertEqual(layout.cover, CGRect(x: 0, y: 0, width: 402, height: 402))
        XCTAssertEqual(layout.information.minY, 418)
        XCTAssertEqual(layout.information.minX, 30)
        XCTAssertEqual(layout.lyrics.minY, 506)
        XCTAssertEqual(layout.lyrics.maxY, 840)
        XCTAssertFalse(layout.requiresScrolling)
    }

    func testTallStillFitsCompletelyAboveInformationAndReservesOneThirdForLyrics() {
        for viewport in [CGSize(width: 320, height: 568), CGSize(width: 402, height: 874), CGSize(width: 440, height: 956)] {
            let layout = ImmersiveLyricsLayout.resolve(viewport: viewport,
                artwork: CGSize(width: 1080, height: 1920), informationHeight: 64, bottomInset: 34)
            XCTAssertEqual(layout.cover.width / layout.cover.height, 9.0 / 16, accuracy: 0.0001)
            XCTAssertEqual(layout.cover.midX, viewport.width / 2)
            XCTAssertEqual(layout.cover.minY, 0)
            XCTAssertGreaterThanOrEqual(layout.information.minY, layout.cover.maxY + 16)
            XCTAssertGreaterThanOrEqual(layout.lyrics.minY, layout.information.maxY + 24)
            XCTAssertGreaterThanOrEqual(layout.lyrics.height, viewport.height / 3 - 0.01)
            XCTAssertLessThanOrEqual(layout.lyrics.maxY, viewport.height - 34 + 0.01)
        }
    }

    func testPlayingVideoUsesTheSameFullWidthAsTheLyricsHiddenImmersivePage() {
        for viewport in [CGSize(width: 320, height: 568), CGSize(width: 402, height: 874), CGSize(width: 440, height: 956)] {
            for source in [CGSize(width: 1080, height: 1440), CGSize(width: 1080, height: 1920), CGSize(width: 1, height: 1)] {
                let layout = ImmersiveLyricsLayout.resolve(viewport: viewport, artwork: source,
                    informationHeight: 64, bottomInset: 34, isVideo: true)
                XCTAssertEqual(layout.cover, AMLLImmersiveArtworkGeometry.frame(viewport: viewport, video: source))
                XCTAssertEqual(layout.cover.width, viewport.width, accuracy: 0.51)
                XCTAssertEqual(layout.cover.width / layout.cover.height, source.width / source.height, accuracy: 0.0001)
                XCTAssertEqual(layout.information.minY, layout.cover.maxY + 16)
                XCTAssertEqual(layout.lyrics.minY, layout.information.maxY + 24)
                XCTAssertGreaterThanOrEqual(layout.lyrics.height, viewport.height / 3 - 0.01)
            }
        }
    }

    func testArtworkGeometryBelongsToTheCurrentTrackEvenWhenTwoTracksShareTheSameImage() {
        let size = CGSize(width: 1080, height: 1440)
        let old = ImmersiveLyricsArtworkSource(trackID: "a", size: size, isVideo: false)
        let current = ImmersiveLyricsArtworkSource(trackID: "b", size: size, isVideo: false)
        XCTAssertNotEqual(old, current)
        XCTAssertEqual(old.forTrack("b"), .placeholder)
        XCTAssertEqual(current.forTrack("b"), current)
        XCTAssertEqual(current.forTrack(nil), .placeholder)
        XCTAssertNotEqual(current, ImmersiveLyricsArtworkSource(trackID: "b", size: size, isVideo: true))
    }

    func testSquareMovesAllJunctionCoordinatesAboveTheTallVideoJunction() {
        let viewport = CGSize(width: 402, height: 874)
        let square = ImmersiveLyricsLayout.resolve(viewport: viewport, artwork: CGSize(width: 1, height: 1), informationHeight: 64, bottomInset: 34)
        let tall = ImmersiveLyricsLayout.resolve(viewport: viewport, artwork: CGSize(width: 9, height: 16), informationHeight: 64, bottomInset: 34)
        XCTAssertLessThan(square.information.minY, tall.information.minY)
        XCTAssertLessThan(square.lyrics.minY, tall.lyrics.minY)
        for layout in [square, tall] {
            XCTAssertEqual(ArtworkReflectionGeometry.frame(cover: layout.cover, viewportHeight: viewport.height).minY, layout.cover.maxY)
            XCTAssertEqual(ImmersiveBackgroundBlurProfile.extendingBackground(video: layout.cover, viewport: viewport).fullStrengthY, layout.cover.maxY)
        }
    }

    func testLargeInformationRemainsReachableRatherThanCollapsingTheCanvas() {
        let layout = ImmersiveLyricsLayout.resolve(viewport: CGSize(width: 320, height: 568),
            artwork: CGSize(width: 1, height: 1), informationHeight: 440, bottomInset: 34)
        XCTAssertTrue(layout.requiresScrolling)
        XCTAssertEqual(layout.information.height, 440)
        XCTAssertGreaterThanOrEqual(layout.lyrics.height, 568.0 / 3)
        XCTAssertGreaterThan(layout.cover.height, 0)
        XCTAssertGreaterThan(layout.contentHeight, 568)
    }

    func testModeOnlyAppliesToPhonePortraitLyricsAndDoesNotEnableVideo() {
        var configuration = LyricsRenderConfiguration()
        let phone = CGSize(width: 402, height: 874)
        XCTAssertFalse(ImmersiveLyricsLayout.isEnabled(configuration, isPhone: true, viewport: phone))
        configuration.immersiveLyrics = true
        XCTAssertTrue(ImmersiveLyricsLayout.isEnabled(configuration, isPhone: true, viewport: phone))
        XCTAssertNil(configuration.animatedArtwork)
        XCTAssertFalse(ImmersiveLyricsLayout.isEnabled(configuration, isPhone: false, viewport: phone))
        XCTAssertFalse(ImmersiveLyricsLayout.isEnabled(configuration, isPhone: true, viewport: CGSize(width: 874, height: 402)))
        configuration.showLyrics = false
        XCTAssertFalse(ImmersiveLyricsLayout.isEnabled(configuration, isPhone: true, viewport: phone))
    }

    func testCalibrationDoesNotMoveOrHideTheNewCover() {
        var legacy = ImmersiveArtworkDebugConfiguration()
        legacy[.video].y = 400
        legacy[.video].height = 1.8
        legacy[.video].enabled = false
        legacy[.reflection].y = 250
        legacy[.reflection].opacity = 0.7
        legacy.blurRadius = 48
        legacy.topFeatherLength = 36
        legacy.order = Array(ImmersiveArtworkLayer.allCases)
        let projected = legacy.forImmersiveLyrics()
        XCTAssertEqual(projected[.video].y, 0)
        XCTAssertEqual(projected[.video].height, 1)
        XCTAssertTrue(projected[.video].enabled)
        XCTAssertEqual(projected[.reflection].y, 0)
        XCTAssertEqual(projected[.reflection].opacity, 0.7)
        XCTAssertEqual(projected.validatedBlur, 48)
        XCTAssertEqual(projected.validatedTopFeatherLength, 36)
        XCTAssertTrue(projected.isBelow(.video, .transition))
        XCTAssertEqual(legacy[.video].y, 400)
    }
}
