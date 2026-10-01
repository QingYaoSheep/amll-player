import Combine
import Foundation
import MusicKit

enum AppleMusicSongMapping {
    static func catalog(_ song: Song, scope: MusicResourceScope) -> MusicCatalogItem {
        .init(spotifyID: song.id.rawValue, kind: .track, name: song.title, subtitle: song.artistName,
              artworkURL: song.artwork?.url(width: 1000, height: 1000),
              availability: song.playParameters == nil ? .metadataOnly : .available,
              track: .init(durationMS: Int((song.duration ?? 0) * 1000), artists: [.init(id: "", name: song.artistName)],
                           album: nil, isrc: song.isrc), service: .appleMusic, scope: scope, publicURL: song.url,
              catalogID: scope == .catalog ? song.id.rawValue : nil)
    }

    static func playback(_ song: Song) -> PlaybackItem {
        let scope: MusicResourceScope = song.id.rawValue.hasPrefix("i.") ? .library : .catalog
        return .init(id: song.id.rawValue, uri: "applemusic:\(scope.rawValue):track:\(song.id.rawValue)",
                     title: song.title, artists: [song.artistName], albumTitle: song.albumTitle,
                     artworkURL: song.artwork?.url(width: 1000, height: 1000), duration: song.duration ?? 0,
                     isEpisode: false, isAdvertisement: false, isrc: song.isrc,
                     service: .appleMusic, resourceScope: scope,
                     catalogID: scope == .catalog ? song.id.rawValue : nil)
    }
}

/// Observes the system player. stop/enterBackground only stop observation;
/// neither disconnect nor a source switch pauses or clears the Music app queue.
@MainActor
final class AppleMusicPlayback: MusicPlaybackProviding {
    let playbackSnapshots: AsyncStream<PlaybackSnapshot>
    private let continuation: AsyncStream<PlaybackSnapshot>.Continuation
    private let session: AppleMusicSession
    private var polling: Task<Void, Never>?
    private var subscriptions = Set<AnyCancellable>()
    private var enabled = false
    private var foreground = false
    private var commandGeneration = UUID()
    private var previous: PlaybackSnapshot?
    private var revision: UInt64 = 0
    private var knownEntryID: String?
    private(set) var knownContext: MusicResourceID?
    private var player: SystemMusicPlayer {
        .shared
    }

    init(session: AppleMusicSession) {
        self.session = session
        let stream = AsyncStream<PlaybackSnapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
        playbackSnapshots = stream.stream
        continuation = stream.continuation
    }

    deinit { polling?.cancel(); continuation.finish() }

    func start() {
        enabled = true; schedule()
    }

    func stop() {
        enabled = false
        commandGeneration = UUID()
        polling?.cancel(); polling = nil
        subscriptions.removeAll()
        previous = nil
        knownContext = nil
    }

    func enterForeground() {
        foreground = true; schedule()
    }

    func enterBackground() {
        foreground = false; polling?.cancel(); polling = nil; subscriptions.removeAll()
    }

