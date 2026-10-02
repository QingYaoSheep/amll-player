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
            player.play()
            for _ in 0..<200 where item.status != .readyToPlay { try await Task.sleep(for: .milliseconds(25)) }
            XCTAssertEqual(item.status, .readyToPlay)
            for target in [8.25, 20.25, 4.25, 36.25] {
                player.pause()
                try await playback.seek(to: target)
                XCTAssertEqual(player.currentTime().seconds, target, accuracy: 0.1, ext)
                probe.clear(); player.play()
                for _ in 0..<200 where probe.samples.count < 3 { try await Task.sleep(for: .milliseconds(10)) }
                player.pause()
                let samples = probe.samples
                XCTAssertFalse(samples.isEmpty, "Decoded audio tap must receive real PCM: " + ext)
                let expected = 320 + floor(target / 2) * 80
                let audible = samples.prefix(3).map(\.frequency).sorted()
                if let median = audible.dropFirst(audible.count / 2).first {
                    XCTAssertEqual(median, expected, accuracy: 45, "The audible marker must agree with the seek, not just currentTime: " + ext + " target " + String(target))
                }
                print("[SEEK-V2] codec=\(ext) target=\(target) media=\(player.currentTime().seconds) decoded=\(audible)")
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
            clientInfo: Unmanaged.passUnretained(self).toOpaque(),
            init: { _, info, storage in storage.pointee = info }, finalize: nil,
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
        guard values.count < 32 else { return }
        let stride = Int(buffers.pointee.mBuffers.mNumberChannels)
        var crossings = 0
        if isFloat {
            let samples = data.assumingMemoryBound(to: Float.self)
            for i in 1..<count where samples[(i - 1) * stride] <= 0 && samples[i * stride] > 0 { crossings += 1 }
        } else {
            let samples = data.assumingMemoryBound(to: Int16.self)
            for i in 1..<count where samples[(i - 1) * stride] <= 0 && samples[i * stride] > 0 { crossings += 1 }
        }
        values.append(.init(time: time, frequency: Double(crossings) * sampleRate / Double(count)))
    }
}
