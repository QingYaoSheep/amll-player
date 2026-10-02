@testable import AMLLPlayer
import AVFoundation
import MediaToolbox
import XCTest

/// Uses decoded PCM from the actual AVPlayerItem, never a player that sets its own time.
@MainActor final class NetEaseDecodedSeekTests: XCTestCase {
    func testRealDecoderLandsOnTheRequestedAudioMarker() async throws {
        for ext in ["mp3", "m4a", "flac"] {
            let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "seek-markers", withExtension: ext))
            let item = AVPlayerItem(url: url)
            let tracks = try await item.asset.loadTracks(withMediaType: .audio)
            let probe = DecodedAudioProbe()
            let parameters = AVMutableAudioMixInputParameters(track: try XCTUnwrap(tracks.first))
            parameters.audioTapProcessor = try probe.makeTap()
            let mix = AVMutableAudioMix(); mix.inputParameters = [parameters]; item.audioMix = mix
            let player = AVPlayer(playerItem: item)
            let session = NetEaseSession(store: SeekFixtureStore())
            let playback = NetEasePlayback(session: session, catalog: NetEaseCatalog(session: session),
                                           defaults: UserDefaults(suiteName: "decoded-seek-" + UUID().uuidString)!, player: player)
            let song = try XCTUnwrap(NetEaseDecoder.item(["id": 42, "name": "Markers", "dt": 48000], kind: .track))
            try await playback.enqueue(song, next: false)
            defer { player.pause(); player.replaceCurrentItem(with: nil) }
            try MusicAudioSession.acquirePlayback()
            player.play()
            for _ in 0..<200 where item.status != .readyToPlay { try await Task.sleep(for: .milliseconds(25)) }
            XCTAssertEqual(item.status, .readyToPlay)
            for target in [8.25, 20.25, 4.25, 36.25] {
                player.pause()
                try await playback.seek(to: target)
                XCTAssertEqual(player.currentTime().seconds, target, accuracy: 0.1, ext)
                probe.clear(); player.play()
                for _ in 0..<200 where probe.samples.filter { $0.time >= target - 0.05 && $0.frequency > 100 }.count < 3 { try await Task.sleep(for: .milliseconds(10)) }
                player.pause()
                let samples = probe.samples
                XCTAssertFalse(samples.isEmpty, "Decoded audio tap must receive real PCM: " + ext)
                let expected = 320 + floor(target / 2) * 80
                let audible = samples.filter { $0.time >= target - 0.05 && $0.time < target + 0.5 && $0.frequency > 100 }.map(\.frequency).sorted()
                XCTAssertFalse(audible.isEmpty, "Decoded non-silent target samples required: " + ext)
                if let median = audible.dropFirst(audible.count / 2).first {
                    XCTAssertEqual(median, expected, accuracy: 45, "The audible marker must agree with the seek, not just currentTime: " + ext + " target " + String(target))
                }
                print("[SEEK-V2] codec=\(ext) target=\(target) media=\(player.currentTime().seconds) decoded=\(samples.map { "\($0.time):\($0.frequency)" })")
            }
        }
    }
}

final class SeekFixtureStore: SpotifySessionDataStoring, @unchecked Sendable {
    func load() throws -> Data? { nil }
    func save(_: Data) throws {}
    func remove() throws {}
}

nonisolated final class DecodedAudioProbe: @unchecked Sendable {
    struct Sample: Sendable { let time: Double; let frequency: Double }
    private let lock = NSLock()
    private var values: [Sample] = []
    private var sampleRate = 44100.0
    private var isFloat = true
    var samples: [Sample] { lock.lock(); defer { lock.unlock() }; return values }
    func clear() { lock.lock(); values.removeAll(); lock.unlock() }
    func makeTap() throws -> MTAudioProcessingTap {
        var callbacks = MTAudioProcessingTapCallbacks(version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: Unmanaged.passRetained(self).toOpaque(),
            init: { _, info, storage in storage.pointee = info }, finalize: { tap in
                Unmanaged<DecodedAudioProbe>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
            },
            prepare: { tap, _, format in
                let probe = Unmanaged<DecodedAudioProbe>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                probe.lock.lock(); probe.sampleRate = format.pointee.mSampleRate
                probe.isFloat = (format.pointee.mFormatFlags & kAudioFormatFlagIsFloat) != 0; probe.lock.unlock()
            }, unprepare: nil,
            process: { tap, count, _, buffers, outCount, outFlags in
                var range = CMTimeRange.zero
                guard MTAudioProcessingTapGetSourceAudio(tap, count, buffers, outFlags, &range, outCount) == noErr else { return }
                let probe = Unmanaged<DecodedAudioProbe>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                probe.record(buffers, count: Int(outCount.pointee), at: range.start.seconds)
            })
        var tap: MTAudioProcessingTap?
        let result = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects, &tap)
        guard result == noErr, let tap else { throw NSError(domain: "AudioProbe", code: Int(result)) }
        return tap
    }
    private func record(_ buffers: UnsafeMutablePointer<AudioBufferList>, count: Int, at time: Double) {
        guard count >= 256, let data = buffers.pointee.mBuffers.mData else { return }
        lock.lock(); defer { lock.unlock() }
        guard values.count < 64 else { return }
        let stride = Int(buffers.pointee.mBuffers.mNumberChannels)
        let available = min(count, Int(buffers.pointee.mBuffers.mDataByteSize) / (stride * (isFloat ? 4 : 2)))
        guard available > 256 else { return }
        let sample: (Int) -> Double = isFloat
            ? { Double(data.assumingMemoryBound(to: Float.self)[$0 * stride]) }
            : { Double(data.assumingMemoryBound(to: Int16.self)[$0 * stride]) / 32768 }
        guard let first = (0..<available).first(where: { abs(sample($0)) > 0.0001 }),
              let last = (0..<available).reversed().first(where: { abs(sample($0)) > 0.0001 }), last - first > 256 else { return }
        var crossings = 0
        for i in (first + 1)...last where sample(i - 1) <= 0 && sample(i) > 0 { crossings += 1 }
        values.append(.init(time: time, frequency: Double(crossings) * sampleRate / Double(last - first)))
    }
}
