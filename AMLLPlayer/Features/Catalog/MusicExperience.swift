import Foundation
import Observation

enum MusicHomePresentation {
    static let order: [MusicLibrarySection] = [.recent, .playlists, .dailySongs, .recommendations, .recentlyAdded, .charts, .topTracks, .savedTracks, .savedAlbums, .followedArtists]
    static func sections(supported: [MusicLibrarySection], connected: Bool) -> [MusicLibrarySection] {
        order.filter { supported.contains($0) && (connected || [.recommendations, .charts].contains($0)) }
    }
    static func usesSongColumns(_ section: MusicLibrarySection, kinds: [MusicCatalogKind?] = []) -> Bool {
        if !kinds.isEmpty { return kinds.allSatisfy { $0 == .track } }
        return [.recent, .dailySongs, .topTracks, .savedTracks].contains(section)
    }
}

struct MusicSearchRequest: Hashable {
    let term: String
    let library: Bool
    let kind: MusicCatalogKind?
    func queries(supported: [MusicCatalogKind]) -> [MusicCatalogQuery] {
        let kinds = kind.map { [$0] } ?? [.track, .album, .artist, .playlist].filter { supported.contains($0) }
        return kinds.map { library ? .librarySearch(term, $0) : .search(term, $0) }
    }
}

@MainActor
final class MusicWelcomePreferences {
    static let key = "music.welcome.completed.v1"
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    func needsWelcome(existingConnection: Bool, savedSpotifyConfiguration: Bool) -> Bool {
        if defaults.object(forKey: Self.key) != nil { return !defaults.bool(forKey: Self.key) }
        let legacy = ["music.source.v1", "lyrics.settings.v1", "lyrics.render.v2", "lyrics.render.v1"]
            .contains { defaults.object(forKey: $0) != nil }
        if legacy || existingConnection || savedSpotifyConfiguration { complete(); return false }
        return true
    }
    func complete() { defaults.set(true, forKey: Self.key) }
}

extension AppModel {
    func isConnected(to service: MusicServiceID) -> Bool {
        switch service {
        case .spotify: sessionState.isAuthenticated
        case .appleMusic: appleMusicState.connected
        case .netease: netEaseState.connected
        }
    }
    var canBrowseCurrentService: Bool {
        switch selectedMusicService {
        case .spotify: sessionState.isAuthenticated
        case .appleMusic: appleMusicState.connected && appleMusicState.capabilities.canBrowse
        case .netease: true
        }
    }
    func connectionSummary(_ service: MusicServiceID) -> String {
        if service == .appleMusic, appleMusicState.connected, !appleMusicState.capabilities.canBrowse {
            return "已连接 · 系统歌曲同步"
        }
        return isConnected(to: service) ? "已连接" : "未连接"
    }
}
