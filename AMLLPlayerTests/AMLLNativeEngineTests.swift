@testable import AMLLPlayer
import CoreText
import UIKit
import XCTest

final class AMLLNativeEngineTests: XCTestCase {
    func testClockDiscontinuityDoesNotPretendToBeASeek() {
        let lines = (0 ..< 4).map { index in
            LyricLine(id: String(index), text: "Line \(index)", start: Double(index * 5), end: Double(index * 5 + 3))
        }
        var engine = AMLLFrameEngine(document: AMLLDisplayDocument(lines: lines),
                                     environment: .init(width: 400, height: 700, screenWidth: 400, fontSize: 32), heights: [60, 60, 60, 60])
        _ = engine.render(.init(position: 1, playing: true), delta: 0)
        engine.handle(.beginBrowsing)
        engine.handle(.browseBy(40))
        engine.handle(.endBrowsing(velocity: 0))
        let discontinuity = engine.render(.init(position: 12, playing: true), delta: 0.18)
        XCTAssertTrue(discontinuity.browsing)
        let seek = engine.render(.init(position: 2, playing: false, seekRevision: 1), delta: 0)
        XCTAssertFalse(seek.browsing)
        XCTAssertEqual(seek.focusGroup, 0)
    }

    func testDifferentRowsRetainIndependentSpringDelays() {
        let lines = (0 ..< 5).map { index in
            LyricLine(id: String(index), text: "Line \(index)", start: Double(index * 2), end: Double(index * 2 + 2))
        }
        var engine = AMLLFrameEngine(document: AMLLDisplayDocument(lines: lines),
                                     environment: .init(width: 400, height: 700, screenWidth: 400, fontSize: 32), heights: [60, 60, 60, 60, 60])
        for _ in 0 ..< 180 {
            _ = engine.render(.init(position: 0.5, playing: true), delta: 1.0 / 60)
        }
        let before = engine.render(.init(position: 0.5, playing: true), delta: 0)
        let after = engine.render(.init(position: 2.1, playing: true), delta: 1.0 / 60)
        let movement = zip(before.rows, after.rows).map { $1.y - $0.y }
        XCTAssertGreaterThan(abs(movement[0] - movement[3]), 0.01)
    }

    @MainActor
    func testCoreTextPreservesEmojiCombiningMarksAndBidirectionalText() {
        let text = "مرحبا 👩‍👩‍👦 é 世界"
        let line = LyricLine(id: "unicode", text: text, start: 0, end: 4,
                             words: [.init(text: text, start: 0, end: 4)], precision: .word)
        let layout = AMLLCoreTextLayout(line: line, width: 160, font: .systemFont(ofSize: 32, weight: .semibold), configuration: .init())
        XCTAssertGreaterThan(layout.size.height, 0)
        XCTAssertFalse(layout.fragments.isEmpty)
        let combined = AMLLWordSegmentation.chunks(line.words).flatMap(\.self).map(\.text).joined()
        XCTAssertEqual(combined, text)
        for offset in layout.breakOffsets {
            XCTAssertNotNil(Range(NSRange(location: offset, length: 0), in: text))
        }
        XCTAssertNotNil(layout.raster(scale: 3).cgImage)
    }

