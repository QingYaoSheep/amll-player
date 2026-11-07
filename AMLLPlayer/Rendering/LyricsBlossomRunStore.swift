import Foundation

/// Engine-owned cursor state survives UIView eviction. All entries advance once
/// per display frame, including temporarily offscreen rows and auxiliary TTML.
final class LyricsBlossomRunStore {
    struct Frame {
        var time: Double
        var delta: Double
        var playing: Bool
        var revision: Int
        var family: Int
        var offset: Double = 0
        var draftTime: Double? = nil
        var catchUpRows: Set<Int> = []
    }
    private struct Entry {
        var layout: LyricsBlossomRunLayout
        var cursors: [LyricsBlossomRunSweep.Cursor]
        var row: Int
        var allowsCatchUp: Bool
        var sample: LyricsBlossomRunLayout.Sample
    }
    private var entries: [String: Entry] = [:]
    private var frame: Frame?
    private(set) var reconstructionCount = 0
    var count: Int { entries.count }
    var active: Bool { entries.values.contains { $0.cursors.contains { $0.active } } }
    var diagnostic: String {
        entries.keys.sorted().prefix(3).compactMap { key -> String? in
            guard let entry = entries[key] else { return nil }
            let states = entry.cursors.prefix(3).map {
                "cursor=\($0.value),from=\($0.from),to=\($0.to),elapsed=\($0.elapsed),duration=\($0.duration),active=\($0.active),index=\($0.lastIndex),suppressed=\($0.suppressed)"
            }.joined(separator: ";")
            return "\(key)[\(states)] fallback=\(entry.layout.fallbackCount)"
        }.joined(separator: " | ")
    }
    func reset() { entries.removeAll(); frame = nil }

    func beginFrame(_ next: Frame) {
        let rebuild = frame == nil || frame?.revision != next.revision || frame?.family != next.family || frame?.offset != next.offset
            || (frame?.draftTime != nil && next.draftTime == nil)
        frame = next
        for key in Array(entries.keys) {
            guard var entry = entries.removeValue(forKey: key) else { continue }
            update(&entry, rebuild: rebuild)
            entries[key] = entry
        }
    }
    private func update(_ entry: inout Entry, rebuild: Bool) {
        guard let frame else { return }
        let effective = (frame.draftTime ?? frame.time) + (frame.family == 3 ? 0.1 : 0)
        for index in entry.cursors.indices {
            let segments = entry.layout.records[index]
            if rebuild {
                entry.cursors[index].reconstruct(now: Float(effective), segments: segments)
            } else if frame.draftTime != nil {
                entry.cursors[index].step(now: Float(effective), delta: Float(frame.delta), segments: segments, force: true)
            } else if frame.playing {
                // Layout/resync sets the source row41 path. Its lifetime is
                // explicit: retained until the next layout/reset, never guessed
                // from native focus or cleared merely because a frame passed.
                entry.cursors[index].stepRow(now: Float(frame.time), delta: Float(frame.delta), segments: segments,
                    flag40: frame.family == 3, flag41: true, force: false)
            }
            if entry.allowsCatchUp && frame.playing && frame.catchUpRows.contains(entry.row) {
                entry.cursors[index].catchUp(segments: segments)
            }
        }
        if rebuild { reconstructionCount += 1 }
        entry.sample = entry.layout.sample(cursors: entry.cursors)
    }
    func sample(key: String, row: Int, layout: LyricsBlossomRunLayout, allowsCatchUp: Bool = true) -> LyricsBlossomRunLayout.Sample {
        if var entry = entries[key], entry.layout.identity == layout.identity || entry.layout.equivalent(to: layout) {
            entry.layout = layout; entry.allowsCatchUp = allowsCatchUp; entries[key] = entry
            return entry.sample
        }
        var entry = Entry(layout: layout, cursors: layout.records.map { _ in .init() }, row: row, allowsCatchUp: allowsCatchUp,
                          sample: layout.sample(time: frame?.time ?? 0))
        update(&entry, rebuild: true)
        entries[key] = entry
        return entry.sample
    }
}
