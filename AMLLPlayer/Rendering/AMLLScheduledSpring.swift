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

    private var spring: LyricsAnimationSpring
    private var parameters = AMLLSourceSpring.Parameters()
    private var time = 0.0
    private var pending: (start: Double, target: Double)?
    private(set) var schedule: Schedule

    init(_ value: Double = 0) {
        spring = LyricsAnimationSpring(value)
        schedule = .init(revision: 0, target: value)
    }

    var position: Double {
        spring.position
    }

    var target: Double {
        schedule.target
    }

    var velocity: Double { spring.velocity }

    mutating func selectStyle(_ style: LyricsAnimationStyle) {
        spring.selectStyle(style)
    }

    mutating func resume(position: Double, velocity: Double, at time: Double) {
        let resumedTarget = pending == nil ? target : spring.target
        spring.resume(position: position, velocity: velocity, target: resumedTarget)
        self.time = time
        if pending == nil, position != target { schedule.startedAt = time }
    }

    var arrived: Bool {
        pending == nil && spring.arrived
    }

    mutating func setPosition(_ value: Double, at time: Double = 0) {
        // Rebuild instead of using the source's setPosition, which deliberately
        // retains queued targets. Direct positioning cancels production work.
        let style = spring.style
        spring = LyricsAnimationSpring(value)
        spring.selectStyle(style)
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

    /// Remove a queued wait while retaining the current position and velocity.
    /// Used by Blossom's pause path; this never snaps an in-progress movement.
    @discardableResult
    mutating func clearPendingDelay(at time: Double) -> Bool {
        guard time.isFinite, time >= self.time, let queued = pending, queued.start > time else { return false }
        pending = (min(queued.start, time), queued.target)
        schedule.scheduledAt = min(queued.start, time)
        advance(to: time)
        return true
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
