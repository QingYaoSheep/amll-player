import Foundation

/// Selection time is in media seconds. Motion tickets use the display clock
/// and are invalidated by the next command on the same row and channel.
struct LyricsBlossomSelectionSchedule {
    struct Record: Decodable {
        var index: Int
        var start: Double
        var end: Double
        var lastWordEnd: Double
        var sourceStart: Double? = nil
        var interlude = false

        func tailReached(at now: Double, shift: Double) -> Bool {
            now > end - shift || (!interlude && now > lastWordEnd - shift)
        }
    }

    enum Kind: Int { case none, initial, append, replace }
    enum Channel: Int, Hashable { case position, scale, light, opacity }
    struct Ticket: Hashable {
        let row: Int
        let channel: Channel
        let generation: Int
    }

    struct Output {
        var selected: [Int] = []
        /// Activity is consumed before enter/exit keys update display selection.
        var active: [Int] = []
        var pending: Int?
        var deadline = -1.0
        var kind = Kind.none
        var catchUp: [Int] = []
        var previewCode = 0
        var removed: Int?
        var enterIndex: Int?
        var takeover = false
        var diagnostic = ""
        var entered: [Int] = []
        var left: [Int] = []
    }

    private(set) var state = Output()
    private var lastPulse = -Double.infinity
    private var tickets: Set<Ticket> = []
    private var positionTicket: Ticket?
    private var bypassClock = false

    static func supported(_ family: Int) -> Bool { family == 2 || family == 3 || family == 0 }

    static func lead(family: Int = 0, gap: Double = 0, adaptive: Bool = false) -> Double {
        let u = (min(0.75, max(0.2, gap)) - 0.2) / 0.55
        let z = adaptive ? 0.9 - 0.12 * u : 0.9
        let period = adaptive ? 0.48 + 0.27 * u : 2 * Double.pi / 10
        let root = sqrt(1 - z * z), decay = z * 2 * Double.pi / period
        return family == 2 || family == 3
            ? log((z / root + 1) / 0.001) / decay
            : log(1 / (0.00073 * root)) / decay
    }

    /// The source previews the old activity list before it attempts a
    /// transition. A preview can dispatch with kind == none.
    static func dispatch(family: Int, now: Double, records: [Record], selected: [Int],
                         pending: Int?, capacity: Int, mainHold: Bool, ticketHold: Bool,
                         deadline: Double, bypassClock: Bool = false, adaptive: Bool = false) -> Output {
        var output = Output(selected: selected, pending: pending, deadline: deadline)
        let special = family == 2 || family == 3
        if special && mainHold { return output }
        if special, !records.contains(where: { $0.index == output.pending }) {
            output.pending = seed(in: records, at: now, retainLast: family == 3)
        }
        guard let p = records.firstIndex(where: { $0.index == output.pending }) else { return output }
        let pendingRecord = records[p]
        let back = selected.last.flatMap { key in records.firstIndex { $0.index == key } }
        if family == 2, !selected.isEmpty, back == nil { return output }
        let currentIndex: Int?
        if family == 2 {
            currentIndex = selected.compactMap { key in records.firstIndex { $0.index == key } }
                .reduce(nil as Int?) { best, i in
                    guard let best, records[best].end > records[i].end else { return i }
                    return best
                }
        } else {
            currentIndex = back
        }
        let current = currentIndex.map { records[$0] }
        let lead = lead(family: family, gap: back.map { pendingRecord.start - records[$0].end } ?? 0, adaptive: adaptive)
        let clockHold = !bypassClock && deadline >= 0 && now < deadline
        let subHold = family == 3 && clockHold
        let shift = !special && pendingRecord.interlude ? 0.0 : 0.5
        let increasing = currentIndex.map { $0 < p } == true && current?.interlude == false && !pendingRecord.interlude
        let room = family == 2 || selected.count < capacity
        let preview = now + 0.25
        if !mainHold, !subHold, let current, pendingRecord.start <= preview + lead {
            if increasing && room && pendingRecord.start < preview {
                output.previewCode = 2
            } else if current.tailReached(at: preview, shift: shift) {
                output.previewCode = 1
                output.catchUp = selected
            }
        }
        if family == 2, output.catchUp.isEmpty, selected.count > 1, let first = selected.first,
           let record = records.first(where: { $0.index == first }), record.end < now + lead {
            output.removed = output.selected.removeFirst()
        }
        guard (special || !ticketHold), pendingRecord.start <= now + lead else { return output }
        if current == nil {
            if family == 2 { output.selected.append(pendingRecord.index) }
            else { output.selected = [pendingRecord.index] }
            output.kind = .initial
        } else if increasing && room && pendingRecord.start < now {
            output.selected.append(pendingRecord.index)
            output.kind = .append
        } else if let current, current.tailReached(at: now, shift: shift), !subHold {
            if !special, increasing, (pendingRecord.end - now) - 0.5 < 0.4 {
                if !room { output.removed = output.selected.removeFirst() }
                output.selected.append(pendingRecord.index)
                output.kind = .append
            } else if special || !clockHold {
                output.selected = [pendingRecord.index]
                output.kind = .replace
            }
        }
        guard output.kind != .none else { return output }
        output.enterIndex = pendingRecord.index
        output.pending = records.indices.contains(p + 1) ? records[p + 1].index : nil
        let until = now + (output.kind == .append ? 0.3 : lead + 0.5)
        if family == 3 {
            output.deadline = output.kind == .append ? -1 : Double(Float(until))
        } else if family == 0 {
            let nextStart = records.indices.contains(p + 1) ? records[p + 1].sourceStart ?? records[p + 1].start : now
            output.deadline = Double(Float(nextStart > now ? min(until, nextStart) : until))
        }
        return output
    }

