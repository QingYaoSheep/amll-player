import UIKit
import XCTest

final class AMLLPlayerUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor func testActualLyricsAddLightAtRestThroughTheProductionZoomPresentation() throws {
        try assertActualLyricBlending(forceMetal: false)
    }

    @MainActor func testActualMetalLyricsAddLightAtRestThroughTheProductionZoomPresentation() throws {
        try assertActualLyricBlending(forceMetal: true)
    }

    @MainActor func testActualMeshBackedMetalLyricsAddLightAtRestThroughTheProductionZoomPresentation() throws {
        try assertActualLyricBlending(forceMetal: true, mesh: true)
    }

    @MainActor func testActualMeshColorMode2MetalLyricsAddLightAtRestThroughTheProductionZoomPresentation() throws {
        try assertActualLyricBlending(forceMetal: true, mesh: true, meshColorMode2: true)
    }

    @MainActor func testMetalBackgroundSharesTheLyricScrollCompositingDestination() throws {
        try assertActualLyricBlending(forceMetal: true, mesh: true, meshColorMode2: true, requireSharedBackdrop: true)
    }

    @MainActor private func assertActualLyricBlending(forceMetal: Bool, mesh: Bool = false, meshColorMode2: Bool = false,
                                                    requireSharedBackdrop: Bool = false) throws {
        var captures: [[UInt8]] = []
        var rowFrames: [CGRect] = []
        var pixelSizes: [CGSize] = []
        var screenshotSizes: [CGSize] = []
        for normal in [true, false] {
            let app = XCUIApplication()
            app.launchArguments += ["--lyrics-ui-testing", "--lyrics-blending-ui-testing", "--skip-welcome-ui-testing",
                                    "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
            if normal { app.launchArguments += ["--lyrics-blend-normal-ui-testing"] }
            if forceMetal { app.launchArguments += ["--lyrics-blending-metal-ui-testing"] }
            if mesh { app.launchArguments += ["--lyrics-blending-mesh-ui-testing"] }
            if meshColorMode2 { app.launchArguments += ["--lyrics-blending-mesh2-ui-testing"] }
            app.launch()
            waitForLyricsEntry(app)
            app.buttons["openNowPlaying"].tap()
            let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "MMMMWWWW")).firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 5))
            if forceMetal {
                let metalReady = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value BEGINSWITH 'HDR_METAL_READY:'"), object: row)
                XCTAssertEqual(XCTWaiter.wait(for: [metalReady], timeout: 15), .completed)
                if requireSharedBackdrop {
                    XCTAssertTrue((row.value as? String)?.contains("sharedBackdrop:true") == true,
                                  "The real Metal backdrop and lyrics must share the native scrolling destination: \(row.value ?? "missing")")
                }
            }
            let screen = app.frame
            var previousFrame: CGRect?
            let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                guard row.exists else { previousFrame = nil; return false }
                let frame = row.frame
                guard frame.width > 20, frame.height > 10, screen.intersects(frame) else { previousFrame = nil; return false }
                defer { previousFrame = frame }
                return frame == previousFrame
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 15), .completed, row.debugDescription)
            let rowFrame = row.frame
            let image = app.screenshot().image
            let screenshot = try XCTUnwrap(image.cgImage)
            let attachment = XCTAttachment(image: image)
            attachment.name = "\(forceMetal ? "Metal" : "SDR") " + (normal ? "Actual lyrics normal blend at rest" : "Actual lyrics Plus Lighter at rest")
            attachment.lifetime = .keepAlways
            add(attachment)
            let scaleX = CGFloat(screenshot.width) / screen.width
            let scaleY = CGFloat(screenshot.height) / screen.height
            XCTAssertEqual(scaleX, scaleY, accuracy: 0.001)
            let region = CGRect(x: (rowFrame.minX - screen.minX) * scaleX, y: (rowFrame.minY - screen.minY) * scaleY,
                                width: rowFrame.width * scaleX, height: rowFrame.height * scaleY).integral
            let cropped = try XCTUnwrap(screenshot.cropping(to: region))
            rowFrames.append(rowFrame)
            pixelSizes.append(CGSize(width: CGFloat(cropped.width), height: CGFloat(cropped.height)))
            screenshotSizes.append(CGSize(width: CGFloat(screenshot.width), height: CGFloat(screenshot.height)))
            let geometry = XCTAttachment(string: "screen=\(screen)\nrow=\(rowFrame)\nROI=\(region)\npixels=\(screenshot.width)x\(screenshot.height)\nUIImageScale=\(image.scale)\nactualScale=\(scaleX),\(scaleY)\n")
            geometry.name = normal ? "Normal glyph geometry" : "Additive glyph geometry"
            geometry.lifetime = .keepAlways
            add(geometry)
            var pixels = [UInt8](repeating: 0, count: cropped.width * cropped.height * 4)
            try pixels.withUnsafeMutableBytes { bytes in
                let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: cropped.width, height: cropped.height,
                    bitsPerComponent: 8, bytesPerRow: cropped.width * 4,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.draw(cropped, in: CGRect(x: 0, y: 0, width: cropped.width, height: cropped.height))
            }
            captures.append(pixels)
            app.terminate()
        }
        let normal = captures[0], additive = captures[1]
        XCTAssertEqual(rowFrames[0], rowFrames[1])
        XCTAssertEqual(pixelSizes[0], pixelSizes[1])
        XCTAssertEqual(screenshotSizes[0], screenshotSizes[1])
        XCTAssertEqual(normal.count, additive.count, "The same paused production lyric must keep identical geometry")
        guard normal.count == additive.count else { return }
        let normalBackground = stride(from: 0, to: normal.count, by: 4).map { Int(normal[$0]) }.min() ?? 0
        let additiveBackground = stride(from: 0, to: additive.count, by: 4).map { Int(additive[$0]) }.min() ?? 0
        XCTAssertLessThanOrEqual(abs(normalBackground - additiveBackground), 2)
        XCTAssertGreaterThan(normalBackground, mesh ? 30 : 100)
        XCTAssertLessThan(normalBackground, mesh ? 230 : 160)
        // Only actual semi-transparent glyph pixels, excluding the middle-gray
        // backdrop and the already-white filled edge. No synthetic color tile.
        let deltas = stride(from: 0, to: normal.count, by: 4).compactMap { index -> Int? in
            let value = Int(normal[index])
            guard value > 140, value < 245 else { return nil }
            return Int(additive[index]) - value
        }.sorted()
        XCTAssertGreaterThan(deltas.count, 100)
        guard !deltas.isEmpty else { return }
        let median = deltas[deltas.count / 2]
        let metrics = XCTAttachment(string: "glyphSamples=\(deltas.count)\nSDRLighteningMedian=\(median)\n")
        metrics.name = "Production native lyric additive contribution at rest"
        metrics.lifetime = .keepAlways
        add(metrics)
        XCTAssertGreaterThan(median, 8, "Plus Lighter must add light to the real backdrop at rest, before any dismissal gesture")
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
        let visibility = app.buttons["toggleLyricsVisibility"]
        XCTAssertTrue(visibility.waitForExistence(timeout: 3))
        // Existence/hittability alone does not mean the bottom panel has
        // finished moving. A tap calculated mid-transition can miss its row.
        var previousFrame: CGRect?
        let panelReady = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard visibility.isHittable else { previousFrame = nil; return false }
            let frame = visibility.frame
            defer { previousFrame = frame }
            return frame == previousFrame
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [panelReady], timeout: 5), .completed)
        XCTAssertEqual(visibility.value as? String, "On")
        visibility.tap()
        let hidden = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == 'Off'"), object: visibility)
        XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 3), .completed)
        visibility.tap()
        let shown = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == 'On'"), object: visibility)
        XCTAssertEqual(XCTWaiter.wait(for: [shown], timeout: 3), .completed)
        app.buttons["closeLyricsQuickSettings"].tap()
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