    @MainActor
    func testMixedDirectionWordUsesDisjointVisualRunsWithLogicalMaskOrder() {
        let text = "abcمرحبا123"
        let line = LyricLine(id: "mixed", text: text, start: 1, end: 5,
                             words: [.init(text: text, start: 1, end: 5)], precision: .word)
        let font = UIFont.systemFont(ofSize: 32, weight: .semibold)
        let layout = AMLLCoreTextLayout(line: line, width: 400, font: font, configuration: .init())
        XCTAssertTrue(layout.fragments.contains(where: \.rtl))
        XCTAssertTrue(layout.fragments.contains { !$0.rtl })
        XCTAssertEqual(layout.fragments.map(\.range.location), layout.fragments.map(\.range.location).sorted())
        XCTAssertEqual(layout.fragments.reduce(0) { $0 + $1.range.length }, text.utf16.count)
        for (index, fragment) in layout.fragments.enumerated() {
            XCTAssertGreaterThan(fragment.rect.width, 0)
            for other in layout.fragments.dropFirst(index + 1) {
                XCTAssertLessThanOrEqual(fragment.rect.intersection(other.rect).width, 0.001)
            }
        }
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .kern: 0]
        let shaped = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        let expectedWidth = CTLineGetTypographicBounds(shaped, nil, nil, nil)
        XCTAssertEqual(layout.maskWords.reduce(0) { $0 + $1.width }, expectedWidth, accuracy: 0.01)
    }

    @MainActor
    func testNativeLayoutExposesCharacterClustersAndCachedBlurRaster() {
        let text = "长音 é 👩‍👩‍👦"
        let line = LyricLine(id: "clusters", text: text, start: 0, end: 4,
                             words: [.init(text: text, start: 0, end: 4)], precision: .word)
        let layout = AMLLCoreTextLayout(line: line, width: 360,
                                        font: .systemFont(ofSize: 32, weight: .semibold), configuration: .init())
        XCTAssertGreaterThanOrEqual(layout.characterFragments.count, 4)
        XCTAssertNotNil(layout.raster(scale: 2, blurRadius: 2).cgImage)
        XCTAssertNotNil(layout.raster(scale: 2, auxiliary: true, blurRadius: 5).cgImage)
    }

    func testFrameStateCarriesRealPageBackgroundAndControlInput() {
        let line = LyricLine(id: "page", text: "Page", start: 0, end: 4)
        var configuration = LyricsRenderConfiguration()
        configuration.showControls = true
        configuration.backgroundBlur = 40
        let item = PlaybackItem(id: "track", uri: "spotify:track:track", title: "Page", artists: ["Test"],
                                albumTitle: nil, artworkURL: URL(string: "https://example.com/cover.jpg"),
                                duration: 100, isEpisode: false, isAdvertisement: false)
        let snapshot = PlaybackSnapshot(item: item, isPlaying: true, position: 25, duration: 100,
                                        device: nil, restrictions: .unrestricted, source: .webAPI, sampledAtUptime: 0)
        var engine = AMLLFrameEngine(document: AMLLDisplayDocument(lines: [line]),
                                     environment: .init(width: 400, height: 700, screenWidth: 400, fontSize: 32), heights: [60])
        let state = engine.render(.init(position: 25, playing: true, playbackSnapshot: snapshot,
                                        artworkURL: item.artworkURL, configuration: configuration), delta: 0)
        XCTAssertEqual(state.background.artworkURL, item.artworkURL)
        XCTAssertEqual(state.background.progress, 0.25, accuracy: 0.000_001)
        XCTAssertEqual(state.background.blur, 40, accuracy: 0.000_001)
        XCTAssertTrue(state.controls.visible)
        XCTAssertEqual(state.controls.progress, 0.25, accuracy: 0.000_001)
    }

    func testPausedBackgroundOccupiesFlowAndKeepsItsOwnMaskScale() throws {
        let lines = [
            LyricLine(id: "main", text: "Lead", start: 1, end: 3),
            LyricLine(id: "background", text: "Echo", start: 1, end: 3, isBackground: true),
            LyricLine(id: "next", text: "Next", start: 8, end: 10),
        ]
        var environment = AMLLRenderEnvironment(width: 400, height: 700, screenWidth: 400, fontSize: 32)
        environment.enableSpring = false
        var engine = AMLLFrameEngine(document: AMLLDisplayDocument(lines: lines), environment: environment, heights: [60, 30, 60])
        let playing = engine.render(.init(position: 0, playing: true), delta: 0)
        _ = engine.render(.init(position: 0, playing: false), delta: 0)
        var paused = engine.render(.init(position: 0, playing: false), delta: 0)
        for _ in 0 ..< 30 {
            paused = engine.render(.init(position: 0, playing: false), delta: 1.0 / 60)
        }
        let background = try XCTUnwrap(paused.rows.first { $0.lineIndex == 1 })
        XCTAssertFalse(background.hidden)
        XCTAssertGreaterThan(background.opacity, 0)
        XCTAssertEqual(background.scale, 1, accuracy: 0.000_001)
        XCTAssertEqual(background.darkAlpha, 0.4, accuracy: 0.000_001)
        // CSS :not(.playing) puts inactive background wrappers back into normal flow.
        let before = try XCTUnwrap(playing.rows.first { $0.lineIndex == 2 })
        let after = try XCTUnwrap(paused.rows.first { $0.lineIndex == 2 })
        XCTAssertEqual(after.y - before.y, 30 + 32 * 0.3, accuracy: 0.000_001)
    }

    @MainActor
    func testNativeCanvasExportsActualFramesWithoutAdvancingLiveState() throws {
        let canvas = AMLLNativeCanvas(frame: CGRect(x: 0, y: 0, width: 402, height: 700))
        let window = UIWindow(frame: canvas.bounds)
        window.addSubview(canvas)
        canvas.backgroundColor = .black
        canvas.position = { 6 }
        canvas.configure(document: LyricsRenderFixture.document, configuration: .init(),
                         input: .init(position: 6, playing: true), active: false, reduceMotion: false)
        for _ in 0 ..< 120 {
            canvas.advanceFrame(delta: 1.0 / 60)
        }
        let before = try XCTUnwrap(canvas.frameState)
        let bytes = try XCTUnwrap(canvas.exportMotionTrace(fps: 60))
        struct Trace: Decodable {
            var environment: AMLLRenderEnvironment
            var fps: Int
            var lineIDs: [String]
            var breaks: [[Int]]
            var frames: [AMLLFrameState]
        }
        let trace = try JSONDecoder().decode(Trace.self, from: bytes)
        XCTAssertEqual(trace.frames.count, 300)
        XCTAssertEqual(trace.environment.width, 402)
        XCTAssertEqual(trace.lineIDs.count, trace.breaks.count)
        XCTAssertEqual(trace.frames.first?.rows.count, before.rows.count)
        XCTAssertEqual(canvas.frameState?.animationTime, before.animationTime)
        XCTAssertEqual(canvas.frameState?.rows.map(\.y), before.rows.map(\.y))
        XCTAssertGreaterThan(canvas.visibleRowCount, 0)
        XCTAssertLessThan(canvas.cachedLayoutCount, trace.lineIDs.count)
        XCTAssertTrue(trace.frames.flatMap(\.rows).allSatisfy { $0.y.isFinite && $0.scale.isFinite })
        let image = UIGraphicsImageRenderer(bounds: canvas.bounds).image { canvas.layer.render(in: $0.cgContext) }
        let attachment = XCTAttachment(image: image)
        attachment.name = "AMLL-source-port-402pt-unapproved"
        attachment.lifetime = .keepAlways
        add(attachment)
        canvas.removeFromSuperview()
    }

    @MainActor
    func testPausedMaskPixelsRemainFrozenUntilExplicitSeek() throws {
        let line = LyricLine(id: "held", text: "Held note", start: 1, end: 10,
                             words: [.init(text: "Held note", start: 1, end: 10)], precision: .word)
        let document = LyricsDocument(candidate: .init(source: .apple, sourceID: "mask-clock", title: "Clock fixture", artists: ["Test"]),
                                      lines: [line], language: "en", selectionReason: "Synthetic clock fixture")
        let canvas = AMLLNativeCanvas(frame: CGRect(x: 0, y: 0, width: 402, height: 700))
        let window = UIWindow(frame: canvas.bounds)
        window.addSubview(canvas)
        defer { canvas.removeFromSuperview() }
        canvas.backgroundColor = .black
        var position = 3.0
        canvas.position = { position }
        canvas.configure(document: document, configuration: .init(), input: .init(position: position, playing: false), active: false, reduceMotion: false)
        for _ in 0 ..< 180 {
            canvas.advanceFrame(delta: 1.0 / 60)
        }
        func pixels() throws -> Data {
            try XCTUnwrap(UIGraphicsImageRenderer(bounds: canvas.bounds).image { canvas.layer.render(in: $0.cgContext) }.pngData())
        }
        XCTAssertGreaterThan(canvas.visibleRowCount, 0)
        let before = try pixels()
        position = 7
        canvas.advanceFrame(delta: 0)
        XCTAssertEqual(try pixels(), before, "A paused snapshot correction must not move the visible fill")
        canvas.configure(document: document, configuration: .init(), input: .init(position: position, playing: false, seekRevision: 1), active: false, reduceMotion: false)
        XCTAssertNotEqual(try pixels(), before, "Explicit seek must update the actual rendered mask")
    }

    func testMaskClockIgnoresSnapshotCorrectionsAndReanchorsOnlyOnSeek() throws {
        let line = LyricLine(id: "held", text: "Held", start: 1, end: 10,
                             words: [.init(text: "Held", start: 1, end: 10)], precision: .word)
        let document = AMLLDisplayDocument(lines: [line])
        var engine = AMLLFrameEngine(document: document,
                                     environment: .init(width: 400, height: 700, screenWidth: 400, fontSize: 32), heights: [60])
        let initial = engine.render(.init(position: 2, playing: true), delta: 0)
        let startTime = try XCTUnwrap(initial.rows.first).wordClock.time
        let corrected = engine.render(.init(position: 4, playing: true), delta: 0.18)
        XCTAssertEqual(try XCTUnwrap(corrected.rows.first).wordClock.time, startTime + 0.18, accuracy: 0.000_001)
        _ = engine.render(.init(position: 4, playing: false), delta: 0)
        let paused = engine.render(.init(position: 5, playing: false), delta: 3)
        XCTAssertEqual(try XCTUnwrap(paused.rows.first).wordClock.time, startTime + 0.18, accuracy: 0.000_001)
        let seek = engine.render(.init(position: 1.5, playing: false, seekRevision: 1), delta: 0)
        XCTAssertEqual(try XCTUnwrap(seek.rows.first).wordClock.time, 1.5 - document.lines[0].start, accuracy: 0.000_001)
        _ = engine.render(.init(position: 1.5, playing: true, seekRevision: 1), delta: 0)
        let resumed = engine.render(.init(position: 1.5, playing: true, seekRevision: 1), delta: 1.0 / 120)
        XCTAssertEqual(try XCTUnwrap(resumed.rows.first).wordClock.time, 1.5 - document.lines[0].start + 1.0 / 120, accuracy: 0.000_001)
    }

    func testWordFloatClockPausesSeeksAndReversesFromEachWordsOwnEnd() {
        var clock = AMLLWordAnimationClock()
        clock.enable(at: 2)
        clock.advance(0.18, playing: true)
        XCTAssertEqual(clock.time, 2.18, accuracy: 0.000_001)
        clock.advance(4, playing: false)
        XCTAssertEqual(clock.time, 2.18, accuracy: 0.000_001)
        clock.disable()
        clock.advance(0.2, playing: false)
        XCTAssertEqual(clock.floatElapsed(wordStart: 0, duration: 1), 0.8, accuracy: 0.000_001)
        XCTAssertEqual(clock.floatElapsed(wordStart: 1, duration: 2), 0.98, accuracy: 0.000_001)
        clock.enable(at: 0.4)
        XCTAssertEqual(clock.time, 0.4, accuracy: 0.000_001)
        XCTAssertEqual(clock.reverseElapsed, 0)
        XCTAssertTrue(clock.enabled)
    }
}
