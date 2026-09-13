@testable import AMLLPlayer
import UIKit
import XCTest

final class AMLLMarqueeMotionTests: XCTestCase {
    @MainActor
    func testRealLabelUsesSourceTrajectoryAndClearsOnDisable() throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
        let controller = UIViewController()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let view = AMLLMetadataText.Label(frame: CGRect(x: 0, y: 0, width: 100, height: 30))
        controller.view.addSubview(view)
        let text = "A long title that needs to move"
        view.configure(text: text, size: 17, bold: true, enabled: true)
        view.layoutIfNeeded()
        XCTAssertEqual(view.accessibilityLabel, text)
        XCTAssertTrue(view.accessibilityActivate())
        let animation = try XCTUnwrap(view.label.layer.animation(forKey: "sourceMarquee") as? CAKeyframeAnimation)
        let motion = AMLLMarqueeMotion(textWidth: view.label.bounds.width, viewportWidth: 100)
        XCTAssertEqual(animation.duration, motion.legDuration * 2, accuracy: 0.0001)
        XCTAssertEqual(animation.repeatCount, 0)
        XCTAssertEqual(animation.values as? [Double], [0, -motion.distance, 0])
        view.configure(text: text, size: 17, bold: true, enabled: false)
        XCTAssertNil(view.label.layer.animation(forKey: "sourceMarquee"))
        XCTAssertFalse(view.accessibilityActivate())
    }

    func testSourceThresholdAndOneRoundTrip() {
        let motion = AMLLMarqueeMotion(textWidth: 222, viewportWidth: 200)
        XCTAssertEqual(motion.distance, 32)
        XCTAssertEqual(motion.legDuration, 1)
        XCTAssertEqual(motion.offset(elapsed: 0.5), -16)
        XCTAssertEqual(motion.offset(elapsed: 1), -32)
        XCTAssertEqual(motion.offset(elapsed: 1.5), -16)
        XCTAssertEqual(motion.offset(elapsed: 2), 0)
        XCTAssertEqual(motion.offset(elapsed: 20), 0)
        XCTAssertEqual(AMLLMarqueeMotion(textWidth: 190, viewportWidth: 200).distance, 0)
    }

    func testInvalidMeasurementDoesNotCreateAnimation() {
        XCTAssertEqual(AMLLMarqueeMotion(textWidth: .nan, viewportWidth: 200).distance, 0)
        XCTAssertEqual(AMLLMarqueeMotion(textWidth: 200, viewportWidth: 0).legDuration, 0)
        XCTAssertEqual(AMLLMarqueeMotion(textWidth: 222, viewportWidth: 200).offset(elapsed: .infinity), 0)
    }
}
