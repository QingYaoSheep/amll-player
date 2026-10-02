import Foundation

/// Completion and timeout compete on one actor; neither leaves an orphaned continuation.
@MainActor final class NativeSeekAwaiter {
    private var continuation: CheckedContinuation<Bool, any Error>?
    private var timeout: Task<Void, Never>?
    private var outcome: Result<Bool, any Error>?
    func wait(seconds: Double, start: () -> Void) async throws -> Bool {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if let outcome { continuation.resume(with: outcome); return }
                self.continuation = continuation
                timeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(max(0.001, seconds))) } catch { return }
                    self?.finish(.failure(PlaybackSeekError.timedOut))
                }
                start()
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(.failure(CancellationError())) }
        }
    }
    func finish(_ result: Result<Bool, any Error>) {
        guard outcome == nil else { return }
        outcome = result; timeout?.cancel(); timeout = nil
        continuation?.resume(with: result); continuation = nil
    }
}
