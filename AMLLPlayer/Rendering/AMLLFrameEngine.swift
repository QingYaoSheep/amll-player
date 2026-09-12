import Foundation

struct AMLLRenderEnvironment: Codable, Equatable, Sendable {
    enum Anchor: String, Codable, Sendable { case top, center, bottom }
    var width: Double
    var height: Double
    var screenWidth: Double
    var fontSize: Double
    var alignPosition = 0.1
    var alignAnchor = Anchor.top
    var reduceMotion = false
    var enableSpring = true
    var enableScale = true
    var enableBlur = true
    var hidePassedLines = false
    var alwaysPostpositionBackground = false
    var dotHeight = 16.0
}

struct AMLLPlayerInput: Sendable {
    var position: Double
    var offset: Double = 0
    var playing: Bool
    /// Explicit event revision; ordinary clock corrections must not be inferred to be seeks.
    var seekRevision = 0
    var seeking = false
}

enum AMLLInteraction: Sendable {
    case beginBrowsing
    case browseBy(Double)
    case endBrowsing(velocity: Double)
    case resumeFollowing
    case seek(lineID: String)
    case playPause
    case previous
    case next
    case volume(Double)
    case beginDismissal
    case cancelDismissal
    case finishDismissal
}

struct AMLLFrameState: Codable, Sendable {
    struct Row: Codable, Sendable {
        var lineIndex: Int
        var groupIndex: Int
        var y: Double
        var scale: Double
        var brightAlpha: Double
        var darkAlpha: Double
        var opacity: Double
        var blur: Double
        var active: Bool
        var hidden: Bool
    }

    struct Interlude: Codable, Equatable, Sendable {
        var start: Double
        var end: Double
        var anchor: Int
        var duet: Bool
        var y: Double
    }

    var lyricTime: Double
    var animationTime: Double
    var focusGroup: Int
    var rows: [Row]
    var interlude: Interlude?
    var browsing: Bool
    var settled: Bool
}

/// Deterministic native host for the pinned timeline/group/layout/scroll algorithms.
/// It owns one spring per group/transform, independent of visibility and view recycling.
struct AMLLFrameEngine {
    private struct GroupMotion {
        var y = AMLLSourceSpring()
        var slide = AMLLSourceSpring(-80)
        var mainScale = AMLLSourceSpring(100)
        var backgroundScale = AMLLSourceSpring(100)
        var mainAlpha = AMLLMaskAlpha()
        var backgroundAlpha = AMLLMaskAlpha()
        var active = false
        var opacity = 1.0
        var blur = 0.0
    }

    let document: AMLLDisplayDocument
    private var environment: AMLLRenderEnvironment
    private var heights: [Double]
    private var motions: [GroupMotion]
    private var timeline = AMLLSourceTimeline()
    private var animationTime = 0.0
    private var scrollOffset = 0.0
    private var scrollVelocity = 0.0
    private var scrollMinimum = 0.0
    private var scrollMaximum = 0.0
    private var lastInteraction = 0.0
    private var browsing = false
    private var touching = false
    private var dirty = true
    private var firstFrame = true
    private var previousInput: AMLLPlayerInput?
    private var interlude: AMLLFrameState.Interlude?

    init(document: AMLLDisplayDocument, environment: AMLLRenderEnvironment, heights: [Double]) {
        self.document = document
        self.environment = environment
        self.heights = heights
        motions = document.groups.map { group in
            var motion = GroupMotion()
            motion.y.setPosition(environment.height * 2)
            if group.backgroundFirst {
                motion.slide.setPosition(80)
            }
            motion.y.updateParameters(.init(mass: 0.9, damping: 15, stiffness: 90))
            motion.slide.updateParameters(.init(mass: 0.9, damping: 15, stiffness: 90))
            motion.mainScale.updateParameters(.init(mass: 2, damping: 25, stiffness: 100))
            motion.backgroundScale.updateParameters(.init(mass: 1, damping: 20, stiffness: 50))
            return motion
        }
    }

    mutating func resize(environment: AMLLRenderEnvironment, heights: [Double]) {
        guard self.environment != environment || self.heights != heights else { return }
        self.environment = environment; self.heights = heights; dirty = true
    }

    mutating func handle(_ interaction: AMLLInteraction) {
        switch interaction {
        case .beginBrowsing:
            touching = true; browsing = true; scrollVelocity = 0
        case let .browseBy(delta):
            guard delta.isFinite else { return }
            scrollOffset = min(scrollMaximum, max(scrollMinimum, scrollOffset + delta))
        case let .endBrowsing(velocity):
            touching = false
            scrollVelocity = velocity.isFinite && abs(velocity) >= 100 ? velocity / 1000 : 0
        case .resumeFollowing:
            touching = false; browsing = false; scrollOffset = 0; scrollVelocity = 0
        default: return
        }
        lastInteraction = animationTime; dirty = true
    }

