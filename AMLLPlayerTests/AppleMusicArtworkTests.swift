@testable import AMLLPlayer
import UIKit
import XCTest

@MainActor
final class AppleMusicArtworkTests: XCTestCase {
    private func item(id: String = "42", scope: MusicResourceScope = .catalog, album: String? = "Album") -> PlaybackItem {
        .init(id: id, uri: "applemusic:\(scope.rawValue):track:\(id)", title: "Song", artists: ["Singer"],
              albumTitle: album, artworkURL: nil, duration: 100, isEpisode: false, isAdvertisement: false,
              service: .appleMusic, resourceScope: scope, catalogID: scope == .catalog ? id : nil)
    }

    func testSystemCoverUsesCatalogIdentityAndRejectsStaleSongDespiteMatchingTitle() {
        let current = item()
        XCTAssertTrue(AppleMusicSystemArtwork.matches(current, storeID: "42", title: nil, artist: nil, album: nil, duration: 0))
        XCTAssertFalse(AppleMusicSystemArtwork.matches(current, storeID: "43", title: "Song", artist: "Singer", album: "Album", duration: 100))
        XCTAssertFalse(AppleMusicSystemArtwork.matches(current, storeID: "0", title: "Song", artist: "Other", album: "Album", duration: 100))
    }

    func testLocalLibraryFallbackRequiresCompleteMatchingMetadata() {
        let current = item(id: "i.local", scope: .library)
        XCTAssertTrue(AppleMusicSystemArtwork.matches(current, storeID: "0", title: "Song", artist: "Singer", album: "Album", duration: 100))
        XCTAssertFalse(AppleMusicSystemArtwork.matches(current, storeID: "0", title: "Song", artist: "Singer", album: "Other", duration: 100))
        XCTAssertFalse(AppleMusicSystemArtwork.matches(current, storeID: "0", title: "Song", artist: "Singer", album: "Album", duration: .nan))
        XCTAssertFalse(AppleMusicSystemArtwork.matches(item(album: nil), storeID: "0", title: "Song", artist: "Singer", album: nil, duration: 100))
    }

    func testSystemArtworkIsReadOncePerSongAndLocalFileLoadsWithoutNetwork() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let data = try XCTUnwrap(UIGraphicsImageRenderer(size: .init(width: 8, height: 8)).image { context in
            UIColor.red.setFill(); context.fill(.init(x: 0, y: 0, width: 8, height: 8))
        }.pngData())
        var reads = 0
        let provider = AppleMusicSystemArtwork(cache: .init(directory: directory), readArtwork: { _ in reads += 1; return data })
        XCTAssertNil(provider.url(for: item(), now: 0))
        let first = try await waitForURL(provider, item: item())
        let loaded = try await ArtworkImageData.load(first)
        XCTAssertEqual(loaded, data)
        XCTAssertNotNil(UIImage(data: loaded))
        XCTAssertEqual(provider.url(for: item(), now: 10), first)
        XCTAssertEqual(reads, 1)
        // The OS can purge Caches at any time; the next sample rebuilds the file.
        try FileManager.default.removeItem(at: first)
        XCTAssertNil(provider.url(for: item(), now: 11))
        let replacement = try await waitForURL(provider, item: item())
        XCTAssertNotEqual(replacement, first)
        XCTAssertEqual(reads, 2)
        provider.reset()
    }

    func testTrackSwitchAndDisconnectDiscardPendingArtworkResults() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let provider = AppleMusicSystemArtwork(cache: .init(directory: directory), readArtwork: { $0.id == "42" ? Data([1, 2]) : Data([3, 4]) })
        XCTAssertNil(provider.url(for: item(), now: 0))
        XCTAssertNil(provider.url(for: item(id: "43"), now: 1))
        let current = try await waitForURL(provider, item: item(id: "43"))
        XCTAssertEqual(try Data(contentsOf: current), Data([3, 4]))
        provider.reset()
        for _ in 0 ..< 20 {
            await Task.yield()
        }
        XCTAssertNil(provider.url(for: item(), now: 2))
        provider.reset()
    }

    func testImageCacheHasByteAndFileBudgetsAndDoesNotTouchOtherFiles() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = SystemArtworkCache(directory: directory, byteLimit: 10)
        _ = try await cache.store(Data([1, 2, 3, 4]))
        let marker = directory.appendingPathComponent("keep.txt")
        try Data([9]).write(to: marker)
        for _ in 0 ..< 8 {
            _ = try await cache.store(Data([5, 6, 7, 8]))
        }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "png" }
        let bytes = try files.reduce(0) { try $0 + Data(contentsOf: $1).count }
        XCTAssertLessThanOrEqual(bytes, 10)
        XCTAssertLessThanOrEqual(files.count, 6)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        do { _ = try await cache.store(Data(repeating: 1, count: 11)); XCTFail("Oversized file must be rejected") }
        catch let error as URLError { XCTAssertEqual(error.code, .dataLengthExceedsMaximum) }
    }

    private func waitForURL(_ provider: AppleMusicSystemArtwork, item: PlaybackItem) async throws -> URL {
        for _ in 0 ..< 100 {
            if let url = provider.url(for: item, now: 1) {
                return url
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw XCTUnwrapError.missingURL
    }

    private enum XCTUnwrapError: Error { case missingURL }
}
