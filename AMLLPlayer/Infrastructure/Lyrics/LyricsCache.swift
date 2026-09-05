import CryptoKit
import Foundation
import SwiftData

struct LyricsSelection: Codable, Equatable, Sendable {
    var candidate: LyricCandidate? = nil
    var offset: Double = 0
}

struct LyricsCacheEntry: Codable, Sendable {
    var track: TrackIdentity
    var payload: LyricsPayload
    var document: LyricsDocument
    var savedAt: Date
    var parserVersion: Int = LyricsDocument.parserVersion
    func isFresh(days: Int, now: Date = Date()) -> Bool {
        days == 0 || now.timeIntervalSince(savedAt) < Double(days) * 86400
    }
}

@MainActor
protocol LyricsCacheProviding {
    func read(track: TrackIdentity, source: LyricsSource, settings: LyricsSettings) throws -> LyricsCacheEntry?
    func save(_ entry: LyricsCacheEntry, settings: LyricsSettings) throws
    func selection(for trackID: String) throws -> LyricsSelection
    func saveSelection(_ value: LyricsSelection, for trackID: String) throws
    func clearLyrics() throws
    func resetSelections() throws
}

@Model
final class StoredLyrics {
    @Attribute(.unique) var key: String
    var scope: String
    var data: Data
    init(key: String, scope: String, data: Data) {
        self.key = key; self.scope = scope; self.data = data
    }
}

@Model
final class StoredLyricsSelection {
    @Attribute(.unique) var trackID: String
    var data: Data
    init(trackID: String, data: Data) {
        self.trackID = trackID; self.data = data
    }
}

@MainActor
final class SwiftDataLyricsCache: LyricsCacheProviding {
    private let container: ModelContainer
    private var context: ModelContext {
        container.mainContext
    }

    init(inMemory: Bool = false) throws {
        if !inMemory, let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            try FileManager.default.createDirectory(at: applicationSupport, withIntermediateDirectories: true)
        }
        let schema = Schema([StoredLyrics.self, StoredLyricsSelection.self])
        container = try ModelContainer(for: schema, configurations: [ModelConfiguration("Lyrics-v1", schema: schema, isStoredInMemoryOnly: inMemory)])
        context.autosaveEnabled = false
    }

    private func scope(_ track: TrackIdentity, _ source: LyricsSource, _ settings: LyricsSettings) -> String {
        let components = [track.spotifyID, source.rawValue, settings.storefront, settings.language]
        let bytes = (try? JSONEncoder().encode(components)) ?? Data()
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    func read(track: TrackIdentity, source: LyricsSource, settings: LyricsSettings) throws -> LyricsCacheEntry? {
        let scope = scope(track, source, settings)
        let rows = try context.fetch(FetchDescriptor<StoredLyrics>(predicate: #Predicate { $0.scope == scope }))
        guard let stored = rows.first else { return nil }
        guard var entry = try? JSONDecoder().decode(LyricsCacheEntry.self, from: stored.data), entry.track.spotifyID == track.spotifyID,
              entry.document.candidate.source == source else { throw LyricsError.cache }
        if entry.parserVersion != LyricsDocument.parserVersion {
            entry.document = try entry.payload.parse(candidate: entry.document.candidate, duration: track.duration)
            entry.parserVersion = LyricsDocument.parserVersion
            try save(entry, settings: settings)
        }
        return entry
    }

    func save(_ entry: LyricsCacheEntry, settings: LyricsSettings) throws {
        let scope = scope(entry.track, entry.document.candidate.source, settings)
        let data = try JSONEncoder().encode(entry)
        do {
            for old in try context.fetch(FetchDescriptor<StoredLyrics>(predicate: #Predicate { $0.scope == scope })) {
                context.delete(old)
            }
            context.insert(StoredLyrics(key: scope + ":\(LyricsDocument.parserVersion)", scope: scope, data: data))
            try context.save()
        } catch { context.rollback(); throw LyricsError.cache }
    }

    func selection(for trackID: String) throws -> LyricsSelection {
        guard let stored = try context.fetch(FetchDescriptor<StoredLyricsSelection>(predicate: #Predicate { $0.trackID == trackID })).first else { return LyricsSelection() }
        guard var value = try? JSONDecoder().decode(LyricsSelection.self, from: stored.data) else { throw LyricsError.cache }
        value.offset = value.offset.isFinite ? max(-10, min(10, value.offset)) : 0
        return value
    }

    func saveSelection(_ value: LyricsSelection, for trackID: String) throws {
        let data = try JSONEncoder().encode(value)
        do {
            if let stored = try context.fetch(FetchDescriptor<StoredLyricsSelection>(predicate: #Predicate { $0.trackID == trackID })).first {
                stored.data = data
            } else {
                context.insert(StoredLyricsSelection(trackID: trackID, data: data))
            }
            try context.save()
        } catch { context.rollback(); throw LyricsError.cache }
    }

    func clearLyrics() throws {
        do { try context.delete(model: StoredLyrics.self); try context.save() }
        catch { context.rollback(); throw LyricsError.cache }
    }

    func resetSelections() throws {
        // Keep offsets; this operation only resets manually chosen matches.
        do {
            for stored in try context.fetch(FetchDescriptor<StoredLyricsSelection>()) {
                var selection = (try? JSONDecoder().decode(LyricsSelection.self, from: stored.data)) ?? LyricsSelection()
                selection.candidate = nil; stored.data = try JSONEncoder().encode(selection)
            }
            try context.save()
        } catch { context.rollback(); throw LyricsError.cache }
    }
}

/// Nonfatal fallback if the on-disk SwiftData store cannot be opened; never deletes it.
@MainActor
final class MemoryLyricsCache: LyricsCacheProviding {
    var entries: [String: LyricsCacheEntry] = [:]
    var selections: [String: LyricsSelection] = [:]
    private func key(_ id: String, _ source: LyricsSource, _ settings: LyricsSettings) -> String {
        [id, source.rawValue, settings.storefront, settings.language].joined(separator: "\u{1f}")
    }

    func read(track: TrackIdentity, source: LyricsSource, settings: LyricsSettings) throws -> LyricsCacheEntry? {
        entries[key(track.spotifyID, source, settings)]
    }

    func save(_ entry: LyricsCacheEntry, settings: LyricsSettings) throws {
        entries[key(entry.track.spotifyID, entry.document.candidate.source, settings)] = entry
    }

    func selection(for trackID: String) throws -> LyricsSelection {
        selections[trackID] ?? LyricsSelection()
    }

    func saveSelection(_ value: LyricsSelection, for trackID: String) throws {
        selections[trackID] = value
    }

    func clearLyrics() throws {
        entries.removeAll()
    }

    func resetSelections() throws {
        for key in Array(selections.keys) {
            selections[key]?.candidate = nil
        }
    }
}
