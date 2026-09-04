import Foundation

enum SpotifyCatalogKind: String, CaseIterable, Hashable, Sendable {
    case track, album, artist, playlist

    var title: String {
        switch self {
        case .track: String(localized: "catalog.tracks")
        case .album: String(localized: "catalog.albums")
        case .artist: String(localized: "catalog.artists")
        case .playlist: String(localized: "catalog.playlists")
        }
    }
}

enum SpotifyContentAvailability: Hashable, Sendable {
    case available, restricted, unsupported, metadataOnly
}

struct SpotifyArtist: Hashable, Sendable {
    let id: String
    let name: String
}

struct SpotifyAlbum: Hashable, Sendable {
    let id: String
    let name: String
}

struct SpotifyTrack: Hashable, Sendable {
    let durationMS: Int
    let artists: [SpotifyArtist]
    let album: SpotifyAlbum?
    let isrc: String?
}

struct SpotifyPlaylist: Hashable, Sendable {
    let ownerName: String?
    let description: String?
    let total: Int?
}

/// Shared identity/presentation plus type-specific metadata. No playable audio URLs.
struct SpotifyCatalogItem: Identifiable, Hashable, Sendable {
    let spotifyID: String
    let kind: SpotifyCatalogKind?
    let name: String
    let subtitle: String
    let artworkURL: URL?
    let availability: SpotifyContentAvailability
    var track: SpotifyTrack? = nil
    var artists: [SpotifyArtist] = []
    var playlist: SpotifyPlaylist? = nil
    var releaseDate: String? = nil

    var id: String { "\(kind?.rawValue ?? "unsupported"):\(spotifyID)" }
    var uri: String? {
        guard let kind, !spotifyID.isEmpty, availability != .unsupported else { return nil }
        return "spotify:\(kind.rawValue):\(spotifyID)"
    }
    var externalURL: URL? {
        guard let kind, !spotifyID.isEmpty, availability != .unsupported else { return nil }
        return URL(string: "https://open.spotify.com/\(kind.rawValue)/\(spotifyID)")
    }
    var canPlay: Bool {
        guard let kind else { return false }
        return availability == .available && [SpotifyCatalogKind.track, .album, .playlist].contains(kind)
    }
}

/// Row identity preserves repeated playlist tracks and their *original* context position.
struct SpotifyCatalogRow: Identifiable, Hashable, Sendable {
    let id: String
    let item: SpotifyCatalogItem
    let position: Int?
}

struct SpotifyPage<Item: Sendable>: Sendable {
    let items: [Item]
    let next: URL?
    let total: Int?
}

struct SpotifyProfile: Equatable, Sendable {
    let accountID: String
    let displayName: String
}

enum SpotifyLibrarySection: String, CaseIterable, Hashable, Sendable {
    case playlists, savedTracks, savedAlbums, followedArtists, recent, topTracks

    static let library: [Self] = [.savedTracks, .savedAlbums, .followedArtists, .playlists]

    var title: String {
        switch self {
        case .playlists: String(localized: "catalog.myPlaylists")
        case .savedTracks: String(localized: "catalog.savedTracks")
        case .savedAlbums: String(localized: "catalog.savedAlbums")
        case .followedArtists: String(localized: "catalog.followedArtists")
        case .recent: String(localized: "catalog.recent")
        case .topTracks: String(localized: "catalog.topTracks")
        }
    }

    var symbol: String {
        switch self {
        case .playlists: "music.note.list"
        case .savedTracks: "heart"
        case .savedAlbums: "square.stack"
        case .followedArtists: "person.2"
        case .recent: "clock"
        case .topTracks: "chart.line.uptrend.xyaxis"
        }
    }
}

enum SpotifyCatalogQuery: Hashable, Sendable {
    case collection(SpotifyLibrarySection)
    case search(String, SpotifyCatalogKind)
    case albumTracks(String)
    case artistAlbums(String)
    case playlistItems(String)

    var endpoint: String {
        switch self {
        case .collection(.playlists): "me/playlists?limit=20"
        case .collection(.savedTracks): "me/tracks?limit=20"
        case .collection(.savedAlbums): "me/albums?limit=20"
        case .collection(.followedArtists): "me/following?type=artist&limit=20"
        case .collection(.recent): "me/player/recently-played?limit=20"
        case .collection(.topTracks): "me/top/tracks?time_range=short_term&limit=20"
        case let .search(term, kind):
            Self.searchEndpoint(term, kind: kind)
        case let .albumTracks(id): "albums/\(id)/tracks?limit=20"
        case let .artistAlbums(id): "artists/\(id)/albums?include_groups=album,single&limit=20"
        case let .playlistItems(id): "playlists/\(id)/items?limit=20"
        }
    }

    var preservesPositions: Bool {
        switch self {
        case .albumTracks, .playlistItems: true
        default: false
        }
    }

    private static func searchEndpoint(_ term: String, kind: SpotifyCatalogKind) -> String {
        var components = URLComponents()
        components.path = "search"
        components.queryItems = [
            URLQueryItem(name: "q", value: term),
            URLQueryItem(name: "type", value: kind.rawValue),
            URLQueryItem(name: "limit", value: "10"),
        ]
        return components.string ?? "search"
    }
}

struct SpotifyCatalogDetail: Sendable {
    let item: SpotifyCatalogItem
    let children: SpotifyCatalogQuery?
    let availability: SpotifyContentAvailability
}

enum SpotifyCatalogError: Error, Equatable, LocalizedError, Sendable {
    case signInRequired, forbidden, unavailable, quotaExceeded, invalidResponse, offline
    case rateLimited(until: Date)

    var errorDescription: String? {
        switch self {
        case .signInRequired: String(localized: "catalog.error.signIn")
        case .forbidden: String(localized: "catalog.error.forbidden")
        case .unavailable: String(localized: "catalog.error.unavailable")
        case .quotaExceeded: String(localized: "catalog.error.quota")
        case .invalidResponse: String(localized: "error.spotifyInvalidResponse")
        case .offline: String(localized: "error.offline")
        case let .rateLimited(until):
            String(localized: "catalog.error.rateLimit") + " " + until.formatted(date: .omitted, time: .standard)
        }
    }

    var allowsRetry: Bool {
        switch self {
        case .quotaExceeded, .signInRequired, .forbidden: false
        case let .rateLimited(until): Date() >= until
        default: true
        }
    }
}

@MainActor
protocol SpotifyCatalogProviding: AnyObject {
    func profile() async throws -> SpotifyProfile
    func page(_ query: SpotifyCatalogQuery, next: URL?) async throws -> SpotifyPage<SpotifyCatalogRow>
    func detail(kind: SpotifyCatalogKind, id: String) async throws -> SpotifyCatalogDetail
    func invalidate()
}
