@testable import AMLLPlayer
import XCTest

final class AMLLPixiStateTests: XCTestCase {
    private struct Fixture: Decodable {
        struct Frame: Decodable { var time: Double; var alpha: Double; var sprites: [[Float]] }
        var name: String
        var steps: [Double]
        var frames: [Frame]
    }

    func testPinnedPixiTrajectories() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "amll-pixi-reference", withExtension: "json"))
        for fixture in try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: url)) {
            var state = AMLLPixiState(rotations: [0, 0.5, 1, 2])
            for (step, expected) in zip(fixture.steps, fixture.frames) {
                state.advance(seconds: step)
                XCTAssertEqual(state.time, expected.time, accuracy: 1e-9, fixture.name)
                XCTAssertEqual(state.alpha, expected.alpha, accuracy: 1e-9, fixture.name)
                for (sprite, reference) in zip(state.sprites(width: 600, height: 900), expected.sprites) {
                    for index in 0 ..< 4 {
                        XCTAssertEqual(sprite[index], reference[index], accuracy: 0.0001, fixture.name)
                    }
                }
            }
        }
    }

    func testFilterThresholdsMatchSourceStrictInequalities() {
        XCTAssertEqual(AMLLPixiState.blurPasses(minimumBorder: 768).count, 5)
        XCTAssertEqual(AMLLPixiState.blurPasses(minimumBorder: 769).count, 6)
        XCTAssertEqual(AMLLPixiState.blurPasses(minimumBorder: 1536).count, 6)
        XCTAssertEqual(AMLLPixiState.blurPasses(minimumBorder: 1537).count, 7)
    }
}
