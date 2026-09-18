@testable import AMLLPlayer
import XCTest

@MainActor
final class ArtworkMediaTests: XCTestCase {
    func testLegacyConfigurationKeepsSquareLayout() throws {
        let data = Data(#"{"enabled":true,"allowCellular":false}"#.utf8)
        let value = try JSONDecoder().decode(AnimatedArtworkConfiguration.self, from: data)
        XCTAssertTrue(value.enabled)
        XCTAssertFalse(value.allowCellular)
        XCTAssertEqual(value.presentation ?? .square, .square)
    }

    func testImmersiveModeSelectsTallResourceAndClearsKindOnReset() async {
        let assets = ArtworkAsset.catalogAssets(attributes: ["editorialVideo": [
            "motionDetailSquare": "https://example.com/square.m3u8",
            "motionDetailTall": "https://example.com/tall.m3u8",
        ]], albumID: "1", storefront: "us")
        let loader = AnimatedArtworkLoader()
        await loader.load(trackID: "one", kind: .portraitVideo, assets: { assets }, download: { url in
            XCTAssertEqual(url.lastPathComponent, "tall.m3u8")
            return URL(fileURLWithPath: "/tall.movpkg")
        })
        XCTAssertEqual(loader.status, .ready)
        XCTAssertEqual(loader.kind, .portraitVideo)
        loader.reset()
        XCTAssertNil(loader.kind)
        XCTAssertNil(loader.localURL)
    }

    func testImmersiveCoverUsesSourceSlotCenterAndExtent() {
        let compact = AMLLImmersiveArtworkGeometry.frame(viewport: CGSize(width: 402, height: 874),
                                                         slot: CGRect(x: 32, y: 95, width: 72, height: 72))
        XCTAssertEqual(compact.width, 482.4, accuracy: 0.001)
        XCTAssertEqual(compact.midX, 68, accuracy: 0.001)
        XCTAssertEqual(compact.midY, 131, accuracy: 0.001)
        let expanded = AMLLImmersiveArtworkGeometry.frame(viewport: CGSize(width: 402, height: 874),
                                                          slot: CGRect(x: 24, y: 95, width: 354, height: 354))
        XCTAssertEqual(expanded.width, 652.8, accuracy: 0.001)
        XCTAssertEqual(expanded.midY, 272, accuracy: 0.001)
    }

    func testPackageOwnershipSurvivesCachePurgeAndCorruptPrimaryIndex() throws {
        let sandbox = try temporarySandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let root = sandbox.appendingPathComponent("cache")
        let cache = ArtworkMediaCache(root: root, sandbox: sandbox, limit: 8)
        let remote = try XCTUnwrap(URL(string: "https://example.com/video.m3u8"))
        func package(_ name: String) throws -> URL {
            let url = sandbox.appendingPathComponent(name + ".movpkg")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try Data(repeating: 1, count: 4).write(to: url.appendingPathComponent("segment"))
            return url
        }
        let first = try package("first")
        _ = try cache.insert(first, for: remote, managedPackage: true)
        let second = try package("second")
        _ = try cache.insert(second, for: remote, managedPackage: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        try FileManager.default.removeItem(at: root)
        try Data("invalid".utf8).write(to: sandbox.appendingPathComponent("Library/Application Support/AMLLArtwork/index.json"))
        let restored = ArtworkMediaCache(root: root, sandbox: sandbox, limit: 8)
        XCTAssertEqual(restored.byteCount, 4)
        XCTAssertNotNil(restored.cached(remote))
        restored.clear()
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.path))
    }

    func testVideoSurfaceReleasesAfterDismantling() async {
        weak var released: AnimatedArtwork.Surface?
        autoreleasepool {
            let surface = AnimatedArtwork.Surface()
            released = surface
            surface.stop()
        }
        for _ in 0 ..< 10 {
            await Task.yield()
        }
        XCTAssertNil(released)
    }

