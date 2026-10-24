import XCTest
@testable import AMLLPlayer

final class NetEaseRadioStateTests: XCTestCase {
    private func songs(_ ids: Range<Int>) -> [MusicCatalogItem] {
        ids.map { .init(spotifyID: String($0), kind: .track, name: "Song \($0)", subtitle: "", artworkURL: nil, availability: .available, service: .netease) }
    }
    func testBatchDedupCapacityAndHistoryBounds() {
        var queue = NetEaseQueueState()
        var radio = NetEaseRadioState(ordinary: .init(), radio: queue)
        XCTAssertEqual(radio.append(songs(0..<20), to: &queue), 10)
        XCTAssertEqual(radio.append(songs(0..<20), to: &queue), 1)
        XCTAssertEqual(NetEaseRadioState.pendingCount(queue), 10)
        for index in 0..<150 {
            queue.currentID = queue.entries.last?.id
            NetEaseRadioState.trimHistory(&queue)
            _ = radio.append(songs((100 + index * 10)..<(110 + index * 10)), to: &queue)
            XCTAssertLessThanOrEqual(queue.entries.count, 61)
            XCTAssertLessThanOrEqual(radio.recentIDs.count, 100)
        }
        let remaining = NetEaseRadioState.pendingCount(queue)
        queue.currentID = queue.entries[queue.entries.count - remaining - 2].id
        XCTAssertEqual(NetEaseRadioState.pendingCount(queue), remaining + 1)
    }
    func testPersistenceRetainsOrdinaryPositionAndModes() throws {
        var ordinary = NetEaseQueueState(entries: songs(0..<3).map { NetEaseQueueEntry(item: $0) })
        ordinary.currentID = ordinary.entries[1].id; ordinary.position = 42.5; ordinary.shuffle = true; ordinary.repeatMode = .all
        let record = NetEaseRadioState(ordinary: ordinary, radio: .init())
        let decoded = try JSONDecoder().decode(NetEaseRadioState.self, from: JSONEncoder().encode(record))
        XCTAssertEqual(decoded.ordinary.position, 42.5)
        XCTAssertEqual(decoded.ordinary.currentID, ordinary.currentID)
        XCTAssertTrue(decoded.ordinary.shuffle); XCTAssertEqual(decoded.ordinary.repeatMode, .all)
        XCTAssertTrue(decoded.isValid)
    }
}
