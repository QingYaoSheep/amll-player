@testable import AMLLPlayer
import MediaPlayer
import UIKit
import XCTest

@MainActor final class NetEasePlaybackCallbackTests: XCTestCase {
    func testNowPlayingArtworkCanBeRequestedOffMainActorAfterPlaybackStarts() async throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32)).image { context in
            UIColor.systemRed.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        }
        let artwork = ArtworkReference(NetEaseNowPlayingArtwork.make(image))
        let size = await Task.detached {
            XCTAssertFalse(Thread.isMainThread)
            return artwork.value.image(at: CGSize(width: 16, height: 16))?.size
        }.value
        XCTAssertEqual(try XCTUnwrap(size), image.size)
    }
}

// MediaPlayer owns the immutable artwork and can request its image concurrently.
private final class ArtworkReference: @unchecked Sendable {
    let value: MPMediaItemArtwork
    init(_ value: MPMediaItemArtwork) { self.value = value }
}
