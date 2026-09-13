@testable import AMLLPlayer
import XCTest

final class ArtworkAssetTests: XCTestCase {
    func testSourceURLShapesAndSquarePortraitSelection() {
        let attributes: [String: Any] = ["editorialVideo": [
            "motionDetailSquare": ["url": "https://example.com/square.m3u8"],
            "motionDetailTall": ["video": ["href": "https://example.com/tall.m3u8"]],
        ]]
        let assets = ArtworkAsset.catalogAssets(attributes: attributes, albumID: "123", storefront: "us")
        XCTAssertEqual(assets.map(\.kind), [.squareVideo, .portraitVideo])
        XCTAssertEqual(assets.map(\.albumID), ["123", "123"])
        XCTAssertEqual(assets.map(\.storefront), ["us", "us"])
        XCTAssertEqual(assets.last?.url.lastPathComponent, "tall.m3u8")
    }

    func testMissingAndInvalidResourcesDoNotBecomePlayableAssets() {
        XCTAssertTrue(ArtworkAsset.catalogAssets(attributes: [:], albumID: "1", storefront: "us").isEmpty)
        XCTAssertNil(ArtworkAsset.mediaURL("file:///secret"))
        XCTAssertNil(ArtworkAsset.mediaURL("https://user:password@example.com/video"))
        XCTAssertNil(ArtworkAsset.mediaURL(["url": 123]))
        XCTAssertNil(ArtworkAsset.mediaURL("http://example.com/video"))
        XCTAssertNotNil(ArtworkAsset.mediaURL(["url": "", "href": "https://example.com/video"]))
    }
}
