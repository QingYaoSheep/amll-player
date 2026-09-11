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
}
