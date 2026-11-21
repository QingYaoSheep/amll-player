@testable import AMLLPlayer
import SwiftUI
import XCTest

@MainActor final class AppHapticsTests: XCTestCase {
    func testFeedbackIsEnabledByDefaultAndRespectsPreferenceAndForeground() throws {
        let suite = "app-haptics-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var active = true
        var events: [AppHaptics.Event] = []
        let haptics = AppHaptics(defaults: defaults, isActive: { active }, emit: { events.append($0) })

        haptics.play(.success)
        defaults.set(false, forKey: AppHaptics.preferenceKey)
        haptics.play(.selection)
        defaults.set(true, forKey: AppHaptics.preferenceKey)
        active = false
        haptics.play(.roomActivity)
        active = true
        haptics.play(.roomActivity)

        XCTAssertEqual(events, [.success, .roomActivity])
    }

    func testSwitchOnlyPulsesForChangedWritesAndFollowsTheNewPreference() throws {
        let suite = "app-haptics-toggle-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var events: [AppHaptics.Event] = []
        let haptics = AppHaptics(defaults: defaults, isActive: { true }, emit: { events.append($0) })
        let toggle = Binding(get: { haptics.isEnabled }, set: { defaults.set($0, forKey: AppHaptics.preferenceKey) })
            .hapticSelection(using: haptics)

        toggle.wrappedValue = true
        toggle.wrappedValue = false
        XCTAssertFalse(haptics.isEnabled)
        XCTAssertTrue(events.isEmpty)
        toggle.wrappedValue = true
        XCTAssertTrue(haptics.isEnabled)
        XCTAssertEqual(events, [.selection])
    }
}
