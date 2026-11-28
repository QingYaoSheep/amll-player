@testable import AMLLPlayer
import XCTest

final class TrackSwipeGestureTests: XCTestCase {
    func testHorizontalLockRejectsVerticalAndSmallGestures() {
        XCTAssertFalse(TrackSwipeMath.isHorizontalLock(translation: CGSize(width: 8, height: 0)))
        XCTAssertFalse(TrackSwipeMath.isHorizontalLock(translation: CGSize(width: 20, height: 20)))
        XCTAssertFalse(TrackSwipeMath.isHorizontalLock(translation: CGSize(width: -16, height: 15)))
        XCTAssertTrue(TrackSwipeMath.isHorizontalLock(translation: CGSize(width: -20, height: 4)))
        XCTAssertTrue(TrackSwipeMath.isHorizontalLock(translation: CGSize(width: 24, height: -8)))
    }

    func testDampedOffsetRespectsPermittedAndRestrictedCaps() {
        XCTAssertEqual(TrackSwipeMath.dampedOffset(for: 0, canSkipNext: true, canSkipPrevious: true), 0)

        let leftAllowed = TrackSwipeMath.dampedOffset(for: -500, canSkipNext: true, canSkipPrevious: true)
        XCTAssertLessThan(leftAllowed, 0)
        XCTAssertGreaterThanOrEqual(leftAllowed, -TrackSwipeMath.permittedMaxOffset)

        let leftRestricted = TrackSwipeMath.dampedOffset(for: -500, canSkipNext: false, canSkipPrevious: true)
        XCTAssertLessThan(leftRestricted, 0)
        XCTAssertGreaterThanOrEqual(leftRestricted, -TrackSwipeMath.restrictedMaxOffset)

        let rightAllowed = TrackSwipeMath.dampedOffset(for: 500, canSkipNext: true, canSkipPrevious: true)
        XCTAssertGreaterThan(rightAllowed, 0)
        XCTAssertLessThanOrEqual(rightAllowed, TrackSwipeMath.permittedMaxOffset)

        let rightRestricted = TrackSwipeMath.dampedOffset(for: 500, canSkipNext: true, canSkipPrevious: false)
        XCTAssertGreaterThan(rightRestricted, 0)
        XCTAssertLessThanOrEqual(rightRestricted, TrackSwipeMath.restrictedMaxOffset)
    }

    func testResolvedActionHonorsThresholdsAndRestrictions() {
        XCTAssertNil(TrackSwipeMath.resolvedAction(translationX: -24, predictedX: -40, canSkipNext: true, canSkipPrevious: true))
        XCTAssertEqual(
            TrackSwipeMath.resolvedAction(translationX: -60, predictedX: -60, canSkipNext: true, canSkipPrevious: true),
            .next
        )
        XCTAssertEqual(
            TrackSwipeMath.resolvedAction(translationX: -20, predictedX: -110, canSkipNext: true, canSkipPrevious: true),
            .next
        )
        XCTAssertNil(
            TrackSwipeMath.resolvedAction(translationX: -80, predictedX: -120, canSkipNext: false, canSkipPrevious: true)
        )

        XCTAssertEqual(
            TrackSwipeMath.resolvedAction(translationX: 60, predictedX: 60, canSkipNext: true, canSkipPrevious: true),
            .previous
        )
        XCTAssertEqual(
            TrackSwipeMath.resolvedAction(translationX: 20, predictedX: 110, canSkipNext: true, canSkipPrevious: true),
            .previous
        )
        XCTAssertNil(
            TrackSwipeMath.resolvedAction(translationX: 80, predictedX: 120, canSkipNext: true, canSkipPrevious: false)
        )
    }
}
