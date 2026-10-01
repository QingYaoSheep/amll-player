import Foundation
import MediaPlayer
import UIKit

/// Metadata-only access. All playback commands remain in SystemMusicPlayer.
@MainActor
final class AppleMusicSystemArtwork {
    private let readArtwork: @MainActor (PlaybackItem) -> Data?
    private let cache: SystemArtworkCache
    private var key: String?
    private var imageURL: URL?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var nextAttempt: TimeInterval = 0

    init(cache: SystemArtworkCache = .init(), readArtwork: (@MainActor (PlaybackItem) -> Data?)? = nil) {
        self.cache = cache
        self.readArtwork = readArtwork ?? Self.readSystemArtwork
    }

    deinit { task?.cancel() }

    func url(for item: PlaybackItem, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> URL? {
        guard item.service == .appleMusic, !item.isEpisode else { reset(); return nil }
        if key != item.uri {
            reset()
            key = item.uri
        }
        if let imageURL, FileManager.default.fileExists(atPath: imageURL.path) {
            return imageURL
        }
        if imageURL != nil {
            imageURL = nil; nextAttempt = 0
        }
        guard task == nil, now >= nextAttempt else { return nil }
        nextAttempt = now + 2 // Artwork may arrive after metadata; never poll images per frame.
        guard let data = readArtwork(item), !data.isEmpty else { return nil }
        let token = generation
        task = Task { [weak self, cache] in
            defer {
                if let self, self.generation == token {
                    self.task = nil
                }
            }
            do {
                let url = try await cache.store(data)
                try Task.checkCancellation()
                guard let self, self.generation == token else { return }
                self.imageURL = url
            } catch { /* Keep MusicKit's URL and allow a later metadata-only retry. */ }
        }
        return nil
    }

    func reset() {
        generation = UUID()
        task?.cancel()
        task = nil
        key = nil
        imageURL = nil
        nextAttempt = 0
    }

    static func matches(_ item: PlaybackItem, storeID: String, title: String?, artist: String?,
                        album: String?, duration: TimeInterval) -> Bool
    {
        guard item.service == .appleMusic, !item.isEpisode else { return false }
        let validStoreID = !storeID.isEmpty && storeID != "0"
        let catalogID = item.catalogID ?? (item.resourceScope == .catalog ? item.id : nil)
        if validStoreID, let catalogID {
            return storeID == catalogID
        }
        func normalized(_ text: String?) -> String {
            (text ?? "").precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !normalized(title).isEmpty, normalized(title) == normalized(item.title),
              !normalized(artist).isEmpty, item.artists.contains(where: { normalized($0) == normalized(artist) }),
              let album, let currentAlbum = item.albumTitle, normalized(album) == normalized(currentAlbum),
              duration.isFinite, item.duration.isFinite, duration > 0, item.duration > 0,
              abs(duration - item.duration) <= 1 else { return false }
        return true
    }

    private static func readSystemArtwork(_ item: PlaybackItem) -> Data? {
        guard let media = MPMusicPlayerController.systemMusicPlayer.nowPlayingItem,
              matches(item, storeID: media.playbackStoreID, title: media.title, artist: media.artist,
                      album: media.albumTitle, duration: media.playbackDuration),
              let image = media.artwork?.image(at: CGSize(width: 1000, height: 1000)) else { return nil }
        return image.pngData()
    }
}

/// Files contain cover images only, never MusicKit credentials or private URLs.
/// Disk work is serialized off the main actor; both byte count and file count are bounded.
actor SystemArtworkCache {
    let directory: URL
    let byteLimit: Int
    init(directory: URL? = nil, byteLimit: Int = 24 * 1024 * 1024) {
        self.directory = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AppleMusicSystemArtwork", isDirectory: true)
        self.byteLimit = byteLimit
    }

    func store(_ data: Data) throws -> URL {
        try Task.checkCancellation()
        guard !data.isEmpty, data.count <= byteLimit else { throw URLError(.dataLengthExceedsMaximum) }
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(UUID().uuidString + ".png")
        try data.write(to: url, options: .atomic)
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        let files = try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys))
            .filter { $0.pathExtension == "png" && $0 != url }
            .compactMap { file -> (URL, Int, Date)? in
                guard let values = try? file.resourceValues(forKeys: keys), values.isRegularFile == true else { return nil }
                return (file, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
            }.sorted { $0.2 > $1.2 }
        var bytes = data.count
        var count = 1
        for file in files {
            if bytes + file.1 <= byteLimit, count < 6 {
                bytes += file.1; count += 1
            } else {
                try manager.removeItem(at: file.0)
            }
        }
        return url
    }
}
