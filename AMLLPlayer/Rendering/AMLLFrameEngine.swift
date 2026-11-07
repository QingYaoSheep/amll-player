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
    var recordBlossomDiagnostics: Bool? = nil
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
    /// Absent in older replay inputs means the pinned AMLL motion path.
    var animationStyle: LyricsAnimationStyle?
    var appleMusicAnimation: LyricsBlossomAnimationOptions?
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
    var progressDraft: Double? = nil
    var seeking = false
    var awaitingSeekConfirmation = false
    var document: LyricsDocument?
    var playbackSnapshot: PlaybackSnapshot?
    var artworkURL: URL?
    var configuration: LyricsRenderConfiguration?
    var event: AMLLPlaybackEvent?

    init(position: Double, offset: Double = 0, playing: Bool, seekRevision: Int = 0, seekPosition: Double? = nil,
         seeking: Bool = false, awaitingSeekConfirmation: Bool = false, document: LyricsDocument? = nil,
         playbackSnapshot: PlaybackSnapshot? = nil, artworkURL: URL? = nil,
         configuration: LyricsRenderConfiguration? = nil, event: AMLLPlaybackEvent? = nil)
    {
        self.position = position
        self.offset = offset
        self.playing = playing
        self.seekRevision = seekRevision
        self.seekPosition = seekPosition
        self.seeking = seeking; self.awaitingSeekConfirmation = awaitingSeekConfirmation
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
    var blossomDiagnostics: String? = nil
    var transitionProgress = 1.0

    private enum CodingKeys: String, CodingKey {
        case lyricTime, animationTime, focusGroup, rows, interlude, browsing, settled, background, controls, blossomDiagnostics, transitionProgress
    }

    init(lyricTime: Double, animationTime: Double, focusGroup: Int, rows: [Row], interlude: Interlude?, browsing: Bool,
         settled: Bool, background: Background = .init(), controls: Controls = .init(), blossomDiagnostics: String? = nil, transitionProgress: Double = 1)
    {
        self.lyricTime = lyricTime; self.animationTime = animationTime; self.focusGroup = focusGroup
        self.rows = rows; self.interlude = interlude; self.browsing = browsing; self.settled = settled
        self.blossomDiagnostics = blossomDiagnostics
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
        blossomDiagnostics = try values.decodeIfPresent(String.self, forKey: .blossomDiagnostics)
        transitionProgress = try values.decodeIfPresent(Double.self, forKey: .transitionProgress) ?? 1
    }
}

/// Deterministic native host for the pinned timeline/group/layout/scroll algorithms.
/// It owns one spring per group/transform, independent of visibility and view recycling.
struct AMLLFrameEngine {
    let runStore = LyricsBlossomRunStore()
    private let blossomRecords: [LyricsBlossomSelectionSchedule.Record]
    private let blossomOrdinaryRecords: [LyricsBlossomSelectionSchedule.Record]
    private let blossomTimedRows: Set<Int>
    private var blossomSelector = LyricsBlossomSelectionSchedule()
    private var blossomNeedsRebase = true
    private(set) var blossomSchedule: LyricsBlossomSelectionSchedule.Output?

    private struct GroupMotion {
        var y = AMLLScheduledSpring()
        var slide = AMLLScheduledSpring(-80)
        var mainScale = LyricsAnimationSpring(100)
        var mainScaleParameters = AMLLSpringParameters.scale
        var backgroundScale = LyricsAnimationSpring(100)
        var mainScaleWait: LyricsBlossomScaleWait?
        var backgroundScaleWait: LyricsBlossomScaleWait?
        var yTransition = AMLLSourceTransition()
        var slideTransition = AMLLSourceTransition(-80)
        var mainScaleTransition = AMLLSourceTransition(100)
        var backgroundScaleTransition = AMLLSourceTransition(100)
        var opacityTransition = AMLLSourceTransition(1)
        var blurTransition = AMLLSourceTransition()
        var mainAlpha = AMLLMaskAlpha()
        var backgroundAlpha = AMLLMaskAlpha()
        var mainLightUp = LyricsBlossomFocusAlpha()
        var backgroundLightUp = LyricsBlossomFocusAlpha()
        var backgroundReady = false
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
        var blossomCommands: [LyricsBlossomSelectionSchedule.Channel: Int] = [:]

        mutating func configureSelectionCompletion(_ enabled: Bool) {
            y.requireAccelerationAtRest = enabled
            mainScale.requireAccelerationAtRest = enabled
            backgroundScale.requireAccelerationAtRest = enabled
            mainLightUp.requireAccelerationAtRest = enabled
            backgroundLightUp.requireAccelerationAtRest = enabled
            yTransition.requiresDuration = enabled
            mainScaleTransition.requiresDuration = enabled
            backgroundScaleTransition.requiresDuration = enabled
            opacityTransition.requiresDuration = enabled
        }

