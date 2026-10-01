import Foundation
import MusicKit

@MainActor
final class AppleMusicLibrary: MusicLibraryMutating {
    private let session: AppleMusicSession
    private let playback: AppleMusicPlayback
    private let catalog: AppleMusicCatalog

    init(session: AppleMusicSession, playback: AppleMusicPlayback, catalog: AppleMusicCatalog) {
        self.session = session; self.playback = playback; self.catalog = catalog
    }

    func favorite(_ item: MusicCatalogItem) async throws {
        try requireLibrary()
        guard session.currentState.capabilities.canFavorite, let kind = item.kind,
              [.track, .album, .playlist].contains(kind) else { throw MusicServiceError.unsupportedOperation }
        let context = session.connectionID
        let type = (item.scope == .library ? "library-" : "") + kind.appleType
        _ = try await session.api.send(AppleMusicAPI.request("/v1/me/favorites", parameters: [
            .init(name: "ids[\(type)]", value: item.spotifyID),
        ], method: "POST"))
        try check(context)
        // Do not fabricate inFavorites from an accepted response. The UI reloads
        // official state; library propagation may not be immediate.
    }

    func addToLibrary(_ item: MusicCatalogItem) async throws {
        try requireLibrary()
        guard item.service == .appleMusic, let kind = item.kind, item.scope == .catalog,
              [.track, .album, .playlist, .musicVideo].contains(kind) else { throw MusicServiceError.unsupportedOperation }
        let context = session.connectionID
        _ = try await session.api.send(AppleMusicAPI.request("/v1/me/library", parameters: [
            .init(name: "ids[\(kind.appleType)]", value: item.spotifyID),
        ], method: "POST"))
        try check(context)
    }

    func createPlaylist(name: String, description: String) async throws -> MusicCatalogItem {
        try requireLibrary()
        let context = session.connectionID
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw MusicCatalogError.invalidResponse }
        let playlist = try await MusicLibrary.shared.createPlaylist(name: name, description: description)
        try check(context)
        catalog.registerCreatedPlaylist(playlist.id.rawValue)
        return .init(spotifyID: playlist.id.rawValue, kind: .playlist, name: playlist.name,
                     subtitle: playlist.curatorName ?? "", artworkURL: playlist.artwork?.url(width: 1000, height: 1000),
                     availability: .available, service: .appleMusic, scope: .library,
                     publicURL: playlist.url, editablePlaylist: true, libraryWritable: true)
    }

    func append(_ item: MusicCatalogItem, to playlist: MusicCatalogItem) async throws {
        try requireLibrary()
        guard playlist.libraryWritable || playlist.editablePlaylist,
              let target = playlist.resource, target.scope == .library, target.kind == .playlist,
              let resource = item.resource, resource.kind == .track else { throw MusicServiceError.unsupportedOperation }
        let context = session.connectionID
        let song = try await playback.resolveSong(resource)
        let list = try await playback.resolvePlaylist(target)
        try check(context)
        _ = try await MusicLibrary.shared.add(song, to: list)
        try check(context)
    }

    func editPlaylist(_ playlist: MusicCatalogItem, name: String, description: String, entries: [MusicCatalogItem]?) async throws {
        try requireLibrary()
        guard playlist.editablePlaylist, catalog.isCreatedPlaylist(playlist.spotifyID),
              let resource = playlist.resource, resource.scope == .library else { throw MusicServiceError.unsupportedOperation }
        let context = session.connectionID
        let list = try await playback.resolvePlaylist(resource)
        if let entries {
            var songs: [Song] = []
            for entry in entries {
                guard let resource = entry.resource, resource.kind == .track else { throw MusicServiceError.unsupportedOperation }
                try await songs.append(playback.resolveSong(resource))
                try check(context)
            }
            _ = try await MusicLibrary.shared.edit(list, name: name, description: description, items: songs)
        } else {
            try check(context)
            _ = try await MusicLibrary.shared.edit(list, name: name, description: description)
        }
        try check(context)
    }

    private func requireLibrary() throws {
        guard session.currentState.connected else { throw MusicServiceError.musicPermissionDenied }
        guard session.currentState.capabilities.canModifyLibrary else { throw MusicServiceError.cloudLibraryRequired }
    }

    private func check(_ context: UUID) throws {
        try Task.checkCancellation()
        guard context == session.connectionID, session.currentState.connected else { throw CancellationError() }
    }
}
