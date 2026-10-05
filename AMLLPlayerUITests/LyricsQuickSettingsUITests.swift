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

    @MainActor func testAppearanceChangesPersistThroughTheProductionPanel() {
        let app = lyricsApp()
        app.launchArguments += ["--quick-settings-preferences-suite", "quick-settings-ui-" + UUID().uuidString]
        openPanel(app)
        let translation = app.switches["quickSettingsTranslation"]
        XCTAssertTrue(translation.exists)
        let previous = translation.value as? String
        toggle(translation)
        let changedValue = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value != %@", previous ?? "1"), object: translation)
        XCTAssertEqual(XCTWaiter.wait(for: [changedValue], timeout: 3), .completed)
        let changed = translation.value as? String
        XCTAssertTrue(panel(app).exists)
        let autoSize = app.switches["quickSettingsAutoSize"]
        reveal(autoSize, in: app)
        XCTAssertTrue(autoSize.exists)
        toggle(autoSize)
        XCTAssertTrue(app.descendants(matching: .any)["quickSettingsSizePreset"].firstMatch.exists)
        toggle(autoSize)
        let font = app.descendants(matching: .any)["quickSettingsFontSize"].firstMatch
        reveal(font, in: app)
        font.tap()
        app.buttons["Large"].tap()
        XCTAssertTrue(panel(app).exists)
        capture(app, name: "Quick-settings-appearance")
        app.terminate()
        openPanel(app)
        XCTAssertEqual(app.switches["quickSettingsTranslation"].value as? String, changed)
        XCTAssertEqual(app.switches["quickSettingsAutoSize"].value as? String, "0")
        let restoredFont = app.descendants(matching: .any)["quickSettingsFontSize"].firstMatch
        XCTAssertEqual(restoredFont.value as? String, "40 pt")
        app.buttons["closeLyricsQuickSettings"].tap()
    }

    @MainActor func testOutsideAndHandleCloseOnlyThePanelAndRotationKeepsItUsable() {
        let app = lyricsApp()
        openPanel(app)
        let handle = app.descendants(matching: .any)["lyricsQuickSettingsHandle"].firstMatch
        let scroll = app.scrollViews["lyricsQuickSettingsScroll"]
        XCTAssertGreaterThan(handle.frame.minY, app.frame.height * 0.3)
        XCTAssertLessThanOrEqual(scroll.frame.maxY - handle.frame.minY, app.frame.height * 0.6 + 1)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap()
        XCTAssertFalse(panel(app).exists)
        XCTAssertTrue(app.buttons["lyricsDisplayOptions"].exists)
        app.buttons["lyricsDisplayOptions"].tap()
        app.descendants(matching: .any)["lyricsQuickSettingsHandle"].firstMatch.swipeDown()
        XCTAssertFalse(panel(app).exists)
        XCTAssertTrue(app.buttons["lyricsDisplayOptions"].exists)
        app.buttons["lyricsDisplayOptions"].tap()
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        XCTAssertTrue(panel(app).waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["closeLyricsQuickSettings"].isHittable)
        capture(app, name: "Quick-settings-landscape")
        app.buttons["closeLyricsQuickSettings"].tap()
        XCTAssertTrue(app.buttons["closeLyricsPlayer"].isHittable)
    }

    @MainActor func testQuickSettingsRoutesToExistingPagesFromBothLyricsLayouts() {
        for legacy in [false, true] {
            let app = lyricsApp()
            if legacy { app.launchArguments += ["--lyrics-custom-profile-ui-testing"] }
            openPanel(app)
            let scroll = app.scrollViews["lyricsQuickSettingsScroll"]
            let appearance = app.buttons["quickSettingsRoute.appearance"]
            reveal(appearance, in: app)
            XCTAssertTrue(appearance.isHittable)
            appearance.tap()
            XCTAssertTrue(app.buttons["closeLyricsQuickSettingsDestination"].waitForExistence(timeout: 4))
            XCTAssertFalse(panel(app).exists)
            app.buttons["closeLyricsQuickSettingsDestination"].tap()
            XCTAssertTrue(app.buttons["closeLyricsQuickSettingsDestination"].waitForNonExistence(timeout: 4))
            app.buttons["lyricsDisplayOptions"].tap()
            let search = app.buttons["quickSettingsRoute.lyricsSearch"]
            reveal(search, in: app)
            XCTAssertTrue(search.isHittable)
            search.tap()
            XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 4))
            XCTAssertFalse(panel(app).exists)
            app.navigationBars["Find or correct lyrics"].buttons["Done"].tap()
            XCTAssertTrue(app.buttons["lyricsDisplayOptions"].waitForExistence(timeout: 3))
            app.terminate()
        }
    }

    @MainActor func testBackgroundAndOffsetApplyWithoutClosingTheMenu() {
        let app = lyricsApp()
        openPanel(app)
        let selector = app.descendants(matching: .any)["quickSettingsBackground"].firstMatch
        reveal(selector, in: app)
        selector.tap()
        app.buttons["Mesh网格（取色模式2）"].tap()
        XCTAssertTrue(panel(app).exists)
        let background = app.descendants(matching: .any)["quickSettingsBackground"].firstMatch
        XCTAssertTrue(displayedText(background).contains("取色模式2"))
        let scroll = app.scrollViews["lyricsQuickSettingsScroll"]
        let offset = app.buttons["quickSettingsOffsetPlus"]
        reveal(offset, in: app)
        XCTAssertTrue(offset.isHittable)
        offset.tap()
        XCTAssertTrue(panel(app).exists)
        XCTAssertEqual(app.descendants(matching: .any)["quickSettingsOffset"].firstMatch.value as? String, "+0.1 s")
        app.buttons["quickSettingsOffsetReset"].tap()
        XCTAssertEqual(app.descendants(matching: .any)["quickSettingsOffset"].firstMatch.value as? String, "+0.0 s")
        capture(app, name: "Quick-settings-operations")
        app.buttons["closeLyricsQuickSettings"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["amllNativeLyricsDisplay"].firstMatch.exists)
    }

    @MainActor func testAppleMusicAndNetEasePlaybackControlsUseTheirExistingQueues() {
        for service in ["appleMusic", "netease"] {
            let app = lyricsApp()
            app.launchArguments += ["--quick-settings-service", service]
            openPanel(app)
            let scroll = app.scrollViews["lyricsQuickSettingsScroll"]
            let shuffle = app.switches["quickSettingsShuffle"]
            reveal(shuffle, in: app)
            XCTAssertTrue(shuffle.isHittable)
            XCTAssertEqual(shuffle.value as? String, "0")
            toggle(shuffle)
            let acknowledged = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == '1'"), object: shuffle)
            XCTAssertEqual(XCTWaiter.wait(for: [acknowledged], timeout: 4), .completed)
            let repeatPicker = app.descendants(matching: .any)["quickSettingsRepeat"].firstMatch
            reveal(repeatPicker, in: app)
            repeatPicker.tap()
            app.buttons["单曲循环"].tap()
            XCTAssertTrue(panel(app).exists)
            XCTAssertTrue(displayedText(repeatPicker).contains("单曲循环"))
            let queue = app.buttons["quickSettingsRoute.queue"]
            reveal(queue, in: app)
            queue.tap()
            let title = service == "netease" ? "网易云播放队列" : "系统播放队列"
            XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 4))
            XCTAssertTrue(app.staticTexts["Fixture Song"].exists)
            XCTAssertFalse(panel(app).exists)
            app.navigationBars[title].buttons[service == "netease" ? "完成" : "Done"].tap()
            XCTAssertTrue(app.buttons["lyricsDisplayOptions"].waitForExistence(timeout: 3))
            app.buttons["lyricsDisplayOptions"].tap()
            reveal(shuffle, in: app)
            XCTAssertEqual(shuffle.value as? String, "1", "Reopening controls must preserve the service's acknowledged state.")
            app.buttons["closeLyricsQuickSettings"].tap()
            app.terminate()
        }
    }

    @MainActor private func lyricsApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["--lyrics-ui-testing", "--skip-welcome-ui-testing", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        return app
    }

    @MainActor private func openPanel(_ app: XCUIApplication) {
        app.launch()
        XCTAssertTrue(app.buttons["openNowPlaying"].waitForExistence(timeout: 15))
        app.buttons["openNowPlaying"].tap()
        XCTAssertTrue(app.buttons["lyricsDisplayOptions"].waitForExistence(timeout: 3))
        app.buttons["lyricsDisplayOptions"].tap()
        XCTAssertTrue(panel(app).waitForExistence(timeout: 3))
        XCTAssertGreaterThan(app.scrollViews["lyricsQuickSettingsScroll"].frame.height, 100,
                             "The real panel must provide a usable scroll viewport, not just a header.")
    }

    @MainActor private func panel(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["lyricsQuickSettingsPanel"].firstMatch
    }

    @MainActor private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        let scroll = app.scrollViews["lyricsQuickSettingsScroll"]
        for _ in 0 ..< 16 where !element.isHittable {
            let viewport = scroll.frame
            let direction = element.exists && element.frame.midY < viewport.midY ? 1.0 : -1.0
            // A full inertial swipe can skip a row and oscillate between the
            // two ends of a short viewport. Move a small, fixed distance.
            let start = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            let end = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5 + direction * 0.22))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        XCTAssertTrue(element.isHittable, "Target: \(element.debugDescription), viewport: \(scroll.frame)")
    }

    @MainActor private func toggle(_ element: XCUIElement) {
        // Native switch accessibility includes the label. Tap the switch
        // itself rather than the label's center, which need not toggle it.
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
    }

    @MainActor private func displayedText(_ element: XCUIElement) -> String {
        element.label + " " + (element.value as? String ?? "")
    }

    @MainActor private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
