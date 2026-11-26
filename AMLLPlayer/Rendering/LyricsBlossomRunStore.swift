import Foundation

/// Engine-owned cursor state survives UIView eviction. All entries advance once
/// per display frame, including temporarily offscreen rows and auxiliary TTML.
final class LyricsBlossomRunStore {
    enum Role {
        case body
        case independent
        case pronunciation(bodyEnd: Double)
    }

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
        var refreshClock = true
        var selectionRebased = false
    }
    private struct Entry {
        var layout: LyricsBlossomRunLayout
        var cursors: [LyricsBlossomRunSweep.Cursor]
        var row: Int
        var role: Role
        var sample: LyricsBlossomRunLayout.Sample
        var clock: Float?
    }
    private var entries: [String: Entry] = [:]
    private var frame: Frame?
    private var retargetingRows: Set<Int> = []
    private var entryResyncRows: Set<Int> = []
    private(set) var rewindRows: Set<Int> = []
    private var deferredCatchUp: [Int: (time: Double, elapsed: Double)] = [:]
    private var pronunciationEvents: [Int: Double] = [:]
    private(set) var dispatchCount = 0
    private(set) var armCount = 0
    private(set) var reconstructionCount = 0
    var count: Int { entries.count }
    var draftTime: Double? { frame?.draftTime }
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
        entryResyncRows.removeAll()
        rewindRows.removeAll()
        deferredCatchUp.removeAll()
        pronunciationEvents.removeAll()
        dispatchCount = 0
        armCount = 0
    }

    func cursorStates(key: String) -> [LyricsBlossomRunSweep.Cursor] { entries[key]?.cursors ?? [] }

    func beginFrame(_ next: Frame) {
        let rebuild = next.rebase || frame == nil || frame?.revision != next.revision || frame?.family != next.family || frame?.offset != next.offset
            || (frame?.draftTime != nil && next.draftTime == nil)
        frame = next
        entryResyncRows.removeAll(keepingCapacity: true)
        if rebuild || next.selectionRebased { retargetingRows = next.selectedRows }
        if rebuild {
            deferredCatchUp.removeAll()
            pronunciationEvents.removeAll()
        } else if next.draftTime != nil {
            deferredCatchUp.removeAll()
            pronunciationEvents.removeAll()
        } else if next.playing {
            for row in Array(deferredCatchUp.keys) {
                if let elapsed = deferredCatchUp[row]?.elapsed {
                    deferredCatchUp[row]?.elapsed = min(0.25, elapsed + next.delta)
                }
            }
        }
        rewindRows.removeAll(keepingCapacity: true)
        if !rebuild, next.draftTime == nil, next.refreshClock {
            let now = Float(next.time)
            for entry in entries.values where entry.clock.map({ $0 - now >= 0.5 }) == true {
                rewindRows.insert(entry.row)
            }
            for row in rewindRows {
                deferredCatchUp.removeValue(forKey: row)
                pronunciationEvents.removeValue(forKey: row)
            }
        }
        for key in Array(entries.keys) {
            guard var entry = entries.removeValue(forKey: key) else { continue }
            update(&entry, rebuild: rebuild, reset: rewindRows.contains(entry.row))
            entries[key] = entry
        }
        applySelection(entered: [], left: [], catchUp: next.catchUpRows)
    }
    private func update(_ entry: inout Entry, rebuild: Bool, reset: Bool = false) {
        guard let frame else { return }
        let now = Float(frame.time)
        if rebuild || reset || entry.clock == nil || (frame.refreshClock && now >= (entry.clock ?? now)) {
            entry.clock = now
        }
        let effective = Float(frame.draftTime ?? frame.time) + (frame.family == 3 ? 0.1 : 0)
        let clock = entry.clock ?? now
        for index in entry.cursors.indices {
            let segments = entry.layout.records[index]
            if reset { entry.cursors[index] = .init() }
            if rebuild {
                entry.cursors[index].reconstruct(now: Float(frame.draftTime == nil ? frame.time : effective), segments: segments)
            } else if frame.draftTime != nil {
                entry.cursors[index].step(now: Float(effective), delta: Float(frame.delta), segments: segments, force: true)
            } else if frame.playing {
                let retarget: Bool
                if case .body = entry.role { retarget = retargetingRows.contains(entry.row) }
                else { retarget = true }
                entry.cursors[index].stepRow(now: clock, delta: Float(frame.delta), segments: segments,
                    flag40: frame.family == 3, flag41: retarget, force: false)
            }
        }
        if rebuild { reconstructionCount += 1 }
        if frame.playing, frame.draftTime == nil { armPronunciation(&entry, now: frame.time) }
        entry.sample = entry.layout.sample(cursors: entry.cursors)
    }

    /// Called after the old run interpolation has consumed this display frame.
    func applySelection(entered: Set<Int>, left: Set<Int>, catchUp: Set<Int>) {
        retargetingRows.subtract(left)
        retargetingRows.formUnion(entered)
        guard let frame, frame.playing, frame.draftTime == nil else { return }
        if frame.family == 3, !entered.isEmpty {
            entryResyncRows.formUnion(entered)
            for key in Array(entries.keys) {
                guard var entry = entries[key], entered.contains(entry.row), case .body = entry.role else { continue }
                resyncEnteredRun(&entry, time: Float(frame.time))
                entries[key] = entry
            }
        }
        guard !catchUp.isEmpty else { return }
        dispatchCount += catchUp.count
        var missing = catchUp
        for row in catchUp where pronunciationEvents[row] == nil { pronunciationEvents[row] = frame.time }
        for key in Array(entries.keys) {
            guard var entry = entries[key], catchUp.contains(entry.row) else { continue }
            if case .body = entry.role {
                missing.remove(entry.row)
                arm(&entry)
            } else {
                armPronunciation(&entry, now: frame.time)
                entry.sample = entry.layout.sample(cursors: entry.cursors)
            }
            entries[key] = entry
        }
        for row in missing where deferredCatchUp[row] == nil {
            deferredCatchUp[row] = (frame.time, 0)
        }
    }

    private func resyncEnteredRun(_ entry: inout Entry, time: Float) {
        entry.clock = time
        for index in entry.cursors.indices {
            entry.cursors[index].resync(effectiveTime: time + 0.1, resetRuns: true, segments: entry.layout.records[index])
        }
        entry.sample = entry.layout.sample(cursors: entry.cursors)
    }

    private func arm(_ entry: inout Entry) {
        for index in entry.cursors.indices where !entry.cursors[index].suppressed && !entry.layout.records[index].isEmpty {
            entry.cursors[index].catchUp(segments: entry.layout.records[index])
            armCount += 1
        }
        entry.sample = entry.layout.sample(cursors: entry.cursors)
    }

    private func armPronunciation(_ entry: inout Entry, now: Double) {
        guard case let .pronunciation(bodyEnd) = entry.role, let dispatched = pronunciationEvents[entry.row],
              let pronunciationEnd = entry.layout.records.compactMap({ $0.last?.end }).max() else { return }
        // Preserve the selector's lead relative to the body. If the
        // pronunciation ends later, wait for its own tail even after the
        // body leaves the selected set.
        let eligibility = dispatched + max(0, Double(pronunciationEnd) - bodyEnd)
        guard now >= eligibility, now <= max(dispatched, Double(pronunciationEnd)) + 0.25 else { return }
        for index in entry.cursors.indices {
            let segments = entry.layout.records[index]
            guard let first = segments.first, now >= Double(first.start), !entry.cursors[index].suppressed else { continue }
            entry.cursors[index].catchUp(segments: segments)
            armCount += 1
        }
    }

    func sample(key: String, row: Int, layout: LyricsBlossomRunLayout, role: Role = .body) -> LyricsBlossomRunLayout.Sample {
        if var entry = entries[key], entry.layout.identity == layout.identity || entry.layout.equivalent(to: layout) {
            entry.layout = layout; entry.role = role; entries[key] = entry
            return entry.sample
        }
        var entry = Entry(layout: layout, cursors: layout.records.map { _ in .init() }, row: row, role: role,
                          sample: layout.sample(time: frame?.time ?? 0))
        if entries[key] != nil, frame?.draftTime == nil {
            // A replaced layout group starts its own tween. Old dispatches
            // refer to the previous group and cannot arm this new cursor.
            deferredCatchUp.removeValue(forKey: row)
            pronunciationEvents.removeValue(forKey: row)
            update(&entry, rebuild: false, reset: true)
        } else {
            update(&entry, rebuild: true)
        }
        if case .body = role, let frame, entryResyncRows.contains(row) {
            resyncEnteredRun(&entry, time: Float(frame.time))
        }
        if case .body = role, let event = deferredCatchUp.removeValue(forKey: row), let frame {
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
