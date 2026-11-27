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
}

/// The video is silent and uses an ambient audio session so external players keep playing.
struct AnimatedArtwork: UIViewRepresentable {
    var url: URL
    var active: Bool
    var allowCellular = false
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
                       gravity: gravity, fadesBottom: fadesBottom)
    }

    static func dismantleUIView(_ view: Surface, coordinator _: ()) {
        view.stop()
    }

    final class Surface: UIView {
        var prepareAudio: () throws -> Void = { try ArtworkAudioPolicy.prepare() }
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
        private var watchdogTask: Task<Void, Never>?
        private var watchdog = ArtworkPlaybackWatchdog()
        private var lastTick: CFTimeInterval?
        private var playbackActive = false
        private var failed = false
        private var reportedFirstFrame = false
        private var reportedVideoSize = CGSize.zero
        private var generation = UUID()

        var activePlayer: AVPlayer { player }

        func attachReflection(to reflectionLayer: AVPlayerLayer) {
            if reflectionLayer.player !== player {
                reflectionLayer.player = player
            }
        }

        func detachReflection(_ reflectionLayer: AVPlayerLayer) {
            if reflectionLayer.player === player {
                reflectionLayer.player = nil
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

        deinit {
            watchdogTask?.cancel()
            NotificationCenter.default.removeObserver(self)
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            CATransaction.begin(); CATransaction.setDisableActions(true)
            bottomFade.frame = bounds
            CATransaction.commit()
        }

        @objc private func resetWatchdogTimestamp() {
            lastTick = nil
        }

        func configure(url: URL, active: Bool, allowCellular: Bool = false,
                       gravity: AVLayerVideoGravity = .resizeAspectFill, fadesBottom: Bool = false)
        {
            guard url.isFileURL || url.scheme?.lowercased() == "https" else { stop(); return }
            playerLayer.videoGravity = gravity
            CATransaction.begin(); CATransaction.setDisableActions(true)
            layer.mask = fadesBottom ? bottomFade : nil
            bottomFade.frame = bounds
            CATransaction.commit()
            let replacesResource = self.url != url || self.allowCellular != allowCellular
            if replacesResource {
                stop()
                self.url = url
                self.allowCellular = allowCellular
                do {
                    try prepareAudio()
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
                // Seed the paused queue before AVPlayerLooper takes ownership so
                // the primary layer can decode and present its first frame.
                player.insert(template, after: nil)
                looper = AVPlayerLooper(player: player, templateItem: template)
                observeCurrentItem()
            }

            if playbackActive != active {
                lastTick = nil
            }
            playbackActive = active
            if active, !failed, player.currentItem?.status != .failed {
                player.play()
                startWatchdogIfNeeded()
            } else {
                player.pause()
                stopWatchdog()
                Task { @MainActor [weak self] in
                    guard let self, !playbackActive else { return }
                    report(.paused)
                }
            }
        }

        /// A page transition may retain this silent frame for at most 200ms.
        func holdCurrentFrameForTransition() {
            player.pause()
            stopWatchdog()
        }

        func stop() {
            generation = UUID()
            stopWatchdog()
            watchdog = ArtworkPlaybackWatchdog()
            reportedState = nil
            lastTick = nil; playbackActive = false; failed = false
            reportedFirstFrame = false
            reportedVideoSize = .zero
            tracksObservation = nil; statusObservation = nil; observedItem = nil
            player.pause()
            looper?.disableLooping(); looper = nil
            player.removeAllItems()
            playerLayer.opacity = 0
            url = nil
        }

        private func startWatchdogIfNeeded() {
            guard watchdogTask == nil, playbackActive, !failed else { return }
            lastTick = CACurrentMediaTime()
            watchdogTask = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                    guard let self, self.playbackActive, !self.failed else {
                        self?.watchdogTask = nil
                        return
                    }
                    self.pollWatchdog()
                }
            }
        }

        private func stopWatchdog() {
            watchdogTask?.cancel()
            watchdogTask = nil
            lastTick = nil
        }

        private func pollWatchdog() {
            let now = CACurrentMediaTime()
            let eligible = playbackActive && UIApplication.shared.applicationState == .active
            let elapsed = lastTick.map { max(0, now - $0) } ?? 0
            lastTick = eligible ? now : nil
            guard !failed else { return }
            if playerLayer.isReadyForDisplay,
               player.currentItem?.presentationSize != reportedVideoSize {
                updateVisibility()
            }
            let state: ArtworkPlaybackState = !eligible ? .paused
                : !playerLayer.isReadyForDisplay ? .preparing
                : player.timeControlStatus == .waitingToPlayAtSpecifiedRate ? .buffering : .displayed
            report(state)
            if let failure = watchdog.advance(elapsed: elapsed, eligible: eligible,
                                              displayed: playerLayer.isReadyForDisplay,
                                              position: player.currentTime().seconds)
            {
                fail(NSError(domain: "AMLL.ArtworkPlayback", code: failure == .firstFrameTimeout ? 1 : 2,
                             userInfo: [NSLocalizedDescriptionKey: "动态封面播放等待超时"]))
            }
        }

        /// AVPlayerLooper creates new items. Observe each current item's tracks
        /// as they load rather than only muting the original template item.
        private func observeCurrentItem() {
            let item = player.currentItem
            guard observedItem !== item else { updateVisibility(); return }
            tracksObservation = nil; statusObservation = nil
            observedItem = item
            guard let item else { updateVisibility(); return }
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
            let visible = !failed && url != nil && player.currentItem?.status == .readyToPlay && playerLayer.isReadyForDisplay
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            playerLayer.opacity = visible ? 1 : 0
            CATransaction.commit()
            let size = player.currentItem?.presentationSize ?? .zero
            if visible,
               let url, !reportedFirstFrame || (size.width > 0 && size.height > 0 && size != reportedVideoSize) {
                reportedFirstFrame = true
                reportedVideoSize = size
                let generation = generation
                Task { @MainActor [weak self] in
                    guard let self, self.generation == generation, self.url == url else { return }
                    onFirstFrame(url, size)
                }
            }
        }

        private func fail(_ error: Error?) {
            guard !failed, let url else { return }
            let failingGeneration = generation
            failed = true
            player.pause()
            stopWatchdog()
            report(.failed)
            guard generation == failingGeneration else { return }
            updateVisibility()
            onFailure(url, error)
        }

        private func report(_ state: ArtworkPlaybackState) {
            guard let url, reportedState != state else { return }
            reportedState = state
            onState(url, state)
        }
    }
}
