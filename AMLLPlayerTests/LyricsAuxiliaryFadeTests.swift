@testable import AMLLPlayer
import UIKit
import XCTest

@MainActor final class LyricsAuxiliaryFadeTests: XCTestCase {
    func testOutgoingSlotSurvivesFadeAndReversalContinuesFromCurrentAlpha() {
        let fade = LyricsAuxiliaryFade()
        defer { fade.cancel() }
        var config = LyricsRenderConfiguration()
        config.translation = true; config.romanization = true
        fade.reset(config)
        config.translation = false
        fade.update(config, animated: true, now: 10)
        let middle = fade.value(.translation, now: 10.07)
        XCTAssertGreaterThan(middle, 0); XCTAssertLessThan(middle, 1)
        XCTAssertEqual(fade.value(.romanization, now: 10.07), 1)
        XCTAssertTrue(fade.layoutConfiguration(config, now: 10.19).translation)
        XCTAssertFalse(fade.layoutConfiguration(config, now: 10.21).translation)
        config.translation = true
        fade.update(config, animated: true, now: 10.07)
        XCTAssertEqual(fade.value(.translation, now: 10.07), middle, accuracy: 0.000001)
        XCTAssertEqual(fade.value(.translation, now: 10.3), 1)
    }

    func testInterleavedTogglesDoNotRestartTheOtherKindsDeadline() {
        let fade = LyricsAuxiliaryFade(); defer { fade.cancel() }
        var config = LyricsRenderConfiguration(); config.translation = true; config.romanization = true
        fade.reset(config)
        config.translation = false; fade.update(config, animated: true, now: 10)
        let before = fade.value(.translation, now: 10.1)
        config.romanization = false; fade.update(config, animated: true, now: 10.1)
        XCTAssertEqual(fade.value(.translation, now: 10.1), before, accuracy: 0.000001)
        XCTAssertFalse(fade.layoutConfiguration(config, now: 10.21).translation)
        XCTAssertTrue(fade.layoutConfiguration(config, now: 10.21).romanization)
        XCTAssertFalse(fade.layoutConfiguration(config, now: 10.31).romanization)
    }

