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
        var selectedRows: Set<Int> = []
        var rebase = false
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
    private var retargetingRows: Set<Int> = []
    private var deferredCatchUp: [Int: (time: Double, elapsed: Double)] = [:]
    private(set) var dispatchCount = 0
    private(set) var armCount = 0
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
    func reset() {
        entries.removeAll()
        frame = nil
        retargetingRows.removeAll()
        deferredCatchUp.removeAll()
        dispatchCount = 0
        armCount = 0
    }

    func cursorStates(key: String) -> [LyricsBlossomRunSweep.Cursor] { entries[key]?.cursors ?? [] }

    func beginFrame(_ next: Frame) {
        let rebuild = next.rebase || frame == nil || frame?.revision != next.revision || frame?.family != next.family || frame?.offset != next.offset
            || (frame?.draftTime != nil && next.draftTime == nil)
        frame = next
        if rebuild {
            retargetingRows = next.selectedRows
            deferredCatchUp.removeAll()
        } else if next.draftTime != nil {
            deferredCatchUp.removeAll()
        } else if next.playing {
            for row in Array(deferredCatchUp.keys) {
                deferredCatchUp[row]?.elapsed += next.delta
                if (deferredCatchUp[row]?.elapsed ?? 0) >= 0.25 { deferredCatchUp.removeValue(forKey: row) }
            }
        }
        for key in Array(entries.keys) {
            guard var entry = entries.removeValue(forKey: key) else { continue }
            update(&entry, rebuild: rebuild)
            entries[key] = entry
        }
        applySelection(entered: [], left: [], catchUp: next.catchUpRows)
    }
    private func update(_ entry: inout Entry, rebuild: Bool) {
        guard let frame else { return }
        let effective = (frame.draftTime ?? frame.time) + (frame.family == 3 ? 0.1 : 0)
        for index in entry.cursors.indices {
            let segments = entry.layout.records[index]
            if rebuild {
                entry.cursors[index].reconstruct(now: Float(frame.draftTime == nil ? frame.time : effective), segments: segments)
            } else if frame.draftTime != nil {
                entry.cursors[index].step(now: Float(effective), delta: Float(frame.delta), segments: segments, force: true)
            } else if frame.playing {
                // Auxiliary text keeps its own clock. Only body rows take
                // their retargeting state from the selection's enter/leave events.
                entry.cursors[index].stepRow(now: Float(frame.time), delta: Float(frame.delta), segments: segments,
                    flag40: frame.family == 3, flag41: !entry.allowsCatchUp || retargetingRows.contains(entry.row), force: false)
            }
        }
        if rebuild { reconstructionCount += 1 }
        entry.sample = entry.layout.sample(cursors: entry.cursors)
    }

    /// Called after the old run interpolation has consumed this display frame.
    func applySelection(entered: Set<Int>, left: Set<Int>, catchUp: Set<Int>) {
        retargetingRows.subtract(left)
        retargetingRows.formUnion(entered)
        guard let frame, frame.playing, frame.draftTime == nil, !catchUp.isEmpty else { return }
        dispatchCount += catchUp.count
        var missing = catchUp
        for key in Array(entries.keys) {
            guard var entry = entries[key], entry.allowsCatchUp, catchUp.contains(entry.row) else { continue }
            missing.remove(entry.row)
            arm(&entry)
            entries[key] = entry
        }
        for row in missing where deferredCatchUp[row] == nil {
            deferredCatchUp[row] = (frame.time, 0)
        }
    }

    private func arm(_ entry: inout Entry) {
        for index in entry.cursors.indices where !entry.cursors[index].suppressed && !entry.layout.records[index].isEmpty {
            entry.cursors[index].catchUp(segments: entry.layout.records[index])
            armCount += 1
        }
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
        if allowsCatchUp, let event = deferredCatchUp.removeValue(forKey: row), let frame {
            let time = Float(event.time + (frame.family == 3 ? 0.1 : 0))
            for index in entry.cursors.indices {
                entry.cursors[index].reconstruct(now: time, segments: layout.records[index])
            }
            arm(&entry)
            for index in entry.cursors.indices {
                entry.cursors[index].stepRow(now: Float(frame.time), delta: Float(event.elapsed),
                    segments: layout.records[index], flag40: true, flag41: false, force: false)
            }
            entry.sample = layout.sample(cursors: entry.cursors)
        }
        entries[key] = entry
        return entry.sample
    }
}
