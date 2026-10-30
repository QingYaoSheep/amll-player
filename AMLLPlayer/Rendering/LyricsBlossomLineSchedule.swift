import Foundation

/// Decoded row facts, not word timing. Unknown native flag mappings must not be
/// replaced with guesses based on isBackground/isDuet. See the evidence ledger.
struct LyricsBlossomLineSchedule: Sendable {
    struct Row: Sendable {
        var start: Double
        var flag1B0 = false
        var flag1B2 = false
        var flag1B3 = false
        var containsWordFlag28 = false

        var eligible: Bool { !flag1B0 && !flag1B2 && !containsWordFlag28 }
        var permitsAdvance: Bool { eligible && !flag1B3 }
    }

    static let step = 0.05
    private let prefix: [Int]

    init(rows: [Row]) {
        var counts = [0]
        counts.reserveCapacity(rows.count + 1)
        for row in rows { counts.append(counts.last! + (row.eligible ? 1 : 0)) }
        prefix = counts
    }

    /// FUN_140303510: count eligible rows in (selectedRow, row], then subtract
    /// one. This is unrelated to the number of characters or visible layers.
    func delay(after selectedRow: Int, through row: Int) -> Double {
        guard selectedRow >= 0, row >= selectedRow, row + 1 < prefix.count else { return 0 }
        return Double(max(0, prefix[row + 1] - prefix[selectedRow + 1] - 1)) * Self.step
    }

    /// The family-3 branch uses the rank in the sorted, unique selected rows.
    static func multiLineDelay(rank: Int) -> Double { Double(max(0, rank - 1)) * step }

    static func clearsDelay(wordVersion: Int, paused: Bool, hidden: Bool, advanceSatisfied: Bool) -> Bool {
        wordVersion == 1 || paused || hidden || advanceSatisfied
    }
}

/// Pure per-frame predicate. Its input must be the source selection, not the
/// last word or a future row inferred from its screen position.
struct LyricsBlossomAdvanceState: Equatable, Sendable {
    let satisfied: Bool

    init(now: Double, family: Int, lastSelectedRow: LyricsBlossomLineSchedule.Row?,
         paused: Bool, hidden: Bool, scrubbing: Bool) {
        // FUN_1401e5ec0: settings+0x90 = 0x3fd999999999999a (0.4).
        // FUN_140315c60: subtract another 0.5; comparison is strict.
        if let row = lastSelectedRow, row.permitsAdvance,
           now.isFinite, row.start.isFinite, family != 2, family != 3,
           !paused, !hidden, !scrubbing {
            satisfied = (row.start - now) - 0.5 < 0.4
        } else {
            satisfied = false
        }
    }
}
