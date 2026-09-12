import Foundation

struct AMLLSafeArea: Codable, Equatable, Sendable {
    var top = 0.0
    var leading = 0.0
    var bottom = 0.0
    var trailing = 0.0
}

struct AMLLRenderEnvironment: Codable, Equatable, Sendable {
    enum Anchor: String, Codable, Sendable { case top, center, bottom }
    var width: Double
    var height: Double
    var screenWidth: Double
    var fontSize: Double
    var safeArea = AMLLSafeArea()
    var displayScale = 1.0
    var maximumFPS = 60
    var localeIdentifier = ""
    var layoutDirection = "ltr"
    var alignPosition = 0.1
    var alignAnchor = Anchor.top
    var reduceMotion = false
    var reduceTransparency = false
    var boldText = false
    var dynamicTypeScale = 1.0
    var voiceOver = false
    var enableSpring = true
    var enableScale = true
    var enableBlur = true
    var hidePassedLines = false
    var alwaysPostpositionBackground = false
    var advance = 0.3
    var dotHeight = 16.0
}

enum AMLLPlaybackEvent: Sendable, Equatable {
    case snapshot
    case seek(revision: Int)
    case trackChanged
    case paused
    case resumed
}

struct AMLLPlayerInput: Sendable {
    var position: Double
    var offset: Double = 0
    var playing: Bool
    /// Explicit event revision; ordinary clock corrections must not be inferred to be seeks.
    var seekRevision = 0
    var seeking = false
    var document: LyricsDocument?
    var playbackSnapshot: PlaybackSnapshot?
    var artworkURL: URL?
    var configuration: LyricsRenderConfiguration?
    var event: AMLLPlaybackEvent?

    init(position: Double, offset: Double = 0, playing: Bool, seekRevision: Int = 0,
         seeking: Bool = false, document: LyricsDocument? = nil,
         playbackSnapshot: PlaybackSnapshot? = nil, artworkURL: URL? = nil,
         configuration: LyricsRenderConfiguration? = nil, event: AMLLPlaybackEvent? = nil)
    {
        self.position = position
        self.offset = offset
        self.playing = playing
        self.seekRevision = seekRevision
        self.seeking = seeking
        self.document = document
        self.playbackSnapshot = playbackSnapshot
        self.artworkURL = artworkURL
        self.configuration = configuration
        self.event = event
    }
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
        var wordClock: AMLLWordAnimationClock
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

    struct Background: Codable, Equatable, Sendable {
        var artworkURL: URL?
        var blur: Double
        var progress: Double
        var seed: UInt64

        init(artworkURL: URL? = nil, blur: Double = 0, progress: Double = 0, seed: UInt64 = 0) {
            self.artworkURL = artworkURL
            self.blur = blur
            self.progress = progress
            self.seed = seed
        }
    }

    struct Controls: Codable, Equatable, Sendable {
        var visible: Bool
        var progress: Double
        var enabled: Bool

        init(visible: Bool = false, progress: Double = 0, enabled: Bool = false) {
            self.visible = visible
            self.progress = progress
            self.enabled = enabled
        }
    }

    var lyricTime: Double
    var animationTime: Double
    var focusGroup: Int
    var rows: [Row]
    var interlude: Interlude?
    var browsing: Bool
    var settled: Bool
    var background = Background()
    var controls = Controls()
    var transitionProgress = 1.0
}

