import Foundation

/// Production scheduling around the pinned analytic solver. Delays are absolute
/// deadlines, so repeated layout and frame loss cannot postpone a queued row.
/// AMLLSourceSpring remains unchanged for source-parity tests.
struct AMLLScheduledSpring: Sendable {
    struct Schedule: Codable, Equatable, Sendable {
        var revision: Int
        var target: Double
        var scheduledAt: Double?
        var startedAt: Double?
    }

    private var spring: AMLLSourceSpring
    private var parameters = AMLLSourceSpring.Parameters()
    private var time = 0.0
    private var pending: (start: Double, target: Double)?
    private(set) var schedule: Schedule

    init(_ value: Double = 0) {
        spring = AMLLSourceSpring(value)
        schedule = .init(revision: 0, target: value)
    }

    var position: Double {
        spring.position
    }

    var target: Double {
        schedule.target
    }

    var arrived: Bool {
        pending == nil && spring.arrived
    }

    mutating func setPosition(_ value: Double, at time: Double = 0) {
        // Rebuild instead of using the source's setPosition, which deliberately
        // retains queued targets. Direct positioning cancels production work.
        spring = AMLLSourceSpring(value)
        spring.updateParameters(parameters)
        self.time = time
        pending = nil
        schedule = .init(revision: schedule.revision, target: value)
    }

    mutating func updateParameters(_ value: AMLLSourceSpring.Parameters) {
        var merged = parameters
        merged.merge(value)
        guard merged != parameters else { return }
        parameters = merged
        spring.updateParameters(merged)
    }

    mutating func setTarget(_ value: Double, startTime: Double, at time: Double, revision: Int) {
        guard value.isFinite, startTime.isFinite, time.isFinite else { return }
        guard value != schedule.target else { return }
        advance(to: time)
        let start: Double = if let pending {
            min(pending.start, max(time, startTime))
        } else if !spring.arrived {
            // A moving row retains velocity and never waits a second time.
            time
        } else {
            max(time, startTime)
        }
        schedule = .init(revision: revision, target: value, scheduledAt: start)
        pending = (start, value)
        advance(to: time)
    }

    mutating func advance(to end: Double) {
        guard end.isFinite, end >= time else { return }
        if let queued = pending, queued.start <= end {
            let boundary = max(time, queued.start)
            spring.update(boundary - time)
            time = boundary
            spring.setTarget(queued.target)
            pending = nil
            schedule.startedAt = boundary
        }
        spring.update(end - time)
        time = end
    }
}
