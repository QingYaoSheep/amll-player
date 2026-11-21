@testable import AMLLPlayer
import XCTest

@MainActor final class ImmersiveArtworkDebugStoreTests: XCTestCase {
    func testButtonVisibilityPersistsWithoutChangingLayerCalibration() throws {
        let suite = "artwork-debug-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ImmersiveArtworkDebugStore(defaults: defaults)
        XCTAssertEqual(store.configuration, .calibratedDefault)
        XCTAssertTrue(store.showsButton, "Existing installations retain the visible button")
        store.configuration[.transition].y = 36
        store.configuration.blurRadius = 48
        let tuning = store.configuration
        store.showsButton = false
        let restored = ImmersiveArtworkDebugStore(defaults: defaults)
        XCTAssertFalse(restored.showsButton)
        XCTAssertEqual(restored.configuration, tuning)
        restored.reset()
        XCTAssertEqual(restored.configuration, .calibratedDefault)
        XCTAssertFalse(restored.showsButton, "Resetting layers must not change the user's button preference")
        restored.showsButton = true
        XCTAssertTrue(ImmersiveArtworkDebugStore(defaults: defaults).showsButton)
    }

    func testApprovedDefaultMatchesTheProvidedCalibration() throws {
        let expected = Data(#"{"blurRadius":10,"layers":{"background":{"enabled":true,"height":1,"opacity":1,"width":1,"x":0,"y":0},"bottomFade":{"enabled":false,"height":0.17,"opacity":1,"width":1,"x":0,"y":-224},"dimming":{"enabled":true,"height":1,"opacity":0.12,"width":1,"x":0,"y":0},"reflection":{"enabled":true,"height":0.41000000000000003,"opacity":0.9400000000000001,"width":1,"x":0,"y":-78},"transition":{"enabled":true,"height":2,"opacity":1,"width":1,"x":0,"y":174},"video":{"enabled":true,"height":1,"opacity":1,"width":1,"x":0,"y":0}},"order":["transition","reflection","bottomFade","video","dimming","background"],"topFeatherLength":80}"#.utf8)
        XCTAssertEqual(ImmersiveArtworkDebugConfiguration.calibratedDefault,
            try JSONDecoder().decode(ImmersiveArtworkDebugConfiguration.self, from: expected))
    }

    func testUpgradeReplacesThePreviousPresetAndEnablesCustomReflection() throws {
        let suite = "artwork-upgrade-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = "AMLL.temporaryImmersiveLayerTuning.v1"
        var old = ImmersiveArtworkDebugConfiguration.calibratedDefault
        old.blurRadius = 12
        old.topFeatherLength = 66
        old[.dimming].opacity = 0
        old[.bottomFade] = .init(enabled: false, y: -119, height: 0.14)
        old[.reflection] = .init(y: -53, height: 0.6)
        old[.transition] = .init(y: 206, height: 2, opacity: 0.99)
        defaults.set(try JSONEncoder().encode(old), forKey: key)
        XCTAssertEqual(ImmersiveArtworkDebugStore(defaults: defaults).configuration, .calibratedDefault)

        old[.reflection].enabled = false
        old[.reflection].y = -40
        defaults.set(try JSONEncoder().encode(old), forKey: key)
        let custom = ImmersiveArtworkDebugStore(defaults: defaults).configuration
        XCTAssertTrue(custom[.reflection].enabled)
        XCTAssertEqual(custom[.reflection].y, -40)
        XCTAssertEqual(custom.blurRadius, 12)
    }
}
