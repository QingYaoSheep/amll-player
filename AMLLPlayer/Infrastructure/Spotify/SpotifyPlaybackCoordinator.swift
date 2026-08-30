import Foundation

@MainActor
final class SpotifyPlaybackCoordinator: SpotifyPlaybackProviding {
    private let session: any SpotifySessionProviding
    private let appRemote: any SpotifyAppRemoteControlling
    private let webAPI: any SpotifyWebAPIProviding
    private let diagnostics: any DiagnosticsExporting
    private let pollInterval: Duration

    private var sessionTask: Task<Void, Never>?
    private var remoteStateTask: Task<Void, Never>?
    private var remoteSnapshotTask: Task<Void, Never>?
    private var pollingTask: Task<Void, Never>?
    private var started = false
    private var isForeground = false
    private var allowBackwardCalibration = false
    private var clock = PlayerClock()
    private var snapshotContinuations: [
        UUID: AsyncStream<PlaybackSnapshot>.Continuation
    ] = [:]

    private(set) var appRemoteState: SpotifyAppRemoteState = .disconnected

    var playbackSnapshots: AsyncStream<PlaybackSnapshot> {
        let identifier = UUID()
        return AsyncStream { continuation in
            if let anchor = clock.anchor {
                continuation.yield(anchor)
            }
            snapshotContinuations[identifier] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in
                    self?.snapshotContinuations[identifier] = nil
                }
            }
        }
    }

    init(
        session: any SpotifySessionProviding,
        appRemote: any SpotifyAppRemoteControlling,
        webAPI: any SpotifyWebAPIProviding = SpotifyWebAPIClient(),
        diagnostics: any DiagnosticsExporting,
        pollInterval: Duration = .seconds(2)
    ) {
        self.session = session
        self.appRemote = appRemote
        self.webAPI = webAPI
        self.diagnostics = diagnostics
        self.pollInterval = pollInterval
    }

    deinit {
        sessionTask?.cancel()
        remoteStateTask?.cancel()
        remoteSnapshotTask?.cancel()
        pollingTask?.cancel()
    }

    func start() {
        guard !started else {
            return
        }
        started = true

        sessionTask = Task { [weak self] in
            guard let self else {
                return
            }
            for await state in session.sessionStates {
                guard !Task.isCancelled else {
                    return
                }
                await handleSessionState(state)
            }
        }

        remoteStateTask = Task { [weak self] in
            guard let self else {
                return
            }
            for await state in appRemote.stateChanges {
                guard !Task.isCancelled else {
                    return
                }
                handleAppRemoteState(state)
            }
        }

        remoteSnapshotTask = Task { [weak self] in
            guard let self else {
                return
            }
            for await snapshot in appRemote.playbackSnapshots {
                guard !Task.isCancelled else {
                    return
                }
                publish(snapshot)
            }
        }
    }

    func enterForeground() {
        start()
        isForeground = true
        Task { [weak self] in
            await self?.activatePlaybackSource()
        }
    }

    func enterBackground() {
        isForeground = false
        pollingTask?.cancel()
        pollingTask = nil
        appRemote.disconnect()
        appRemoteState = .disconnected
        record("Playback synchronization suspended")
    }

    func refresh() async throws {
        let token = try await session.validAccessToken()
        publish(try await webAPI.playback(accessToken: token))
    }

    func play() async throws {
        try ensureControllable()
        try await performPreferredRemoteCommand(
            appRemoteAction: { try await self.appRemote.play() },
            webAction: { token in
                try await self.webAPI.play(
                    accessToken: token,
                    deviceID: self.clock.anchor?.device?.id
                )
            }
        )
    }

    func pause() async throws {
        try ensureControllable()
        try await performPreferredRemoteCommand(
            appRemoteAction: { try await self.appRemote.pause() },
            webAction: { token in
                try await self.webAPI.pause(
                    accessToken: token,
                    deviceID: self.clock.anchor?.device?.id
                )
            }
        )
    }

    func seek(to position: TimeInterval) async throws {
        try ensureControllable()
        guard clock.anchor?.restrictions.canSeek != false else {
            throw SpotifyServiceError.restrictedDevice
        }
        allowBackwardCalibration = true
        try await performPreferredRemoteCommand(
            appRemoteAction: { try await self.appRemote.seek(to: position) },
            webAction: { token in
                try await self.webAPI.seek(
                    accessToken: token,
                    position: position,
                    deviceID: self.clock.anchor?.device?.id
                )
            }
        )
    }

    func skipNext() async throws {
        try ensureControllable()
        guard clock.anchor?.restrictions.canSkipNext != false else {
            throw SpotifyServiceError.restrictedDevice
        }
        try await performPreferredRemoteCommand(
            appRemoteAction: { try await self.appRemote.skipNext() },
            webAction: { token in
                try await self.webAPI.skipNext(
                    accessToken: token,
                    deviceID: self.clock.anchor?.device?.id
                )
            }
        )
    }

    func skipPrevious() async throws {
        try ensureControllable()
        guard clock.anchor?.restrictions.canSkipPrevious != false else {
            throw SpotifyServiceError.restrictedDevice
        }
        try await performPreferredRemoteCommand(
            appRemoteAction: { try await self.appRemote.skipPrevious() },
            webAction: { token in
                try await self.webAPI.skipPrevious(
                    accessToken: token,
                    deviceID: self.clock.anchor?.device?.id
                )
            }
        )
    }

    func setVolume(percent: Int, on deviceID: String?) async throws {
        let token = try await session.validAccessToken()
        try await webAPI.setVolume(
            accessToken: token,
            percent: percent,
            deviceID: deviceID ?? clock.anchor?.device?.id
        )
        scheduleRefresh()
    }

    func play(uri: String, on deviceID: String?) async throws {
        if appRemoteState == .connected, deviceID == nil {
            do {
                try await appRemote.play(uri: uri)
                return
            } catch {
                record("App Remote play failed; using Web API")
            }
        }

        let token = try await session.validAccessToken()
        try await webAPI.play(accessToken: token, uri: uri, deviceID: deviceID)
        scheduleRefresh()
    }

    func devices() async throws -> [PlaybackDevice] {
        let token = try await session.validAccessToken()
        return try await webAPI.devices(accessToken: token)
    }

    func transferPlayback(to deviceID: String) async throws {
        let token = try await session.validAccessToken()
        try await webAPI.transferPlayback(accessToken: token, deviceID: deviceID)
        appRemote.disconnect()
        appRemoteState = .disconnected
        startPolling()
        scheduleRefresh()
        record("Playback transferred to a Connect device")
    }

    private func handleSessionState(_ state: SpotifySessionState) async {
        switch state {
        case .authenticated:
            if isForeground {
                await activatePlaybackSource()
            }
        case .signedOut, .failed:
            pollingTask?.cancel()
            pollingTask = nil
            appRemote.disconnect()
            appRemoteState = .disconnected
            publish(
                .empty(
                    source: .webAPI,
                    sampledAtUptime: ProcessInfo.processInfo.systemUptime
                )
            )
        case .authorizing, .refreshing:
            break
        }
    }

    private func activatePlaybackSource() async {
        guard isForeground, session.currentState.isAuthenticated else {
            return
        }

        do {
            let token = try await session.validAccessToken()
            if session.spotifyAppInstalled {
                appRemote.connect(accessToken: token)
                startPolling()
            } else {
                appRemoteState = .unavailable
                startPolling()
            }
        } catch {
            record("Playback source activation failed")
        }
    }

    private func handleAppRemoteState(_ state: SpotifyAppRemoteState) {
        appRemoteState = state
        switch state {
        case .connected:
            pollingTask?.cancel()
            pollingTask = nil
            record("App Remote connected")
        case .failed, .disconnected, .unavailable:
            if isForeground, session.currentState.isAuthenticated {
                startPolling()
            }
        case .connecting:
            break
        }
    }

    private func startPolling() {
        guard pollingTask == nil, isForeground else {
            return
        }

        pollingTask = Task { [weak self] in
            guard let self else {
                return
            }

            while !Task.isCancelled {
                var delay = pollInterval
                do {
                    try await refresh()
                } catch let error as SpotifyServiceError {
                    if case let .rateLimited(retryAfter) = error {
                        delay = .seconds(max(retryAfter ?? 2, 1))
                    }
                    if error == .tokenExpired {
                        try? await session.refreshIfNeeded()
                    }
                } catch {
                    // Polling remains best-effort; user actions surface their own errors.
                }

                do {
                    try await Task.sleep(for: delay)
                } catch {
                    return
                }
            }
        }
    }

    private func performPreferredRemoteCommand(
        appRemoteAction: () async throws -> Void,
        webAction: (String) async throws -> Void
    ) async throws {
        if appRemoteState == .connected {
            do {
                try await appRemoteAction()
                return
            } catch {
                record("App Remote command failed; using Web API")
            }
        }

        let token = try await session.validAccessToken()
        try await webAction(token)
        scheduleRefresh()
    }

    private func ensureControllable() throws {
        guard clock.anchor?.item != nil else {
            throw SpotifyServiceError.noPlayback
        }
        if clock.anchor?.device?.isRestricted == true {
            throw SpotifyServiceError.restrictedDevice
        }
    }

    private func publish(_ snapshot: PlaybackSnapshot) {
        let calibrated = clock.calibrate(
            with: snapshot,
            allowBackwardJump: allowBackwardCalibration
        )
        allowBackwardCalibration = false
        snapshotContinuations.values.forEach { $0.yield(calibrated) }
    }

    private func scheduleRefresh() {
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            try? await self?.refresh()
        }
    }

    private func record(_ message: String) {
        Task {
            await diagnostics.record(category: "spotify.playback", message: message)
        }
    }
}
