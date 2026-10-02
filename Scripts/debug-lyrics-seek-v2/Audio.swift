import AVFoundation
import MediaToolbox
import Foundation
import Dispatch

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

let root = CommandLine.arguments[1]
Task { @MainActor in
    for ext in ["flac", "mp3", "m4a"] {
        let url = CommandLine.arguments.contains("--http")
            ? URL(string: "http://127.0.0.1:18083/seek-markers." + ext)!
            : URL(fileURLWithPath: root).appendingPathComponent("seek-markers." + ext)
        let item = AVPlayerItem(url: url)
        let probe = DecodedAudioProbe()
        let tracks = try await item.asset.loadTracks(withMediaType: .audio)
        let params = AVMutableAudioMixInputParameters(track: tracks[0]); params.audioTapProcessor = try probe.makeTap()
        let mix = AVMutableAudioMix(); mix.inputParameters = [params]; item.audioMix = mix
        let player = AVPlayer(playerItem: item); player.play()
        try await Task.sleep(for: .seconds(1))
        for target in [8.25, 20.25, 4.25, 36.25] {
            player.pause(); let finished = await player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            probe.clear(); player.play(); try await Task.sleep(for: .milliseconds(400)); player.pause()
            print("[SEEK-V2] codec=\(ext) target=\(target) finished=\(finished) media=\(player.currentTime().seconds) pcm=\(probe.samples.map { String($0.time) + ":" + String($0.frequency) })")
        }
        player.replaceCurrentItem(with: nil)
    }
    exit(0)
}
DispatchQueue.global().asyncAfter(deadline: .now() + 40) { print("[SEEK-V2] real seek timeout"); exit(2) }
RunLoop.main.run()
