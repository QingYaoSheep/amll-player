@testable import AMLLPlayer
import XCTest

final class AppleMusicLayoutReferenceTests: XCTestCase {
    func testSuppliedCapturesResolveToIPhone16ProPointCanvas() {
        let manifest = AppleMusicLayoutReferenceManifest.suppliedIPhone16Pro
        XCTAssertEqual(manifest.schemaVersion, 1)
        XCTAssertEqual(manifest.captures.count, 2)
        for capture in manifest.captures {
            XCTAssertEqual(Double(capture.pixelWidth) / capture.displayScale, 402)
            XCTAssertEqual(Double(capture.pixelHeight) / capture.displayScale, 874)
        }
        XCTAssertEqual(Set(manifest.captures.map(\.state)), [.lyricsVisible, .lyricsHidden])
    }

    func testMeasuredHandleMatchesSuppliedPixels() {
        let metrics = AppleMusicLyricsLayoutMetrics.iPhone16Pro
        XCTAssertEqual(metrics.handleTop * 3, 207, accuracy: 0.5)
        XCTAssertEqual(metrics.handleSize.width * 3, 180, accuracy: 0.5)
        XCTAssertEqual(metrics.handleSize.height * 3, 12, accuracy: 0.5)
    }

    func testResponsiveLayoutKeepsCompactAndTabletBoundsUsable() {
        let compact = AppleMusicLyricsLayoutMetrics.responsive(in: CGSize(width: 320, height: 568))
        XCTAssertGreaterThanOrEqual(compact.horizontalInset, 20)
        XCTAssertGreaterThanOrEqual(compact.compactArtworkSize, 60)

        let tablet = AppleMusicLyricsLayoutMetrics.responsive(in: CGSize(width: 1_032, height: 1_376))
        XCTAssertLessThanOrEqual(tablet.compactArtworkSize, 88)
        XCTAssertGreaterThan(tablet.horizontalInset, compact.horizontalInset)
    }
}