    private func temporarySandbox() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testCacheEvictsLeastRecentlyUsedAndSurvivesRecreation() throws {
        let sandbox = try temporarySandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let root = sandbox.appendingPathComponent("cache")
        let cache = ArtworkMediaCache(root: root, sandbox: sandbox, limit: 8)
        let urls = (0 ..< 3).map { URL(string: "https://example.com/\($0).mp4")! }
        func add(_ index: Int) throws {
            let temporary = sandbox.appendingPathComponent("download")
            try Data(repeating: UInt8(index), count: 4).write(to: temporary)
            _ = try cache.insert(temporary, for: urls[index], managedPackage: false)
        }
        try add(0); try add(1)
        XCTAssertNotNil(cache.cached(urls[0]))
        try add(2)
        XCTAssertNil(cache.cached(urls[1]))
        XCTAssertNotNil(cache.cached(urls[0]))
        XCTAssertEqual(cache.byteCount, 8)
        let restored = ArtworkMediaCache(root: root, sandbox: sandbox, limit: 8)
        XCTAssertNotNil(restored.cached(urls[2]))
        restored.clear()
        XCTAssertEqual(restored.byteCount, 0)
        XCTAssertNil(restored.cached(urls[0]))
    }

    func testHLSPackageIsNotMovedAndOversizedMediaIsRejected() throws {
        let sandbox = try temporarySandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let cache = ArtworkMediaCache(root: sandbox.appendingPathComponent("cache"), sandbox: sandbox, limit: 8)
        let package = sandbox.appendingPathComponent("system.movpkg", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 8).write(to: package.appendingPathComponent("segment"))
        let url = try XCTUnwrap(URL(string: "https://example.com/cover.m3u8"))
        XCTAssertEqual(try cache.insert(package, for: url, managedPackage: true).standardizedFileURL, package.standardizedFileURL)
        XCTAssertEqual(cache.byteCount, 8)
        let oversized = sandbox.appendingPathComponent("large")
        try Data(repeating: 1, count: 9).write(to: oversized)
        XCTAssertThrowsError(try cache.insert(oversized, for: XCTUnwrap(URL(string: "https://example.com/large.mp4")), managedPackage: false))
        XCTAssertEqual(cache.byteCount, 8)
        XCTAssertNotNil(cache.cached(url))
    }

    func testUpgradeDoesNotOptIntoVideoOrCellularAndPortraitDoesNotReplaceSquare() async {
        let configuration = AnimatedArtworkConfiguration()
        XCTAssertFalse(configuration.enabled)
        XCTAssertFalse(configuration.allowCellular)
        let loader = AnimatedArtworkLoader()
        await loader.load(trackID: "one", assets: {
            [.init(kind: .portraitVideo, url: URL(string: "https://example.com/tall.m3u8")!, albumID: "1", storefront: "us")]
        }, download: { _ in XCTFail("Portrait must not be downloaded by square mode"); return URL(fileURLWithPath: "/unused") })
        XCTAssertEqual(loader.status, .unavailable)
        XCTAssertNil(loader.localURL)
    }

    func testLateResultCannotReplaceNewSong() async throws {
        let loader = AnimatedArtworkLoader()
        let asset = try ArtworkAsset(kind: .squareVideo, url: XCTUnwrap(URL(string: "https://example.com/square.m3u8")), albumID: "1", storefront: "us")
        var completion: CheckedContinuation<URL, Never>?
        let old = Task {
            await loader.load(trackID: "old", assets: { [asset] }, download: { _ in
                await withCheckedContinuation { completion = $0 }
            })
        }
        for _ in 0 ..< 1000 {
            if completion != nil {
                break
            }
            await Task.yield()
        }
        guard let completion else { old.cancel(); XCTFail("Download did not start"); return }
        let newURL = URL(fileURLWithPath: "/new.movpkg")
        await loader.load(trackID: "new", assets: { [asset] }, download: { _ in newURL })
        completion.resume(returning: URL(fileURLWithPath: "/old.movpkg"))
        await old.value
        XCTAssertEqual(loader.trackID, "new")
        XCTAssertEqual(loader.localURL, newURL)
        XCTAssertEqual(loader.status, .ready)
        loader.reset()
        XCTAssertNil(loader.localURL)
    }
}
