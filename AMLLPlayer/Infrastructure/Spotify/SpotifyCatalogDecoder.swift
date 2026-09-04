import Foundation

enum SpotifyCatalogDecoder {
    static func profile(_ data: Data) throws -> SpotifyProfile {
        let value = try object(data)
        guard let id = (value["account_id"] as? String) ?? (value["id"] as? String), !id.isEmpty else {
            throw SpotifyCatalogError.invalidResponse
        }
        return SpotifyProfile(accountID: id, displayName: (value["display_name"] as? String) ?? id)
    }

    static func page(
        _ data: Data, query: SpotifyCatalogQuery, requestedURL: URL
    ) throws -> SpotifyPage<SpotifyCatalogRow> {
        let root = try object(data)
        let container: [String: Any]
        switch query {
        case let .search(_, kind):
            container = (root[kind.rawValue + "s"] as? [String: Any]) ?? [:]
        case .collection(.followedArtists):
            container = (root["artists"] as? [String: Any]) ?? [:]
        default:
            container = root
        }
        guard let items = container["items"] as? [Any] else {
            throw SpotifyCatalogError.invalidResponse
        }
        let requestedOffset = URLComponents(url: requestedURL, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "offset" })?.value.flatMap(Int.init)
        let offset = max(0, (container["offset"] as? Int) ?? requestedOffset ?? 0)
        var seen = Set<String>()
        let rows: [SpotifyCatalogRow] = items.enumerated().compactMap { index, raw in
            guard let wrapper = raw as? [String: Any] else { return nil }
            let payload: [String: Any]
            switch query {
            case .collection(.savedTracks), .collection(.recent):
                guard let track = wrapper["track"] as? [String: Any] else { return nil }
                payload = track
            case .collection(.savedAlbums):
                guard let album = wrapper["album"] as? [String: Any] else { return nil }
                payload = album
            case .playlistItems:
                guard let entry = (wrapper["item"] as? [String: Any])
                    ?? (wrapper["track"] as? [String: Any]) else { return nil }
                payload = entry
            default:
                payload = wrapper
            }
            let position = offset + index
            let item = item(payload, fallbackID: "missing-\(position)", local: wrapper["is_local"] as? Bool == true)
            // Keep duplicate playlist occurrences, but deduplicate collection/recent results.
            guard query.preservesPositions || seen.insert(item.id).inserted else { return nil }
            return SpotifyCatalogRow(
                id: query.preservesPositions ? "\(position):\(item.id)" : item.id,
                item: item, position: query.preservesPositions ? position : nil
            )
        }
        return SpotifyPage(
            items: rows,
            next: (container["next"] as? String).flatMap(URL.init(string:)),
            total: container["total"] as? Int
        )
    }

    static func detail(_ data: Data, kind: SpotifyCatalogKind) throws -> SpotifyCatalogDetail {
        let value = try object(data)
        guard let id = value["id"] as? String, validID(id) else { throw SpotifyCatalogError.invalidResponse }
        let item = item(value, fallbackID: id)
        guard item.kind == kind else { throw SpotifyCatalogError.invalidResponse }
        let children: SpotifyCatalogQuery?
        var availability = item.availability
        switch kind {
        case .track: children = nil
        case .album: children = .albumTracks(id)
        case .artist: children = .artistAlbums(id)
        case .playlist:
            // Dev Mode may supply metadata with no readable items. Do not invent a list.
            let embedded = (value["items"] as? [String: Any]) ?? (value["tracks"] as? [String: Any])
            if embedded?["items"] is [Any] {
                children = .playlistItems(id)
            } else {
                children = nil
                availability = .metadataOnly
            }
        }
        return SpotifyCatalogDetail(item: item, children: children, availability: availability)
    }

    static func validID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
        }
    }

    private static func object(_ data: Data) throws -> [String: Any] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SpotifyCatalogError.invalidResponse
        }
        return root
    }

    private static func item(
        _ value: [String: Any], fallbackID: String, local: Bool = false
    ) -> SpotifyCatalogItem {
        let rawID = value["id"] as? String
        let kind = (value["type"] as? String).flatMap(SpotifyCatalogKind.init(rawValue:))
        let artists = ((value["artists"] as? [[String: Any]]) ?? []).compactMap { (artist) -> SpotifyArtist? in
            guard let id = artist["id"] as? String, validID(id) else { return nil }
            return SpotifyArtist(id: id, name: (artist["name"] as? String) ?? String(localized: "catalog.unknown"))
        }
        let albumObject = value["album"] as? [String: Any]
        let owner = (value["owner"] as? [String: Any])?["display_name"] as? String
        let imageObjects = (value["images"] as? [[String: Any]]) ?? (albumObject?["images"] as? [[String: Any]]) ?? []
        let imageURL = imageObjects.compactMap { $0["url"] as? String }
            .compactMap(URL.init(string:)).first { $0.scheme == "https" }
        let unsupported = kind == nil || rawID.map(validID) != true || local || value["is_local"] as? Bool == true
        let restricted = value["is_playable"] as? Bool == false
            || !((value["restrictions"] as? [String: Any]) ?? [:]).isEmpty
        let subtitle = kind == .playlist ? owner ?? "" : artists.map(\.name).joined(separator: ", ")
        var result = SpotifyCatalogItem(
            spotifyID: rawID ?? fallbackID, kind: kind,
            name: (value["name"] as? String) ?? String(localized: "catalog.unknown"),
            subtitle: subtitle, artworkURL: imageURL,
            availability: unsupported ? .unsupported : restricted ? .restricted : .available,
            artists: artists, releaseDate: value["release_date"] as? String
        )
        if kind == .track {
            let album: SpotifyAlbum?
            if let albumID = albumObject?["id"] as? String, validID(albumID) {
                album = SpotifyAlbum(id: albumID, name: (albumObject?["name"] as? String) ?? "")
            } else {
                album = nil
            }
            result.track = SpotifyTrack(
                durationMS: max(0, (value["duration_ms"] as? Int) ?? 0), artists: artists, album: album,
                isrc: (value["external_ids"] as? [String: Any])?["isrc"] as? String
            )
        }
        if kind == .playlist {
            let content = (value["items"] as? [String: Any]) ?? (value["tracks"] as? [String: Any])
            result.playlist = SpotifyPlaylist(
                ownerName: owner, description: value["description"] as? String, total: content?["total"] as? Int
            )
        }
        return result
    }
}
