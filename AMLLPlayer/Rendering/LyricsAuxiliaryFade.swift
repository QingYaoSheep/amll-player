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
    private(set) var revision = 0
    var didFinish: () -> Void = {}
    private static let duration = 0.2
    private static let curve = UnitCurve.bezier(startControlPoint: .init(x: 0.23, y: 1), endControlPoint: .init(x: 0.32, y: 1))

    func update(_ configuration: LyricsRenderConfiguration, animated: Bool, now: Double = CACurrentMediaTime()) {
        let targets: [LyricsAuxiliaryKind: Bool] = [.translation: configuration.translation, .romanization: configuration.romanization]
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
        guard let end = changes.values.filter({ $0.from != $0.to && $0.start + Self.duration > now })
            .map({ $0.start + Self.duration }).min() else { return }
        let ticket = revision, delay = end - now
        completion = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, self.revision == ticket else { return }
            self.revision &+= 1
            self.didFinish()
            self.armCompletion(now: CACurrentMediaTime())
        }
    }

    func cancel() { completion?.cancel(); completion = nil }

    var hiddenKinds: Set<LyricsAuxiliaryKind> { Set(changes.compactMap { $0.value.to == 0 ? $0.key : nil }) }
    var isAnimating: Bool { changes.values.contains { $0.from != $0.to && CACurrentMediaTime() < $0.start + Self.duration } }
    func start(_ kind: LyricsAuxiliaryKind) -> Double { changes[kind]?.start ?? 0 }
    func target(_ kind: LyricsAuxiliaryKind) -> Double { changes[kind]?.to ?? 1 }
    func deadline(_ kind: LyricsAuxiliaryKind) -> Double { start(kind) + Self.duration }

    func reset(_ configuration: LyricsRenderConfiguration) {
        cancel(); initialized = false
        update(configuration, animated: false)
    }

    func value(_ kind: LyricsAuxiliaryKind, now: Double = CACurrentMediaTime()) -> Double {
        guard let change = changes[kind] else { return 1 }
        let p = Self.curve.value(at: (now - change.start) / Self.duration)
        return change.from + (change.to - change.from) * p
    }

    func layoutConfiguration(_ configuration: LyricsRenderConfiguration, now: Double = CACurrentMediaTime()) -> LyricsRenderConfiguration {
        var result = configuration
        func retained(_ kind: LyricsAuxiliaryKind) -> Bool {
            guard let c = changes[kind] else { return false }
            return c.from > 0 && now < c.start + Self.duration
        }
        result.translation = configuration.translation || retained(.translation)
        result.romanization = configuration.romanization || retained(.romanization)
        return result
    }

    /// The mask is attached only to SDR annotation planes, never the HDR
    /// or main word layers. No bitmap capture or additional display link.
    func mask(bounds: CGRect, regions: [LyricsAuxiliaryKind: [CGRect]], origin: CGPoint = .zero,
              now: Double = CACurrentMediaTime()) -> CALayer? {
        let relevant = regions.filter { !$0.value.isEmpty }
        guard relevant.keys.contains(where: { kind in
            guard let c = changes[kind] else { return false }
            return c.to < 1 || now < c.start + Self.duration
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
            let target = changes[kind]?.to ?? 1
            shape.opacity = Float(target)
            root.addSublayer(shape)
            if let c = changes[kind], now < c.start + Self.duration {
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
