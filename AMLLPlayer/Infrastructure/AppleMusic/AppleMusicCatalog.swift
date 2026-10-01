import Foundation
import MusicKit

@MainActor
final class AppleMusicCatalog: MusicCatalogProviding {
    let service: MusicServiceID = .appleMusic
    let homeSections: [MusicLibrarySection] = [.playlists, .recent, .recentlyAdded, .recommendations, .charts]
    let librarySections: [MusicLibrarySection] = [.savedTracks, .savedAlbums, .followedArtists, .playlists, .downloaded]
    let searchKinds = MusicCatalogKind.allCases
    let session: AppleMusicSession
    private var generation = UUID()
    private var ownedPlaylists = Set<String>()
    private let defaults: UserDefaults
    private let ownershipKey: String

    init(session: AppleMusicSession, defaults: UserDefaults = .standard) {
        self.session = session
        self.defaults = defaults
        ownershipKey = "appleMusic.createdPlaylists.v1." + (Bundle.main.bundleIdentifier ?? "AMLLPlayer")
        ownedPlaylists = Set(defaults.stringArray(forKey: ownershipKey) ?? [])
    }

    func invalidate() {
        generation = UUID()
    }

    func profile() async throws -> MusicProfile {
        try requireConnection()
        // This ID is a connection context, never advertised as an Apple account ID.
        return .init(accountID: session.connectionID.uuidString, displayName: "Apple Music")
    }

    func page(_ query: MusicCatalogQuery, next: URL?) async throws -> MusicPage<MusicCatalogRow> {
        try session.requireCatalog()
        if case .collection(.downloaded) = query {
            return try await downloaded(next: next)
        }
        if case let .libraryItems(section, ascending) = query {
            return try await sortedLibrary(section, ascending: ascending, next: next)
        }
        let token = generation
        let context = session.connectionID
        let request: URLRequest
        if let next {
            guard AppleMusicAPI.allowed(next) else { throw MusicCatalogError.invalidResponse }
            request = URLRequest(url: next)
        } else {
            request = try makeRequest(query)
        }
        let data = try await session.api.send(request)
        try check(token, context)
        return try AppleMusicCatalogDecoder.page(data, query: query, url: request.url!, editableIDs: editableIDs)
    }

    func detail(kind: MusicCatalogKind, id: String) async throws -> MusicCatalogDetail {
        try await detail(resource: .init(service: .appleMusic, kind: kind, scope: .catalog, rawValue: id))
    }

    func detail(resource: MusicResourceID) async throws -> MusicCatalogDetail {
        try session.requireCatalog()
        let token = generation
        let context = session.connectionID
        let path = try AppleMusicAPI.resourcePath(resource, storefront: region)
        var parameters: [URLQueryItem] = []
        if resource.scope == .catalog, [.track, .album, .musicVideo].contains(resource.kind) {
            parameters.append(.init(name: "include", value: resource.kind == .track ? "artists,albums" : "artists"))
        }
        if [.track, .album, .playlist].contains(resource.kind) {
            parameters.append(.init(name: "extend", value: "inFavorites"))
        }
        let data = try await session.api.send(AppleMusicAPI.request(path, parameters: parameters))
        try check(token, context)
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let rows = root?["data"] as? [[String: Any]], let first = rows.first,
              let item = AppleMusicCatalogDecoder.item(first, editableIDs: editableIDs) else { throw MusicCatalogError.unavailable }
        let children: MusicCatalogQuery? = [.album, .playlist, .artist].contains(resource.kind) ? .resourceChildren(resource) : nil
        return .init(item: item, children: children, availability: item.availability)
    }

    func suggestions(_ term: String) async throws -> [String] {
        try session.requireCatalog()
        let token = generation
        let context = session.connectionID
        let data = try await session.api.send(AppleMusicAPI.request("/v1/catalog/\(region)/search/suggestions", parameters: [
            .init(name: "term", value: term), .init(name: "kinds", value: "terms"),
        ]))
        try check(token, context)
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let results = root?["results"] as? [String: Any]
        let suggestions = results?["suggestions"] as? [[String: Any]] ?? []
        return suggestions.compactMap { $0["searchTerm"] as? String }.prefix(10).map(\.self)
    }

    private var region: String {
        session.currentState.storefront ?? ""
    }

    private var editableIDs: Set<String> {
        return ownedPlaylists
    }

    func registerCreatedPlaylist(_ id: String) {
        ownedPlaylists.insert(id)
        defaults.set(Array(ownedPlaylists).sorted(), forKey: ownershipKey)
    }

    func isCreatedPlaylist(_ id: String) -> Bool {
        editableIDs.contains(id)
    }

