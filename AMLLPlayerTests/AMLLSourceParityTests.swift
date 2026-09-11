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