    func testHighBlurRemovesAuxiliaryHaloBeforeFilteringAndPreservesMainPixels() async throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = false
        func image(auxiliary: Bool) throws -> CGImage {
            let rendered = UIGraphicsImageRenderer(size: CGSize(width: 80, height: 100), format: format).image { renderer in
                renderer.cgContext.setFillColor(UIColor.white.cgColor)
                renderer.cgContext.fill(CGRect(x: 10, y: 10, width: 20, height: 20))
                if auxiliary { renderer.cgContext.fill(CGRect(x: 10, y: 60, width: 20, height: 10)) }
            }
            return try XCTUnwrap(rendered.cgImage)
        }
        let source = try image(auxiliary: true), main = try image(auxiliary: false)
        let regions: [LyricsAuxiliaryKind: [CGRect]] = [.translation: [CGRect(x: 0, y: 60, width: 80, height: 10)]]
        let beforeValue = await LyricsAuxiliaryBlurDecoder.shared.decode(.raster(source, scale: 1, regions: regions), hidden: [], maximum: 12)
        let afterValue = await LyricsAuxiliaryBlurDecoder.shared.decode(.raster(source, scale: 1, regions: regions), hidden: [.translation], maximum: 12)
        let referenceValue = await LyricsAuxiliaryBlurDecoder.shared.decode(.raster(main, scale: 1, regions: [:]), hidden: [], maximum: 12)
        let before = try XCTUnwrap(beforeValue), after = try XCTUnwrap(afterValue), reference = try XCTUnwrap(referenceValue)
        XCTAssertEqual(after.far.pngData(), reference.far.pngData(), "Erase only source annotation pixels, then blur; primary blur and auxiliary tails must match a main-only reference")

        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow
        let window = UIWindow(windowScene: scene); window.frame = scene.coordinateSpace.bounds
        window.rootViewController = UIViewController(); window.makeKeyAndVisible()
        window.rootViewController?.view.backgroundColor = .black
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 80, height: 100))
        window.rootViewController?.view.addSubview(view)
        let near = CALayer(), far = CALayer(); near.opacity = 0
        view.layer.addSublayer(near); view.layer.addSublayer(far)
        let presentation = LyricsAuxiliaryBlurPresentation(near: near, far: far)
        let fade = LyricsAuxiliaryFade()
        var config = LyricsRenderConfiguration(); config.translation = true; fade.reset(config)
        presentation.install(before, source: .raster(source, scale: 1, regions: regions), size: view.bounds.size, fade: fade)
        defer { fade.cancel(); window.isHidden = true; previous?.makeKey() }
        try await Task.sleep(for: .milliseconds(30))
        let initial = try pixels(view)
        config.translation = false; fade.update(config, animated: true); presentation.update(fade)
        try await Task.sleep(for: .milliseconds(55))
        let middle = try pixels(view)
        XCTAssertEqual(middle.0, initial.0, accuracy: 3, "The common main-glyph blur must not dim during the texture dissolve")
        XCTAssertGreaterThan(initial.1, middle.1)
        try await Task.sleep(for: .milliseconds(220))
        XCTAssertLessThan(try pixels(view).1, 2, "No auxiliary halo may survive outside the old typographic box")
    }

    func testRealMaskFadesAuxiliaryPixelsWithoutFadingTheMainTextPlane() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = UIViewController(); window.makeKeyAndVisible()
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 80, height: 100))
        view.backgroundColor = .white; window.rootViewController?.view.backgroundColor = .black
        window.rootViewController?.view.addSubview(view)
        let fade = LyricsAuxiliaryFade()
        defer { fade.cancel(); window.isHidden = true; previous?.makeKey() }
        var config = LyricsRenderConfiguration(); config.translation = true
        fade.reset(config)
        config.translation = false; fade.update(config, animated: true)
        view.layer.mask = fade.mask(bounds: view.bounds, regions: [.translation: [CGRect(x: 0, y: 60, width: 80, height: 40)]])
        try await Task.sleep(for: .milliseconds(55))
        let first = try pixels(view)
        XCTAssertGreaterThan(first.0, 250, "Body pixels remain opaque")
        XCTAssertGreaterThan(first.1, 0); XCTAssertLessThan(first.1, 250, "The outgoing annotation has an intermediate alpha")
        try await Task.sleep(for: .milliseconds(220))
        let last = try pixels(view)
        XCTAssertGreaterThan(last.0, 250); XCTAssertLessThan(last.1, 2)
    }

    func testIncomingBlurUsesIndependentAnimatedPlanesForBothRasterizers() async throws {
        var line = LyricLine(id: "incoming", text: "Main", start: 0, end: 4)
        line.translation = "Translation"; line.romanization = "Romanization"
        var config = LyricsRenderConfiguration(); config.translation = true; config.romanization = true
        let core = AMLLCoreTextLayout(line: line, width: 200, font: .systemFont(ofSize: 24), configuration: config)
        let legacy = LyricTextLayout(line: line, width: 200, configuration: config, traits: .init())
        let sources: [LyricsAuxiliaryBlurSource] = [
            .coreText(core.rasterSnapshot(), hideRomanization: false),
            .raster(try XCTUnwrap(legacy.image(scale: 1).cgImage), scale: 1, regions: legacy.auxiliaryRegions),
        ]
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow
        let window = UIWindow(windowScene: scene); window.frame = scene.coordinateSpace.bounds
        window.rootViewController = UIViewController(); window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKey() }
        for source in sources {
            let normalValue = await LyricsAuxiliaryBlurDecoder.shared.decode(source, hidden: [], maximum: 12)
            let normal = try XCTUnwrap(normalValue)
            let host = UIView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
            let near = CALayer(), far = CALayer()
            host.layer.addSublayer(near); host.layer.addSublayer(far)
            window.rootViewController?.view.addSubview(host)
            let presentation = LyricsAuxiliaryBlurPresentation(near: near, far: far)
            let fade = LyricsAuxiliaryFade()
            config.translation = false; config.romanization = false; fade.reset(config)
            config.translation = true; config.romanization = true; fade.update(config, animated: true)
            presentation.install(normal, source: source, size: CGSize(width: 200, height: 160), fade: fade)
            XCTAssertNil(far.contents, "Do not publish a full incoming bitmap while separated planes are being prepared")
            var alphas: [Float] = []
            var interleaved = false
            for _ in 0 ..< 30 {
                try await Task.sleep(for: .milliseconds(8))
                if let layer = far.sublayers?.first(where: { $0.name == "auxiliaryBlur.translation" }), let shown = layer.presentation() {
                    alphas.append(shown.opacity)
                    if !interleaved, shown.opacity > 0, shown.opacity < 0.99 {
                        let duration = layer.animation(forKey: "auxiliaryVisibility")?.duration
                        config.romanization = false; fade.update(config, animated: true); presentation.update(fade)
                        XCTAssertEqual(layer.animation(forKey: "auxiliaryVisibility")?.duration, duration,
                            "Changing romanization must not restart the translation plane")
                        interleaved = true
                    }
                }
                presentation.update(fade)
            }
            XCTAssertTrue(alphas.contains { $0 > 0 && $0 < 0.99 }, "Blurred incoming annotation needs actual intermediate frames: \(alphas)")
            fade.cancel(); host.removeFromSuperview()
        }
    }

    func testRetainedBlurSurvivesDelayedIncomingPreparation() async throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = false
        func image(auxiliary: Bool) throws -> CGImage {
            try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 80, height: 100), format: format).image { renderer in
                renderer.cgContext.setFillColor(UIColor.white.cgColor)
                renderer.cgContext.fill(CGRect(x: 10, y: 10, width: 20, height: 20))
                if auxiliary { renderer.cgContext.fill(CGRect(x: 10, y: 60, width: 20, height: 10)) }
            }.cgImage)
        }
        let mainSource = LyricsAuxiliaryBlurSource.raster(try image(auxiliary: false), scale: 1, regions: [:])
        let fullSource = LyricsAuxiliaryBlurSource.raster(try image(auxiliary: true), scale: 1,
            regions: [.translation: [CGRect(x: 0, y: 60, width: 80, height: 10)]])
        let oldValue = await LyricsAuxiliaryBlurDecoder.shared.decode(mainSource, hidden: [], maximum: 12)
        let newValue = await LyricsAuxiliaryBlurDecoder.shared.decode(fullSource, hidden: [], maximum: 12)
        let old = try XCTUnwrap(oldValue), new = try XCTUnwrap(newValue)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow
        let window = UIWindow(windowScene: scene); window.frame = scene.coordinateSpace.bounds
        window.rootViewController = UIViewController(); window.makeKeyAndVisible()
        window.rootViewController?.view.backgroundColor = .black
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 80, height: 100))
        window.rootViewController?.view.addSubview(view)
        let near = CALayer(), far = CALayer(); near.opacity = 0
        view.layer.addSublayer(near); view.layer.addSublayer(far)
        let original = LyricsAuxiliaryBlurPresentation(near: near, far: far)
        let fade = LyricsAuxiliaryFade()
        var config = LyricsRenderConfiguration(); config.translation = false; fade.reset(config)
        defer { fade.cancel(); window.isHidden = true; previous?.makeKey() }
        original.install(old, source: mainSource, size: view.bounds.size, fade: fade)
        try await Task.sleep(for: .milliseconds(30))
        let before = try pixels(view)
        let starter = try XCTUnwrap(original.snapshot(origin: .zero))
        let replacement = LyricsAuxiliaryBlurPresentation(near: near, far: far)
        replacement.decode = { source, maximum in
            try? await Task.sleep(for: .milliseconds(120))
            return await LyricsAuxiliaryBlurDecoder.shared.split(source, maximum: maximum)
        }
        config.translation = true; fade.update(config, animated: true)
        replacement.showStarter(starter, origin: .zero)
        replacement.install(new, source: fullSource, size: view.bounds.size, fade: fade)
        try await Task.sleep(for: .milliseconds(55))
        let held = try pixels(view)
        XCTAssertEqual(held.0, before.0, accuracy: 2, "Keep the previous main blur while the new body texture is prepared")
        XCTAssertLessThan(held.1, 2, "The incoming annotation must not appear before preparation")
        try await Task.sleep(for: .milliseconds(250))
        let final = try pixels(view)
        XCTAssertEqual(final.0, before.0, accuracy: 3)
        XCTAssertGreaterThan(final.1, held.1)
    }

    func testProductionCanvasRetainsOutgoingLayoutAndBothWordClocks() async throws {
        var line = LyricLine(id: "one", text: "Hello", start: 0, end: 5,
            words: [.init(text: "Hello", start: 0, end: 5)], precision: .word)
        line.translation = "你好"; line.romanization = "ni hao"
        let document = LyricsDocument(candidate: .init(source: .apple, sourceID: "aux-fade", title: "Fade", artists: []),
            lines: [line], language: "en", selectionReason: "UI visibility regression")
        let canvas = AMLLNativeCanvas(frame: CGRect(x: 0, y: 0, width: 402, height: 700))
        let window = UIWindow(frame: canvas.frame); window.addSubview(canvas); window.isHidden = false
        defer { canvas.stop(); window.isHidden = true }
        canvas.position = { 1 }
        var config = LyricsRenderConfiguration(); config.translation = true; config.romanization = true
        let input = AMLLPlayerInput(position: 1, playing: false)
        canvas.configure(document: document, configuration: config, input: input, active: true, reduceMotion: false)
        canvas.layoutIfNeeded(); canvas.advanceFrame(delta: 0)
        let builds = canvas.layoutBuildCount
        let before = try XCTUnwrap(canvas.frameState)
        config.translation = false; config.romanization = false
        canvas.configure(document: document, configuration: config, input: input, active: true, reduceMotion: false)
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(canvas.layoutBuildCount, builds, "Outgoing text must not be removed before its fade")
        try await Task.sleep(for: .milliseconds(260))
        canvas.layoutIfNeeded(); canvas.advanceFrame(delta: 0)
        XCTAssertGreaterThan(canvas.layoutBuildCount, builds)
        let after = try XCTUnwrap(canvas.frameState)
        XCTAssertEqual(after.lyricTime, before.lyricTime)
        XCTAssertEqual(after.rows.first?.wordClock.time, before.rows.first?.wordClock.time)
        XCTAssertEqual(after.rows.first?.fillComplete, before.rows.first?.fillComplete)
    }

    private func pixels(_ view: UIView) throws -> (Double, Double) {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: view.bounds.size, format: format).image { _ in
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
        let cg = try XCTUnwrap(image.cgImage)
        func red(_ y: Int) throws -> Double {
            var values = [UInt8](repeating: 0, count: 4)
            try values.withUnsafeMutableBytes { storage in
                let context = try XCTUnwrap(CGContext(data: storage.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                    bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.draw(try XCTUnwrap(cg.cropping(to: CGRect(x: 20, y: y, width: 1, height: 1))), in: CGRect(x: 0, y: 0, width: 1, height: 1))
            }
            return Double(values[0])
        }
        return try (red(20), red(80))
    }
}
