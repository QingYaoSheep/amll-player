import Foundation

/// Catalog metadata only. Discovery never downloads media or starts playback.
struct ArtworkAsset: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case squareVideo, portraitVideo }
    var kind: Kind
    var url: URL
    var albumID: String
    var storefront: String

    static func mediaURL(_ value: Any?, depth: Int = 0) -> URL? {
        guard depth < 5 else { return nil }
        if let value = value as? String {
            guard let url = URL(string: value), url.scheme == "https", url.host != nil,
                  url.user == nil, url.password == nil else { return nil }
            return url
        }
        guard let object = value as? [String: Any] else { return nil }
        for key in ["url", "href", "video"] {
            if let url = mediaURL(object[key], depth: depth + 1) {
                return url
            }
        }
        return nil
    }

    static func catalogAssets(attributes: [String: Any], albumID: String, storefront: String) -> [Self] {
        guard let video = attributes["editorialVideo"] as? [String: Any] else { return [] }
        return [("motionDetailSquare", Kind.squareVideo), ("motionDetailTall", Kind.portraitVideo)].compactMap { key, kind in
            guard let url = mediaURL(video[key]) else { return nil }
            return .init(kind: kind, url: url, albumID: albumID, storefront: storefront)
        }
    }
}
