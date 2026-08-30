@preconcurrency import SpotifyiOS
import Foundation

@MainActor
final class SpotifyAppRemoteController: NSObject, SpotifyAppRemoteControlling {
    private let appRemote: SPTAppRemote
    private var stateContinuations: [
        UUID: AsyncStream<SpotifyAppRemoteState>.Continuation
    ] = [:]
    private var snapshotContinuations: [
        UUID: AsyncStream<PlaybackSnapshot>.Continuation
    ] = [:]

    private(set) var state: SpotifyAppRemoteState = .disconnected {
        didSet {
            stateContinuations.values.forEach { $0.yield(state) }
        }
    }

    var stateChanges: AsyncStream<SpotifyAppRemoteState> {
        let identifier = UUID()
        return AsyncStream { continuation in
            continuation.yield(state)
            stateContinuations[identifier] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in
                    self?.stateContinuations[identifier] = nil
                }
            }
        }
    }

    var playbackSnapshots: AsyncStream<PlaybackSnapshot> {
        let identifier = UUID()
        return AsyncStream { continuation in
            snapshotContinuations[identifier] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in
                    self?.snapshotContinuations[identifier] = nil
                }
            }
        }
    }

    init(clientID: String, redirectURI: URL) {
        let configuration = SPTConfiguration(
            clientID: clientID,
            redirectURL: redirectURI
        )
        self.appRemote = SPTAppRemote(
            configuration: configuration,
            logLevel: .none
        )
        super.init()
        appRemote.delegate = self
    }

    func connect(accessToken: String) {
        appRemote.connectionParameters.accessToken = accessToken
        guard !appRemote.isConnected else {
            state = .connected
            subscribeToPlayerState()
            return
        }
        state = .connecting
        appRemote.connect()
    }

    func disconnect() {
        appRemote.playerAPI?.unsubscribe(nil)
        appRemote.playerAPI?.delegate = nil
        if appRemote.isConnected {
            appRemote.disconnect()
        }
        state = .disconnected
    }

    func play() async throws {
        try await perform { callback in
            appRemote.playerAPI?.resume(callback)
        }
    }

    func pause() async throws {
        try await perform { callback in
            appRemote.playerAPI?.pause(callback)
        }
    }

    func seek(to position: TimeInterval) async throws {
        try await perform { callback in
            appRemote.playerAPI?.seek(
                toPosition: max(0, Int((position * 1_000).rounded())),
                callback: callback
            )
        }
    }

    func skipNext() async throws {
        try await perform { callback in
            appRemote.playerAPI?.skip(toNext: callback)
        }
    }

    func skipPrevious() async throws {
        try await perform { callback in
            appRemote.playerAPI?.skip(toPrevious: callback)
        }
    }

    func play(uri: String) async throws {
        try await perform { callback in
            appRemote.playerAPI?.play(uri, callback: callback)
        }
    }

    private func perform(
        _ operation: (@escaping SPTAppRemoteCallback) -> Void
    ) async throws {
        guard state == .connected, appRemote.playerAPI != nil else {
            throw SpotifyServiceError.appRemoteUnavailable
        }

        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            operation { _, error in
                if error != nil {
                    continuation.resume(throwing: SpotifyServiceError.transport)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func subscribeToPlayerState() {
        guard let playerAPI = appRemote.playerAPI else {
            state = .failed
            return
        }

        playerAPI.delegate = self
        playerAPI.subscribe(toPlayerState: { [weak self] _, error in
            guard let self else {
                return
            }
            if error != nil {
                self.state = .failed
            }
        })
        playerAPI.getPlayerState { [weak self] result, _ in
            guard let playerState = result as? SPTAppRemotePlayerState else {
                return
            }
            self?.publish(playerState)
        }
    }

    private func publish(_ playerState: SPTAppRemotePlayerState) {
        let track = playerState.track
        let item = PlaybackItem(
            id: Self.identifier(from: track.uri),
            uri: track.uri,
            title: track.name,
            artists: [track.artist.name],
            albumTitle: track.album.name,
            artworkURL: nil,
            duration: TimeInterval(track.duration) / 1_000,
            isEpisode: track.isEpisode,
            isAdvertisement: track.isAdvertisement
        )
        let restrictions = playerState.playbackRestrictions
        let snapshot = PlaybackSnapshot(
            item: item,
            isPlaying: !playerState.isPaused,
            position: TimeInterval(playerState.playbackPosition) / 1_000,
            duration: item.duration,
            device: nil,
            restrictions: PlaybackRestrictions(
                canPause: true,
                canResume: true,
                canSeek: restrictions.canSeek,
                canSkipNext: restrictions.canSkipNext,
                canSkipPrevious: restrictions.canSkipPrevious
            ),
            source: .appRemote,
            sampledAtUptime: ProcessInfo.processInfo.systemUptime
        )
        snapshotContinuations.values.forEach { $0.yield(snapshot) }
    }

    private static func identifier(from uri: String) -> String? {
        let components = uri.split(separator: ":")
        guard components.count >= 3 else {
            return nil
        }
        return String(components.last!)
    }
}

extension SpotifyAppRemoteController: @preconcurrency SPTAppRemoteDelegate {
    func appRemoteDidEstablishConnection(_ appRemote: SPTAppRemote) {
        state = .connected
        subscribeToPlayerState()
    }

    func appRemote(
        _ appRemote: SPTAppRemote,
        didFailConnectionAttemptWithError error: Error?
    ) {
        state = .failed
    }

    func appRemote(_ appRemote: SPTAppRemote, didDisconnectWithError error: Error?) {
        state = .disconnected
    }
}

extension SpotifyAppRemoteController: @preconcurrency SPTAppRemotePlayerStateDelegate {
    func playerStateDidChange(_ playerState: SPTAppRemotePlayerState) {
        publish(playerState)
    }
}
