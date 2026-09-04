import Foundation

@MainActor
protocol SpotifySessionProviding: AnyObject {
    var currentState: SpotifySessionState { get }
    var sessionStates: AsyncStream<SpotifySessionState> { get }
    var spotifyAppInstalled: Bool { get }

    func authorize() throws
    func authorizeInBrowser() async throws
    func refreshIfNeeded() async throws
    func validAccessToken() async throws -> String
    func handleRedirectURL(_ url: URL) -> Bool
    func logout()
}

@MainActor
protocol SpotifyPlaybackProviding: AnyObject {
    var playbackSnapshots: AsyncStream<PlaybackSnapshot> { get }
    var appRemoteState: SpotifyAppRemoteState { get }

    func start()
    func stop()
    func enterForeground()
    func enterBackground()
    func refresh() async throws
    func play() async throws
    func pause() async throws
    func seek(to position: TimeInterval) async throws
    func skipNext() async throws
    func skipPrevious() async throws
    func setVolume(percent: Int, on deviceID: String?) async throws
    func play(uri: String, on deviceID: String?) async throws
    func devices() async throws -> [PlaybackDevice]
    func transferPlayback(to deviceID: String) async throws
}

@MainActor
protocol SpotifyAppRemoteControlling: AnyObject {
    var state: SpotifyAppRemoteState { get }
    var stateChanges: AsyncStream<SpotifyAppRemoteState> { get }
    var playbackSnapshots: AsyncStream<PlaybackSnapshot> { get }

    func connect(accessToken: String)
    func disconnect()
    func play() async throws
    func pause() async throws
    func seek(to position: TimeInterval) async throws
    func skipNext() async throws
    func skipPrevious() async throws
    func play(uri: String) async throws
}

protocol SpotifyWebAPIProviding: Sendable {
    func playback(accessToken: String) async throws -> PlaybackSnapshot
    func devices(accessToken: String) async throws -> [PlaybackDevice]
    func play(accessToken: String, deviceID: String?) async throws
    func pause(accessToken: String, deviceID: String?) async throws
    func seek(
        accessToken: String,
        position: TimeInterval,
        deviceID: String?
    ) async throws
    func skipNext(accessToken: String, deviceID: String?) async throws
    func skipPrevious(accessToken: String, deviceID: String?) async throws
    func setVolume(
        accessToken: String,
        percent: Int,
        deviceID: String?
    ) async throws
    func play(
        accessToken: String,
        uri: String,
        deviceID: String?
    ) async throws
    func transferPlayback(accessToken: String, deviceID: String) async throws
}
