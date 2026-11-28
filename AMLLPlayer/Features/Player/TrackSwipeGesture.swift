import SwiftUI

enum TrackSwipeAction: Equatable, Sendable {
    case previous
    case next
}

/// Pure horizontal directional lock, rubberband damping, and skip resolution
/// shared between the immersive lyrics header and compact mini players.
enum TrackSwipeMath {
    static let minimumHorizontalDistance: CGFloat = 12
    static let directionRatio: CGFloat = 1.4
    static let triggerThreshold: CGFloat = 56
    static let predictedThreshold: CGFloat = 100
    static let permittedMaxOffset: CGFloat = 36
    static let restrictedMaxOffset: CGFloat = 14

    static func isHorizontalLock(translation: CGSize) -> Bool {
        abs(translation.width) >= minimumHorizontalDistance
            && abs(translation.width) > abs(translation.height) * directionRatio
    }

    static func dampedOffset(for translationX: CGFloat, canSkipNext: Bool, canSkipPrevious: Bool) -> CGFloat {
        guard translationX.isFinite, translationX != 0 else { return 0 }
        let permitted = translationX < 0 ? canSkipNext : canSkipPrevious
        let limit = permitted ? permittedMaxOffset : restrictedMaxOffset
        let distance = abs(translationX)
        let damped = (distance * limit * 0.55) / (limit + 0.55 * distance)
        let magnitude = min(limit, damped)
        return translationX < 0 ? -magnitude : magnitude
    }

    static func resolvedAction(translationX: CGFloat, predictedX: CGFloat,
                               canSkipNext: Bool, canSkipPrevious: Bool) -> TrackSwipeAction?
    {
        guard translationX.isFinite, predictedX.isFinite else { return nil }
        if translationX < 0, abs(translationX) >= triggerThreshold || -predictedX >= predictedThreshold {
            return canSkipNext ? .next : nil
        }
        if translationX > 0, abs(translationX) >= triggerThreshold || predictedX >= predictedThreshold {
            return canSkipPrevious ? .previous : nil
        }
        return nil
    }
}

struct TrackSwipeSkipModifier: ViewModifier {
    let enabled: Bool
    let canSkipNext: Bool
    let canSkipPrevious: Bool
    let onSkipNext: () -> Void
    let onSkipPrevious: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dragOffset: CGFloat = 0
    @State private var lockedHorizontal = false
    @State private var crossedThreshold = false
    @GestureState private var gestureActive = false

    func body(content: Content) -> some View {
        content
            .offset(x: reduceMotion ? 0 : dragOffset)
            .simultaneousGesture(
                DragGesture(minimumDistance: TrackSwipeMath.minimumHorizontalDistance)
                    .updating($gestureActive) { _, active, _ in active = true }
                    .onChanged { value in
                        guard enabled else { return }
                        if !lockedHorizontal {
                            guard TrackSwipeMath.isHorizontalLock(translation: value.translation) else { return }
                            lockedHorizontal = true
                        }
                        withTransaction(Transaction(animation: nil)) {
                            dragOffset = TrackSwipeMath.dampedOffset(
                                for: value.translation.width,
                                canSkipNext: canSkipNext,
                                canSkipPrevious: canSkipPrevious
                            )
                        }
                        if !crossedThreshold,
                           TrackSwipeMath.resolvedAction(
                               translationX: value.translation.width,
                               predictedX: value.translation.width,
                               canSkipNext: canSkipNext,
                               canSkipPrevious: canSkipPrevious
                           ) != nil
                        {
                            crossedThreshold = true
                            AppHaptics.shared.play(.selection)
                        }
                    }
                    .onEnded { value in
                        guard enabled, lockedHorizontal else {
                            resetDrag()
                            return
                        }
                        let action = TrackSwipeMath.resolvedAction(
                            translationX: value.translation.width,
                            predictedX: value.predictedEndTranslation.width,
                            canSkipNext: canSkipNext,
                            canSkipPrevious: canSkipPrevious
                        )
                        resetDrag()
                        switch action {
                        case .next: onSkipNext()
                        case .previous: onSkipPrevious()
                        case nil: break
                        }
                    },
                including: enabled ? .all : .none
            )
            .onChange(of: gestureActive) { _, active in
                if !active, dragOffset != 0 || lockedHorizontal || crossedThreshold {
                    resetDrag()
                }
            }
    }

    private func resetDrag() {
        lockedHorizontal = false
        crossedThreshold = false
        withAnimation(reduceMotion ? nil : LyricsPageMotion.geometry) {
            dragOffset = 0
        }
    }
}

extension View {
    func trackSwipeToSkip(
        enabled: Bool = true,
        canSkipNext: Bool,
        canSkipPrevious: Bool,
        onSkipNext: @escaping () -> Void,
        onSkipPrevious: @escaping () -> Void
    ) -> some View {
        modifier(TrackSwipeSkipModifier(
            enabled: enabled,
            canSkipNext: canSkipNext,
            canSkipPrevious: canSkipPrevious,
            onSkipNext: onSkipNext,
            onSkipPrevious: onSkipPrevious
        ))
    }
}
