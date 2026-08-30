import Foundation
import Observation
import SwiftUI

enum AppSection: Hashable {
    case player
    case settings
}

@MainActor
@Observable
final class AppModel {
    var selectedSection: AppSection = .player
    private(set) var sessionState: SpotifySessionState
    private(set) var playbackSnapshot: PlaybackSnapshot?
    private(set) var devicesState: LoadableState<[PlaybackDevice]> = .idle
    private(set) var isPerformingAction = false
    var presentedError: SpotifyServiceError?

    let environment: AppEnvironment

    @ObservationIgnored private var sessionTask: Task<Void, Never>?
    @ObservationIgnored private var playbackTask: Task<Void, Never>?
    @ObservationIgnored private var clock = PlayerClock()
    @ObservationIgnored private var prepared = false

    init(environment: AppEnvironment) {
        self.environment = environment
        self.sessionState = environment.spotifySession.currentState
    }

    deinit {
        sessionTask?.cancel()
        playbackTask?.cancel()
    }

    func prepare() {
        guard !prepared else {
            return
        }
        prepared = true
        environment.spotifyPlayback.start()

        sessionTask = Task { [weak self] in
            guard let self else {
                return
            }
            for await state in environment.spotifySession.sessionStates {
                guard !Task.isCancelled else {
                    return
                }
                sessionState = state
                if case let .failed(error) = state, error != .notConfigured {
                    presentedError = error
                }
            }
        }

        playbackTask = Task { [weak self] in
            guard let self else {
                return
            }
            for await snapshot in environment.spotifyPlayback.playbackSnapshots {
                guard !Task.isCancelled else {
                    return
                }
                playbackSnapshot = snapshot
                clock = PlayerClock(anchor: snapshot)
            }
        }
    }

    func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .active:
            environment.spotifyPlayback.enterForeground()
        case .background:
            environment.spotifyPlayback.enterBackground()
        case .inactive:
            break
        @unknown default:
            environment.spotifyPlayback.enterBackground()
        }
    }

    func handleOpenURL(_ url: URL) {
        _ = environment.spotifySession.handleRedirectURL(url)
    }

    func authorize() {
        do {
            try environment.spotifySession.authorize()
        } catch {
            present(error)
        }
    }

    func logout() {
        environment.spotifySession.logout()
        playbackSnapshot = nil
        devicesState = .idle
        clock = PlayerClock()
    }

    func refreshPlayback() async {
        await perform {
            try await environment.spotifyPlayback.refresh()
        }
    }

    func togglePlayPause() async {
        await perform {
            if playbackSnapshot?.isPlaying == true {
                try await environment.spotifyPlayback.pause()
            } else {
                try await environment.spotifyPlayback.play()
            }
        }
    }

    func skipNext() async {
        await perform { try await environment.spotifyPlayback.skipNext() }
    }

    func skipPrevious() async {
        await perform { try await environment.spotifyPlayback.skipPrevious() }
    }

    func seek(to position: TimeInterval) async {
        await perform {
            try await environment.spotifyPlayback.seek(to: position)
        }
    }

    func setVolume(percent: Int, deviceID: String?) async {
        await perform {
            try await environment.spotifyPlayback.setVolume(
                percent: percent,
                on: deviceID
            )
        }
    }

    func loadDevices() async {
        devicesState = .loading
        do {
            devicesState = .loaded(try await environment.spotifyPlayback.devices())
        } catch {
            let appError = mapped(error)
            devicesState = .failed(.unavailable(appError.localizedDescription))
            presentedError = appError
        }
    }

    func transferPlayback(to deviceID: String) async {
        await perform {
            try await environment.spotifyPlayback.transferPlayback(to: deviceID)
            await loadDevices()
        }
    }

    func progress(at uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) -> TimeInterval {
        clock.position(at: uptime)
    }

    private func perform(_ operation: () async throws -> Void) async {
        guard !isPerformingAction else {
            return
        }
        isPerformingAction = true
        defer { isPerformingAction = false }

        do {
            try await operation()
        } catch {
            present(error)
        }
    }

    private func present(_ error: Error) {
        presentedError = mapped(error)
    }

    private func mapped(_ error: Error) -> SpotifyServiceError {
        error as? SpotifyServiceError ?? .transport
    }
}
