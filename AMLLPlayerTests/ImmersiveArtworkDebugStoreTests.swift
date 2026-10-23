@testable import AMLLPlayer
import XCTest

@MainActor final class ImmersiveArtworkDebugStoreTests: XCTestCase {
    func testButtonVisibilityPersistsWithoutChangingLayerCalibration() throws {
        let suite = "artwork-debug-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ImmersiveArtworkDebugStore(defaults: defaults)
        XCTAssertTrue(store.showsButton, "Existing installations retain the visible button")
        store.configuration[.transition].y = 36
        store.configuration.blurRadius = 48
        let tuning = store.configuration
        store.showsButton = false
        let restored = ImmersiveArtworkDebugStore(defaults: defaults)
        XCTAssertFalse(restored.showsButton)
        XCTAssertEqual(restored.configuration, tuning)
        restored.reset()
        XCTAssertFalse(restored.showsButton, "Resetting layers must not change the user's button preference")
        restored.showsButton = true
        XCTAssertTrue(ImmersiveArtworkDebugStore(defaults: defaults).showsButton)
    }
}
