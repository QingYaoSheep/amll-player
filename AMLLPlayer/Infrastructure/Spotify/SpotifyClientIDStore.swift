import Foundation

struct SpotifyClientIDStore {
    private let storage: any SpotifySessionDataStoring

    init(
        storage: any SpotifySessionDataStoring = KeychainSpotifySessionStore(account: "client-id")
    ) {
        self.storage = storage
    }

    func load() throws -> String? {
        guard let data = try storage.load(),
              let value = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        return Self.normalized(value)
    }

    func save(_ value: String) throws {
        guard let clientID = Self.normalized(value) else {
            throw SpotifyServiceError.notConfigured
        }
        try storage.save(Data(clientID.utf8))
    }

    static func normalized(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed != "your_spotify_client_id",
              trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
        else {
            return nil
        }
        return trimmed
    }
}
