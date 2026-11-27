import Foundation

/// A PiP presentation of the main lyric selector's events. Run targets and the
/// original row transitions still belong to the lyric engine.
struct DesktopLyricsScrollHandoff {
    struct Selection {
        var selected: [Int] = []
        var pending: Int?
        var early: Int?
        var departing: [Int] = []
    }

    private(set) var upcoming: Int?
    private var started: [Int: Double] = [:]
    var needsPruning: Bool { !started.isEmpty }

    mutating func update(_ selection: Selection, at now: Double, delta: Double,
                         interlude: Bool, immediately: Bool) {
        if interlude || upcoming != selection.pending || selection.selected.contains(upcoming ?? -1) {
            upcoming = nil
        }
        if !interlude, let early = selection.early, early == selection.pending { upcoming = early }
        // A pulse is sampled at the end of the display tick. Show both
        // channels on that tick and do not re-arm the same old group.
        let lead = immediately ? DesktopLyricsDeparture.duration : min(max(0, delta), 1.0 / 60)
        for group in selection.departing where started[group] == nil {
            started[group] = now - lead
        }
    }

    func departure(_ group: Int, at now: Double) -> DesktopLyricsDeparture? {
        started[group].map { DesktopLyricsDeparture(elapsed: now - $0) }
    }

    mutating func keep(nearby groups: Set<Int>) {
        started = started.filter { groups.contains($0.key) }
    }

    func isAnimating(at now: Double) -> Bool {
        started.values.contains { now - $0 < DesktopLyricsDeparture.duration }
    }
}