    private func schedule() {
        guard enabled, foreground, session.currentState.connected, polling == nil else { return }
        player.state.objectWillChange.sink { [weak self] in
            Task { @MainActor in
                await Task.yield()
                guard let self, enabled, foreground else { return }
                sample()
            }
        }.store(in: &subscriptions)
        player.queue.objectWillChange.sink { [weak self] in
            Task { @MainActor in
                await Task.yield()
                guard let self, enabled, foreground else { return }
                knownContext = nil // External mutations invalidate the app's queue assumptions.
                sample()
            }
        }.store(in: &subscriptions)
        polling = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, enabled, foreground, session.currentState.connected else { return }
                sample()
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            }
        }
    }

    func refresh() async throws {
        try requireConnection(); sample()
    }

    func play() async throws {
        try requireConnection(); try await player.play(); sample()
    }

    func pause() async throws {
        try requireConnection(); player.pause(); sample()
    }

    func seek(to position: TimeInterval) async throws {
        try requireConnection()
        guard position.isFinite, let previous, previous.restrictions.canSeek else { throw MusicServiceError.unsupportedOperation }
        player.playbackTime = min(previous.duration, max(0, position))
        revision &+= 1
        sample()
    }

    func skipNext() async throws {
        try requireConnection(); try await player.skipToNextEntry(); sample()
    }

    func skipPrevious() async throws {
        try requireConnection(); try await player.skipToPreviousEntry(); sample()
    }

    func setShuffle(_ enabled: Bool) async throws {
        try requireConnection(); player.state.shuffleMode = enabled ? .songs : .off; sample()
    }

    func setRepeat(_ mode: MusicRepeatMode) async throws {
        try requireConnection()
        switch mode { case .off: player.state.repeatMode = MusicPlayer.RepeatMode.none
        case .all: player.state.repeatMode = .all
        case .one: player.state.repeatMode = .one }
        sample()
    }

    func play(item: MusicCatalogItem, context: MusicResourceID?, position: Int?) async throws {
        try requireConnection()
        guard session.currentState.capabilities.canPlayCatalog || item.scope == .library else { throw MusicServiceError.musicSubscriptionRequired }
        guard item.service == .appleMusic, item.canPlay else { throw MusicCatalogError.unavailable }
        let token = commandGeneration
        let connection = session.connectionID
        let resource = context ?? item.resource!
        let queue: MusicPlayer.Queue
        switch resource.kind {
        case .playlist:
            let playlist = try await resolvePlaylist(resource)
            if let position {
                let loaded = try await playlist.with([.entries])
                guard let entries = loaded.entries, let entry = try await entryAt(position, in: entries) else { throw MusicCatalogError.unavailable }
                queue = MusicPlayer.Queue(playlist: loaded, startingAt: entry)
            } else {
                queue = MusicPlayer.Queue(for: [playlist])
            }
        case .album:
            let album = try await resolveAlbum(resource)
            if let position {
                let loaded = try await album.with([.tracks])
                guard let tracks = loaded.tracks, let track = try await entryAt(position, in: tracks) else { throw MusicCatalogError.unavailable }
                queue = MusicPlayer.Queue(album: loaded, startingAt: track)
            } else {
                queue = MusicPlayer.Queue(for: [album])
            }
        case .track: queue = try await MusicPlayer.Queue(for: [resolveSong(resource)])
        case .station:
            let response = try await MusicCatalogResourceRequest<Station>(matching: \.id, equalTo: MusicItemID(resource.rawValue)).response()
            guard let station = response.items.first else { throw MusicCatalogError.unavailable }
            queue = MusicPlayer.Queue(for: [station])
        case .artist, .musicVideo: throw MusicServiceError.unsupportedOperation
        }
        try Task.checkCancellation()
        guard token == commandGeneration, connection == session.connectionID, enabled else { throw CancellationError() }
        player.queue = queue
        try await player.play()
        guard token == commandGeneration else { throw CancellationError() }
        knownContext = context ?? item.resource
        knownEntryID = player.queue.currentEntry?.id
        sample()
    }

    func enqueue(_ item: MusicCatalogItem, next: Bool) async throws {
        try requireConnection()
        guard let resource = item.resource, resource.service == .appleMusic, resource.kind == .track else { throw MusicServiceError.unsupportedOperation }
        let token = commandGeneration
        let song = try await resolveSong(resource)
        try Task.checkCancellation()
        guard token == commandGeneration, enabled else { throw CancellationError() }
        try await player.queue.insert(song, position: next ? .afterCurrentEntry : .tail)
    }

    func resolveSong(_ resource: MusicResourceID) async throws -> Song {
        if resource.scope == .library {
            var request = MusicLibraryRequest<Song>()
            request.filter(matching: \.id, equalTo: MusicItemID(resource.rawValue))
            guard let song = try await request.response().items.first else { throw MusicCatalogError.unavailable }
            return song
        }
        let request = MusicCatalogResourceRequest<Song>(matching: \.id, equalTo: MusicItemID(resource.rawValue))
        guard let song = try await request.response().items.first else { throw MusicCatalogError.unavailable }
        return song
    }

    func resolvePlaylist(_ resource: MusicResourceID) async throws -> Playlist {
        if resource.scope == .library {
            var request = MusicLibraryRequest<Playlist>()
            request.filter(matching: \.id, equalTo: MusicItemID(resource.rawValue))
            guard let item = try await request.response().items.first else { throw MusicCatalogError.unavailable }
            return item
        }
        guard let item = try await MusicCatalogResourceRequest<Playlist>(matching: \.id, equalTo: MusicItemID(resource.rawValue)).response().items.first else { throw MusicCatalogError.unavailable }
        return item
    }

    private func resolveAlbum(_ resource: MusicResourceID) async throws -> Album {
        if resource.scope == .library {
            var request = MusicLibraryRequest<Album>()
            request.filter(matching: \.id, equalTo: MusicItemID(resource.rawValue))
            guard let item = try await request.response().items.first else { throw MusicCatalogError.unavailable }
            return item
        }
        guard let item = try await MusicCatalogResourceRequest<Album>(matching: \.id, equalTo: MusicItemID(resource.rawValue)).response().items.first else { throw MusicCatalogError.unavailable }
        return item
    }

    private func entryAt<T: MusicItem>(_ position: Int, in collection: MusicItemCollection<T>) async throws -> T? {
        guard position >= 0 else { return nil }
        var batch = collection
        var offset = 0
        while true {
            try Task.checkCancellation()
            if position < offset + batch.count {
                return Array(batch)[position - offset]
            }
            offset += batch.count
            guard batch.hasNextBatch, let next = try await batch.nextBatch(limit: 100), !next.isEmpty else { return nil }
            batch = next
        }
    }

    private func sample() {
        guard enabled, foreground, session.currentState.connected else { return }
        let entry = player.queue.currentEntry
        var item: PlaybackItem?
        if case let .song(song) = entry?.item {
            item = AppleMusicSongMapping.playback(song)
        } else if let entry {
            item = .init(id: entry.id, uri: "applemusic:entry:\(entry.id)", title: entry.title,
                         artists: [entry.subtitle ?? ""], albumTitle: nil,
                         artworkURL: entry.artwork?.url(width: 1000, height: 1000), duration: 0,
                         isEpisode: true, isAdvertisement: false, service: .appleMusic)
        }
        let time = player.playbackTime
        let now = ProcessInfo.processInfo.systemUptime
        let valid = time.isFinite && time >= 0
        let duration = item?.duration ?? 0
        let playing = player.state.playbackStatus == .playing && valid
        let position = valid ? (duration > 0 ? min(time, duration) : time) : 0
        if let previous, previous.item?.uri == item?.uri, valid,
           abs(position - PlayerClock(anchor: previous).position(at: now)) > 1
        {
            revision &+= 1
        }
        if knownEntryID != entry?.id {
            knownContext = nil; knownEntryID = entry?.id
        }
        let snapshot = PlaybackSnapshot(item: item, isPlaying: playing, position: position, duration: duration,
                                        device: nil, restrictions: .init(canPause: true, canResume: true, canSeek: duration > 0 && valid,
                                                                         canSkipNext: true, canSkipPrevious: true),
                                        source: .musicKit, sampledAtUptime: now,
                                        playbackRate: playing ? Double(player.state.playbackRate) : 0, positionRevision: revision,
                                        shuffleEnabled: player.state.shuffleMode == .songs,
                                        repeatMode: player.state.repeatMode == .one ? .one : (player.state.repeatMode == .all ? .all : .off))
        previous = snapshot
        continuation.yield(snapshot)
    }

    private func requireConnection() throws {
        guard session.currentState.connected else { throw MusicServiceError.musicPermissionDenied }
    }
}
