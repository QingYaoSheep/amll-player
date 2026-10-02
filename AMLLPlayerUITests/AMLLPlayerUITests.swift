import XCTest

final class AMLLPlayerUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor func testPlayerAndSettingsAreReachable() {
        let app = XCUIApplication()
        app.launchArguments += ["--skip-welcome-ui-testing", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Home"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["connectCurrentMusic"].exists)
        app.buttons["openSettings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 3))
        app.buttons["musicAccountsLink"].tap()
        XCTAssertTrue(app.buttons["spotifyLoginLink"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["appleMusicLoginLink"].exists)
        app.buttons["appleMusicLoginLink"].tap()
        XCTAssertTrue(app.buttons["appleMusicAuthorize"].waitForExistence(timeout: 3))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["spotifyLoginLink"].tap()
        XCTAssertTrue(app.buttons["spotifyAuthorize"].waitForExistence(timeout: 3))
        app.buttons["spotifyAdvancedConfiguration"].tap()
        let clientID = app.textFields["spotifyClientID"]
        XCTAssertTrue(clientID.waitForExistence(timeout: 3))
        clientID.tap(); clientID.typeText("test-client\n")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["spotifyAuthorize"].isEnabled)
    }

    @MainActor func testWelcomeCanBeSkippedIntoStableNavigation() {
        let app = XCUIApplication()
        app.launchArguments += ["--welcome-ui-testing"]
        app.launch()
        XCTAssertTrue(app.buttons["skipMusicWelcome"].waitForExistence(timeout: 5))
        capture(app, name: "Product-welcome")
        app.buttons["skipMusicWelcome"].tap()
        XCTAssertTrue(app.buttons["openSettings"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.tabBars.buttons.count >= 3)
    }

    @MainActor func testProductPagesAndSearchHistory() {
        let app = catalogApp()
        XCTAssertTrue(app.staticTexts["为 Test Listener 精选"].waitForExistence(timeout: 5))
        capture(app, name: "Product-home")
        app.buttons["openSettings"].tap()
        XCTAssertTrue(app.buttons["musicAccountsLink"].waitForExistence(timeout: 3))
        capture(app, name: "Product-settings")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.tabBars.buttons["Library"].tap()
        XCTAssertTrue(app.staticTexts["Test Playlist"].waitForExistence(timeout: 3))
        capture(app, name: "Product-library")
        app.tabBars.buttons["Search"].tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.tap(); field.typeText("Music")
        XCTAssertTrue(app.staticTexts["Music Result"].firstMatch.waitForExistence(timeout: 5))
        capture(app, name: "Product-search")
        field.typeText("\n")
        let clear = field.buttons.firstMatch
        if clear.exists { clear.tap() } else { field.tap(); field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 5)) }
        XCTAssertTrue(app.buttons["clearMusicSearchHistory"].waitForExistence(timeout: 5))
        app.buttons["clearMusicSearchHistory"].tap()
        XCTAssertFalse(app.buttons["clearMusicSearchHistory"].exists)
    }

    @MainActor func testCatalogNavigationAndMetadataOnlyPlaylist() {
        let app = catalogApp()
        XCTAssertTrue(app.staticTexts["为 Test Listener 精选"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Library"].tap()
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
        app.buttons["Albums"].firstMatch.tap()
        let result = app.staticTexts["Test Result"].firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 4))
        result.tap()
        XCTAssertTrue(app.navigationBars["Test Album"].waitForExistence(timeout: 3))
        app.navigationBars["Test Album"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(result.waitForExistence(timeout: 3))
        XCTAssertEqual(field.value as? String, "Test")
    }

    @MainActor func testLyricsSearchPreviewApplyAndManualLock() {
        let app = XCUIApplication()
        app.launchArguments += ["--lyrics-ui-testing", "--skip-welcome-ui-testing", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
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
        capture(app, name: "Product-lyrics-portrait")
        XCUIDevice.shared.orientation = .landscapeLeft
        let landscape = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in app.frame.width > app.frame.height }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [landscape], timeout: 5), .completed)
        defer { XCUIDevice.shared.orientation = .portrait }
        XCTAssertTrue(app.buttons["closeLyricsPlayer"].waitForExistence(timeout: 3))
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Plan5-fullscreen-landscape"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.buttons["closeLyricsPlayer"].tap()
        XCTAssertTrue(app.buttons["openNowPlaying"].waitForExistence(timeout: 3))
    }

    @MainActor private func capture(_ app: XCUIApplication, name: String) {
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = name; image.lifetime = .keepAlways; add(image)
    }

    @MainActor private func catalogApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["--catalog-ui-testing", "--skip-welcome-ui-testing", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
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
