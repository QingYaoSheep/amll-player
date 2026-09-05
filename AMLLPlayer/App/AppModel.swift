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
    private(set) var catalog: SpotifyCatalogStore
    let lyrics: LyricsCoordinator
    private(set) var selectedDeviceID: String?
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
    @ObservationIgnored private var lyricsMetadataTask: Task<Void, Never>?
    @ObservationIgnored private var clock = PlayerClock()
    @ObservationIgnored private var prepared = false
    @ObservationIgnored private var isForeground = false
    @ObservationIgnored private let clientIDStore: SpotifyClientIDStore
    @ObservationIgnored private let environmentFactory: @MainActor (AppConfiguration) -> AppEnvironment

    init(
        environment: AppEnvironment,
        clientIDStore: SpotifyClientIDStore = SpotifyClientIDStore(),
        catalogProvider: (any SpotifyCatalogProviding)? = nil,
        lyrics: LyricsCoordinator? = nil,
        environmentFactory: @escaping @MainActor (AppConfiguration) -> AppEnvironment = {
            AppEnvironment.make(configuration: $0)
        }
    ) {
        self.environment = environment
        self.lyrics = lyrics ?? .live()
        self.clientIDStore = clientIDStore
        self.environmentFactory = environmentFactory
        self.sessionState = environment.spotifySession.currentState
        self.catalog = SpotifyCatalogStore(
            provider: catalogProvider ?? SpotifyCatalogClient(session: environment.spotifySession)
        )
        if self.sessionState.isAuthenticated { self.catalog.activate() }
    }

    deinit {
        sessionTask?.cancel()
        playbackTask?.cancel()
        lyricsMetadataTask?.cancel()
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
                switch state {
                case .authenticated: catalog.activate()
                case .signedOut, .authorizing, .failed:
                    if catalog.active { catalog.reset() }
                    lyrics.update(track: nil)
                case .refreshing: break
                }
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
                if sessionState.isAuthenticated { updateLyricsMetadata(snapshot.item) }
            }
        }
    }

    func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .active:
            isForeground = true
            lyrics.setForeground(true)
            environment.spotifyPlayback.enterForeground()
        case .background:
            isForeground = false
            lyricsMetadataTask?.cancel()
            lyrics.setForeground(false)
            environment.spotifyPlayback.enterBackground()
        case .inactive:
            break
        @unknown default:
            isForeground = false
            lyrics.setForeground(false)
            lyricsMetadataTask?.cancel()
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
        lyricsMetadataTask?.cancel()
        lyrics.update(track: nil)
        catalog.reset()
        selectedDeviceID = nil
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
        lyricsMetadataTask?.cancel()
        lyrics.update(track: nil)
        catalog.reset()
        selectedDeviceID = nil
        environment.spotifyPlayback.stop()
        environment.spotifySession.logout()
        environment = environmentFactory(configuration)
        catalog = SpotifyCatalogStore(provider: SpotifyCatalogClient(session: environment.spotifySession))
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
            selectedDeviceID = deviceID
            await loadDevices()
        }
    }

    func playCatalog(_ item: SpotifyCatalogItem, contextURI: String? = nil, position: Int? = nil) async throws {
        guard catalog.active, item.canPlay, let uri = item.uri else { throw SpotifyCatalogError.unavailable }
        guard !isPerformingAction else { return }
        isPerformingAction = true
        defer { isPerformingAction = false }
        let epoch = catalog.identity
        let playback = environment.spotifyPlayback
        let deviceID = selectedDeviceID ?? playbackSnapshot?.device?.id
        if let contextURI, let position {
            try await playback.play(contextURI: contextURI, position: position, on: deviceID)
        } else {
            try await playback.play(uri: uri, on: deviceID)
        }
        guard catalog.active, catalog.identity == epoch else { throw CancellationError() }
        // A successful command must not be reported as failed just because its follow-up poll failed.
        try? await playback.refresh()
    }

    func progress(at uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) -> TimeInterval {
        clock.position(at: uptime)
    }

    private func updateLyricsMetadata(_ item: PlaybackItem?) {
        let identity = TrackIdentity(item)
        let changed = lyrics.track?.spotifyID != identity?.spotifyID
        lyrics.update(track: identity)
        guard changed else { return }
        lyricsMetadataTask?.cancel()
        guard var identity, identity.isrc == nil, SpotifyCatalogDecoder.validID(identity.spotifyID) else { return }
        let client = SpotifyCatalogClient(session: environment.spotifySession)
        lyricsMetadataTask = Task { [weak self] in
            guard let detail = try? await client.detail(kind: .track, id: identity.spotifyID),
                  !Task.isCancelled, let self, sessionState.isAuthenticated,
                  lyrics.track?.spotifyID == identity.spotifyID else { return }
            identity.isrc = detail.item.track?.isrc
            if identity.isrc != nil { lyrics.update(track: identity) }
        }
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
