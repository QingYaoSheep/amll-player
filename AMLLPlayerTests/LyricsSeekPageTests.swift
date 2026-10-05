@testable import AMLLPlayer
import AVFoundation
import SwiftUI
import UIKit
import XCTest

@MainActor final class LyricsSeekPageTests: XCTestCase {
    func testQuickSettingsKeepNativeAudioClockAndProductionCanvasRunning() async throws {
        let (model, player, song) = try await makeModel()
        let presentation = LyricsQuickSettingsPresentation()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        let host = UIHostingController(rootView: AMLLLyricsPlayer(model: model, presentation: presentation)
            .environment(\.scenePhase, .active))
        window.rootViewController = host; window.makeKeyAndVisible()
        host.loadViewIfNeeded(); host.view.frame = window.bounds; host.view.layoutIfNeeded()
        defer { player.pause(); model.netEasePlayback.deselect(); window.isHidden = true; window.rootViewController = nil }
        try await start(model, song)
        try await wait("native audio is advancing") { player.currentTime().seconds > 0.3 && model.playbackSnapshot?.isPlaying == true }
        let canvas = try await waitForCanvas(host.view)
        let item = try XCTUnwrap(player.currentItem)
        let previous = player.currentTime().seconds, revision = model.lyricsSeekRevision
        var frames: [AMLLFrameState] = []
        canvas.frameObserver = { frames.append($0) }
        presentation.open(reduceMotion: false)
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertTrue(presentation.isPresented)
        XCTAssertTrue(findCanvas(host.view) === canvas)
        XCTAssertTrue(player.currentItem === item)
        XCTAssertGreaterThan(player.rate, 0)
        XCTAssertGreaterThan(player.currentTime().seconds - previous, 0.4)
        XCTAssertGreaterThan(frames.count, 5)
        XCTAssertGreaterThan(try XCTUnwrap(frames.last).lyricTime - (try XCTUnwrap(frames.first).lyricTime), 0.3)
        XCTAssertEqual(model.lyricsSeekRevision, revision)
        XCTAssertEqual(model.progress(), player.currentTime().seconds, accuracy: 0.4)
        presentation.close(reduceMotion: false)
        try await Task.sleep(for: .milliseconds(500))
        canvas.frameObserver = nil
        XCTAssertFalse(presentation.isPresented)
        XCTAssertTrue(findCanvas(host.view) === canvas)
        XCTAssertTrue(player.currentItem === item)
        XCTAssertGreaterThan(player.rate, 0)
        let attachment = XCTAttachment(image: UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        })
        attachment.name = "Quick-settings-native-audio-continuity"; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testProductionLyricClickKeepsTheReturnSpringAndStagger() async throws {
        let (model, player, song) = try await makeModel()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        let host = UIHostingController(rootView: AMLLLyricsPlayer(model: model).environment(\.scenePhase, .active))
        window.rootViewController = host; window.makeKeyAndVisible()
        host.loadViewIfNeeded(); host.view.frame = window.bounds; host.view.layoutIfNeeded()
        defer { player.pause(); model.netEasePlayback.deselect(); window.isHidden = true; window.rootViewController = nil }
        try await start(model, song)
        try await wait("document and snapshot") { model.lyrics.document != nil && model.playbackSnapshot != nil }
        try await pauseFixture(model, player)
        await model.seek(to: 4.25)
        try await wait("initial seek") { abs(model.progress() - 4.25) < 1 }
        let canvas = try await waitForCanvas(host.view)
        try await wait("confirmed canvas settled") {
            canvas.frameState?.settled == true && abs((canvas.frameState?.lyricTime ?? 0) - 4.25) < 0.01
        }
        // Dispatch the same interactions as the production pan handler.
        canvas.handleInteraction(.beginBrowsing)
        canvas.handleInteraction(.browseBy(80))
        try await wait("dragged presentation") { canvas.frameState?.browsing == true }
        canvas.handleInteraction(.endBrowsing(velocity: 0))
        try await wait("browsed presentation") { canvas.frameState?.browsing == true }
        let before = try XCTUnwrap(canvas.frameState).rows
        let targetRow = try XCTUnwrap(descendants(canvas).first { $0.isAccessibilityElement && $0.accessibilityLabel?.contains("Marker 4") == true })
        var frames: [AMLLFrameState] = []
        canvas.frameObserver = { frames.append($0) }
        XCTAssertTrue(targetRow.accessibilityActivate(), "Activate the real production row callback")
        try await wait("clicked lyric confirmation") { model.progress() >= 16 && model.progress() < 17 && !model.isPerformingAction }
        try await Task.sleep(for: .milliseconds(1400))
        canvas.frameObserver = nil
        XCTAssertTrue(findCanvas(host.view) === canvas, "A seek must not replace the visible canvas")
        let confirmed = frames.filter { $0.lyricTime >= 16 && $0.lyricTime < 18 }
        XCTAssertGreaterThan(confirmed.count, 10, "CADisplayLink must animate after the actual click")
        let first = try XCTUnwrap(confirmed.first), last = try XCTUnwrap(confirmed.last)
        let initialY = before[4].y, finalY = last.rows[4].y
        XCTAssertGreaterThan(abs(initialY - finalY), 60)
        XCTAssertLessThan(abs(first.rows[4].y - initialY), abs(finalY - initialY) * 0.25, "First confirmed frame must retain the browsed presentation")
        XCTAssertGreaterThan(abs(first.rows[4].y - finalY), 30, "The click must not snap straight to the target")
        XCTAssertTrue(confirmed.contains { abs($0.rows[4].y - initialY) > 8 && abs($0.rows[4].y - finalY) > 8 })
        let focusStart = try XCTUnwrap(first.rows[4].positionMotion?.scheduledAt)
        let followingStart = try XCTUnwrap(first.rows[5].positionMotion?.scheduledAt)
        XCTAssertGreaterThan(followingStart, focusStart, "Following rows must retain the return action's stagger")
        print("[SEEK-V2] page frames=\(frames.count) first=\(first.rows[4].y) before=\(initialY) final=\(finalY)")
    }