/// Deterministic native host for the pinned timeline/group/layout/scroll algorithms.
/// It owns one spring per group/transform, independent of visibility and view recycling.
struct AMLLFrameEngine {
    private struct GroupMotion {
        var y = AMLLSourceSpring()
        var slide = AMLLSourceSpring(-80)
        var mainScale = AMLLSourceSpring(100)
        var backgroundScale = AMLLSourceSpring(100)
        var yTransition = AMLLSourceTransition()
        var slideTransition = AMLLSourceTransition(-80)
        var mainScaleTransition = AMLLSourceTransition(100)
        var backgroundScaleTransition = AMLLSourceTransition(100)
        var mainAlpha = AMLLMaskAlpha()
        var backgroundAlpha = AMLLMaskAlpha()
        var mainWords = AMLLWordAnimationClock()
        var backgroundWords = AMLLWordAnimationClock()
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
        let oldHot = timeline.hot, oldBuffered = timeline.buffered
        let layout = timeline.update(time: time + environment.advance * 1000,
                                     groups: document.timings, seeking: seeking, hasBottomContent: false)
        for index in motions.indices {
            motions[index].mainWords.advance(elapsed, playing: previousInput?.playing ?? false)
            motions[index].backgroundWords.advance(elapsed, playing: previousInput?.playing ?? false)
            let disabled = seeking
                ? !timeline.hot.contains(index) && (oldHot.contains(index) || oldBuffered.contains(index))
                : oldBuffered.contains(index) && !timeline.buffered.contains(index)
            if disabled {
                motions[index].mainWords.disable(); motions[index].backgroundWords.disable()
            }
            if timeline.hot.contains(index), seeking || !oldHot.contains(index) {
                let group = document.groups[index]
                motions[index].mainWords.enable(at: time / 1000 - document.lines[group.main].start)
                if let background = group.background {
                    motions[index].backgroundWords.enable(at: time / 1000 - document.lines[background].start)
                }
            }
        }
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
            } else if !environment.reduceMotion {
                motions[index].yTransition.update(elapsed)
                motions[index].slideTransition.update(elapsed)
                motions[index].mainScaleTransition.update(elapsed)
                motions[index].backgroundScaleTransition.update(elapsed)
            }
            let yPosition = environment.enableSpring && !environment.reduceMotion
                ? motions[index].y.position : motions[index].yTransition.value
            let slidePosition = environment.enableSpring && !environment.reduceMotion
                ? motions[index].slide.position : motions[index].slideTransition.value
            let mainScalePosition = environment.enableSpring && !environment.reduceMotion
                ? motions[index].mainScale.position : motions[index].mainScaleTransition.value
            let backgroundScalePosition = environment.enableSpring && !environment.reduceMotion
                ? motions[index].backgroundScale.position : motions[index].backgroundScaleTransition.value
            let forceAlpha = touching || environment.reduceMotion || !environment.enableSpring
            motions[index].mainAlpha.update(scale: mainScalePosition / 100,
                                            gradient: motions[index].active, delta: elapsed, force: forceAlpha)
            motions[index].backgroundAlpha.update(scale: backgroundScalePosition / 100,
                                                  gradient: motions[index].active, delta: elapsed, force: forceAlpha)
            let motion = motions[index]
            let group = document.groups[index]
            let padding = environment.fontSize * 0.4
            let progress = min(1, max(0, 1 - abs(slidePosition) / 80))
            let bgFirst = group.backgroundFirst && !environment.alwaysPostpositionBackground
            let bgHeight = group.background.map(height) ?? 0
            let backgroundVisible = motion.active || !input.playing
            let bgAdvance = bgFirst ? bgHeight * progress + (backgroundVisible ? environment.fontSize * 0.3 : 0) : 0
            let y = (yPosition * 10).rounded() / 10
            rows.append(.init(lineIndex: group.main, groupIndex: index, y: y + padding + bgAdvance,
                              scale: mainScalePosition / 100, brightAlpha: motion.mainAlpha.bright,
                              darkAlpha: motion.mainAlpha.dark, wordClock: motion.mainWords, opacity: motion.opacity,
                              blur: min(5, motion.blur), active: motion.active, hidden: false))
            if let background = group.background {
                let top = bgFirst ? y + padding - bgHeight * (1 - progress) : y + padding + height(group.main) + environment.fontSize * 0.3
                rows.append(.init(lineIndex: background, groupIndex: index, y: top + bgHeight * slidePosition / 100,
                                  scale: backgroundScalePosition / 100 * (0.8 + progress * 0.2),
                                  brightAlpha: motion.backgroundAlpha.bright, darkAlpha: motion.backgroundAlpha.dark,
                                  wordClock: motion.backgroundWords,
                                  opacity: motion.opacity * (backgroundVisible ? 1 : 0), blur: min(5, motion.blur),
                                  active: motion.active, hidden: !motion.active && progress == 0))
            }
        }
        firstFrame = false; previousInput = input
        let duration = input.playbackSnapshot?.duration ?? 0
        let progress = duration > 0 ? min(1, max(0, input.position / duration)) : 0
        return .init(
            lyricTime: time / 1000,
            animationTime: animationTime,
            focusGroup: timeline.focus,
            rows: rows,
            interlude: interlude,
            browsing: browsing,
            settled: motions.allSatisfy {
                if environment.enableSpring || environment.reduceMotion {
                    return $0.y.arrived && $0.slide.arrived && $0.mainScale.arrived && $0.backgroundScale.arrived
                }
                return $0.yTransition.arrived && $0.slideTransition.arrived
                    && $0.mainScaleTransition.arrived && $0.backgroundScaleTransition.arrived
            },
            background: .init(artworkURL: input.artworkURL,
                              blur: input.configuration?.backgroundBlur ?? 0,
                              progress: progress,
                              seed: 0),
            controls: .init(visible: input.configuration?.showControls ?? false,
                            progress: progress,
                            enabled: input.playbackSnapshot?.restrictions.canSeek ?? false),
            transitionProgress: 1
        )
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
            let immediate = force || seeking || firstFrame
            if immediate {
                motions[index].y.setPosition(y)
                motions[index].slide.setPosition(slide)
                motions[index].mainScale.setPosition(mainScale)
                motions[index].backgroundScale.setPosition(bgScale)
                motions[index].yTransition.setPosition(y)
                motions[index].slideTransition.setPosition(slide)
                motions[index].mainScaleTransition.setPosition(mainScale)
                motions[index].backgroundScaleTransition.setPosition(bgScale)
            } else if !environment.enableSpring {
                motions[index].yTransition.setTarget(y)
                motions[index].slideTransition.setTarget(slide)
                motions[index].mainScaleTransition.setTarget(mainScale)
                motions[index].backgroundScaleTransition.setTarget(bgScale)
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
                motions[index].yTransition.setPosition(y)
                motions[index].slideTransition.setPosition(slide)
                motions[index].mainScaleTransition.setPosition(mainScale)
                motions[index].backgroundScaleTransition.setPosition(bgScale)
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
