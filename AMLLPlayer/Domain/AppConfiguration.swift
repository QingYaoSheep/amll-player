import Foundation

struct AppConfiguration: Equatable, Sendable {
    static let defaultRedirectURI = URL(string: "amllplayer://spotify-callback")!

    let spotifyClientID: String?
    let spotifyRedirectURI: URL

    var isSpotifyConfigured: Bool {
        guard let spotifyClientID else {
            return false
        }

        return !spotifyClientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && spotifyClientID != "your_spotify_client_id"
    }

    init(bundle: Bundle) {
        self.init(infoDictionary: bundle.infoDictionary ?? [:])
    }

    init(infoDictionary: [String: Any]) {
        let clientID = infoDictionary["SpotifyClientID"] as? String
        let redirectValue = infoDictionary["SpotifyRedirectURI"] as? String

        spotifyClientID = clientID?.trimmingCharacters(in: .whitespacesAndNewlines)
        spotifyRedirectURI = redirectValue.flatMap(URL.init(string:)) ?? Self.defaultRedirectURI
    }

    static let preview = AppConfiguration(
        infoDictionary: [
            "SpotifyClientID": "preview-client",
            "SpotifyRedirectURI": "amllplayer://spotify-callback",
        ]
    )
}
