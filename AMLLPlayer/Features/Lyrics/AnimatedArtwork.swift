import AVFoundation
import SwiftUI

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

/// Static artwork remains underneath until the local video's first frame.
/// Does not configure AVAudioSession or publish Now Playing metadata.
struct AnimatedArtwork: UIViewRepresentable {
    var url: URL
    var active: Bool
    var reflectionFrames: ArtworkReflectionFrames? = nil

    func makeUIView(context _: Context) -> Surface {
        Surface()
    }

    func updateUIView(_ view: Surface, context _: Context) {
        view.configure(url: url, active: active, reflectionFrames: reflectionFrames)
    }

    static func dismantleUIView(_ view: Surface, coordinator _: ()) {
        view.stop()
    }

    final class Surface: UIView {
        override class var layerClass: AnyClass {
            AVPlayerLayer.self
        }

        private var playerLayer: AVPlayerLayer {
            layer as! AVPlayerLayer
        }

        private let player = AVQueuePlayer()
        private var looper: AVPlayerLooper?
        private var url: URL?
        private var ready: NSKeyValueObservation?
        private var currentItemObservation: NSKeyValueObservation?
        private var tracksObservation: NSKeyValueObservation?
        private var statusObservation: NSKeyValueObservation?
        private weak var observedItem: AVPlayerItem?
        private weak var reflectionFrames: ArtworkReflectionFrames?
        private var reflectionToken: UUID?
        private var output: AVPlayerItemVideoOutput?
        private weak var outputItem: AVPlayerItem?
        private var displayLink: CADisplayLink?
        @MainActor private final class Target: NSObject {
            weak var surface: Surface?
            @objc func tick(_ link: CADisplayLink) {
                surface?.capture(link)
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
            playerLayer.videoGravity = .resizeAspectFill
            playerLayer.opacity = 0
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

        func configure(url: URL, active: Bool, reflectionFrames: ArtworkReflectionFrames? = nil) {
            guard url.isFileURL else { stop(); return }
            if self.url != url {
                stop()
                self.url = url
                looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
                observeCurrentItem()
            }
            if self.reflectionFrames !== reflectionFrames {
                clearReflection()
                self.reflectionFrames = reflectionFrames
                reflectionToken = reflectionFrames?.begin()
            }
            if reflectionFrames != nil, displayLink == nil {
                let target = Target(); target.surface = self
                let link = CADisplayLink(target: target, selector: #selector(Target.tick(_:)))
                link.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
                link.add(to: .main, forMode: .common)
                displayLink = link
            }
            displayLink?.isPaused = !active
            if active, player.currentItem?.status != .failed {
                player.play()
            } else {
                player.pause()
            }
        }

        func stop() {
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
            tracksObservation = item.observe(\.tracks, options: [.initial, .new]) { [weak self, weak item] _, _ in
                Task { @MainActor [weak self, weak item] in
                    guard let self, let item, self.player.currentItem === item else { return }
                    self.disableAudio(in: item)
                }
            }
            statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self, weak item] _, _ in
                Task { @MainActor [weak self, weak item] in
                    guard let self, let item, self.player.currentItem === item else { return }
                    self.disableAudio(in: item)
                    self.updateVisibility()
                    if item.status == .failed {
                        self.player.pause()
                        self.reflectionFrames?.clear(source: self.reflectionToken)
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
            let visible = url != nil && player.currentItem?.status == .readyToPlay && playerLayer.isReadyForDisplay
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            playerLayer.opacity = visible ? 1 : 0
            CATransaction.commit()
        }

        private func clearReflection() {
            displayLink?.invalidate(); displayLink = nil
            if let output {
                outputItem?.remove(output)
            }
            output = nil; outputItem = nil
            reflectionFrames?.clear(source: reflectionToken)
            reflectionFrames = nil; reflectionToken = nil
        }

        private func capture(_ link: CADisplayLink) {
            guard let reflectionFrames, let reflectionToken, let item = player.currentItem,
                  item.status == .readyToPlay else { return }
            if outputItem !== item {
                if let output {
                    outputItem?.remove(output)
                }
                let next = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
                item.add(next); output = next; outputItem = item
            }
            guard let output else { return }
            let time = output.itemTime(forHostTime: link.targetTimestamp)
            guard output.hasNewPixelBuffer(forItemTime: time),
                  let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) else { return }
            reflectionFrames.display(buffer, source: reflectionToken)
        }
    }
}
