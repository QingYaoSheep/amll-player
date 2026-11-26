@testable import AMLLPlayer
import XCTest

final class TabletLyricsLayoutTests: XCTestCase {
    func testWideReferenceAndCenteredCoverWhenLyricsAreHidden() throws {
        let size = CGSize(width: 1376, height: 1030)
        let layout = TabletLyricsLayout(size: size, showsLyrics: true)
        XCTAssertEqual(layout.mode, .wide)
        assertRect(layout.cover, 57.765, 103, 561.05, 561.05)
        assertRect(layout.lyrics, 670, 0, 650.96, 1030)
        assertRect(layout.progress, 55.04, 780.55, 566.5, 20)
        XCTAssertEqual(layout.transportCenter.x, 339.29, accuracy: 0.001)
        XCTAssertEqual(layout.transportCenter.y - layout.buttonSize / 2, 820.275, accuracy: 0.001)
        XCTAssertEqual(layout.transportCenter.x - layout.transportSpacing - layout.buttonSize / 2, 210.29, accuracy: 0.001)
        XCTAssertEqual(layout.buttonSize, 68, accuracy: 0.001)
        XCTAssertEqual(layout.glyphSize, 36, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(layout.volume).minY, 905, accuracy: 0.001)
        XCTAssertEqual(layout.typography.anchor * 1030, 443.525, accuracy: 0.001)
        XCTAssertEqual(layout.typography.primarySize, 48)
        for (visualLines, step) in [(1, 98.0), (2, 156.0), (3, 214.0)] {
            let typography = layout.typography
            XCTAssertEqual(Double(visualLines) * (typography.primarySize + typography.visualLineLeading) + typography.paragraphGap, step)
        }
        let hidden = TabletLyricsLayout(size: size, showsLyrics: false)
        XCTAssertEqual(hidden.cover.midX, size.width / 2, accuracy: 0.001)
        XCTAssertEqual(hidden.lyrics, layout.lyrics)
    }

    func testNarrowAndMiniGeometry() {
        let narrow = TabletLyricsLayout(size: CGSize(width: 900, height: 800), showsLyrics: true)
        XCTAssertEqual(narrow.mode, .narrow)
        assertRect(narrow.cover, 72, 80, 90, 90)
        assertRect(narrow.lyrics, 72, 170, 756, 390)
        assertRect(narrow.progress, 90, 560, 720, 17.25)
        let mini = TabletLyricsLayout(size: CGSize(width: 720, height: 400), showsLyrics: true)
        XCTAssertEqual(mini.mode, .mini)
        assertRect(mini.lyrics, 378, 0, 324, 400)
        assertRect(mini.progress, 378, 213.9, 324, 30)
        XCTAssertEqual(mini.cover.midX, 180, accuracy: 0.001)
        XCTAssertEqual(mini.cover.midY, 200, accuracy: 0.001)
        XCTAssertNil(mini.volume)
        XCTAssertNil(narrow.volume)
    }

    func testWindowBoundariesAndTouchTargets() {
        for (width, height, mode) in [(1300.0, 1000.0, TabletLyricsLayout.Mode.wide), (1299, 1000, .narrow),
                                      (720, 400, .mini), (721, 400, .wide), (720, 401, .wide), (320, 620, .narrow)] {
            let layout = TabletLyricsLayout(size: CGSize(width: width, height: height), showsLyrics: true,
                                            topInset: 64, bottomInset: 20)
            XCTAssertEqual(layout.mode, mode)
            XCTAssertGreaterThanOrEqual(layout.buttonSize, 44)
            XCTAssertGreaterThan(layout.lyrics.height, 0)
            XCTAssertLessThanOrEqual(layout.lyrics.maxY, CGFloat(height))
            XCTAssertEqual(layout.typography.fade, layout.typography.fade.sorted())
        }
    }

    func testConfigurationPreservesUserAdjustmentsAndBlurReachesTheReferenceMaximum() {
        let layout = TabletLyricsLayout(size: CGSize(width: 1376, height: 1030), showsLyrics: true)
        var preferences = LyricsRenderConfiguration.amllDefault
        preferences.fontSize = 36
        preferences.anchor += 0.06
        preferences.paragraphSpacing = 12
        preferences.lyricBlurLevel = 4
        let value = layout.typography.configuration(preferences, in: layout.lyrics.size).validated()
        XCTAssertEqual(value.fontSize, 52)
        XCTAssertEqual(value.anchor, layout.typography.anchor + 0.06, accuracy: 0.001)
        XCTAssertEqual(value.paragraphSpacing, 12)
        XCTAssertEqual(value.lyricBlurLevel, 4)
        XCTAssertNil(preferences.tabletTypography)
        let maximum = TabletLyricTypography.maximumBlur(level: nil)
        XCTAssertEqual(maximum, 6)
        XCTAssertEqual(TabletLyricTypography.blur(distance: 0, maximum: maximum), 0)
        XCTAssertEqual(TabletLyricTypography.blur(distance: 1, maximum: maximum), 2.1875)
        XCTAssertEqual(TabletLyricTypography.blur(distance: -1, maximum: maximum), 3.4375)
        XCTAssertEqual(TabletLyricTypography.blur(distance: 7, maximum: maximum), 6)
        var transition = AMLLSourceTransition()
        transition.setTarget(6, duration: 0.12, usesTabletBlurCurve: true)
        transition.update(0.06)
        XCTAssertGreaterThan(transition.value, 0)
        XCTAssertLessThan(transition.value, 3)
        transition.update(0.06)
        XCTAssertEqual(transition.value, 6)
    }

    private func assertRect(_ rect: CGRect, _ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat,
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(rect.minX, x, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(rect.minY, y, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(rect.width, width, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(rect.height, height, accuracy: 0.001, file: file, line: line)
    }
}
