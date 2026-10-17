import Observation
import SwiftUI
import UIKit

/// Device A/B evidence: a non-unit page opacity restores Plus Lighter and the
/// restored composition survives returning to opacity 1. Refresh only once per
/// ordinary Mesh presentation, after its first drawable and entry transition.
@MainActor @Observable
final class LyricsCompositingRecovery {
    enum Phase: String { case inactive, awaitingBackground, awaitingTransition, refreshing, ready }

    private(set) var phase: Phase = .inactive
    private(set) var requestID: UUID?
    private(set) var opacity: Double = 1
    private(set) var completedRefreshes = 0
    @ObservationIgnored private var context: String?
    @ObservationIgnored private var task: Task<Void, Never>?

    func configure(context: String?) {
        guard self.context != context else { return }
        task?.cancel(); task = nil
        self.context = context
        requestID = context.map { _ in UUID() }
        phase = context == nil ? .inactive : .awaitingBackground
        setOpacity(1)
    }

    var backgroundPresentation: AMLLBackgroundPresentation? {
        guard let requestID else { return nil }
        return AMLLBackgroundPresentation(id: requestID) { [weak self] id, window in
            self?.backgroundPresented(id, in: window)
        }
    }

    func backgroundPresented(_ id: UUID, in window: UIWindow) {
        guard requestID == id, phase == .awaitingBackground else { return }
        phase = .awaitingTransition
        var controller = window.rootViewController
        while let presented = controller?.presentedViewController { controller = presented }
        if let transition = controller?.transitionCoordinator,
           transition.animate(alongsideTransition: nil, completion: { [weak self] _ in
               Task { @MainActor [weak self] in self?.beginRefresh(id) }
           }) { return }
        beginRefresh(id)
    }

    func reset() { configure(context: nil) }

    private func beginRefresh(_ id: UUID) {
        guard requestID == id, phase == .awaitingTransition else { return }
        phase = .refreshing
        setOpacity(0.99)
        task = Task { [weak self] in
            // Span several display transactions, with no persistent timer or
            // new display link. Return to the original alpha without animation.
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            guard let self, self.requestID == id, self.phase == .refreshing else { return }
            self.setOpacity(1)
            self.phase = .ready
            self.requestID = nil
            self.completedRefreshes += 1
            self.task = nil
        }
    }

    private func setOpacity(_ value: Double) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) { opacity = value }
    }
}