    mutating func render(_ input: AMLLPlayerInput, delta: Double) -> AMLLFrameState {
        let elapsed = delta.isFinite ? max(0, delta) : 0
        animationTime += elapsed
        let rawTime = ((input.position.isFinite ? input.position : 0) - (input.offset.isFinite ? input.offset : 0)) * 1000
        // DomLyricPlayer.setCurrentTime uses Math.round (ties toward +infinity).
        let time = floor(rawTime + 0.5)
        let seeking = firstFrame || input.seeking || previousInput?.seekRevision != input.seekRevision
        if seeking {
            scrollOffset = 0; scrollVelocity = 0; touching = false; browsing = false
        }
        if !touching, abs(scrollVelocity) > 0.05, elapsed > 0, elapsed <= 0.1 {
            scrollOffset = min(scrollMaximum, max(scrollMinimum, scrollOffset - scrollVelocity * elapsed * 1000))
            scrollVelocity *= pow(0.95, elapsed * 1000 / 16)
            dirty = true
        }
        if browsing, !touching, abs(scrollVelocity) <= 0.05, animationTime - lastInteraction >= 5 {
            handle(.resumeFollowing)
        }
        let oldFocus = timeline.focus
        let layout = timeline.update(time: time, groups: document.timings, seeking: seeking, hasBottomContent: false)
        let candidate = currentInterlude(time: time)
        let changedInterlude = candidate?.anchor != interlude?.anchor
        if changedInterlude {
            interlude = candidate
        }
        if dirty || layout || changedInterlude || previousInput?.playing != input.playing {
            if oldFocus != timeline.focus || changedInterlude {
                let interval = timeline.focus > 0 && timeline.focus < document.timings.count
                    ? (document.timings[timeline.focus].startTime - document.timings[timeline.focus - 1].startTime) / 1000 : nil
                if seeking || interlude != nil || interval != nil {
                    let p = AMLLMotionMetrics.verticalSpring(lineInterval: interval, seeking: seeking, interlude: interlude != nil)
                    for index in motions.indices {
                        motions[index].y.updateParameters(.init(mass: p.mass, damping: p.damping, stiffness: p.stiffness))
                        motions[index].slide.updateParameters(.init(mass: p.mass, damping: p.damping, stiffness: p.stiffness))
                    }
                }
            }
            layoutGroups(playing: input.playing, seeking: seeking, force: touching || environment.reduceMotion)
            dirty = false
        }
        var rows: [AMLLFrameState.Row] = []
        for index in motions.indices {
            if environment.enableSpring, !environment.reduceMotion {
                motions[index].y.update(elapsed)
                motions[index].slide.update(elapsed)
                motions[index].mainScale.update(elapsed)
                motions[index].backgroundScale.update(elapsed)
            }
            let forceAlpha = touching || environment.reduceMotion || !environment.enableSpring
            motions[index].mainAlpha.update(scale: motions[index].mainScale.position / 100,
                                            gradient: motions[index].active, delta: elapsed, force: forceAlpha)
            motions[index].backgroundAlpha.update(scale: motions[index].backgroundScale.position / 100,
                                                  gradient: motions[index].active, delta: elapsed, force: forceAlpha)
            let motion = motions[index]
            let group = document.groups[index]
            let padding = environment.fontSize * 0.4
            let progress = min(1, max(0, 1 - abs(motion.slide.position) / 80))
            let bgFirst = group.backgroundFirst && !environment.alwaysPostpositionBackground
            let bgHeight = group.background.map(height) ?? 0
            let backgroundVisible = motion.active || !input.playing
            let bgAdvance = bgFirst ? bgHeight * progress + (backgroundVisible ? environment.fontSize * 0.3 : 0) : 0
            let y = (motion.y.position * 10).rounded() / 10
            rows.append(.init(lineIndex: group.main, groupIndex: index, y: y + padding + bgAdvance,
                              scale: motion.mainScale.position / 100, brightAlpha: motion.mainAlpha.bright,
                              darkAlpha: motion.mainAlpha.dark, opacity: motion.opacity,
                              blur: min(5, motion.blur), active: motion.active, hidden: false))
            if let background = group.background {
                let top = bgFirst ? y + padding - bgHeight * (1 - progress) : y + padding + height(group.main) + environment.fontSize * 0.3
                rows.append(.init(lineIndex: background, groupIndex: index, y: top + bgHeight * motion.slide.position / 100,
                                  scale: motion.backgroundScale.position / 100 * (0.8 + progress * 0.2),
                                  brightAlpha: motion.backgroundAlpha.bright, darkAlpha: motion.backgroundAlpha.dark,
                                  opacity: motion.opacity * (backgroundVisible ? 1 : 0), blur: min(5, motion.blur),
                                  active: motion.active, hidden: !motion.active && progress == 0))
            }
        }
        firstFrame = false; previousInput = input
        return .init(lyricTime: time / 1000, animationTime: animationTime, focusGroup: timeline.focus,
                     rows: rows, interlude: interlude, browsing: browsing,
                     settled: motions.allSatisfy { $0.y.arrived && $0.slide.arrived && $0.mainScale.arrived && $0.backgroundScale.arrived })
    }

