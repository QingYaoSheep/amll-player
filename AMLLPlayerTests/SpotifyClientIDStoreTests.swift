import XCTest

@testable import AMLLPlayer

final class SpotifyClientIDStoreTests: XCTestCase {
    func testSavedClientIDCanBeLoadedByAnotherStore() throws {
        let storage = MemorySpotifyDataStore()
        try SpotifyClientIDStore(storage: storage).save("  runtime-client\n")

        XCTAssertEqual(
            try SpotifyClientIDStore(storage: storage).load(),
            "runtime-client"
        )
    }

    func testInvalidInputDoesNotReplaceSavedClientID() throws {
        let store = SpotifyClientIDStore(storage: MemorySpotifyDataStore())
        try store.save("original-client")

        for invalidValue in ["", "  \n", "your_spotify_client_id", "client with spaces"] {
            XCTAssertThrowsError(try store.save(invalidValue))
        }
        XCTAssertEqual(try store.load(), "original-client")
    }

    func testRuntimeClientIDOverridesBuildDefaultAndPreservesRedirect() {
        let original = AppConfiguration(
            infoDictionary: ["SpotifyClientID": "build-client"]
        )
        let overridden = original.overridingSpotifyClientID(" runtime-client ")

        XCTAssertEqual(overridden.spotifyClientID, "runtime-client")
        XCTAssertEqual(overridden.spotifyRedirectURI, original.spotifyRedirectURI)
        XCTAssertTrue(overridden.isSpotifyConfigured)
        XCTAssertEqual(original.overridingSpotifyClientID(nil), original)
        XCTAssertEqual(original.overridingSpotifyClientID(" "), original)
    }
}

final class MemorySpotifyDataStore: SpotifySessionDataStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?

    func load() throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return data
    }

    func save(_ data: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        self.data = data
    }

    func remove() throws {
        lock.lock()
        defer { lock.unlock() }
        data = nil
    }
}
