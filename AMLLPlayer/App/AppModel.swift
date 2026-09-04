import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class AppModel {
    private(set) var sessionState: SpotifySessionState
    private(set) var playbackSnapshot: PlaybackSnapshot?
    private(set) var devicesState: LoadableState<[PlaybackDevice]> = .idle
    private(set) var isPerformingAction = false
    var presentedError: SpotifyServiceError?

    private(set) var environment: AppEnvironment
    private(set) var isBrowserLoginInProgress = false

    var isSpotifyLoginBusy: Bool {
        if isBrowserLoginInProgress {
            return true
        }
        switch sessionState {
        case .authorizing, .refreshing:
            return true
        default:
            return false
        }
    }

    @ObservationIgnored private var sessionTask: Task<Void, Never>?
    @ObservationIgnored private var playbackTask: Task<Void, Never>?
    @ObservationIgnored private var clock = PlayerClock()
    @ObservationIgnored private var prepared = false
    @ObservationIgnored private var isForeground = false
    @ObservationIgnored private let clientIDStore: SpotifyClientIDStore
    @ObservationIgnored private let environmentFactory: @MainActor (AppConfiguration) -> AppEnvironment

    init(
        environment: AppEnvironment,
        clientIDStore: SpotifyClientIDStore = SpotifyClientIDStore(),
        environmentFactory: @escaping @MainActor (AppConfiguration) -> AppEnvironment = {
            AppEnvironment.make(configuration: $0)
        }
    ) {
        self.environment = environment
        self.clientIDStore = clientIDStore
        self.environmentFactory = environmentFactory
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
            isForeground = true
            environment.spotifyPlayback.enterForeground()
        case .background:
            isForeground = false
            environment.spotifyPlayback.enterBackground()
        case .inactive:
            break
        @unknown default:
            isForeground = false
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

    func authorizeInBrowser(clientID: String? = nil) async {
        guard !isSpotifyLoginBusy, !isPerformingAction else {
            return
        }
        isBrowserLoginInProgress = true
        defer { isBrowserLoginInProgress = false }

        do {
            if let clientID {
                try configureSpotify(clientID: clientID)
            }
            try await environment.spotifySession.authorizeInBrowser()
        } catch is CancellationError {
            return
        } catch {
            present(error)
        }
    }

    func logout() {
        environment.spotifySession.logout()
        sessionState = .signedOut
        playbackSnapshot = nil
        devicesState = .idle
        clock = PlayerClock()
    }

    func configureSpotify(clientID value: String) throws {
        guard let clientID = SpotifyClientIDStore.normalized(value) else {
            throw SpotifyServiceError.notConfigured
        }
        let configuration = environment.configuration.overridingSpotifyClientID(clientID)
        if let error = configuration.spotifyConfigurationError {
            throw error
        }
        try clientIDStore.save(clientID)
        guard clientID != environment.configuration.spotifyClientID else {
            return
        }

        sessionTask?.cancel()
        playbackTask?.cancel()
        environment.spotifyPlayback.stop()
        environment.spotifySession.logout()
        environment = environmentFactory(configuration)
        sessionState = environment.spotifySession.currentState
        playbackSnapshot = nil
        devicesState = .idle
        clock = PlayerClock()
        presentedError = nil
        prepared = false
        prepare()
        if isForeground {
            environment.spotifyPlayback.enterForeground()
        }
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
