@testable import AMLLPlayer
import XCTest

final class LockScreenLyricsTests: XCTestCase {
    typealias State = LockScreenLyricsAttributes.ContentState

    func testContextUsesOriginalLineIdentityAndEffectiveOffset() {
        let timeline = fixture()
        var state = State(track: 1, title: "Song", status: .playing)

        XCTAssertEqual(timeline.update(&state, position: 1.49, offset: 0.5), 1.5)
        XCTAssertNil(state.current)
        XCTAssertEqual(state.next?.text, "First line")

        XCTAssertEqual(timeline.update(&state, position: 5.5, offset: 0.5), 6.5)
        XCTAssertEqual(state.rows.map(\.text), ["First line", "Second line", "Third line"])
        XCTAssertEqual(state.rows.map(\.id), [0, 2, 3])
    }

    func testInterludeShowsContextWithoutHighlightingFinishedLyrics() {
        var state = State(track: 1, title: "Song", status: .playing)
        XCTAssertEqual(fixture().update(&state, position: 11, offset: 0), 15)
        XCTAssertEqual(state.previous?.text, "Second line")
        XCTAssertNil(state.current)
        XCTAssertEqual(state.next?.text, "Third line")
    }

    func testNormalHandoffScrollsButConfirmedJumpsSnapInEitherDirection() {
        let timeline = fixture()
        var first = State(track: 1, title: "Song", status: .playing)
        _ = timeline.update(&first, position: 2, offset: 0)
        var second = first
        _ = timeline.update(&second, position: 5.5, offset: 0)
        var third = second
        _ = timeline.update(&third, position: 16, offset: 0)
        XCTAssertTrue(LockScreenLyricsState.isForward(first, second, discontinuity: false))
        XCTAssertFalse(LockScreenLyricsState.isForward(first, second, discontinuity: true))
        XCTAssertFalse(LockScreenLyricsState.isForward(first, third, discontinuity: false))
        XCTAssertFalse(LockScreenLyricsState.isForward(third, first, discontinuity: true))
    }

    func testPauseResumesAtRealPositionAndLateSamplesCannotReusePreviousTrackLyrics() {
        let timeline = fixture()
        var paused = State(track: 1, title: "Song", status: .loading)
        _ = LockScreenLyricsState.project(&paused, timeline: timeline, position: 5.5, offset: 0,
                                          playing: false, trusted: true, previous: nil)
        XCTAssertEqual(paused.status, .paused)
        XCTAssertEqual(paused.rows.count, 3)

        var stale = State(track: 1, title: "Song", status: .loading)
        _ = LockScreenLyricsState.project(&stale, timeline: timeline, position: 16, offset: 0,
                                          playing: true, trusted: false, previous: paused)
        XCTAssertEqual(stale.status, .outOfSync)
        XCTAssertEqual(stale.rows, paused.rows)

        let frozen = stale
        _ = LockScreenLyricsState.project(&stale, timeline: timeline, position: 16, offset: 0,
                                          playing: true, trusted: true, previous: frozen)
        XCTAssertEqual(stale.status, .playing)
        XCTAssertEqual(stale.current?.text, "Third line")

        var next = State(track: 2, title: "New song", status: .loading)
        _ = LockScreenLyricsState.project(&next, timeline: nil, position: 0, offset: 0,
                                          playing: true, trusted: true, previous: paused)
        XCTAssertEqual(next.status, .loading)
        _ = LockScreenLyricsState.project(&next, timeline: nil, position: 0, offset: 0,
                                          playing: true, trusted: false, previous: paused)
        XCTAssertTrue(next.rows.isEmpty)
        XCTAssertNil(next.backdrop)
    }

    func testRequiresFreshSourceSamplesAfterBackgrounding() {
        let apple = PlaybackSnapshot.empty(source: .musicKit, sampledAtUptime: 100)
        let spotify = PlaybackSnapshot.empty(source: .webAPI, sampledAtUptime: 100)
        let netease = PlaybackSnapshot.empty(source: .nativeAudio, sampledAtUptime: 100)
        XCTAssertTrue(LockScreenLyricsState.canFollow(apple, externalSampleAfter: nil, uptime: 101))
        XCTAssertFalse(LockScreenLyricsState.canFollow(apple, externalSampleAfter: 100.1, uptime: 101))
        XCTAssertFalse(LockScreenLyricsState.canFollow(spotify, externalSampleAfter: nil, uptime: 109))
        XCTAssertTrue(LockScreenLyricsState.canFollow(spotify, externalSampleAfter: 99, uptime: 104))
        XCTAssertTrue(LockScreenLyricsState.canFollow(netease, externalSampleAfter: 100.1, uptime: 101))
        XCTAssertFalse(LockScreenLyricsState.canFollow(netease, externalSampleAfter: nil, uptime: 103))
    }

    func testPayloadRemainsBelowActivityKitLimitAndKeepsLyricsAheadOfArtwork() throws {
        let long = String(repeating: "👩🏽‍🎤\u{0001}\"", count: 800)
        let state = State(track: 4, title: long,
                          previous: .init(id: 2, text: long), current: .init(id: 3, text: long),
                          next: .init(id: 4, text: long), status: .playing,
                          backdrop: Data(repeating: 0, count: 4096))
        let fitted = LockScreenLyricsState.fitted(state)
        XCTAssertLessThan(try JSONEncoder().encode(fitted).count, 4_096)
        XCTAssertEqual(fitted.rows.map(\.id), [2, 3, 4])
        XCTAssertTrue(fitted.current?.text.hasPrefix("👩🏽‍🎤") == true)
        XCTAssertNil(fitted.backdrop)
    }

    func testDismissalPersistsThroughSongChangesAndGatesActivityStarts() {
        var session = LockScreenLyricsSession()
        XCTAssertFalse(session.canStart(foreground: false, playing: true, synchronized: true))
        XCTAssertFalse(session.canStart(foreground: true, playing: false, synchronized: true))
        XCTAssertFalse(session.canStart(foreground: true, playing: true, synchronized: false))
        session.dismiss()
        XCTAssertFalse(session.canStart(foreground: true, playing: true, synchronized: true))
        session.ended()
        XCTAssertTrue(session.canStart(foreground: true, playing: true, synchronized: true))
    }

    private func fixture() -> LockScreenLyricsTimeline {
        let lines = [
            LyricLine(id: "1", text: "First\nline", start: 1, end: 4),
            LyricLine(id: "background", text: "Background", start: 3, end: 4, isBackground: true),
            LyricLine(id: "2", text: "Second line", start: 5, end: 6),
            LyricLine(id: "3", text: "Third line", start: 15, end: 19),
        ]
        return .init(document: .init(candidate: .init(source: .qq, sourceID: "test", title: "Song", artists: []),
                                     lines: lines, language: "en", selectionReason: "fixture"))
    }
}
