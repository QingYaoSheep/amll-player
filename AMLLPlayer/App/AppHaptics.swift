import SwiftUI
import UIKit

@MainActor
final class AppHaptics {
    enum Event: Equatable, Sendable {
        case selection, success, roomActivity
    }

    nonisolated static let preferenceKey = "app.haptics.enabled"
    static let shared = AppHaptics()

    private let defaults: UserDefaults
    private let isActive: @MainActor () -> Bool
    private let emit: @MainActor (Event) -> Void

    init(defaults: UserDefaults = .standard,
         isActive: @escaping @MainActor () -> Bool = { UIApplication.shared.applicationState == .active },
         emit: @escaping @MainActor (Event) -> Void = AppHaptics.emitSystemFeedback) {
        self.defaults = defaults
        self.isActive = isActive
        self.emit = emit
    }

    var isEnabled: Bool {
        defaults.object(forKey: Self.preferenceKey) as? Bool ?? true
    }

    func play(_ event: Event) {
        guard isEnabled, isActive() else { return }
        emit(event)
    }

    private static func emitSystemFeedback(_ event: Event) {
        switch event {
        case .selection:
            UISelectionFeedbackGenerator().selectionChanged()
        case .success:
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .roomActivity:
            UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        }
    }
}

extension Binding where Value: Equatable {
    /// Only a control's write can trigger feedback. Model refreshes still use the original binding.
    @MainActor
    func hapticSelection(using haptics: AppHaptics = .shared) -> Binding<Value> {
        Binding(get: { wrappedValue }, set: { value, transaction in
            let changed = value != wrappedValue
            self.transaction(transaction).wrappedValue = value
            if changed { haptics.play(.selection) }
        })
    }
}
