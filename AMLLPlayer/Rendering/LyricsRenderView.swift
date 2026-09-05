import SwiftUI
import UIKit

struct NativeLyricsView: UIViewRepresentable {
    let document: LyricsDocument
    let configuration: LyricsRenderConfiguration
    let offset: Double
    let duration: Double
    let playing: Bool
    let active: Bool
    let canSeek: Bool
    let position: () -> Double
    let seek: (Double) -> Void
    let resumeToken: Int
    let browsing: (Bool) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeUIView(context _: Context) -> LyricsRenderView {
        LyricsRenderView()
    }

    func updateUIView(_ view: LyricsRenderView, context _: Context) {
        view.position = position; view.seek = seek; view.browsing = browsing
        view.update(document: document, configuration: configuration.validated(), offset: offset, duration: duration,
                    playing: playing, active: active, canSeek: canSeek, reduceMotion: reduceMotion, resumeToken: resumeToken)
    }

    static func dismantleUIView(_ uiView: LyricsRenderView, coordinator _: ()) {
        uiView.stop()
    }
}

@MainActor
final class LyricsRenderView: UIView, LyricsRendering, UIScrollViewDelegate {
    var position: () -> Double = { 0 }
    var seek: (Double) -> Void = { _ in }
    var browsing: (Bool) -> Void = { _ in }
    private let scroll = LyricsScrollView()
    private let dots = AMLLInterludeDotsView()
    private var timeline = LyricsTimeline(lines: [])
    private var document: LyricsDocument?
    private var configuration = LyricsRenderConfiguration()
    private var offset = 0.0, duration = 0.0
    private var playing = false, active = true, canSeek = false, reduceMotion = false
    private var resumeToken = 0
    private var follow = LyricsFollowState()
    private var motion = LyricsMotionModel()
    private var displayLink: CADisplayLink?
    private var proxy: DisplayLinkProxy?
    private var previousTick = 0.0
    private var previousTime: Double?
    private var lastSize = CGSize.zero
    private var frames: [CGRect] = []
    private var rows: [Int: LyricRowView] = [:]
    private var pool: [LyricRowView] = []
    private var layouts: [Int: LyricTextLayout] = [:]
    private var layoutOrder: [Int] = []
    private var needsRebuild = true
    private var lastFocus: Int?
    private var lastActive: [Int] = []
    private(set) var frameMilliseconds = 0.0
    private(set) var measuredFPS = 0.0
    var visibleRowCount: Int {
        rows.count
    }

    var cachedLayoutCount: Int {
        layouts.count
    }

    var isFollowing: Bool {
        follow.following
    }

    var isDisplayLinkRunning: Bool {
        displayLink != nil && displayLink?.isPaused == false
    }

