@testable import AMLLPlayer
import AVFoundation
import XCTest

@MainActor final class NetEaseSeekTests: XCTestCase {
    private func playback(_ player: ControlledSeekPlayer) async throws -> NetEasePlayback {
        let session = NetEaseSession(store: SeekMemoryStore())
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "Seek-\(UUID())"))
        let result = NetEasePlayback(session: session, catalog: NetEaseCatalog(session: session), defaults: defaults, player: player)
        let song = try XCTUnwrap(NetEaseDecoder.item(["id": 42, "name": "Seek", "dt": 32000], kind: .track))
        try await result.enqueue(song, next: false)
        return result
    }
    func testSeekDoesNotPublishIntermediateDecoderTimes() async throws {
        let player = ControlledSeekPlayer()
        let playback = try await playback(player)
        var snapshots: [PlaybackSnapshot] = []
        let reader = Task { for await snapshot in playback.playbackSnapshots { snapshots.append(snapshot) } }
        defer { reader.cancel() }
        for _ in 0..<20 { await Task.yield() }
        let work = Task { try await playback.seek(to: 4) }
        for _ in 0..<100 where !player.pending { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(player.pending)
        player.setTime(1) // A temporary decoder time before AVFoundation confirms the exact seek.
        try await playback.refresh()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertFalse(snapshots.contains { $0.position == 1 }, "Unconfirmed decoder times must not scroll the lyric timeline")
        let waiting = try XCTUnwrap(snapshots.last)
        XCTAssertEqual(waiting.position, 12)
        XCTAssertFalse(waiting.isPlaying)
        XCTAssertEqual(PlayerClock(anchor: waiting).position(at: waiting.sampledAtUptime + 2), 12, accuracy: 0.001)
        player.complete(at: 4, finished: true)
        try await work.value
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(snapshots.last?.position, 4)
        XCTAssertEqual(snapshots.last?.positionRevision, 1)
    }
    func testCancelledAVFoundationSeekCannotAcknowledgeRequestedTime() async throws {
        let player = ControlledSeekPlayer()
        let playback = try await playback(player)
        var snapshots: [PlaybackSnapshot] = []
        let reader = Task { for await snapshot in playback.playbackSnapshots { snapshots.append(snapshot) } }
        defer { reader.cancel() }
        let work = Task { try await playback.seek(to: 4) }
        for _ in 0..<100 where !player.pending { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(player.pending)
        player.complete(at: 12, finished: false)
        do { try await work.value; XCTFail("An interrupted seek must not be reported as successful") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        try await playback.refresh()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(snapshots.last?.positionRevision, 0)
        XCTAssertEqual(snapshots.last?.position, 12)
    }
    func testSeekPublishesActualLandedTimeRatherThanAssumedTarget() async throws {
        let player = ControlledSeekPlayer()
        let playback = try await playback(player)
        var snapshots: [PlaybackSnapshot] = []
        let reader = Task { for await value in playback.playbackSnapshots { snapshots.append(value) } }
        defer { reader.cancel() }
        let work = Task { try await playback.seek(to: 4) }
        for _ in 0..<100 where !player.pending { try await Task.sleep(for: .milliseconds(10)) }
        player.complete(at: 4.125, finished: true)
        try await work.value
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(snapshots.last?.position, 4.125)
        XCTAssertEqual(playback.queue.position, 4.125)
        XCTAssertEqual(snapshots.last?.positionRevision, 1)
    }
    func testSourceDepartureRejectsLateSeekCompletionAndReleasesSampling() async throws {
        let player = ControlledSeekPlayer(), playback = try await playback(player)
        var snapshots: [PlaybackSnapshot] = []
        let reader = Task { for await value in playback.playbackSnapshots { snapshots.append(value) } }
        defer { reader.cancel() }
        let work = Task { try await playback.seek(to: 4) }
        for _ in 0..<100 where !player.pending { try await Task.sleep(for: .milliseconds(10)) }
        playback.deselect()
        for _ in 0..<20 { await Task.yield() }
        let count = snapshots.count
        player.complete(at: 4, finished: true)
        do { try await work.value; XCTFail("A departed service must reject the old completion") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(snapshots.count, count)
        XCTAssertEqual(snapshots.last?.positionRevision, 0)
        try await playback.refresh()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertGreaterThan(snapshots.count, count, "Cancellation must release the snapshot gate")
    }
}

private final class SeekMemoryStore: SpotifySessionDataStoring, @unchecked Sendable {
    func load() throws -> Data? { nil }
    func save(_: Data) throws {}
    func remove() throws {}
}

nonisolated private final class ControlledSeekPlayer: AVPlayer, @unchecked Sendable {
    private let lock = NSLock()
    private var time = 12.0
    private var completion: (@Sendable (Bool) -> Void)?
    private let item = AVPlayerItem(url: URL(fileURLWithPath: "/unneeded-audio-fixture"))
    override var currentItem: AVPlayerItem? { item }
    override func currentTime() -> CMTime { lock.lock(); defer { lock.unlock() }; return CMTime(seconds: time, preferredTimescale: 600) }
    var pending: Bool { lock.lock(); defer { lock.unlock() }; return completion != nil }
    func setTime(_ value: Double) { lock.lock(); time = value; lock.unlock() }
    override func seek(to time: CMTime, toleranceBefore: CMTime, toleranceAfter: CMTime, completionHandler: @escaping @Sendable (Bool) -> Void) {
        lock.lock(); completion = completionHandler; lock.unlock()
    }
    func complete(at value: Double, finished: Bool) {
        lock.lock(); time = value; let handler = completion; completion = nil; lock.unlock()
        handler?(finished)
    }
}
