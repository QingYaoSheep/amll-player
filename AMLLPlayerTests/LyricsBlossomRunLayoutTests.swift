@testable import AMLLPlayer
import XCTest

final class LyricsBlossomRunLayoutTests: XCTestCase {
    func testRecordKeepsTimedSyllablesAndDoesNotSplitHyphens() {
        let model = LyricsBlossomRunLayout(text: "talking L-O-V-E", pieces: [
            .init(range: NSRange(location: 0, length: 3), width: 30, start: 1, end: 2),
            .init(range: NSRange(location: 3, length: 4), width: 40, start: 2, end: 3),
            .init(range: NSRange(location: 8, length: 7), width: 70, start: 4, end: 5, group: 1),
        ], pixelsPerPoint: 1)
        XCTAssertEqual(model.recordCount, 2)
        let sample = model.sample(time: 1.5)
        let first = model.edge(for: NSRange(location: 0, length: 3), sample: sample)!
        let second = model.edge(for: NSRange(location: 3, length: 4), sample: sample)!
        XCTAssertEqual(first - second, 30, accuracy: 0.0001)
        XCTAssertLessThan(model.edge(for: NSRange(location: 8, length: 7), sample: sample)!, 0)
    }

    func testPixelWindowConvertsOnceForRetinaAndHDRUsesSameSample() {
        for scale in [1.0, 2, 3] {
            let model = LyricsBlossomRunLayout(text: "word", pieces: [
                .init(range: NSRange(location: 0, length: 4), width: 100 / scale, start: 0, end: 2),
            ], pixelsPerPoint: scale)
            let sample = model.sample(time: 1)
            XCTAssertEqual(sample.feather * scale, 30, accuracy: 0.0001)
            // Native exact-time reconstruction: target at 1s =65; window starts at33.
            XCTAssertEqual(model.edge(for: NSRange(location: 0, length: 4), sample: sample)! * scale,
                           33, accuracy: 0.0001)
        }
    }

    func testAbsoluteClockMakesPauseSeekRecycleAndFrameRatesDeterministic() {
        let model = LyricsBlossomRunLayout(text: "tail", pieces: [
            .init(range: NSRange(location: 0, length: 4), width: 100, start: 1, end: 6),
        ], pixelsPerPoint: 1)
        let range = NSRange(location: 0, length: 4)
        let expected = model.edge(for: range, sample: model.sample(time: 3))!
        for dt in [1.0 / 60, 1.0 / 120, 0.037] {
            for time in stride(from: 0.0, through: 8, by: dt) { _ = model.sample(time: time) }
            XCTAssertEqual(model.edge(for: range, sample: model.sample(time: 3)), expected)
            XCTAssertEqual(model.edge(for: range, sample: model.sample(time: 3)), expected)
        }
        XCTAssertEqual(model.edge(for: range, sample: model.sample(time: 0)), -32)
        // No last-word -0.9s shortcut. A long final word is still filling.
        XCTAssertLessThan(model.edge(for: range, sample: model.sample(time: 5.2))!, 100)
    }

    func testWhitespaceUnicodeAndSharedProviderTiming() {
        let text = "你好吗\u{00a0}مرحبا\t🙂"
        let ns = text as NSString
        let ranges = [ns.range(of: "你好吗"), ns.range(of: "مرحبا"), ns.range(of: "🙂")]
        let model = LyricsBlossomRunLayout(text: text, pieces: ranges.enumerated().map { index, range in
            .init(range: range, width: 60, start: 2, end: 4, group: index)
        }, pixelsPerPoint: 1)
        XCTAssertEqual(model.recordCount, 3)
        for range in ranges {
            XCTAssertLessThan(model.edge(for: range, sample: model.sample(time: 1))!, 0)
            XCTAssertEqual(model.edge(for: range, sample: model.sample(time: 3)),
                           model.edge(for: ranges[0], sample: model.sample(time: 3)))
        }
    }

    func testFragmentCannotBorrowAnotherRecordsClock() {
        let model = LyricsBlossomRunLayout(text: "a b", pieces: [
            .init(range: NSRange(location: 0, length: 1), width: 10, start: 0, end: 1),
            .init(range: NSRange(location: 2, length: 1), width: 10, start: 4, end: 5, group: 1),
        ], pixelsPerPoint: 1, fragmentRanges: [NSRange(location: 0, length: 3)])
        XCTAssertNil(model.edge(for: NSRange(location: 0, length: 3), sample: model.sample(time: 2)))
    }

    func testScaleWaitDoesNotRestartAndConsumesRemainder() {
        var spring = LyricsAnimationSpring(100)
        spring.selectStyle(.appleMusic164)
        var wait: LyricsBlossomScaleWait?
        LyricsBlossomScaleWait.retarget(&spring, pending: &wait, target: 98, at: 0, delay: 0.05)
        LyricsBlossomScaleWait.retarget(&spring, pending: &wait, target: 98, at: 0.04, delay: 0.05)
        XCTAssertEqual(wait?.start, 0.05)
        LyricsBlossomScaleWait.advance(&spring, pending: &wait, delta: 0.08, endingAt: 0.08)
        XCTAssertNil(wait)
        var direct = LyricsAnimationSpring(100)
        direct.selectStyle(.appleMusic164)
        direct.setTarget(98); direct.update(0.03)
        XCTAssertEqual(spring.position, direct.position, accuracy: 1e-10)
        XCTAssertEqual(spring.velocity, direct.velocity, accuracy: 1e-10)
    }

    func testAdvanceOrPauseClearsOnlyScaleWaitWithoutSnapping() {
        var spring = LyricsAnimationSpring(100)
        spring.selectStyle(.appleMusic164)
        var wait: LyricsBlossomScaleWait?
        LyricsBlossomScaleWait.retarget(&spring, pending: &wait, target: 98, at: 0, delay: 0.5)
        LyricsBlossomScaleWait.retarget(&spring, pending: &wait, target: 98, at: 0.1, delay: 0)
        XCTAssertNil(wait)
        XCTAssertEqual(spring.position, 100)
        XCTAssertEqual(spring.target, 98)
    }
}