    func testHiddenCanvasStartsAtTheLatestConfirmedAudioTime() async throws {
        let (model, player, song) = try await makeModel()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        let host = UIHostingController(rootView: AMLLLyricsPlayer(model: model).environment(\.scenePhase, .active))
        window.rootViewController = host; window.makeKeyAndVisible()
        host.loadViewIfNeeded(); host.view.frame = window.bounds; host.view.layoutIfNeeded()
        defer { player.pause(); model.netEasePlayback.deselect(); window.isHidden = true; window.rootViewController = nil }
        try await start(model, song)
        let old = try await waitForCanvas(host.view)
        try await pauseFixture(model, player)
        model.renderPreferences.configuration.showLyrics = false
        try await wait { findCanvas(host.view) == nil }
        await model.seek(to: 20.25, entry: .progress, trackURI: song.uri)
        XCTAssertEqual(player.currentTime().seconds, 20.25, accuracy: 0.1)
        model.renderPreferences.configuration.showLyrics = true
        let current = try await waitForCanvas(host.view)
        XCTAssertFalse(current === old)
        try await wait { current.frameState != nil }
        let frame = try XCTUnwrap(current.frameState)
        XCTAssertEqual(frame.lyricTime, model.progress(), accuracy: 0.15)
        let displayStart = AMLLDisplayDocument(lines: try XCTUnwrap(model.lyrics.document).lines).lines[5].start
        XCTAssertEqual(frame.rows[5].wordClock.time + displayStart, frame.lyricTime, accuracy: 0.1)
        XCTAssertFalse(frame.rows[5].fillComplete)
    }

    private func pauseFixture(_ model: AppModel, _ player: AVPlayer) async throws {
        // A buffering player's snapshot can say not playing even though play
        // is pending. Toggle would start it again rather than pause it.
        try await model.netEasePlayback.pause()
        try await wait("paused media and clock") {
            player.rate == 0 && model.playbackSnapshot?.isPlaying == false
                && abs(model.progress() - player.currentTime().seconds) < 0.01
        }
        print("[SEEK-V2] fixture paused media=\(player.currentTime().seconds) clock=\(model.progress())")
    }