        mutating func advanceScales(delta: Double, endingAt end: Double) {
            LyricsBlossomScaleWait.advance(&mainScale, pending: &mainScaleWait, delta: delta, endingAt: end)
            LyricsBlossomScaleWait.advance(&backgroundScale, pending: &backgroundScaleWait, delta: delta, endingAt: end)
        }

        mutating func targetScales(main: Double, background: Double, at time: Double, delay: Double) {
            LyricsBlossomScaleWait.retarget(&mainScale, pending: &mainScaleWait, target: main, at: time, delay: delay)
            LyricsBlossomScaleWait.retarget(&backgroundScale, pending: &backgroundScaleWait, target: background, at: time, delay: delay)
        }
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

    private static func selectionRecords(_ document: AMLLDisplayDocument, associatedStarts: Bool)
        -> [LyricsBlossomSelectionSchedule.Record] {
        var records: [LyricsBlossomSelectionSchedule.Record] = []
        var previousEnd = 0.0
        for (index, group) in document.groups.enumerated() {
            let main = group.main
            guard !document.sourceBackgroundFlags[main] else { continue }
            let start = document.sourceLineStarts[main], end = document.sourceLineEnds[main]
            guard start.isFinite, end.isFinite else { continue }
            if Float(start - previousEnd) > 7 {
                records.append(.init(index: document.groups.count + index,
                    start: Double(Float(previousEnd + 0.5)), end: start, lastWordEnd: start, interlude: true))
            }
            let associatedStart = group.background.map {
                min(document.sourceLineStarts[$0], document.lines[$0].words.map(\.start).min() ?? start)
            } ?? start
            records.append(.init(index: index, start: associatedStarts ? min(start, associatedStart) : start,
                end: end, lastWordEnd: document.lines[main].words.last?.end ?? end, sourceStart: start))
            previousEnd = end
        }
        return records
    }

    private func blossomGroup(for key: Int) -> Int {
        document.groups.indices.contains(key) ? key : max(0, key - document.groups.count - 1)
    }

    private func blossomRows(_ keys: [Int]) -> Set<Int> {
        Set(keys.flatMap { key -> [Int] in
            guard document.groups.indices.contains(key) else { return [] }
            let group = document.groups[key]
            return [group.main] + (group.background.map { [$0] } ?? [])
        })
    }

    private func pendingBlossomTickets() -> Set<LyricsBlossomSelectionSchedule.Ticket> {
        var pending: Set<LyricsBlossomSelectionSchedule.Ticket> = []
        guard !environment.reduceMotion, !browsing else { return pending }
        for (index, motion) in motions.enumerated() {
            for (channel, generation) in motion.blossomCommands {
                let running = switch channel {
                case .position: environment.enableSpring ? !motion.y.arrived : !motion.yTransition.arrived
                case .scale: environment.enableSpring
                    ? motion.mainScaleWait != nil || motion.backgroundScaleWait != nil
                        || !motion.mainScale.arrived || !motion.backgroundScale.arrived
                    : !motion.mainScaleTransition.arrived || !motion.backgroundScaleTransition.arrived
                case .light: !motion.mainLightUp.arrived || !motion.backgroundLightUp.arrived
                case .opacity: !motion.opacityTransition.arrived
                        || motion.mainRetirement?.arrived == false || motion.backgroundRetirement?.arrived == false
                }
                if running { pending.insert(.init(row: index, channel: channel, generation: generation)) }
            }
        }
        return pending
    }

    init(document: AMLLDisplayDocument, environment: AMLLRenderEnvironment, heights: [Double]) {
        self.document = document
        blossomRecords = Self.selectionRecords(document, associatedStarts: true)
        blossomOrdinaryRecords = Self.selectionRecords(document, associatedStarts: false)
        blossomTimedRows = Set(document.lines.indices.filter { index in
            let line = document.lines[index]
            guard line.precision == .word, let first = line.words.first else { return false }
            return !first.text.isEmpty && first.start.isFinite && first.end.isFinite
        })
        self.environment = environment
        self.heights = heights
        motions = document.groups.map { group in
            var motion = GroupMotion()
            let style = environment.animationStyle ?? .amll
            motion.configureSelectionCompletion(style == .appleMusic164
                && LyricsBlossomSelectionSchedule.supported((environment.appleMusicAnimation ?? .init()).selectionFamily))
            motion.y.selectStyle(style); motion.slide.selectStyle(style)
            motion.mainScale.selectStyle(style); motion.backgroundScale.selectStyle(style)
            motion.y.setPosition(environment.height * 2)
            if group.backgroundFirst {
                motion.slide.setPosition(80)
            }
            let motionStyle = LyricsAnimationMotion(style: environment.animationStyle ?? .amll)
            motion.y.updateParameters(motionStyle.initialVertical.sourceParameters)
            motion.slide.updateParameters(motionStyle.initialVertical.sourceParameters)
            motion.mainScale.updateParameters(motionStyle.mainScale.sourceParameters)
            motion.mainScaleParameters = motionStyle.mainScale
            motion.backgroundScale.updateParameters(motionStyle.backgroundScale.sourceParameters)
            return motion
        }
    }

