@testable import AMLLPlayer
import XCTest

final class AMLLLayoutCalibrationTests: XCTestCase {
    func testCalibrationChangesBreakDecisionAndPreservesText() {
        let children = [AMLLBalancedLayout.Child(text: "AV", width: 30, isSpace: false),
                        .init(text: " ", width: 5, isSpace: true),
                        .init(text: "office", width: 65, isSpace: false)]
        let calibrated = AMLLBalancedLayout.calibrated(children, visualWidth: 80)
        XCTAssertEqual(calibrated.map(\.text), children.map(\.text))
        XCTAssertEqual(calibrated.map(\.isSpace), children.map(\.isSpace))
        XCTAssertEqual(calibrated.reduce(0) { $0 + $1.width }, 80, accuracy: 1e-9)
        XCTAssertFalse(AMLLBalancedLayout.breaks(children: children, width: 90, cjkBoundaries: []).isEmpty)
        XCTAssertTrue(AMLLBalancedLayout.breaks(children: calibrated, width: 90, cjkBoundaries: []).isEmpty)
        XCTAssertEqual(AMLLBalancedLayout.calibrated(children, visualWidth: .nan), children)
        XCTAssertTrue(AMLLBalancedLayout.calibrated([], visualWidth: 20).isEmpty)
    }
}
