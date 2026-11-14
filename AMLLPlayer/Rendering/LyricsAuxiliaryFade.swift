import SwiftUI
import UIKit

enum LyricsAuxiliaryKind: CaseIterable, Hashable, Sendable { case translation, romanization }

/// UI visibility uses wall time, independently of the song and word clocks.
/// Outgoing layout slots survive until their pixels have finished fading.
@MainActor final class LyricsAuxiliaryFade {
    private struct Change {
        var from: Double
        var to: Double
        var start: Double
        var motionFrom: Double
        var motionVelocity: Double
        init(from: Double, to: Double, start: Double, motionFrom: Double? = nil, motionVelocity: Double = 0) {
            self.from = from; self.to = to; self.start = start
            self.motionFrom = motionFrom ?? from; self.motionVelocity = motionVelocity
        }
    }
    private var changes: [LyricsAuxiliaryKind: Change] = [:]
    private var initialized = false
    private var completion: Task<Void, Never>?
    private var preparations: [UUID: Set<LyricsAuxiliaryKind>] = [:]
    private var reduceMotion = false
    private(set) var revision = 0
    var didFinish: () -> Void = {}

    func update(_ configuration: LyricsRenderConfiguration, animated: Bool, reduceMotion: Bool = false, now: Double = CACurrentMediaTime()) {
        let motionPreferenceChanged = self.reduceMotion != reduceMotion
        if motionPreferenceChanged { self.reduceMotion = reduceMotion; revision &+= 1 }
        let targets: [LyricsAuxiliaryKind: Bool] = [.translation: configuration.translation, .romanization: configuration.romanization]
        if initialized, !animated, changes.contains(where: { isWaiting($0.key) || pending($0.value, now: now) }) {
            completion?.cancel()
            preparations.removeAll()
            for kind in LyricsAuxiliaryKind.allCases {
                let target = targets[kind] == true ? 1.0 : 0.0
                changes[kind] = Change(from: target, to: target, start: now - LyricsAuxiliaryMotion.settlingDuration)
            }
            revision &+= 1
            return
        }
        guard !initialized || targets.contains(where: { changes[$0.key]?.to != ($0.value ? 1 : 0) }) else {
            if motionPreferenceChanged { completion?.cancel(); didFinish(); armCompletion(now: now) }
            return
        }
        completion?.cancel()
        let animate = initialized && animated
        for kind in LyricsAuxiliaryKind.allCases {
            let target = targets[kind] == true ? 1.0 : 0.0
            if initialized, changes[kind]?.to == target { continue }
            let current = animate ? value(kind, now: now) : target
            let motion = animate ? geometry(kind, now: now) : (position: target, velocity: 0.0)
            changes[kind] = Change(from: current, to: target,
                start: animate ? now : now - LyricsAuxiliaryMotion.settlingDuration,
                motionFrom: motion.position, motionVelocity: motion.velocity)
        }
        initialized = true; revision &+= 1
        guard animate else { return }
        armCompletion(now: now)
    }

