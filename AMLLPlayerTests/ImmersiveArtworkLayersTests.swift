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
        XCTAssertEqual(custom.fullStrengthY, video.maxY, accuracy: 0.001)
        XCTAssertEqual(custom.strength(at: (custom.frame.minY + video.maxY) / 2), 0.5, accuracy: 0.001)

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
