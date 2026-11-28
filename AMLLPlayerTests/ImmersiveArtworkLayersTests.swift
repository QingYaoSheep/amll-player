@testable import AMLLPlayer
import CoreGraphics
import SwiftUI
import UIKit
import XCTest

@MainActor
final class ImmersiveArtworkLayersTests: XCTestCase {
    func testBackgroundBlurProfileStartsAtTheJunctionAndExtendsUpWithoutMovingItsBottom() {
        let viewport = CGSize(width: 402, height: 874)
        let video = AMLLImmersiveArtworkGeometry.frame(viewport: viewport, video: CGSize(width: 9, height: 16))
        let profile = ImmersiveBackgroundBlurProfile.extendingBackground(video: video, viewport: viewport)
        let expectedHeight = AMLLImmersiveArtworkGeometry.transitionHalfHeight(videoHeight: video.height)
            * ImmersiveArtworkPreset.transitionHeightScale
        let expectedTop = min(video.maxY, max(0, video.maxY - expectedHeight + ImmersiveArtworkPreset.transitionYOffset))
        XCTAssertEqual(profile.frame.minX, 0)
        XCTAssertEqual(profile.frame.width, viewport.width)
        XCTAssertEqual(profile.frame.minY, expectedTop, accuracy: 0.001)
        XCTAssertEqual(profile.frame.maxY, viewport.height)
        XCTAssertEqual(profile.fullStrengthY, video.maxY, accuracy: 0.001)
        XCTAssertEqual(profile.strength(at: profile.frame.minY), 0)
        XCTAssertEqual(profile.strength(at: video.maxY), 1)
        XCTAssertEqual(profile.strength(at: viewport.height), 1)

        let custom = ImmersiveBackgroundBlurProfile.extendingBackground(video: video, viewport: viewport,
                                                                        yOffset: -20, heightScale: 1.5)
        XCTAssertLessThan(custom.frame.minY, profile.frame.minY)
        XCTAssertEqual(custom.frame.maxY, viewport.height)
        XCTAssertEqual(custom.fullStrengthY, video.maxY - 20, accuracy: 0.001)
        XCTAssertEqual(
            custom.fullStrengthY - custom.frame.minY,
            AMLLImmersiveArtworkGeometry.transitionHalfHeight(videoHeight: video.height) * 1.5,
            accuracy: 0.001
        )
        XCTAssertEqual(custom.strength(at: (custom.frame.minY + custom.fullStrengthY) / 2), 0.5, accuracy: 0.001)

        let backgroundOnly = profile.backgroundOnly(viewportHeight: viewport.height)
        XCTAssertEqual(backgroundOnly.frame.minY, 0)
        XCTAssertEqual(backgroundOnly.strength(at: 0), 1)
        XCTAssertEqual(backgroundOnly.strength(at: viewport.height), 1)
    }

    func testTopFeatherIsLocalSmoothAndClippedToTheUpperExtension() {
        let profile = ImmersiveBackgroundBlurProfile(frame: CGRect(x: 0, y: 180, width: 128, height: 470), fullStrengthY: 400)
        for length: CGFloat in [24, 80] {
            XCTAssertEqual(profile.effectiveTopFeatherLength(length), length)
            XCTAssertEqual(profile.topFeatherOpacity(at: 180, length: length), 0)
            XCTAssertEqual(profile.topFeatherOpacity(at: 180 + length / 4, length: length), 0.15625, accuracy: 0.000001)
            XCTAssertEqual(profile.topFeatherOpacity(at: 180 + length / 2, length: length), 0.5, accuracy: 0.000001)
            XCTAssertEqual(profile.topFeatherOpacity(at: 180 + length, length: length), 1)
            XCTAssertEqual(profile.topFeatherOpacity(at: 650, length: length), 1)
            XCTAssertLessThan(profile.topFeatherOpacity(at: 180 + length * 0.001, length: length), 0.00001)
            XCTAssertGreaterThan(profile.topFeatherOpacity(at: 180 + length * 0.999, length: length), 0.99999)
            var previous: CGFloat = 0
            for sample in 0 ... 256 {
                let opacity = profile.topFeatherOpacity(at: 180 + length * CGFloat(sample) / 256, length: length)
                XCTAssertGreaterThanOrEqual(opacity, previous)
                previous = opacity
            }
        }
        XCTAssertEqual(profile.topFeatherOpacity(at: 180, length: 0), 1)
        let short = ImmersiveBackgroundBlurProfile(frame: CGRect(x: 0, y: 390, width: 128, height: 260), fullStrengthY: 400)
        XCTAssertEqual(short.effectiveTopFeatherLength(80), 10)
        XCTAssertEqual(short.topFeatherOpacity(at: 400, length: 80), 1)
        let background = profile.backgroundOnly(viewportHeight: 650)
        XCTAssertEqual(background.effectiveTopFeatherLength(24), 0)
        XCTAssertEqual(background.topFeatherOpacity(at: 0, length: 24), 1)
    }

