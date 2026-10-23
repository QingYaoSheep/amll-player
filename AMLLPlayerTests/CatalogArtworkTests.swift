import UIKit
import XCTest
@testable import AMLLPlayer

@MainActor final class CatalogArtworkTests: XCTestCase {
    func testLocalArtworkIsDownsampledReusedAndRejectsUntrustedSchemes() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: url) }
        let original = UIGraphicsImageRenderer(size: CGSize(width: 1024, height: 1024)).image { context in
            UIColor.systemIndigo.setFill(); context.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
        }
        try XCTUnwrap(original.pngData()).write(to: url)
        let cache = CatalogImageCache.shared
        let loaded = await cache.image(url, pixels: 200)
        let image = try XCTUnwrap(loaded)
        XCTAssertLessThanOrEqual(try XCTUnwrap(image.cgImage).width, 256)
        XCTAssertGreaterThan(image.size.width, 100)
        let reused = await cache.image(url, pixels: 200)
        XCTAssertTrue(image === reused)
        let insecure = await cache.image(URL(string: "http://example.com/art.png")!)
        XCTAssertNil(insecure)
    }

    func testDescriptionIsPlainTextAndFilledControlsHaveReadableContrast() throws {
        XCTAssertEqual(MusicCatalogText.description("<p>A &amp; B<br>Live</p>"), "A & B\nLive")
        XCTAssertNil(MusicCatalogText.description("<p> </p>"))
        let fill = try XCTUnwrap(UIColor(named: "MusicAccentFill"))
        for style in [UIUserInterfaceStyle.light, .dark] {
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            XCTAssertTrue(fill.resolvedColor(with: .init(userInterfaceStyle: style)).getRed(&red, green: &green, blue: &blue, alpha: &alpha))
            func linear(_ value: CGFloat) -> CGFloat { value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4) }
            let luminance = linear(red) * 0.2126 + linear(green) * 0.7152 + linear(blue) * 0.0722
            XCTAssertGreaterThanOrEqual(1.05 / (luminance + 0.05), 4.5, "Normal-size white button text must remain readable")
            XCTAssertEqual(alpha, 1)
        }
    }
}
