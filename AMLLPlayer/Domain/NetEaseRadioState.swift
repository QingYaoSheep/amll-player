import Foundation

/// Persisted independently from the ordinary queue. Contains identities, never media URLs.
struct NetEaseRadioState: Codable {
    var ordinary: NetEaseQueueState
    var radio: NetEaseQueueState
    var recentIDs: [String] = []

    static func pendingCount(_ queue: NetEaseQueueState) -> Int {
        guard let index = queue.entries.firstIndex(where: { $0.id == queue.currentID }) else { return queue.entries.count }
        return queue.entries.count - index - 1
    }
    mutating func append(_ items: [MusicCatalogItem], to queue: inout NetEaseQueueState) -> Int {
        var seen = Set(recentIDs + queue.entries.map { $0.item.spotifyID })
        let slots = max(0, 10 - Self.pendingCount(queue))
        let accepted = items.filter { $0.service == .netease && $0.kind == .track && seen.insert($0.spotifyID).inserted }.prefix(slots)
        queue.entries += accepted.map { NetEaseQueueEntry(item: $0) }
        recentIDs = Array((recentIDs + accepted.map(\.spotifyID)).suffix(100))
        if queue.currentID == nil { queue.currentID = queue.entries.first?.id }
        radio = queue
        return accepted.count
    }
    static func trimHistory(_ queue: inout NetEaseQueueState) {
        guard let current = queue.entries.firstIndex(where: { $0.id == queue.currentID }), current > 50 else { return }
        queue.entries.removeFirst(current - 50)
    }
    var isValid: Bool {
        ordinary.entries.count <= 10000 && radio.entries.count <= 61 && recentIDs.count <= 100
            && !radio.shuffle && radio.repeatMode == .off
            && (radio.entries.isEmpty || radio.entries.contains { $0.id == radio.currentID })
            && Set(radio.entries.map(\.id)).count == radio.entries.count
    }
}

enum NetEaseRadioError: LocalizedError {
    case modesUnavailable, noRecommendations, unavailableBatch
    var errorDescription: String? {
        switch self {
        case .modesUnavailable: "私人 FM 自动安排接下来播放的歌曲；退出 FM 后可使用随机、循环和队列编辑。"
        case .noRecommendations: "暂时没有新的私人 FM 推荐，请稍后重试，或退出 FM 恢复普通队列。"
        case .unavailableBatch: "连续五首推荐暂时无法播放，请重试或退出私人 FM。"
        }
    }
}