    mutating func resize(environment: AMLLRenderEnvironment, heights: [Double]) {
        guard self.environment != environment || self.heights != heights else { return }
        if self.environment.animationStyle != environment.animationStyle
            || self.environment.appleMusicAnimation != environment.appleMusicAnimation {
            runStore.reset()
            blossomNeedsRebase = true
        }
        if self.environment.enableSpring != environment.enableSpring
            || self.environment.reduceMotion != environment.reduceMotion {
            blossomSelector.invalidateTickets()
        }
        if self.environment.enableSpring != environment.enableSpring,
           !self.environment.reduceMotion, !environment.reduceMotion {
            for index in motions.indices {
                if environment.enableSpring {
                    let y = motions[index].yTransition, slide = motions[index].slideTransition
                    let main = motions[index].mainScaleTransition, background = motions[index].backgroundScaleTransition
                    let mainTarget = motions[index].mainScale.target, backgroundTarget = motions[index].backgroundScale.target
                    motions[index].y.resume(position: y.value, velocity: y.velocity, at: animationTime)
                    motions[index].slide.resume(position: slide.value, velocity: slide.velocity, at: animationTime)
                    motions[index].mainScale.resume(position: main.value, velocity: main.velocity, target: mainTarget)
                    motions[index].backgroundScale.resume(position: background.value, velocity: background.velocity, target: backgroundTarget)
                } else {
                    let y = motions[index].y, slide = motions[index].slide
                    let main = motions[index].mainScale, background = motions[index].backgroundScale
                    motions[index].yTransition.setPosition(y.position)
                    motions[index].yTransition.setTarget(y.target, initialVelocity: y.velocity)
                    motions[index].slideTransition.setPosition(slide.position)
                    motions[index].slideTransition.setTarget(slide.target, initialVelocity: slide.velocity)
                    motions[index].mainScaleTransition.setPosition(main.position)
                    motions[index].mainScaleTransition.setTarget(main.target, initialVelocity: main.velocity)
                    motions[index].backgroundScaleTransition.setPosition(background.position)
                    motions[index].backgroundScaleTransition.setTarget(background.target, initialVelocity: background.velocity)
                }
            }
        }
        if (self.environment.animationStyle ?? .amll) != (environment.animationStyle ?? .amll)
            || self.environment.appleMusicAnimation != environment.appleMusicAnimation {
            let policy = LyricsAnimationMotion(style: environment.animationStyle ?? .amll, options: environment.appleMusicAnimation)
            let interval = timeline.focus > 0 && timeline.focus < document.timings.count
                ? (document.timings[timeline.focus].startTime - document.timings[timeline.focus - 1].startTime) / 1000 : nil
            let vertical = policy.vertical(lineInterval: interval, gap: sourceGap(at: timeline.focus), seeking: false, interlude: interlude != nil)
            for index in motions.indices {
                // Parameter changes retain the solver's presented position, velocity,
                // queued position deadline, lyric clocks and focus/retirement events.
                let style = environment.animationStyle ?? .amll
                motions[index].configureSelectionCompletion(style == .appleMusic164
                    && LyricsBlossomSelectionSchedule.supported((environment.appleMusicAnimation ?? .init()).selectionFamily))
                motions[index].mainScaleWait = nil
                motions[index].backgroundScaleWait = nil
                if (self.environment.animationStyle ?? .amll) != style {
                    if style == .appleMusic164 {
                        motions[index].mainLightUp.resume(bright: motions[index].mainAlpha.bright, dark: motions[index].mainAlpha.dark)
                        motions[index].backgroundLightUp.resume(bright: motions[index].backgroundAlpha.bright, dark: motions[index].backgroundAlpha.dark)
                    } else {
                        let main = motions[index].mainLightUp.value, background = motions[index].backgroundLightUp.value
                        motions[index].mainAlpha.resume(bright: main.bright, dark: main.dark)
                        motions[index].backgroundAlpha.resume(bright: background.bright, dark: background.dark)
                    }
                }
                motions[index].y.selectStyle(style); motions[index].slide.selectStyle(style)
                motions[index].mainScale.selectStyle(style); motions[index].backgroundScale.selectStyle(style)
                motions[index].backgroundScale.updateParameters(policy.backgroundScale.sourceParameters)
                motions[index].y.updateParameters(vertical.sourceParameters)
                motions[index].slide.updateParameters(vertical.sourceParameters)
                let scale = policy.mainScale(focused: motions[index].visualActive)
                if motions[index].mainScaleParameters != scale {
                    motions[index].mainScale.updateParameters(scale.sourceParameters)
                    motions[index].mainScaleParameters = scale
                }
            }
        }
        positionReset = self.environment.width != environment.width || self.environment.height != environment.height
            || self.heights != heights
        if positionReset { blossomNeedsRebase = true }
        self.environment = environment; self.heights = heights; dirty = true
    }

