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
    /// The requested position can precede the authoritative Spotify clock update.
    var seekPosition: Double?
    var seeking = false
    var document: LyricsDocument?
    var playbackSnapshot: PlaybackSnapshot?
    var artworkURL: URL?
    var configuration: LyricsRenderConfiguration?
    var event: AMLLPlaybackEvent?

    init(position: Double, offset: Double = 0, playing: Bool, seekRevision: Int = 0, seekPosition: Double? = nil,
         seeking: Bool = false, document: LyricsDocument? = nil,
         playbackSnapshot: PlaybackSnapshot? = nil, artworkURL: URL? = nil,
         configuration: LyricsRenderConfiguration? = nil, event: AMLLPlaybackEvent? = nil)
    {
        self.position = position
        self.offset = offset
        self.playing = playing
        self.seekRevision = seekRevision
        self.seekPosition = seekPosition
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
    struct Row: Codable, Equatable, Sendable {
        enum VisualFocus: String, Codable, Equatable, Sendable {
            case waiting, preparing, current, holding, passed
        }

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
        var visualFocus: VisualFocus
        var fillComplete: Bool
        var hdrHold: Bool
        struct Retirement: Codable, Equatable, Sendable {
            var startedAt: Double
            var progress: Double
            var hdrWeight: Double
        }

        var retirement: Retirement?
        var positionMotion: AMLLScheduledSpring.Schedule?

        private enum CodingKeys: String, CodingKey {
            case lineIndex, groupIndex, y, scale, brightAlpha, darkAlpha, wordClock, opacity, blur, active, hidden
            case visualFocus, fillComplete, hdrHold, retirement, positionMotion
        }

        init(lineIndex: Int, groupIndex: Int, y: Double, scale: Double, brightAlpha: Double, darkAlpha: Double,
             wordClock: AMLLWordAnimationClock, opacity: Double = 1, blur: Double = 0,
             active: Bool = false, hidden: Bool = false, visualFocus: VisualFocus = .waiting,
             fillComplete: Bool = false, hdrHold: Bool = false,
             positionMotion: AMLLScheduledSpring.Schedule? = nil, retirement: Retirement? = nil)
        {
            self.lineIndex = lineIndex; self.groupIndex = groupIndex; self.y = y; self.scale = scale
            self.brightAlpha = brightAlpha; self.darkAlpha = darkAlpha; self.wordClock = wordClock
            self.opacity = opacity; self.blur = blur; self.active = active; self.hidden = hidden
            self.visualFocus = visualFocus; self.fillComplete = fillComplete; self.hdrHold = hdrHold
            self.positionMotion = positionMotion; self.retirement = retirement
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            lineIndex = try values.decode(Int.self, forKey: .lineIndex)
            groupIndex = try values.decode(Int.self, forKey: .groupIndex)
            y = try values.decode(Double.self, forKey: .y)
            scale = try values.decode(Double.self, forKey: .scale)
            brightAlpha = try values.decode(Double.self, forKey: .brightAlpha)
            darkAlpha = try values.decode(Double.self, forKey: .darkAlpha)
            wordClock = try values.decode(AMLLWordAnimationClock.self, forKey: .wordClock)
            opacity = try values.decodeIfPresent(Double.self, forKey: .opacity) ?? 1
            blur = try values.decodeIfPresent(Double.self, forKey: .blur) ?? 0
            active = try values.decodeIfPresent(Bool.self, forKey: .active) ?? false
            hidden = try values.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
            visualFocus = try values.decodeIfPresent(VisualFocus.self, forKey: .visualFocus) ?? .waiting
            fillComplete = try values.decodeIfPresent(Bool.self, forKey: .fillComplete) ?? false
            hdrHold = try values.decodeIfPresent(Bool.self, forKey: .hdrHold) ?? false
            retirement = try values.decodeIfPresent(Retirement.self, forKey: .retirement)
            positionMotion = try values.decodeIfPresent(AMLLScheduledSpring.Schedule.self, forKey: .positionMotion)
        }
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

        private enum CodingKeys: String, CodingKey { case artworkURL, blur, progress, seed }

        init(artworkURL: URL? = nil, blur: Double = 0, progress: Double = 0, seed: UInt64 = 0) {
            self.artworkURL = artworkURL
            self.blur = blur
            self.progress = progress
            self.seed = seed
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            artworkURL = try values.decodeIfPresent(URL.self, forKey: .artworkURL)
            blur = try values.decodeIfPresent(Double.self, forKey: .blur) ?? 0
            progress = try values.decodeIfPresent(Double.self, forKey: .progress) ?? 0
            seed = try values.decodeIfPresent(UInt64.self, forKey: .seed) ?? 0
        }
    }

    struct Controls: Codable, Equatable, Sendable {
        var visible: Bool
        var progress: Double
        var enabled: Bool

        private enum CodingKeys: String, CodingKey { case visible, progress, enabled }

        init(visible: Bool = false, progress: Double = 0, enabled: Bool = false) {
            self.visible = visible
            self.progress = progress
            self.enabled = enabled
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            visible = try values.decodeIfPresent(Bool.self, forKey: .visible) ?? false
            progress = try values.decodeIfPresent(Double.self, forKey: .progress) ?? 0
            enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
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

    private enum CodingKeys: String, CodingKey {
        case lyricTime, animationTime, focusGroup, rows, interlude, browsing, settled, background, controls, transitionProgress
    }

    init(lyricTime: Double, animationTime: Double, focusGroup: Int, rows: [Row], interlude: Interlude?, browsing: Bool,
         settled: Bool, background: Background = .init(), controls: Controls = .init(), transitionProgress: Double = 1)
    {
        self.lyricTime = lyricTime; self.animationTime = animationTime; self.focusGroup = focusGroup
        self.rows = rows; self.interlude = interlude; self.browsing = browsing; self.settled = settled
        self.background = background; self.controls = controls; self.transitionProgress = transitionProgress
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        lyricTime = try values.decode(Double.self, forKey: .lyricTime)
        animationTime = try values.decode(Double.self, forKey: .animationTime)
        focusGroup = try values.decode(Int.self, forKey: .focusGroup)
        rows = try values.decode([Row].self, forKey: .rows)
        interlude = try values.decodeIfPresent(Interlude.self, forKey: .interlude)
        browsing = try values.decode(Bool.self, forKey: .browsing)
        settled = try values.decode(Bool.self, forKey: .settled)
        background = try values.decodeIfPresent(Background.self, forKey: .background) ?? .init()
        controls = try values.decodeIfPresent(Controls.self, forKey: .controls) ?? .init()
        transitionProgress = try values.decodeIfPresent(Double.self, forKey: .transitionProgress) ?? 1
    }
}

/// Deterministic native host for the pinned timeline/group/layout/scroll algorithms.
/// It owns one spring per group/transform, independent of visibility and view recycling.
struct AMLLFrameEngine {
    private struct GroupMotion {
        var y = AMLLScheduledSpring()
        var slide = AMLLScheduledSpring(-80)
        var mainScale = AMLLSourceSpring(100)
        var backgroundScale = AMLLSourceSpring(100)
        var yTransition = AMLLSourceTransition()
        var slideTransition = AMLLSourceTransition(-80)
        var mainScaleTransition = AMLLSourceTransition(100)
        var backgroundScaleTransition = AMLLSourceTransition(100)
        var opacityTransition = AMLLSourceTransition(1)
        var blurTransition = AMLLSourceTransition()
        var mainAlpha = AMLLMaskAlpha()
        var backgroundAlpha = AMLLMaskAlpha()
        var mainWords = AMLLWordAnimationClock()
        var backgroundWords = AMLLWordAnimationClock()
        var active = false
        var opacity = 1.0
        var blur = 0.0
        var mainCompleted = false
        var visualActive = false
        var backgroundVisualActive = false
        var mainSinging = false
        var backgroundSinging = false
        var mainFocusRetained = false
        var backgroundCompleted = false
        var backgroundFocusRetained = false
        var completedReleaseAt: Double?
        var mainRetirement: AMLLFocusRetirement?
        var backgroundRetirement: AMLLFocusRetirement?
    }

    let document: AMLLDisplayDocument
    private var environment: AMLLRenderEnvironment
    private var heights: [Double]
    private var motions: [GroupMotion]
    private var timeline = AMLLSourceTimeline()
    private var singingTimeline = AMLLSourceTimeline()
    private var animationTime = 0.0
    private var scrollOffset = 0.0
    private var previousPreceding = 0.0
    private var scrollVelocity = 0.0
    private var scrollMinimum = 0.0
    private var scrollMaximum = 0.0
    private var lastInteraction = 0.0
    private var browsing = false
    private var touching = false
    private var resumeAtLineStart: Double?
    private var dirty = true
    private var firstFrame = true
    private var previousInput: AMLLPlayerInput?
    private var pendingSeek: (target: Double, origin: Double, requestedAt: Double)?
    /// Advances when the actual lyric clock is reanchored, including delayed seek delivery.
    private(set) var timeAnchorRevision = 0
    private var interlude: AMLLFrameState.Interlude?
    private var visualFocus: Int?
    private var pendingVisualFocus: (index: Int, startTime: Double)?
    private var positionRevision = 0
    private var positionReset = false
    private var releasedForInterlude = false
    private var previousSongEnded = false

    private static func backgroundSeed(for artworkURL: URL?) -> UInt64 {
        guard let value = artworkURL?.absoluteString, !value.isEmpty else { return 0 }
        // FNV-1a keeps the background deterministic across launches and
        // devices while avoiding Swift's process-randomized Hasher seed.
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return hash
    }

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
        positionReset = self.environment.width != environment.width || self.environment.height != environment.height
            || self.heights != heights
        self.environment = environment; self.heights = heights; dirty = true
    }

    mutating func handle(_ interaction: AMLLInteraction) {
        switch interaction {
        case .beginBrowsing:
            touching = true; browsing = true; scrollVelocity = 0
            resumeAtLineStart = nil
        case let .browseBy(delta):
            guard delta.isFinite else { return }
            scrollOffset = min(scrollMaximum, max(scrollMinimum, scrollOffset + delta))
        case let .endBrowsing(velocity):
            touching = false
            // A short, bounded coast after release. Units are points/ms;
            // the decay below integrates independently of display refresh.
            scrollVelocity = velocity.isFinite ? min(0.8, max(-0.8, velocity / 1000)) : 0
            let releasedTime = (previousInput?.position ?? 0) - (previousInput?.offset ?? 0)
            resumeAtLineStart = document.groups.map { document.actualLineStarts[$0.main] }
                .filter { $0 > releasedTime }.min()
        case .resumeFollowing:
            touching = false; browsing = false; scrollOffset = 0; scrollVelocity = 0
            resumeAtLineStart = nil
            pendingVisualFocus = nil
            visualFocus = nil
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
        let songEnded = (input.playbackSnapshot?.duration ?? 0) > 0
            && input.position >= (input.playbackSnapshot?.duration ?? 0)
        if songEnded != previousSongEnded {
            dirty = true
            previousSongEnded = songEnded
        }
        let eventRequiresSeek = switch input.event {
        case .seek, .trackChanged: true
        default: false
        }
        let revisionChanged = previousInput.map { $0.seekRevision != input.seekRevision } ?? false
        let seekRequested = input.seeking || eventRequiresSeek || revisionChanged
        if seekRequested {
            if let target = input.seekPosition, target.isFinite, abs(target - input.position) > 0.001 {
                pendingSeek = (target, input.position, animationTime)
            } else {
                pendingSeek = nil
            }
        }
        if input.seekPosition == nil {
            pendingSeek = nil
        }
        var seekArrived = false
        if let pending = pendingSeek {
            // Accept only movement toward this explicit request. Do not infer
            // a seek from ordinary snapshot corrections or rewrite song time.
            let moved = pending.target < pending.origin
                ? input.position <= (pending.origin + pending.target) / 2
                : input.position >= pending.target - 0.001
            let tolerance = 0.25 + (input.playing ? animationTime - pending.requestedAt : 0)
            if moved, abs(input.position - pending.target) <= tolerance {
                seekArrived = true
                pendingSeek = nil
            }
        }
        let seeking = firstFrame || seekRequested || seekArrived
        if seeking {
            timeAnchorRevision &+= 1
            scrollOffset = 0; scrollVelocity = 0; touching = false; browsing = false
            resumeAtLineStart = nil
            pendingVisualFocus = nil
            visualFocus = nil
            releasedForInterlude = false
            for index in motions.indices {
                motions[index].mainFocusRetained = false
                motions[index].backgroundFocusRetained = false
                motions[index].completedReleaseAt = nil
                motions[index].mainRetirement = nil
                motions[index].backgroundRetirement = nil
            }
        }
        if browsing, !touching, abs(scrollVelocity) > 0.001, elapsed > 0 {
            let decay = exp(-elapsed / 0.12)
            let distance = scrollVelocity * 120 * (1 - decay)
            let nextOffset = min(scrollMaximum, max(scrollMinimum, scrollOffset - distance))
            scrollVelocity = nextOffset == scrollOffset ? 0 : scrollVelocity * decay
            scrollOffset = nextOffset
            dirty = true
        }
        if browsing, !touching, input.playing, let start = resumeAtLineStart, time / 1000 >= start {
            handle(.resumeFollowing)
        }
        let oldFocus = timeline.focus
        let layout = timeline.update(time: time + environment.advance * 1000,
                                     groups: document.timings, seeking: seeking, hasBottomContent: false)
        let singingLayout = singingTimeline.update(time: time, groups: document.singingTimings,
                                                   seeking: seeking, hasBottomContent: false)
        for index in motions.indices {
            motions[index].mainWords.advance(elapsed, playing: previousInput?.playing ?? false)
            motions[index].backgroundWords.advance(elapsed, playing: previousInput?.playing ?? false)
            let group = document.groups[index]
            let mainStart = document.actualLineStarts[group.main]
            let mainEnd = document.actualLineEnds[group.main]
            let mainSinging = mainStart <= time / 1000 && time / 1000 < mainEnd
            let beganSinging = mainSinging && !motions[index].mainSinging
            if mainSinging != motions[index].mainSinging {
                dirty = true
            }
            motions[index].mainSinging = mainSinging
            if beganSinging, !seeking, browsing || visualFocus == timeline.focus {
                releaseCompletedFocus(except: index, at: animationTime - elapsed)
            }
            if mainSinging, motions[index].mainRetirement == nil {
                motions[index].mainFocusRetained = true
            }
            let mainCompleted = time / 1000 >= mainEnd && time / 1000 >= mainStart
            if mainCompleted != motions[index].mainCompleted {
                dirty = true
                if !mainCompleted {
                    motions[index].mainFocusRetained = mainSinging
                    motions[index].mainRetirement = nil
                    motions[index].mainWords = AMLLWordAnimationClock()
                    motions[index].completedReleaseAt = nil
                }
            }
            motions[index].mainCompleted = mainCompleted
            if mainSinging, seeking || !motions[index].mainWords.enabled {
                motions[index].mainWords.enable(at: time / 1000 - document.lines[group.main].start)
            } else if seeking {
                motions[index].mainWords = AMLLWordAnimationClock()
            } else if !mainSinging, motions[index].mainWords.enabled {
                motions[index].mainWords.disable()
            }
            if let background = group.background {
                let backgroundStart = document.actualLineStarts[background]
                let backgroundSinging = backgroundStart <= time / 1000 && time / 1000 < document.actualLineEnds[background]
                if backgroundSinging != motions[index].backgroundSinging {
                    dirty = true
                }
                let beganBackground = backgroundSinging && !motions[index].backgroundSinging
                motions[index].backgroundSinging = backgroundSinging
                if beganBackground, !seeking, browsing || visualFocus == timeline.focus {
                    releaseCompletedFocus(except: index, at: animationTime - elapsed)
                }
                if backgroundSinging, motions[index].backgroundRetirement == nil {
                    motions[index].backgroundFocusRetained = true
                }
                let backgroundCompleted = time / 1000 >= document.actualLineEnds[background]
                if backgroundCompleted != motions[index].backgroundCompleted {
                    dirty = true
                    if !backgroundCompleted {
                        motions[index].backgroundFocusRetained = backgroundSinging
                        motions[index].backgroundRetirement = nil
                        motions[index].backgroundWords = AMLLWordAnimationClock()
                        motions[index].completedReleaseAt = nil
                    }
                }
                motions[index].backgroundCompleted = backgroundCompleted
                if backgroundSinging, seeking || !motions[index].backgroundWords.enabled {
                    motions[index].backgroundWords.enable(at: time / 1000 - document.lines[background].start)
                } else if seeking {
                    motions[index].backgroundWords = AMLLWordAnimationClock()
                } else if !backgroundSinging, motions[index].backgroundWords.enabled {
                    motions[index].backgroundWords.disable()
                }
            }
        }
        let candidate = currentInterlude(time: time)
        let changedInterlude = candidate?.anchor != interlude?.anchor
        if changedInterlude {
            interlude = candidate
        }
        if songEnded {
            visualFocus = nil
            pendingVisualFocus = nil
        } else if interlude != nil {
            visualFocus = nil
            pendingVisualFocus = nil
            releasedForInterlude = true
            for index in motions.indices {
                motions[index].mainFocusRetained = false
                motions[index].backgroundFocusRetained = false
            }
        } else if (visualFocus == nil && !releasedForInterlude) || seeking || (releasedForInterlude && changedInterlude) {
            selectVisualFocus(document.groups.indices.contains(timeline.focus) ? timeline.focus : nil, at: animationTime - elapsed)
            releasedForInterlude = false
        }
        if songEnded {
            for index in motions.indices {
                motions[index].mainFocusRetained = false
                motions[index].backgroundFocusRetained = false
            }
        }
        if browsing {
            pendingVisualFocus = nil
            if let current = motions.indices.first(where: { motions[$0].mainSinging }) {
                visualFocus = current
            }
        }
        if !songEnded, !browsing, interlude == nil, pendingVisualFocus == nil,
           visualFocus != timeline.focus, environment.reduceMotion || !input.playing
        {
            selectVisualFocus(document.groups.indices.contains(timeline.focus) ? timeline.focus : nil, at: animationTime - elapsed)
        }
        if dirty || layout || singingLayout || changedInterlude || previousInput?.playing != input.playing {
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
            layoutGroups(playing: input.playing, seeking: seeking, frameStart: animationTime - elapsed, sourcePosition: input.position)
            dirty = false
        }
        let forceAlpha = seeking || firstFrame || environment.reduceMotion
        var appearanceTime = animationTime - elapsed
        while !browsing {
            var nextEvent = pendingVisualFocus?.startTime
            for motion in motions {
                if let deadline = motion.completedReleaseAt, deadline < (nextEvent ?? .infinity) {
                    nextEvent = deadline
                }
            }
            guard let nextEvent, nextEvent <= animationTime else { break }
            let boundary = max(appearanceTime, nextEvent)
            advanceAppearance(delta: boundary - appearanceTime, forceAlpha: forceAlpha)
            for index in motions.indices {
                if let deadline = motions[index].completedReleaseAt, deadline <= boundary {
                    releaseVisualFocus(in: index, at: boundary, allowEarly: true)
                }
            }
            if let pending = pendingVisualFocus, pending.startTime <= boundary {
                selectVisualFocus(pending.index, at: boundary)
                pendingVisualFocus = nil
            }
            layoutGroups(playing: input.playing, seeking: false, frameStart: boundary, sourcePosition: input.position)
            dirty = false
            appearanceTime = boundary
        }
        advanceAppearance(delta: animationTime - appearanceTime, forceAlpha: forceAlpha)
        for index in motions.indices {
            motions[index].y.advance(to: animationTime)
            motions[index].slide.advance(to: animationTime)
        }
        var rows: [AMLLFrameState.Row] = []
        rows.reserveCapacity(document.groups.count * 2)
        var allSettled = true
        for index in motions.indices {
            let yPosition = environment.enableSpring && !environment.reduceMotion
                ? motions[index].y.position : motions[index].yTransition.value
            let slidePosition = environment.enableSpring && !environment.reduceMotion
                ? motions[index].slide.position : motions[index].slideTransition.value
            let mainScalePosition = environment.enableSpring && !environment.reduceMotion
                ? motions[index].mainScale.position : motions[index].mainScaleTransition.value
            let backgroundScalePosition = environment.enableSpring && !environment.reduceMotion
                ? motions[index].backgroundScale.position : motions[index].backgroundScaleTransition.value
            let motion = motions[index]
            let mainExit = motion.mainRetirement?.presentation(opacity: motion.opacityTransition.value)
            let backgroundExit = motion.backgroundRetirement?.presentation(opacity: motion.opacityTransition.value)
            let group = document.groups[index]
            let actualStart = document.actualLineStarts[group.main]
            let visualState: AMLLFrameState.Row.VisualFocus = if motion.mainRetirement != nil {
                .passed
            } else if motion.mainSinging {
                .current
            } else if motion.mainFocusRetained && motion.mainCompleted && !songEnded && interlude == nil {
                .holding
            } else if visualFocus == index && time / 1000 < actualStart && !browsing {
                .preparing
            } else if motion.mainCompleted || index < (visualFocus ?? timeline.focus) {
                .passed
            } else {
                .waiting
            }
            let holdHDR = visualState == .holding && !songEnded && interlude == nil
            let padding = environment.fontSize * 0.4
            let progress = min(1, max(0, 1 - abs(slidePosition) / 80))
            let bgFirst = group.backgroundFirst && !environment.alwaysPostpositionBackground
            let bgHeight = group.background.map(height) ?? 0
            let backgroundVisible = motion.active || !input.playing || !(motion.backgroundRetirement?.arrived ?? true)
            let bgAdvance = bgFirst ? bgHeight * progress : 0
            let y = (yPosition * 10).rounded() / 10
            rows.append(.init(lineIndex: group.main, groupIndex: index, y: y + padding + bgAdvance,
                              scale: mainScalePosition / 100, brightAlpha: mainExit?.bright ?? motion.mainAlpha.bright,
                              darkAlpha: mainExit?.dark ?? motion.mainAlpha.dark, wordClock: motion.mainWords,
                              opacity: motion.opacityTransition.value,
                              blur: mainExit?.blur ?? min(5, motion.blurTransition.value),
                              active: motion.mainSinging,
                              hidden: false,
                              visualFocus: visualState, fillComplete: motion.mainCompleted, hdrHold: holdHDR,
                              positionMotion: motion.y.schedule, retirement: mainExit?.state))
            if let background = group.background {
                let backgroundState: AMLLFrameState.Row.VisualFocus = motion.backgroundRetirement != nil ? .passed
                    : motion.backgroundSinging ? .current
                    : motion.backgroundFocusRetained && motion.backgroundCompleted ? .holding
                    : motion.backgroundCompleted ? .passed
                    : motion.backgroundVisualActive && !browsing ? .preparing : .waiting
                let top = bgFirst ? y + padding - bgHeight * (1 - progress) : y + padding + height(group.main)
                rows.append(.init(lineIndex: background, groupIndex: index, y: top + bgHeight * slidePosition / 100,
                                  scale: backgroundScalePosition / 100 * (0.8 + progress * 0.2),
                                  brightAlpha: backgroundExit?.bright ?? motion.backgroundAlpha.bright, darkAlpha: backgroundExit?.dark ?? motion.backgroundAlpha.dark,
                                  wordClock: motion.backgroundWords,
                                  opacity: motion.opacityTransition.value * (backgroundVisible ? 1 : 0),
                                  blur: backgroundExit?.blur ?? min(5, motion.blurTransition.value),
                                  active: motion.backgroundSinging, hidden: !motion.active && progress == 0 && (motion.backgroundRetirement?.arrived ?? true),
                                  visualFocus: backgroundState, fillComplete: motion.backgroundCompleted,
                                  hdrHold: backgroundState == .holding && !songEnded && interlude == nil,
                                  positionMotion: motion.y.schedule, retirement: backgroundExit?.state))
            }
            allSettled = allSettled && (motion.mainRetirement?.arrived ?? true) && (motion.backgroundRetirement?.arrived ?? true)
            if environment.enableSpring || environment.reduceMotion {
                allSettled = allSettled && motion.y.arrived && motion.slide.arrived
                    && motion.mainScale.arrived && motion.backgroundScale.arrived
                    && motion.opacityTransition.arrived && motion.blurTransition.arrived
            } else {
                allSettled = allSettled && motion.yTransition.arrived && motion.slideTransition.arrived
                    && motion.mainScaleTransition.arrived && motion.backgroundScaleTransition.arrived
                    && motion.opacityTransition.arrived && motion.blurTransition.arrived
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
            settled: allSettled,
            background: .init(artworkURL: input.artworkURL,
                              blur: input.configuration?.backgroundBlur ?? 0,
                              progress: progress,
                              seed: Self.backgroundSeed(for: input.artworkURL)),
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

    private mutating func advanceAppearance(delta elapsed: Double, forceAlpha: Bool) {
        guard elapsed > 0 || forceAlpha else { return }
        for index in motions.indices {
            if environment.enableSpring, !environment.reduceMotion {
                motions[index].mainScale.update(elapsed)
                motions[index].backgroundScale.update(elapsed)
            } else if !environment.reduceMotion {
                motions[index].yTransition.update(elapsed)
                motions[index].slideTransition.update(elapsed)
                motions[index].mainScaleTransition.update(elapsed)
                motions[index].backgroundScaleTransition.update(elapsed)
            }
            if !environment.reduceMotion {
                motions[index].opacityTransition.update(elapsed)
                motions[index].blurTransition.update(elapsed)
            }
            motions[index].mainRetirement?.advance(elapsed, immediately: forceAlpha)
            motions[index].backgroundRetirement?.advance(elapsed, immediately: forceAlpha)
            let mainAppearanceScale = environment.enableScale ? (environment.enableSpring ? motions[index].mainScale.position : motions[index].mainScaleTransition.value) / 100
                : (motions[index].visualActive ? 1 : 0.97)
            let backgroundAppearanceScale = environment.enableScale ? (environment.enableSpring ? motions[index].backgroundScale.position : motions[index].backgroundScaleTransition.value) / 100
                : (motions[index].backgroundVisualActive ? 1 : 0.97)
            motions[index].mainAlpha.update(scale: motions[index].mainCompleted && !motions[index].visualActive ? 0.97 : mainAppearanceScale,
                                            gradient: motions[index].visualActive, delta: elapsed, force: forceAlpha)
            motions[index].backgroundAlpha.update(scale: motions[index].backgroundCompleted && !motions[index].backgroundVisualActive ? 0.97 : backgroundAppearanceScale,
                                                  gradient: motions[index].backgroundVisualActive, delta: elapsed, force: forceAlpha)
        }
    }

    /// Scroll-ahead may transfer appearance before the outgoing word ends.
    /// Genuine source-time overlap keeps each singing voice focused.
    private func canReleaseBeforeWordEnd(in index: Int, line: Int) -> Bool {
        !browsing && index < timeline.focus && document.singingTimings.indices.contains(timeline.focus)
            && document.actualLineEnds[line] * 1000 <= document.singingTimings[timeline.focus].startTime
    }

    private mutating func releaseVisualFocus(in index: Int, at time: Double, allowEarly: Bool = false) {
        motions[index].completedReleaseAt = nil
        let group = document.groups[index]
        let releaseMainAhead = allowEarly && canReleaseBeforeWordEnd(in: index, line: group.main)
        let releaseBackgroundAhead = allowEarly && (group.background.map { canReleaseBeforeWordEnd(in: index, line: $0) } ?? false)
        if !motions[index].mainSinging || releaseMainAhead, motions[index].mainFocusRetained {
            motions[index].mainFocusRetained = false
            if motions[index].mainCompleted || releaseMainAhead, motions[index].mainRetirement == nil {
                motions[index].mainRetirement = .init(at: time,
                    bright: motions[index].mainAlpha.bright, dark: motions[index].mainAlpha.dark,
                    opacity: motions[index].opacityTransition.value, blur: motions[index].blurTransition.value)
            }
            dirty = true
        }
        if !motions[index].backgroundSinging || releaseBackgroundAhead, motions[index].backgroundFocusRetained {
            motions[index].backgroundFocusRetained = false
            if motions[index].backgroundCompleted || releaseBackgroundAhead, motions[index].backgroundRetirement == nil {
                motions[index].backgroundRetirement = .init(at: time,
                    bright: motions[index].backgroundAlpha.bright, dark: motions[index].backgroundAlpha.dark,
                    opacity: motions[index].opacityTransition.value, blur: motions[index].blurTransition.value)
            }
            dirty = true
        }
    }

    private mutating func releaseCompletedFocus(except incoming: Int?, at time: Double) {
        for index in motions.indices where index != incoming {
            // A later incoming focus event cannot release a row before its own
            // queued movement starts, or restart one that is already fading.
            if let deadline = motions[index].completedReleaseAt, deadline > time { continue }
            releaseVisualFocus(in: index, at: time)
        }
    }

    private mutating func selectVisualFocus(_ index: Int?, at time: Double) {
        releaseCompletedFocus(except: index, at: time)
        visualFocus = index
        if let index, !motions[index].mainCompleted || motions[index].mainRetirement == nil {
            motions[index].mainFocusRetained = true
        }
    }

    private mutating func layoutGroups(playing: Bool, seeking: Bool, frameStart: Double, sourcePosition: Double) {
        for index in motions.indices {
            let preparesBackground = document.groups[index].background != nil && visualFocus == index
                && !browsing && !motions[index].backgroundCompleted && motions[index].backgroundRetirement == nil
            motions[index].backgroundVisualActive = (motions[index].backgroundSinging && motions[index].backgroundRetirement == nil)
                || motions[index].backgroundFocusRetained || preparesBackground
        }
        let active = motions.map { ($0.mainSinging && $0.mainRetirement == nil) || $0.backgroundVisualActive }
        let groupHeights = document.groups.enumerated().map { index, group in
            height(group.main) + environment.fontSize * 0.8
                + (active[index] || !playing ? group.background.map { height($0) } ?? 0 : 0)
        }
        let preceding = groupHeights.prefix(timeline.focus).reduce(0, +)
        if browsing {
            // Automatic focus can advance while the user is reading. Keep
            // the browsed content stationary until the release boundary.
            scrollOffset += previousPreceding - preceding
        }
        previousPreceding = preceding
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
        var revisedPositions = false
        for index in motions.indices {
            if interlude?.anchor == index - 1 {
                y += environment.fontSize * 0.4
                interlude?.y = y
                y += environment.dotHeight + environment.fontSize * 0.4
            }
            let group = document.groups[index]
            let focused = (motions[index].mainSinging && motions[index].mainRetirement == nil) || motions[index].mainFocusRetained
                || (visualFocus == index && !browsing && !motions[index].mainCompleted && motions[index].mainRetirement == nil)
            let appearanceFocus = motions[index].mainCompleted && !motions[index].mainFocusRetained
                ? max(visualFocus ?? singingTimeline.focus, timeline.focus) : visualFocus ?? singingTimeline.focus
            motions[index].visualActive = focused
            motions[index].active = active[index]
            motions[index].opacity = environment.hidePassedLines && playing && !active[index] && !focused
                && !motions[index].mainSinging && !motions[index].backgroundSinging
                && index < (interlude.map { $0.anchor + 1 } ?? appearanceFocus)
                ? 0.0001 : (active[index] || focused ? 0.85 : (nonDynamic ? 0.2 : 1))
            var blur = 0.0
            if environment.enableBlur, !environment.reduceMotion, !browsing, !active[index] && !focused {
                blur = index < appearanceFocus
                    ? Double(2 + appearanceFocus - index) : Double(index - appearanceFocus)
                if environment.screenWidth <= 1024 {
                    blur *= 0.8
                }
            }
            let retiredBlur = environment.enableBlur && !environment.reduceMotion && !browsing
                ? Double(index <= appearanceFocus ? 2 + appearanceFocus - index : index - appearanceFocus)
                    * (environment.screenWidth <= 1024 ? 0.8 : 1) : 0
            motions[index].mainRetirement?.setBlur(retiredBlur, immediately: browsing || environment.reduceMotion)
            motions[index].backgroundRetirement?.setBlur(retiredBlur, immediately: browsing || environment.reduceMotion)
            let targetOpacity = motions[index].opacity
            motions[index].mainRetirement?.targetOpacity = targetOpacity
            motions[index].backgroundRetirement?.targetOpacity = targetOpacity
            motions[index].blur = blur
            let hiddenSlide = group.backgroundFirst && !environment.alwaysPostpositionBackground ? 80.0 : -80.0
            let slide = active[index] || !playing ? 0 : hiddenSlide
            let mainScale = !focused && environment.enableScale && (playing || visualFocus != nil) ? 97.0 : 100
            let bgFocused = motions[index].backgroundVisualActive
            let bgScale = !bgFocused && playing && environment.enableScale ? 75.0 : 100
            // Reduce Motion is a source-defined accessibility variant: it
            // keeps the AMLL geometry but resolves every transition in the
            // same frame instead of leaving opacity/blur on a stale value.
            let immediate = seeking || firstFrame || environment.reduceMotion
            let immediatePosition = immediate || browsing || positionReset
            let positionTargetChanged = motions[index].y.target != y
            if motions[index].y.target != y || motions[index].slide.target != slide {
                if !revisedPositions {
                    positionRevision &+= 1; revisedPositions = true
                }
            }
            if immediatePosition {
                motions[index].y.setPosition(y, at: frameStart)
                motions[index].slide.setPosition(slide, at: frameStart)
                motions[index].yTransition.setPosition(y)
                motions[index].slideTransition.setPosition(slide)
            }
            if immediate {
                motions[index].mainScale.setPosition(mainScale)
                motions[index].backgroundScale.setPosition(bgScale)
                motions[index].mainScaleTransition.setPosition(mainScale)
                motions[index].backgroundScaleTransition.setPosition(bgScale)
                motions[index].opacityTransition.setPosition(motions[index].opacity)
                motions[index].blurTransition.setPosition(blur)
            } else if !environment.enableSpring {
                if !immediatePosition {
                    motions[index].yTransition.setTarget(y)
                    motions[index].slideTransition.setTarget(slide)
                }
                motions[index].mainScaleTransition.setTarget(mainScale)
                motions[index].backgroundScaleTransition.setTarget(bgScale)
                if !immediatePosition {
                    motions[index].y.setPosition(y, at: frameStart)
                    motions[index].slide.setPosition(slide, at: frameStart)
                }
                motions[index].mainScale.setPosition(mainScale)
                motions[index].backgroundScale.setPosition(bgScale)
                motions[index].opacityTransition.setTarget(motions[index].opacity, duration: 0.4)
                motions[index].blurTransition.setTarget(blur, duration: 0.4)
            } else {
                if !immediatePosition {
                    motions[index].y.setTarget(y, startTime: frameStart + delay, at: frameStart, revision: positionRevision)
                    // The local background reveal shares the focus event; do not queue a second stagger.
                    motions[index].slide.setTarget(slide, startTime: frameStart, at: frameStart, revision: positionRevision)
                }
                // DomLyricLine.setTransform deliberately does not delay its scale spring.
                if motions[index].mainScale.target != mainScale {
                    motions[index].mainScale.setTarget(mainScale)
                }
                if motions[index].backgroundScale.target != bgScale {
                    motions[index].backgroundScale.setTarget(bgScale)
                }
                motions[index].yTransition.setPosition(y)
                motions[index].slideTransition.setPosition(slide)
                motions[index].mainScaleTransition.setPosition(mainScale)
                motions[index].backgroundScaleTransition.setPosition(bgScale)
                motions[index].opacityTransition.setTarget(motions[index].opacity, duration: 0.4)
                motions[index].blurTransition.setTarget(blur, duration: 0.4)
            }
            if browsing {
                motions[index].blurTransition.setPosition(0)
            }
            // A source-clock correction can restore a singing row while its
            // previous upward motion is already running. Do not consume that
            // old motion's appearance event again on an unrelated layout.
            let startsUpwardMotion = (previousInput.map { $0.position <= sourcePosition } ?? true)
                && (positionTargetChanged || (environment.enableSpring && motions[index].y.schedule.startedAt == nil))
            if seeking || browsing || positionReset {
                motions[index].completedReleaseAt = nil
            } else if index < timeline.focus, y < motions[index].y.position,
                      (motions[index].mainFocusRetained && (motions[index].mainCompleted || (startsUpwardMotion && canReleaseBeforeWordEnd(in: index, line: group.main))))
                      || (motions[index].backgroundFocusRetained && group.background.map { motions[index].backgroundCompleted || (startsUpwardMotion && canReleaseBeforeWordEnd(in: index, line: $0)) } == true),
                      motions[index].completedReleaseAt == nil
            {
                // Retire the outgoing row when its OWN upward motion starts,
                // independently of the incoming row's staggered spring deadline.
                motions[index].completedReleaseAt = environment.enableSpring
                    ? max(frameStart, motions[index].y.schedule.scheduledAt ?? frameStart) : frameStart
            }
            if !seeking, !browsing, playing, !environment.reduceMotion,
               visualFocus != nil, index == timeline.focus, visualFocus != index
            {
                pendingVisualFocus = (index: index, startTime: environment.enableSpring
                    ? (motions[index].y.schedule.scheduledAt ?? frameStart) : frameStart)
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
        positionReset = false
    }
}
