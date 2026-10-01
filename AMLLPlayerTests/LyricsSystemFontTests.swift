@testable import AMLLPlayer
import CoreText
import UIKit
import XCTest

@MainActor
final class LyricsSystemFontTests: XCTestCase {
    func testRealGlyphRunsUseSystemLatinAndChineseFonts() throws {
        let line = LyricLine(id: "system-font", text: "Hello 世界", start: 0, end: 2,
                             words: [.init(text: "Hello ", start: 0, end: 1, romanWord: "hello", ruby: "你好"),
                                     .init(text: "世界", start: 1, end: 2, romanWord: "shi jie", ruby: "世界")],
                             translation: "你好，世界", precision: .word)
        for weight in [UIFont.Weight.regular, .bold] {
            let requested = UIFont.systemFont(ofSize: 32, weight: weight)
            let layout = AMLLCoreTextLayout(line: line, width: 360, font: requested, configuration: .init())
            let runs = layout.glyphFontRuns
            XCTAssertFalse(runs.isEmpty)
            let body = runs.filter { $0.role == "body" }
            XCTAssertTrue(body.contains { $0.name.contains("SF") || $0.family.contains("System") }, "Actual Latin glyph fonts: \(body)")
            XCTAssertTrue(body.contains { $0.name.contains("PingFang") }, "Actual Chinese fallback fonts: \(body)")
            XCTAssertFalse(runs.contains { $0.name.contains("Times") || $0.name.contains("Helvetica") || $0.name.contains("Arial") || $0.name.contains("LastResort") },
                           "A requested system font must not silently resolve to another Latin face")
            XCTAssertTrue(body.allSatisfy { abs($0.pointSize - 32) < 0.01 })
            let attachment = XCTAttachment(data: try JSONEncoder().encode(runs), uniformTypeIdentifier: "public.json")
            attachment.name = "Actual lyric glyph fonts \(weight == .bold ? "bold" : "regular")"
            attachment.lifetime = .keepAlways
            add(attachment)
            let image = XCTAttachment(image: layout.raster(scale: 3))
            image.name = "System lyric font raster \(weight == .bold ? "bold" : "regular")"
            image.lifetime = .keepAlways
            add(image)
        }
    }
}
