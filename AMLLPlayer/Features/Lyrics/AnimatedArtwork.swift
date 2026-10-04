import AVFoundation
import SwiftUI

@MainActor private enum ArtworkAudioPolicy {
    static func prepare() throws {
        try MusicAudioSession.prepareArtwork()
    }
}

struct AnimatedArtworkConfiguration: Codable, Equatable, Sendable {
    enum Presentation: String, Codable, CaseIterable, Sendable {
        case square
        case immersive
    }

    var enabled = false
    var allowCellular = false
    /// Optional for decoding previously saved configurations without migration loss.
    var presentation: Presentation?
    var reflection: Bool?
}

/// The video is silent and uses a mixing audio session so Spotify keeps playing.
struct AnimatedArtwork: UIViewRepresentable {
    var url: URL
    var active: Bool
    var allowCellular = false
    var reflectionFrames: ArtworkReflectionFrames?
    var onFailure: (URL, Error?) -> Void = { _, _ in }
    var onState: (URL, ArtworkPlaybackState) -> Void = { _, _ in }
    var onFirstFrame: (URL, CGSize) -> Void = { _, _ in }
    var gravity: AVLayerVideoGravity = .resizeAspectFill
    var fadesBottom = false

    func makeUIView(context _: Context) -> Surface {
        Surface()
    }

    func updateUIView(_ view: Surface, context _: Context) {
        view.onFailure = onFailure
        view.onState = onState
        view.onFirstFrame = onFirstFrame
        view.configure(url: url, active: active, allowCellular: allowCellular,
                       reflectionFrames: reflectionFrames, gravity: gravity, fadesBottom: fadesBottom)
    }

    static func dismantleUIView(_ view: Surface, coordinator _: ()) {
        view.stop()
    }

    final class Surface: UIView {
        var onFailure: (URL, Error?) -> Void = { _, _ in }
        var onState: (URL, ArtworkPlaybackState) -> Void = { _, _ in }
        var onFirstFrame: (URL, CGSize) -> Void = { _, _ in }
        private var reportedState: ArtworkPlaybackState?
        override class var layerClass: AnyClass {
            AVPlayerLayer.self
        }

        private var playerLayer: AVPlayerLayer {
            layer as! AVPlayerLayer
        }

        private let bottomFade = CAGradientLayer()

