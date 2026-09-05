@testable import AMLLPlayer
import XCTest

@MainActor
final class LyricsRenderPreferencesTests: XCTestCase {
    func testSettingsSurviveRelaunchAndReset() throws {
        let name = "render-tests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = LyricsRenderPreferences(defaults: defaults)
        preferences.configuration.fontSize = 40
        preferences.configuration.translation = false
        preferences.configuration.remainingTime = true
        let restored = LyricsRenderPreferences(defaults: defaults)
        XCTAssertEqual(restored.configuration.fontSize, 40)
        XCTAssertFalse(restored.configuration.translation)
        XCTAssertTrue(restored.configuration.remainingTime)
        restored.configuration = .init()
        XCTAssertEqual(LyricsRenderPreferences(defaults: defaults).configuration, .init())
    }

    func testLegacyPartialSettingsGainNewDefaultsAndClampRanges() throws {
        let name = "render-tests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(Data(#"{"fontSize":999,"translation":false,"backgroundBlur":-4}"#.utf8), forKey: "lyrics.render.v1")
        let value = LyricsRenderPreferences(defaults: defaults).configuration
        XCTAssertEqual(value.fontSize, 52)
        XCTAssertEqual(value.backgroundBlur, 0)
        XCTAssertFalse(value.translation)
        XCTAssertTrue(value.romanization)
        XCTAssertFalse(value.remainingTime)
    }

    func testCorruptAndFutureVersionSettingsFallBackWithoutDeletingData() throws {
        let name = "render-tests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        for raw in ["invalid", #"{"version":99,"configuration":{"fontSize":40}}"#] {
            let data = Data(raw.utf8)
            defaults.set(data, forKey: "lyrics.render.v1")
            XCTAssertEqual(LyricsRenderPreferences(defaults: defaults).configuration, .init())
            XCTAssertEqual(defaults.data(forKey: "lyrics.render.v1"), data)
        }
    }

    func testCreditModesSelectTypesAndOnlyPreferredModesFallBack() {
        var document = LyricsDocument(candidate: .init(source: .apple, sourceID: "test", title: "Test", artists: []),
                                      lines: [], language: "", selectionReason: "", lyricAuthor: "Transcriber", songwriters: ["Composer"])
        typealias Mode = LyricsRenderConfiguration.Credits
        XCTAssertNil(Mode.hidden.content(in: document))
        XCTAssertEqual(Mode.lyricAuthor.content(in: document)?.names, ["Transcriber"])
        XCTAssertEqual(Mode.preferSongwriters.content(in: document)?.names, ["Composer"])
        document.songwriters = [" "]
        XCTAssertNil(Mode.songwriters.content(in: document))
        XCTAssertEqual(Mode.preferSongwriters.content(in: document)?.kind, .lyricAuthor)
        document.lyricAuthor = nil
        XCTAssertNil(Mode.preferLyricAuthor.content(in: document))
        document.songwriters = ["Composer"]
        XCTAssertEqual(Mode.preferLyricAuthor.content(in: document)?.kind, .songwriters)
    }

    func testReducedMotionDoesNotAlterUserBackgroundBlur() {
        let regular = RenderQualityPolicy.resolve(maximumFPS: 120, reduceMotion: false)
        XCTAssertEqual(regular.frameRate, 120)
        let reduced = RenderQualityPolicy.resolve(maximumFPS: 120, reduceMotion: true)
        XCTAssertFalse(reduced.emphasis)
        XCTAssertFalse(reduced.blur)
        var configuration = LyricsRenderConfiguration()
        configuration.backgroundBlur = 75
        XCTAssertEqual(configuration.validated().backgroundBlur, 75)
    }
}
