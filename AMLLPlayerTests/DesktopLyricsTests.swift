@testable import AMLLPlayer
import CoreMedia
import UIKit
import XCTest

final class DesktopLyricsTests: XCTestCase {
    func testSettingsDefaultAndDecodeInvalidFieldsIndependently() throws {
        let decoder = JSONDecoder()
        let defaults = try decoder.decode(DesktopLyricsSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(defaults, DesktopLyricsSettings())
        let partial = Data(#"{"fontSize":90,"blurStrength":-1,"wordHighlight":false,"aspect":"tall","transition":"unknown"}"#.utf8)
        let settings = try decoder.decode(DesktopLyricsSettings.self, from: partial)
        XCTAssertEqual(settings.fontSize, 36)
        XCTAssertEqual(settings.blurStrength, 0)
        XCTAssertEqual(settings.aspect, .tall)
        XCTAssertEqual(settings.transition, .blur)
        XCTAssertFalse(settings.wordHighlight)
    }

    @MainActor
    func testAppearancePersistsAndCanResetWithoutChangingLegacyAutoStart() throws {
        let suite = "desktop-lyrics-test-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: DesktopLyricsController.autoStartKey)
        let preferences = DesktopLyricsPreferences(defaults: defaults)
        preferences.settings.aspect = .tall
        preferences.settings.blurStrength = 3.2
        preferences.settings.transition = .fade
        XCTAssertEqual(DesktopLyricsPreferences(defaults: defaults).settings, preferences.settings)
        XCTAssertEqual(preferences.settings.blurStrength, 3)
        preferences.settings = .init()
        XCTAssertEqual(DesktopLyricsPreferences(defaults: defaults).settings, DesktopLyricsSettings())
        XCTAssertTrue(defaults.bool(forKey: DesktopLyricsController.autoStartKey))
    }

    @MainActor
    func testFirstFrameDimensionsAndTierLimitsForEachAspect() {
        typealias Aspect = DesktopLyricsSettings.Aspect
        XCTAssertEqual(DesktopLyricsFrames(aspect: .wide).pixelSize, CGSize(width: 960, height: 480))
        XCTAssertEqual(DesktopLyricsFrames(aspect: .standard).pixelSize, CGSize(width: 960, height: 540))
        XCTAssertEqual(DesktopLyricsFrames(aspect: .tall).pixelSize, CGSize(width: 960, height: 720))
        XCTAssertEqual(Aspect.wide.outputSize(for: CGSize(width: 1000, height: 500)), CGSize(width: 1152, height: 576))
        XCTAssertEqual(Aspect.standard.outputSize(for: CGSize(width: 1080, height: 400)), CGSize(width: 960, height: 540))
        XCTAssertEqual(Aspect.tall.outputSize(for: CGSize(width: 2000, height: 1500)), CGSize(width: 1104, height: 828))
        for aspect in Aspect.allCases {
            for size in aspect.pixelSizes {
                XCTAssertEqual(size.width / size.height, aspect.ratio, accuracy: 0.001)
                XCTAssertLessThanOrEqual(size.width * size.height, 1280 * 720)
            }
        }
    }

    @MainActor
    func testQuickResizesOnlyReallocateForTheFinalTier() {
        let frames = DesktopLyricsFrames(aspect: .standard)
        let initial = CGSize(width: 960, height: 540)
        frames.resize(CMVideoDimensions(width: 1100, height: 650), at: 1)
        frames.applyPendingResize(at: 1.05)
        XCTAssertEqual(frames.pixelSize, initial)
        frames.resize(CMVideoDimensions(width: 1200, height: 700), at: 1.1)
        frames.applyPendingResize(at: 1.2)
        XCTAssertEqual(frames.pixelSize, initial)
        frames.applyPendingResize(at: 1.3)
        XCTAssertEqual(frames.pixelSize, CGSize(width: 1280, height: 720))
    }

    func testInstantChangeSnapsTheNativePositionAndPreservesLyricTime() throws {
        let document = AMLLDisplayDocument(lines: (0 ..< 3).map { index in
            let start = Double(index) * 3
            return LyricLine(id: "line-\(index)", text: "Line \(index)", start: start, end: start + 3)
        })
        var environment = AMLLRenderEnvironment(width: 320, height: 180, screenWidth: 320, fontSize: 22)
        environment.advance = 0
        environment.enableBlur = false
        environment.snapLinePresentation = true
        var engine = AMLLFrameEngine(document: document, environment: environment, heights: [44, 44, 44])
        let first = engine.render(.init(position: 2.99, playing: true), delta: 0)
        let next = engine.render(.init(position: 3.01, playing: true), delta: 0.02)
        let old = try XCTUnwrap(first.rows.first { $0.lineIndex == 1 })
        let current = try XCTUnwrap(next.rows.first { $0.lineIndex == 1 })
        let motion = try XCTUnwrap(current.positionMotion)
        XCTAssertLessThan(current.y, old.y)
        XCTAssertEqual(current.y, motion.target + 22 * 0.4, accuracy: 0.1)
        XCTAssertEqual(current.visualFocus, .current)
        XCTAssertEqual(current.blur, 0)
        XCTAssertEqual(next.lyricTime, 3.01, accuracy: 0.001)
    }

    func testDesktopPoliciesKeepTheSourcePresetAndSeparateBlurFromWordHighlighting() {
        var source = LyricsRenderConfiguration()
        source.blurInactive = false
        source.fontSize = 32
        var settings = DesktopLyricsSettings()
        settings.fontSize = 28
        settings.wordHighlight = false
        XCTAssertEqual(settings.blurMaximum, 1)
        XCTAssertTrue(settings.rendererConfiguration(source).blurInactive)
        XCTAssertEqual(settings.rendererConfiguration(source).fontSize, 28)
        XCTAssertEqual(settings.rendererConfiguration(source).animationStyle, source.animationStyle)
        settings.transition = .fade
        XCTAssertFalse(settings.rendererConfiguration(source).blurInactive)
        XCTAssertFalse(settings.snapsLines)
        XCTAssertFalse(settings.wordHighlight)
        settings.transition = .instant
        XCTAssertTrue(settings.snapsLines)
        XCTAssertEqual(settings.blurStrength, 1)
        XCTAssertEqual(source.fontSize, 32)
    }

    func testSingleLineSettingsKeepSavedScrollingOptionsAndSeparateAuxiliaries() throws {
        let data = Data(#"{"aspect":"tall","transition":"fade"}"#.utf8)
        var settings = try JSONDecoder().decode(DesktopLyricsSettings.self, from: data)
        XCTAssertEqual(settings.mode, .scrolling)
        XCTAssertTrue(settings.singleLineTranslation)
        XCTAssertTrue(settings.singleLineRomanization)
        settings.mode = .singleLine
        settings.singleLineTranslation = false
        var source = LyricsRenderConfiguration()
        source.romanization = false
        XCTAssertEqual(settings.outputAspect, .singleLine)
        XCTAssertEqual(settings.outputAspect.pixelSizes, [
            CGSize(width: 960, height: 384), CGSize(width: 1120, height: 448), CGSize(width: 1280, height: 512)
        ])
        XCTAssertFalse(settings.rendererConfiguration(source).translation)
        XCTAssertTrue(settings.rendererConfiguration(source).romanization)
        let decoded = try JSONDecoder().decode(DesktopLyricsSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded, settings)

        settings.mode = .scrolling
        XCTAssertEqual(settings.outputAspect, .tall)
        XCTAssertEqual(settings.transition, .fade)
        XCTAssertFalse(settings.rendererConfiguration(source).romanization)
    }

    func testSingleLineSelectionUsesSourceOnsetsAndHoldsThroughGaps() {
        let document = singleLineFixture()
        let timeline = DesktopLyricsSingleLineTimeline(document: document)
        XCTAssertNil(timeline.line(at: 0.99))
        XCTAssertEqual(timeline.line(at: 1)?.index, 0)
        XCTAssertEqual(timeline.line(at: 2)?.index, 0) // A background voice enters.
        XCTAssertEqual(timeline.line(at: 3)?.index, 2) // New main voice wins the overlap and the tie.
        XCTAssertEqual(timeline.line(at: 5.5)?.index, 2) // No return to the earlier overlap.
        XCTAssertEqual(timeline.line(at: 7)?.index, 2)
        XCTAssertEqual(timeline.line(at: 8)?.index, 4)
        XCTAssertEqual(timeline.line(at: 1.1)?.index, 0) // Seek back.
        XCTAssertEqual(timeline.line(at: DesktopLyricsSingleLineTimeline.lyricTime(position: 3.2, offset: 0.2))?.index, 2)
    }

    func testSingleLineTransitionFinishesExitBeforeShowingNewestTarget() {
        var transition = DesktopLyricsSingleLineTransition()
        XCTAssertEqual(transition.frame(target: 0, now: 0, immediate: true, blurs: true).layer, .live(index: 0, alpha: 1))
        let handoff = transition.frame(target: 1, now: 1, immediate: false, blurs: true)
        XCTAssertEqual(handoff.capture, 0)
        XCTAssertEqual(handoff.layer, .outgoing(alpha: 1, blur: 0))

        let interrupted = transition.frame(target: 2, now: 1.06, immediate: false, blurs: true)
        XCTAssertNil(interrupted.capture)
        guard case let .outgoing(alpha, blur) = interrupted.layer else { return XCTFail("The newer lyric drew during the exit") }
        XCTAssertLessThan(alpha, 1)
        XCTAssertGreaterThan(blur, 0)
        XCTAssertTrue(transition.isAnimating)

        let boundary = 1 + DesktopLyricsSingleLineTransition.duration
        XCTAssertEqual(transition.frame(target: 2, now: boundary, immediate: false, blurs: true).layer, .live(index: 2, alpha: 0))
        let completed = transition.frame(target: 2, now: boundary + 0.2, immediate: false, blurs: true)
        XCTAssertEqual(completed.layer, .live(index: 2, alpha: 1))
        XCTAssertFalse(transition.isAnimating)
    }

    func testSingleLineReducedMotionAndConfirmedSeekClearWithoutStaleLayers() {
        var transition = DesktopLyricsSingleLineTransition()
        _ = transition.frame(target: 0, now: 0, immediate: true, blurs: false)
        _ = transition.frame(target: 1, now: 1, immediate: false, blurs: false)
        let fade = transition.frame(target: 1, now: 1.04, immediate: false, blurs: false)
        guard case let .outgoing(alpha, radius) = fade.layer else { return XCTFail("Missing pure fade") }
        XCTAssertLessThan(alpha, 1)
        XCTAssertEqual(radius, 0)
        let seek = transition.frame(target: 4, now: 1.05, immediate: true, blurs: false)
        XCTAssertEqual(seek.layer, .live(index: 4, alpha: 1))
        XCTAssertNil(seek.capture)
        XCTAssertFalse(transition.isAnimating)
        XCTAssertEqual(transition.frame(target: nil, now: 2, immediate: true, blurs: true).layer, .empty)
    }

    @MainActor
    func testSingleLineCanvasInstallsOnlyTheSelectedNativeRow() {
        let document = singleLineFixture()
        let timeline = DesktopLyricsSingleLineTimeline(document: document)
        var settings = DesktopLyricsSettings()
        settings.mode = .singleLine
        let canvas = AMLLNativeCanvas(frame: CGRect(origin: .zero, size: settings.outputAspect.canvasSize))
        canvas.drivesFramesExternally = true
        canvas.configure(document: document, configuration: settings.rendererConfiguration(.init()),
                         input: .init(position: 3.2, playing: true), active: true,
                         reduceMotion: false, canSeek: false, desktopSettings: settings)
        let sample = LyricsPlaybackFrame(snapshot: nil, position: 3.2, playing: true, seekRevision: 0,
                                         pending: nil, confirmation: nil, legacySeekPosition: nil)
        _ = canvas.advanceExportFrame(sample: sample, delta: 0, singleLine: timeline.line(at: 3.2))
        XCTAssertEqual(canvas.visibleRowCount, 1)
        XCTAssertNil(canvas.snapshotExportLine(0))
        XCTAssertNotNil(canvas.snapshotExportLine(2))
    }

    private func singleLineFixture() -> LyricsDocument {
        let lines = [
            LyricLine(id: "opening", text: "Opening", start: 0, end: 6,
                      words: [.init(text: "Opening", start: 1, end: 6)], precision: .word),
            LyricLine(id: "bg", text: "Background", start: 2, end: 3, isBackground: true),
            LyricLine(id: "overlap", text: "Overlap", start: 3, end: 4, translation: "Translation", romanization: "Romanization"),
            LyricLine(id: "same", text: "Same onset", start: 3, end: 5),
            LyricLine(id: "late", text: "After interlude", start: 8, end: 9)
        ]
        return .init(candidate: .init(source: .apple, sourceID: "single-line", title: "", artists: []),
                     lines: lines, language: "en", selectionReason: "test")
    }

    @MainActor
    func testOffscreenLayerRenderingRespectsTheWordGradientAlphaMask() throws {
        let bounds = CGRect(x: 0, y: 0, width: 32, height: 8)
        let text = CALayer()
        text.bounds = bounds
        text.backgroundColor = UIColor.white.cgColor
        let mask = CAGradientLayer()
        mask.frame = bounds
        mask.colors = [UIColor.white.cgColor, UIColor.clear.cgColor]
        mask.startPoint = CGPoint(x: 0, y: 0.5)
        mask.endPoint = CGPoint(x: 1, y: 0.5)
        text.mask = mask

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = try XCTUnwrap(UIGraphicsImageRenderer(size: bounds.size, format: format).image {
            text.render(in: $0.cgContext)
        }.cgImage)
        let context = try XCTUnwrap(CGContext(data: nil, width: 32, height: 8, bitsPerComponent: 8,
            bytesPerRow: 128, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo:
                CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: bounds)
        let data = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        let leftAlpha = data[(4 * 32 + 2) * 4 + 3]
        let rightAlpha = data[(4 * 32 + 29) * 4 + 3]
        XCTAssertGreaterThan(leftAlpha, 185)
        XCTAssertLessThan(rightAlpha, 75)
    }
}
