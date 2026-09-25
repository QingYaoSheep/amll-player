import UIKit
import XCTest
@testable import AMLLPlayer

final class AMLLFramePerformanceTests: XCTestCase {
    @MainActor
    func testBoundedSamplesAndNearestRankPercentiles() {
        let recorder = AMLLFramePerformanceRecorder(capacity: 4)
        for value in 1 ... 5 {
            recorder.append(.init(interval: Double(value) * 4, cpu: Double(value),
                                  layout: 0, raster: 0, engine: 0, layers: 0,
                                  drawableWait: 0, gpuSubmission: 0, gpu: 0,
                                  cacheBytes: value * 100))
        }
        let result = recorder.summary(targetFPS: 120)
        XCTAssertEqual(result.frames, 4)
        XCTAssertEqual(recorder.samples.map(\.cpu), [2, 3, 4, 5])
        XCTAssertEqual(result.cpu.p50, 3)
        XCTAssertEqual(result.cpu.p95, 5)
        XCTAssertEqual(result.cpu.p99, 5)
        XCTAssertEqual(result.peakCacheBytes, 500)
        XCTAssertEqual(result.longFrames, 2)
        recorder.reset()
        XCTAssertEqual(recorder.summary(targetFPS: 120).frames, 0)
    }

    @MainActor
    func testBackgroundRasterMatchesVisibleRowRaster() async {
        let line = LyricLine(id: "raster", text: "歌って ✨", start: 0, end: 2,
                             words: [.init(text: "歌って", start: 0, end: 2)], precision: .word)
        let layout = AMLLCoreTextLayout(line: line, width: 320,
                                        font: .systemFont(ofSize: 32), configuration: .init())
        let expected = AMLLPreparedRowImages(snapshot: layout.rasterSnapshot(), scale: 2)
        let snapshot = layout.rasterSnapshot()
        let actual = await Task.detached(priority: .utility) {
            AMLLPreparedRowImages(snapshot: snapshot, scale: 2)
        }.value
        XCTAssertEqual(actual.sharp.pngData(), expected.sharp.pngData())
        XCTAssertEqual(actual.ruby.pngData(), expected.ruby.pngData())
        XCTAssertEqual(actual.nearBlur.pngData(), expected.nearBlur.pngData())
    }
}