    func testVariableBlurMaskProducesMonotonicAlphaRampAndSupportsStatusBarCutoff() throws {
        let profile = ImmersiveBackgroundBlurProfile(frame: CGRect(x: 0, y: 180, width: 128, height: 470), fullStrengthY: 400)
        let image = try XCTUnwrap(ImmersiveVariableBlurMask.make(
            profile: profile,
            topFeatherLength: ImmersiveArtworkPreset.topFeatherLength
        ))
        XCTAssertEqual(image.width, 1)
        XCTAssertEqual(image.height, 256)

        let alphas = try alphaRows(of: image)
        XCTAssertLessThanOrEqual(alphas[0], 2, "The top edge of the variable blur mask must feather smoothly from 0")
        XCTAssertEqual(alphas[alphas.count - 1], 255, "The bottom of the mask must reach full blur strength")

        var previous = 0
        for row in alphas {
            XCTAssertGreaterThanOrEqual(row, previous)
            previous = row
        }

        let protected = try XCTUnwrap(ImmersiveVariableBlurMask.make(
            profile: profile,
            topFeatherLength: ImmersiveArtworkPreset.topFeatherLength,
            clearThroughY: 260
        ))
        let protectedAlphas = try alphaRows(of: protected)
        for row in 0 ..< protected.height {
            let y = profile.frame.minY + (CGFloat(row) + 0.5) / CGFloat(protected.height) * profile.frame.height
            if y < 260 {
                XCTAssertEqual(protectedAlphas[row], 0)
            } else {
                XCTAssertEqual(protectedAlphas[row], alphas[row])
            }
        }
    }

    func testTopFeatherDisplayMaskMatchesSmoothstepAndStatusBarCutoff() throws {
        let profile = ImmersiveBackgroundBlurProfile(frame: CGRect(x: 0, y: 180, width: 128, height: 470), fullStrengthY: 400)
        let image = try XCTUnwrap(ImmersiveVariableBlurMask.makeTopFeatherMask(
            profile: profile,
            topFeatherLength: ImmersiveArtworkPreset.topFeatherLength,
            includeRadiusRamp: false
        ))
        XCTAssertEqual(image.width, 1)
        XCTAssertEqual(image.height, 256)

        let alphas = try alphaRows(of: image)
        XCTAssertLessThanOrEqual(alphas[0], 2, "Top row must fade smoothly from 0")
        let midRow = Int(((220 - profile.frame.minY) / profile.frame.height * CGFloat(image.height)).rounded(.down))
        XCTAssertEqual(Double(alphas[midRow]), 128, accuracy: 10)
        for row in 0 ..< image.height {
            let y = profile.frame.minY + (CGFloat(row) + 0.5) / CGFloat(image.height) * profile.frame.height
            if y >= profile.frame.minY + ImmersiveArtworkPreset.topFeatherLength {
                XCTAssertEqual(alphas[row], 255)
            }
        }

        let backgroundOnly = profile.backgroundOnly(viewportHeight: 650)
        XCTAssertNil(ImmersiveVariableBlurMask.makeTopFeatherMask(
            profile: backgroundOnly,
            topFeatherLength: ImmersiveArtworkPreset.topFeatherLength,
            clearThroughY: 0,
            includeRadiusRamp: false
        ))

        let statusBarProtected = try XCTUnwrap(ImmersiveVariableBlurMask.makeTopFeatherMask(
            profile: backgroundOnly,
            topFeatherLength: ImmersiveArtworkPreset.topFeatherLength,
            clearThroughY: 62,
            includeRadiusRamp: false
        ))
        let protectedAlphas = try alphaRows(of: statusBarProtected)
        for row in 0 ..< statusBarProtected.height {
            let y = backgroundOnly.frame.minY + (CGFloat(row) + 0.5) / CGFloat(statusBarProtected.height) * backgroundOnly.frame.height
            if y < 62 {
                XCTAssertEqual(protectedAlphas[row], 0)
            } else {
                XCTAssertEqual(protectedAlphas[row], 255)
            }
        }
    }

