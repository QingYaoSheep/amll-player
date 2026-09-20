import CryptoKit
import Foundation

/// Stores completed media only. HLS packages stay at the URL assigned by
/// AVFoundation; moving a .movpkg can invalidate its internal references.
@MainActor
final class ArtworkMediaCache {
    static let shared = ArtworkMediaCache()
    static let maximumBytes: Int64 = 200 * 1024 * 1024
    private struct Entry: Codable {
        var key: String
        var relativePath: String
        var accessed: Date
        var unusable: Bool?
        var bytes: Int64?
    }

    private let root: URL
    private let sandbox: URL
    private let registry: URL
    private let limit: Int64
    private var entries: [Entry] = []

    init(root: URL? = nil, sandbox: URL = URL(fileURLWithPath: NSHomeDirectory()), limit: Int64 = maximumBytes) {
        self.sandbox = sandbox.standardizedFileURL.resolvingSymlinksInPath()
        self.root = (root ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AnimatedArtwork", isDirectory: true)).standardizedFileURL.resolvingSymlinksInPath()
        self.limit = max(0, limit)
        registry = self.sandbox.appendingPathComponent("Library/Application Support/AMLLArtwork/index.json")
        try? FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: registry.deletingLastPathComponent(), withIntermediateDirectories: true)
        // HLS ownership must survive eviction of Library/Caches.
        for file in [registry, registry.appendingPathExtension("backup"), self.root.appendingPathComponent("index.json")] {
            if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode([Entry].self, from: data) {
                entries = saved; break
            }
        }
        prune()
    }

    private func key(_ url: URL) -> String {
        SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func safeURL(_ relativePath: String) -> URL? {
        let url = sandbox.appendingPathComponent(relativePath).standardizedFileURL.resolvingSymlinksInPath()
        guard url.path.hasPrefix(sandbox.path + "/"),
              url.pathExtension == "movpkg" || url.path.hasPrefix(root.standardizedFileURL.path + "/") else { return nil }
        return url
    }

    func cached(_ remote: URL) -> URL? {
        guard let index = entries.firstIndex(where: { $0.key == key(remote) }),
              entries[index].unusable != true,
              let url = safeURL(entries[index].relativePath) else { return nil }
        let actualBytes = size(url)
        guard actualBytes > 0, entries[index].bytes.map({ $0 == actualBytes }) ?? true else {
            invalidate(localURL: url)
            return nil
        }
        entries[index].bytes = actualBytes
        entries[index].accessed = Date()
        save()
        return url
    }

    /// Reject only the exact failed file, not a newer replacement for its URL.
    /// Retain ownership if deletion fails so clear/prune can still reclaim it.
    func invalidate(localURL: URL) {
        guard localURL.isFileURL else { return }
        let target = localURL.standardizedFileURL.resolvingSymlinksInPath()
        for index in entries.indices where safeURL(entries[index].relativePath) == target {
            entries[index].unusable = true
        }
        entries.removeAll { entry in
            guard entry.unusable == true, let owned = safeURL(entry.relativePath), owned == target else { return false }
            do { try FileManager.default.removeItem(at: owned); return true }
            catch { return !FileManager.default.fileExists(atPath: owned.path) }
        }
        save()
    }

    /// A local file is admitted atomically after a successful download. An
    /// oversized asset is rejected rather than evicting everything then keeping it.
    func insert(_ local: URL, for remote: URL, managedPackage: Bool) throws -> URL {
        let destination: URL
        if managedPackage {
            destination = local.standardizedFileURL.resolvingSymlinksInPath()
            guard destination.path.hasPrefix(sandbox.path + "/"), destination.pathExtension == "movpkg" else {
                throw CocoaError(.fileReadInvalidFileName)
            }
        } else {
            // Download into a new owned file before replacing the registry
            // entry. A missing, corrupt or oversized replacement must not
            // destroy the last usable cover for the same remote URL.
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            destination = root.appendingPathComponent(key(remote) + "-" + UUID().uuidString + ".mp4")
            try FileManager.default.moveItem(at: local, to: destination)
        }
        let bytes = size(destination)
        guard bytes > 0, bytes <= limit else {
            try? FileManager.default.removeItem(at: destination)
            throw CocoaError(.fileWriteOutOfSpace)
        }
        for entry in entries where entry.key == key(remote) {
            if let previous = safeURL(entry.relativePath), previous != destination,
               FileManager.default.fileExists(atPath: previous.path)
            {
                do { try FileManager.default.removeItem(at: previous) }
                catch { try? FileManager.default.removeItem(at: destination); throw error }
            }
        }
        entries.removeAll { $0.key == key(remote) }
        entries.append(.init(key: key(remote), relativePath: String(destination.path.dropFirst(sandbox.path.count + 1)), accessed: Date(), bytes: bytes))
        prune()
        guard byteCount <= limit else {
            // If an older package cannot be removed, reject the new admission
            // rather than silently exceeding the configured cache budget.
            try? FileManager.default.removeItem(at: destination)
            // Keep ownership if rollback itself fails so clear/prune can retry.
            if !FileManager.default.fileExists(atPath: destination.path) {
                entries.removeAll { $0.key == key(remote) }
            }
            save()
            throw CocoaError(.fileWriteOutOfSpace)
        }
        return destination
    }

    var byteCount: Int64 {
        entries.reduce(0) { $0 + (safeURL($1.relativePath).map(size) ?? 0) }
    }

    func clear() {
        entries.removeAll { entry in
            guard let url = safeURL(entry.relativePath), FileManager.default.fileExists(atPath: url.path) else { return true }
            do { try FileManager.default.removeItem(at: url); return true }
            catch { return false }
        }
        save()
    }

    private func prune() {
        entries.removeAll { entry in
            guard let url = safeURL(entry.relativePath) else { return true }
            return !FileManager.default.fileExists(atPath: url.path)
        }
        entries.sort { $0.accessed < $1.accessed }
        var total = byteCount
        while total > limit, let entry = entries.first {
            if let url = safeURL(entry.relativePath) {
                let bytes = size(url)
                do { try FileManager.default.removeItem(at: url) }
                catch { break }
                total -= bytes
            }
            entries.removeFirst()
        }
        save()
    }

    private func size(_ url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey]
        func bytes(_ file: URL) -> Int64 {
            guard let values = try? file.resourceValues(forKeys: keys), values.isRegularFile == true,
                  values.isSymbolicLink != true else { return 0 }
            return Int64(values.fileSize ?? 0)
        }
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
           let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys))
        {
            return enumerator.reduce(0) { $0 + (($1 as? URL).map(bytes) ?? 0) }
        }
        return bytes(url)
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: registry, options: .atomic)
            try? data.write(to: registry.appendingPathExtension("backup"), options: .atomic)
        }
    }
}
