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
        let expected = Data(#"{"blurRadius":12,"layers":{"background":{"enabled":true,"height":1,"opacity":1,"width":1,"x":0,"y":0},"bottomFade":{"enabled":false,"height":0.14,"opacity":1,"width":1,"x":0,"y":-119},"dimming":{"enabled":true,"height":1,"opacity":0,"width":1,"x":0,"y":0},"reflection":{"enabled":true,"height":0.6,"opacity":1,"width":1,"x":0,"y":-53},"transition":{"enabled":true,"height":2,"opacity":0.99,"width":1,"x":0,"y":206},"video":{"enabled":true,"height":1,"opacity":1,"width":1,"x":0,"y":0}},"order":["transition","reflection","bottomFade","video","dimming","background"],"topFeatherLength":66}"#.utf8)
        XCTAssertEqual(ImmersiveArtworkDebugConfiguration.calibratedDefault,
            try JSONDecoder().decode(ImmersiveArtworkDebugConfiguration.self, from: expected))
    }
}
