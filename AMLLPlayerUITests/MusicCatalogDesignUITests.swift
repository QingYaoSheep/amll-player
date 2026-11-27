import UIKit
import XCTest

final class MusicCatalogDesignUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor func testGlassIsContinuousBelowTheHandleInRoomAndQueue() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--lyrics-ui-testing", "--skip-welcome-ui-testing", "--quick-settings-service", "netease"]
        app.launch()
        let player = app.buttons["openNowPlaying"]
        XCTAssertTrue(player.waitForExistence(timeout: 12))
        player.tap()
        let settings = app.buttons["lyricsDisplayOptions"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()
        let scroll = app.scrollViews["lyricsQuickSettingsScroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 5))

        for identifier in ["quickSettingsNetEaseListeningRoom", "quickSettingsRoute.queue"] {
            let route = app.buttons[identifier]
            for _ in 0 ..< 6 where !route.isHittable { scroll.swipeUp(velocity: .slow) }
            XCTAssertTrue(route.isHittable)
            route.tap()
            let title = app.staticTexts["lyricsQuickSettingsDestinationTitle"]
            XCTAssertTrue(title.waitForExistence(timeout: 5))
            try assertNoGlassSeam(in: app, name: identifier)
            if identifier == "quickSettingsNetEaseListeningRoom" {
                let inbox = app.buttons["netEaseRoomInbox"]
                XCTAssertTrue(inbox.isHittable)
                inbox.tap()
                let inboxTitle = app.staticTexts.matching(NSPredicate(
                    format: "label == 'Received Invitations' OR label == '收到的邀请'")).firstMatch
                XCTAssertTrue(inboxTitle.waitForExistence(timeout: 5))
                app.buttons["backLyricsQuickSettingsChild"].tap()
                XCTAssertTrue(inbox.waitForExistence(timeout: 5))
            }
            app.buttons["backLyricsQuickSettingsDestination"].tap()
            XCTAssertTrue(scroll.waitForExistence(timeout: 5))
        }
    }

    @MainActor private func assertNoGlassSeam(in app: XCUIApplication, name: String) throws {
        let handle = app.descendants(matching: .any)["lyricsQuickSettingsHandle"].firstMatch.frame
        XCTAssertEqual(handle.height, 44, accuracy: 1)
        let screen = app.frame
        let capture = app.screenshot()
        let attachment = XCTAttachment(screenshot: capture)
        attachment.name = name + "-glass"
        attachment.lifetime = .keepAlways
        add(attachment)
        let image = try XCTUnwrap(capture.image.cgImage)
        let scaleX = CGFloat(image.width) / screen.width
        let scaleY = CGFloat(image.height) / screen.height

        let jumps = try (2 ... 8).map { column -> Double in
            let x = (handle.minX - screen.minX + handle.width * CGFloat(column) / 10) * scaleX
            let y = handle.maxY - screen.minY
            let above = try pixelLuminance(image, x: Int(x), y: Int((y - 1) * scaleY))
            let below = try pixelLuminance(image, x: Int(x), y: Int((y + 1) * scaleY))
            return abs(above - below)
        }.sorted()
        XCTAssertLessThan(jumps[jumps.count / 2], 12,
                          "A full-width brightness step at the bottom of the handle indicates a second backdrop: \(jumps)")
    }

    private func pixelLuminance(_ image: CGImage, x: Int, y: Int) throws -> Double {
        let rect = CGRect(x: x, y: y, width: 1, height: 1)
        let pixel = try XCTUnwrap(image.cropping(to: rect))
        var rgba = [UInt8](repeating: 0, count: 4)
        try rgba.withUnsafeMutableBytes { bytes in
            let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
            let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                bytesPerRow: 4, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(pixel, in: CGRect(origin: .zero, size: rect.size))
        }
        return 0.2126 * Double(rgba[0]) + 0.7152 * Double(rgba[1]) + 0.0722 * Double(rgba[2])
    }

    @MainActor func testNetEaseLyricsRoomCapsuleOpensDetailsAndFriendChat() {
        let app = XCUIApplication()
        app.launchArguments += ["--lyrics-ui-testing", "--netease-room-ui-testing", "--skip-welcome-ui-testing",
            "--quick-settings-service", "netease", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let miniPlayer = app.descendants(matching: .any)["miniPlayerBar"].firstMatch
        XCTAssertTrue(miniPlayer.waitForExistence(timeout: 12))
        miniPlayer.tap()
        let capsule = app.buttons["netEaseLyricsRoomCapsule"]
        XCTAssertTrue(capsule.waitForExistence(timeout: 12))
        let banner = app.buttons["netEaseRoomBanner"]
        let bannerGone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: banner)
        XCTAssertEqual(XCTWaiter.wait(for: [bannerGone], timeout: 8), .completed)
        XCTAssertGreaterThanOrEqual(capsule.frame.height, 44)
        XCTAssertTrue((capsule.value as? String)?.contains("Fixture Friend") == true)
        let capsuleHittable = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"),
                                                        object: capsule)
        XCTAssertEqual(XCTWaiter.wait(for: [capsuleHittable], timeout: 4), .completed,
                       "The room capsule must receive a tap outside the status bar")
        if app.frame.width < 550, app.frame.height > app.frame.width {
            XCTAssertGreaterThanOrEqual(capsule.frame.minY, 64, "Keep the room capsule below the Dynamic Island")
        }
        let initialTimeLabel = capsule.label
        let clockTicks = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != %@", initialTimeLabel),
                                                   object: capsule)
        XCTAssertEqual(XCTWaiter.wait(for: [clockTicks], timeout: 4), .completed)
        capture(app, "NetEase-lyrics-room-capsule")
        capsule.tap()
        let header = app.staticTexts["lyricsQuickSettingsDestinationTitle"]
        XCTAssertTrue(header.waitForExistence(timeout: 8), "The room capsule must open the shared glass panel.")
        let chat = app.buttons["netEaseDuetChat"]
        XCTAssertTrue(chat.waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["backLyricsQuickSettingsDestination"].exists)
        XCTAssertTrue(app.buttons["netEaseRoomAddSong"].exists)
        capture(app, "NetEase-room-detail")
        chat.tap()
        XCTAssertTrue(app.staticTexts["你好"].firstMatch.waitForExistence(timeout: 8))
        app.buttons["netEaseDuetChatClose"].tap()
        let add = app.buttons["netEaseRoomAddSong"]
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        add.tap()
        let song = app.buttons["netEasePickSong:42"]
        XCTAssertTrue(song.waitForExistence(timeout: 5))
        song.tap()
        XCTAssertTrue(app.staticTexts["You added \"Fixture Song\""].firstMatch.waitForExistence(timeout: 8))
        let headerY = header.frame.minY
        let roomContent = app.descendants(matching: .any)["netEaseRoomContent"].firstMatch
        XCTAssertTrue(roomContent.exists)
        roomContent.swipeUp()
        XCTAssertEqual(header.frame.minY, headerY, accuracy: 2)
        XCTAssertFalse(app.navigationBars["Listen Together"].isHittable)
        capture(app, "NetEase-room-detail-scrolled")
        app.buttons["closeLyricsQuickSettingsDestination"].tap()
        XCTAssertTrue(capsule.waitForExistence(timeout: 5))
    }

    @MainActor func testNetEaseFriendsOpensPrivateConversationAndSharesTheCurrentSong() {
        let app = XCUIApplication()
        app.launchArguments += ["--catalog-ui-testing", "--netease-friends-ui-testing", "--skip-welcome-ui-testing",
            "--quick-settings-service", "netease", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let friends = app.buttons["netEaseFriends"]
        XCTAssertTrue(friends.waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Fixture Song"].waitForExistence(timeout: 8))
        friends.tap()
        let conversation = app.buttons["netEaseConversation:2"]
        XCTAssertTrue(conversation.waitForExistence(timeout: 8))
        capture(app, "NetEase-recent-conversations")
        let contacts = app.buttons["netEaseContacts"]
        XCTAssertTrue(contacts.isHittable)
        contacts.tap()
        let friend = app.buttons["netEaseContact:2"]
        XCTAssertTrue(friend.waitForExistence(timeout: 8))
        capture(app, "NetEase-contacts")
        friend.tap()
        XCTAssertTrue(app.staticTexts["你好"].firstMatch.waitForExistence(timeout: 8))
        let share = app.buttons["netEaseShareSong"]
        XCTAssertTrue(share.exists)
        share.tap()
        let current = app.buttons["netEasePickSong:42"]
        XCTAssertTrue(current.waitForExistence(timeout: 5))
        current.tap()
        let send = app.buttons["netEaseSendMessage"]
        XCTAssertTrue(send.waitForExistence(timeout: 3))
        XCTAssertTrue(send.isEnabled)
        send.tap()
        XCTAssertTrue(app.buttons["Play Song"].firstMatch.waitForExistence(timeout: 8))
        let draft = app.descendants(matching: .any)["netEaseMessageDraft"].firstMatch
        XCTAssertTrue(draft.exists)
        draft.tap()
        draft.typeText("Hello from AMLL")
        send.tap()
        XCTAssertTrue(app.staticTexts["Hello from AMLL"].firstMatch.waitForExistence(timeout: 6))
        capture(app, "NetEase-private-conversation-song-card")
    }

    @MainActor func testHomePostersAccountMenuAndLongPressActions() {
        let app = launch()
        let card = app.descendants(matching: .any)["homeCard:track:song0"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(card.frame.height, card.frame.width)
        XCTAssertFalse(app.buttons["catalogPlay-track:song0"].exists, "Home cards must not carry an overlapping play button")
        capture(app, "AppleStyle-home-posters")
        card.press(forDuration: 0.8)
        XCTAssertTrue(app.buttons["Play"].waitForExistence(timeout: 3))
        capture(app, "AppleStyle-home-context-menu")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.1)).tap()
        app.buttons["musicSourceMenu"].tap()
        XCTAssertTrue(app.buttons["openSettings"].waitForExistence(timeout: 3))
        capture(app, "AppleStyle-home-account-menu")
    }

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
        XCTAssertEqual(expand.label, "Show Less")
        let duplicate = app.buttons.matching(identifier: "catalogPlay-track:repeated")
        reveal(duplicate.firstMatch, app)
        XCTAssertEqual(duplicate.count, 2, "Duplicate playlist entries must retain their independent positions")
        XCTAssertGreaterThanOrEqual(duplicate.firstMatch.frame.width, 44)
        XCTAssertGreaterThanOrEqual(duplicate.firstMatch.frame.height, 44)
        let rowStep = duplicate.element(boundBy: 1).frame.minY - duplicate.element(boundBy: 0).frame.minY
        XCTAssertEqual(rowStep, 52, accuracy: 2)
        capture(app, "WWDC-playlist-repeated-entries")
    }

    @MainActor func testPersonalFMStartsFromHomeAndRestoresOrdinaryQueue() {
        let app = XCUIApplication()
        app.launchArguments += ["--catalog-ui-testing", "--home-fm-ui-testing", "--skip-welcome-ui-testing",
            "--quick-settings-service", "netease", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let fm = app.buttons["homePersonalFM"]
        let featured = app.scrollViews["musicHomeFeatured"]
        XCTAssertTrue(featured.waitForExistence(timeout: 8))
        for _ in 0..<3 {
            if fm.exists && featured.frame.contains(fm.frame) { break }
            featured.swipeLeft()
        }
        XCTAssertTrue(fm.isHittable)
        XCTAssertTrue(app.staticTexts["Fixture Song"].waitForExistence(timeout: 8), "An ordinary queue must exist before entering FM")
        fm.tap()
        let options = app.buttons["lyricsDisplayOptions"]
        XCTAssertTrue(options.waitForExistence(timeout: 8))
        options.tap()
        let panel = app.scrollViews["lyricsQuickSettingsScroll"]
        XCTAssertTrue(panel.waitForExistence(timeout: 3))
        let shuffle = app.buttons["quickSettingsShuffle"]
        let queue = app.buttons["quickSettingsRoute.queue"]
        for _ in 0..<16 {
            if queue.exists && queue.isHittable { break }
            // Match the existing quick-settings tests: a small bidirectional
            // drag cannot skip the route as a full inertial swipe can.
            let direction = queue.exists && queue.frame.midY < panel.frame.midY ? 1.0 : -1.0
            let start = panel.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            let end = panel.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5 + direction * 0.22))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        XCTAssertTrue(shuffle.exists)
        XCTAssertFalse(shuffle.isEnabled, "FM must keep random playback disabled")
        capture(app, "AppleStyle-FM-queue-route-before-open")
        XCTAssertTrue(queue.isHittable, "Target: \(queue.debugDescription), viewport: \(panel.frame)"); queue.tap()
        XCTAssertTrue(app.navigationBars["NetEase Queue"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["FM Song 100"].exists)
        XCTAssertFalse(app.buttons["Edit"].exists)
        capture(app, "AppleStyle-personal-FM-queue")
        app.buttons["exitPersonalFM"].tap()
        XCTAssertTrue(app.staticTexts["Fixture Song"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["exitPersonalFM"].exists)
        XCTAssertTrue(app.buttons["Edit"].exists)
        capture(app, "AppleStyle-restored-ordinary-queue")
    }

    @MainActor func testArtistHighlightsAndAlbumNavigation() {
        let app = launch()
        capture(app, "WWDC-home-artist-flow")
        selectTab("Library", app)
        let artists = app.buttons["Followed artists"]
        XCTAssertTrue(artists.waitForExistence(timeout: 5))
        let categories = app.descendants(matching: .any)["catalogLibraryCategories"].firstMatch
        XCTAssertTrue(categories.waitForExistence(timeout: 5))
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
        // Switch from the real root toolbar while the other tab retains its
        // old detail route; source changes must clear that inactive route too.
        selectTab("Home", app)
        app.buttons["musicSourceMenu"].tap()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Apple Music ·")).firstMatch.tap()
        XCTAssertTrue(app.buttons["musicSourceMenu"].waitForExistence(timeout: 5))
        selectTab("Search", app)
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
        XCTAssertEqual(expand.label, "Show Less")
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
        XCTAssertTrue(app.staticTexts["Featured for Test Listener"].waitForExistence(timeout: 5))
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