    static func seed(in records: [Record], at now: Double, retainLast: Bool = true) -> Int? {
        var recent: Int?
        for i in records.indices where records[i].start <= now {
            if recent.map({ records[$0].start <= records[i].start }) ?? true { recent = i }
        }
        guard let i = recent else { return records.first?.index }
        if records[i].end > now { return records[i].index }
        return records.indices.contains(i + 1) ? records[i + 1].index : (retainLast ? records[i].index : nil)
    }

    mutating func rebase(records: [Record], now: Double, capacity: Int, bypassClock: Bool, family: Int = 0) {
        let overlapping = records.filter { $0.start <= now && now < $0.end }
        let selected = (family == 2 ? overlapping : Array(overlapping.suffix(capacity))).map(\.index)
        let pending = selected.last.flatMap { key in
            records.firstIndex { $0.index == key }.flatMap { i in
                records.indices.contains(i + 1) ? records[i + 1].index : nil
            }
        }
        state = Output(selected: selected, active: selected,
                       pending: selected.isEmpty ? Self.seed(in: records, at: now, retainLast: family != 2) : pending)
        tickets.removeAll()
        positionTicket = nil
        lastPulse = -.infinity
        self.bypassClock = bypassClock
    }

    mutating func invalidateTickets() {
        tickets.removeAll()
        positionTicket = nil
    }

    mutating func installed(_ ticket: Ticket, family: Int, kind: Kind) {
        guard kind != .none || family == 2 else { return }
        if family == 3 {
            if ticket.channel == .position && kind != .append { positionTicket = ticket }
        } else {
            tickets.insert(ticket)
        }
    }

    mutating func update(family: Int, now: Double, wall: Double, records: [Record],
                         capacity: Int, running: Bool, rebased: Bool, browsing: Bool,
                         adaptive: Bool = false,
                         isPending: (Ticket) -> Bool) -> Output {
        if !rebased { bypassClock = false }
        if let positionTicket, !isPending(positionTicket) { self.positionTicket = nil }
        tickets = tickets.filter(isPending)
        let ticketHold = !bypassClock && !tickets.isEmpty
        let clockHold = !bypassClock && state.deadline >= 0 && now < state.deadline
        let mainHold = family == 3 ? positionTicket != nil : ticketHold || (family != 2 && clockHold)
        let pulse = running && !rebased && !records.isEmpty
            && ((family != 2 && family != 3) || (wall.isFinite && wall - lastPulse >= 1.0 / 30))
        var output = Output(selected: state.selected, active: state.active, pending: state.pending, deadline: state.deadline)
        if pulse {
            lastPulse = wall
            output = Self.dispatch(family: family, now: now, records: records, selected: state.active,
                pending: state.pending, capacity: capacity, mainHold: mainHold, ticketHold: ticketHold,
                deadline: state.deadline, bypassClock: bypassClock, adaptive: adaptive)
            output.active = output.selected
            if family == 2 {
                output.selected = state.selected
                if let removed = output.removed { output.selected.removeAll { $0 == removed } }
                if let entered = output.enterIndex {
                    if output.kind == .replace { output.selected = [entered] }
                    else { output.selected.append(entered) }
                }
            }
            output.entered = output.selected.filter { !state.selected.contains($0) }
            output.left = state.selected.filter { !output.selected.contains($0) }
        }
        if family == 0, running, !browsing, !mainHold,
           let key = output.selected.last, let last = records.first(where: { $0.index == key }), !last.interlude {
            output.takeover = (last.end - now) - 0.5 < 0.4
        }
        output.diagnostic = "family=\(family) pulse=\(pulse) mainHold=\(mainHold) clockHold=\(clockHold) deadline=\(output.deadline) tickets=\(tickets.count) positionTicket=\(String(describing: positionTicket)) kind=\(output.kind) preview=\(output.previewCode) entered=\(output.entered) left=\(output.left) catchUp=\(output.catchUp)"
        state = output
        return output
    }
}
