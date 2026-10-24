import Foundation

enum AppleMusicHomeDecoder {
    static func page(_ data: Data, query: MusicHomeQuery, url: URL) throws -> MusicHomePage {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let values = root["data"] as? [[String: Any]] else { throw MusicCatalogError.invalidResponse }
        let next = try AppleMusicAPI.next(root["next"] as? String, from: url)
        func rows(_ values: [[String: Any]], prefix: String) -> [MusicCatalogRow] {
            values.enumerated().compactMap { index, value in
                guard let item = AppleMusicCatalogDecoder.item(value) else { return nil }
                return .init(id: "\(prefix):\(index):\(item.id)", item: item, position: nil)
            }
        }
        switch query {
        case .recommendations:
            var groups: [MusicHomeSection] = [], pages: [String: MusicHomePage] = [:]
            for value in values {
                guard let id = value["id"] as? String, let a = value["attributes"] as? [String: Any] else { continue }
                let title = display(a["title"]) ?? "推荐"
                groups.append(.init(id: id, title: title, subtitle: display(a["reason"]), query: .recommendation(id)))
                if let relations = value["relationships"] as? [String: Any],
                   let content = relations["contents"] as? [String: Any], let items = content["data"] as? [[String: Any]] {
                    pages[id] = .init(items: rows(items, prefix: id), next: try AppleMusicAPI.next(content["next"] as? String, from: url))
                }
            }
            return .init(next: next, groups: groups, groupPages: pages)
        case .replay:
            guard let summary = values.first(where: { ($0["attributes"] as? [String: Any])?["period"] as? String == "year" }),
                  let a = summary["attributes"] as? [String: Any], let year = a["year"] as? Int else {
                if values.isEmpty { return .init() }
                throw MusicCatalogError.invalidResponse
            }
            let views = summary["views"] as? [String: Any] ?? [:]
            var sections: [MusicReplaySection] = []
            for (key, relationship, title) in [("top-songs", "song", "年度歌曲"), ("top-albums", "album", "年度专辑"), ("top-artists", "artist", "年度歌手")] {
                guard let view = views[key] as? [String: Any], let entries = view["data"] as? [[String: Any]] else { continue }
                let resources = entries.flatMap { entry -> [[String: Any]] in
                    let relationships = entry["relationships"] as? [String: Any]
                    return (relationships?[relationship] as? [String: Any])?["data"] as? [[String: Any]] ?? []
                }
                let decoded = rows(resources, prefix: "replay:\(year):\(key)")
                if !decoded.isEmpty { sections.append(.init(id: key, title: title, items: decoded)) }
            }
            return .init(replay: .init(year: String(year), sections: sections))
        default: return .init(items: rows(values, prefix: url.absoluteString), next: next, total: (root["meta"] as? [String: Any])?["total"] as? Int)
        }
    }
    private static func display(_ value: Any?) -> String? {
        (value as? String) ?? (value as? [String: Any])?["stringForDisplay"] as? String
    }
}
