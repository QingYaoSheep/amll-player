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
        XCTAssertNil(state.translation)
        XCTAssertNil(state.romanization)
    }

    func testUsesCurrentTranslationAndGeneratedProviderOrWordRomanization() {
        var state = State(track: 1, title: "Song", status: .playing)
        let timeline = fixture()
        _ = timeline.update(&state, position: 1.1, offset: 0)
        XCTAssertEqual(state.translation, "译文一")
        XCTAssertEqual(state.romanization, "Provider first")
        _ = timeline.update(&state, position: 5.1, offset: 0)
        XCTAssertEqual(state.translation, "译文二")
        XCTAssertEqual(state.romanization, "Generated second")
        _ = timeline.update(&state, position: 16.0, offset: 0)
        XCTAssertNil(state.translation)
        XCTAssertEqual(state.romanization, "Word fallback")
    }

    func testAuxiliaryTogglesAreIndependentAndFollowTheFrozenLine() {
        let timeline = fixture()
        var playing = State(track: 1, title: "Song", status: .playing)
        _ = timeline.update(&playing, position: 5.2, offset: 0)
        LockScreenLyricsState.applyAuxiliaryPreferences(&playing, translation: true, romanization: false)
        XCTAssertEqual(playing.translation, "译文二")
        XCTAssertNil(playing.romanization)

        var frozen = State(track: 1, title: "Song", status: .loading)
        _ = LockScreenLyricsState.project(&frozen, timeline: timeline, position: 16, offset: 0,
                                          playing: true, trusted: false, previous: playing)
        LockScreenLyricsState.applyAuxiliaryPreferences(&frozen, translation: false, romanization: true)
        XCTAssertEqual(frozen.current?.id, playing.current?.id)
        XCTAssertNil(frozen.translation)
        XCTAssertEqual(frozen.romanization, "Generated second")
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
                          backdrop: Data(repeating: 0, count: 4096), translation: long, romanization: long)
        let fitted = LockScreenLyricsState.fitted(state)
        XCTAssertLessThan(try JSONEncoder().encode(fitted).count, 4_096)
        XCTAssertEqual(fitted.rows.map(\.id), [2, 3, 4])
        XCTAssertTrue(fitted.current?.text.hasPrefix("👩🏽‍🎤") == true)
        XCTAssertTrue(fitted.translation?.hasPrefix("👩🏽‍🎤") == true)
        XCTAssertTrue(fitted.romanization?.hasPrefix("👩🏽‍🎤") == true)
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

    func testSilentWAVDataProducesValidZeroedOneSecondPCM() {
        let wav = SilentWAVData.makeOneSecondPCM()
        XCTAssertEqual(wav.count, 44 + 88_200)
        XCTAssertEqual(String(decoding: wav[0 ..< 4], as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: wav[8 ..< 16], as: UTF8.self), "WAVEfmt ")
        XCTAssertEqual(String(decoding: wav[36 ..< 40], as: UTF8.self), "data")
        XCTAssertTrue(wav.dropFirst(44).allSatisfy { $0 == 0 })
    }

    @MainActor
    func testBackgroundKeepAliveFollowsServiceForegroundAndDismissalRules() {
        let driver = FakeSilentAudioDriver()
        let keepAlive = LockScreenBackgroundKeepAlive(driver: driver, idleTimeout: .seconds(180))

        // Ignores NetEase (owns real audio) and stays off when disabled or missing activity.
        keepAlive.synchronize(.init(lockScreenEnabled: true, keepAliveEnabled: true, hasActiveActivity: true,
                                    isForeground: false, isTransitioningOut: false, service: .netease, isPlaying: true))
        XCTAssertFalse(keepAlive.isRunning)
        keepAlive.synchronize(.init(lockScreenEnabled: true, keepAliveEnabled: false, hasActiveActivity: true,
                                    isForeground: false, isTransitioningOut: false, service: .appleMusic, isPlaying: true))
        XCTAssertFalse(keepAlive.isRunning)
        keepAlive.synchronize(.init(lockScreenEnabled: true, keepAliveEnabled: true, hasActiveActivity: false,
                                    isForeground: false, isTransitioningOut: false, service: .spotify, isPlaying: true))
        XCTAssertFalse(keepAlive.isRunning)
        XCTAssertEqual(driver.startCount, 0)

        // Pre-arms during .inactive transition when playing Apple Music with an active Live Activity.
        keepAlive.synchronize(.init(lockScreenEnabled: true, keepAliveEnabled: true, hasActiveActivity: true,
                                    isForeground: true, isTransitioningOut: true, service: .appleMusic, isPlaying: true))
        XCTAssertTrue(keepAlive.isRunning)
        XCTAssertEqual(driver.startCount, 1)

        // Remains running on transition into .background and switches cleanly to Spotify if active.
        keepAlive.synchronize(.init(lockScreenEnabled: true, keepAliveEnabled: true, hasActiveActivity: true,
                                    isForeground: false, isTransitioningOut: false, service: .appleMusic, isPlaying: true))
        XCTAssertTrue(keepAlive.isRunning)
        XCTAssertEqual(driver.startCount, 1)

        // Returning to foreground stops silent playback immediately.
        keepAlive.synchronize(.init(lockScreenEnabled: true, keepAliveEnabled: true, hasActiveActivity: true,
                                    isForeground: true, isTransitioningOut: false, service: .appleMusic, isPlaying: true))
        XCTAssertFalse(keepAlive.isRunning)
        XCTAssertEqual(driver.stopCount, 1)

        // Starts in background for Spotify when playing, and stops immediately when dismissed.
        keepAlive.synchronize(.init(lockScreenEnabled: true, keepAliveEnabled: true, hasActiveActivity: true,
                                    isForeground: false, isTransitioningOut: false, service: .spotify, isPlaying: true))
        XCTAssertTrue(keepAlive.isRunning)
        XCTAssertEqual(driver.startCount, 2)
        keepAlive.synchronize(.init(lockScreenEnabled: true, keepAliveEnabled: true, hasActiveActivity: false,
                                    isForeground: false, isTransitioningOut: false, service: .spotify, isPlaying: true))
        XCTAssertFalse(keepAlive.isRunning)
        XCTAssertEqual(driver.stopCount, 2)
    }

    @MainActor
    func testBackgroundKeepAlivePauseGraceCancelsOnResumeAndSleepsOnTimeout() async throws {
        let driver = FakeSilentAudioDriver()
        let keepAlive = LockScreenBackgroundKeepAlive(driver: driver, idleTimeout: .milliseconds(80))
        var idleSleepCount = 0
        keepAlive.onIdleSleep = { idleSleepCount += 1 }

        let playing = LockScreenKeepAliveContext(lockScreenEnabled: true, keepAliveEnabled: true,
                                                 hasActiveActivity: true, isForeground: false,
                                                 isTransitioningOut: false, service: .appleMusic, isPlaying: true)
        var paused = playing
        paused.isPlaying = false

        keepAlive.synchronize(playing)
        XCTAssertTrue(keepAlive.isRunning)
        XCTAssertFalse(keepAlive.isWaitingIdleSleep)

        // Pausing enters grace window without immediately cutting silent audio.
        keepAlive.synchronize(paused)
        XCTAssertTrue(keepAlive.isRunning)
        XCTAssertTrue(keepAlive.isWaitingIdleSleep)

        // Resuming within grace period cancels the sleep timer.
        try await Task.sleep(for: .milliseconds(30))
        keepAlive.synchronize(playing)
        XCTAssertTrue(keepAlive.isRunning)
        XCTAssertFalse(keepAlive.isWaitingIdleSleep)
        try await Task.sleep(for: .milliseconds(70))
        XCTAssertTrue(keepAlive.isRunning)
        XCTAssertEqual(idleSleepCount, 0)

        // Pausing beyond the timeout releases the audio session and invokes onIdleSleep.
        keepAlive.synchronize(paused)
        XCTAssertTrue(keepAlive.isWaitingIdleSleep)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(keepAlive.isRunning)
        XCTAssertFalse(keepAlive.isWaitingIdleSleep)
        XCTAssertEqual(driver.stopCount, 1)
        XCTAssertEqual(idleSleepCount, 1)
    }

    private func fixture() -> LockScreenLyricsTimeline {
        let lines = [
            LyricLine(id: "1", text: "First\nline", start: 1, end: 4, translation: "译文一", romanization: "Provider first"),
            LyricLine(id: "background", text: "Background", start: 3, end: 4, isBackground: true),
            LyricLine(id: "2", text: "Second line", start: 5, end: 6, translation: "译文二", romanization: "Provider second"),
            LyricLine(id: "3", text: "Third line", start: 15, end: 19,
                      words: [.init(text: "Third line", start: 15, end: 19, romanWord: "Word fallback")]),
        ]
        let generated = LyricLine(id: "romanized", text: "Generated second", start: 5, end: 6)
        return .init(document: .init(candidate: .init(source: .qq, sourceID: "test", title: "Song", artists: []),
                                     lines: lines, language: "en", selectionReason: "fixture",
                                     romanizationTTMLTrack: .init(ttml: "", cues: [.init(sourceLineIndex: 2, line: generated, tokens: [])])))
    }
}

@MainActor
private final class FakeSilentAudioDriver: SilentAudioKeepAliveDriving {
    private(set) var isPlaying = false
    private(set) var startCount = 0
    private(set) var stopCount = 0

    func start() -> Bool {
        startCount += 1
        isPlaying = true
        return true
    }

    func stop() {
        stopCount += 1
        isPlaying = false
    }
}
