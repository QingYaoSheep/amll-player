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
    }
    private var changes: [LyricsAuxiliaryKind: Change] = [:]
    private var initialized = false
    private var completion: Task<Void, Never>?
    private var preparations: [UUID: Set<LyricsAuxiliaryKind>] = [:]
    private(set) var revision = 0
    var didFinish: () -> Void = {}
    private static let duration = 0.2
    private static let curve = UnitCurve.bezier(startControlPoint: .init(x: 0.23, y: 1), endControlPoint: .init(x: 0.32, y: 1))

    func update(_ configuration: LyricsRenderConfiguration, animated: Bool, now: Double = CACurrentMediaTime()) {
        let targets: [LyricsAuxiliaryKind: Bool] = [.translation: configuration.translation, .romanization: configuration.romanization]
        if initialized, !animated, changes.contains(where: { isWaiting($0.key) || ($0.value.from != $0.value.to && now < $0.value.start + Self.duration) }) {
            completion?.cancel()
            preparations.removeAll()
            for kind in LyricsAuxiliaryKind.allCases {
                let target = targets[kind] == true ? 1.0 : 0.0
                changes[kind] = Change(from: target, to: target, start: now - Self.duration)
            }
            revision &+= 1
            return
        }
        guard !initialized || targets.contains(where: { changes[$0.key]?.to != ($0.value ? 1 : 0) }) else { return }
        completion?.cancel()
        let animate = initialized && animated
        for kind in LyricsAuxiliaryKind.allCases {
            let target = targets[kind] == true ? 1.0 : 0.0
            if initialized, changes[kind]?.to == target { continue }
            let current = animate ? value(kind, now: now) : target
            changes[kind] = Change(from: current, to: target, start: animate ? now : now - Self.duration)
        }
        initialized = true; revision &+= 1
        guard animate else { return }
        armCompletion(now: now)
    }

    private func armCompletion(now: Double) {
        guard let end = changes.filter({ !isWaiting($0.key) && $0.value.from != $0.value.to && $0.value.start + Self.duration > now })
            .map({ $0.value.start + Self.duration }).min() else { return }
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
            return change.from != change.to && (isWaiting(kind) || now < change.start + Self.duration)
        }
        guard !pending.isEmpty else { return nil }
        for kind in pending where !isWaiting(kind) {
            let presented = value(kind, now: now)
            changes[kind]?.from = presented
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
    var isAnimating: Bool { changes.contains { isWaiting($0.key) || ($0.value.from != $0.value.to && CACurrentMediaTime() < $0.value.start + Self.duration) } }
    func start(_ kind: LyricsAuxiliaryKind) -> Double { changes[kind]?.start ?? 0 }
    func target(_ kind: LyricsAuxiliaryKind) -> Double { changes[kind]?.to ?? 1 }
    func deadline(_ kind: LyricsAuxiliaryKind) -> Double { start(kind) + Self.duration }

    func reset(_ configuration: LyricsRenderConfiguration) {
        cancel(); initialized = false
        update(configuration, animated: false)
    }

    func value(_ kind: LyricsAuxiliaryKind, now: Double = CACurrentMediaTime()) -> Double {
        guard let change = changes[kind] else { return 1 }
        if isWaiting(kind) { return change.from }
        let p = Self.curve.value(at: (now - change.start) / Self.duration)
        return change.from + (change.to - change.from) * p
    }

    func layoutConfiguration(_ configuration: LyricsRenderConfiguration, now: Double = CACurrentMediaTime()) -> LyricsRenderConfiguration {
        var result = configuration
        func retained(_ kind: LyricsAuxiliaryKind) -> Bool {
            guard let c = changes[kind] else { return false }
            return c.from > 0 && (isWaiting(kind) || now < c.start + Self.duration)
        }
        result.translation = configuration.translation || retained(.translation)
        result.romanization = configuration.romanization || retained(.romanization)
        return result
    }

    func fullPlaneMask(bounds: CGRect, kind: LyricsAuxiliaryKind) -> CALayer? {
        // The separate pronunciation plane includes padded blur pixels and
        // a small word lift outside its typographic bounds.
        let padding = CGFloat(LyricsAnimationBlur.maximum(10) * 3 + 1)
        let extent = CGRect(x: 0, y: 0, width: bounds.width + padding * 2, height: bounds.height + padding * 2)
        let result = mask(bounds: extent, regions: [kind: [extent]])
        result?.position = CGPoint(x: bounds.midX, y: bounds.midY)
        return result
    }

    /// The mask is attached only to SDR annotation planes, never the HDR
    /// or main word layers. No bitmap capture or additional display link.
    func mask(bounds: CGRect, regions: [LyricsAuxiliaryKind: [CGRect]], origin: CGPoint = .zero,
              now: Double = CACurrentMediaTime()) -> CALayer? {
        let relevant = regions.filter { !$0.value.isEmpty }
        guard relevant.keys.contains(where: { kind in
            guard let c = changes[kind] else { return false }
            return isWaiting(kind) || c.to < 1 || now < c.start + Self.duration
        }) else { return nil }
        let root = CALayer(); root.frame = bounds
        let rects = relevant.values.flatMap { $0 }.map {
            $0.offsetBy(dx: -origin.x, dy: -origin.y).intersection(bounds)
        }.filter { !$0.isEmpty && !$0.isNull }
        let path = CGMutablePath(); path.addRect(bounds)
        // Disjoint union strips keep even-odd holes correct for overlapping
        // fragments (ligatures and bidi annotation pieces).
        let ys = Array(Set(rects.flatMap { [$0.minY, $0.maxY] })).sorted()
        if ys.count > 1 {
            for i in 0 ..< ys.count - 1 {
                let y = (ys[i] + ys[i + 1]) / 2
                let spans = rects.filter { $0.minY <= y && $0.maxY >= y }.sorted { $0.minX < $1.minX }
                var interval: CGRect?
                for rect in spans {
                    if let old = interval, rect.minX <= old.maxX {
                        interval = CGRect(x: old.minX, y: ys[i], width: max(old.maxX, rect.maxX) - old.minX, height: ys[i + 1] - ys[i])
                    } else {
                        if let interval { path.addRect(interval) }
                        interval = CGRect(x: rect.minX, y: ys[i], width: rect.width, height: ys[i + 1] - ys[i])
                    }
                }
                if let interval { path.addRect(interval) }
            }
        }
        let body = CAShapeLayer(); body.path = path; body.fillRule = .evenOdd; body.fillColor = UIColor.white.cgColor
        root.addSublayer(body)
        for (kind, areas) in relevant {
            let shape = CAShapeLayer(), area = CGMutablePath()
            for rect in areas { area.addRect(rect.offsetBy(dx: -origin.x, dy: -origin.y)) }
            shape.path = area; shape.fillColor = UIColor.white.cgColor
            let target = isWaiting(kind) ? value(kind, now: now) : (changes[kind]?.to ?? 1)
            shape.opacity = Float(target)
            root.addSublayer(shape)
            if let c = changes[kind], !isWaiting(kind), now < c.start + Self.duration {
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = value(kind, now: now); fade.toValue = target
                fade.duration = max(0, c.start + Self.duration - now)
                fade.timingFunction = LyricsPageMotion.contentTimingFunction
                shape.add(fade, forKey: "auxiliaryVisibility")
            }
        }
        return root
    }
}
