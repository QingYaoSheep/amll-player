import Foundation

enum MusicCatalogKind: String, CaseIterable, Hashable, Codable, Sendable {
    case track, album, artist, playlist, station, musicVideo

    var title: String {
        switch self {
        case .track: String(localized: "catalog.tracks")
        case .album: String(localized: "catalog.albums")
        case .artist: String(localized: "catalog.artists")
        case .playlist: String(localized: "catalog.playlists")
        case .station: "电台"
        case .musicVideo: "音乐视频"
        }
    }
}

enum MusicContentAvailability: String, Codable, Hashable, Sendable {
    case available, restricted, unsupported, metadataOnly
}

struct MusicArtist: Codable, Hashable, Sendable {
    let id: String
    let name: String
}

struct MusicAlbum: Codable, Hashable, Sendable {
    let id: String
    let name: String
}

struct MusicTrack: Codable, Hashable, Sendable {
    let durationMS: Int
    let artists: [MusicArtist]
    let album: MusicAlbum?
    let isrc: String?
}

struct MusicPlaylist: Codable, Hashable, Sendable {
    let ownerName: String?
    let description: String?
    let total: Int?
}

/// Shared identity/presentation plus type-specific metadata. No playable audio URLs.
struct MusicCatalogItem: Codable, Identifiable, Hashable, Sendable {
    let spotifyID: String
    let kind: MusicCatalogKind?
    let name: String
    let subtitle: String
    let artworkURL: URL?
    let availability: MusicContentAvailability
    var track: MusicTrack?
    var artists: [MusicArtist] = []
    var playlist: MusicPlaylist?
    var releaseDate: String?

    var service: MusicServiceID = .spotify
    var scope: MusicResourceScope = .catalog
    var publicURL: URL?
    var catalogID: String?
    var inFavorites: Bool?
    var editablePlaylist = false
    var libraryWritable = false
    var isExplicit = false
    var resource: MusicResourceID? {
        kind.map { MusicResourceID(service: service, kind: $0, scope: scope, rawValue: spotifyID) }
    }

    var id: String {
        service == .spotify ? "\(kind?.rawValue ?? "unsupported"):\(spotifyID)"
            : resource?.key ?? "\(service.rawValue):unsupported:\(spotifyID)"
    }

    var uri: String? {
        guard let kind, !spotifyID.isEmpty, availability != .unsupported else { return nil }
        if service == .netease { return "netease:\(kind.rawValue):\(spotifyID)" }
        return service == .spotify ? "spotify:\(kind.rawValue):\(spotifyID)" : "applemusic:\(scope.rawValue):\(kind.rawValue):\(spotifyID)"
    }

    var externalURL: URL? {
        if service != .spotify {
            return publicURL
        }
        guard let kind, !spotifyID.isEmpty, availability != .unsupported else { return nil }
        return URL(string: "https://open.spotify.com/\(kind.rawValue)/\(spotifyID)")
    }

    var canPlay: Bool {
        guard let kind else { return false }
        return availability == .available && [MusicCatalogKind.track, .album, .playlist, .station].contains(kind)
    }
}

/// Row identity preserves repeated playlist tracks and their *original* context position.
struct MusicCatalogRow: Identifiable, Hashable, Sendable {
    let id: String
    let item: MusicCatalogItem
    let position: Int?
}

struct MusicPage<Item: Sendable>: Sendable {
    let items: [Item]
    let next: URL?
    let total: Int?
}

struct MusicProfile: Equatable, Sendable {
    let accountID: String
    let displayName: String
}

enum MusicLibrarySection: String, CaseIterable, Hashable, Sendable {
    case dailySongs, playlists, savedTracks, savedAlbums, followedArtists, recent, topTracks, recentlyAdded, recommendations, charts, downloaded

    static let library: [Self] = [.savedTracks, .savedAlbums, .followedArtists, .playlists]

    var title: String {
        switch self {
        case .dailySongs: "每日推荐歌曲"
        case .playlists: String(localized: "catalog.myPlaylists")
        case .savedTracks: String(localized: "catalog.savedTracks")
        case .savedAlbums: String(localized: "catalog.savedAlbums")
        case .followedArtists: String(localized: "catalog.followedArtists")
        case .recent: String(localized: "catalog.recent")
        case .topTracks: String(localized: "catalog.topTracks")
        case .recentlyAdded: "最近添加"
        case .recommendations: "为你推荐"
        case .charts: "排行榜"
        case .downloaded: "已下载歌曲"
        }
    }

    var symbol: String {
        switch self {
        case .dailySongs: "sun.max"
        case .playlists: "music.note.list"
        case .savedTracks: "heart"
        case .savedAlbums: "square.stack"
        case .followedArtists: "person.2"
        case .recent: "clock"
        case .topTracks: "chart.line.uptrend.xyaxis"
        case .recentlyAdded: "plus.circle"
        case .recommendations: "sparkles"
        case .charts: "chart.bar"
        case .downloaded: "arrow.down.circle"
        }
    }
}

enum MusicCatalogQuery: Hashable, Sendable {
    case collection(MusicLibrarySection)
    case search(String, MusicCatalogKind)
    case albumTracks(String)
    case artistAlbums(String)
    case playlistItems(String)
    case librarySearch(String, MusicCatalogKind)
    case resourceChildren(MusicResourceID)
    case libraryItems(MusicLibrarySection, ascending: Bool)

