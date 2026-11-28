@testable import AMLLPlayer
import XCTest

final class ImmersiveLyricsLayoutTests: XCTestCase {
    @MainActor func testLyricsBackdropKeepsTheCalibratedArtworkPageJunction() {
        let viewport = CGSize(width: 402, height: 874)
        let cover = AMLLImmersiveArtworkGeometry.frame(viewport: viewport, video: CGSize(width: 3, height: 4))
        let visible = AMLLImmersiveArtworkGeometry.fittedFrame(container: cover, source: cover.size)
        let expected = ImmersiveBackgroundBlurProfile.extendingBackground(video: visible, viewport: viewport)
        let actual = ImmersiveArtworkMedia.Layout.immersive(cover: cover, viewport: viewport,
            presentsFrame: true, reduceTransparency: false)
        XCTAssertEqual(actual.video, visible)
        XCTAssertEqual(actual.transition, expected.frame, "Opening lyrics must not lift the calibrated blur region")
        XCTAssertEqual(actual.blurProfile, expected)
        XCTAssertEqual(actual.reflection, ImmersiveArtworkPreset.reflectionFrame(cover: visible, viewportHeight: viewport.height))
        XCTAssertEqual(actual.backgroundDimming, ImmersiveArtworkPreset.dimmingOpacity, accuracy: 0.0001)
    }

    func testSquareCoverAndInformationLeaveAnIndependentLyricViewport() {
        let layout = ImmersiveLyricsLayout.resolve(viewport: CGSize(width: 402, height: 874),
            artwork: CGSize(width: 1000, height: 1000), informationHeight: 64, bottomInset: 34)
        XCTAssertEqual(layout.cover, CGRect(x: 0, y: 0, width: 402, height: 402))
        XCTAssertEqual(layout.information.minY, 418)
        XCTAssertEqual(layout.information.minX, 30)
        XCTAssertEqual(layout.lyrics.minY, 482)
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
            XCTAssertEqual(layout.lyrics.minY, layout.information.maxY)
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
                let informationTop = source.height > source.width ? layout.cover.maxY - 80 : layout.cover.maxY + 16
                XCTAssertEqual(layout.information.minY, informationTop)
                XCTAssertEqual(layout.lyrics.minY, layout.information.maxY)
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

    func testPortraitVideoInformationIsInsideTheCoverAndFadeStartsAtTheArtistBottom() {
        let layout = ImmersiveLyricsLayout.resolve(viewport: CGSize(width: 402, height: 874),
            artwork: CGSize(width: 3, height: 4), informationHeight: 64, bottomInset: 34,
            isVideo: true, informationTextBottom: 58)
        XCTAssertTrue(layout.overlaysArtwork)
        XCTAssertEqual(layout.cover.height, 536)
        XCTAssertEqual(layout.information.minY, 456)
        XCTAssertEqual(layout.information.maxY, 520)
        XCTAssertEqual(layout.lyrics.minY, 514)
        XCTAssertEqual(layout.lyrics.maxY, 840)
        XCTAssertFalse(layout.requiresScrolling)
        let large = ImmersiveLyricsLayout.resolve(viewport: CGSize(width: 320, height: 568),
            artwork: CGSize(width: 3, height: 4), informationHeight: 500, bottomInset: 34, isVideo: true)
        XCTAssertFalse(large.overlaysArtwork)
        XCTAssertGreaterThan(large.information.minY, large.cover.maxY)
        XCTAssertTrue(large.requiresScrolling)
    }

    func testFocusIsEighteenPercentWithoutChangingOrdinaryPreferences() {
        var preference = LyricsRenderConfiguration()
        preference.anchor = 0.62
        preference.sizePreset = .medium
        let page = CGSize(width: 402, height: 874)
        let layout = ImmersiveLyricsLayout.resolve(viewport: page, artwork: CGSize(width: 1, height: 1),
            informationHeight: 64, bottomInset: 34)
        let projected = layout.lyricConfiguration(preference, page: page).validated()
        XCTAssertEqual(projected.anchor, 0.18)
        XCTAssertEqual(projected.fontSize, preference.resolvedFontSize(width: page.width, height: page.height))
        XCTAssertNil(projected.sizePreset)
        XCTAssertEqual(preference.anchor, 0.62)
        XCTAssertEqual(preference.sizePreset, .medium)
        preference.anchor = 0.18
        XCTAssertEqual(preference.validated().anchor, 0.2, "The ordinary anchor range must stay unchanged")
    }

    func testInformationAndLyricsFollowTheActualCalibratedCover() {
        let layout = ImmersiveLyricsLayout.resolve(viewport: CGSize(width: 402, height: 874),
            artwork: CGSize(width: 3, height: 4), informationHeight: 64, bottomInset: 34, isVideo: true,
            informationTextBottom: 60)
        XCTAssertEqual(layout.cover.width, 402)
        XCTAssertEqual(layout.visibleCover, layout.cover)
        XCTAssertEqual(layout.visibleCover.width / layout.visibleCover.height, 0.75, accuracy: 0.001)
        XCTAssertEqual(layout.information.maxY, layout.visibleCover.maxY - 16)
        XCTAssertEqual(layout.lyrics.minY, layout.information.minY + 60)
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

    func testImmersiveArtworkPresetRetainsCalibratedGeometryAndDefaults() {
        XCTAssertEqual(ImmersiveArtworkPreset.dimmingOpacity, 0.12, accuracy: 0.0001)
        XCTAssertEqual(ImmersiveArtworkPreset.reflectionYOffset, -78, accuracy: 0.0001)
        XCTAssertEqual(ImmersiveArtworkPreset.reflectionHeightScale, 0.41, accuracy: 0.0001)
        XCTAssertEqual(ImmersiveArtworkPreset.reflectionOpacity, 0.94, accuracy: 0.0001)
        XCTAssertEqual(ImmersiveArtworkPreset.blurRadius, 10, accuracy: 0.0001)
        XCTAssertEqual(ImmersiveArtworkPreset.topFeatherLength, 80, accuracy: 0.0001)
        XCTAssertEqual(ImmersiveArtworkPreset.transitionYOffset, 0, accuracy: 0.0001)
        XCTAssertEqual(ImmersiveArtworkPreset.transitionHeightScale, 0.88, accuracy: 0.0001)
        XCTAssertEqual(ImmersiveArtworkPreset.transitionOpacity, 1.0, accuracy: 0.0001)
    }
}
