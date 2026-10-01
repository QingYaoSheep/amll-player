import Foundation

enum AppleMusicCatalogDecoder {
    static func item(_ value: [String: Any], editableIDs: Set<String> = []) -> MusicCatalogItem? {
        guard let id = value["id"] as? String, let type = value["type"] as? String,
              let kind = MusicCatalogKind.apple(type), let a = value["attributes"] as? [String: Any],
              let name = a["name"] as? String else { return nil }
        let scope: MusicResourceScope = type.hasPrefix("library-") ? .library : .catalog
        let p = a["playParams"] as? [String: Any]
        let relations = value["relationships"] as? [String: Any] ?? [:]
        func related(_ key: String) -> [[String: Any]] {
            (relations[key] as? [String: Any])?["data"] as? [[String: Any]] ?? []
        }
        let artists = related("artists").compactMap { r -> MusicArtist? in
            guard let id = r["id"] as? String, let attrs = r["attributes"] as? [String: Any],
                  let name = attrs["name"] as? String else { return nil }
            return .init(id: id, name: name)
        }
        let album = related("albums").first.flatMap { r -> MusicAlbum? in
            guard let id = r["id"] as? String, let attrs = r["attributes"] as? [String: Any],
                  let name = attrs["name"] as? String else { return nil }
            return .init(id: id, name: name)
        }
        let artwork = a["artwork"] as? [String: Any]
        let image = (artwork?["url"] as? String)?
            .replacingOccurrences(of: "{w}", with: "1000")
            .replacingOccurrences(of: "{h}", with: "1000")
            .replacingOccurrences(of: "{f}", with: "jpg")
        let trackArtists = artists.isEmpty ? [MusicArtist(id: "", name: a["artistName"] as? String ?? "")] : artists
        let catalogID = scope == .catalog ? id : p?["catalogId"] as? String
        var item = MusicCatalogItem(
            spotifyID: id, kind: kind, name: name,
            subtitle: a["artistName"] as? String ?? a["curatorName"] as? String ?? "",
            artworkURL: image.flatMap(URL.init(string:)),
            availability: p == nil ? .metadataOnly : .available,
            track: kind == .track ? MusicTrack(durationMS: a["durationInMillis"] as? Int ?? 0,
                                               artists: trackArtists, album: album, isrc: a["isrc"] as? String) : nil,
            artists: artists,
            playlist: kind == .playlist ? MusicPlaylist(ownerName: a["curatorName"] as? String,
                                                        description: (a["description"] as? [String: Any])?["standard"] as? String,
                                                        total: a["trackCount"] as? Int) : nil,
            releaseDate: a["releaseDate"] as? String,
            service: .appleMusic, scope: scope, publicURL: (a["url"] as? String).flatMap(URL.init(string:)),
            catalogID: catalogID, inFavorites: a["inFavorites"] as? Bool,
            editablePlaylist: scope == .library && kind == .playlist && editableIDs.contains(id),
            libraryWritable: scope == .library && (a["canEdit"] as? Bool == true),
            isExplicit: a["contentRating"] as? String == "explicit"
        )
        if kind == .artist || kind == .musicVideo {
            item = item.withAvailability(.metadataOnly)
        }
        return item
    }

    static func page(_ data: Data, query: MusicCatalogQuery, url: URL, editableIDs: Set<String> = []) throws -> MusicPage<MusicCatalogRow> {
        guard data.count <= 8 * 1024 * 1024,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw MusicCatalogError.invalidResponse }
        var container = root
        switch query {
        case let .search(_, kind), let .librarySearch(_, kind):
            let results = root["results"] as? [String: Any] ?? [:]
            container = results[kind.appleType] as? [String: Any]
                ?? results["library-" + kind.appleType] as? [String: Any] ?? ["data": []]
        case .collection(.charts):
            let charts = (root["results"] as? [String: Any])?["songs"] as? [[String: Any]] ?? []
            container = charts.first ?? ["data": []]
        default: break
        }
        guard var resources = container["data"] as? [[String: Any]] else { throw MusicCatalogError.invalidResponse }
        if case .collection(.recommendations) = query {
            resources = resources.flatMap { resource in
                let relations = resource["relationships"] as? [String: Any] ?? [:]
                return (relations["contents"] as? [String: Any])?["data"] as? [[String: Any]] ?? []
            }
        }
        let offset = URLComponents(url: url, resolvingAgainstBaseURL: true)?.queryItems?
            .first(where: { $0.name == "offset" })?.value.flatMap(Int.init) ?? 0
        let rows = resources.enumerated().compactMap { index, resource -> MusicCatalogRow? in
            guard let item = item(resource, editableIDs: editableIDs) else { return nil }
            let position = query.preservesPositions ? offset + index : nil
            return .init(id: position.map { "\(item.id):\($0)" } ?? item.id, item: item, position: position)
        }
        return try .init(items: rows, next: AppleMusicAPI.next(container["next"] as? String, from: url),
                         total: (container["meta"] as? [String: Any])?["total"] as? Int)
    }
}

private extension MusicCatalogItem {
    func withAvailability(_ value: MusicContentAvailability) -> Self {
        Self(spotifyID: spotifyID, kind: kind, name: name, subtitle: subtitle, artworkURL: artworkURL,
             availability: value, track: track, artists: artists, playlist: playlist, releaseDate: releaseDate,
             service: service, scope: scope, publicURL: publicURL, catalogID: catalogID, inFavorites: inFavorites,
             editablePlaylist: editablePlaylist, libraryWritable: libraryWritable, isExplicit: isExplicit)
    }
}