    var contentOffset: Double {
        scroll.contentOffset.y
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        scroll.delegate = self
        scroll.alwaysBounceVertical = true
        scroll.showsVerticalScrollIndicator = false
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.accessibilityIdentifier = "nativeLyricsScroll"
        scroll.accessibilityLabel = NSLocalizedString("render.lyrics", comment: "")
        scroll.beginAccessibilityBrowsing = { [weak self] in self?.beginBrowsing() }
        addSubview(scroll)
        dots.isAccessibilityElement = true
        dots.accessibilityLabel = NSLocalizedString("render.interlude", comment: "")
        dots.isHidden = true; scroll.addSubview(dots)
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (view: LyricsRenderView, _: UITraitCollection) in
            view.needsRebuild = true; view.setNeedsLayout()
        }
    }

    required init?(coder _: NSCoder) {
        nil
    }

    func update(document: LyricsDocument, configuration: LyricsRenderConfiguration, offset: Double, duration: Double,
                playing: Bool, active: Bool, canSeek: Bool, reduceMotion: Bool, resumeToken: Int)
    {
        if self.document != document {
            self.document = document; timeline = LyricsTimeline(lines: document.lines)
            follow.reset(); motion = LyricsMotionModel(); previousTime = nil; lastFocus = nil; lastActive = []; needsRebuild = true
            scroll.setContentOffset(scroll.contentOffset, animated: false)
            DispatchQueue.main.async { [weak self] in self?.browsing(false) }
        }
        if self.configuration != configuration || self.reduceMotion != reduceMotion {
            needsRebuild = true
        }
        self.configuration = configuration; self.offset = offset; self.duration = duration
        self.playing = playing; self.active = active; self.canSeek = canSeek; self.reduceMotion = reduceMotion
        for row in rows.values {
            row.setCanSeek(canSeek)
        }
        if self.resumeToken != resumeToken {
            self.resumeToken = resumeToken; resumeFollowing()
        }
        setNeedsLayout(); syncDisplayLink()
        if !needsRebuild {
            drawFrame(dt: 1 / 60)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        scroll.frame = bounds
        guard bounds.width > 32, bounds.height > 0 else { return }
        if bounds.size != lastSize || needsRebuild {
            let resized = bounds.size != lastSize
            lastSize = bounds.size; needsRebuild = false
            rows.values.forEach { $0.removeFromSuperview() }; rows.removeAll(); pool.removeAll()
            layouts.removeAll(); layoutOrder.removeAll(); frames.removeAll()
            if resized {
                follow.reset(); previousTime = nil
                scroll.setContentOffset(scroll.contentOffset, animated: false)
                DispatchQueue.main.async { [weak self] in self?.browsing(false) }
            }
            var y = bounds.height * configuration.anchor
            for index in timeline.lines.indices {
                let layout = makeLayout(index)
                let inset: CGFloat = timeline.lines[index].isBackground ? 32 : 20
                frames.append(CGRect(x: inset, y: y, width: bounds.width - inset * 2, height: layout.size.height))
                y += layout.size.height + (timeline.lines[index].isBackground ? 14 : 28)
            }
            scroll.contentSize = CGSize(width: bounds.width, height: y + bounds.height * (1 - configuration.anchor))
        }
        drawFrame(dt: 1 / 60)
        if playing || !follow.following {
            syncDisplayLink()
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow(); syncDisplayLink()
    }

    func resumeFollowing() {
        scroll.setContentOffset(scroll.contentOffset, animated: false)
        follow.resume(); follow.position = scroll.contentOffset.y
        motion.handle(.resumeFollowing, at: CACurrentMediaTime())
        DispatchQueue.main.async { [weak self] in self?.browsing(false) }
        syncDisplayLink()
    }

    func stop() {
        displayLink?.invalidate(); displayLink = nil; proxy = nil; previousTick = 0
    }

    private func syncDisplayLink() {
        guard window != nil, active else { stop(); return }
        if displayLink == nil {
            let proxy = DisplayLinkProxy(); proxy.owner = self; self.proxy = proxy
            let link = CADisplayLink(target: proxy, selector: #selector(DisplayLinkProxy.tick(_:)))
            link.add(to: .main, forMode: .common); displayLink = link
        }
        let policy = RenderQualityPolicy.resolve(maximumFPS: window?.screen.maximumFramesPerSecond ?? 60, reduceMotion: reduceMotion)
        displayLink?.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: Float(policy.frameRate), preferred: Float(policy.frameRate))
        if displayLink?.isPaused == true {
            previousTick = 0
        }
        displayLink?.isPaused = false
    }

    fileprivate func tick(_ link: CADisplayLink) {
        let begin = CACurrentMediaTime()
        let dt = previousTick > 0 ? link.timestamp - previousTick : 1 / 60
        previousTick = link.timestamp
        drawFrame(dt: dt)
        frameMilliseconds = frameMilliseconds * 0.9 + (CACurrentMediaTime() - begin) * 100
        if dt > 0 {
            measuredFPS = measuredFPS * 0.9 + 0.1 / dt
        }
    }

    private func drawFrame(dt: Double) {
        guard !needsRebuild, frames.count == timeline.lines.count, active else { return }
        let playbackTime = position()
        let state = timeline.state(position: playbackTime, offset: offset, advance: configuration.advance)
        let jumped = previousTime.map { abs(state.time - $0) > 1 } ?? true
        previousTime = state.time
        if state.focus != lastFocus {
            let interval: TimeInterval? = state.focus.flatMap { focus in
                guard focus > 0 else { return nil }
                var previous = focus - 1
                while previous >= 0, timeline.lines[previous].isBackground { previous -= 1 }
                guard previous >= 0 else { return nil }
                return timeline.lines[focus].start - timeline.lines[previous].start
            }
            follow.configure(lineInterval: interval, seeking: jumped, interlude: state.interlude != nil)
        }
        if motion.resumeIfBrowseTimedOut(at: CACurrentMediaTime()) {
            follow.resume(); follow.position = scroll.contentOffset.y
            browsing(false)
        }
        var settled = true
        if let focus = state.focus, frames.indices.contains(focus), follow.following, !scroll.isDragging, !scroll.isDecelerating {
            let target = min(max(0, scroll.contentSize.height - bounds.height), max(0, frames[focus].minY - bounds.height * configuration.anchor))
            let value = follow.step(target: target, dt: dt, immediate: reduceMotion || jumped)
            scroll.contentOffset.y = value
            settled = follow.isSettled(at: target)
            if settled, (motion.mode == .returning || motion.mode == .seeking) {
                motion.settledFollowing()
            }
        }
        recycleRows()
        let policy = RenderQualityPolicy.resolve(maximumFPS: window?.screen.maximumFramesPerSecond ?? 60, reduceMotion: reduceMotion)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for (index, row) in rows {
            let active = state.active.contains(index)
            let blur = lineBlur(index: index, state: state, active: active)
            row.update(time: state.time, active: active, configuration: configuration, policy: policy,
                       reduceMotion: reduceMotion, delta: dt, blurLevel: blur)
        }
        CATransaction.commit()
        dots.isHidden = true
        if follow.following, let interlude = state.interlude,
           let presentation = AMLLInterludeMotion.presentation(time: state.time, start: interlude.start, end: interlude.end, playing: playing),
           frames.indices.contains(interlude.nextLineIndex)
        {
            let size = max(10, min(24, configuration.fontSize * 0.32))
            let width = size * 3 + 8 * 2
            let next = frames[interlude.nextLineIndex]
            let x = interlude.isNextDuet ? bounds.width - 20 - width : 20
            dots.frame = CGRect(x: x, y: next.minY - size - configuration.fontSize * 0.8, width: width, height: size)
            dots.apply(presentation)
            dots.isHidden = false
        }
        if state.focus != lastFocus || state.active != lastActive {
            lastFocus = state.focus
            lastActive = state.active
            let snapshot = timeline.accessibility(state, canSeek: canSeek)
            scroll.accessibilityValue = ([snapshot.previous] + snapshot.current.map { Optional($0) } + [snapshot.next])
                .compactMap(\.self).joined(separator: ", ")
            // Do not post announcements on every word or steal VoiceOver focus while the user browses.
        }
        if !playing, settled, motion.mode != .browsing {
            displayLink?.isPaused = true; previousTick = 0
        }
    }

    private func makeLayout(_ index: Int) -> LyricTextLayout {
        if let layout = layouts[index] {
            return layout
        }
        let line = timeline.lines[index]
        let width = bounds.width - (line.isBackground ? 64 : 40)
        let layout = LyricTextLayout(line: line, width: width, configuration: configuration, traits: traitCollection)
        layouts[index] = layout; layoutOrder.append(index)
        if layoutOrder.count > 48 {
            layouts.removeValue(forKey: layoutOrder.removeFirst())
        }
        return layout
    }

    private func recycleRows() {
        let area = CGRect(x: 0, y: scroll.contentOffset.y - 100, width: bounds.width, height: bounds.height + 200)
        var lower = 0, upper = frames.count
        while lower < upper {
            let mid = (lower + upper) / 2
            if frames[mid].maxY < area.minY {
                lower = mid + 1
            } else {
                upper = mid
            }
        }
        var visible = Set<Int>(), index = lower
        while index < frames.count, frames[index].minY <= area.maxY {
            visible.insert(index); index += 1
        }
        for key in Array(rows.keys) where !visible.contains(key) {
            if let row = rows.removeValue(forKey: key) {
                row.removeFromSuperview(); if pool.count < 12 {
                    pool.append(row)
                }
            }
        }
        for key in visible.sorted() where rows[key] == nil {
            let row = pool.popLast() ?? LyricRowView()
            row.transform = .identity; row.frame = frames[key]
            let line = timeline.lines[key]
            row.configure(line: line, layout: makeLayout(key), scale: window?.screen.scale ?? 2,
                          configuration: configuration, blur: configuration.blurInactive && !reduceMotion, canSeek: canSeek)
            { [weak self] in
                guard let self, self.canSeek else { return }
                self.seek(LyricsTimeline.seekTarget(line: line, offset: self.offset, duration: self.duration))
                self.motion.handle(.seek(to: line.start), at: CACurrentMediaTime())
                self.resumeFollowing()
            }
            row.onFocus = { [weak self] in self?.beginBrowsing() }
            row.onResume = { [weak self] in self?.resumeFollowing() }
            scroll.addSubview(row); rows[key] = row
        }
        scroll.accessibilityElements = rows.keys.sorted().compactMap { rows[$0] }
    }

    func scrollViewWillBeginDragging(_: UIScrollView) {
        beginBrowsing()
    }

    private func beginBrowsing() {
        follow.browse(); motion.handle(.beginBrowsing, at: CACurrentMediaTime())
        browsing(true); displayLink?.isPaused = false
    }

    func scrollViewDidScroll(_: UIScrollView) {
        guard !needsRebuild else { return }
        recycleRows()
        if !follow.following {
            let time = position() - offset
            let policy = RenderQualityPolicy.resolve(maximumFPS: 60, reduceMotion: reduceMotion)
            for (index, row) in rows {
                row.update(time: time, active: timeline.lines[index].start <= time && time < timeline.lines[index].end,
                           configuration: configuration, policy: policy, reduceMotion: reduceMotion)
            }
        }
    }

    private func lineBlur(index: Int, state: LyricsRenderState, active: Bool) -> Double {
        guard configuration.blurInactive, !reduceMotion, follow.following, !active else { return 0 }
        let latest = state.active.max() ?? state.focus ?? index
        let focus = state.focus ?? latest
        let distance = index < focus ? abs(focus - index) + 1 : abs(index - max(focus, latest))
        let compactScale = bounds.width <= 1_024 ? 0.8 : 1
        return min(5, Double(1 + distance) * compactScale)
    }
}

private final class AMLLInterludeDotsView: UIView {
    private let dots = (0 ..< 3).map { _ in CALayer() }

    override init(frame: CGRect) {
        super.init(frame: frame)
        for dot in dots {
            dot.backgroundColor = UIColor.white.cgColor
            layer.addSublayer(dot)
        }
    }

    required init?(coder _: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        let diameter = min(bounds.height, (bounds.width - 16) / 3)
        for (index, dot) in dots.enumerated() {
            dot.frame = CGRect(x: CGFloat(index) * (diameter + 8), y: (bounds.height - diameter) / 2, width: diameter, height: diameter)
            dot.cornerRadius = diameter / 2
        }
    }

    func apply(_ presentation: AMLLInterludePresentation) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        transform = CGAffineTransform(scaleX: presentation.scale, y: presentation.scale)
        for (index, dot) in dots.enumerated() {
            dot.opacity = Float(presentation.dotOpacities[index])
        }
        CATransaction.commit()
    }
}

private final class LyricsScrollView: UIScrollView {
    var beginAccessibilityBrowsing: (() -> Void)?
    override func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
        beginAccessibilityBrowsing?()
        return super.accessibilityScroll(direction)
    }
}

@MainActor
private final class DisplayLinkProxy: NSObject {
    weak var owner: LyricsRenderView?
    @objc func tick(_ link: CADisplayLink) {
        owner?.tick(link)
    }
}
