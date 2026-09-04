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

        app.buttons["openSettings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 2))
        XCTAssertEqual(app.sheets.count, 0)
        XCTAssertTrue(app.staticTexts["Spotify connection only"].exists)

        app.buttons["spotifyLoginLink"].tap()
        XCTAssertTrue(app.navigationBars["Sign in to Spotify"].waitForExistence(timeout: 2))
        XCTAssertEqual(app.sheets.count, 0)
        let clientID = app.textFields["spotifyClientID"]
        let authorize = app.buttons["spotifyAuthorize"]
        XCTAssertTrue(clientID.exists)
        XCTAssertFalse(authorize.isEnabled)
        clientID.tap()
        clientID.typeText("test-client\n")
        XCTAssertTrue(authorize.isEnabled)

        app.navigationBars["Sign in to Spotify"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["Settings"].exists)
        app.navigationBars["Settings"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["Spotify Player"].exists)
    }
}