    private func height(_ index: Int) -> Double {
        heights.indices.contains(index) ? heights[index] : environment.height / 5
    }

    private func currentInterlude(time: Double) -> AMLLFrameState.Interlude? {
        for anchor in [timeline.focus - 1, timeline.focus, timeline.focus + 1] {
            guard anchor >= -1, anchor < document.timings.count - 1 else { continue }
            let start = anchor == -1 ? 0 : document.timings[anchor].endTime
            let end = max(start, document.timings[anchor + 1].startTime - 250)
            if end - start >= 4000, start < time + 20, time + 20 < end {
                return .init(start: max(start, time + 20) / 1000, end: end / 1000, anchor: anchor,
                             duet: document.lines[document.groups[anchor + 1].main].isDuet, y: 0)
            }
        }
        return nil
    }

    private mutating func layoutGroups(playing: Bool, seeking: Bool, force: Bool) {
        let latest = timeline.buffered.max() ?? -1
        let active = motions.indices.map { timeline.buffered.contains($0) || ($0 >= timeline.focus && $0 < latest) }
        let groupHeights = document.groups.enumerated().map { index, group in
            height(group.main) + environment.fontSize * 0.8
                + (active[index] || !playing ? group.background.map { height($0) + environment.fontSize * 0.3 } ?? 0 : 0)
        }
        let preceding = groupHeights.prefix(timeline.focus).reduce(0, +)
        scrollMinimum = -preceding
        var y = -scrollOffset - preceding + environment.height * environment.alignPosition
        if let interlude, interlude.anchor != -1 {
            y -= environment.dotHeight + environment.fontSize * 0.8
        }
        if groupHeights.indices.contains(timeline.focus) {
            switch environment.alignAnchor {
            case .top: break
            case .center: y -= groupHeights[timeline.focus] / 2
            case .bottom: y -= groupHeights[timeline.focus]
            }
        }
        var delay = 0.0, baseDelay = touching ? 0 : 0.05
        let nonDynamic = !document.lines.contains { $0.precision == .word }
        for index in motions.indices {
            if interlude?.anchor == index - 1 {
                y += environment.fontSize * 0.4
                interlude?.y = y
                y += environment.dotHeight + environment.fontSize * 0.4
            }
            let group = document.groups[index]
            let hasBuffered = timeline.buffered.contains(index)
            motions[index].active = active[index]
            motions[index].opacity = environment.hidePassedLines && playing && index < (interlude.map { $0.anchor + 1 } ?? timeline.focus)
                ? 0.0001 : (hasBuffered ? 0.85 : (nonDynamic ? 0.2 : 1))
            var blur = 0.0
            if environment.enableBlur, !environment.reduceMotion, !touching, abs(scrollVelocity) <= 0.05, !active[index] {
                blur = index < timeline.focus ? Double(2 + timeline.focus - index) : Double(1 + abs(index - max(timeline.focus, latest)))
                if environment.screenWidth <= 1024 {
                    blur *= 0.8
                }
            }
            motions[index].blur = blur
            let hiddenSlide = group.backgroundFirst && !environment.alwaysPostpositionBackground ? 80.0 : -80.0
            let slide = active[index] || !playing ? 0 : hiddenSlide
            let mainScale = !active[index] && playing && environment.enableScale ? 97.0 : 100
            let bgScale = !active[index] && playing ? 75.0 : 100
            if force || !environment.enableSpring {
                motions[index].y.setPosition(y)
                motions[index].slide.setPosition(slide)
                motions[index].mainScale.setPosition(mainScale)
                motions[index].backgroundScale.setPosition(bgScale)
            } else {
                motions[index].y.setTarget(y, delay: delay)
                motions[index].slide.setTarget(slide, delay: delay)
                // DomLyricLine.setTransform deliberately does not delay its scale spring.
                motions[index].mainScale.setTarget(mainScale)
                motions[index].backgroundScale.setTarget(bgScale)
            }
            y += groupHeights[index]
            if y >= 0, !seeking {
                delay += baseDelay
                if index >= timeline.focus {
                    baseDelay /= 1.05
                }
            }
        }
        scrollMaximum = max(scrollMinimum, y + scrollOffset - environment.height / 2)
    }
}
