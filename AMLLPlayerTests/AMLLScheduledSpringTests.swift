@testable import AMLLPlayer
import XCTest

final class AMLLScheduledSpringTests: XCTestCase {
    func testRepeatedTargetDoesNotPostponeTheOriginalDeadline() {
        var spring = AMLLScheduledSpring()
        spring.setTarget(100, startTime: 0.2, at: 0, revision: 1)
        spring.advance(to: 0.1)
        spring.setTarget(100, startTime: 0.6, at: 0.1, revision: 2)
        XCTAssertEqual(spring.schedule.scheduledAt, 0.2)
        XCTAssertEqual(spring.schedule.revision, 1)
        spring.advance(to: 0.3)
        XCTAssertGreaterThan(spring.position, 0)
        XCTAssertEqual(spring.schedule.startedAt, 0.2)
    }

    func testDirectPositionCancelsQueuedTargetAndKeepsItsPosition() {
        var spring = AMLLScheduledSpring()
        spring.setTarget(100, startTime: 0.2, at: 0, revision: 1)
        spring.setPosition(40, at: 0.1)
        spring.advance(to: 1)
        XCTAssertEqual(spring.position, 40)
        XCTAssertNil(spring.schedule.scheduledAt)
        XCTAssertNil(spring.schedule.startedAt)
        XCTAssertTrue(spring.arrived)
    }

    func testFrameCrossingDeadlineConsumesTheRemainingTime() {
        var reference = AMLLSourceSpring()
        reference.setTarget(100)
        reference.update(0.15)
        for frames in [[0.35], [0.1, 0.2, 0.35], (1 ... 42).map { Double($0) / 120 }] {
            var spring = AMLLScheduledSpring()
            spring.setTarget(100, startTime: 0.2, at: 0, revision: 1)
            for time in frames {
                spring.advance(to: time)
            }
            XCTAssertEqual(spring.position, reference.position, accuracy: 0.000_001)
            XCTAssertEqual(spring.schedule.startedAt, 0.2)
        }
    }

    func testMovingRowRetargetsWithoutAnotherDelay() {
        var spring = AMLLScheduledSpring()
        spring.setTarget(100, startTime: 0, at: 0, revision: 1)
        spring.advance(to: 0.1)
        let moving = spring.position
        spring.setTarget(200, startTime: 0.7, at: 0.1, revision: 2)
        XCTAssertEqual(spring.schedule.startedAt, 0.1)
        spring.advance(to: 0.2)
        XCTAssertGreaterThan(spring.position, moving)
    }

    func testChangedQueuedTargetKeepsEarlierDeadlineAndParameterUpdatesDoNotCancelIt() {
        var spring = AMLLScheduledSpring()
        spring.setTarget(100, startTime: 0.2, at: 0, revision: 1)
        spring.setTarget(200, startTime: 0.7, at: 0.1, revision: 2)
        spring.updateParameters(.init(mass: 0.9, damping: 15, stiffness: 90))
        spring.advance(to: 0.3)
        XCTAssertEqual(spring.schedule.startedAt, 0.2)
        XCTAssertEqual(spring.target, 200)
        XCTAssertGreaterThan(spring.position, 0)
    }
}
