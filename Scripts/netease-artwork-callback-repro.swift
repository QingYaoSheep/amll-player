import MediaPlayer
import UIKit
import Foundation

@main struct ArtworkCallbackReproduction {
    static func main() async {
        let artwork = await MainActor.run {
            let image = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32)).image { context in
                UIColor.systemRed.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
            }
            return ArtworkReference(NetEaseNowPlayingArtwork.make(image))
        }
        let size = await Task.detached {
            precondition(!Thread.isMainThread)
            return artwork.value.image(at: CGSize(width: 16, height: 16))?.size
        }.value
        precondition(size == CGSize(width: 32, height: 32))
        print("Now Playing background artwork callback: PASS")
    }
}
private final class ArtworkReference: @unchecked Sendable {
    let value: MPMediaItemArtwork
    init(_ value: MPMediaItemArtwork) { self.value = value }
}
