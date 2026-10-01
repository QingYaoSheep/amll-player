import Foundation
import Observation

/// Replacement edits are permitted only after every page of the current load has arrived.
@MainActor @Observable
final class MusicPlaylistEditingState {
    var entries: [MusicCatalogRow] = []
    private(set) var isLoading = false
    private(set) var isLoaded = false
    private(set) var error: String?
    @ObservationIgnored private var generation = UUID()

    func cancel() {
        generation = UUID()
        isLoading = false
        isLoaded = false
        entries = []
        error = nil
    }

    func load(resource: MusicResourceID, provider: any MusicCatalogProviding) async {
        cancel()
        let token = generation
        isLoading = true
        defer {
            if generation == token {
                isLoading = false
            }
        }
        do {
            var cursor: URL?
            var rows: [MusicCatalogRow] = []
            var visited = Set<URL>()
            repeat {
                let page = try await provider.page(.resourceChildren(resource), next: cursor)
                try Task.checkCancellation()
                guard token == generation else { return }
                rows += page.items
                cursor = page.next
                if let cursor, !visited.insert(cursor).inserted {
                    throw MusicCatalogError.invalidResponse
                }
            } while cursor != nil
            guard rows.allSatisfy({ $0.item.kind == .track }) else {
                throw MusicServiceError.unsupportedOperation
            }
            entries = rows
            isLoaded = true
        } catch is CancellationError {} catch {
            guard token == generation else { return }
            self.error = MusicCatalogError.presenting(error, service: provider.service).localizedDescription
        }
    }
}
