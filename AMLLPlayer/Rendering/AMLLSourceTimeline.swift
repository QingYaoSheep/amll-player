import Foundation

struct AMLLGroupTiming: Codable, Equatable, Sendable {
    var startTime: Double
    var endTime: Double
}

/// Source port: core/src/lyric-player/base/timeline.ts. All times are milliseconds.
struct AMLLSourceTimeline: Sendable {
    private(set) var hot: Set<Int> = []
    private(set) var buffered: Set<Int> = []
    private(set) var focus = 0
    private(set) var time = 0.0

    @discardableResult
    mutating func update(time: Double, groups: [AMLLGroupTiming], seeking: Bool, hasBottomContent: Bool) -> Bool {
        guard time.isFinite else { return false }
        let nextHot = Set(groups.indices.filter { groups[$0].startTime <= time && time < groups[$0].endTime })
        let added = nextHot.subtracting(hot)
        let removedBuffered = buffered.subtracting(nextHot)
        hot = nextHot
        self.time = time
        var layout = false
        if seeking {
            buffered = hot
            focus = buffered.min() ?? groups.firstIndex(where: { $0.startTime >= time }) ?? groups.count
            layout = true
        } else if !added.isEmpty {
            buffered.formUnion(added)
            buffered.subtract(removedBuffered)
            if let first = buffered.min() {
                focus = first
            }
            layout = true
        } else if !removedBuffered.isEmpty, removedBuffered == buffered {
            buffered.formIntersection(hot)
            layout = true
        }
        if buffered.isEmpty, let last = groups.last, time >= last.endTime {
            let target = hasBottomContent ? groups.count : groups.count - 1
            if focus != target {
                focus = target; layout = true
            }
        }
        return layout
    }
}
