import QuartzCore
import SwiftUI
import UIKit

/// Presentation motion, independent of the lyric engine's focus/word springs.
/// Reuses the app's existing 1/100/18 spring; the supplied paused-song video
/// reaches about 55pt at the next row and visually settles in roughly 0.6s.
@MainActor enum LyricsAuxiliaryMotion {
    static let parameters = LyricsAnimationMotion(style: .appleMusic164).initialVertical
    static let enteringDuration = 0.4
    static let exitingDuration = 0.16
    static let enteringCurve = UnitCurve.bezier(startControlPoint: .init(x: 0.37, y: 0), endControlPoint: .init(x: 0.63, y: 1))
    static let exitingCurve = enteringCurve
    static let settlingDuration: Double = {
        let spring = CASpringAnimation()
        spring.mass = parameters.mass; spring.stiffness = parameters.stiffness; spring.damping = parameters.damping
        return spring.settlingDuration
    }()

    static func sample(from: Double, velocity: Double = 0, to: Double, elapsed: Double) -> (position: Double, velocity: Double) {
        guard elapsed > 0 else { return (from, velocity) }
        guard elapsed < settlingDuration else { return (to, 0) }
        // Presentation uses the same physical coefficients without inheriting
        // the lyric source solver's signed arrival/derivative stopping rules.
        let damping = parameters.damping / (2 * parameters.mass)
        let omegaSquared = parameters.stiffness / parameters.mass
        let displacement = from - to
        let frequency = sqrt(max(0, omegaSquared - damping * damping))
        let decay = exp(-damping * elapsed)
        if frequency > 0.000001 {
            let sine = sin(frequency * elapsed), cosine = cos(frequency * elapsed)
            let coefficient = (velocity + damping * displacement) / frequency
            let wave = displacement * cosine + coefficient * sine
            let derivative = -displacement * frequency * sine + coefficient * frequency * cosine
            return (to + decay * wave, decay * (derivative - damping * wave))
        }
        let coefficient = velocity + damping * displacement
        let wave = displacement + coefficient * elapsed
        return (to + decay * wave, decay * (coefficient - damping * wave))
    }

    static func duration(target: Double) -> Double { target > 0 ? enteringDuration : exitingDuration }
    static func curve(target: Double) -> UnitCurve { target > 0 ? enteringCurve : exitingCurve }
    static func slotKey(row: Int, kind: LyricsAuxiliaryKind) -> Int { row * 2 + (kind == .translation ? 0 : 1) }

    static func mask(bounds: CGRect, regions: [CGRect], excluding: Bool = false) -> CAShapeLayer {
        let path = CGMutablePath()
        if excluding { path.addRect(bounds) }
        let rects = regions.map { $0.intersection(bounds) }.filter { !$0.isNull && !$0.isEmpty }
        let ys = Array(Set(rects.flatMap { [$0.minY, $0.maxY] })).sorted()
        if ys.count > 1 {
            for index in 0 ..< ys.count - 1 {
                let y = (ys[index] + ys[index + 1]) / 2
                let spans = rects.filter { $0.minY <= y && y <= $0.maxY }.sorted { $0.minX < $1.minX }
                var span: CGRect?
                for rect in spans {
                    if let previous = span, rect.minX <= previous.maxX {
                        span = CGRect(x: previous.minX, y: ys[index], width: max(previous.maxX, rect.maxX) - previous.minX, height: ys[index + 1] - ys[index])
                    } else {
                        if let span { path.addRect(span) }
                        span = CGRect(x: rect.minX, y: ys[index], width: rect.width, height: ys[index + 1] - ys[index])
                    }
                }
                if let span { path.addRect(span) }
            }
        }
        let mask = CAShapeLayer(); mask.path = path; mask.fillColor = UIColor.white.cgColor
        mask.fillRule = excluding ? .evenOdd : .nonZero
        return mask
    }
}

/// Per-row offsets live outside recycled row views. Engine geometry is
/// committed once; this transform bridges its old and new presentations.
@MainActor final class LyricsAuxiliaryReflow {
    private struct Row {
        var from: Double
        var velocity: Double
    }
    private var rows: [Int: Row] = [:]
    private var startsAt: Double?
    private var capturedAt = 0.0
    private var pending: [Int: CGFloat] = [:]
    private var previousVelocities: [Int: Double] = [:]
    private var kinds = Set<LyricsAuxiliaryKind>()
    var hasPending: Bool { !pending.isEmpty }

    func reset() { rows.removeAll(); pending.removeAll(); previousVelocities.removeAll(); startsAt = nil; kinds.removeAll() }

    func capture(_ positions: [Int: CGFloat], kinds: Set<LyricsAuxiliaryKind>, now: Double = CACurrentMediaTime()) {
        previousVelocities = rows.mapValues { row in
            LyricsAuxiliaryMotion.sample(from: row.from, velocity: row.velocity, to: 0, elapsed: startsAt.map { now - $0 } ?? 0).velocity
        }
        pending = positions; self.kinds = kinds; startsAt = nil; capturedAt = now
        rows.removeAll()
    }

    func install(index: Int, target: CGFloat, scale: CGFloat, enabled: Bool) {
        guard let presented = pending.removeValue(forKey: index) else { return }
        guard enabled else { return }
        let from = Double((presented - target) / max(0.0001, scale))
        if abs(from) > 0.001 || abs(previousVelocities[index] ?? 0) > 0.001 {
            rows[index] = Row(from: from, velocity: previousVelocities[index] ?? 0)
        }
    }

    func offset(index: Int, fade: LyricsAuxiliaryFade, now: Double = CACurrentMediaTime()) -> CGFloat {
        guard let row = rows[index] else { return 0 }
        if startsAt == nil, kinds.allSatisfy({ !fade.isWaiting($0) }) {
            startsAt = max(capturedAt, kinds.map { fade.start($0) }.max() ?? capturedAt)
        }
        return CGFloat(LyricsAuxiliaryMotion.sample(from: row.from, velocity: row.velocity, to: 0,
            elapsed: startsAt.map { now - $0 } ?? 0).position)
    }

    var isAnimating: Bool {
        guard !rows.isEmpty else { return false }
        return startsAt.map { CACurrentMediaTime() < $0 + LyricsAuxiliaryMotion.settlingDuration } ?? true
    }

    func finishFrame(visible: Set<Int>) {
        guard !pending.isEmpty || !previousVelocities.isEmpty || !rows.isEmpty else { return }
        pending.removeAll(); previousVelocities.removeAll()
        rows = rows.filter { visible.contains($0.key) }
        if !isAnimating { rows.removeAll(); startsAt = nil }
    }
}
