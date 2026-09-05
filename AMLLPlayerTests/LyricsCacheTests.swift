@testable import AMLLPlayer
import XCTest

@MainActor
final class LyricsCacheTests: XCTestCase {
    func testSwiftDataRoundTripAndRegionLanguageIsolation() throws {
        let cache = try SwiftDataLyricsCache(inMemory: true)
        let track = TrackIdentity(spotifyID: "spotify-id", title: "Fixture", artists: [], duration: 10)
        let candidate = LyricCandidate(source: .qq, sourceID: "qq-id", title: "Fixture", artists: [])
        let payload = LyricsPayload(format: .lrc, original: "[00:01]Text")
        let entry = try LyricsCacheEntry(track: track, payload: payload, document: payload.parse(candidate: candidate, duration: 10), savedAt: Date())
        var settings = LyricsSettings()
        try cache.save(entry, settings: settings)
        XCTAssertEqual(try cache.read(track: track, source: .qq, settings: settings)?.document, entry.document)
        XCTAssertNil(try cache.read(track: track, source: .apple, settings: settings))
        settings.language = "en"; XCTAssertNil(try cache.read(track: track, source: .qq, settings: settings))
        settings = LyricsSettings(); settings.storefront = "gb"
        XCTAssertNil(try cache.read(track: track, source: .qq, settings: settings))
    }

    func testParserUpgradeReparsesRawWithoutLosingSelectionOffsetOrDate() throws {
        let cache = try SwiftDataLyricsCache(inMemory: true), settings = LyricsSettings()
        let track = TrackIdentity(spotifyID: "song", title: "Fixture", artists: [], duration: 10)
        let candidate = LyricCandidate(source: .qq, sourceID: "qq", title: "Fixture", artists: [])
        let payload = LyricsPayload(format: .lrc, original: "[00:01]Fresh parser")
        var document = try payload.parse(candidate: candidate, duration: 10); document.lines[0].text = "Old parser"
        let date = Date(timeIntervalSince1970: 100)
        try cache.save(LyricsCacheEntry(track: track, payload: payload, document: document, savedAt: date, parserVersion: 0), settings: settings)
        try cache.saveSelection(LyricsSelection(candidate: candidate, offset: 2.5), for: "song")
        let restored = try cache.read(track: track, source: .qq, settings: settings)
        XCTAssertEqual(restored?.document.lines.first?.text, "Fresh parser"); XCTAssertEqual(restored?.savedAt, date)
        XCTAssertEqual(restored?.parserVersion, LyricsDocument.parserVersion)
        try cache.clearLyrics()
        XCTAssertNil(try cache.read(track: track, source: .qq, settings: settings))
        XCTAssertEqual(try cache.selection(for: "song").offset, 2.5)
        XCTAssertEqual(try cache.selection(for: "song").candidate, candidate)
        try cache.resetSelections()
        XCTAssertNil(try cache.selection(for: "song").candidate); XCTAssertEqual(try cache.selection(for: "song").offset, 2.5)
    }
}
