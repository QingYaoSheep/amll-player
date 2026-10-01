import Foundation

enum ArtworkImageData {
    static func load(_ url: URL) async throws -> Data {
        if url.isFileURL {
            return try await Task.detached(priority: .userInitiated) {
                try Task.checkCancellation()
                return try Data(contentsOf: url)
            }.value
        }
        return try await URLSession.shared.data(from: url).0
    }
}
