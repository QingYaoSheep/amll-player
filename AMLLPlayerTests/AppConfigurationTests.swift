import XCTest

@testable import AMLLPlayer

final class AppConfigurationTests: XCTestCase {
    func testUsesConfiguredClientIDAndRedirectURI() {
        let configuration = AppConfiguration(
            infoDictionary: [
                "SpotifyClientID": "client-for-test",
                "SpotifyRedirectURI": "amllplayer://spotify-callback",
            ]
        )

        XCTAssertTrue(configuration.isSpotifyConfigured)
        XCTAssertEqual(
            configuration.spotifyRedirectURI.absoluteString,
            "amllplayer://spotify-callback"
        )
    }

    func testMissingClientIDIsNotConfigured() {
        let configuration = AppConfiguration(infoDictionary: [:])

        XCTAssertFalse(configuration.isSpotifyConfigured)
        XCTAssertEqual(
            configuration.spotifyRedirectURI,
            AppConfiguration.defaultRedirectURI
        )
    }

    func testRejectsRedirectURIThatDoesNotMatchRegisteredCallback() {
        let configuration = AppConfiguration(
            infoDictionary: [
                "SpotifyClientID": "client-for-test",
                "SpotifyRedirectURI": "other-app://callback",
            ]
        )

        XCTAssertFalse(configuration.isSpotifyConfigured)
    }
}
