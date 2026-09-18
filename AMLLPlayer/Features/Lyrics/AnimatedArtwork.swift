import AVFoundation
import SwiftUI

struct AnimatedArtworkConfiguration: Codable, Equatable, Sendable {
    var enabled = false
    var allowCellular = false
}

/// Static artwork remains underneath until the local video's first frame.
/// Does not configure AVAudioSession or publish Now Playing metadata.
struct AnimatedArtwork: UIViewRepresentable {
    var url: URL
    var active: Bool

    func makeUIView(context _: Context) -> Surface {
        Surface()
    }

    func updateUIView(_ view: Surface, context _: Context) {
        view.configure(url: url, active: active)
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
            ready = playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] layer, _ in
                let visible = layer.isReadyForDisplay
                Task { @MainActor [weak self] in self?.playerLayer.opacity = visible ? 1 : 0 }
            }
        }

        required init?(coder _: NSCoder) {
            nil
        }

        func configure(url: URL, active: Bool) {
            guard url.isFileURL else { stop(); return }
            if self.url != url {
                stop()
                self.url = url
                looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
            }
            if active {
                player.play()
            } else {
                player.pause()
            }
        }

        func stop() {
            player.pause()
            looper?.disableLooping(); looper = nil
            player.removeAllItems()
            playerLayer.opacity = 0
            url = nil
        }
    }
}
