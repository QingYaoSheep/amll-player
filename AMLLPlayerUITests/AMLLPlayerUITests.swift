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

    func testCatalogNavigationAndMetadataOnlyPlaylist() {
        let app = catalogApp()
        XCTAssertTrue(app.staticTexts["Test Listener"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Library"].tap()
        app.buttons["My playlists"].tap()
        XCTAssertTrue(app.staticTexts["Test Playlist"].waitForExistence(timeout: 3))
        app.staticTexts["Test Playlist"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Open in Spotify"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Spotify has not made these tracks available to this app. Open in Spotify to continue."].exists)
    }

    func testSearchSurvivesDetailNavigation() {
        let app = catalogApp()
        app.tabBars.buttons["Search"].tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.tap()
        field.typeText("Test")
        let result = app.staticTexts["Test Result"]
        XCTAssertTrue(result.waitForExistence(timeout: 4))
        result.tap()
        XCTAssertTrue(app.navigationBars["Test Song"].waitForExistence(timeout: 3))
        app.navigationBars["Test Song"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(result.waitForExistence(timeout: 3))
        XCTAssertEqual(field.value as? String, "Test")
    }

    private func catalogApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["--catalog-ui-testing", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        return app
    }
}
