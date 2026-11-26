import UIKit
import XCTest

final class TabletLyricsPlayerUITests: XCTestCase {
    @MainActor func testIPadOrdinaryPlayersSurviveRotationAndLyricToggle() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad)
        let device = XCUIDevice.shared
        defer { device.orientation = .portrait }
        for (service, custom) in [("spotify", false), ("appleMusic", true), ("netease", false)] {
            device.orientation = .landscapeLeft
            let app = XCUIApplication()
            app.launchArguments += ["--lyrics-ui-testing", "--skip-welcome-ui-testing", "-AppleLanguages", "(en)",
                "-AppleLocale", "en_US", "--quick-settings-service", service,
                "--quick-settings-preferences-suite", "tablet-lyrics-" + UUID().uuidString]
            if custom { app.launchArguments += ["--lyrics-custom-profile-ui-testing"] }
            app.launch()
            defer { app.terminate() }
            let nowPlaying = app.buttons["openNowPlaying"]
            guard nowPlaying.waitForExistence(timeout: 15) else { XCTFail("Missing Now Playing control"); return }
            nowPlaying.tap()
            waitForOrientation(of: app, landscape: true)
            let toggle = app.buttons["tabletLyricsToggle"]
            guard toggle.waitForExistence(timeout: 5) else { XCTFail("Missing iPad lyric visibility control"); return }
            XCTAssertGreaterThanOrEqual(toggle.frame.height, 44)
            let renderer = app.descendants(matching: .any)[custom ? "nativeLyricsScroll" : "amllNativeLyricsDisplay"].firstMatch
            XCTAssertTrue(renderer.waitForExistence(timeout: 5))
            attach(service + "-landscape", app.screenshot())
            toggle.tap()
            XCTAssertTrue(toggle.isHittable)
            XCTAssertEqual(toggle.label, "Show lyrics")
            toggle.tap()
            XCTAssertTrue(renderer.waitForExistence(timeout: 5))
            device.orientation = .portrait
            waitForOrientation(of: app, landscape: false)
            XCTAssertTrue(toggle.waitForExistence(timeout: 5))
            XCTAssertTrue(toggle.isHittable)
            XCTAssertTrue(renderer.waitForExistence(timeout: 5))
            attach(service + "-portrait", app.screenshot())
        }
    }

    @MainActor private func waitForOrientation(of app: XCUIApplication, landscape: Bool) {
        let orientation = NSPredicate { _, _ in
            let frame = app.frame
            return landscape ? frame.width > frame.height : frame.height > frame.width
        }
        let expectation = XCTNSPredicateExpectation(predicate: orientation, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 8), .completed)
    }

    private func attach(_ name: String, _ screenshot: XCUIScreenshot) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
