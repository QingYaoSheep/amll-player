@testable import AMLLPlayer
import UIKit
import XCTest

@MainActor final class LyricsCompositingRecoveryTests: XCTestCase {
    func testRefreshWaitsForTheCurrentBackgroundAndReturnsToFullOpacityOnlyOnce() async throws {
        let recovery = LyricsCompositingRecovery()
        let window = UIWindow()
        window.rootViewController = UIViewController()
        recovery.configure(context: "ordinary-mesh")
        let request = try XCTUnwrap(recovery.backgroundPresentation)
        XCTAssertEqual(recovery.opacity, 1)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(recovery.completedRefreshes, 0, "Mounting alone must not refresh an unpresented background")
        request.didPresent(UUID(), window)
        XCTAssertEqual(recovery.opacity, 1, "A replaced surface cannot begin the refresh")
        request.didPresent(request.id, window)
        XCTAssertEqual(recovery.opacity, 0.99)
        request.didPresent(request.id, window)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(recovery.opacity, 1)
        XCTAssertEqual(recovery.completedRefreshes, 1)
        XCTAssertNil(recovery.backgroundPresentation, "No presentation observer remains after recovery")
        recovery.configure(context: "ordinary-mesh")
        request.didPresent(request.id, window)
        XCTAssertEqual(recovery.completedRefreshes, 1)
        XCTAssertEqual(recovery.opacity, 1, "Ordinary view updates must not restart page opacity changes")
    }

    func testLeavingOrReplacingTheContextCancelsOldRefreshesAndCallbacks() async throws {
        let recovery = LyricsCompositingRecovery()
        let window = UIWindow()
        window.rootViewController = UIViewController()
        recovery.configure(context: "first")
        let first = try XCTUnwrap(recovery.backgroundPresentation)
        first.didPresent(first.id, window)
        XCTAssertEqual(recovery.opacity, 0.99)
        recovery.reset()
        XCTAssertEqual(recovery.opacity, 1)
        recovery.configure(context: "second")
        let second = try XCTUnwrap(recovery.backgroundPresentation)
        XCTAssertNotEqual(first.id, second.id)
        first.didPresent(first.id, window)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(recovery.completedRefreshes, 0)
        XCTAssertEqual(recovery.opacity, 1)
        second.didPresent(second.id, window)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(recovery.completedRefreshes, 1)
        XCTAssertEqual(recovery.opacity, 1)
    }
}
