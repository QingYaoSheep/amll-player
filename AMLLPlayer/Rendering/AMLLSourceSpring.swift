import Foundation

/// Source port: core/src/utils/spring.ts and derivative.ts (see THIRD_PARTY_NOTICES).
/// Seconds, including queued changes and the original finite-difference velocity.
struct AMLLSourceSpring: Sendable {
    struct Parameters: Equatable, Sendable {
        var mass: Double?
        var damping: Double?
        var stiffness: Double?
        var soft: Bool?

        mutating func merge(_ other: Self) {
            mass = other.mass ?? mass
            damping = other.damping ?? damping
            stiffness = other.stiffness ?? stiffness
            soft = other.soft ?? soft
        }
    }

    private struct Solver: Sendable {
        var from: Double
        var velocity: Double
        var to: Double
        var parameters: Parameters
        var constant = false

        func value(_ time: Double) -> Double {
            if constant {
                return to
            }
            if time < 0 {
                return from
            }
            let mass = parameters.mass ?? 1
            let damping = parameters.damping ?? 10
            let stiffness = parameters.stiffness ?? 100
            let delta = to - from
            if parameters.soft == true || damping / (2 * sqrt(stiffness * mass)) >= 1 {
                let frequency = -sqrt(stiffness / mass)
                let leftover = -frequency * delta - velocity
                return to - (delta + time * leftover) * exp(time * frequency)
            }
            let frequency = sqrt(4 * mass * stiffness - damping * damping)
            let leftover = (damping * delta - 2 * mass * velocity) / frequency
            return to - (cos(time * 0.5 * frequency / mass) * delta + sin(time * 0.5 * frequency / mass) * leftover)
                * exp(time * -0.5 * damping / mass)
        }

        func speed(_ time: Double) -> Double {
            (value(time + 0.001) - value(time - 0.001)) / 0.002
        }

        func acceleration(_ time: Double) -> Double {
            (speed(time + 0.001) - speed(time - 0.001)) / 0.002
        }
    }

    private(set) var position: Double
    private(set) var target: Double
    private var elapsed = 0.0
    private var parameters = Parameters()
    private var solver: Solver
    private var queuedTarget: (time: Double, value: Double)?
    private var queuedParameters: (time: Double, value: Parameters)?

    init(_ position: Double = 0) {
        self.position = position
        target = position
        solver = Solver(from: position, velocity: 0, to: position, parameters: .init(), constant: true)
    }

    var arrived: Bool {
        // Preserve the original signed derivative checks, including their asymmetry.
        abs(target - position) < 0.01 && solver.speed(elapsed) < 0.01 && solver.acceleration(elapsed) < 0.01
            && queuedTarget == nil && queuedParameters == nil
    }

    mutating func setPosition(_ value: Double) {
        target = value
        position = value
        solver = Solver(from: value, velocity: 0, to: value, parameters: parameters, constant: true)
    }

    mutating func setTarget(_ value: Double, delay: Double = 0) {
        if delay > 0 {
            queuedTarget = (delay, value)
        } else {
            queuedTarget = nil
            target = value
            resetSolver()
        }
    }

    mutating func updateParameters(_ value: Parameters, delay: Double = 0) {
        if delay > 0 {
            queuedParameters = (delay, value)
        } else {
            queuedTarget = nil
            parameters.merge(value)
            resetSolver()
        }
    }

    mutating func update(_ delta: Double) {
        guard delta.isFinite, delta >= 0 else { return }
        elapsed += delta
        position = solver.value(elapsed)
        if var queued = queuedParameters {
            queued.time -= delta
            queuedParameters = queued
            // The pinned source retains this queue after expiration. Do not silently fix it.
            if queued.time <= 0 {
                updateParameters(queued.value)
            }
        }
        if var queued = queuedTarget {
            queued.time -= delta
            queuedTarget = queued
            if queued.time <= 0 {
                setTarget(queued.value)
            }
        }
        if arrived {
            setPosition(target)
        }
    }

    private mutating func resetSolver() {
        let velocity = solver.speed(elapsed)
        elapsed = 0
        solver = Solver(from: position, velocity: velocity, to: target, parameters: parameters)
    }
}