    mutating func handle(_ interaction: AMLLInteraction) {
        switch interaction {
        case .beginBrowsing:
            touching = true; browsing = true; scrollVelocity = 0
            blossomSelector.invalidateTickets()
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
        // Keep the exact committed boundary. Reconstructing it as (time + dt)
        // - dt can round backwards and make a scheduled spring reject the frame.
        var frameStart = animationTime
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
        // A request can precede the player's new clock. Preserve the browsed
        // presentation until confirmation, then reset time once and animate
        // the position independently. Never first return to the old focus.
        let seeking = firstFrame || (!input.awaitingSeekConfirmation && ((seekRequested && pendingSeek == nil) || seekArrived))
        if seeking {
            timeAnchorRevision &+= 1
            handle(.resumeFollowing)
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
        if browsing, !touching, input.playing, pendingSeek == nil, !input.awaitingSeekConfirmation, let start = resumeAtLineStart, time / 1000 >= start {
            handle(.resumeFollowing)
        }
        let oldFocus = timeline.focus
        let appleStyle = environment.animationStyle == .appleMusic164
        let options = environment.appleMusicAnimation ?? .init()
        let family = options.selectionFamily
        let usesBlossomSelector = appleStyle && LyricsBlossomSelectionSchedule.supported(family)
        var layout = timeline.update(time: time + (appleStyle ? 0 : environment.advance * 1000),
                                     groups: appleStyle ? document.singingTimings : document.timings,
                                     seeking: seeking, hasBottomContent: false)
        if usesBlossomSelector {
            // Consume old channel motion before checking its tickets. A newly
            // installed transition starts at this frame's boundary.
            if !input.playing, previousInput?.playing == true {
                for index in motions.indices {
                    motions[index].y.clearPendingDelay(at: frameStart)
                    motions[index].slide.clearPendingDelay(at: frameStart)
                }
            }
            advanceAppearance(delta: elapsed, forceAlpha: false, endingAt: animationTime)
            for index in motions.indices {
                motions[index].y.advance(to: animationTime)
                motions[index].slide.advance(to: animationTime)
            }
            frameStart = animationTime
            let lyricTime = time / 1000
            let rebased = seeking || blossomNeedsRebase || previousInput?.offset != input.offset
                || (previousInput?.progressDraft != nil && input.progressDraft == nil)
            let records = family == 3 ? blossomRecords : blossomOrdinaryRecords
            let capacity = options.maximumLines
            if rebased {
                let target = timeline.focus
                let visible = motions.indices.contains(target) && motions[target].y.position < environment.height
                    && motions[target].y.position + height(document.groups[target].main) > 0
                blossomSelector.rebase(records: records, now: lyricTime, capacity: capacity,
                    bypassClock: !seeking || firstFrame || !visible || input.progressDraft != nil)
                pendingVisualFocus = nil
                for index in motions.indices { motions[index].completedReleaseAt = nil }
                for key in blossomSelector.state.selected where document.groups.indices.contains(key) {
                    motions[key].mainRetirement = nil
                    motions[key].backgroundRetirement = nil
                }
                blossomNeedsRebase = false
                dirty = true
            }
            runStore.beginFrame(.init(time: lyricTime, delta: elapsed,
                playing: input.playing && !input.awaitingSeekConfirmation,
                revision: timeAnchorRevision, family: family, offset: input.offset,
                draftTime: input.progressDraft.map { $0 - input.offset },
                selectedRows: blossomRows(blossomSelector.state.selected), rebase: rebased))
            // Snapshot pending commands before mutating the scheduler so the
            // completion query cannot overlap an inout access to this engine.
            let pendingTickets = pendingBlossomTickets()
            let schedule = blossomSelector.update(family: family, now: lyricTime, wall: animationTime,
                records: records, capacity: capacity, running: input.playing && !songEnded
                    && !input.awaitingSeekConfirmation && input.progressDraft == nil,
                rebased: rebased, browsing: browsing, isPending: pendingTickets.contains)
            if schedule.takeover != blossomSchedule?.takeover || schedule.kind != .none { dirty = true }
            blossomSchedule = schedule
            let catchUp = Set(schedule.catchUp.compactMap { key in
                document.groups.indices.contains(key) ? document.groups[key].main : nil
            }).intersection(blossomTimedRows)
            runStore.applySelection(entered: blossomRows(schedule.entered), left: blossomRows(schedule.left), catchUp: catchUp)
            if let key = schedule.selected.last {
                let focus = blossomGroup(for: key)
                layout = timeline.selectFocus(focus) || layout
            }
        } else {
            blossomSchedule = nil
        }
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
            if beganSinging, !seeking, !usesBlossomSelector || browsing, browsing || visualFocus == timeline.focus {
                releaseCompletedFocus(except: index, at: frameStart)
            }
            if mainSinging, motions[index].mainRetirement == nil, !usesBlossomSelector || browsing {
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
                if environment.animationStyle == .appleMusic164 {
                    let ready = input.playing && time / 1000 >= backgroundStart
                    if ready != motions[index].backgroundReady { dirty = true }
                    motions[index].backgroundReady = ready
                }
                let backgroundSinging = backgroundStart <= time / 1000 && time / 1000 < document.actualLineEnds[background]
                if backgroundSinging != motions[index].backgroundSinging {
                    dirty = true
                }
                let beganBackground = backgroundSinging && !motions[index].backgroundSinging
                motions[index].backgroundSinging = backgroundSinging
                if beganBackground, !seeking, !usesBlossomSelector || browsing, browsing || visualFocus == timeline.focus {
                    releaseCompletedFocus(except: index, at: frameStart)
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
        } else if usesBlossomSelector && !browsing {
            if let schedule = blossomSchedule {
                for key in schedule.left where document.groups.indices.contains(key) {
                    releaseVisualFocus(in: key, at: frameStart, selectionExit: true)
                }
                for key in schedule.entered where document.groups.indices.contains(key) {
                    motions[key].mainRetirement = nil
                    motions[key].backgroundRetirement = nil
                }
                let selected = Set(schedule.selected)
                for index in motions.indices {
                    motions[index].mainFocusRetained = selected.contains(index)
                    motions[index].backgroundFocusRetained = selected.contains(index) && motions[index].backgroundSinging
                }
                visualFocus = schedule.selected.last.flatMap { document.groups.indices.contains($0) ? $0 : nil }
            }
        } else if (visualFocus == nil && !releasedForInterlude) || seeking || (releasedForInterlude && changedInterlude) {
            selectVisualFocus(document.groups.indices.contains(timeline.focus) ? timeline.focus : nil, at: frameStart)
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
        if !usesBlossomSelector, !songEnded, !browsing, interlude == nil, pendingVisualFocus == nil,
           visualFocus != timeline.focus, environment.reduceMotion || !input.playing
        {
            selectVisualFocus(document.groups.indices.contains(timeline.focus) ? timeline.focus : nil, at: frameStart)
        }
        let pendingScale = environment.animationStyle == .appleMusic164
            && motions.contains { $0.mainScaleWait != nil || $0.backgroundScaleWait != nil }
        if dirty || layout || singingLayout || changedInterlude || previousInput?.playing != input.playing || pendingScale {
            if oldFocus != timeline.focus || changedInterlude {
                let interval = timeline.focus > 0 && timeline.focus < document.timings.count
                    ? (document.timings[timeline.focus].startTime - document.timings[timeline.focus - 1].startTime) / 1000 : nil
                if seeking || interlude != nil || interval != nil {
                    let p = LyricsAnimationMotion(style: environment.animationStyle ?? .amll)
                        .vertical(lineInterval: interval, gap: sourceGap(at: timeline.focus), seeking: seeking, interlude: interlude != nil)
                    for index in motions.indices {
                        motions[index].y.updateParameters(.init(mass: p.mass, damping: p.damping, stiffness: p.stiffness))
                        motions[index].slide.updateParameters(.init(mass: p.mass, damping: p.damping, stiffness: p.stiffness))
                    }
                }
            }
            layoutGroups(playing: input.playing, seeking: seeking, frameStart: frameStart,
                         sourcePosition: input.position, lyricTime: time / 1000)
            dirty = false
        }
        let forceAlpha = seeking || firstFrame || environment.reduceMotion
        var appearanceTime = frameStart
        while !browsing {
            var nextEvent = pendingVisualFocus?.startTime
            for motion in motions {
                if let deadline = motion.completedReleaseAt, deadline < (nextEvent ?? .infinity) {
                    nextEvent = deadline
                }
            }
            guard let nextEvent, nextEvent <= animationTime else { break }
            let boundary = max(appearanceTime, nextEvent)
            advanceAppearance(delta: boundary - appearanceTime, forceAlpha: forceAlpha, endingAt: boundary)
            for index in motions.indices {
                if let deadline = motions[index].completedReleaseAt, deadline <= boundary {
                    releaseVisualFocus(in: index, at: boundary, allowEarly: true)
                }
            }
            if let pending = pendingVisualFocus, pending.startTime <= boundary {
                selectVisualFocus(pending.index, at: boundary)
                pendingVisualFocus = nil
            }
            layoutGroups(playing: input.playing, seeking: false, frameStart: boundary,
                         sourcePosition: input.position, lyricTime: time / 1000)
            dirty = false
            appearanceTime = boundary
        }
        advanceAppearance(delta: animationTime - appearanceTime, forceAlpha: forceAlpha, endingAt: animationTime)
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
            let mainAlpha = environment.animationStyle == .appleMusic164 ? motion.mainLightUp.value : (motion.mainAlpha.bright, motion.mainAlpha.dark)
            let backgroundAlpha = environment.animationStyle == .appleMusic164 ? motion.backgroundLightUp.value : (motion.backgroundAlpha.bright, motion.backgroundAlpha.dark)
            let padding = environment.fontSize * 0.4
            let progress = min(1, max(0, 1 - abs(slidePosition) / 80))
            let bgFirst = group.backgroundFirst && !environment.alwaysPostpositionBackground
            let bgHeight = group.background.map(height) ?? 0
            let backgroundVisible = motion.active || !input.playing || !(motion.backgroundRetirement?.arrived ?? true)
            let bgAdvance = bgFirst ? bgHeight * progress : 0
            let y = (yPosition * 10).rounded() / 10
            rows.append(.init(lineIndex: group.main, groupIndex: index, y: y + padding + bgAdvance,
                              scale: mainScalePosition / 100, brightAlpha: mainExit?.bright ?? mainAlpha.0,
                              darkAlpha: mainExit?.dark ?? mainAlpha.1, wordClock: motion.mainWords,
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
                                  brightAlpha: backgroundExit?.bright ?? backgroundAlpha.0, darkAlpha: backgroundExit?.dark ?? backgroundAlpha.1,
                                  wordClock: motion.backgroundWords,
                                  opacity: motion.opacityTransition.value * (backgroundVisible ? 1 : 0),
                                  blur: backgroundExit?.blur ?? min(5, motion.blurTransition.value),
                                  active: motion.backgroundSinging, hidden: !motion.active && progress == 0 && (motion.backgroundRetirement?.arrived ?? true),
                                  visualFocus: backgroundState, fillComplete: motion.backgroundCompleted,
                                  hdrHold: backgroundState == .holding && !songEnded && interlude == nil,
                                  positionMotion: motion.y.schedule, retirement: backgroundExit?.state))
            }
            if environment.animationStyle == .appleMusic164 {
                allSettled = allSettled && motion.mainLightUp.arrived && motion.backgroundLightUp.arrived
                    && motion.mainScaleWait == nil && motion.backgroundScaleWait == nil
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
        if appleStyle && !usesBlossomSelector {
            runStore.beginFrame(.init(time: time / 1000, delta: elapsed,
                playing: input.playing && !input.awaitingSeekConfirmation,
                revision: timeAnchorRevision, family: options.selectionFamily, offset: input.offset,
                draftTime: input.progressDraft.map { $0 - input.offset }))
        } else if !appleStyle, previousInput?.configuration?.animationStyle == .appleMusic164 { runStore.reset() }
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
            blossomDiagnostics: appleStyle ? blossomSchedule.map {
                "\($0.diagnostic); selected=\($0.selected); pending=\(String(describing: $0.pending)); takeover=\($0.takeover); dispatches=\(runStore.dispatchCount); armed=\(runStore.armCount); \(environment.recordBlossomDiagnostics == true ? runStore.diagnostic : "cursor recording off")"
            } ?? "family=\(family) native compatibility" : nil,
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

    /// Source timings are separate from advance-adjusted scroll scheduling.
    private func sourceGap(at index: Int) -> Double? {
        guard index > 0, document.groups.indices.contains(index) else { return nil }
        let line = document.groups[index].main, previous = document.groups[index - 1].main
        return document.actualLineStarts[line] - document.actualLineEnds[previous]
    }

    private mutating func advanceAppearance(delta elapsed: Double, forceAlpha: Bool, endingAt end: Double) {
        guard elapsed > 0 || forceAlpha else { return }
        for index in motions.indices {
            if environment.enableSpring, !environment.reduceMotion {
                motions[index].advanceScales(delta: elapsed, endingAt: end)
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
            if environment.animationStyle == .appleMusic164 {
                motions[index].mainLightUp.update(focused: motions[index].visualActive, delta: elapsed, force: forceAlpha)
                motions[index].backgroundLightUp.update(focused: motions[index].backgroundVisualActive, delta: elapsed, force: forceAlpha)
            }
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

    private mutating func releaseVisualFocus(in index: Int, at time: Double, allowEarly: Bool = false,
                                             selectionExit: Bool = false) {
        motions[index].completedReleaseAt = nil
        let group = document.groups[index]
        let releaseMainAhead = selectionExit || (allowEarly && canReleaseBeforeWordEnd(in: index, line: group.main))
        let releaseBackgroundAhead = selectionExit
            || (allowEarly && (group.background.map { canReleaseBeforeWordEnd(in: index, line: $0) } ?? false))
        if !motions[index].mainSinging || releaseMainAhead, motions[index].mainFocusRetained {
            motions[index].mainFocusRetained = false
            if motions[index].mainCompleted || releaseMainAhead, motions[index].mainRetirement == nil {
                motions[index].mainRetirement = .init(at: time,
                    bright: environment.animationStyle == .appleMusic164 ? motions[index].mainLightUp.value.bright : motions[index].mainAlpha.bright,
                    dark: environment.animationStyle == .appleMusic164 ? motions[index].mainLightUp.value.dark : motions[index].mainAlpha.dark,
                    opacity: motions[index].opacityTransition.value, blur: motions[index].blurTransition.value)
            }
            dirty = true
        }
        if !motions[index].backgroundSinging || releaseBackgroundAhead, motions[index].backgroundFocusRetained {
            motions[index].backgroundFocusRetained = false
            if motions[index].backgroundCompleted || releaseBackgroundAhead, motions[index].backgroundRetirement == nil {
                motions[index].backgroundRetirement = .init(at: time,
                    bright: environment.animationStyle == .appleMusic164 ? motions[index].backgroundLightUp.value.bright : motions[index].backgroundAlpha.bright,
                    dark: environment.animationStyle == .appleMusic164 ? motions[index].backgroundLightUp.value.dark : motions[index].backgroundAlpha.dark,
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

    private mutating func layoutGroups(playing: Bool, seeking: Bool, frameStart: Double, sourcePosition: Double, lyricTime: Double) {
        let blossom = environment.animationStyle == .appleMusic164 ? (environment.appleMusicAnimation ?? .init()) : nil
        let sourceSelection = blossomSchedule.map { Set($0.selected) }
        for index in motions.indices {
            let preparesBackground = document.groups[index].background != nil && visualFocus == index
                && !browsing && !motions[index].backgroundCompleted && motions[index].backgroundRetirement == nil
                && (blossom == nil || blossom?.background == 1)
                && (environment.animationStyle != .appleMusic164 || motions[index].backgroundReady)
            motions[index].backgroundVisualActive = (motions[index].backgroundSinging && motions[index].backgroundRetirement == nil)
                || motions[index].backgroundFocusRetained || preparesBackground
        }
        let active = motions.map { ($0.mainSinging && $0.mainRetirement == nil) || $0.backgroundVisualActive }
        let selectedSinging: Set<Int>? = if let blossom, blossom.limitsSelection {
            Set(motions.indices.filter { motions[$0].mainSinging }.prefix(blossom.maximumLines))
        } else { nil }
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
        let clearsBlossomDelay = environment.animationStyle == .appleMusic164
            && LyricsBlossomLineSchedule.clearsDelay(wordVersion: blossom?.word ?? 0,
                                                    paused: !playing, hidden: false, advanceSatisfied: false)
        var delay = 0.0, baseDelay = touching || clearsBlossomDelay ? 0 : LyricsBlossomLineSchedule.step
        // Native selected voices supply real row-end times. The predicate only
        // clears the scale wait; it cannot seek or force a word to be filled.
        let selected = blossomSchedule?.selected.filter { document.groups.indices.contains($0) }
            ?? motions.indices.filter { motions[$0].mainSinging && selectedSinging?.contains($0) != false }
        let advanceClearsScale = blossomSchedule?.takeover ?? false
        let nonDynamic = !document.lines.contains { $0.precision == .word }
        var revisedPositions = false
        for index in motions.indices {
            let oldVisual = motions[index].visualActive
            let oldY = motions[index].y.target
            let oldScale = motions[index].mainScaleWait?.target ?? motions[index].mainScale.target
            let oldBackgroundScale = motions[index].backgroundScaleWait?.target ?? motions[index].backgroundScale.target
            let oldOpacity = motions[index].opacityTransition.target
            if clearsBlossomDelay {
                if motions[index].y.clearPendingDelay(at: frameStart) {
                    if pendingVisualFocus?.index == index { pendingVisualFocus?.startTime = frameStart }
                    if motions[index].completedReleaseAt != nil { motions[index].completedReleaseAt = frameStart }
                }
                motions[index].slide.clearPendingDelay(at: frameStart)
            }
            if interlude?.anchor == index - 1 {
                y += environment.fontSize * 0.4
                interlude?.y = y
                y += environment.dotHeight + environment.fontSize * 0.4
            }
            let group = document.groups[index]
            let allowsSingingFocus = !motions[index].mainSinging || selectedSinging?.contains(index) != false
            let focused = if let sourceSelection, !browsing {
                sourceSelection.contains(index) && interlude == nil && motions[index].mainRetirement == nil
            } else {
                allowsSingingFocus && ((motions[index].mainSinging && motions[index].mainRetirement == nil)
                    || motions[index].mainFocusRetained || (visualFocus == index && !browsing
                        && !motions[index].mainCompleted && motions[index].mainRetirement == nil))
            }
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
            let suppressInactiveScale = blossom?.word == 2
            let inactiveScale = environment.animationStyle == .appleMusic164 ? 98.0 : 97.0
            let mainScale = !focused && environment.enableScale && !suppressInactiveScale && (playing || visualFocus != nil) ? inactiveScale : 100
            let bgFocused = motions[index].backgroundVisualActive
            let bgScale = !bgFocused && playing && environment.enableScale ? 75.0 : 100
            // Reduce Motion is a source-defined accessibility variant: it
            // keeps the AMLL geometry but resolves every transition in the
            // same frame instead of leaving opacity/blur on a stale value.
            // Seeking invalidates lyric clocks and masks, but the spatial handoff
            // follows the same spring as Return to Current. Only initial layout
            // and the existing accessibility variant position immediately.
            let immediate = firstFrame || environment.reduceMotion
            let scaleDelay: Double = if let blossom, !seeking, !browsing,
                !LyricsBlossomLineSchedule.clearsDelay(wordVersion: blossom.word, paused: !playing,
                    hidden: false, advanceSatisfied: advanceClearsScale) {
                blossom.selectionFamily == 3
                    ? LyricsBlossomLineSchedule.multiLineDelay(rank: selected.firstIndex(of: index) ?? 0)
                    : Double(max(0, index - (selected.last ?? timeline.focus) - 1)) * LyricsBlossomLineSchedule.step
            } else { 0 }
            if environment.animationStyle == .appleMusic164 {
                let parameters = LyricsAnimationMotion(style: .appleMusic164, options: blossom).mainScale(focused: focused)
                if motions[index].mainScaleParameters != parameters {
                    motions[index].mainScale.updateParameters(parameters.sourceParameters)
                    motions[index].mainScaleParameters = parameters
                }
            }
            let immediatePosition = immediate || browsing || positionReset
            let positionTargetChanged = motions[index].y.target != y
            let presentedY = environment.enableSpring && !environment.reduceMotion
                ? motions[index].y.position : motions[index].yTransition.value
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
                motions[index].mainScaleWait = nil
                motions[index].backgroundScaleWait = nil
                motions[index].mainScale.setPosition(mainScale)
                motions[index].backgroundScale.setPosition(bgScale)
                motions[index].mainScaleTransition.setPosition(mainScale)
                motions[index].backgroundScaleTransition.setPosition(bgScale)
                motions[index].opacityTransition.setPosition(motions[index].opacity)
                motions[index].blurTransition.setPosition(blur)
            } else if !environment.enableSpring {
                motions[index].mainScaleWait = nil
                motions[index].backgroundScaleWait = nil
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
                // AMLL still uses zero scale delay. Blossom's 50ms scheduler
                // belongs to this transform channel, independently of native Y.
                motions[index].targetScales(main: mainScale, background: bgScale, at: frameStart, delay: scaleDelay)
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
            if let blossom, let schedule = blossomSchedule {
                var changed: [LyricsBlossomSelectionSchedule.Channel] = []
                if oldY != y { changed.append(.position) }
                if oldScale != mainScale || oldBackgroundScale != bgScale { changed.append(.scale) }
                if oldVisual != focused {
                    motions[index].mainLightUp.setFocused(focused, immediately: immediate)
                    changed.append(.light)
                }
                if oldOpacity != motions[index].opacityTransition.target { changed.append(.opacity) }
                for channel in changed {
                    motions[index].blossomCommands[channel, default: 0] &+= 1
                    // The command producer arms only target-list rows. A
                    // direct layout has no transition to hold.
                    if !immediatePosition, !seeking, schedule.selected.contains(index),
                       (blossom.selectionFamily != 3 || schedule.entered.contains(index)),
                       channel != .position || positionTargetChanged,
                       let generation = motions[index].blossomCommands[channel] {
                        blossomSelector.installed(.init(row: index, channel: channel, generation: generation),
                            family: blossom.selectionFamily, kind: schedule.kind)
                    }
                }
            }
            // A source-clock correction can restore a singing row while its
            // previous upward motion is already running. Do not consume that
            // old motion's appearance event again on an unrelated layout.
            let startsUpwardMotion = (previousInput.map { $0.position <= sourcePosition } ?? true)
                && (positionTargetChanged || (environment.enableSpring && motions[index].y.schedule.startedAt == nil))
            if sourceSelection != nil || seeking || browsing || positionReset {
                motions[index].completedReleaseAt = nil
            } else if index < timeline.focus, y < presentedY,
                      (motions[index].mainFocusRetained && (motions[index].mainCompleted || (startsUpwardMotion && canReleaseBeforeWordEnd(in: index, line: group.main))))
                      || (motions[index].backgroundFocusRetained && group.background.map { motions[index].backgroundCompleted || (startsUpwardMotion && canReleaseBeforeWordEnd(in: index, line: $0)) } == true),
                      motions[index].completedReleaseAt == nil
            {
                // Retire the outgoing row when its OWN upward motion starts,
                // independently of the incoming row's staggered spring deadline.
                motions[index].completedReleaseAt = environment.enableSpring
                    ? max(frameStart, motions[index].y.schedule.scheduledAt ?? frameStart) : frameStart
            }
            if sourceSelection == nil, !seeking, !browsing, playing, !environment.reduceMotion,
               visualFocus != nil, index == timeline.focus, visualFocus != index
            {
                pendingVisualFocus = (index: index, startTime: environment.enableSpring
                    ? (motions[index].y.schedule.scheduledAt ?? frameStart) : frameStart)
            }
            y += groupHeights[index]
            // Animated seeks use the same row stagger as Return to Current.
            // Immediate initial/accessibility layouts ignore these deadlines.
            if y >= 0 {
                delay += baseDelay
                if index >= timeline.focus {
                    if environment.animationStyle != .appleMusic164 { baseDelay /= 1.05 }
                }
            }
        }
        scrollMaximum = max(scrollMinimum, y + scrollOffset - environment.height / 2)
        positionReset = false
    }
}
