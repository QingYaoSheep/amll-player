import Foundation
import Observation

/// Controls visibility of engineering/troubleshooting diagnostics UI.
/// Hidden by default in Release builds; unlocked via 5 taps on the About version badge.
@MainActor @Observable
final class AppDiagnosticsVisibility {
    static let shared = AppDiagnosticsVisibility()
    static let storageKey = "AMLL.advancedDiagnosticsUnlocked.v1"

    var isUnlocked: Bool {
        didSet {
            defaults.set(isUnlocked, forKey: Self.storageKey)
        }
    }

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if defaults.object(forKey: Self.storageKey) != nil {
            isUnlocked = defaults.bool(forKey: Self.storageKey)
        } else {
            #if DEBUG
            isUnlocked = true
            #else
            isUnlocked = false
            #endif
        }
    }

    @discardableResult
    func toggle() -> Bool {
        isUnlocked.toggle()
        return isUnlocked
    }
}
