import MediaPlayer
import UIKit

/// The artwork request callback is invoked by MediaPlayer, including off the main queue.
enum NetEaseNowPlayingArtwork {
    nonisolated static func make(_ image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }
}
