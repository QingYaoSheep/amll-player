@testable import AMLLPlayer
import Foundation
import XCTest

final class AMLLSourceParityTests: XCTestCase {
    private struct Reference: Decodable {
        struct Trace: Decodable {
            struct Frame: Decodable { var delta: Double; var value: Double }
            var fps: Int
            var frames: [Frame]
        }

        struct Layout: Decodable {
            var children: [AMLLBalancedLayout.Child]
            var width: Double
            var boundaries: [Int]
            var breaks: [Int]
        }

        struct State: Decodable {
            var time: Double
            var seeking: Bool
            var hot: [Int]
            var buffered: [Int]
            var focus: Int
            var layout: Bool
        }

        var traces: [Trace]
        var breaks: [Layout]
        var groups: [AMLLGroupTiming]
        var timeline: [State]
        struct SourceLine: Decodable {
            struct Word: Decodable { var word: String; var startTime: Double; var endTime: Double }
            var startTime: Double
            var endTime: Double
            var words: [Word]
            var isBG: Bool
        }

        var original: [SourceLine]
        var optimized: [SourceLine]
        struct AlphaTrace: Decodable {
            struct Frame: Decodable {
                var delta: Double
                var scale: Double
                var gradient: Bool
                var bright: Double
                var dark: Double
            }

            var fps: Int
            var frames: [Frame]
        }

        var alpha: [AlphaTrace]
        struct Mask: Decodable {
            struct Frame: Decodable { var time: Double; var edge: Double }
            var start: Double
            var end: Double
            var width: Double
            var padding: Double
            var feather: Double
            var frames: [Frame]
        }

        var masks: [Mask]
        struct Emphasis: Decodable {
            struct Input: Decodable {
                var duration: Double
                var delay: Double
                var count: Int
                var rubyCount: Int
                var last: Bool
                var background: Bool
            }

            struct Character: Decodable {
                var delay: Double
                var duration: Double
                var floatDelay: Double
                var floatDuration: Double
                var frames: [AMLLSourceWordAnimation.Keyframe]
            }

            var input: Input
            var characters: [Character]
        }

        var emphasis: [Emphasis]
    }

