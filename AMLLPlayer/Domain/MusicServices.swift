import Foundation

enum MusicServiceID: String, Codable, CaseIterable, Identifiable, Sendable {
    case spotify, appleMusic
    var id: String {
        rawValue
    }

    var title: String {
        self == .spotify ? "Spotify" : "Apple Music"
    }
}

enum MusicResourceScope: String, Codable, Hashable, Sendable { case catalog, library }

struct MusicResourceID: Hashable, Codable, Sendable {
    let service: MusicServiceID
    let kind: MusicCatalogKind
    let scope: MusicResourceScope
    let rawValue: String
    var key: String {
        "\(service.rawValue):\(scope.rawValue):\(kind.rawValue):\(rawValue)"
    }

    init(service: MusicServiceID, kind: MusicCatalogKind, scope: MusicResourceScope, rawValue: String) {
        self.service = service; self.kind = kind; self.scope = scope; self.rawValue = rawValue
    }

    init?(appleURI: String) {
        let parts = appleURI.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0] == "applemusic", let scope = MusicResourceScope(rawValue: String(parts[1])),
              let kind = MusicCatalogKind(rawValue: String(parts[2])), !parts[3].isEmpty else { return nil }
        self.init(service: .appleMusic, kind: kind, scope: scope, rawValue: String(parts[3]))
    }
}

struct MusicServiceCapabilities: Equatable, Sendable {
    var canBrowse = false
    var canPlayCatalog = false
    var canModifyLibrary = false
    var canFavorite = false
    var usesSystemRoutes = false
    static let spotify = Self(canBrowse: true, canPlayCatalog: true)
}

enum MusicAuthorizationState: String, Sendable {
    case notDetermined, denied, restricted, authorized
}

struct MusicConnectionState: Equatable, Sendable {
    var contextID = UUID()
    var connected = false
    var requesting = false
    var authorization: MusicAuthorizationState = .notDetermined
    var storefront: String?
    var capabilities = MusicServiceCapabilities()
    var error: MusicServiceError?
}

@MainActor
protocol MusicSessionProviding: AnyObject {
    var currentState: MusicConnectionState { get }
    var connectionStates: AsyncStream<MusicConnectionState> { get }
    func connect() async
    func refresh() async
    func disconnect()
}

enum MusicRepeatMode: String, CaseIterable, Sendable {
    case off, all, one
    var title: String {
        switch self { case .off: "关闭"; case .all: "全部循环"; case .one: "单曲循环" }
    }
}

@MainActor
protocol MusicPlaybackProviding: AnyObject {
    var playbackSnapshots: AsyncStream<PlaybackSnapshot> { get }
    func start()
    func stop()
    func enterForeground()
    func enterBackground()
    func refresh() async throws
    func play() async throws
    func pause() async throws
    func seek(to position: TimeInterval) async throws
    func skipNext() async throws
    func skipPrevious() async throws
    func play(item: MusicCatalogItem, context: MusicResourceID?, position: Int?) async throws
    func setVolume(percent: Int, on deviceID: String?) async throws
    func devices() async throws -> [PlaybackDevice]
    func transferPlayback(to deviceID: String) async throws
    func setShuffle(_ enabled: Bool) async throws
    func setRepeat(_ mode: MusicRepeatMode) async throws
    func enqueue(_ item: MusicCatalogItem, next: Bool) async throws
}

extension MusicPlaybackProviding {
    func setVolume(percent _: Int, on _: String?) async throws {
        throw MusicServiceError.unsupportedOperation
    }

    func devices() async throws -> [PlaybackDevice] {
        []
    }

    func transferPlayback(to _: String) async throws {
        throw MusicServiceError.unsupportedOperation
    }

    func setShuffle(_: Bool) async throws {
        throw MusicServiceError.unsupportedOperation
    }

    func setRepeat(_: MusicRepeatMode) async throws {
        throw MusicServiceError.unsupportedOperation
    }

    func enqueue(_: MusicCatalogItem, next _: Bool) async throws {
        throw MusicServiceError.unsupportedOperation
    }
}

@MainActor
protocol MusicLibraryMutating: AnyObject {
    func favorite(_ item: MusicCatalogItem) async throws
    func addToLibrary(_ item: MusicCatalogItem) async throws
    func createPlaylist(name: String, description: String) async throws -> MusicCatalogItem
    func append(_ item: MusicCatalogItem, to playlist: MusicCatalogItem) async throws
    func editPlaylist(_ playlist: MusicCatalogItem, name: String, description: String, entries: [MusicCatalogItem]?) async throws
}

/// Spotify's persisted ID remains byte-for-byte unchanged. New services use
/// namespaced IDs so all existing lyric selection/offset stores remain readable.
enum MusicTrackIdentity {
    static func key(service: MusicServiceID, scope: MusicResourceScope, id: String) -> String {
        service == .spotify ? id : "\(service.rawValue):\(scope.rawValue):\(id)"
    }
}

@MainActor
final class MusicSourcePreferences {
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var selected: MusicServiceID {
        get { defaults.string(forKey: "music.source.v1").flatMap(MusicServiceID.init(rawValue:)) ?? .spotify }
        set { defaults.set(newValue.rawValue, forKey: "music.source.v1") }
    }

    var hasSelection: Bool {
        defaults.object(forKey: "music.source.v1") != nil
    }
}