    private func armCompletion(now: Double) {
        let deadlines = changes.filter { !isWaiting($0.key) }.flatMap { _, change -> [Double] in
            guard change.from != change.to || change.motionFrom != change.to else { return [] }
            return [change.start + LyricsAuxiliaryMotion.duration(target: change.to), change.start + LyricsAuxiliaryMotion.settlingDuration]
        }.filter { $0 > now }
        guard let end = deadlines.min() else { return }
        let ticket = revision, delay = end - now
        completion = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, self.revision == ticket else { return }
            self.revision &+= 1
            self.didFinish()
            self.armCompletion(now: CACurrentMediaTime())
        }
    }

    func cancel() { completion?.cancel(); completion = nil; preparations.removeAll() }

    /// Hold the actual pixels while their replacement is prepared. The UI
    /// clock starts on readiness, rather than expiring in layout/CI work.
    func beginPreparation(_ kinds: Set<LyricsAuxiliaryKind>, now: Double = CACurrentMediaTime()) -> UUID? {
        let pending = kinds.filter { kind in
            guard let change = changes[kind] else { return false }
            return self.pending(change, now: now) || isWaiting(kind)
        }
        guard !pending.isEmpty else { return nil }
        for kind in pending where !isWaiting(kind) {
            let presented = value(kind, now: now)
            let motion = geometry(kind, now: now)
            changes[kind]?.from = presented
            changes[kind]?.motionFrom = motion.position
            changes[kind]?.motionVelocity = motion.velocity
            changes[kind]?.start = now
        }
        let token = UUID(); preparations[token] = pending
        completion?.cancel(); revision &+= 1; armCompletion(now: now)
        return token
    }

    func finishPreparation(_ token: UUID?, now: Double = CACurrentMediaTime()) {
        guard let token, let kinds = preparations.removeValue(forKey: token) else { return }
        for kind in kinds where !isWaiting(kind) { changes[kind]?.start = now }
        completion?.cancel(); revision &+= 1
        didFinish(); armCompletion(now: now)
    }

    func isWaiting(_ kind: LyricsAuxiliaryKind) -> Bool { preparations.values.contains { $0.contains(kind) } }

    var hiddenKinds: Set<LyricsAuxiliaryKind> { Set(changes.compactMap { $0.value.to == 0 ? $0.key : nil }) }
    private func pending(_ change: Change, now: Double) -> Bool {
        (change.from != change.to && now < change.start + LyricsAuxiliaryMotion.duration(target: change.to))
            || (!reduceMotion && change.motionFrom != change.to && now < change.start + LyricsAuxiliaryMotion.settlingDuration)
    }
    var isAnimating: Bool { changes.contains { isWaiting($0.key) || pending($0.value, now: CACurrentMediaTime()) } }
    func start(_ kind: LyricsAuxiliaryKind) -> Double { changes[kind]?.start ?? 0 }
    func target(_ kind: LyricsAuxiliaryKind) -> Double { changes[kind]?.to ?? 1 }
    func deadline(_ kind: LyricsAuxiliaryKind) -> Double { start(kind) + LyricsAuxiliaryMotion.duration(target: target(kind)) }

    func geometry(_ kind: LyricsAuxiliaryKind, now: Double = CACurrentMediaTime()) -> (position: Double, velocity: Double) {
        guard let change = changes[kind] else { return (1, 0) }
        if reduceMotion { return (change.to, 0) }
        if isWaiting(kind) { return (change.motionFrom, 0) }
        return LyricsAuxiliaryMotion.sample(from: change.motionFrom, velocity: change.motionVelocity, to: change.to, elapsed: now - change.start)
    }

    private func preparePlane(_ layer: CALayer) {
        if layer.actions?["opacity"] == nil {
            var actions = layer.actions ?? [:]
            actions["opacity"] = NSNull(); actions["transform"] = NSNull(); layer.actions = actions
        }
    }

    func applyGeometry(to layer: CALayer, kind: LyricsAuxiliaryKind, distance: CGFloat, offset: CGFloat = 0, now: Double = CACurrentMediaTime()) {
        preparePlane(layer)
        let transform = CGAffineTransform(translationX: 0, y: CGFloat(geometry(kind, now: now).position - 1) * distance + offset)
        if layer.affineTransform() != transform { layer.setAffineTransform(transform) }
    }

    func applyVisibility(to layer: CALayer, kind: LyricsAuxiliaryKind, now: Double = CACurrentMediaTime()) {
        preparePlane(layer)
        let opacity = Float(value(kind, now: now))
        if layer.opacity != opacity { layer.opacity = opacity }
    }

    func reset(_ configuration: LyricsRenderConfiguration) {
        cancel(); initialized = false
        update(configuration, animated: false)
    }

    func value(_ kind: LyricsAuxiliaryKind, now: Double = CACurrentMediaTime()) -> Double {
        guard let change = changes[kind] else { return 1 }
        if isWaiting(kind) { return change.from }
        let p = LyricsAuxiliaryMotion.curve(target: change.to).value(at: min(1, max(0, (now - change.start) / LyricsAuxiliaryMotion.duration(target: change.to))))
        return change.from + (change.to - change.from) * p
    }

    func layoutConfiguration(_ configuration: LyricsRenderConfiguration, now: Double = CACurrentMediaTime()) -> LyricsRenderConfiguration {
        var result = configuration
        func retained(_ kind: LyricsAuxiliaryKind) -> Bool {
            guard let c = changes[kind] else { return false }
            return c.from > 0 && (isWaiting(kind) || now < c.start + LyricsAuxiliaryMotion.duration(target: c.to))
        }
        result.translation = configuration.translation || retained(.translation)
        result.romanization = configuration.romanization || retained(.romanization)
        return result
    }

}
