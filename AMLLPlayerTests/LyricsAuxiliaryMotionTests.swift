@testable import AMLLPlayer
import UIKit
import XCTest

@MainActor final class LyricsAuxiliaryMotionTests: XCTestCase {
    func testPresentationSpringMatchesTheMeasuredPausedVideoRowMotion() throws {
        struct Sample: Decodable { var elapsed: Double; var position: Double }
        struct Capture: Decodable { var totalMovement: Double; var samples: [Sample] }
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "auxiliary-video-motion", withExtension: "json"))
        let capture = try JSONDecoder().decode(Capture.self, from: Data(contentsOf: url))
        for sample in capture.samples {
            let actual = LyricsAuxiliaryMotion.sample(from: 0, to: capture.totalMovement, elapsed: sample.elapsed).position
            XCTAssertEqual(actual, sample.position, accuracy: 2, "Measured video at \(sample.elapsed)s; this is a presentation fit, not an Apple implementation claim")
        }
        for fps in [60.0, 120.0] {
            for time in stride(from: 0.0, through: 0.7, by: 1 / fps) {
                let open = LyricsAuxiliaryMotion.sample(from: 0, to: 1, elapsed: time).position
                let close = LyricsAuxiliaryMotion.sample(from: 1, to: 0, elapsed: time).position
                XCTAssertEqual(open + close, 1, accuracy: 0.000001)
            }
        }
    }

    func testAuxiliaryMovesDownOnEntryUpOnExitAndRetargetsItsVelocity() {
        let fade = LyricsAuxiliaryFade(); defer { fade.cancel() }
        var config = LyricsRenderConfiguration(); config.translation = false; fade.reset(config)
        config.translation = true; fade.update(config, animated: true, now: 10)
        let first = fade.geometry(.translation, now: 10)
        let middle = fade.geometry(.translation, now: 10.1)
        XCTAssertEqual(first.position, 0)
        XCTAssertGreaterThan(middle.position, first.position); XCTAssertLessThan(middle.position, 1)
        XCTAssertGreaterThan(fade.value(.translation, now: 10.1), 0); XCTAssertLessThan(fade.value(.translation, now: 10.1), 1)
        config.translation = false; fade.update(config, animated: true, now: 10.1)
        XCTAssertEqual(fade.geometry(.translation, now: 10.1).position, middle.position, accuracy: 0.000001)
        XCTAssertEqual(fade.geometry(.translation, now: 10.1).velocity, middle.velocity, accuracy: 0.000001)
        XCTAssertLessThan(fade.geometry(.translation, now: 10.5).position, middle.position)
        fade.update(config, animated: true, reduceMotion: true, now: 10.15)
        XCTAssertEqual(fade.geometry(.translation, now: 10.15).position, 0)
    }

    func testRowReflowHoldsForReadinessAndReversesFromItsPresentedPosition() {
        let fade = LyricsAuxiliaryFade(); defer { fade.cancel() }
        var config = LyricsRenderConfiguration(); config.translation = false; fade.reset(config)
        config.translation = true; fade.update(config, animated: true, now: 10)
        let token = fade.beginPreparation([.translation], now: 10)
        let reflow = LyricsAuxiliaryReflow()
        reflow.capture([1: 100], kinds: [.translation], now: 10)
        reflow.install(index: 1, target: 160, scale: 1, enabled: true)
        XCTAssertEqual(reflow.offset(index: 1, fade: fade, now: 10.4), -60)
        fade.finishPreparation(token, now: 10.4)
        XCTAssertEqual(reflow.offset(index: 1, fade: fade, now: 10.4), -60)
        let offset = reflow.offset(index: 1, fade: fade, now: 10.55)
        XCTAssertGreaterThan(offset, -60); XCTAssertLessThan(offset, 0)
        reflow.capture([1: 160 + offset], kinds: [.translation], now: 10.55)
        reflow.install(index: 1, target: 100, scale: 1, enabled: true)
        XCTAssertEqual(100 + reflow.offset(index: 1, fade: fade, now: 10.55), 160 + offset, accuracy: 0.000001)
        reflow.reset(); XCTAssertFalse(reflow.isAnimating)
    }

    func testRealNativeAndCompatibilityPagesAnimateSpacingWhilePaused() async throws {
        var lines = (0 ..< 3).map { index in
            LyricLine(id: "aux-motion-\(index)", text: "Main line \(index)", start: Double(index * 5), end: Double(index * 5 + 4))
        }
        for index in lines.indices { lines[index].translation = "First translation\nSecond translation"; lines[index].romanization = "Romanization" }
        let document = LyricsDocument(candidate: .init(source: .apple, sourceID: "aux-motion", title: "Motion", artists: []),
            lines: lines, language: "en", selectionReason: "Paused row reflow")
        for native in [true, false] {
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let previous = scene.keyWindow
            let window = UIWindow(windowScene: scene); window.frame = scene.coordinateSpace.bounds
            window.rootViewController = UIViewController(); window.makeKeyAndVisible()
            let frame = CGRect(x: 0, y: 0, width: 402, height: 700)
            let view: UIView = native ? AMLLNativeCanvas(frame: frame) : LyricsRenderView(frame: frame)
            window.rootViewController?.view.addSubview(view)
            var config = LyricsRenderConfiguration(); config.translation = false; config.romanization = true; config.romanizationFirst = false
            config.blurInactive = false; config.hdr = .init(enabled: false)
            var songPosition = 1.0, seekRevision = 0
            var reduceMotion = false
            func playback() -> LyricsPlaybackFrame {
                .init(snapshot: nil, position: songPosition, playing: false, seekRevision: seekRevision,
                    pending: nil, confirmation: nil, legacySeekPosition: nil)
            }
            func update() {
                if let canvas = view as? AMLLNativeCanvas {
                    canvas.position = { songPosition }; canvas.playbackFrame = { playback() }
                    canvas.configure(document: document, configuration: config, input: .init(position: songPosition, playing: false), active: true, reduceMotion: reduceMotion)
                } else if let canvas = view as? LyricsRenderView {
                    canvas.position = { songPosition }; canvas.playbackFrame = { playback() }
                    canvas.update(document: document, configuration: config, offset: 0, duration: 20, playing: false,
                        active: true, canSeek: true, reduceMotion: reduceMotion, resumeToken: 0)
                }
                view.layoutIfNeeded()
            }
            func positions() -> [Int: CGFloat] {
                (view as? AMLLNativeCanvas)?.auxiliaryRowMainPositions ?? (view as? LyricsRenderView)?.auxiliaryRowMainPositions ?? [:]
            }
            func gap() throws -> CGFloat {
                let values = positions()
                return try XCTUnwrap(values[1]) - XCTUnwrap(values[0])
            }
            func pronunciationPosition() throws -> CGFloat {
                let slots = (view as? AMLLNativeCanvas)?.auxiliaryRowSlots ?? (view as? LyricsRenderView)?.auxiliaryRowSlots ?? [:]
                return try XCTUnwrap(slots[0]?[.romanization])
            }
            defer {
                (view as? AMLLNativeCanvas)?.stop(); (view as? LyricsRenderView)?.stop()
                window.isHidden = true; previous?.makeKey()
            }
            update(); try await Task.sleep(for: .milliseconds(450))
            let before = try gap(), main = try XCTUnwrap(positions()[0])
            let pronunciationBefore = try pronunciationPosition()
            config.translation = true; update()
            XCTAssertEqual(try gap(), before, accuracy: 2, "No first-frame spacing jump; native \(native)")
            try await Task.sleep(for: .milliseconds(120))
            let opening = try gap()
            try await Task.sleep(for: .milliseconds(1100))
            let expanded = try gap()
            let pronunciationExpanded = try pronunciationPosition()
            XCTAssertGreaterThan(opening, before); XCTAssertLessThan(opening, expanded)
            XCTAssertGreaterThan(expanded - before, 10)
            XCTAssertGreaterThan(pronunciationExpanded - pronunciationBefore, 10)
            XCTAssertEqual(try XCTUnwrap(positions()[0]), main, accuracy: 2)
            config.translation = false; update()
            XCTAssertEqual(try gap(), expanded, accuracy: 2, "Exit starts from the displayed row spacing")
            try await Task.sleep(for: .milliseconds(100))
            let closing = try gap()
            let slotBeforeCleanup = try pronunciationPosition()
            try await Task.sleep(for: .milliseconds(100))
            let slotAfterCleanup = try pronunciationPosition()
            XCTAssertLessThan(abs(slotAfterCleanup - slotBeforeCleanup), (pronunciationExpanded - pronunciationBefore) * 0.8,
                "The remaining annotation must not snap when the outgoing translation raster is removed")
            try await Task.sleep(for: .milliseconds(1000))
            XCTAssertLessThan(closing, expanded); XCTAssertGreaterThan(closing, before)
            XCTAssertEqual(try gap(), before, accuracy: 2)
            XCTAssertEqual(try XCTUnwrap(positions()[0]), main, accuracy: 2)
            XCTAssertEqual(try pronunciationPosition(), pronunciationBefore, accuracy: 2)
            if let canvas = view as? AMLLNativeCanvas { XCTAssertEqual(canvas.frameState?.lyricTime, 1) }
            config.translation = true; update()
            try await Task.sleep(for: .milliseconds(80))
            XCTAssertLessThan(try gap(), expanded)
            // No configure call: exercise the same trusted frame-driven path
            // that can consume the seek revision before SwiftUI refreshes.
            songPosition = 1.2; seekRevision += 1
            try await Task.sleep(for: .milliseconds(80))
            XCTAssertEqual(try gap(), expanded, accuracy: 2, "A confirmed small seek must clear old reflow offsets")
            if let canvas = view as? AMLLNativeCanvas { XCTAssertEqual(canvas.frameState?.lyricTime ?? 0, 1.2, accuracy: 0.001) }
            config.translation = false; update()
            try await Task.sleep(for: .milliseconds(70))
            reduceMotion = true; update()
            try await Task.sleep(for: .milliseconds(40))
            let reduced = try gap()
            try await Task.sleep(for: .milliseconds(120))
            XCTAssertEqual(try gap(), reduced, accuracy: 1, "Reduce Motion must cancel an already installed spring")
        }
    }
}