        private let player = AVQueuePlayer()
        private var looper: AVPlayerLooper?
        private var url: URL?
        private var allowCellular = false
        private var ready: NSKeyValueObservation?
        private var currentItemObservation: NSKeyValueObservation?
        private var tracksObservation: NSKeyValueObservation?
        private var statusObservation: NSKeyValueObservation?
        private weak var observedItem: AVPlayerItem?
        private weak var reflectionFrames: ArtworkReflectionFrames?
        private var reflectionToken: UUID?
        private var output: AVPlayerItemVideoOutput?
        private var outputTarget: Target?
        private weak var outputItem: AVPlayerItem?
        private var outputWakeDeadline: CFTimeInterval?
        private var outputNotificationRequested = false
        private var playerVideoOutput: AVPlayerVideoOutput?
        private var lastPlayerOutputTime: CMTime?
        private var frameOutputWatchdog = ArtworkFrameOutputWatchdog()
        private var displayLink: CADisplayLink?
        private var watchdog = ArtworkPlaybackWatchdog()
        private var lastTick: CFTimeInterval?
        private var playbackActive = false
        private var failed = false
        private var reportedFirstFrame = false
        private var reportedVideoSize = CGSize.zero
        private var externallyDriven = false
        private var generation = UUID()
        @MainActor private final class Target: NSObject, AVPlayerItemOutputPullDelegate {
            weak var surface: Surface?
            @objc func tick(_ link: CADisplayLink) {
                surface?.capture(link)
            }
            nonisolated func outputMediaDataWillChange(_ sender: AVPlayerItemOutput) {
                Task { @MainActor [weak self] in
                    guard let surface = self?.surface, !surface.failed, surface.output === sender else { return }
                    surface.outputNotificationRequested = false
                    surface.refreshReflectionFrame()
                    if !surface.playbackActive, surface.reflectionFrames?.hasFrame != true {
                        surface.outputWakeDeadline = CACurrentMediaTime() + 2
                        surface.displayLink?.isPaused = false
                    }
                }
            }
        }

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            isAccessibilityElement = false
            player.isMuted = true
            player.volume = 0
            player.preventsDisplaySleepDuringVideoPlayback = false
            playerLayer.player = player
            playerLayer.backgroundColor = UIColor.clear.cgColor
            playerLayer.videoGravity = .resizeAspectFill
            playerLayer.opacity = 0
            isOpaque = false
            bottomFade.colors = AMLLImmersiveArtworkGeometry.videoFadeStops.map {
                UIColor(white: 1, alpha: CGFloat($0.alpha)).cgColor
            }
            bottomFade.locations = AMLLImmersiveArtworkGeometry.videoFadeStops.map { NSNumber(value: $0.location) }
            NotificationCenter.default.addObserver(self, selector: #selector(resetWatchdogTimestamp),
                                                   name: UIApplication.willResignActiveNotification, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(resetWatchdogTimestamp),
                                                   name: UIApplication.didBecomeActiveNotification, object: nil)
            ready = playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.updateVisibility() }
            }
            currentItemObservation = player.observe(\.currentItem, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.observeCurrentItem() }
            }
        }

        required init?(coder _: NSCoder) {
            nil
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            CATransaction.begin(); CATransaction.setDisableActions(true)
            bottomFade.frame = bounds
            CATransaction.commit()
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil {
                refreshReflectionFrame()
                reflectionFrames?.replayLatest()
            }
        }

        @objc private func resetWatchdogTimestamp() {
            lastTick = nil
            frameOutputWatchdog.suspend()
        }

        func configure(url: URL, active: Bool, allowCellular: Bool = false,
                       reflectionFrames: ArtworkReflectionFrames? = nil,
                       gravity: AVLayerVideoGravity = .resizeAspectFill, fadesBottom: Bool = false,
                       externallyDriven: Bool = false)
        {
            guard url.isFileURL || url.scheme?.lowercased() == "https" else { stop(); return }
            playerLayer.videoGravity = gravity
            self.externallyDriven = externallyDriven
            CATransaction.begin(); CATransaction.setDisableActions(true)
            layer.mask = fadesBottom ? bottomFade : nil
            bottomFade.frame = bounds
            CATransaction.commit()
            if self.url != url || self.allowCellular != allowCellular {
                stop()
                self.url = url
                self.allowCellular = allowCellular
                do {
                    // Configure before AVPlayerLooper inserts an item or playback begins.
                    // Ambient mixes with the existing music session without taking control.
                    try ArtworkAudioPolicy.prepare()
                } catch {
                    let generation = generation
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == generation else { return }
                        self.fail(error)
                    }
                    return
                }
                let asset = AVURLAsset(url: url, options: [
                    AVURLAssetAllowsCellularAccessKey: allowCellular,
                    AVURLAssetAllowsExpensiveNetworkAccessKey: allowCellular,
                    AVURLAssetAllowsConstrainedNetworkAccessKey: false,
                ])
                let template = AVPlayerItem(asset: asset)
                disableAudio(in: template)
                // The looper prepares replicas asynchronously. Seed the paused
                // queue so the player layer can load/present a first frame even
                // before those replicas become available. Do not mutate the
                // queue after the looper takes ownership.
                player.insert(template, after: nil)
                looper = AVPlayerLooper(player: player, templateItem: template)
                observeCurrentItem()
            }
            if self.reflectionFrames !== reflectionFrames {
                clearReflection()
                self.reflectionFrames = reflectionFrames
                reflectionToken = reflectionFrames?.begin()
            }
            // Attach to the actual loop item before play(), including paused
            // presentation. Late attachment in capture() missed this lifecycle.
            attachReflectionOutput()
            if externallyDriven { displayLink?.invalidate(); displayLink = nil }
            if displayLink == nil && !externallyDriven {
                let target = Target(); target.surface = self
                let link = CADisplayLink(target: target, selector: #selector(Target.tick(_:)))
                link.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
                link.add(to: .main, forMode: .common)
                displayLink = link
            }
            if playbackActive != active {
                lastTick = nil
            }
            playbackActive = active
            if active { outputWakeDeadline = nil }
            displayLink?.isPaused = !active && outputWakeDeadline == nil
            if active, !failed, player.currentItem?.status != .failed {
                player.play()
            } else {
                player.pause()
                // Report asynchronously: configure is called during a SwiftUI update.
                Task { @MainActor [weak self] in
                    guard let self, !playbackActive else { return }
                    report(.paused)
                }
            }
            refreshReflectionFrame()
            if !active, reflectionFrames != nil, reflectionFrames?.hasFrame != true {
                if outputWakeDeadline == nil { outputWakeDeadline = CACurrentMediaTime() + 2 }
                displayLink?.isPaused = false
                requestOutputNotification()
            }
        }

        func stop() {
            generation = UUID()
            watchdog = ArtworkPlaybackWatchdog()
            reportedState = nil
            lastTick = nil; playbackActive = false; failed = false
            reportedFirstFrame = false
            reportedVideoSize = .zero
            tracksObservation = nil; statusObservation = nil; observedItem = nil
            clearReflection()
            player.pause()
            looper?.disableLooping(); looper = nil
            player.removeAllItems()
            playerLayer.opacity = 0
            url = nil
        }

        /// AVPlayerLooper creates new items. Observe each current item's tracks
        /// as they load rather than only muting the original template item.
        private func observeCurrentItem() {
            let item = player.currentItem
            guard observedItem !== item else { updateVisibility(); return }
            tracksObservation = nil; statusObservation = nil
            observedItem = item
            guard let item else { updateVisibility(); return }
            attachReflectionOutput()
            tracksObservation = item.observe(\.tracks, options: [.initial, .new]) { [weak self, weak item] _, _ in
                Task { @MainActor [weak self, weak item] in
                    guard let self, let item, player.currentItem === item else { return }
                    disableAudio(in: item)
                }
            }
            statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self, weak item] _, _ in
                Task { @MainActor [weak self, weak item] in
                    guard let self, let item, player.currentItem === item else { return }
                    disableAudio(in: item)
                    updateVisibility()
                    if item.status == .failed {
                        fail(item.error)
                    }
                }
            }
            disableAudio(in: item)
            updateVisibility()
        }

        private func disableAudio(in item: AVPlayerItem) {
            for track in item.tracks where track.assetTrack?.mediaType == .audio {
                track.isEnabled = false
            }
        }

        private func updateVisibility() {
            // Read current state when the main-actor callback runs. A queued
            // readiness notification from the previous song must not expose it.
            let visible = !failed && url != nil && player.currentItem?.status == .readyToPlay && playerLayer.isReadyForDisplay
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            playerLayer.opacity = visible && !externallyDriven ? 1 : 0
            CATransaction.commit()
            if visible { refreshReflectionFrame() }
            let size = player.currentItem?.presentationSize ?? .zero
            if !externallyDriven, visible, let url, !reportedFirstFrame || (size.width > 0 && size.height > 0 && size != reportedVideoSize) {
                reportedFirstFrame = true
                reportedVideoSize = size
                let generation = generation
                Task { @MainActor [weak self] in
                    guard let self, self.generation == generation, self.url == url else { return }
                    onFirstFrame(url, size)
                }
            }
        }

        private func clearReflection() {
            displayLink?.invalidate(); displayLink = nil
            if let output {
                output.setDelegate(nil, queue: nil)
                outputItem?.remove(output)
            }
            output = nil; outputItem = nil; outputTarget = nil; outputWakeDeadline = nil
            player.videoOutput = nil; playerVideoOutput = nil; lastPlayerOutputTime = nil
            frameOutputWatchdog = ArtworkFrameOutputWatchdog()
            outputNotificationRequested = false
            reflectionFrames?.outputAttached = false
            reflectionFrames?.clear(source: reflectionToken)
            reflectionFrames = nil; reflectionToken = nil
        }

        private func capture(_ link: CADisplayLink) {
            sampleVideoFrame(at: link.timestamp, targetTime: link.targetTimestamp)
            if !playbackActive, reflectionFrames?.hasFrame == true || link.timestamp >= (outputWakeDeadline ?? 0) {
                outputWakeDeadline = nil
                displayLink?.isPaused = true
                if reflectionFrames?.hasFrame != true { requestOutputNotification() }
            }
        }

        /// The compositor drives this once per display frame, even while the
        /// song is paused and its independently animated background is moving.
        func sampleVideoFrame(at timestamp: CFTimeInterval, targetTime: CFTimeInterval) {
            let eligible = playbackActive && UIApplication.shared.applicationState == .active
            let elapsed = lastTick.map { timestamp - $0 } ?? 0
            lastTick = eligible ? timestamp : nil
            guard !failed else { return }
            if playerLayer.isReadyForDisplay,
               player.currentItem?.presentationSize != reportedVideoSize {
                updateVisibility()
            }
            let displayed = externallyDriven ? reportedFirstFrame : playerLayer.isReadyForDisplay
            let state: ArtworkPlaybackState = !eligible ? .paused
                : !displayed ? .preparing
                : player.timeControlStatus == .waitingToPlayAtSpecifiedRate ? .buffering : .displayed
            report(state)
            if let failure = watchdog.advance(elapsed: elapsed, eligible: eligible,
                                              displayed: displayed,
                                              position: player.currentTime().seconds)
            {
                fail(NSError(domain: "AMLL.ArtworkPlayback", code: failure == .firstFrameTimeout ? 1 : 2,
                             userInfo: [NSLocalizedDescriptionKey: "动态封面播放等待超时"]))
                return
            }
            refreshReflectionFrame(hostTime: targetTime)
        }

        func compositionDidPresent(_ frame: ImmersiveArtworkFrame) {
            guard externallyDriven, !failed, let url, frame.generation == reflectionToken else { return }
            guard !reportedFirstFrame || reportedVideoSize != frame.size else { return }
            reportedFirstFrame = true; reportedVideoSize = frame.size
            onFirstFrame(url, frame.size)
        }

        func failComposition() {
            fail(NSError(domain: "AMLL.ArtworkComposition", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "动态封面画面合成失败"]))
        }

        private func attachReflectionOutput() {
            guard playerVideoOutput == nil, reflectionFrames != nil, let item = player.currentItem else { return }
            if outputItem !== item {
                if let output {
                    output.setDelegate(nil, queue: nil)
                    outputItem?.remove(output)
                }
                let next = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
                let target = Target(); target.surface = self
                next.setDelegate(target, queue: .main)
                item.add(next); output = next; outputItem = item
                outputTarget = target
                outputNotificationRequested = false
                reflectionFrames?.outputAttached = true
            }
        }

        /// Host-time prediction may be invalid during initial HLS buffering or
        /// pause. Fall back to the actual item's media time, never another clock.
        func refreshReflectionFrame(hostTime: CFTimeInterval? = nil) {
            guard !failed, let reflectionFrames, let reflectionToken,
                  let item = player.currentItem else { return }
            reflectionFrames.samplingAttempts += 1
            reflectionFrames.mediaTime = player.currentTime().seconds
            reflectionFrames.mediaRate = player.rate
            reflectionFrames.videoDisplayed = playerLayer.isReadyForDisplay
            reflectionFrames.resourceKind = url?.isFileURL == true ? (url?.pathExtension ?? "本地") : "在线"
            let now = CACurrentMediaTime()
            let eligible = window != nil && UIApplication.shared.applicationState == .active
                // Readiness may drop between HLS loop items. Once this resource
                // presented a frame, keep the foreground starvation clock alive.
                && (reportedFirstFrame || playerLayer.isReadyForDisplay || (externallyDriven && item.status == .readyToPlay))
                && (playbackActive || !reflectionFrames.hasFrame)
            let starved = frameOutputWatchdog.sample(now: now, eligible: eligible)
            if playerVideoOutput == nil, starved { usePlayerLevelFrameOutput() }
            reflectionFrames.outputStarvationSeconds = frameOutputWatchdog.waiting
            if externallyDriven, frameOutputWatchdog.timedOut {
                fail(NSError(domain: "AMLL.ArtworkFrameOutput", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "动态封面视频帧等待超时"]))
                return
            }
            if let playerVideoOutput {
                for timestamp in [hostTime, CACurrentMediaTime()].compactMap({ $0 }) {
                    let time = CMTime(seconds: timestamp, preferredTimescale: 1_000_000_000)
                    guard let sample = playerVideoOutput.taggedBuffers(forHostTime: time),
                          lastPlayerOutputTime.map({ CMTimeCompare($0, sample.presentationTime) != 0 }) ?? true else { continue }
                    for tagged in sample.taggedBufferGroup {
                        if case let .pixelBuffer(buffer) = tagged.buffer {
                            lastPlayerOutputTime = sample.presentationTime
                            if reflectionFrames.display(buffer, source: reflectionToken, presentationTime: sample.presentationTime) {
                                frameOutputWatchdog.receivedFrame(now: now)
                                reflectionFrames.outputStarvationSeconds = 0
                            }
                            return
                        }
                    }
                }
                return
            }
            attachReflectionOutput()
            guard item.status == .readyToPlay, let output, outputItem === item else { return }
            let predicted = hostTime.map { output.itemTime(forHostTime: $0) }
            for time in [predicted, player.currentTime()].compactMap({ $0 }) where time.isNumeric {
                var displayedTime = CMTime.invalid
                if output.hasNewPixelBuffer(forItemTime: time),
                   let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: &displayedTime) {
                    if reflectionFrames.display(buffer, source: reflectionToken, presentationTime: displayedTime.isNumeric ? displayedTime : time) {
                        frameOutputWatchdog.receivedFrame(now: now)
                        reflectionFrames.outputStarvationSeconds = 0
                    }
                    return
                }
            }
        }

        /// HLS / decoder changes can leave an item output attached but silent.
        /// Switch once to the public player-level output with native pixel
        /// buffers. It follows the same player across loop items and avoids a
        /// second decoder/player or a permanently retained blank reflection.
        func usePlayerLevelFrameOutput() {
            guard playerVideoOutput == nil, reflectionFrames != nil else { return }
            if let output {
                output.setDelegate(nil, queue: nil)
                outputItem?.remove(output)
            }
            output = nil; outputItem = nil; outputTarget = nil
            outputNotificationRequested = false
            let specification = AVVideoOutputSpecification(tagCollections: [[.mediaType(.video)]])
            let next = AVPlayerVideoOutput(specification: specification)
            playerVideoOutput = next
            player.videoOutput = next
            lastPlayerOutputTime = nil
            reflectionFrames?.outputKind = "播放器级（原生像素格式）"
            reflectionFrames?.frameOutputSwitches += 1
            reflectionFrames?.outputAttached = true
        }

        private func requestOutputNotification() {
            guard !outputNotificationRequested, let output else { return }
            outputNotificationRequested = true
            output.requestNotificationOfMediaDataChange(withAdvanceInterval: 0.03)
        }

        private func fail(_ error: Error?) {
            guard !failed, let url else { return }
            failed = true
            player.pause()
            displayLink?.isPaused = true
            reflectionFrames?.clear(source: reflectionToken)
            updateVisibility()
            report(.failed)
            onFailure(url, error)
        }

        private func report(_ state: ArtworkPlaybackState) {
            guard let url, reportedState != state else { return }
            reportedState = state
            onState(url, state)
        }
    }
}