    var endpoint: String {
        switch self {
        case .collection(.playlists): "me/playlists?limit=20"
        case .collection(.savedTracks): "me/tracks?limit=20"
        case .collection(.savedAlbums): "me/albums?limit=20"
        case .collection(.followedArtists): "me/following?type=artist&limit=20"
        case .collection(.recent): "me/player/recently-played?limit=20"
        case .collection(.topTracks): "me/top/tracks?time_range=short_term&limit=20"
        case .collection(.dailySongs), .collection(.recentlyAdded), .collection(.recommendations), .collection(.charts), .collection(.downloaded), .librarySearch, .resourceChildren, .libraryItems: ""
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
        case let .resourceChildren(resource): resource.kind == .album || resource.kind == .playlist
        default: false
        }
    }

    private static func searchEndpoint(_ term: String, kind: MusicCatalogKind) -> String {
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

struct MusicCatalogDetail: Sendable {
    let item: MusicCatalogItem
    let children: MusicCatalogQuery?
    let availability: MusicContentAvailability
}

enum MusicCatalogError: Error, Equatable, LocalizedError, Sendable {
    case signInRequired, forbidden, unavailable, quotaExceeded, invalidResponse, offline
    case rateLimited(until: Date)
    case service(MusicServiceError, retry: Bool)

    static func presenting(_ error: Error, service: MusicServiceID) -> Self {
        if let netease = error as? NetEaseError { return .service(.musicFailure(netease.localizedDescription), retry: netease != .expired) }
        if let error = error as? MusicServiceError {
            let retry: Bool
            switch error {
            case .musicConfiguration, .musicPermissionDenied, .musicPermissionRestricted, .musicSubscriptionRequired, .cloudLibraryRequired: retry = false
            default: retry = true
            }
            return .service(error, retry: retry)
        }
        let error = error as? Self ?? .invalidResponse
        if service == .netease { return .service(.musicFailure(error.localizedDescription), retry: true) }
        guard service == .appleMusic else { return error }
        switch error {
        case .signInRequired: return .service(.musicPermissionDenied, retry: false)
        case .forbidden: return .service(.musicFailure("Apple Music 拒绝访问，请检查系统授权、订阅和同步资料库状态。"), retry: false)
        case .invalidResponse: return .service(.musicFailure("Apple Music 返回了无法识别的响应。"), retry: true)
        default: return error
        }
    }

    var errorDescription: String? {
        switch self {
        case .signInRequired: String(localized: "catalog.error.signIn")
        case .forbidden: String(localized: "catalog.error.forbidden")
        case .unavailable: String(localized: "catalog.error.unavailable")
        case .quotaExceeded: String(localized: "catalog.error.quota")
        case .invalidResponse: String(localized: "error.spotifyInvalidResponse")
        case .offline: String(localized: "error.offline")
        case let .service(error, _): error.localizedDescription
        case let .rateLimited(until):
            String(localized: "catalog.error.rateLimit") + " " + until.formatted(date: .omitted, time: .standard)
        }
    }

    var allowsRetry: Bool {
        switch self {
        case .quotaExceeded, .signInRequired, .forbidden: false
        case let .rateLimited(until): Date() >= until
        case let .service(_, retry): retry
        default: true
        }
    }
}

@MainActor
protocol MusicCatalogProviding: AnyObject {
    func profile() async throws -> MusicProfile
    func page(_ query: MusicCatalogQuery, next: URL?) async throws -> MusicPage<MusicCatalogRow>
    func detail(kind: MusicCatalogKind, id: String) async throws -> MusicCatalogDetail
    func invalidate()
    var service: MusicServiceID { get }
    var homeSections: [MusicLibrarySection] { get }
    var librarySections: [MusicLibrarySection] { get }
    var searchKinds: [MusicCatalogKind] { get }
    func detail(resource: MusicResourceID) async throws -> MusicCatalogDetail
    func suggestions(_ term: String) async throws -> [String]
}

extension MusicCatalogProviding {
    var service: MusicServiceID {
        .spotify
    }

    var homeSections: [MusicLibrarySection] {
        [.playlists, .savedTracks, .savedAlbums, .followedArtists, .recent, .topTracks]
    }

    var librarySections: [MusicLibrarySection] {
        MusicLibrarySection.library
    }

    var searchKinds: [MusicCatalogKind] {
        [.track, .album, .artist, .playlist]
    }

    func detail(resource: MusicResourceID) async throws -> MusicCatalogDetail {
        guard resource.service == service else { throw MusicCatalogError.unavailable }
        return try await detail(kind: resource.kind, id: resource.rawValue)
    }

    func suggestions(_: String) async throws -> [String] {
        []
    }
}

// Source-compatible adapters for the existing Spotify client and fixtures.
typealias SpotifyCatalogKind = MusicCatalogKind
typealias SpotifyContentAvailability = MusicContentAvailability
typealias SpotifyArtist = MusicArtist
typealias SpotifyAlbum = MusicAlbum
typealias SpotifyTrack = MusicTrack
typealias SpotifyPlaylist = MusicPlaylist
typealias SpotifyCatalogItem = MusicCatalogItem
typealias SpotifyCatalogRow = MusicCatalogRow
typealias SpotifyPage = MusicPage
typealias SpotifyProfile = MusicProfile
typealias SpotifyLibrarySection = MusicLibrarySection
typealias SpotifyCatalogQuery = MusicCatalogQuery
typealias SpotifyCatalogDetail = MusicCatalogDetail
typealias SpotifyCatalogError = MusicCatalogError
typealias SpotifyCatalogProviding = MusicCatalogProviding