    func testPresetReflectionFrameAndFadeStopsKeepCalibratedGeometry() {
        let cover = CGRect(x: 0, y: 0, width: 402, height: 536)
        let base = ArtworkReflectionGeometry.frame(cover: cover, viewportHeight: 874)
        let calibrated = ImmersiveArtworkPreset.reflectionFrame(cover: cover, viewportHeight: 874)
        XCTAssertEqual(calibrated.minX, base.minX)
        XCTAssertEqual(calibrated.width, base.width)
        XCTAssertEqual(calibrated.height, base.height * ImmersiveArtworkPreset.reflectionHeightScale, accuracy: 0.001)
        XCTAssertEqual(calibrated.midY, base.midY + ImmersiveArtworkPreset.reflectionYOffset, accuracy: 0.001)

        XCTAssertEqual(ArtworkReflectionStyle.fadeStops.count, 7)
        XCTAssertEqual(ArtworkReflectionStyle.fadeStops.first?.location, 0)
        XCTAssertEqual(ArtworkReflectionStyle.fadeStops.first?.alpha, 1)
        XCTAssertEqual(ArtworkReflectionStyle.fadeStops.last?.location, 1)
        XCTAssertEqual(ArtworkReflectionStyle.fadeStops.last?.alpha, 0)
    }

    func testSquareStaticCoverMatchesPortraitDynamicCoverBlurTransitionSpan() throws {
        let customAdjustment = ImmersiveArtworkLayerAdjustment(y: -20, height: 1.5)
        let viewports = [
            CGSize(width: 375, height: 812),
            CGSize(width: 393, height: 852),
            CGSize(width: 402, height: 874),
            CGSize(width: 440, height: 956),
        ]
        for viewport in viewports {
            let squareLayout = ImmersiveLyricsLayout.resolve(
                viewport: viewport,
                artwork: CGSize(width: 1000, height: 1000),
                informationHeight: 64,
                bottomInset: 34,
                isVideo: false
            )
            let portraitLayout = ImmersiveLyricsLayout.resolve(
                viewport: viewport,
                artwork: CGSize(width: 1080, height: 1440),
                informationHeight: 64,
                bottomInset: 34,
                isVideo: true
            )

            let squareProfile = ImmersiveBackgroundBlurProfile.extendingBackground(
                video: squareLayout.cover,
                viewport: viewport
            )
            let portraitProfile = ImmersiveBackgroundBlurProfile.extendingBackground(
                video: portraitLayout.cover,
                viewport: viewport
            )
            XCTAssertEqual(squareProfile.fullStrengthY, squareLayout.cover.maxY, accuracy: 0.001)
            XCTAssertEqual(
                squareProfile.fullStrengthY - squareProfile.frame.minY,
                portraitProfile.fullStrengthY - portraitProfile.frame.minY,
                accuracy: 0.001
            )
            XCTAssertEqual(
                squareProfile.effectiveTopFeatherLength(ImmersiveArtworkPreset.topFeatherLength),
                portraitProfile.effectiveTopFeatherLength(ImmersiveArtworkPreset.topFeatherLength),
                accuracy: 0.001
            )
            for distance in [CGFloat(20), 40, 80] {
                XCTAssertEqual(
                    squareProfile.strength(at: squareProfile.fullStrengthY - distance),
                    portraitProfile.strength(at: portraitProfile.fullStrengthY - distance),
                    accuracy: 0.0001
                )
            }
            XCTAssertEqual(
                squareProfile.topFeatherOpacity(at: squareProfile.frame.minY + 20, length: ImmersiveArtworkPreset.topFeatherLength),
                portraitProfile.topFeatherOpacity(at: portraitProfile.frame.minY + 20, length: ImmersiveArtworkPreset.topFeatherLength),
                accuracy: 0.0001
            )

            let squareCustom = ImmersiveBackgroundBlurProfile.extendingBackground(
                video: squareLayout.cover,
                viewport: viewport,
                adjustment: customAdjustment
            )
            let portraitCustom = ImmersiveBackgroundBlurProfile.extendingBackground(
                video: portraitLayout.cover,
                viewport: viewport,
                adjustment: customAdjustment
            )
            XCTAssertEqual(
                squareCustom.fullStrengthY - squareCustom.frame.minY,
                portraitCustom.fullStrengthY - portraitCustom.frame.minY,
                accuracy: 0.001
            )

            let squareMedia = ImmersiveArtworkMedia.Layout.immersive(
                cover: squareLayout.cover,
                viewport: viewport,
                presentsFrame: false,
                reduceTransparency: false
            )
            let portraitMedia = ImmersiveArtworkMedia.Layout.immersive(
                cover: portraitLayout.cover,
                viewport: viewport,
                presentsFrame: true,
                reduceTransparency: false
            )
            let squareBlur = try XCTUnwrap(squareMedia.blurProfile)
            let portraitBlur = try XCTUnwrap(portraitMedia.blurProfile)
            XCTAssertEqual(
                squareBlur.fullStrengthY - squareMedia.transition.minY,
                portraitBlur.fullStrengthY - portraitMedia.transition.minY,
                accuracy: 0.001
            )
        }
    }

