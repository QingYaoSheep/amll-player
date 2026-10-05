import XCTest

final class LyricsQuickSettingsUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor func testQuickSettingsStayOpenAcrossLyricVisibilityChanges() {
        let app = XCUIApplication()
        app.launchArguments += ["--lyrics-ui-testing", "--skip-welcome-ui-testing", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(app.buttons["openNowPlaying"].waitForExistence(timeout: 15))
        app.buttons["openNowPlaying"].tap()
        app.buttons["lyricsDisplayOptions"].tap()
        let panel = app.descendants(matching: .any)["lyricsQuickSettingsPanel"].firstMatch
        XCTAssertTrue(panel.waitForExistence(timeout: 3), "The display options must open a bottom quick-settings panel.")
        app.buttons["toggleLyricsVisibility"].tap()
        XCTAssertTrue(panel.exists, "Changing appearance must keep the panel open.")
        app.buttons["toggleLyricsVisibility"].tap()
        XCTAssertTrue(panel.exists)
        app.buttons["closeLyricsQuickSettings"].tap()
        XCTAssertFalse(panel.exists)
        XCTAssertTrue(app.descendants(matching: .any)["amllNativeLyricsDisplay"].firstMatch.exists)
        app.buttons["closeLyricsPlayer"].tap()
        XCTAssertTrue(app.buttons["openNowPlaying"].waitForExistence(timeout: 3))
    }
}