    private func reference() throws -> Reference {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "amll-motion-reference", withExtension: "json"))
        return try JSONDecoder().decode(Reference.self, from: Data(contentsOf: url))
    }

    func testDelayedInterruptedSpringsMatchEveryOriginalFrame() throws {
        for trace in try reference().traces {
            var spring = AMLLSourceSpring(0)
            spring.updateParameters(.init(mass: 0.9, damping: 15, stiffness: 90))
            spring.setTarget(180, delay: 0.05)
            for (index, frame) in trace.frames.enumerated() {
                if index == 20 {
                    spring.setTarget(-40, delay: 0.025)
                }
                if index == 35 {
                    spring.updateParameters(.init(damping: 25, stiffness: 170))
                }
                spring.update(frame.delta)
                XCTAssertEqual(spring.position, frame.value, accuracy: 0.000_001, "\(trace.fps) Hz frame \(index)")
            }
        }
    }

    func testBalancedBreaksMatchOriginalForFixedGlyphMeasurements() throws {
        for layout in try reference().breaks {
            XCTAssertEqual(AMLLBalancedLayout.breaks(children: layout.children, width: layout.width,
                                                     cjkBoundaries: Set(layout.boundaries)), layout.breaks)
        }
    }

    func testMaskAttackReleaseMatchesEveryOriginalFrame() throws {
        for trace in try reference().alpha {
            var alpha = AMLLMaskAlpha()
            for (index, frame) in trace.frames.enumerated() {
                alpha.update(scale: frame.scale, gradient: frame.gradient, delta: frame.delta)
                XCTAssertEqual(alpha.bright, frame.bright, accuracy: 0.000_001, "\(trace.fps) Hz alpha frame \(index)")
                XCTAssertEqual(alpha.dark, frame.dark, accuracy: 0.000_001, "\(trace.fps) Hz alpha frame \(index)")
            }
        }
    }

    func testConnectedMaskTravelMatchesOriginalKeyframesAndGapHolds() throws {
        let masks = try reference().masks
        let words = masks.map { AMLLWordMask.Word(start: $0.start, end: $0.end, width: $0.width) }
        for (index, mask) in masks.enumerated() {
            for frame in mask.frames {
                let edge = AMLLWordMask.edge(time: frame.time, index: index, words: words, feather: mask.feather)
                // Source clamps the CSS mask to its padded element; the native gradient
                // may extend outside the fragment, with identical visible coverage.
                let clipped = min(mask.width + mask.padding, max(-mask.padding - mask.feather, edge))
                XCTAssertEqual(clipped, frame.edge, accuracy: 0.000_001, "word \(index) at \(frame.time)")
            }
        }
    }

    func testEmphasisKeyframesMatchOriginalIncludingLastWordRubyAndBackgroundTiming() throws {
        for fixture in try reference().emphasis {
            let input = fixture.input
            let characters = AMLLSourceWordAnimation.emphasis(duration: input.duration / 1000, delay: input.delay / 1000,
                                                              characterCount: input.count, rubyCount: input.rubyCount,
                                                              isLastWord: input.last, isBackground: input.background)
            XCTAssertEqual(characters.count, fixture.characters.count)
            for (actual, expected) in zip(characters, fixture.characters) {
                XCTAssertEqual(actual.delay, expected.delay, accuracy: 0.000_001)
                XCTAssertEqual(actual.duration, expected.duration, accuracy: 0.000_001)
                XCTAssertEqual(actual.floatDelay, expected.floatDelay, accuracy: 0.000_001)
                XCTAssertEqual(actual.floatDuration, expected.floatDuration, accuracy: 0.000_001)
                XCTAssertEqual(actual.frames.count, 32)
                for (frame, golden) in zip(actual.frames, expected.frames) {
                    XCTAssertEqual(frame.offset, golden.offset)
                    XCTAssertEqual(frame.scale, golden.scale, accuracy: 0.000_001)
                    XCTAssertEqual(frame.x, golden.x, accuracy: 0.000_001)
                    XCTAssertEqual(frame.y, golden.y, accuracy: 0.000_001)
                    XCTAssertEqual(frame.glowRadius, golden.glowRadius, accuracy: 0.000_001)
                    XCTAssertEqual(frame.glowOpacity, golden.glowOpacity, accuracy: 0.000_001)
                    XCTAssertEqual(frame.floatY, golden.floatY, accuracy: 0.000_001)
                }
            }
        }
    }

    func testOverlapBuffersAndExplicitSeeksMatchOriginalTimeline() throws {
        let fixture = try reference()
        var timeline = AMLLSourceTimeline()
        for frame in fixture.timeline {
            let layout = timeline.update(time: frame.time, groups: fixture.groups, seeking: frame.seeking, hasBottomContent: false)
            XCTAssertEqual(timeline.hot.sorted(), frame.hot)
            XCTAssertEqual(timeline.buffered.sorted(), frame.buffered)
            XCTAssertEqual(timeline.focus, frame.focus)
            XCTAssertEqual(layout, frame.layout)
        }
    }

    func testDisplayOptimizationMatchesSourceWithoutChangingWordTimes() throws {
        let fixture = try reference()
        let input = fixture.original.enumerated().map { index, line in
            LyricLine(id: String(index), text: line.words.map(\.word).joined(), start: line.startTime / 1000,
                      end: line.endTime / 1000, words: line.words.map { .init(text: $0.word, start: $0.startTime / 1000, end: $0.endTime / 1000) },
                      isBackground: line.isBG, precision: .word)
        }
        let display = AMLLDisplayDocument(lines: input)
        for (line, expected) in zip(display.lines, fixture.optimized) {
            XCTAssertEqual(line.start * 1000, expected.startTime, accuracy: 0.000_001)
            XCTAssertEqual(line.end * 1000, expected.endTime, accuracy: 0.000_001)
            XCTAssertEqual(line.isBackground, expected.isBG)
            XCTAssertEqual(line.text, expected.words.map(\.word).joined())
            for (word, expectedWord) in zip(line.words, expected.words) {
                XCTAssertEqual(word.start * 1000, expectedWord.startTime, accuracy: 0.000_001)
                XCTAssertEqual(word.end * 1000, expectedWord.endTime, accuracy: 0.000_001)
            }
        }
        XCTAssertEqual(input[0].text, "a  b")
        XCTAssertEqual(display.groups.count, 4)
        XCTAssertTrue(display.groups[0].backgroundFirst)
    }
}
