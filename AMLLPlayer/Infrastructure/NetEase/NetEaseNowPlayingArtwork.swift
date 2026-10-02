import MediaPlayer
import UIKit

/// MediaPlayer requests this immutable image from arbitrary queues. Creating the
/// callback outside MainActor prevents Swift 6 from adding a main-queue assertion.
enum NetEaseNowPlayingArtwork {
    nonisolated static func make(_ image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }
}
