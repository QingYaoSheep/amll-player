import Foundation

/// Optional source flags prevent an unknown mapping from silently permitting
/// takeover or catch-up. Native family-2/3 selection remains a separate path.
struct LyricsBlossomSelectionSchedule {
    struct Record {
        var index: Int
        var start: Double
        var end: Double
        var lastWordEnd: Double
        var flag20: Bool? = nil
        var flag21: Bool? = nil
        var permitsTakeover: Bool? = nil
        var permitsCatchUp: Bool? = nil
    }
    struct Output {
        var selected: [Int]
        var pending: Int?
        var focusOverride: Int? = nil
        var takeover = false
        var catchUp: Set<Int> = []
        var diagnostic: String
    }
    static func lead(gap: Double = 0, adaptive: Bool = false) -> Double {
        let u = (min(0.75, max(0.2, gap)) - 0.2) / 0.55
        let z = adaptive ? 0.9 - 0.12 * u : 0.9
        let period = adaptive ? 0.48 + 0.27 * u : 2 * Double.pi / 10
        let omega = 2 * Double.pi / period
        return log(1 / (0.00073 * sqrt(1 - z * z))) / (z * omega)
    }
    /// Exact ordinary-family checker result: 1 means catch-up, 2 means append.
    /// Unknown flags or hold state disable this source-specific operation.
    static func catchUpCode(now: Double, current c: Record, pending p: Record,
                            count: Int, capacity: Int, holding: Bool?) -> Int? {
        guard let holding, let p20 = p.flag20, let p21 = p.flag21,
              let c20 = c.flag20, let c21 = c.flag21,
              c.permitsCatchUp == true, p.permitsCatchUp == true else { return nil }
        guard !holding else { return 0 }
        let t = now + 0.25
        guard t + lead(gap: p.start - c.end) >= p.start else { return 0 }
        if !p20 && !p21 && !c20 && !c21 && count < capacity && p.index > c.index && t > p.start { return 2 }
        let shift = p20 ? 0.0 : 0.5
        return t > c.end - shift || (c21 && t > c.lastWordEnd - shift) ? 1 : 0
    }
    func evaluate(now: Double, family: Int, records: [Record], fallback: [Int], capacity: Int,
                  playing: Bool, scrubbing: Bool, holding: Bool? = nil) -> Output {
        let ordered = records // Preordered once at document construction.
        let pending = ordered.first { $0.start > now }
        var result = Output(selected: fallback, pending: pending?.index,
            diagnostic: family == 2 || family == 3 ? "version selection: native compatibility" : "ordinary fixed lead adaptation; takeover/catch-up disabled: source flags/hold state unmapped")
        guard family != 2 && family != 3 else { return result }
        // Keep the newest ordinary record as it crosses its actual start, so
        // the timeline cannot jump back to an older overlapping voice. Other
        // families keep the original buffered anchor.
        if playing && !scrubbing { result.focusOverride = fallback.last }
        // Ordinary selection lead is a native selection-record adaptation.
        // Takeover/catch-up retain the stricter source guards below.
        if let p = pending, playing, !scrubbing, now + Self.lead() >= p.start {
            result.focusOverride = p.index
            result.selected = Array((fallback + [p.index]).sorted().suffix(max(1, capacity)))
        }
        guard playing, !scrubbing, let last = result.selected.last,
              let current = ordered.first(where: { $0.index == last }) else { return result }
        if current.permitsTakeover == true {
            result.takeover = (current.end - now) - 0.5 < 0.4
        }
        if let p = pending, let c = fallback.last.flatMap({ index in ordered.first { $0.index == index } }),
           Self.catchUpCode(now: now, current: c, pending: p, count: fallback.count,
                           capacity: capacity, holding: holding) == 1 {
            result.catchUp = Set(fallback)
        }
        return result
    }
}
