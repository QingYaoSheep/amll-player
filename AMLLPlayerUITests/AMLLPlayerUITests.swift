import XCTest

final class AMLLPlayerUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor func testPlayerAndSettingsAreReachable() {
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

    @MainActor func testCatalogNavigationAndMetadataOnlyPlaylist() {
        let app = catalogApp()
        XCTAssertTrue(app.staticTexts["Test Listener"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Library"].tap()
        app.buttons["My playlists"].tap()
        XCTAssertTrue(app.staticTexts["Test Playlist"].waitForExistence(timeout: 3))
        app.staticTexts["Test Playlist"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Open in Spotify"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Spotify has not made these tracks available to this app. Open in Spotify to continue."].exists)
    }

    @MainActor func testSearchSurvivesDetailNavigation() {
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

    @MainActor func testLyricsSearchPreviewApplyAndManualLock() {
        let app = XCUIApplication()
        app.launchArguments += ["--lyrics-ui-testing", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        waitForLyricsEntry(app)
        app.buttons["openNowPlaying"].tap()
        let actions = app.buttons["lyricsActions"]
        XCTAssertTrue(actions.waitForExistence(timeout: 3))
        actions.tap()
        app.buttons["Find or correct lyrics"].tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 3))
        search.tap(); search.typeText("Correction")
        let candidate = app.staticTexts["Correction Candidate"].firstMatch
        XCTAssertTrue(candidate.waitForExistence(timeout: 5)); candidate.tap()
        XCTAssertTrue(app.staticTexts["Corrected fixture line"].waitForExistence(timeout: 5))
        app.buttons["lyricsApply"].tap()
        XCTAssertTrue(app.staticTexts["Manual · locked"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["amllNativeLyricsDisplay"].firstMatch.waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Corrected fixture line")).firstMatch.waitForExistence(timeout: 3))
        app.buttons["closeLyricsPlayer"].tap()
        XCTAssertTrue(app.buttons["openNowPlaying"].waitForExistence(timeout: 3))
    }

    @MainActor func testNativeLyricsBrowseRestoreVisibilityAndRotate() {
        let app = XCUIApplication()
        app.launchArguments += ["--lyrics-ui-testing", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        waitForLyricsEntry(app)
        app.buttons["openNowPlaying"].tap()
        let lyrics = app.descendants(matching: .any)["amllNativeLyricsDisplay"].firstMatch
        XCTAssertTrue(lyrics.waitForExistence(timeout: 5))
        lyrics.swipeUp()
        let resume = app.buttons["resumeLyricsFollowing"]
        XCTAssertTrue(resume.waitForExistence(timeout: 3))
        resume.tap()
        app.buttons["lyricsDisplayOptions"].tap()
        app.buttons["toggleLyricsVisibility"].tap()
        app.buttons["lyricsDisplayOptions"].tap()
        XCTAssertTrue(app.buttons["toggleLyricsVisibility"].waitForExistence(timeout: 3))
        app.buttons["toggleLyricsVisibility"].tap()
        XCTAssertTrue(lyrics.waitForExistence(timeout: 3))
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        XCTAssertTrue(app.buttons["closeLyricsPlayer"].waitForExistence(timeout: 3))
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Plan5-fullscreen-landscape"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.buttons["closeLyricsPlayer"].tap()
        XCTAssertTrue(app.buttons["openNowPlaying"].waitForExistence(timeout: 3))
    }

    @MainActor private func catalogApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["--catalog-ui-testing", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        return app
    }

    @MainActor private func waitForLyricsEntry(_ app: XCUIApplication) {
        // Account and playback fixtures arrive independently. Retain the real
        // tab accessory route and attach evidence if it never becomes visible.
        let found = app.buttons["openNowPlaying"].waitForExistence(timeout: 15)
        if !found {
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "Missing lyric entry hierarchy"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.lifetime = .keepAlways
            add(screenshot)
        }
        XCTAssertTrue(found)
    }
}
