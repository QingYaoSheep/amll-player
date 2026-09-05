@testable import AMLLPlayer
import SwiftUI
import UIKit
import XCTest

@MainActor
final class LyricsRenderViewTests: XCTestCase {
    func testWordLayoutPreservesComposedCharactersAndWrapsLongWords() {
        let text = "e\u{301} 👩🏽‍🚀 " + String(repeating: "長", count: 60)
        let line = LyricLine(id: "unicode", text: text, start: 0, end: 10,
                             words: [LyricWord(text: text, start: 0, end: 10)], precision: .word)
        let layout = LyricTextLayout(line: line, width: 180, configuration: .init(), traits: UITraitCollection())
        XCTAssertGreaterThan(layout.fragments.count, 1)
        XCTAssertEqual(layout.fragments.first?.lower, 0)
        XCTAssertEqual(layout.fragments.last?.upper, 1)
        XCTAssertTrue(layout.fragments.allSatisfy { $0.rect.width > 0 && $0.rect.maxX <= 181 })
        let large = LyricTextLayout(line: line, width: 180, configuration: .init(),
                                    traits: UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge))
        XCTAssertGreaterThan(large.size.height, layout.size.height)
    }

    func testMixedDirectionWordsUseTheirGlyphDirection() {
        let line = LyricLine(id: "bidi", text: "Hello مرحبا", start: 0, end: 5,
                             words: [LyricWord(text: "Hello", start: 0, end: 2), LyricWord(text: "مرحبا", start: 2, end: 5)], precision: .word)
        let layout = LyricTextLayout(line: line, width: 350, configuration: .init(), traits: UITraitCollection())
        XCTAssertTrue(layout.fragments.contains { $0.start == 0 && !$0.rtl })
        XCTAssertTrue(layout.fragments.contains { $0.start == 2 && $0.rtl })
    }

    func testLinePrecisionDoesNotManufactureWordFragments() {
        let line = LyricLine(id: "lrc", text: "Line lyric", start: 0, end: 5,
                             words: [LyricWord(text: "Line lyric", start: 0, end: 5)], precision: .line)
        let layout = LyricTextLayout(line: line, width: 300, configuration: .init(), traits: UITraitCollection())
        XCTAssertTrue(layout.fragments.isEmpty)
    }

    func testCompletedWordHasFullMaskAndBackwardSeekRestoresGradient() throws {
        let line = LyricLine(id: "word", text: "Held", start: 0, end: 10,
                             words: [LyricWord(text: "Held", start: 0, end: 5)], precision: .word)
        let layout = LyricTextLayout(line: line, width: 300, configuration: .init(), traits: UITraitCollection())
        let row = LyricRowView(frame: CGRect(origin: .zero, size: layout.size))
        row.configure(line: line, layout: layout, scale: 2, configuration: .init(), blur: false, canSeek: false) {}
        let piece = try XCTUnwrap(row.layer.sublayers?.last)
        row.update(time: 6, active: true, configuration: .init(), policy: .resolve(maximumFPS: 60, reduceMotion: true), reduceMotion: true)
        XCTAssertNil(piece.mask)
        row.update(time: 2, active: true, configuration: .init(), policy: .resolve(maximumFPS: 60, reduceMotion: true), reduceMotion: true)
        XCTAssertNotNil(piece.mask)
        XCTAssertEqual(piece.opacity, 1)
        row.update(time: 11, active: false, configuration: .init(), policy: .resolve(maximumFPS: 60, reduceMotion: true), reduceMotion: true)
        XCTAssertEqual(piece.opacity, 0)
    }

    func testVoiceOverHonorsVisibilityAndDeviceSeekCapability() {
        let line = LyricLine(id: "voice", text: "Main", start: 0, end: 5, translation: "Translation", romanization: "Romanization")
        var config = LyricsRenderConfiguration()
        config.translation = false
        let layout = LyricTextLayout(line: line, width: 300, configuration: config, traits: UITraitCollection())
        let row = LyricRowView()
        var seeks = 0
        row.configure(line: line, layout: layout, scale: 2, configuration: config, blur: false, canSeek: false) { seeks += 1 }
        XCTAssertEqual(row.accessibilityLabel, "Main, Romanization")
        XCTAssertFalse(row.accessibilityActivate())
        XCTAssertEqual(seeks, 0)
        row.setCanSeek(true)
        XCTAssertTrue(row.accessibilityActivate())
        XCTAssertEqual(seeks, 1)
    }

    func testLongSongReusesVisibleRowsAndBoundedLayoutsAcrossSeeks() {
        let view = LyricsRenderView(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        var time = 5.0
        view.position = { time }
        for sample in stride(from: 5.0, through: 1790.0, by: 30) {
            time = sample
            update(view, reduceMotion: true)
            view.layoutIfNeeded()
            XCTAssertLessThanOrEqual(view.cachedLayoutCount, 48)
            XCTAssertLessThan(view.visibleRowCount, 20)
        }
        XCTAssertGreaterThan(view.contentOffset, 0)
        time = 5
        update(view, reduceMotion: true)
        XCTAssertEqual(view.contentOffset, 0, accuracy: 1)
    }

    func testCapabilityChangePreservesManualBrowsingAndStopReleasesDisplayLink() throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let controller = UIViewController()
        window.rootViewController = controller
        window.isHidden = false
        defer { window.isHidden = true }
        let view = LyricsRenderView(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        controller.view.addSubview(view)
        view.position = { 60 }
        update(view, playing: true)
        view.layoutIfNeeded()
        XCTAssertTrue(view.isDisplayLinkRunning)
        let scroll = try XCTUnwrap(view.subviews.compactMap { $0 as? UIScrollView }.first)
        view.scrollViewWillBeginDragging(scroll)
        scroll.contentOffset.y = 200
        let offset = view.contentOffset
        update(view, canSeek: false, playing: true)
        view.layoutIfNeeded()
        XCTAssertFalse(view.isFollowing)
        XCTAssertEqual(view.contentOffset, offset)
        update(view, active: false)
        XCTAssertFalse(view.isDisplayLinkRunning)
        view.removeFromSuperview()
        XCTAssertFalse(view.isDisplayLinkRunning)
    }

    func testPausedResumeTravelsBackToCurrentLineWithoutSeek() throws {
        let view = LyricsRenderView(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        view.position = { 5 }
        var seeks = 0
        view.seek = { _ in seeks += 1 }
        update(view)
        view.layoutIfNeeded()
        let scroll = try XCTUnwrap(view.subviews.compactMap { $0 as? UIScrollView }.first)
        view.scrollViewWillBeginDragging(scroll)
        scroll.contentOffset.y = 800
        view.resumeFollowing()
        for _ in 0 ..< 180 {
            update(view)
        }
        XCTAssertTrue(view.isFollowing)
        XCTAssertEqual(view.contentOffset, 0, accuracy: 0.3)
        XCTAssertEqual(seeks, 0)
    }

    func testFixedTimelineImagesForVisualReview() {
        let view = LyricsRenderView(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        for time in [2.5, 6.5, 18, 26] {
            view.position = { time }
            update(view, reduceMotion: true)
            view.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: view.bounds).image { context in
                UIColor(white: 0.08, alpha: 1).setFill()
                context.fill(view.bounds)
                view.layer.render(in: context.cgContext)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = "Plan5-390x700-time-\(time)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    func testStaticCoverImagesForVisualReview() throws {
        for size in [CGSize(width: 390, height: 844), CGSize(width: 844, height: 390)] {
            for blur in [0.0, 40.0] {
                let renderer = ImageRenderer(content:
                    AlbumArtworkBackground(url: nil, blur: blur, previewImage: Image(uiImage: LyricsRenderFixture.cover))
                        .frame(width: size.width, height: size.height))
                renderer.scale = 1
                let image = try XCTUnwrap(renderer.uiImage)
                XCTAssertEqual(image.size, size)
                let attachment = XCTAttachment(image: image)
                attachment.name = "Plan5-cover-\(Int(size.width))x\(Int(size.height))-blur-\(Int(blur))"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }

    private func update(_ view: LyricsRenderView, canSeek: Bool = true, playing: Bool = false,
                        active: Bool = true, reduceMotion: Bool = false)
    {
        view.update(document: LyricsRenderFixture.document, configuration: .init(), offset: 0, duration: 1800,
                    playing: playing, active: active, canSeek: canSeek, reduceMotion: reduceMotion, resumeToken: 0)
    }
}
