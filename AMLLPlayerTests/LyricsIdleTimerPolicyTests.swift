@testable import AMLLPlayer
import XCTest

final class LyricsIdleTimerPolicyTests: XCTestCase {
    func testShouldKeepAwakeOnlyWhenAllConditionsAreTrue() {
        for enabled in [false, true] {
            for visible in [false, true] {
                for foreground in [false, true] {
                    for playing in [false, true] {
                        let expected = enabled && visible && foreground && playing
                        XCTAssertEqual(
                            LyricsIdleTimerPolicy.shouldKeepAwake(
                                enabled: enabled,
                                lyricsPageVisible: visible,
                                isForeground: foreground,
                                isPlaying: playing
                            ),
                            expected
                        )
                    }
                }
            }
        }
    }
}
