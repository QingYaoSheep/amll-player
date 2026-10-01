import CryptoKit
import Foundation

@MainActor final class NetEaseCatalog: MusicCatalogProviding {
    let service: MusicServiceID = .netease
    let session: NetEaseSession
    private var epoch = UUID()
    private var playlists: [String: [String: Any]] = [:]
    private var sequenceCache: [String: [MusicCatalogItem]] = [:]
    var homeSections: [MusicLibrarySection] { session.currentState.connected ? [.playlists, .savedTracks, .dailySongs, .recommendations, .charts, .recent] : [.recommendations, .charts] }
    var librarySections: [MusicLibrarySection] { session.currentState.connected ? [.savedTracks, .playlists, .savedAlbums, .followedArtists] : [] }
    var searchKinds: [MusicCatalogKind] { [.track, .album, .artist, .playlist] }
    init(session: NetEaseSession) { self.session = session }
    func invalidate() { epoch = UUID(); playlists.removeAll(); sequenceCache.removeAll() }
    func profile() async throws -> MusicProfile {
        guard let p = session.profile else { throw NetEaseError.expired }
        return .init(accountID: p.id, displayName: p.name)
    }
    private func call(_ path: String, _ p: [String: Any] = [:], privateData: Bool = true) async throws -> [String: Any] {
        let token = epoch
        let r = try await session.call(path, p, authenticated: privateData)
        guard token == epoch else { throw CancellationError() }; return r
    }
    func songs(_ ids: [String]) async throws -> [MusicCatalogItem] {
        var output: [MusicCatalogItem] = []
        for start in stride(from: 0, to: ids.count, by: 100) {
            let batch = Array(ids[start..<min(ids.count, start + 100)])
            let c = String(data: try JSONSerialization.data(withJSONObject: batch.map { ["id": $0] }), encoding: .utf8)!
            let r = try await call("/v3/song/detail", ["c": c], privateData: false)
            var byID: [String: MusicCatalogItem] = [:]
            for v in r["songs"] as? [[String: Any]] ?? [] {
                if let item = NetEaseDecoder.item(v, kind: .track) { byID[item.spotifyID] = item }
            }
            output += batch.map { byID[$0] ?? NetEaseDecoder.missingTrack($0) }
        }
        return output
    }
    func playlist(_ id: String, force: Bool = false) async throws -> [String: Any] {
        if !force, let cached = playlists[id] { return cached }
        let r = try await call("/v6/playlist/detail", ["id": id, "n": 0, "s": 0], privateData: false)
        guard let p = r["playlist"] as? [String: Any] else { throw NetEaseError.invalidResponse }
        // Bounded metadata cache; contains IDs, never audio URLs.
        if playlists.count >= 16 { playlists.removeAll() }
        playlists[id] = p; return p
    }
    func playlistIDs(_ id: String) async throws -> [String] {
        let p = try await playlist(id)
        guard let entries = p["trackIds"] as? [[String: Any]] else { throw NetEaseError.invalidResponse }
        return entries.map { NetEaseDecoder.id($0["id"]) }
    }
    func allSongs(_ resource: MusicResourceID) async throws -> [MusicCatalogItem] {
        guard resource.service == .netease else { throw NetEaseError.invalidResponse }
        switch resource.kind {
        case .track: return try await songs([resource.rawValue])
        case .playlist: _ = try await playlist(resource.rawValue, force: true)
            return try await songs(playlistIDs(resource.rawValue))
        case .album:
            let r = try await call("/v1/album/" + resource.rawValue, privateData: false)
            return (r["songs"] as? [[String: Any]] ?? []).compactMap { NetEaseDecoder.item($0, kind: .track) }
        default: throw MusicServiceError.unsupportedOperation
        }
    }
    func detail(kind: MusicCatalogKind, id: String) async throws -> MusicCatalogDetail {
        var v: [String: Any]
        let children: MusicCatalogQuery?
        switch kind {
        case .playlist: v = try await playlist(id, force: true); children = .playlistItems(id)
        case .album:
            let r = try await call("/v1/album/" + id, privateData: false); v = r["album"] as? [String: Any] ?? [:]; children = .albumTracks(id)
        case .artist:
            let r = try await call("/v1/artist/" + id, privateData: false); v = r["artist"] as? [String: Any] ?? [:]; children = .artistAlbums(id)
        case .track:
            guard let item = try await songs([id]).first else { throw NetEaseError.invalidResponse }
            return .init(item: item, children: nil, availability: item.availability)
        default: throw MusicServiceError.unsupportedOperation
        }
        // Ownership must be established from the response, never from navigation scope.
        v["id"] = id
        guard let item = NetEaseDecoder.item(v, kind: kind, owner: session.profile?.id) else { throw NetEaseError.invalidResponse }
        return .init(item: item, children: children, availability: item.availability)
    }
    func suggestions(_ term: String) async throws -> [String] {
        let r = try await call("/search/suggest/keyword", ["s": term], privateData: false)
        let a = (r["result"] as? [String: Any])?["allMatch"] as? [[String: Any]] ?? []
        return a.compactMap { $0["keyword"] as? String }
    }
    func page(_ query: MusicCatalogQuery, next: URL?) async throws -> MusicPage<MusicCatalogRow> {
        let key = SHA256.hash(data: Data(String(describing: query).utf8)).map { String(format: "%02x", $0) }.joined()
        let offset: Int
        if let next {
            guard next.scheme == "https", next.host == "music.163.com", next.path == "/amll-page/" + key,
                  let raw = URLComponents(url: next, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "offset" })?.value,
                  let parsed = Int(raw), parsed >= 0 else { throw NetEaseError.invalidResponse }
            offset = parsed
        } else { offset = 0 }
        let limit = 50
        var values: [MusicCatalogItem] = []
        var total: Int?; var more = false
        func decode(_ array: Any?, _ kind: MusicCatalogKind) -> [MusicCatalogItem] {
            (array as? [[String: Any]] ?? []).compactMap { NetEaseDecoder.item($0, kind: kind, owner: session.profile?.id) }
        }
        switch query {
        case let .search(term, kind):
            let type = [MusicCatalogKind.track: 1, .album: 10, .artist: 100, .playlist: 1000][kind] ?? 1
            let r = try await call("/cloudsearch/pc", ["s": term, "type": type, "limit": limit, "offset": offset, "total": true], privateData: false)
            let result = r["result"] as? [String: Any] ?? [:]
            let name = [MusicCatalogKind.track: "songs", .album: "albums", .artist: "artists", .playlist: "playlists"][kind] ?? "songs"
            values = decode(result[name], kind)
            total = result[[MusicCatalogKind.track: "songCount", .album: "albumCount", .artist: "artistCount", .playlist: "playlistCount"][kind] ?? "songCount"] as? Int
            more = offset + values.count < (total ?? 0)
        case let .playlistItems(id):
            if offset == 0 { _ = try await playlist(id, force: true) }
            let ids = try await playlistIDs(id); total = ids.count
            values = try await songs(Array(ids.dropFirst(offset).prefix(limit))); more = offset + values.count < ids.count
        case let .albumTracks(id):
            let all = try await allSongs(.init(service: .netease, kind: .album, scope: .catalog, rawValue: id))
            total = all.count; values = Array(all.dropFirst(offset).prefix(limit)); more = offset + values.count < all.count
        case let .artistAlbums(id):
            let r = try await call("/artist/albums/" + id, ["offset": offset, "limit": limit], privateData: false)
            values = decode(r["hotAlbums"], .album); more = r["more"] as? Bool ?? false
        case let .collection(section):
            let uid = session.profile?.id ?? ""
            switch section {
            case .playlists:
                let r = try await call("/user/playlist", ["uid": uid, "offset": offset, "limit": limit, "includeVideo": false])
                values = decode(r["playlist"], .playlist); more = r["more"] as? Bool ?? false
            case .savedAlbums, .followedArtists:
                let r = try await call(section == .savedAlbums ? "/album/sublist" : "/artist/sublist", ["offset": offset, "limit": limit])
                values = decode(r["data"], section == .savedAlbums ? .album : .artist); more = r["hasMore"] as? Bool ?? false; total = r["count"] as? Int
            case .savedTracks:
                let r = try await call("/song/like/get", ["uid": uid])
                let ids = (r["ids"] as? [Any] ?? []).map(NetEaseDecoder.id)
                total = ids.count; values = try await songs(Array(ids.dropFirst(offset).prefix(limit)))
                values = values.map { var v = $0; v.inFavorites = true; return v }; more = offset + values.count < ids.count
            case .dailySongs, .recommendations, .charts, .recent:
                let all: [MusicCatalogItem]
                if offset > 0, let cached = sequenceCache[key] { all = cached } else {
                    let path: String
                    switch section {
                    case .dailySongs: path = "/v3/discovery/recommend/songs"
                    case .recommendations: path = "/personalized/playlist"
                    case .charts: path = "/toplist"
                    default: path = "/play-record/song/list"
                    }
                    let r = try await call(path, ["limit": 100], privateData: section == .dailySongs || section == .recent)
                    let data = r["data"] as? [String: Any] ?? [:]
                    switch section {
                    case .dailySongs: all = decode(data["dailySongs"], .track)
                    case .recommendations: all = decode(r["result"], .playlist)
                    case .charts: all = decode(r["list"], .playlist)
                    default:
                        let entries = data["list"] as? [[String: Any]] ?? []
                        all = entries.compactMap { ($0["data"] as? [String: Any]).flatMap { NetEaseDecoder.item($0, kind: .track) } }
                    }
                    sequenceCache[key] = all
                }
                total = all.count; values = Array(all.dropFirst(offset).prefix(limit)); more = offset + values.count < all.count
            default: throw MusicServiceError.unsupportedOperation
            }
        default: throw MusicServiceError.unsupportedOperation
        }
        let rows = values.enumerated().map { i, item in
            MusicCatalogRow(id: "\(key):\(offset + i):\(item.id)", item: item, position: query.preservesPositions ? offset + i : nil)
        }
        return .init(items: rows, next: more ? URL(string: "https://music.163.com/amll-page/\(key)?offset=\(offset + values.count)") : nil, total: total)
    }
    func audio(_ id: String, quality: NetEaseQuality) async throws -> NetEaseAudioSource {
        let r = try await call("/song/enhance/player/url/v1", ["ids": "[\(id)]", "level": quality.rawValue, "encodeType": "flac"], privateData: false)
        return try NetEaseAudioSource.decode(r, id: id)
    }
}
