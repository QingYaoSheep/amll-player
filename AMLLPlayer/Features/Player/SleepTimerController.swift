import Foundation
import Observation

enum SleepTimerMode: Equatable, Sendable {
    case off
    case until(Date)
    case endOfTrack(trackURI: String)
}

enum SleepTimerPreset: String, CaseIterable, Identifiable, Sendable {
    case fifteenMinutes
    case thirtyMinutes
    case fortyFiveMinutes
    case sixtyMinutes
    case endOfTrack

    var id: String { rawValue }

    var minutes: Int? {
        switch self {
        case .fifteenMinutes: 15
        case .thirtyMinutes: 30
        case .fortyFiveMinutes: 45
        case .sixtyMinutes: 60
        case .endOfTrack: nil
        }
    }

    var titleKey: String {
        switch self {
        case .fifteenMinutes: "sleepTimer.15m"
        case .thirtyMinutes: "sleepTimer.30m"
        case .fortyFiveMinutes: "sleepTimer.45m"
        case .sixtyMinutes: "sleepTimer.60m"
        case .endOfTrack: "sleepTimer.endOfTrack"
        }
    }
}

/// Cross-service playback sleep timer. Uses an absolute deadline so foreground
/// countdown stays exact, and clears expired deadlines silently on wake.
@MainActor
@Observable
final class SleepTimerController {
    private(set) var mode: SleepTimerMode = .off
    var isActive: Bool { mode != .off }

    @ObservationIgnored private var timerTask: Task<Void, Never>?
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private let sleep: @Sendable (TimeInterval) async throws -> Void
    @ObservationIgnored var onTriggerPause: (@MainActor () async -> Void)?

    init(
        now: @escaping @MainActor () -> Date = Date.init,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
            try await Task.sleep(for: .seconds(seconds))
        },
        onTriggerPause: (@MainActor () async -> Void)? = nil
    ) {
        self.now = now
        self.sleep = sleep
        self.onTriggerPause = onTriggerPause
    }

    deinit {
        timerTask?.cancel()
    }

    func start(minutes: Int) {
        guard minutes > 0 else { return }
        let deadline = now().addingTimeInterval(TimeInterval(minutes * 60))
        schedule(until: deadline)
    }

    func extend(minutes: Int = 5) {
        guard minutes > 0, case let .until(deadline) = mode else { return }
        let base = max(now(), deadline)
        schedule(until: base.addingTimeInterval(TimeInterval(minutes * 60)))
    }

    func startEndOfTrack(currentTrackURI: String?) {
        timerTask?.cancel()
        timerTask = nil
        guard let uri = currentTrackURI, !uri.isEmpty else {
            mode = .off
            return
        }
        mode = .endOfTrack(trackURI: uri)
    }

    func cancel() {
        timerTask?.cancel()
        timerTask = nil
        mode = .off
    }

    func handleTrackChange(previousURI: String?, currentURI: String?, isPlaying: Bool) {
        guard case let .endOfTrack(targetURI) = mode else { return }
        guard previousURI == targetURI, currentURI != targetURI else { return }
        mode = .off
        guard isPlaying else { return }
        Task { [weak self] in
            await self?.onTriggerPause?()
        }
    }

    func reconcileOnForeground() {
        guard case let .until(deadline) = mode else { return }
        if now() >= deadline {
            cancel()
        }
    }

    func remainingSeconds(at date: Date? = nil) -> Int? {
        guard case let .until(deadline) = mode else { return nil }
        return max(0, Int(ceil(deadline.timeIntervalSince(date ?? now()))))
    }

    static func formattedDuration(_ totalSeconds: Int) -> String {
        let clamped = max(0, totalSeconds)
        let hours = clamped / 3_600
        let minutes = (clamped % 3_600) / 60
        let seconds = clamped % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    private func schedule(until deadline: Date) {
        timerTask?.cancel()
        mode = .until(deadline)
        let delay = max(0, deadline.timeIntervalSince(now()))
        let sleepOperation = sleep
        timerTask = Task { [weak self] in
            do {
                if delay > 0 {
                    try await sleepOperation(delay)
                }
                guard !Task.isCancelled, let self, self.mode == .until(deadline) else { return }
                self.mode = .off
                self.timerTask = nil
                await self.onTriggerPause?()
            } catch {}
        }
    }
}
