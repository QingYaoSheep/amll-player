import Foundation

@MainActor final class NetEaseLibrary: MusicLibraryMutating {
    let session: NetEaseSession
    let catalog: NetEaseCatalog
    init(session: NetEaseSession, catalog: NetEaseCatalog) { self.session = session; self.catalog = catalog }
    func favorite(_ item: MusicCatalogItem) async throws { try await setFavorite(item, enabled: true) }
    func setFavorite(_ item: MusicCatalogItem, enabled: Bool) async throws {
        let context = session.currentState.contextID
        guard item.service == .netease else { throw NetEaseError.invalidResponse }
        if item.kind == .track {
            _ = try await session.call("/radio/like", ["trackId": item.spotifyID, "like": enabled, "alg": "itembased", "time": 3])
            let state = try await favoriteState(item)
            guard state == enabled else { throw NetEaseError.invalidResponse }
        } else if item.kind == .playlist {
            _ = try await session.call(enabled ? "/playlist/subscribe" : "/playlist/unsubscribe", ["id": item.spotifyID])
            catalog.invalidate()
            let p = try await catalog.playlist(item.spotifyID, force: true)
            guard p["subscribed"] as? Bool == enabled else { throw NetEaseError.invalidResponse }
        } else { throw MusicServiceError.unsupportedOperation }
        try check(context)
        catalog.invalidate()
    }
    func favoriteState(_ item: MusicCatalogItem) async throws -> Bool {
        if item.kind == .track {
            let r = try await session.call("/song/like/get", ["uid": session.profile?.id ?? ""])
            return (r["ids"] as? [Any] ?? []).contains { NetEaseDecoder.id($0) == item.spotifyID }
        }
        let p = try await catalog.playlist(item.spotifyID, force: true)
        return p["subscribed"] as? Bool ?? false
    }
    func addToLibrary(_ item: MusicCatalogItem) async throws { try await favorite(item) }
    func createPlaylist(name: String, description: String) async throws -> MusicCatalogItem {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 100 else { throw MusicServiceError.musicFailure("请输入 1–100 字的歌单名称。") }
        let context = session.currentState.contextID
        let before = try await ownedPlaylists(); try check(context)
        let r: [String: Any]
        do { r = try await session.call("/playlist/create", ["name": title, "privacy": 0, "type": "NORMAL"]) }
        catch let error as URLError where error.code == .timedOut {
            // Never blindly retry a create whose server-side outcome is uncertain.
            let after = try await ownedPlaylists()
            let old = Set(before.map(\.spotifyID))
            let candidates = after.filter { !old.contains($0.spotifyID) && $0.name == title }
            guard candidates.count == 1 else { throw MusicServiceError.musicFailure("创建结果尚未确认，请刷新我的歌单后核对，避免重复创建。") }
            try check(context)
            if !description.isEmpty { try await editPlaylist(candidates[0], name: title, description: description, entries: nil) }
            return candidates[0]
        }
        guard let p = r["playlist"] as? [String: Any],
              let item = NetEaseDecoder.item(p, kind: .playlist, owner: session.profile?.id) else { throw NetEaseError.invalidResponse }
        try check(context)
        if !description.isEmpty { try await editPlaylist(item, name: title, description: description, entries: nil) }
        catalog.invalidate()
        return try await catalog.detail(kind: .playlist, id: item.spotifyID).item
    }
    func append(_ item: MusicCatalogItem, to playlist: MusicCatalogItem) async throws {
        try await modify(item, in: playlist, remove: false)
    }
    func remove(_ item: MusicCatalogItem, from playlist: MusicCatalogItem) async throws {
        try await modify(item, in: playlist, remove: true)
    }
    private func modify(_ item: MusicCatalogItem, in playlist: MusicCatalogItem, remove: Bool) async throws {
        guard item.service == .netease, item.kind == .track else { throw NetEaseError.invalidResponse }
        let context = session.currentState.contextID
        try await requireOwner(playlist); try check(context)
        let before = try await catalog.playlistIDs(playlist.spotifyID)
        try check(context)
        if before.contains(item.spotifyID) == !remove { return }
        let tracks = String(data: try JSONSerialization.data(withJSONObject: [item.spotifyID]), encoding: .utf8)!
        do {
            _ = try await session.call("/playlist/manipulate/tracks", ["op": remove ? "del" : "add", "pid": playlist.spotifyID, "trackIds": tracks, "imme": true])
        } catch let error as URLError where error.code == .timedOut {
            catalog.invalidate()
            let after = try await catalog.playlistIDs(playlist.spotifyID)
            guard after.contains(item.spotifyID) == !remove else { throw error }
        }
        catalog.invalidate()
        guard try await catalog.playlistIDs(playlist.spotifyID).contains(item.spotifyID) == !remove else { throw NetEaseError.invalidResponse }
    }
    func editPlaylist(_ playlist: MusicCatalogItem, name: String, description: String, entries: [MusicCatalogItem]?) async throws {
        guard entries == nil else { throw MusicServiceError.unsupportedOperation }
        let context = session.currentState.contextID
        try await requireOwner(playlist); try check(context)
        let id = playlist.spotifyID
        func json(_ p: [String: Any]) throws -> String { String(data: try JSONSerialization.data(withJSONObject: p), encoding: .utf8)! }
        let batch = try ["/api/playlist/update/name": json(["id": id, "name": name]),
                         "/api/playlist/desc/update": json(["id": id, "desc": description])]
        let r = try await session.call("/batch", batch)
        for key in batch.keys {
            if let result = r[key] as? [String: Any], result["code"] as? Int != 200 { throw NetEaseError.invalidResponse }
        }
        catalog.invalidate()
        let p = try await catalog.playlist(id, force: true)
        guard p["name"] as? String == name, (p["description"] as? String ?? "") == description else { throw NetEaseError.invalidResponse }
    }
    func deletePlaylist(_ item: MusicCatalogItem) async throws {
        let context = session.currentState.contextID
        try await requireOwner(item); try check(context)
        _ = try await session.call("/playlist/remove", ["ids": "[\(item.spotifyID)]"])
        catalog.invalidate()
        guard !(try await ownedPlaylists()).contains(where: { $0.spotifyID == item.spotifyID }) else { throw NetEaseError.invalidResponse }
    }
    private func check(_ context: UUID) throws {
        guard session.currentState.connected, session.currentState.contextID == context else { throw CancellationError() }
    }
    private func requireOwner(_ item: MusicCatalogItem) async throws {
        guard item.service == .netease, item.kind == .playlist else { throw NetEaseError.invalidResponse }
        let p = try await catalog.playlist(item.spotifyID, force: true)
        let creator = p["creator"] as? [String: Any] ?? [:]
        guard NetEaseDecoder.id(creator["userId"]) == session.profile?.id, p["specialType"] as? Int != 5 else {
            throw MusicServiceError.musicFailure("此歌单不能由当前账号编辑。")
        }
    }
    private func ownedPlaylists() async throws -> [MusicCatalogItem] {
        var next: URL?; var output: [MusicCatalogItem] = []
        repeat {
            let page = try await catalog.page(.collection(.playlists), next: next)
            output += page.items.map(\.item).filter(\.editablePlaylist); next = page.next
        } while next != nil
        return output
    }
}
