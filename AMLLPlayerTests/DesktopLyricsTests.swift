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
        XCTAssertGreaterThan(blur, 1)
        XCTAssertGreaterThan(alpha, 0.7, "Visible softening needs enough old-line opacity")
        XCTAssertTrue(transition.isAnimating)

        let boundary = 1 + DesktopLyricsSingleLineTransition.exitDuration
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

    @MainActor
    func testDesktopBackdropIsBlurredOpaqueAndReusedForTheSameCover() async throws {
        let size = CGSize(width: 100, height: 50)
        let bounds = CGRect(origin: .zero, size: size)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let source = renderer.image { output in
            output.cgContext.setFillColor(UIColor.white.cgColor)
            output.cgContext.fill(CGRect(x: 50, y: 0, width: 50, height: 50))
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: url) }
        try XCTUnwrap(source.pngData()).write(to: url)

        let background = DesktopLyricsBackground(size: size)
        background.update(artworkURL: url)
        for _ in 0 ..< 500 where background.artwork == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotNil(background.artwork)
        let revision = background.revision
        background.update(artworkURL: url)
        XCTAssertEqual(background.revision, revision)
        let rendered = try XCTUnwrap(renderer.image { _ in background.draw(in: bounds) }.cgImage)
        let context = try XCTUnwrap(CGContext(data: nil, width: 100, height: 50, bitsPerComponent: 8,
            bytesPerRow: 400, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo:
                CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(rendered, in: bounds)
        let pixels = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        let row = 25 * 400
        XCTAssertEqual(pixels[row + 49 * 4 + 3], 255)
        XCTAssertGreaterThan(Int(pixels[row + 46 * 4]), Int(pixels[row + 4 * 4]) + 20)
        XCTAssertLessThan(Int(pixels[row + 54 * 4]), Int(pixels[row + 95 * 4]) - 10)

        background.update(artworkURL: nil)
        XCTAssertNil(background.artwork)
        XCTAssertNotEqual(background.revision, revision)
    }

    @MainActor
    func testMetadataAndStoppedLyricsDoNotRequestPlaybackRateRendering() {
        let item = PlaybackItem(id: "sample", uri: "test:sample", title: "Sample", artists: [],
                                albumTitle: nil, duration: 12, isEpisode: false, isAdvertisement: false)
        let snapshot = PlaybackSnapshot(item: item, isPlaying: true, position: 1, duration: 12,
                                        device: nil, restrictions: .unrestricted, source: .nativeAudio, sampledAtUptime: 0)
        let producer = DesktopLyricsFrames(aspect: .singleLine)
        var frame = LyricsPlaybackFrame(snapshot: snapshot, position: 1, playing: true, seekRevision: 0,
                                        pending: nil, confirmation: nil, legacySeekPosition: nil)
        producer.render(frame: frame, lyrics: nil, revision: 0, offset: 0, configuration: .init(),
                        settings: .init(), animates: true)
        XCTAssertFalse(producer.needsPlaybackFrames)
        let lyrics = singleLineFixture()
        producer.render(frame: frame, lyrics: lyrics, revision: 1, offset: 0, configuration: .init(),
                        settings: .init(), animates: true)
        XCTAssertTrue(producer.needsPlaybackFrames)
        frame.playing = false
        producer.render(frame: frame, lyrics: lyrics, revision: 1, offset: 0, configuration: .init(),
                        settings: .init(), animates: true)
        XCTAssertFalse(producer.needsPlaybackFrames)
    }

    func testAdaptiveWindowExpandsForAdditionalVoicesThenSettlesBack() throws {
        var height = DesktopLyricsAdaptiveHeight()
        XCTAssertEqual(height.update(contentHeight: 32, at: 0), 44)
        XCTAssertEqual(height.update(contentHeight: 120, at: 1), 136)
        XCTAssertEqual(height.update(contentHeight: 178, at: 1.1), 208)
        XCTAssertEqual(height.update(contentHeight: 32, at: 2), 208)
        XCTAssertTrue(height.isSettling)
        XCTAssertEqual(height.update(contentHeight: 32, at: 2.4), 44)
        XCTAssertFalse(height.isSettling)
        XCTAssertEqual(height.update(contentHeight: 500, at: 3), 240)

        var settings = DesktopLyricsSettings()
        settings.fitsContent = true
        settings.alignment = .centered
        settings.aspect = .tall
        let restored = try JSONDecoder().decode(DesktopLyricsSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(restored, settings)
        XCTAssertEqual(restored.outputAspect, .tall)
    }

    func testScrollingStartsBothExitChannelsOnTheSelectorCatchUpFrame() throws {
        let records: [LyricsBlossomSelectionSchedule.Record] = [
            .init(index: 0, start: 0, end: 4.5, lastWordEnd: 4.5),
            .init(index: 1, start: 4.55, end: 8, lastWordEnd: 8)
        ]
        let catchUp = LyricsBlossomSelectionSchedule.dispatch(family: 2, now: 3.9, records: records,
            selected: [0], pending: 1, capacity: 2, mainHold: false, ticketHold: false, deadline: -1, adaptive: true)
        XCTAssertEqual(catchUp.catchUp, [0])
        XCTAssertNil(catchUp.enterIndex)
        var handoff = DesktopLyricsScrollHandoff()
        let selection = AMLLFrameEngine.desktopHandoff(for: catchUp, groupCount: 2)
        handoff.update(selection, at: 1, delta: 1.0 / 60, interlude: false, immediately: false)
        XCTAssertEqual(handoff.upcoming, 1)
        let start = try XCTUnwrap(handoff.departure(0, at: 1))
        XCTAssertLessThan(start.opacity, 1)
        XCTAssertGreaterThan(start.softness, 0)

        let later = try XCTUnwrap(handoff.departure(0, at: 1.08))
        handoff.update(selection, at: 1.08, delta: 1.0 / 60, interlude: false, immediately: false)
        XCTAssertEqual(handoff.departure(0, at: 1.08)?.opacity, later.opacity)
        XCTAssertLessThan(later.opacity, start.opacity)
        XCTAssertGreaterThan(later.softness, start.softness)
        XCTAssertEqual(handoff.departure(0, at: 1.3)?.opacity, 0)
        XCTAssertFalse(handoff.isAnimating(at: 1.3))
    }

    func testScrollingCutoffKeepsAlreadySelectedLyricAheadOfLaterPendingLyrics() throws {
        let cutoff = LyricsBlossomSelectionSchedule.Output(selected: [1], pending: 2, left: [0])
        let selection = AMLLFrameEngine.desktopHandoff(for: cutoff, groupCount: 3)
        var handoff = DesktopLyricsScrollHandoff()
        handoff.update(selection, at: 1, delta: 1.0 / 60, interlude: false, immediately: false)
        XCTAssertEqual(selection.selected, [1])
        XCTAssertNil(handoff.upcoming)
        XCTAssertNotNil(handoff.departure(0, at: 1))
        XCTAssertNil(handoff.departure(1, at: 1))

        let enter = LyricsBlossomSelectionSchedule.Output(selected: [1], pending: 2, catchUp: [0],
                                                          enterIndex: 1, entered: [1], left: [0])
        let combined = AMLLFrameEngine.desktopHandoff(for: enter, groupCount: 3)
        XCTAssertNil(combined.early)
        XCTAssertEqual(Set(combined.departing), [0])
    }

    @MainActor
    func testSingleLinePiPResizesTheVideoSampleWhenFontSizeChanges() {
        let item = PlaybackItem(id: "fit-text", uri: "test:fit-text", title: "Fit", artists: [],
                                albumTitle: nil, duration: 8, isEpisode: false, isAdvertisement: false)
        let snapshot = PlaybackSnapshot(item: item, isPlaying: false, position: 1, duration: 8,
                                        device: nil, restrictions: .unrestricted, source: .nativeAudio, sampledAtUptime: 0)
        let frame = LyricsPlaybackFrame(snapshot: snapshot, position: 1, playing: false, seekRevision: 0,
                                         pending: nil, confirmation: nil, legacySeekPosition: nil)
        let document = LyricsDocument(candidate: .init(source: .apple, sourceID: "fit-text", title: "", artists: []),
                                      lines: [.init(id: "row", text: "Fit", start: 0, end: 7)],
                                      language: "en", selectionReason: "Resize with font size")
        let producer = DesktopLyricsFrames(aspect: .singleLine)
        var settings = DesktopLyricsSettings()
        settings.fitsContent = true
        settings.fontSize = 16
        settings.singleLineTranslation = false
        settings.singleLineRomanization = false
        producer.render(frame: frame, lyrics: document, revision: 1, offset: 0, configuration: .init(),
                        settings: settings, animates: true)
        let small = producer.pixelSize
        settings.fontSize = 36
        producer.render(frame: frame, lyrics: document, revision: 1, offset: 0, configuration: .init(),
                        settings: settings, animates: true)
        XCTAssertLessThan(small.height, 96 * small.width / 320)
        XCTAssertEqual(producer.pixelSize.width, small.width)
        XCTAssertGreaterThan(producer.pixelSize.height, small.height)
        settings.fontSize = 16
        producer.render(frame: frame, lyrics: document, revision: 1, offset: 0, configuration: .init(),
                        settings: settings, animates: true)
        XCTAssertEqual(producer.pixelSize, small)
    }

    @MainActor
    func testDesktopCenterAlignmentMovesBothWordGeometryAndAuxiliary() throws {
        let line = LyricLine(id: "centered", text: "Hello", start: 0, end: 1,
                             words: [.init(text: "Hello", start: 0, end: 1)], translation: "Hi",
                             isDuet: true, precision: .word)
        let font = UIFont.systemFont(ofSize: 24)
        var configuration = LyricsRenderConfiguration()
        configuration.translation = true
        let right = AMLLCoreTextLayout(line: line, width: 260, font: font, configuration: configuration)
        let center = AMLLCoreTextLayout(line: line, width: 260, font: font,
                                        configuration: configuration, centered: true)
        let original = try XCTUnwrap(right.fragments.first)
        let moved = try XCTUnwrap(center.fragments.first)
        XCTAssertGreaterThan(original.rect.midX, moved.rect.midX)
        XCTAssertEqual(moved.rect.midX, 130, accuracy: 1)
        XCTAssertEqual(center.horizontalInkBounds.midX, 130, accuracy: 1)
        XCTAssertEqual(moved.word, original.word)
    }

    @MainActor
    func testScrollingViewportKeepsOverlappingMainAndBackgroundVoices() throws {
        let lines = [
            LyricLine(id: "lead", text: "Lead", start: 0, end: 6),
            LyricLine(id: "response", text: "Response", start: 2, end: 5, isBackground: true),
            LyricLine(id: "overlap", text: "Second lead", start: 3, end: 8)
        ]
        let document = LyricsDocument(candidate: .init(source: .apple, sourceID: "duet", title: "", artists: []),
                                      lines: lines, language: "en", selectionReason: "Overlapping voices")
        let bounds = CGRect(x: 0, y: 0, width: 320, height: 240)
        let canvas = AMLLNativeCanvas(frame: bounds)
        canvas.drivesFramesExternally = true
        let settings = DesktopLyricsSettings()
        canvas.configure(document: document, configuration: settings.rendererConfiguration(.init()),
                         input: .init(position: 3.5, playing: true), active: true,
                         reduceMotion: true, canSeek: false, desktopSettings: settings)
        let sample = LyricsPlaybackFrame(snapshot: nil, position: 3.5, playing: true, seekRevision: 0,
                                         pending: nil, confirmation: nil, legacySeekPosition: nil)
        _ = canvas.advanceExportFrame(sample: sample, delta: 0)
        let state = try XCTUnwrap(canvas.frameState)
        XCTAssertEqual(Set(state.rows.filter { $0.active && !$0.hidden }.map(\.lineIndex)), [0, 1, 2])
        XCTAssertEqual(canvas.visibleRowCount, 3)
        XCTAssertGreaterThan(canvas.exportScrollingBounds.height, 50)
    }

    @MainActor
    func testNativeInterludeDrawsInSingleLineExport() throws {
        let lines = [
            LyricLine(id: "before", text: "Before", start: 0, end: 1),
            LyricLine(id: "after", text: "After", start: 10, end: 11)
        ]
        let document = LyricsDocument(candidate: .init(source: .apple, sourceID: "gap", title: "", artists: []),
                                      lines: lines, language: "en", selectionReason: "Interlude")
        let canvas = AMLLNativeCanvas(frame: CGRect(x: 0, y: 0, width: 320, height: 128))
        canvas.drivesFramesExternally = true
        var settings = DesktopLyricsSettings()
        settings.mode = .singleLine
        settings.alignment = .centered
        canvas.configure(document: document, configuration: settings.rendererConfiguration(.init()),
                         input: .init(position: 2, playing: true), active: true,
                         reduceMotion: false, canSeek: false, desktopSettings: settings)
        var sample = LyricsPlaybackFrame(snapshot: nil, position: 2, playing: true, seekRevision: 0,
                                         pending: nil, confirmation: nil, legacySeekPosition: nil)
        _ = canvas.advanceExportFrame(sample: sample, delta: 0)
        sample.position = 3
        _ = canvas.advanceExportFrame(sample: sample, delta: 1 / 60)
        XCTAssertNotNil(canvas.frameState?.interlude)
        XCTAssertEqual(canvas.visibleRowCount, 0)
        let dots = canvas.exportScrollingBounds
        XCTAssertFalse(dots.isNull)
        XCTAssertEqual(dots.midX, canvas.bounds.midX, accuracy: 1)
        XCTAssertEqual(dots.midY, canvas.bounds.midY, accuracy: 1)
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
