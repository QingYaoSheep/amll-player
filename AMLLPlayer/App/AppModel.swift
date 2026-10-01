import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class AppModel {
    private(set) var selectedMusicService: MusicServiceID
    private(set) var appleMusicState = MusicConnectionState()
    private(set) var netEaseState = MusicConnectionState()
    @ObservationIgnored let netEaseSession: NetEaseSession
    @ObservationIgnored let netEaseCatalog: NetEaseCatalog
    @ObservationIgnored let netEaseLibrary: NetEaseLibrary
    @ObservationIgnored let netEasePlayback: NetEasePlayback
    @ObservationIgnored private var netEaseStore: SpotifyCatalogStore
    @ObservationIgnored private var netEaseSessionTask: Task<Void, Never>?
    @ObservationIgnored private var netEasePlaybackTask: Task<Void, Never>?
    @ObservationIgnored let appleSession: any MusicSessionProviding
    @ObservationIgnored private let applePlayback: any MusicPlaybackProviding
    @ObservationIgnored let appleCatalog: any MusicCatalogProviding
    @ObservationIgnored let appleLibrary: any MusicLibraryMutating
    @ObservationIgnored private let musicPreferences: MusicSourcePreferences
    @ObservationIgnored private var spotifyCatalog: SpotifyCatalogStore
    @ObservationIgnored private var appleStore: SpotifyCatalogStore
    @ObservationIgnored private var appleSessionTask: Task<Void, Never>?
    @ObservationIgnored private var applePlaybackTask: Task<Void, Never>?
    @ObservationIgnored private var sourceGeneration = UUID()

    var currentServiceConnected: Bool {
        switch selectedMusicService {
        case .spotify: sessionState.isAuthenticated
        case .appleMusic: appleMusicState.connected
        case .netease: netEaseState.connected
        }
    }

    private var currentPlayback: any MusicPlaybackProviding {
        switch selectedMusicService {
        case .spotify: environment.spotifyPlayback
        case .appleMusic: applePlayback
        case .netease: netEasePlayback
        }
    }

    private(set) var sessionState: SpotifySessionState
    private(set) var playbackSnapshot: PlaybackSnapshot?
    /// Monotonic lyric-time anchor revision. Renderer input uses this instead
    /// of guessing a seek from a normal playback snapshot correction.
    private(set) var lyricsSeekRevision = 0
    /// Requested Spotify position, kept separate from the asynchronously reported progress.
    private(set) var lyricsSeekPosition: TimeInterval?
    private(set) var devicesState: LoadableState<[PlaybackDevice]> = .idle
    private(set) var isPerformingAction = false
    var presentedError: SpotifyServiceError?

    private(set) var environment: AppEnvironment
    private(set) var catalog: SpotifyCatalogStore
    let lyrics: LyricsCoordinator
    let renderPreferences: LyricsRenderPreferences
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
        renderPreferences: LyricsRenderPreferences? = nil,
        appleSession: (any MusicSessionProviding)? = nil,
        applePlayback: (any MusicPlaybackProviding)? = nil,
        appleCatalog: (any MusicCatalogProviding)? = nil,
        appleLibrary: (any MusicLibraryMutating)? = nil,
        netEaseSession: NetEaseSession? = nil,
        musicPreferences: MusicSourcePreferences = MusicSourcePreferences(),
        environmentFactory: @escaping @MainActor (AppConfiguration) -> AppEnvironment = {
            AppEnvironment.make(configuration: $0)
        }
    ) {
        let nativeSession = AppleMusicSession()
        let nativePlayback = AppleMusicPlayback(session: nativeSession)
        let nativeCatalog = AppleMusicCatalog(session: nativeSession)
        let resolvedSession = appleSession ?? nativeSession
        let resolvedCatalog = appleCatalog ?? nativeCatalog
        let nSession = netEaseSession ?? NetEaseSession()
        let nCatalog = NetEaseCatalog(session: nSession)
        self.netEaseSession = nSession
        self.netEaseCatalog = nCatalog
        self.netEaseLibrary = NetEaseLibrary(session: nSession, catalog: nCatalog)
        self.netEasePlayback = NetEasePlayback(session: nSession, catalog: nCatalog)
        self.netEaseStore = SpotifyCatalogStore(provider: nCatalog)
        self.netEaseState = nSession.currentState
        let selectedService = musicPreferences.selected
        let spotifyStore = SpotifyCatalogStore(provider: catalogProvider ?? SpotifyCatalogClient(session: environment.spotifySession))
        let appleStore = SpotifyCatalogStore(provider: resolvedCatalog)
        self.appleSession = appleSession ?? nativeSession
        self.applePlayback = applePlayback ?? nativePlayback
        self.appleCatalog = appleCatalog ?? nativeCatalog
        self.appleLibrary = appleLibrary ?? AppleMusicLibrary(session: nativeSession, playback: nativePlayback, catalog: nativeCatalog)
        self.musicPreferences = musicPreferences
        selectedMusicService = selectedService
        appleMusicState = resolvedSession.currentState
        self.environment = environment
        self.lyrics = lyrics ?? .live()
        self.renderPreferences = renderPreferences ?? LyricsRenderPreferences()
        self.clientIDStore = clientIDStore
        self.environmentFactory = environmentFactory
        sessionState = environment.spotifySession.currentState
        spotifyCatalog = spotifyStore
        self.appleStore = appleStore
        switch selectedService {
        case .spotify: catalog = spotifyStore
        case .appleMusic: catalog = appleStore
        case .netease: catalog = self.netEaseStore
        }
        if sessionState.isAuthenticated {
            spotifyCatalog.activate()
        }
        if appleMusicState.connected {
            appleStore.activate()
        }
    }

    deinit {
        sessionTask?.cancel()
        playbackTask?.cancel()
        appleSessionTask?.cancel()
        applePlaybackTask?.cancel()
        netEaseSessionTask?.cancel()
        netEasePlaybackTask?.cancel()
        lyricsMetadataTask?.cancel()
    }

    func prepare() {
        guard !prepared else {
            return
        }
        prepared = true
        ArtworkMediaDownload.recoverAbandonedTransfers()
        environment.spotifyPlayback.start()
        prepareAppleMusic()
        prepareNetEase()

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
                case .authenticated: spotifyCatalog.activate()
                case .signedOut, .authorizing, .failed:
                    if spotifyCatalog.active {
                        spotifyCatalog.reset()
                    }
                    if selectedMusicService == .spotify {
                        lyrics.update(track: nil)
                    }
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
                guard selectedMusicService == .spotify else { continue }
                receive(snapshot)
            }
        }
    }

    func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .active:
            netEaseSession.setForeground(true)
            isForeground = true
            lyrics.setForeground(true)
            currentPlayback.enterForeground()
            Task { await appleSession.refresh(); await netEaseSession.refresh() }
        case .background:
            netEaseSession.setForeground(false)
            isForeground = false
            lyricsMetadataTask?.cancel()
            lyrics.setForeground(false)
            currentPlayback.enterBackground()
        case .inactive:
            netEaseSession.setForeground(false)
        @unknown default:
            netEaseSession.setForeground(false)
            isForeground = false
            lyrics.setForeground(false)
            lyricsMetadataTask?.cancel()
            currentPlayback.enterBackground()
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
        spotifyCatalog.reset()
        selectedDeviceID = nil
        environment.spotifySession.logout()
        sessionState = .signedOut
        if selectedMusicService == .spotify {
            clearPlayback()
        }
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
        if selectedMusicService == .spotify {
            clearPlayback()
        }
        spotifyCatalog.reset()
        selectedDeviceID = nil
        environment.spotifyPlayback.stop()
        environment.spotifySession.logout()
        environment = environmentFactory(configuration)
        spotifyCatalog = SpotifyCatalogStore(provider: SpotifyCatalogClient(session: environment.spotifySession))
        if selectedMusicService == .spotify {
            catalog = spotifyCatalog
        }
        sessionState = environment.spotifySession.currentState
        if selectedMusicService == .spotify {
            clearPlayback()
        }
        presentedError = nil
        prepared = false
        prepare()
        if isForeground, selectedMusicService == .spotify {
            environment.spotifyPlayback.enterForeground()
        }
    }

    func refreshPlayback() async {
        await perform {
            try await currentPlayback.refresh()
        }
    }

    func togglePlayPause() async {
        await perform {
            if playbackSnapshot?.isPlaying == true {
                try await currentPlayback.pause()
            } else {
                try await currentPlayback.play()
            }
        }
    }

    func skipNext() async {
        await perform { try await currentPlayback.skipNext() }
    }

    func skipPrevious() async {
        await perform { try await currentPlayback.skipPrevious() }
    }

    func seek(to position: TimeInterval) async {
        guard !isPerformingAction else { return }
        let epoch = sourceGeneration
        let playback = currentPlayback
        lyricsSeekPosition = position
        lyricsSeekRevision &+= 1
        await perform {
            do {
                try await playback.seek(to: position)
            } catch {
                if epoch == sourceGeneration {
                    lyricsSeekPosition = nil
                }
                throw error
            }
        }
    }

    func setVolume(percent: Int, deviceID: String?) async {
        await perform {
            try await currentPlayback.setVolume(
                percent: percent,
                on: deviceID
            )
        }
    }

    func loadDevices() async {
        let epoch = sourceGeneration
        let playback = currentPlayback
        devicesState = .loading
        do {
            let devices = try await playback.devices()
            guard epoch == sourceGeneration else { return }
            devicesState = .loaded(devices)
        } catch {
            guard epoch == sourceGeneration else { return }
            let appError = mapped(error)
            devicesState = .failed(.unavailable(appError.localizedDescription))
            presentedError = appError
        }
    }

    func transferPlayback(to deviceID: String) async {
        let epoch = sourceGeneration
        let playback = currentPlayback
        await perform {
            try await playback.transferPlayback(to: deviceID)
            guard epoch == sourceGeneration else { return }
            selectedDeviceID = deviceID
            await loadDevices()
        }
    }

    func playCatalog(_ item: SpotifyCatalogItem, contextURI: String? = nil, position: Int? = nil, shuffled: Bool = false) async throws {
        guard catalog.active, item.canPlay, let uri = item.uri else { throw SpotifyCatalogError.unavailable }
        guard !isPerformingAction else { return }
        isPerformingAction = true
        defer { isPerformingAction = false }
        let epoch = catalog.identity
        if selectedMusicService == .netease {
            guard netEaseSession.currentState.connected else { throw NetEaseError.expired }
            guard item.service == .netease else { throw MusicCatalogError.unavailable }
            let context = contextURI.flatMap { raw -> MusicResourceID? in
                let parts = raw.split(separator: ":")
                guard parts.count == 3, parts[0] == "netease", let kind = MusicCatalogKind(rawValue: String(parts[1])) else { return nil }
                return .init(service: .netease, kind: kind, scope: .catalog, rawValue: String(parts[2]))
            }
            if shuffled { try await netEasePlayback.playShuffled(item) }
            else { try await netEasePlayback.play(item: item, context: context, position: position) }
            guard catalog.identity == epoch else { throw CancellationError() }
            return
        }
        if selectedMusicService == .appleMusic {
            guard item.service == .appleMusic else { throw MusicCatalogError.unavailable }
            let context = contextURI.flatMap(MusicResourceID.init(appleURI:))
            if shuffled {
                try await applePlayback.playShuffled(item)
            } else {
                try await applePlayback.play(item: item, context: context, position: position)
            }
            guard catalog.identity == epoch else { throw CancellationError() }
            try? await applePlayback.refresh()
            return
        }
        guard item.service == .spotify else { throw MusicCatalogError.unavailable }
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

    func selectMusicService(_ service: MusicServiceID) {
        guard service != selectedMusicService else { return }
        sourceGeneration = UUID()
        currentPlayback.enterBackground()
        if selectedMusicService == .netease { netEasePlayback.deselect() }
        if selectedMusicService == .appleMusic {
            applePlayback.stop()
        }
        catalog.reset()
        clearPlayback()
        selectedMusicService = service
        musicPreferences.selected = service
        switch service {
        case .spotify: catalog = spotifyCatalog
        case .appleMusic: catalog = appleStore
        case .netease: catalog = netEaseStore
        }
        if currentServiceConnected || service == .netease {
            catalog.activate()
        }
        if service == .appleMusic { applePlayback.start() }
        if service == .netease { netEasePlayback.start() }
        if isForeground {
            currentPlayback.enterForeground()
        }
        Task { [weak self] in
            guard let self, currentServiceConnected else { return }
            try? await currentPlayback.refresh()
        }
    }

    func connectAppleMusic() async {
        await appleSession.connect()
    }

    func refreshAppleMusic() async {
        await appleSession.refresh()
    }

    func disconnectAppleMusic() {
        applePlayback.stop()
        appleSession.disconnect()
        appleMusicState = appleSession.currentState
        appleStore.reset()
        if selectedMusicService == .appleMusic {
            clearPlayback()
        }
    }

    func setShuffle(_ enabled: Bool) async {
        await perform { try await currentPlayback.setShuffle(enabled) }
    }

    func setRepeat(_ mode: MusicRepeatMode) async {
        await perform { try await currentPlayback.setRepeat(mode) }
    }

    func enqueue(_ item: MusicCatalogItem, next: Bool) async {
        await perform { try await currentPlayback.enqueue(item, next: next) }
    }

    func mutateAppleLibrary(_ action: @MainActor (any MusicLibraryMutating) async throws -> Void) async throws {
        guard selectedMusicService == .appleMusic, currentServiceConnected else { throw MusicCatalogError.signInRequired }
        let epoch = sourceGeneration
        do { try await action(appleLibrary) } catch {
            guard epoch == sourceGeneration else { throw CancellationError() }
            throw error
        }
        try Task.checkCancellation()
        guard epoch == sourceGeneration else { throw CancellationError() }
        // Force all private pages to reload from the service; never guess favorites.
        await appleStore.refreshContent()
    }

    func disconnectNetEase() {
        netEasePlayback.clearAccount()
        netEaseSession.disconnect()
        netEaseState = netEaseSession.currentState
        netEaseStore.reset(); netEaseStore.activate()
        if selectedMusicService == .netease { clearPlayback() }
    }

    func mutateNetEase(_ action: @MainActor (NetEaseLibrary) async throws -> Void) async throws {
        guard selectedMusicService == .netease, currentServiceConnected else { throw NetEaseError.expired }
        let epoch = sourceGeneration
        let context = netEaseSession.currentState.contextID
        try await action(netEaseLibrary)
        guard epoch == sourceGeneration, context == netEaseSession.currentState.contextID else { throw CancellationError() }
        netEaseCatalog.invalidate()
        await netEaseStore.refreshContent()
    }

    private func prepareNetEase() {
        netEaseStore.activate()
        guard netEaseSessionTask == nil else { return }
        netEaseSessionTask = Task { [weak self] in
            guard let self else { return }
            for await state in netEaseSession.connectionStates {
                guard !Task.isCancelled else { return }
                let changed = state.contextID != netEaseState.contextID || state.connected != netEaseState.connected
                netEaseState = state
                if changed {
                    netEaseStore.reset()
                    netEasePlayback.accountChanged()
                    if selectedMusicService == .netease { clearPlayback() }
                }
                if state.connected {
                    netEaseStore.activate()
                    if selectedMusicService == .netease { netEasePlayback.start() }
                } else {
                    netEasePlayback.stop()
                    if selectedMusicService == .netease { clearPlayback() }
                    netEaseStore.activate()
                }
            }
        }
        netEasePlaybackTask = Task { [weak self] in
            guard let self else { return }
            for await snapshot in netEasePlayback.playbackSnapshots {
                guard !Task.isCancelled else { return }
                if selectedMusicService == .netease { receive(snapshot) }
            }
        }
        Task { await netEaseSession.refresh() }
    }

    private func clearPlayback() {
        lyricsMetadataTask?.cancel()
        lyrics.update(track: nil)
        playbackSnapshot = nil
        lyricsSeekPosition = nil
        lyricsSeekRevision &+= 1
        devicesState = .idle
        clock = PlayerClock()
    }

    private func receive(_ snapshot: PlaybackSnapshot) {
        guard currentServiceConnected else { return }
        if playbackSnapshot?.item?.uri != snapshot.item?.uri {
            lyricsSeekPosition = nil
        } else if let previous = playbackSnapshot, snapshot.positionRevision != previous.positionRevision {
            lyricsSeekPosition = snapshot.position
            lyricsSeekRevision &+= 1
        }
        playbackSnapshot = snapshot
        clock = PlayerClock(anchor: snapshot)
        updateLyricsMetadata(snapshot.item)
    }

    private func prepareAppleMusic() {
        guard appleSessionTask == nil else { return }
        appleSessionTask = Task { [weak self] in
            guard let self else { return }
            for await state in appleSession.connectionStates {
                guard !Task.isCancelled else { return }
                let changed = appleMusicState.storefront != state.storefront
                    || appleMusicState.contextID != state.contextID
                    || appleMusicState.capabilities.canModifyLibrary != state.capabilities.canModifyLibrary
                    || appleMusicState.connected != state.connected
                    || appleMusicState.capabilities.canBrowse != state.capabilities.canBrowse
                appleMusicState = state
                if changed {
                    appleStore.reset()
                }
                if state.connected {
                    appleStore.activate()
                    if selectedMusicService == .appleMusic {
                        applePlayback.start()
                        if isForeground {
                            applePlayback.enterForeground()
                        }
                    }
                } else {
                    applePlayback.stop()
                    if selectedMusicService == .appleMusic {
                        clearPlayback()
                    }
                }
            }
        }
        applePlaybackTask = Task { [weak self] in
            guard let self else { return }
            for await snapshot in applePlayback.playbackSnapshots {
                guard !Task.isCancelled else { return }
                guard selectedMusicService == .appleMusic else { continue }
                receive(snapshot)
            }
        }
        Task { await appleSession.refresh() }
    }

    private func updateLyricsMetadata(_ item: PlaybackItem?) {
        let identity = TrackIdentity(item)
        let changed = lyrics.track?.spotifyID != identity?.spotifyID
        lyrics.update(track: identity)
        guard changed else { return }
        lyricsMetadataTask?.cancel()
        guard item?.service == .spotify, var identity, identity.isrc == nil, SpotifyCatalogDecoder.validID(identity.spotifyID) else { return }
        let client = SpotifyCatalogClient(session: environment.spotifySession)
        lyricsMetadataTask = Task { [weak self] in
            guard let detail = try? await client.detail(kind: .track, id: identity.spotifyID),
                  !Task.isCancelled, let self, sessionState.isAuthenticated,
                  lyrics.track?.spotifyID == identity.spotifyID else { return }
            identity.isrc = detail.item.track?.isrc
            if identity.isrc != nil {
                lyrics.update(track: identity)
            }
        }
    }

    private func perform(_ operation: () async throws -> Void) async {
        guard !isPerformingAction else {
            return
        }
        isPerformingAction = true
        defer { isPerformingAction = false }
        let epoch = sourceGeneration

        do {
            try await operation()
        } catch is CancellationError {
        } catch {
            if epoch == sourceGeneration {
                present(error)
            }
        }
    }

    private func present(_ error: Error) {
        presentedError = mapped(error)
    }

    private func mapped(_ error: Error) -> SpotifyServiceError {
        error as? SpotifyServiceError ?? (selectedMusicService != .spotify ? .musicFailure(error.localizedDescription) : .transport)
    }
}
