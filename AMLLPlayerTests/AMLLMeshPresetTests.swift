@testable import AMLLPlayer
import XCTest

final class AMLLMeshPresetTests: XCTestCase {
    private struct Fixture: Decodable {
        var seed: UInt32
        var preset: AMLLMeshPreset
    }

    func testSeededGeneratorMatchesPinnedTypeScript() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "amll-background-reference", withExtension: "json"))
        let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: url))
        XCTAssertEqual(fixtures.count, 4)
        for fixture in fixtures {
            var random = AMLLMeshPreset.Random(state: fixture.seed)
            let actual = AMLLMeshPreset.generate(random: &random)
            XCTAssertEqual(actual.width, fixture.preset.width)
            XCTAssertEqual(actual.height, fixture.preset.height)
            XCTAssertEqual(actual.conf.count, fixture.preset.conf.count)
            for (point, expected) in zip(actual.conf, fixture.preset.conf) {
                XCTAssertEqual(point.cx, expected.cx)
                XCTAssertEqual(point.cy, expected.cy)
                for field in [\AMLLMeshPreset.Point.x, \.y, \.ur, \.vr, \.up, \.vp] {
                    // sin implementations can differ between V8 and Darwin.
                    XCTAssertEqual(point[keyPath: field], expected[keyPath: field], accuracy: 1e-8)
                }
            }
        }
    }

    func testAllSourcePresetsHaveCompleteGrid() throws {
        let presets = try AMLLMeshPreset.loadPresets()
        XCTAssertEqual(presets.count, 6)
        for preset in presets {
            XCTAssertEqual(preset.conf.count, preset.width * preset.height)
            let indexes = Set(preset.conf.map { $0.cx + $0.cy * preset.width })
            XCTAssertEqual(indexes, Set(0 ..< preset.width * preset.height))
        }
    }
}
