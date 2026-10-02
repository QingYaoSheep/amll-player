import XCTest

final class LegacyMiniPlayerUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor func testLegacyMiniPlayerStaysAboveUsableTabs() {
        let app = XCUIApplication()
        app.launchArguments = ["--lyrics-ui-testing", "--skip-welcome-ui-testing",
            "--legacy-mini-player-ui-testing", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let mini = app.descendants(matching: .any)["miniPlayerBar"].firstMatch
        XCTAssertTrue(mini.waitForExistence(timeout: 15))
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 5))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Legacy-mini-player-tabs"; screenshot.lifetime = .keepAlways; add(screenshot)
        XCTAssertLessThanOrEqual(mini.frame.maxY, tabBar.frame.minY + 1,
            "The legacy mini player must be above the native tab bar, never over or below it.")
        for name in ["Search", "Library", "Home"] {
            let button = tabBar.buttons[name]
            XCTAssertTrue(button.isHittable, "Tab must remain usable: " + name)
            XCTAssertTrue(mini.frame.intersection(button.frame).isNull)
            button.tap()
            XCTAssertTrue(app.navigationBars[name].waitForExistence(timeout: 3))
        }
        app.buttons["openNowPlaying"].tap()
        XCTAssertTrue(app.buttons["closeLyricsPlayer"].waitForExistence(timeout: 5))
        app.buttons["closeLyricsPlayer"].tap()
        XCTAssertTrue(mini.waitForExistence(timeout: 5))
        XCTAssertLessThanOrEqual(mini.frame.maxY, tabBar.frame.minY + 1)
    }
}
