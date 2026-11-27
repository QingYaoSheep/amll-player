import AVFoundation
import Foundation

/// Builds a compact, all-zero 16-bit mono PCM WAV buffer in memory so
/// lock-screen keep-alive never requires bundled audio assets.
enum SilentWAVData {
    static func makeOneSecondPCM(sampleRate: UInt32 = 44_100) -> Data {
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let blockAlign = channels * (bitsPerSample / 8)
        let byteRate = sampleRate * UInt32(blockAlign)
        let dataSize = sampleRate * UInt32(blockAlign)
        let riffSize = UInt32(36) + dataSize

        var data = Data(capacity: Int(44 + dataSize))
        func appendASCII(_ text: String) {
            data.append(contentsOf: text.utf8)
        }
        func appendLE16(_ value: UInt16) {
            var le = value.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }
        func appendLE32(_ value: UInt32) {
            var le = value.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }

        appendASCII("RIFF")
        appendLE32(riffSize)
        appendASCII("WAVE")
        appendASCII("fmt ")
        appendLE32(16) // PCM fmt chunk size
        appendLE16(1) // Linear PCM format
        appendLE16(channels)
        appendLE32(sampleRate)
        appendLE32(byteRate)
        appendLE16(blockAlign)
        appendLE16(bitsPerSample)
        appendASCII("data")
        appendLE32(dataSize)
        data.append(Data(count: Int(dataSize)))
        return data
    }
}

@MainActor
protocol SilentAudioKeepAliveDriving: AnyObject {
    var isPlaying: Bool { get }
    func start() -> Bool
    func stop()
}

/// Loops in-memory silent audio while holding only the mix-with-others audio lease.
/// Deliberately never writes MPNowPlayingInfoCenter or MPRemoteCommandCenter.
@MainActor
final class SystemSilentAudioKeepAliveDriver: SilentAudioKeepAliveDriving {
    private var player: AVAudioPlayer?
    private var desiredRunning = false
    nonisolated(unsafe) private var observers: [any NSObjectProtocol] = []

    var isPlaying: Bool {
        desiredRunning && (player?.isPlaying == true)
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    func start() -> Bool {
        guard AMLLBuildCapabilities.supportsSilentBackgroundKeepAlive else { return false }
        guard !MusicAudioSession.ownsPlayback else { return false }
        do {
            try MusicAudioSession.activateLockScreenKeepAlive()
        } catch {
            return false
        }

        if player == nil {
            guard let created = try? AVAudioPlayer(
                data: SilentWAVData.makeOneSecondPCM(),
                fileTypeHint: AVFileType.wav.rawValue
            ) else {
                MusicAudioSession.releaseLockScreenKeepAlive()
                return false
            }
            created.numberOfLoops = -1
            created.volume = 0
            created.prepareToPlay()
            player = created
        }

        installObserversIfNeeded()
        if player?.isPlaying == true || player?.play() == true {
            desiredRunning = true
            return true
        }

        MusicAudioSession.releaseLockScreenKeepAlive()
        return false
    }

    func stop() {
        desiredRunning = false
        player?.stop()
        player?.currentTime = 0
        MusicAudioSession.releaseLockScreenKeepAlive()
    }

    private func installObserversIfNeeded() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            MainActor.assumeIsolated {
                guard let self, self.desiredRunning,
                      rawType == AVAudioSession.InterruptionType.ended.rawValue,
                      !MusicAudioSession.ownsPlayback else { return }
                try? MusicAudioSession.activateLockScreenKeepAlive()
                _ = self.player?.play()
            }
        })
        observers.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.player = nil
                if self.desiredRunning {
                    _ = self.start()
                }
            }
        })
    }
}

struct LockScreenKeepAliveContext: Equatable, Sendable {
    var lockScreenEnabled: Bool
    var keepAliveEnabled: Bool
    var hasActiveActivity: Bool
    var isForeground: Bool
    var isTransitioningOut: Bool
    var service: MusicServiceID
    var isPlaying: Bool
}

/// Coordinates silent background keep-alive lifecycle and auto-sleep grace timeout
/// for external playback services (Apple Music / Spotify).
@MainActor
final class LockScreenBackgroundKeepAlive {
    static let defaultIdleTimeout: Duration = .seconds(180)

    private let driver: any SilentAudioKeepAliveDriving
    private let idleTimeout: Duration
    private var idleSleepTask: Task<Void, Never>?
    private(set) var isRunning = false
    private(set) var isWaitingIdleSleep = false
    var onIdleSleep: (() -> Void)?

    init(
        driver: (any SilentAudioKeepAliveDriving)? = nil,
        idleTimeout: Duration = LockScreenBackgroundKeepAlive.defaultIdleTimeout
    ) {
        self.driver = driver ?? SystemSilentAudioKeepAliveDriver()
        self.idleTimeout = idleTimeout
    }

    deinit {
        idleSleepTask?.cancel()
    }

    func synchronize(_ context: LockScreenKeepAliveContext) {
        let eligible = context.lockScreenEnabled
            && context.keepAliveEnabled
            && context.hasActiveActivity
            && context.service != .netease

        guard eligible else {
            stop()
            return
        }

        if context.isForeground && !context.isTransitioningOut {
            stop()
            return
        }

        if context.isTransitioningOut {
            if context.isPlaying {
                cancelIdleSleep()
                if !isRunning {
                    isRunning = driver.start()
                }
            }
            return
        }

        // App is in the background with an active external Live Activity.
        if context.isPlaying {
            cancelIdleSleep()
            if !isRunning {
                isRunning = driver.start()
            }
        } else if isRunning {
            scheduleIdleSleepIfNeeded()
        }
    }

    func stop() {
        cancelIdleSleep()
        guard isRunning || driver.isPlaying else { return }
        isRunning = false
        driver.stop()
    }

    private func cancelIdleSleep() {
        idleSleepTask?.cancel()
        idleSleepTask = nil
        isWaitingIdleSleep = false
    }

    private func scheduleIdleSleepIfNeeded() {
        guard idleSleepTask == nil else { return }
        isWaitingIdleSleep = true
        let timeout = idleTimeout
        idleSleepTask = Task { [weak self] in
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.idleSleepTask = nil
            self.isWaitingIdleSleep = false
            self.stop()
            self.onIdleSleep?()
        }
    }
}