    private func start(_ model: AppModel, _ song: MusicCatalogItem) async throws {
        model.prepare(); model.handleScenePhase(.active)
        // Let the real session stream install the account before starting media.
        try await Task.sleep(for: .seconds(1))
        print("[SEEK-V2] start connected=\(model.netEaseState.connected) active=\(model.catalog.active)")
        do { try await model.playCatalog(song) }
        catch {
            print("[SEEK-V2] start failed \(error) phases=\(PlaybackSeekDiagnostics.shared.events.map(\.phase))")
            throw error
        }
        try await wait("lyrics ready") { model.lyrics.document != nil && model.playbackSnapshot?.item != nil }
    }

    private func makeModel() async throws -> (AppModel, AVPlayer, MusicCatalogItem) {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "seek-markers", withExtension: "flac"))
        let session = NetEaseSession(api: SeekFixtureAPI(), store: SeekFixtureStore())
        try await session.importCookie("MUSIC_U=fixture-only")
        let defaults = UserDefaults(suiteName: "page-seek-" + UUID().uuidString)!
        let preferences = MusicSourcePreferences(defaults: defaults); preferences.selected = .netease
        let player = AVPlayer()
        let playback = NetEasePlayback(session: session, catalog: NetEaseCatalog(session: session), defaults: defaults,
                                       player: player, makeItem: { _ in NetEasePlayback.makeAudioItem(url) })
        let lyrics = LyricsCoordinator(providers: [SeekFixtureLyrics()], cache: MemoryLyricsCache(), settingsStore: LyricsSettingsStore(defaults: defaults))
        let model = AppModel(environment: .make(configuration: .preview), lyrics: lyrics,
                             renderPreferences: LyricsRenderPreferences(defaults: defaults), netEaseSession: session,
                             netEasePlayback: playback, musicPreferences: preferences)
        let song = try XCTUnwrap(NetEaseDecoder.item(SeekFixtureAPI.song, kind: .track))
        return (model, player, song)
    }
    private func wait(_ label: String = #function, _ condition: () -> Bool) async throws {
        for _ in 0..<500 { if condition() { return }; try await Task.sleep(for: .milliseconds(10)) }
        XCTFail("Production page state timed out: \(label)"); throw CancellationError()
    }
    private func waitForCanvas(_ root: UIView) async throws -> AMLLNativeCanvas {
        try await wait("mounted production canvas") {
            root.setNeedsLayout(); root.layoutIfNeeded(); return findCanvas(root) != nil
        }
        return try XCTUnwrap(findCanvas(root))
    }
    private func findCanvas(_ root: UIView) -> AMLLNativeCanvas? { descendants(root).compactMap { $0 as? AMLLNativeCanvas }.first }
    private func descendants(_ root: UIView) -> [UIView] { [root] + root.subviews.flatMap(descendants) }
}

@MainActor private final class SeekFixtureAPI: NetEaseRequesting {
    static let song: [String: Any] = ["id": 42, "name": "Markers", "dt": 48000]
    func send(_ path: String, _ parameters: [String: Any], cookie: String?) async throws -> NetEaseResponse {
        if path == "/w/nuser/account/get" { return .init(object: ["profile": ["userId": 1, "nickname": "Fixture"]]) }
        if path == "/v3/song/detail" { return .init(object: ["songs": [Self.song]]) }
        if path == "/song/enhance/player/url/v1" {
            return .init(object: ["data": [["id": 42, "code": 200, "url": "https://fixture.music.126.net/markers.flac", "level": "lossless"]]])
        }
        return .init(object: ["code": 200])
    }
}
private final class SeekFixtureLyrics: LyricsProvider, @unchecked Sendable {
    let source = LyricsSource.qq
    func search(track _: TrackIdentity, query _: String, settings _: LyricsSettings) async throws -> [LyricCandidate] {
        [.init(source: .qq, sourceID: "markers", title: "Markers", artists: [], score: 100)]
    }
    func lyrics(candidate _: LyricCandidate, settings _: LyricsSettings) async throws -> LyricsAssetBundle {
        let body = (0..<12).map { i in "<p begin=\"\(i * 4)s\" end=\"\(i * 4 + 3)s\"><span begin=\"\(i * 4)s\" end=\"\(i * 4 + 3)s\">Marker \(i)</span></p>" }.joined()
        return .init(format: .ttml, original: "<tt xmlns=\"http://www.w3.org/ns/ttml\"><body><div>" + body + "</div></body></tt>")
    }
}
