import XCTest

final class MusicCatalogDesignUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor func testPlaylistNavigationPlaybackAndRepeatedEntries() {
        let app = launch()
        capture(app, "WWDC-home-light")
        selectTab("Library", app)
        let card = app.staticTexts["Test Playlist"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        let play = app.buttons["catalogPlay-playlist:list1"]
        XCTAssertTrue(play.isHittable)
        XCTAssertGreaterThanOrEqual(play.frame.width, 44)
        play.tap()
        XCTAssertFalse(app.navigationBars["Test Playlist"].exists, "Play must not navigate the surrounding card")
        card.tap()
        XCTAssertTrue(app.navigationBars["Test Playlist"].waitForExistence(timeout: 5))
        capture(app, "WWDC-playlist-header")
        let expand = app.buttons["catalogExpandDescription"]
        reveal(expand, app)
        expand.tap()
        XCTAssertEqual(expand.label, "收起介绍")
        let duplicate = app.buttons.matching(identifier: "catalogPlay-track:repeated")
        reveal(duplicate.firstMatch, app)
        XCTAssertEqual(duplicate.count, 2, "Duplicate playlist entries must retain their independent positions")
        capture(app, "WWDC-playlist-repeated-entries")
    }

    @MainActor func testArtistHighlightsAndAlbumNavigation() {
        let app = launch()
        capture(app, "WWDC-home-artist-flow")
        selectTab("Library", app)
        let artists = app.buttons["Followed artists"]
        XCTAssertTrue(artists.waitForExistence(timeout: 5))
        let categories = app.scrollViews["catalogLibraryCategories"]
        for _ in 0..<4 {
            if categories.frame.insetBy(dx: 12, dy: 0).contains(artists.frame) { break }
            categories.swipeLeft()
        }
        XCTAssertTrue(artists.isHittable)
        artists.tap()
        let artist = app.staticTexts["Test Artist"].firstMatch
        XCTAssertTrue(artist.waitForExistence(timeout: 5))
        artist.tap()
        XCTAssertTrue(app.navigationBars["Test Artist"].waitForExistence(timeout: 5))
        reveal(app.buttons["catalogPlay-track:song0"], app)
        capture(app, "WWDC-artist-highlights")
        let album = app.staticTexts["Test Album 1"].firstMatch
        reveal(album, app)
        capture(app, "WWDC-artist-albums")
        album.tap()
        XCTAssertTrue(app.buttons["catalogPrimaryArtist"].waitForExistence(timeout: 5))
        capture(app, "WWDC-album-header")
        app.buttons["catalogPrimaryArtist"].tap()
        XCTAssertTrue(app.navigationBars["Test Artist"].waitForExistence(timeout: 5))
    }

    @MainActor func testSearchFailureRetainsRecoveryAndSourceSwitchResetsNavigation() {
        let app = launch()
        selectTab("Search", app)
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap(); field.typeText("Unavailable\n")
        let albums = app.buttons["Albums"].firstMatch
        XCTAssertTrue(albums.waitForExistence(timeout: 5)); albums.tap()
        let result = app.staticTexts["Unavailable Result"].firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 5)); result.tap()
        let external = app.descendants(matching: .any).matching(NSPredicate(
            format: "label == %@ AND (elementType == %d OR elementType == %d)", "Open in Spotify",
            Int(XCUIElement.ElementType.button.rawValue), Int(XCUIElement.ElementType.link.rawValue))).firstMatch
        XCTAssertTrue(external.waitForExistence(timeout: 5), "A denied initial detail request still needs an external recovery action")
        XCTAssertTrue(external.isHittable)
        capture(app, "WWDC-detail-error-recovery")
        app.buttons["musicSourceMenu"].tap()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Apple Music ·")).firstMatch.tap()
        XCTAssertTrue(app.buttons["musicSourceMenu"].waitForExistence(timeout: 5))
        XCTAssertFalse(external.exists, "Changing service must discard the old service's detail route")
        XCTAssertFalse(app.staticTexts["Unavailable Result"].exists)
    }

    @MainActor func testAccessibilityTextKeepsDescriptionAndControlsReachable() {
        let app = launch(largeText: true)
        capture(app, "WWDC-home-accessibility-text")
        selectTab("Library", app)
        let card = app.staticTexts["Test Playlist"].firstMatch
        reveal(card, app); card.tap()
        let expand = app.buttons["catalogExpandDescription"]
        reveal(expand, app)
        expand.tap()
        XCTAssertEqual(expand.label, "收起介绍")
        reveal(app.buttons["catalogPlay-playlist:list1"], app)
        XCTAssertTrue(app.buttons["catalogPlay-playlist:list1"].isHittable)
        capture(app, "WWDC-playlist-accessibility-text")
    }

    @MainActor private func launch(largeText: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["--catalog-ui-testing", "--catalog-design-ui-testing", "--skip-welcome-ui-testing",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        if largeText { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launch()
        XCTAssertTrue(app.buttons["musicSourceMenu"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["为 Test Listener 精选"].waitForExistence(timeout: 5))
        return app
    }

    @MainActor private func selectTab(_ name: String, _ app: XCUIApplication) {
        let tab = app.tabBars.buttons[name]
        if tab.exists { tab.tap() } else { app.buttons[name].firstMatch.tap() }
    }

    @MainActor private func reveal(_ element: XCUIElement, _ app: XCUIApplication) {
        for _ in 0..<8 {
            if element.exists {
                let frame = element.frame
                if app.frame.insetBy(dx: 0, dy: 80).contains(CGPoint(x: frame.midX, y: frame.midY)), element.isHittable { return }
            }
            app.swipeUp()
        }
        XCTAssertTrue(element.isHittable, element.debugDescription)
    }

    @MainActor private func capture(_ app: XCUIApplication, _ name: String) {
        let capture = XCTAttachment(screenshot: app.screenshot())
        capture.name = name; capture.lifetime = .keepAlways; add(capture)
    }
}