    func testUpwardGradientLengthIsIndependentOfTopOffset() {
        let viewport = CGSize(width: 402, height: 874)
        let squareCover = ImmersiveLyricsLayout.resolve(
            viewport: viewport,
            artwork: CGSize(width: 1000, height: 1000),
            informationHeight: 64,
            bottomInset: 34,
            isVideo: false
        ).cover
        let portraitCover = ImmersiveLyricsLayout.resolve(
            viewport: viewport,
            artwork: CGSize(width: 1080, height: 1440),
            informationHeight: 64,
            bottomInset: 34,
            isVideo: true
        ).cover
        let offsets: [CGFloat] = [-120, 0, 80, 174, 240]

        for cover in [squareCover, portraitCover] {
            let referenceHeight = AMLLImmersiveArtworkGeometry.blurTransitionReferenceHeight(video: cover, viewport: viewport)
            let expectedLength = AMLLImmersiveArtworkGeometry.transitionHalfHeight(videoHeight: referenceHeight)
                * ImmersiveArtworkPreset.transitionHeightScale

            for offset in offsets {
                let profile = ImmersiveBackgroundBlurProfile.extendingBackground(
                    video: cover,
                    viewport: viewport,
                    adjustment: ImmersiveArtworkLayerAdjustment(y: offset, height: ImmersiveArtworkPreset.transitionHeightScale)
                )
                XCTAssertEqual(profile.fullStrengthY, cover.maxY + offset, accuracy: 0.001)
                XCTAssertEqual(profile.fullStrengthY - profile.frame.minY, expectedLength, accuracy: 0.001)
                XCTAssertEqual(profile.effectiveTopFeatherLength(80), 80, accuracy: 0.001)
                XCTAssertEqual(profile.strength(at: profile.frame.minY), 0, accuracy: 0.0001)
                XCTAssertEqual(profile.strength(at: profile.frame.minY + expectedLength / 2), 0.5, accuracy: 0.0001)
                XCTAssertEqual(profile.strength(at: profile.fullStrengthY), 1, accuracy: 0.0001)
            }

            let shorter = ImmersiveBackgroundBlurProfile.extendingBackground(
                video: cover,
                viewport: viewport,
                yOffset: 180,
                heightScale: 0.5
            )
            let longer = ImmersiveBackgroundBlurProfile.extendingBackground(
                video: cover,
                viewport: viewport,
                yOffset: 180,
                heightScale: 1.5
            )
            XCTAssertEqual(shorter.fullStrengthY, longer.fullStrengthY, accuracy: 0.001)
            XCTAssertEqual((longer.fullStrengthY - longer.frame.minY) / (shorter.fullStrengthY - shorter.frame.minY), 3, accuracy: 0.001)
        }

        let offBottom = ImmersiveBackgroundBlurProfile.extendingBackground(
            video: portraitCover,
            viewport: viewport,
            yOffset: 600,
            heightScale: 0.88
        )
        XCTAssertEqual(offBottom.frame.height, 0, accuracy: 0.001)
    }

    private func alphaRows(of image: CGImage) throws -> [Int] {
        let data = try XCTUnwrap(image.dataProvider?.data as Data?)
        var result: [Int] = []
        result.reserveCapacity(image.height)
        for row in 0 ..< image.height {
            result.append(Int(data[row * 4 + 3]))
        }
        return result
    }
}
