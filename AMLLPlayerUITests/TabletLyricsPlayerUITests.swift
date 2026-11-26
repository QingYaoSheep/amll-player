import UIKit
import XCTest

final class TabletLyricsPlayerUITests: XCTestCase {
    @MainActor func testIPadOrdinaryPlayersSurviveRotationAndLyricToggle() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad)
        let device = XCUIDevice.shared
        defer { device.orientation = .portrait }
        for custom in [false, true] {
            device.orientation = .landscapeLeft
            let app = XCUIApplication()
            app.launchArguments += ["--lyrics-ui-testing", "--skip-welcome-ui-testing", "-AppleLanguages", "(en)",
                "-AppleLocale", "en_US", "--quick-settings-preferences-suite", "tablet-lyrics-" + UUID().uuidString]
            if custom { app.launchArguments += ["--lyrics-custom-profile-ui-testing"] }
            app.launch()
            defer { app.terminate() }
            let nowPlaying = app.buttons["openNowPlaying"]
            guard nowPlaying.waitForExistence(timeout: 15) else { XCTFail("Missing Now Playing control"); return }
            nowPlaying.tap()
            let toggle = app.buttons["tabletLyricsToggle"]
            guard toggle.waitForExistence(timeout: 5) else { XCTFail("Missing iPad lyric visibility control"); return }
            XCTAssertGreaterThanOrEqual(toggle.frame.height, 44)
            let renderer = app.descendants(matching: .any)[custom ? "nativeLyricsScroll" : "amllNativeLyricsDisplay"].firstMatch
            XCTAssertTrue(renderer.waitForExistence(timeout: 5))
            attach(custom ? "Custom landscape" : "AMLL landscape", app.screenshot())
            toggle.tap()
            XCTAssertTrue(toggle.isHittable)
            XCTAssertEqual(toggle.label, "Show lyrics")
            toggle.tap()
            XCTAssertTrue(renderer.waitForExistence(timeout: 5))
            device.orientation = .portrait
            XCTAssertTrue(toggle.waitForExistence(timeout: 5))
            XCTAssertTrue(toggle.isHittable)
            XCTAssertTrue(renderer.waitForExistence(timeout: 5))
            attach(custom ? "Custom portrait" : "AMLL portrait", app.screenshot())
        }
    }

    private func attach(_ name: String, _ screenshot: XCUIScreenshot) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
