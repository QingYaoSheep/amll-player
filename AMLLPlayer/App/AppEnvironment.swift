import Foundation

@MainActor
struct AppEnvironment {
    let configuration: AppConfiguration
    let diagnostics: any DiagnosticsExporting
    let spotifySession: any SpotifySessionProviding
    let spotifyPlayback: any SpotifyPlaybackProviding

    static var live: AppEnvironment {
        make(configuration: AppConfiguration(bundle: .main))
    }

    static func make(configuration: AppConfiguration) -> AppEnvironment {
        let diagnostics = DiagnosticsStore()
        guard let clientID = configuration.spotifyClientID,
              configuration.isSpotifyConfigured
        else {
            return AppEnvironment(
                configuration: configuration,
                diagnostics: diagnostics,
                spotifySession: UnavailableSpotifySession(),
                spotifyPlayback: UnavailableSpotifyPlayback()
            )
        }

        let spotifySession = SpotifySessionController(
            clientID: clientID,
            redirectURI: configuration.spotifyRedirectURI,
            diagnostics: diagnostics
        )
        let appRemote = SpotifyAppRemoteController(
            clientID: clientID,
            redirectURI: configuration.spotifyRedirectURI
        )
        let spotifyPlayback = SpotifyPlaybackCoordinator(
            session: spotifySession,
            appRemote: appRemote,
            diagnostics: diagnostics
        )
        return AppEnvironment(
            configuration: configuration,
            diagnostics: diagnostics,
            spotifySession: spotifySession,
            spotifyPlayback: spotifyPlayback
        )
    }
}
