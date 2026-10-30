import Foundation

/// LyricsBlossom FUN_140155fe0/1401560c0. Kept separate from the pinned
/// AMLL solver, whose finite derivatives and stopping rules are intentional.
struct LyricsBlossomSpring: Sendable {
    var parameters = AMLLSpringParameters(mass: 1, damping: 18, stiffness: 100)
    private var from: Double
    private var initialVelocity = 0.0
    private var elapsed = 0.0
    private(set) var target: Double
    private(set) var position: Double
    private(set) var velocity = 0.0

    init(_ value: Double = 0) {
        from = value; target = value; position = value
    }

    var arrived: Bool { abs(position - target) < 0.01 && abs(velocity) < 0.01 }

    /// Exact derivative; the supplied reconstruction's underdamped velocity
    /// has inverted sine/cosine signs. Check it against x'(t), not its label.
    static func sample(from: Double, to: Double, velocity: Double, time: Double,
                       parameters p: AMLLSpringParameters) -> (position: Double, velocity: Double) {
        guard time > 0 else { return (from, velocity) }
        let delta = to - from, omega = sqrt(p.stiffness / p.mass)
        let alpha = p.damping / (2 * p.mass)
        if alpha >= omega {
            // Source mode 1 uses the critically damped form for both regimes.
            let b = omega * delta - velocity, decay = exp(-omega * time)
            return (to - decay * (delta + b * time), decay * (omega * (delta + b * time) - b))
        }
        let frequency = sqrt(omega * omega - alpha * alpha)
        let b = (alpha * delta - velocity) / frequency
        let cosine = cos(frequency * time), sine = sin(frequency * time)
        let wave = delta * cosine + b * sine, decay = exp(-alpha * time)
        return (to - decay * wave,
                decay * (alpha * wave + delta * frequency * sine - b * frequency * cosine))
    }

    mutating func resume(position: Double, velocity: Double, target: Double) {
        from = position; self.position = position; initialVelocity = velocity
        self.velocity = velocity; self.target = target; elapsed = 0
    }

    mutating func update(_ delta: Double) {
        guard delta.isFinite, delta >= 0 else { return }
        elapsed += delta
        let value = Self.sample(from: from, to: target, velocity: initialVelocity, time: elapsed, parameters: parameters)
        position = value.position; velocity = value.velocity
        if arrived { resume(position: target, velocity: 0, target: target) }
    }
}

/// One production seam for switching solvers without resetting schedules or
/// time anchors. The AMLL branch delegates every operation to the old solver.
struct LyricsAnimationSpring: Sendable {
    private var legacy: AMLLSourceSpring
    private var blossom: LyricsBlossomSpring
    private var parameters = AMLLSourceSpring.Parameters()
    // The pinned solver clamps x(t<0) to its starting position, so its central
    // derivative reports half velocity at t=0. Preserve only the style handoff
    // value until time advances; ordinary AMLL operations stay unchanged.
    private var handoffVelocity: Double?
    private(set) var style = LyricsAnimationStyle.amll

    init(_ value: Double = 0) {
        legacy = AMLLSourceSpring(value); blossom = LyricsBlossomSpring(value)
    }

    var position: Double { style == .amll ? legacy.position : blossom.position }
    var velocity: Double { style == .amll ? (handoffVelocity ?? legacy.velocity) : blossom.velocity }
    var target: Double { style == .amll ? legacy.target : blossom.target }
    var arrived: Bool { style == .amll ? legacy.arrived : blossom.arrived }

    mutating func selectStyle(_ value: LyricsAnimationStyle) {
        guard style != value else { return }
        let p = position, v = velocity, t = target
        style = value
        applyBlossomParameters()
        if style == .amll { legacy.updateParameters(parameters) }
        resume(position: p, velocity: v, target: t)
        if style == .amll { handoffVelocity = v }
    }

    mutating func setPosition(_ value: Double) {
        handoffVelocity = nil
        if style == .amll { legacy.setPosition(value) }
        else { blossom.resume(position: value, velocity: 0, target: value) }
    }

    mutating func resume(position: Double, velocity: Double, target: Double) {
        handoffVelocity = nil
        if style == .amll { legacy.resume(position: position, velocity: velocity, target: target) }
        else { blossom.resume(position: position, velocity: velocity, target: target) }
    }

    mutating func setTarget(_ value: Double) {
        if style == .amll {
            if let handoffVelocity {
                legacy.resume(position: position, velocity: handoffVelocity, target: value)
            } else { legacy.setTarget(value) }
        }
        else { blossom.resume(position: position, velocity: velocity, target: value) }
    }

    mutating func updateParameters(_ value: AMLLSourceSpring.Parameters) {
        parameters.merge(value)
        if style == .amll {
            let p = position, t = target
            legacy.updateParameters(value)
            if let handoffVelocity { legacy.resume(position: p, velocity: handoffVelocity, target: t) }
        }
        else {
            let p = position, v = velocity, t = target
            applyBlossomParameters()
            blossom.resume(position: p, velocity: v, target: t)
        }
    }

    mutating func update(_ delta: Double) {
        if style == .amll { legacy.update(delta) } else { blossom.update(delta) }
        if delta.isFinite, delta > 0 { handoffVelocity = nil }
    }

    private mutating func applyBlossomParameters() {
        blossom.parameters = .init(mass: parameters.mass ?? 1, damping: parameters.damping ?? 18,
                                   stiffness: parameters.stiffness ?? 100)
    }
}
