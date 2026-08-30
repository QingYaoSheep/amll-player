import XCTest

final class AMLLPlayerUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testPlayerAndSettingsAreReachable() {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()

        XCTAssertTrue(app.navigationBars["Spotify Player"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Spotify configuration required"].exists)

        app.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["Spotify connection only"].exists)
    }
}