    private func makeRequest(_ query: MusicCatalogQuery) throws -> URLRequest {
        var path: String
        var parameters: [URLQueryItem] = [.init(name: "limit", value: "25")]
        switch query {
        case let .collection(section):
            switch section {
            case .playlists: path = "/v1/me/library/playlists"
            case .savedTracks: path = "/v1/me/library/songs"
            case .savedAlbums: path = "/v1/me/library/albums"
            case .followedArtists: path = "/v1/me/library/artists"
            case .recent: path = "/v1/me/recent/played"
            case .recentlyAdded: path = "/v1/me/library/recently-added"
            case .recommendations:
                path = "/v1/me/recommendations"
                parameters.append(.init(name: "include", value: "contents"))
            case .charts:
                path = "/v1/catalog/\(region)/charts"
                parameters.append(.init(name: "types", value: "songs"))
            case .dailySongs, .topTracks, .downloaded: throw MusicCatalogError.unavailable
            }
        case let .search(term, kind):
            path = "/v1/catalog/\(region)/search"
            parameters += [.init(name: "term", value: term), .init(name: "types", value: kind.appleType)]
        case let .librarySearch(term, kind):
            guard [.track, .album, .artist, .playlist].contains(kind) else { throw MusicCatalogError.unavailable }
            path = "/v1/me/library/search"
            parameters += [.init(name: "term", value: term), .init(name: "types", value: "library-" + kind.appleType)]
        case let .resourceChildren(resource):
            path = try AppleMusicAPI.resourcePath(resource, storefront: region)
                + (resource.kind == .artist ? "/albums" : "/tracks")
        case let .albumTracks(id):
            path = try AppleMusicAPI.resourcePath(.init(service: .appleMusic, kind: .album, scope: .catalog, rawValue: id), storefront: region) + "/tracks"
        case let .artistAlbums(id):
            path = try AppleMusicAPI.resourcePath(.init(service: .appleMusic, kind: .artist, scope: .catalog, rawValue: id), storefront: region) + "/albums"
        case let .playlistItems(id):
            path = try AppleMusicAPI.resourcePath(.init(service: .appleMusic, kind: .playlist, scope: .catalog, rawValue: id), storefront: region) + "/tracks"
        case .libraryItems: throw MusicCatalogError.unavailable
        }
        if path.hasPrefix("/v1/me/library/"), !session.currentState.capabilities.canModifyLibrary {
            throw MusicServiceError.cloudLibraryRequired
        }
        return try AppleMusicAPI.request(path, parameters: parameters)
    }

    private func downloaded(next: URL?) async throws -> MusicPage<MusicCatalogRow> {
        try await sortedLibrary(.downloaded, ascending: true, next: next)
    }

    private func sortedLibrary(_ section: MusicLibrarySection, ascending: Bool, next: URL?) async throws -> MusicPage<MusicCatalogRow> {
        let token = generation
        let context = session.connectionID
        var offset = 0
        if let next {
            let parts = next.path.split(separator: "/")
            guard next.scheme == "amll-library", next.host == context.uuidString.lowercased(),
                  parts.count == 3, parts[0] == Substring(section.rawValue), parts[1] == Substring(String(ascending)),
                  let n = Int(parts[2]), n >= 0 else { throw MusicCatalogError.invalidResponse }
            offset = n
        }
        var items: [MusicCatalogItem]
        switch section {
        case .savedTracks, .downloaded:
            var request = MusicLibraryRequest<Song>()
            request.includeOnlyDownloadedContent = section == .downloaded
            request.limit = 25; request.offset = offset
            request.sort(by: \.title, ascending: ascending)
            items = try await request.response().items.map { AppleMusicSongMapping.catalog($0, scope: .library) }
        case .savedAlbums:
            var request = MusicLibraryRequest<Album>()
            request.limit = 25; request.offset = offset
            request.sort(by: \.title, ascending: ascending)
            items = try await request.response().items.map {
                .init(spotifyID: $0.id.rawValue, kind: .album, name: $0.title, subtitle: $0.artistName,
                      artworkURL: $0.artwork?.url(width: 1000, height: 1000), availability: $0.playParameters == nil ? .metadataOnly : .available,
                      service: .appleMusic, scope: .library, publicURL: $0.url)
            }
        case .followedArtists:
            var request = MusicLibraryRequest<Artist>()
            request.limit = 25; request.offset = offset
            request.sort(by: \.name, ascending: ascending)
            items = try await request.response().items.map {
                .init(spotifyID: $0.id.rawValue, kind: .artist, name: $0.name, subtitle: "",
                      artworkURL: $0.artwork?.url(width: 1000, height: 1000), availability: .metadataOnly,
                      service: .appleMusic, scope: .library, publicURL: $0.url)
            }
        case .playlists:
            var request = MusicLibraryRequest<Playlist>()
            request.limit = 25; request.offset = offset
            request.sort(by: \.name, ascending: ascending)
            items = try await request.response().items.map {
                .init(spotifyID: $0.id.rawValue, kind: .playlist, name: $0.name, subtitle: $0.curatorName ?? "",
                      artworkURL: $0.artwork?.url(width: 1000, height: 1000), availability: $0.playParameters == nil ? .metadataOnly : .available,
                      service: .appleMusic, scope: .library, publicURL: $0.url, editablePlaylist: editableIDs.contains($0.id.rawValue))
            }
        default: throw MusicCatalogError.unavailable
        }
        try check(token, context)
        let rows = items.map { MusicCatalogRow(id: $0.id, item: $0, position: nil) }
        let cursor = rows.count == 25 ? URL(string: "amll-library://\(context.uuidString.lowercased())/\(section.rawValue)/\(ascending)/\(offset + rows.count)") : nil
        return .init(items: rows, next: cursor, total: nil)
    }

    private func requireConnection() throws {
        guard session.currentState.connected else { throw MusicCatalogError.signInRequired }
    }

    private func check(_ token: UUID, _ context: UUID) throws {
        try Task.checkCancellation()
        guard token == generation, context == session.connectionID, session.currentState.connected, session.currentState.capabilities.canBrowse else { throw CancellationError() }
    }
}
