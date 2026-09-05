@testable import AMLLPlayer
import XCTest

final class LyricsTimelineTests: XCTestCase {
    private let lines = [
        LyricLine(id: "main", text: "Main", start: 5, end: 10),
        LyricLine(id: "background", text: "Echo", start: 7, end: 9, isBackground: true),
        LyricLine(id: "duet", text: "Reply", start: 8, end: 12, isDuet: true),
        LyricLine(id: "last", text: "Last", start: 18, end: 22),
    ]

    func testIntroAndInterludeUseSilenceAcrossAllVoices() throws {
        let timeline = LyricsTimeline(lines: lines)
        XCTAssertEqual(try XCTUnwrap(timeline.state(position: 2.5, offset: 0, advance: 0).gapProgress), 0.5, accuracy: 0.001)
        XCTAssertNil(timeline.state(position: 10, offset: 0, advance: 0).gapProgress)
        XCTAssertEqual(try XCTUnwrap(timeline.state(position: 15, offset: 0, advance: 0).gapProgress), 0.5, accuracy: 0.001)
        XCTAssertNil(timeline.state(position: 23, offset: 0, advance: 0).gapProgress)
    }

    func testOverlapUsesIndependentHalfOpenIntervalsAndMainVoiceFocus() {
        let timeline = LyricsTimeline(lines: lines)
        XCTAssertEqual(timeline.state(position: 8, offset: 0, advance: 0).active, [0, 1, 2])
        XCTAssertEqual(timeline.state(position: 8, offset: 0, advance: 0).focus, 2)
        XCTAssertEqual(timeline.state(position: 9, offset: 0, advance: 0).active, [0, 2])
        XCTAssertEqual(timeline.state(position: 10, offset: 0, advance: 0).active, [2])
    }

    func testAdvanceMovesFocusWithoutChangingWordTimeOrSeek() {
        let timeline = LyricsTimeline(lines: lines)
        let state = timeline.state(position: 18.8, offset: 1, advance: 0.3)
        XCTAssertEqual(state.time, 17.8, accuracy: 0.001)
        XCTAssertTrue(state.active.isEmpty)
        XCTAssertEqual(state.focus, 3)
        XCTAssertEqual(LyricsTimeline.progress(time: state.time, start: 18, end: 20), 0)
        XCTAssertEqual(LyricsTimeline.seekTarget(line: lines[3], offset: 1, duration: 30), 19)
        XCTAssertEqual(LyricsTimeline.seekTarget(line: lines[0], offset: -10, duration: 30), 0)
    }

    func testBackwardSeekRecomputesCurrentLineAndWordFill() {
        let timeline = LyricsTimeline(lines: lines)
        XCTAssertEqual(timeline.state(position: 20, offset: 0, advance: 0).active, [3])
        let back = timeline.state(position: 6, offset: 0, advance: 0)
        XCTAssertEqual(back.active, [0])
        XCTAssertEqual(LyricsTimeline.progress(time: back.time, start: 5, end: 10), 0.2, accuracy: 0.001)
    }

    func testOverlappingVoiceDoesNotJumpBackAfterAdvanceWindow() {
        let timeline = LyricsTimeline(lines: lines)
        for time in [7.8, 8.0, 8.2, 9.0, 10.0] {
            XCTAssertEqual(timeline.state(position: time, offset: 0, advance: 0.3).focus, 2)
        }
    }

    func testLongNoteZeroDurationAndCompletedWord() {
        XCTAssertEqual(LyricsTimeline.progress(time: 15, start: 5, end: 25), 0.5)
        XCTAssertEqual(LyricsTimeline.progress(time: 25, start: 5, end: 25), 1)
        XCTAssertEqual(LyricsTimeline.progress(time: 5, start: 5, end: 5), 1)
        XCTAssertEqual(LyricsTimeline.progress(time: .nan, start: 5, end: 25), 0)
    }

    func testEmptyAndMalformedInputNeverBuildInvalidRanges() {
        XCTAssertNil(LyricsTimeline(lines: []).state(position: 1, offset: 0, advance: 0).focus)
        let malformed = LyricsTimeline(lines: [LyricLine(id: "bad", text: "Bad", start: .nan, end: 1)] + lines)
        XCTAssertEqual(malformed.lines.count, 4)
        XCTAssertTrue(malformed.state(position: .nan, offset: .infinity, advance: -10).time.isFinite)
    }

    func testAccessibilityContainsCurrentAndAdjacentContext() {
        let timeline = LyricsTimeline(lines: lines)
        let snapshot = timeline.accessibility(timeline.state(position: 10, offset: 0, advance: 0), canSeek: false)
        XCTAssertEqual(snapshot.current, ["Reply"])
        XCTAssertEqual(snapshot.previous, "Echo")
        XCTAssertEqual(snapshot.next, "Last")
        XCTAssertFalse(snapshot.canSeek)
    }

    func testBrowsingResumeAndPausedSpringSettleWithoutSeeking() {
        var follow = LyricsFollowState()
        follow.position = 800
        follow.browse()
        XCTAssertEqual(follow.step(target: 100, dt: 1 / 60, immediate: false), 800)
        follow.resume()
        XCTAssertFalse(follow.isSettled(at: 100))
        for _ in 0 ..< 180 {
            _ = follow.step(target: 100, dt: 1 / 60, immediate: false)
        }
        XCTAssertTrue(follow.isSettled(at: 100))
        XCTAssertEqual(follow.step(target: 600, dt: 1, immediate: true), 600)
        follow.reset()
        XCTAssertTrue(follow.following)
        XCTAssertEqual(follow.position, 0)
    }

    func testSpringRetargetAndDroppedFrameRemainFinite() {
        var follow = LyricsFollowState()
        _ = follow.step(target: 1000, dt: 1 / 120, immediate: false)
        let velocity = follow.velocity
        _ = follow.step(target: 700, dt: 1 / 120, immediate: false)
        XCTAssertGreaterThan(follow.velocity, velocity)
        _ = follow.step(target: -100, dt: 5, immediate: false)
        XCTAssertTrue(follow.position.isFinite)
        XCTAssertTrue(follow.velocity.isFinite)
    }
}
