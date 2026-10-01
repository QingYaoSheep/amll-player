import Foundation

enum NetEaseDecoder {
    static func id(_ value: Any?) -> String { (value as? NSNumber)?.stringValue ?? (value as? String) ?? "" }
    static func image(_ value: Any?) -> URL? {
        guard let raw = value as? String, var c = URLComponents(string: raw),
              let host = c.host, host == "music.163.com" || host.hasSuffix(".music.126.net") else { return nil }
        if c.scheme == "http" { c.scheme = "https" }
        return c.scheme == "https" ? c.url : nil
    }
    static func artists(_ value: Any?) -> [MusicArtist] {
        (value as? [[String: Any]] ?? []).map { .init(id: id($0["id"]), name: $0["name"] as? String ?? "") }
    }
    static func item(_ value: [String: Any], kind: MusicCatalogKind, owner: String? = nil) -> MusicCatalogItem? {
        let identifier = id(value["id"])
        guard !identifier.isEmpty, let name = value["name"] as? String else { return nil }
        let art = artists(value["ar"] ?? value["artists"])
        let album = value["al"] as? [String: Any] ?? value["album"] as? [String: Any] ?? [:]
        let creator = value["creator"] as? [String: Any] ?? [:]
        let own = owner != nil && id(creator["userId"]) == owner
        let privilege = value["privilege"] as? [String: Any] ?? [:]
        let restricted = (privilege["st"] as? Int ?? 0) < 0
        return .init(spotifyID: identifier, kind: kind, name: name,
                     subtitle: kind == .playlist ? creator["nickname"] as? String ?? "" : art.map(\.name).joined(separator: ", "),
                     artworkURL: image(value["coverImgUrl"] ?? value["picUrl"] ?? value["img1v1Url"] ?? album["picUrl"]),
                     availability: restricted ? .restricted : (kind == .artist ? .metadataOnly : .available),
                     track: kind == .track ? .init(durationMS: value["dt"] as? Int ?? value["duration"] as? Int ?? 0,
                                                  artists: art, album: album.isEmpty ? nil : .init(id: id(album["id"]), name: album["name"] as? String ?? ""), isrc: value["isrc"] as? String) : nil,
                     artists: art,
                     playlist: kind == .playlist ? .init(ownerName: creator["nickname"] as? String,
                                                        description: value["description"] as? String, total: value["trackCount"] as? Int) : nil,
                     service: .netease, publicURL: URL(string: "https://music.163.com/#/\(kind == .track ? "song" : kind.rawValue)?id=\(identifier)"),
                     catalogID: identifier, inFavorites: value["subscribed"] as? Bool,
                     editablePlaylist: own && (value["specialType"] as? Int != 5), libraryWritable: own && (value["specialType"] as? Int != 5))
    }
    static func missingTrack(_ id: String) -> MusicCatalogItem {
        .init(spotifyID: id, kind: .track, name: "不可用歌曲", subtitle: "", artworkURL: nil,
              availability: .restricted, service: .netease, catalogID: id)
    }
}

enum NetEaseQuality: String, CaseIterable, Codable, Identifiable {
    case standard, exhigh, lossless
    var id: String { rawValue }
    var title: String { switch self { case .standard: "标准"; case .exhigh: "高品质"; case .lossless: "无损" } }
}
struct NetEaseAudioSource {
    var url: URL
    var level: String
    var bitrate: Int
    var trialEnd: Double?
    static func decode(_ root: [String: Any], id: String) throws -> Self {
        guard let row = (root["data"] as? [[String: Any]])?.first(where: { NetEaseDecoder.id($0["id"]) == id }) else { throw NetEaseError.invalidResponse }
        guard row["code"] as? Int == 200, let raw = row["url"] as? String, !raw.isEmpty else { throw NetEaseError.restricted }
        guard row["freeTrialInfo"] == nil || row["freeTrialInfo"] is NSNull else { throw NetEaseError.trialOnly }
        guard var c = URLComponents(string: raw), let host = c.host,
              host.hasSuffix(".music.126.net") || host.hasSuffix(".music.163.com") else { throw NetEaseError.unavailable }
        if c.scheme == "http" { c.scheme = "https" }
        guard c.scheme == "https", let url = c.url else { throw NetEaseError.unavailable }
        return .init(url: url, level: row["level"] as? String ?? "", bitrate: row["br"] as? Int ?? 0, trialEnd: nil)
    }
}
