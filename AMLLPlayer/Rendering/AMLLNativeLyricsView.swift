import CoreImage
import CryptoKit
import SwiftUI
import UIKit

/// Native AMLL lyric canvas used by the real lyric page and the deterministic
/// Debug preview. The legacy renderer remains available as a comparison path.
struct AMLLNativeLyricsView: UIViewRepresentable {
    var document: LyricsDocument
    var documentVersion: Int? = nil
    var configuration: LyricsRenderConfiguration
    var input: AMLLPlayerInput
    var position: () -> Double
    var interaction: (AMLLInteraction) -> Void
    var canSeek = true
    var active = true
    var targetFPS = 120
    var resumeToken = 0
    var fadeTop: CGFloat?
    var created: (AMLLNativeCanvas) -> Void = { _ in }
    var browsing: (Bool) -> Void = { _ in }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func makeUIView(context _: Context) -> AMLLNativeCanvas {
        let view = AMLLNativeCanvas()
        DispatchQueue.main.async { created(view) }
        return view
    }

    func updateUIView(_ view: AMLLNativeCanvas, context _: Context) {
        view.position = position
        view.onInteraction = interaction
        view.onBrowsing = browsing
        view.fadeTop = fadeTop
        view.setFrameRate(targetFPS)
        view.configure(document: document, documentVersion: documentVersion, configuration: configuration, input: input, active: active,
                       reduceMotion: reduceMotion, reduceTransparency: reduceTransparency, canSeek: canSeek)
        view.resumeFollowing(token: resumeToken)
    }

    static func dismantleUIView(_ view: AMLLNativeCanvas, coordinator _: ()) {
        view.stop()
    }
}

@MainActor
final class AMLLNativeCanvas: UIView {
    var fadeTop: CGFloat? {
        didSet {
            if oldValue != fadeTop {
                setNeedsLayout()
            }
        }
    }

    private let viewportFade = CAGradientLayer()
    @MainActor private final class LinkTarget: NSObject {
        weak var owner: AMLLNativeCanvas?
        @objc func tick(_ link: CADisplayLink) {
            owner?.tick(link)
        }
    }

    var position: () -> Double = { 0 }
    var onInteraction: (AMLLInteraction) -> Void = { _ in }
    var onBrowsing: (Bool) -> Void = { _ in }
    private var source: LyricsDocument?
    private var sourceVersion: Int?
    private var display: AMLLDisplayDocument?
    private var configuration = LyricsRenderConfiguration()
    private var input = AMLLPlayerInput(position: 0, playing: false)
    private var engine: AMLLFrameEngine?
    fileprivate struct RowLayouts {
        var original: AMLLCoreTextLayout
        var romanization: AMLLCoreTextLayout?
        var romanizationCue: RomanizationTTMLTrack.Cue?
        var alignedRomanization: Bool
    }
    private var layouts: [Int: RowLayouts] = [:]
    private var romanizationCues: [Int: RomanizationTTMLTrack.Cue] = [:]
    private var heights: [Double] = []
    private var rowViews: [Int: AMLLCompositeRow] = [:]
    private var retainedRows: [Int: AMLLCompositeRow] = [:]
    private var retainedOrder: [Int] = []
    private var preparedRows: [Int: AMLLPreparedCompositeImages] = [:]
    private var preparedOrder: [Int] = []
    private var preparingRows = Set<Int>()
    private var prewarmGeneration = 0
    private var lastVisibleCenter: Int?
    private var link: CADisplayLink?
    private var linkTarget: LinkTarget?
    private var lastTick = 0.0
    private var dirty = true
    private var lastLayoutKey: LayoutKey?
    private var needsFrame = true
    private var lastHeadroom = 1.0
    private var lastHeadroomCheck = 0.0
    private var fadeSize = CGSize.zero
    private var appliedFadeTop: CGFloat?
    private var active = true
    private var canSeek = true
    private var reduceMotion = false
    private var reduceTransparency = false
    private var lastTranslation: CGFloat = 0
    private var resumeToken = 0
    private var targetFPS = 120
    private var framesInSample = 0
    private var sampleDuration = 0.0
    private var sampleWork = 0.0
    var performanceRecordingEnabled = false {
        didSet { if performanceRecordingEnabled != oldValue { performanceRecorder.reset() } }
    }
    private let performanceRecorder = AMLLFramePerformanceRecorder()
    private var pendingLayoutMilliseconds = 0.0
    private var pendingRasterMilliseconds = 0.0
    private(set) var layoutBuildCount = 0
    private var hasDuet = false
    private let dots = AMLLInterludeDotsView()
    private lazy var hdrRenderer = LyricsHDRRenderer()
    private var hdrTime: Double?
    private var hdrSeekRevision = 0
    private var hdrWasPlaying = false
    private var hdrOffset = 0.0
    #if DEBUG
        var hdrCapabilitiesOverride: LyricsHDRCapabilities?
        private var controlledReplay = false
    #endif
    private(set) var frameState: AMLLFrameState?
    private(set) var measuredFPS = 0.0
    private(set) var frameMilliseconds = 0.0
    var visibleRowCount: Int {
        rowViews.count
    }

    var cachedLayoutCount: Int {
        layouts.count
    }

    var performanceSummary: AMLLFramePerformance {
        performanceRecorder.summary(targetFPS: min(targetFPS, window?.screen.maximumFramesPerSecond ?? 60))
    }

    #if DEBUG
        func exportPerformanceSamples() -> Data? {
            struct Export: Codable {
                var sourceID: String?
                var documentHash: String?
                var viewport: CGSize
                var displayScale: CGFloat
                var configuration: LyricsRenderConfiguration
                var summary: AMLLFramePerformance
                var samples: [AMLLFramePerformance.Sample]
            }
            let documentEncoder = JSONEncoder()
            documentEncoder.outputFormatting = [.sortedKeys]
            let documentHash = source.flatMap { try? documentEncoder.encode($0) }
                .map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }
            return try? JSONEncoder().encode(Export(sourceID: source?.candidate.id,
                                                    documentHash: documentHash,
                                                    viewport: bounds.size,
                                                    displayScale: window?.screen.scale ?? 1,
                                                    configuration: configuration,
                                                    summary: performanceSummary,
                                                    samples: performanceRecorder.samples))
        }
    #endif

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        clipsToBounds = true
        addSubview(dots)
        dots.isHidden = true
        addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(pan(_:))))
        NotificationCenter.default.addObserver(self, selector: #selector(releaseOffscreenResources),
                                               name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(refreshAfterActivation),
                                               name: UIApplication.didBecomeActiveNotification, object: nil)
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self, UITraitLegibilityWeight.self]) { (view: AMLLNativeCanvas, _: UITraitCollection) in
            view.dirty = true; view.setNeedsLayout()
        }
    }

    required init?(coder _: NSCoder) {
        nil
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func releaseOffscreenResources() {
        retainedRows.removeAll()
        retainedOrder.removeAll()
        prewarmGeneration &+= 1
        preparedRows.removeAll()
        preparedOrder.removeAll()
        preparingRows.removeAll()
        let visible = Set(rowViews.keys)
        layouts = layouts.filter { visible.contains($0.key) }
        needsFrame = true
    }

    @objc private func refreshAfterActivation() {
        rowViews.values.forEach { $0.invalidateVisualCache() }
        needsFrame = true
        syncLink()
    }

    func configure(document: LyricsDocument, documentVersion: Int? = nil,
                   configuration: LyricsRenderConfiguration, input: AMLLPlayerInput,
                   active: Bool, reduceMotion: Bool, reduceTransparency: Bool = false, canSeek: Bool = true)
    {
        let documentChanged = documentVersion.map { sourceVersion != $0 } ?? (source != document)
        if documentChanged || self.configuration.obsceneWordMask != configuration.obsceneWordMask {
            hdrTime = nil
            source = document
            sourceVersion = documentVersion
            romanizationCues = Dictionary(document.romanizationTTMLTrack?.cues.map {
                ($0.sourceLineIndex, $0)
            } ?? [], uniquingKeysWith: { _, newest in newest })
            var displayLines = document.lines
            // A generated cue replaces provider pronunciation only in the
            // display copy. The original lyric and fallback stay untouched.
            for index in romanizationCues.keys where displayLines.indices.contains(index) {
                displayLines[index].romanization = ""
                for wordIndex in displayLines[index].words.indices {
                    displayLines[index].words[wordIndex].romanWord = nil
                }
            }
            display = AMLLDisplayDocument(lines: (configuration.obsceneWordMask ?? .init()).apply(to: displayLines))
            engine = nil; dirty = true
            hasDuet = display?.lines.contains(where: \.isDuet) ?? false
        }
        let configurationChanged = self.configuration != configuration
        if configurationChanged {
            if Self.layoutSettings(self.configuration) != Self.layoutSettings(configuration) {
                dirty = true
            }
            needsFrame = true
        }
        let accessibilityChanged = self.reduceMotion != reduceMotion || self.reduceTransparency != reduceTransparency
        if self.active != active {
            needsFrame = true
            if active { rowViews.values.forEach { $0.invalidateVisualCache() } }
        }
        if self.canSeek != canSeek { needsFrame = true }
        if accessibilityChanged
            || self.input.seekRevision != input.seekRevision || self.input.playing != input.playing
            || self.input.offset != input.offset || self.input.event != input.event
            || self.input.position != input.position {
            needsFrame = true
        }
        self.configuration = configuration; self.input = input; self.active = active
        self.canSeek = canSeek; self.reduceMotion = reduceMotion; self.reduceTransparency = reduceTransparency
        if dirty { setNeedsLayout() }
        else if configurationChanged || accessibilityChanged {
            engine?.resize(environment: renderEnvironment(), heights: heights)
        }
        syncLink()
        #if DEBUG
            if link == nil, !controlledReplay, needsFrame, !dirty { draw(delta: 0) }
        #endif
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if fadeSize != bounds.size || appliedFadeTop != fadeTop {
            updateViewportFade()
            fadeSize = bounds.size
            appliedFadeTop = fadeTop
        }
        guard bounds.width > 0, bounds.height > 0, let display else { return }
        let layoutKey = currentLayoutKey()
        if dirty || lastLayoutKey != layoutKey {
            dirty = false
            lastLayoutKey = layoutKey
            layouts.removeAll()
            rowViews.values.forEach { $0.removeFromSuperview() }; rowViews.removeAll()
            retainedRows.removeAll(); retainedOrder.removeAll()
            prewarmGeneration &+= 1
            preparedRows.removeAll(); preparedOrder.removeAll(); preparingRows.removeAll()
            lastVisibleCenter = nil
            heights = display.lines.indices.map { makeLayout($0).original.size.height }
            let environment = renderEnvironment()
            if engine == nil {
                engine = AMLLFrameEngine(document: display, environment: environment, heights: heights)
            } else {
                engine?.resize(environment: environment, heights: heights)
            }
        }
        needsFrame = true
        // Debug's explicit replay has no display link. Production commits the
        // new size and the first frame together on the next CADisplayLink tick.
        if link == nil { draw(delta: 0) }
    }

    private struct LayoutSettings: Equatable {
        var translation: Bool
        var romanization: Bool
        var romanizationFirst: Bool
        var fontSize: Double
        var sizePreset: AMLLLyricSizePreset?
        var bold: Bool
        var tracking: Double
        var horizontalPadding: Double?
        var paragraphSpacing: Double?
        var auxiliaryScale: Double?
    }

    private struct LayoutKey: Equatable {
        var documentVersion: Int?
        var viewport: CGSize
        var displayScale: CGFloat
        var pointSize: CGFloat
        var inset: CGFloat
        var boldText: Bool
        var direction: UIUserInterfaceLayoutDirection
        var locale: String
        var settings: LayoutSettings
    }

    private func currentLayoutKey() -> LayoutKey {
        .init(documentVersion: sourceVersion, viewport: bounds.size,
              displayScale: window?.screen.scale ?? 1,
              pointSize: resolvedPointSize, inset: inset,
              boldText: traitCollection.legibilityWeight == .bold,
              direction: effectiveUserInterfaceLayoutDirection,
              locale: Locale.current.identifier,
              settings: Self.layoutSettings(configuration))
    }

    private static func layoutSettings(_ value: LyricsRenderConfiguration) -> LayoutSettings {
        .init(translation: value.translation, romanization: value.romanization,
              romanizationFirst: value.romanizationFirst, fontSize: value.fontSize,
              sizePreset: value.sizePreset, bold: value.bold, tracking: value.tracking,
              horizontalPadding: value.horizontalPadding,
              paragraphSpacing: value.paragraphSpacing, auxiliaryScale: value.auxiliaryScale)
    }

    private func updateViewportFade() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard let fadeTop, bounds.height > 0 else { layer.mask = nil; return }
        let stops: [(CGFloat, CGFloat)] = [
            (0, 0), (min(0.8, max(0, fadeTop) / bounds.height), 0),
            (min(0.9, max(0, fadeTop + 64) / bounds.height), 1), (0.82, 1), (1, 0),
        ].sorted { $0.0 < $1.0 }
        viewportFade.frame = bounds
        viewportFade.startPoint = CGPoint(x: 0.5, y: 0)
        viewportFade.endPoint = CGPoint(x: 0.5, y: 1)
        viewportFade.locations = stops.map { NSNumber(value: Double($0.0)) }
        viewportFade.colors = stops.map { UIColor.white.withAlphaComponent($0.1).cgColor }
        layer.mask = viewportFade
    }

    private func renderEnvironment() -> AMLLRenderEnvironment {
        let safeArea = safeAreaInsets
        let traits = traitCollection
        let typeScale = UIFontMetrics(forTextStyle: .body).scaledValue(for: 1)
        let screen = window?.screen
        let direction = effectiveUserInterfaceLayoutDirection == .rightToLeft ? "rtl" : "ltr"
        let reduceTransparencyEnabled = UIAccessibility.isReduceTransparencyEnabled
        let safe = AMLLSafeArea(top: safeArea.top, leading: safeArea.left,
                                bottom: safeArea.bottom, trailing: safeArea.right)
        var environment = AMLLRenderEnvironment(width: bounds.width,
                                                height: bounds.height,
                                                screenWidth: Double(window?.bounds.width ?? bounds.width),
                                                // `resolvedPointSize` already applies Dynamic Type once.
                                                // Keep the engine's spacing metrics in the same unit as
                                                // the Core Text layout instead of scaling them again.
                                                fontSize: Double(resolvedPointSize))
        environment.safeArea = safe
        environment.displayScale = Double(screen?.scale ?? 1)
        environment.maximumFPS = screen?.maximumFramesPerSecond ?? 60
        environment.localeIdentifier = Locale.current.identifier
        environment.layoutDirection = direction
        environment.alignPosition = configuration.anchor
        environment.reduceMotion = reduceMotion
        environment.reduceTransparency = reduceTransparency || reduceTransparencyEnabled
        environment.boldText = traits.legibilityWeight == .bold
        environment.dynamicTypeScale = typeScale
        environment.voiceOver = UIAccessibility.isVoiceOverRunning
        environment.enableSpring = configuration.enableSpring
        environment.enableScale = configuration.enableScale
        environment.enableBlur = configuration.blurInactive && !environment.reduceTransparency
        environment.hidePassedLines = configuration.hidePassedLines
        environment.alwaysPostpositionBackground = configuration.alwaysPostpositionBackground
        environment.advance = configuration.advance
        environment.dotHeight = max(environment.fontSize * 0.5, bounds.height * 0.01)
        return environment
    }

    private var inset: CGFloat {
        configuration.horizontalPadding ?? ((window?.bounds.width ?? bounds.width) <= 500 ? 20 : resolvedPointSize)
    }

    private var resolvedPointSize: CGFloat {
        let metrics = UIFontMetrics(forTextStyle: .title1)
        return metrics.scaledValue(for: configuration.resolvedFontSize(width: bounds.width, height: bounds.height), compatibleWith: traitCollection)
    }

    private func makeLayout(_ index: Int) -> RowLayouts {
        if let cached = layouts[index] {
            return cached
        }
        layoutBuildCount += 1
        let started = performanceRecordingEnabled ? CACurrentMediaTime() : 0
        defer {
            if performanceRecordingEnabled {
                pendingLayoutMilliseconds += (CACurrentMediaTime() - started) * 1_000
            }
        }
        let line = display!.lines[index]
        let baseSize = resolvedPointSize
        let size = max(10, baseSize * (line.isBackground ? 0.7 : 1))
        // `size` is already Dynamic Type adjusted by `resolvedPointSize`.
        // Applying UIFontMetrics.scaledFont here would scale the same value a
        // second time at accessibility text sizes.
        let font = UIFont.systemFont(ofSize: size, weight: configuration.bold || traitCollection.legibilityWeight == .bold ? .bold : .regular)
        let width = max(1, bounds.width - inset * 2) * (hasDuet ? 0.85 : 1)
        let cue = configuration.romanization ? romanizationCues[index] : nil
        if let cue, !cue.tokens.isEmpty, line.precision == .word {
            var placement = line
            placement.generatedRomanization = cue.tokens
            placement.generatedRomanizationLanguage = cue.line.generatedRomanizationLanguage
            let aligned = AMLLCoreTextLayout(line: placement, width: width, font: font,
                                             configuration: configuration)
            if aligned.hasGeneratedRomanizationLayout {
                let result = RowLayouts(original: aligned, romanization: nil,
                                        romanizationCue: cue, alignedRomanization: true)
                layouts[index] = result
                return result
            }
        }
        var romanConfiguration = configuration
        romanConfiguration.romanization = false
        romanConfiguration.translation = false
        romanConfiguration.paragraphSpacing = 0
        let romanFont = font.withSize(max(10, size * (configuration.auxiliaryScale ?? 0.5)))
        let romanLayout = cue.map {
            AMLLCoreTextLayout(line: $0.line, width: width, font: romanFont, configuration: romanConfiguration)
        }
        let original = AMLLCoreTextLayout(line: line, width: width, font: font, configuration: configuration,
                                          romanizationReserve: romanLayout?.size.height ?? 0)
        let result = RowLayouts(original: original, romanization: romanLayout,
                                romanizationCue: cue, alignedRomanization: false)
        layouts[index] = result
        return result
    }

    private func draw(delta: Double) {
        guard !dirty, engine != nil, let display else { return }
        let frameStarted = performanceRecordingEnabled ? CACurrentMediaTime() : 0
        input.position = position()
        // Mutate the unique stored engine. Copying the struct here makes its
        // group-motion array copy on write once per display refresh.
        let state = engine!.render(input, delta: delta)
        let engineFinished = performanceRecordingEnabled ? CACurrentMediaTime() : 0
        if frameState?.browsing != state.browsing {
            #if DEBUG
                if !controlledReplay {
                    DispatchQueue.main.async { [weak self] in self?.onBrowsing(state.browsing) }
                }
            #else
                DispatchQueue.main.async { [weak self] in self?.onBrowsing(state.browsing) }
            #endif
        }
        frameState = state
        needsFrame = false
        if hdrTime == nil || input.playing || hdrWasPlaying || input.seeking || hdrSeekRevision != input.seekRevision || hdrOffset != input.offset {
            hdrTime = state.lyricTime
        }
        hdrWasPlaying = input.playing
        hdrSeekRevision = input.seekRevision
        hdrOffset = input.offset
        var capabilities = LyricsHDRCapabilities(supportsEDR: (window?.screen.potentialEDRHeadroom ?? 1) > 1,
                                                 headroom: Double(window?.screen.currentEDRHeadroom ?? 1))
        #if DEBUG
            capabilities = hdrCapabilitiesOverride ?? capabilities
        #endif
        lastHeadroom = capabilities.headroom
        let visible = state.rows.filter { !$0.hidden && $0.y + heights[$0.lineIndex] >= -bounds.height * 0.5 && $0.y <= bounds.height * 1.5 }
        let brightness = capabilities.outputBrightness(configuration: configuration.hdr ?? .init(),
                                                        reduceTransparency: reduceTransparency)
        let actualTime = hdrTime ?? state.lyricTime
        let sourceLines = source?.lines ?? []
        let activeHDR: Set<Int> = brightness > 1 ? Set(visible.compactMap { row -> Int? in
            guard sourceLines.indices.contains(row.lineIndex) else { return nil }
            let line = sourceLines[row.lineIndex]
            return line.start.isFinite && line.end.isFinite && line.end > line.start
                && ((actualTime >= line.start && actualTime < line.end) || row.hdrHold)
                ? row.lineIndex : nil
        }) : []
        let hdr = LyricsHDRFrameState(activeLineIndexes: activeHDR, outputBrightness: brightness)
        let indexes = Set(visible.map(\.lineIndex))
        for index in Array(rowViews.keys) where !indexes.contains(index) {
            if let view = rowViews.removeValue(forKey: index) {
                view.removeFromSuperview()
                retainedRows[index] = view
                retainedOrder.append(index)
            }
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for row in visible {
            let view: AMLLCompositeRow
            if let existing = rowViews[row.lineIndex] {
                view = existing
            } else if let retained = retainedRows.removeValue(forKey: row.lineIndex) {
                retainedOrder.removeAll { $0 == row.lineIndex }
                view = retained
                rowViews[row.lineIndex] = view; addSubview(view)
            } else {
                let layout = makeLayout(row.lineIndex)
                layouts[row.lineIndex] = layout
                let rasterStarted = performanceRecordingEnabled ? CACurrentMediaTime() : 0
                let prepared = preparedRows.removeValue(forKey: row.lineIndex)
                if prepared != nil { preparedOrder.removeAll { $0 == row.lineIndex } }
                view = AMLLCompositeRow(line: display.lines[row.lineIndex], layouts: layout,
                                        scale: window?.screen.scale ?? 2, prepared: prepared)
                if performanceRecordingEnabled {
                    pendingRasterMilliseconds += (CACurrentMediaTime() - rasterStarted) * 1_000
                }
                view.onSeek = { [weak self] in
                    guard let self, canSeek else { return }
                    onInteraction(.seek(lineID: display.lines[row.lineIndex].id))
                }
                rowViews[row.lineIndex] = view; addSubview(view)
            }
            let line = display.lines[row.lineIndex]
            let width = layouts[row.lineIndex]?.original.size.width ?? bounds.width - inset * 2
            let anchor = CGPoint(x: line.isDuet ? 1 : 0, y: 0.5)
            let rowBounds = CGRect(x: 0, y: 0, width: width, height: heights[row.lineIndex])
            let rowPosition = CGPoint(x: line.isDuet ? bounds.width - inset : inset, y: row.y + heights[row.lineIndex] / 2)
            let rowTransform = CGAffineTransform(scaleX: row.scale, y: row.scale)
            if view.layer.anchorPoint != anchor { view.layer.anchorPoint = anchor }
            if view.bounds != rowBounds { view.bounds = rowBounds }
            if view.layer.position != rowPosition { view.layer.position = rowPosition }
            if view.transform != rowTransform { view.transform = rowTransform }
            view.setCanSeek(canSeek)
            let gain = hdr.activeLineIndexes.contains(row.lineIndex) ? hdr.outputBrightness : 1
            view.updateVisuals(renderer: gain > 1 ? hdrRenderer : nil,
                               gain: gain, lyricTime: state.lyricTime,
                               row: row, configuration: configuration, motionEnabled: !reduceMotion && configuration.emphasizeWords)
            if view.needsHDRRetry { needsFrame = true }
        }
        if let interlude = state.interlude,
           let presentation = AMLLInterludeMotion.presentation(time: state.lyricTime, start: interlude.start, end: interlude.end, playing: input.playing)
        {
            let height = renderEnvironment().dotHeight
            let width = height * 3 + configuration.fontSize * 0.5 + 12
            dots.frame = CGRect(x: interlude.duet ? bounds.width - inset - width : inset, y: interlude.y, width: width, height: height)
            dots.isHidden = false; dots.apply(presentation); bringSubviewToFront(dots)
        } else {
            dots.isHidden = true
        }
        trimRetainedRows()
        CATransaction.commit()
        schedulePrewarm(visible: visible)
        if performanceRecordingEnabled {
            let finished = CACurrentMediaTime()
            let hdrTimings = hdrRenderer?.drainTimings()
            performanceRecorder.append(.init(interval: delta * 1_000,
                                             cpu: (finished - frameStarted) * 1_000,
                                             layout: pendingLayoutMilliseconds,
                                             raster: pendingRasterMilliseconds,
                                             engine: (engineFinished - frameStarted) * 1_000,
                                             layers: (finished - engineFinished) * 1_000,
                                             drawableWait: hdrTimings?.wait ?? 0,
                                             gpuSubmission: hdrTimings?.submit ?? 0,
                                             gpu: hdrTimings?.gpu ?? 0,
                                             cacheBytes: resourceBytes))
            pendingLayoutMilliseconds = 0
            pendingRasterMilliseconds = 0
        }
    }

    private var resourceBytes: Int {
        rowViews.values.reduce(0) { $0 + $1.estimatedBytes }
            + retainedRows.values.reduce(0) { $0 + $1.estimatedBytes }
            + preparedRows.values.reduce(0) { $0 + $1.estimatedBytes }
    }

    private func trimRetainedRows() {
        let budget = UIDevice.current.userInterfaceIdiom == .pad ? 128 * 1_048_576 : 64 * 1_048_576
        while !retainedOrder.isEmpty && (retainedOrder.count > 12 || resourceBytes > budget) {
            let index = retainedOrder.removeFirst()
            retainedRows.removeValue(forKey: index)
        }
        while !preparedOrder.isEmpty && resourceBytes > budget {
            let index = preparedOrder.removeFirst()
            preparedRows.removeValue(forKey: index)
        }
    }

    private func schedulePrewarm(visible: [AMLLFrameState.Row]) {
        guard active, window != nil,
              let first = visible.map(\.lineIndex).min(),
              let last = visible.map(\.lineIndex).max(), let display else { return }
        let center = (first + last) / 2
        let direction = center < (lastVisibleCenter ?? center) ? -1 : 1
        lastVisibleCenter = center
        let edge = direction > 0 ? last : first
        for distance in 1 ... 2 where preparingRows.isEmpty {
            let index = edge + direction * distance
            guard display.lines.indices.contains(index), rowViews[index] == nil,
                  retainedRows[index] == nil, preparedRows[index] == nil,
                  !preparingRows.contains(index), let layout = layouts[index] else { continue }
            preparingRows.insert(index)
            let generation = prewarmGeneration
            let scale = window?.screen.scale ?? 2
            let original = layout.original.rasterSnapshot()
            let romanization = layout.romanization?.rasterSnapshot()
            let aligned = layout.alignedRomanization
            Task.detached(priority: .utility) { [weak self] in
                let images = AMLLPreparedCompositeImages(
                    original: AMLLPreparedRowImages(snapshot: original, scale: scale,
                                                    hideRomanization: aligned),
                    romanization: romanization.map { AMLLPreparedRowImages(snapshot: $0, scale: scale) },
                    overlay: aligned ? AMLLPreparedOverlayImages(snapshot: original, scale: scale) : nil
                )
                await MainActor.run {
                    guard let self, self.prewarmGeneration == generation else { return }
                    self.preparingRows.remove(index)
                    guard self.rowViews[index] == nil, self.retainedRows[index] == nil else { return }
                    self.preparedRows[index] = images
                    self.preparedOrder.append(index)
                    self.trimRetainedRows()
                }
            }
        }
    }

    #if DEBUG
        struct ResourceCounts: Codable {
            var visibleRows: Int
            var retainedRows: Int
            var layouts: Int
            var layers: Int
        }

        var resourceCounts: ResourceCounts {
            func count(_ layer: CALayer) -> Int {
                1 + (layer.sublayers ?? []).reduce(0) { $0 + count($1) }
                    + (layer.mask.map(count) ?? 0)
            }
            return .init(visibleRows: rowViews.count, retainedRows: retainedRows.count,
                         layouts: layouts.count,
                         layers: Array(rowViews.values).reduce(0) { $0 + count($1.layer) }
                             + Array(retainedRows.values).reduce(0) { $0 + count($1.layer) })
        }

        var glyphUpdateCount: Int {
            rowViews.values.reduce(0) { $0 + $1.visualUpdateCount }
        }

        /// Manual display-link equivalent for deterministic offscreen validation.
        func advanceFrame(delta: Double) {
            layoutIfNeeded()
            draw(delta: delta)
        }

        /// Rebuild from the fixed initial state for backward as well as forward
        /// navigation. Uses production layout/layers without emitting callbacks.
        func replay(_ scenario: AMLLReplayScenario, through requestedFrame: Int,
                    captureResources: ((ResourceCounts) -> Void)? = nil) throws -> [AMLLFrameState]
        {
            var cursor = try AMLLReplayCursor(scenario)
            controlledReplay = true
            stop()
            defer { controlledReplay = false }
            engine = nil; dirty = true; hdrTime = nil
            input = cursor.input
            position = { scenario.initialPosition }
            setNeedsLayout(); layoutIfNeeded()
            var frames: [AMLLFrameState] = []
            for _ in 0 ..< min(max(0, requestedFrame + 1), scenario.frameDeltas.count) {
                guard let next = cursor.next() else { break }
                input = next.input
                let time = next.input.position
                let beginning = time - (next.input.playing ? next.delta : 0)
                position = { beginning }
                next.interactions.forEach { engine?.handle($0) }
                draw(delta: 0)
                input.seeking = false
                position = { time }
                draw(delta: next.delta)
                if let frameState {
                    frames.append(frameState)
                    captureResources?(resourceCounts)
                }
            }
            return frames
        }
    #endif

    override func didMoveToWindow() {
        super.didMoveToWindow()
        setNeedsLayout()
        syncLink()
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        if !dirty { engine?.resize(environment: renderEnvironment(), heights: heights) }
        needsFrame = true
    }

    func stop() {
        link?.invalidate(); link = nil; linkTarget = nil; lastTick = 0
        prewarmGeneration &+= 1
        preparedRows.removeAll(); preparedOrder.removeAll(); preparingRows.removeAll()
    }

    func resumeFollowing(token: Int) {
        guard resumeToken != token else { return }
        resumeToken = token
        engine?.handle(.resumeFollowing)
        onInteraction(.resumeFollowing)
        needsFrame = true
        syncLink()
    }

    func setFrameRate(_ fps: Int) {
        guard targetFPS != fps else { return }
        targetFPS = fps
        if let link {
            applyFrameRate(link)
        }
    }

    private func applyFrameRate(_ link: CADisplayLink) {
        let rate = Float(min(max(60, targetFPS), window?.screen.maximumFramesPerSecond ?? 60))
        link.preferredFrameRateRange = .init(minimum: 60, maximum: rate, preferred: rate)
    }

    #if DEBUG
        /// Simulates a bounded five-second continuation of the actual engine state.
        /// Unlike a list of timestamps, these frames contain every group's sampled transforms.
        func exportMotionTrace(fps: Int) -> Data? {
            guard var replay = engine, !dirty else { return nil }
            struct Trace: Encodable {
                var schema = 2
                var coreVersion = "0.5.2"
                var environment: AMLLRenderEnvironment
                var fps: Int
                var lineIDs: [String]
                var breaks: [[Int]]
                var layoutDiagnostics: [[String]]
                var frames: [AMLLFrameState]
            }
            let rate = fps == 120 ? 120 : 60
            let start = position()
            var replayInput = input
            var frames: [AMLLFrameState] = []
            for frame in 0 ..< rate * 5 {
                replayInput.position = start + (input.playing ? Double(frame) / Double(rate) : 0)
                frames.append(replay.render(replayInput, delta: frame == 0 ? 0 : 1 / Double(rate)))
            }
            let trace = Trace(environment: renderEnvironment(), fps: rate,
                              lineIDs: display?.lines.map(\.id) ?? [],
                              breaks: heights.indices.map { makeLayout($0).original.breakOffsets },
                              layoutDiagnostics: heights.indices.map { makeLayout($0).original.diagnostics }, frames: frames)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return try? encoder.encode(trace)
        }
    #endif

    private func syncLink() {
        #if DEBUG
            if controlledReplay {
                stop(); return
            }
        #endif
        guard window != nil, active else { stop(); return }
        guard link == nil else { return }
        let target = LinkTarget(); target.owner = self; linkTarget = target
        let link = CADisplayLink(target: target, selector: #selector(LinkTarget.tick(_:)))
        applyFrameRate(link)
        link.add(to: .main, forMode: .common); self.link = link
    }

    private func tick(_ link: CADisplayLink) {
        let start = CACurrentMediaTime()
        if dirty || lastLayoutKey?.viewport != bounds.size || appliedFadeTop != fadeTop {
            layoutIfNeeded()
        }
        let delta = lastTick == 0 ? 0 : link.timestamp - lastTick
        if !input.playing, !needsFrame, frameState?.settled == true, frameState?.browsing == false {
            let wantsEDR = configuration.hdr?.enabled == true && !reduceTransparency
            if !wantsEDR || start - lastHeadroomCheck < 0.25 {
                lastTick = link.timestamp
                return
            }
            lastHeadroomCheck = start
            if abs(Double(window?.screen.currentEDRHeadroom ?? 1) - lastHeadroom) < 0.001 {
                lastTick = link.timestamp
                return
            }
        }
        lastTick = link.timestamp; draw(delta: delta)
        framesInSample += 1; sampleDuration += delta; sampleWork += CACurrentMediaTime() - start
        if sampleDuration >= 1 {
            measuredFPS = Double(framesInSample) / sampleDuration
            frameMilliseconds = sampleWork * 1000 / Double(framesInSample)
            framesInSample = 0; sampleDuration = 0; sampleWork = 0
        }
    }

    @objc private func pan(_ gesture: UIPanGestureRecognizer) {
        needsFrame = true
        switch gesture.state {
        case .began:
            lastTranslation = 0
            onInteraction(.beginBrowsing)
            engine?.handle(.beginBrowsing)
        case .changed:
            let value = gesture.translation(in: self).y
            let delta = lastTranslation - value
            onInteraction(.browseBy(delta))
            engine?.handle(.browseBy(delta)); lastTranslation = value
        case .ended:
            let velocity = gesture.velocity(in: self).y
            onInteraction(.endBrowsing(velocity: velocity))
            engine?.handle(.endBrowsing(velocity: velocity))
        case .cancelled, .failed:
            onInteraction(.endBrowsing(velocity: 0))
            engine?.handle(.endBrowsing(velocity: 0))
        default: break
        }
        // The display link consumes gesture state once per frame. Drawing
        // here as well doubles compositing work during touch tracking.
    }
}

/// The original line and the generated TTML cue are separate native rows.
/// Only their geometry is grouped for AMLL's focus/scroll layout.
@MainActor
private final class AMLLCompositeRow: UIView {
    private let original: AMLLNativeRow
    private let romanization: AMLLNativeRow?
    private let alignedRomanization: AMLLRomanizationOverlay?
    private let romanizationCue: LyricLine?

    var onSeek: (() -> Void)? {
        didSet {
            original.onSeek = onSeek
            romanization?.onSeek = onSeek
            alignedRomanization?.onSeek = onSeek
        }
    }

    var visualUpdateCount: Int {
        original.visualUpdateCount + (romanization?.visualUpdateCount ?? 0)
    }

    var estimatedBytes: Int {
        original.estimatedBytes + (romanization?.estimatedBytes ?? 0)
            + (alignedRomanization?.estimatedBytes ?? 0)
    }

    var needsHDRRetry: Bool { original.needsHDRRetry }

    func invalidateVisualCache() {
        original.invalidateVisualCache()
        romanization?.invalidateVisualCache()
    }

    init(line: LyricLine, layouts: AMLLNativeCanvas.RowLayouts, scale: CGFloat,
         prepared: AMLLPreparedCompositeImages? = nil) {
        original = AMLLNativeRow(line: line, layout: layouts.original, scale: scale,
                                 hideRomanization: layouts.alignedRomanization, prepared: prepared?.original)
        romanizationCue = layouts.romanizationCue?.line
        alignedRomanization = layouts.alignedRomanization && layouts.romanizationCue != nil
            ? AMLLRomanizationOverlay(layout: layouts.original, cue: layouts.romanizationCue!.line,
                                      scale: scale, prepared: prepared?.overlay)
            : nil
        if let cue = layouts.romanizationCue, let layout = layouts.romanization {
            romanization = AMLLNativeRow(line: cue.line, layout: layout, scale: scale,
                                          prepared: prepared?.romanization)
        } else {
            romanization = nil
        }
        super.init(frame: CGRect(origin: .zero, size: layouts.original.size))
        isOpaque = false
        original.frame = bounds
        addSubview(original)
        if let alignedRomanization {
            alignedRomanization.frame = bounds
            addSubview(alignedRomanization)
        }
        if let romanization, let layout = layouts.romanization {
            romanization.frame = CGRect(x: 0, y: layouts.original.romanizationSlotY ?? 0,
                                        width: layout.size.width, height: layout.size.height)
            addSubview(romanization)
        }
    }

    required init?(coder _: NSCoder) { nil }

    func setCanSeek(_ value: Bool) {
        original.setCanSeek(value)
        romanization?.setCanSeek(value)
        alignedRomanization?.setCanSeek(value)
    }

    func updateVisuals(renderer: LyricsHDRRenderer?, gain: Double, lyricTime: Double,
                       row: AMLLFrameState.Row, configuration: LyricsRenderConfiguration, motionEnabled: Bool)
    {
        original.updateVisuals(renderer: renderer, gain: gain, row: row,
                               configuration: configuration, motionEnabled: motionEnabled)
        alignedRomanization?.update(row: row, lyricTime: lyricTime, configuration: configuration)
        guard let cue = romanizationCue, let romanization else { return }
        var independent = row
        var clock = AMLLWordAnimationClock()
        clock.enable(at: max(0, lyricTime - cue.start))
        independent.wordClock = clock
        independent.fillComplete = cue.precision == .word && lyricTime >= cue.end
        independent.hdrHold = false
        independent.active = lyricTime >= cue.start && lyricTime < cue.end
        if cue.precision == .line, !independent.active {
            independent.opacity *= row.darkAlpha
        }
        var auxiliaryConfiguration = configuration
        auxiliaryConfiguration.romanization = false
        auxiliaryConfiguration.translation = false
        // The pronunciation has its own TTML masks. Original-word emphasis
        // and HDR must not be applied to this independent SDR text row.
        romanization.updateVisuals(renderer: nil, gain: 1, row: independent,
                                   configuration: auxiliaryConfiguration, motionEnabled: false)
    }

}

@MainActor
private final class AMLLNativeRow: UIView {

    private struct RubyPiece {
        var layer: CALayer
        var mask: CAGradientLayer
        var fragment: AMLLCoreTextLayout.RubyFragment
        var maskWidth: Double
        var advance: Double
    }

    private struct WordPiece {
        var layer: CALayer
        var mask: CAGradientLayer
        var fragment: AMLLCoreTextLayout.WordFragment
        var maskIndex: Int
        var advance: Double
    }

    private struct CharacterPiece {
        var layer: CALayer
        var mask: CAGradientLayer
        var fragment: AMLLCoreTextLayout.CharacterFragment
        var maskIndex: Int
        var advance: Double
        var animation: AMLLSourceWordAnimation.CharacterAnimation?
    }

    private let line: LyricLine
    private let textLayout: AMLLCoreTextLayout
    private let base = CALayer()
    private let ruby = CALayer()
    private let auxiliary = CALayer()
    private var words: [WordPiece] = []
    private var characters: [CharacterPiece] = []
    private var rubyPieces: [RubyPiece] = []
    private let maskWords: [AMLLWordMask.Word]
    private let sharpImage: UIImage
    private let sharpRubyImage: UIImage
    private let sharpAuxiliaryImage: UIImage
    private let rasterBytes: Int
    private let nearBlur = CALayer()
    private let farBlur = CALayer()
    private var lastCanSeek: Bool?
    private var hdrRow: LyricsHDRRow?
    var estimatedBytes: Int {
        rasterBytes + (hdrRow?.estimatedBytes ?? 0)
    }
    var onSeek: (() -> Void)?

    init(line: LyricLine, layout: AMLLCoreTextLayout, scale: CGFloat,
         hideRomanization: Bool = false, prepared: AMLLPreparedRowImages? = nil) {
        self.line = line; textLayout = layout
        let indexes = layout.maskWords.indices.filter { layout.maskWords[$0].width > 0 }
        maskWords = indexes.map { layout.maskWords[$0] }
        let maskIndexByWord = Dictionary(uniqueKeysWithValues: indexes.enumerated().map { ($0.element, $0.offset) })
        var rubyWidths: [String: Double] = [:]
        for fragment in layout.rubyFragments {
            let key = "\(fragment.kind.rawValue):\(fragment.wordIndex):\(fragment.segmentIndex)"
            rubyWidths[key, default: 0] += fragment.rect.width
        }
        // Keep the three compositing layers disjoint. In particular, a word
        // piece must not sample a ruby or translation row from the full-line
        // bitmap when its contentsRect is animated independently.
        let images = prepared ?? AMLLPreparedRowImages(snapshot: layout.rasterSnapshot(),
                                                        scale: scale, hideRomanization: hideRomanization)
        sharpImage = images.sharp
        sharpRubyImage = images.ruby
        sharpAuxiliaryImage = images.auxiliary
        rasterBytes = images.estimatedBytes
        super.init(frame: CGRect(origin: .zero, size: layout.size))
        base.contents = sharpImage.cgImage; base.contentsScale = scale; base.frame = bounds; layer.addSublayer(base)
        ruby.contents = sharpRubyImage.cgImage; ruby.contentsScale = scale; ruby.frame = bounds; layer.addSublayer(ruby)
        var rubyAdvances: [String: Double] = [:]
        for fragment in layout.rubyFragments where fragment.rect.width > 0
            && (!hideRomanization || fragment.kind != .romanization) {
            let piece = CALayer()
            piece.frame = fragment.rect
            piece.contents = sharpRubyImage.cgImage
            piece.contentsScale = scale
            piece.contentsRect = CGRect(x: fragment.rect.minX / layout.size.width, y: fragment.rect.minY / layout.size.height,
                                        width: fragment.rect.width / layout.size.width, height: fragment.rect.height / layout.size.height)
            let mask = CAGradientLayer()
            mask.frame = piece.bounds
            piece.mask = mask
            layer.addSublayer(piece)
            let key = "\(fragment.kind.rawValue):\(fragment.wordIndex):\(fragment.segmentIndex)"
            let maskWidth = rubyWidths[key, default: 0]
            rubyPieces.append(.init(layer: piece, mask: mask, fragment: fragment,
                                    maskWidth: maskWidth, advance: rubyAdvances[key, default: 0]))
            rubyAdvances[key, default: 0] += fragment.rect.width
        }
        ruby.isHidden = !rubyPieces.isEmpty
        auxiliary.contents = sharpAuxiliaryImage.cgImage
        auxiliary.contentsScale = scale; auxiliary.frame = bounds; layer.addSublayer(auxiliary)
        // Blur the entire composed text, including annotations, before any
        // glyph cropping. Never feed blurred pixels through word masks.
        for (blurLayer, image) in [(nearBlur, images.nearBlur), (farBlur, images.farBlur)] {
            blurLayer.contents = image.cgImage
            blurLayer.contentsScale = min(scale, 1)
            // Offset the padded texture back to the original text origin.
            // Layout width, baselines and word masks remain unchanged.
            let paddingX = (image.size.width - bounds.width) / 2
            let paddingY = (image.size.height - bounds.height) / 2
            blurLayer.frame = CGRect(x: -paddingX, y: -paddingY, width: image.size.width, height: image.size.height)
            blurLayer.opacity = 0
            layer.addSublayer(blurLayer)
        }
        var consumed: [Int: Double] = [:]
        for fragment in layout.fragments where fragment.rect.width > 0 {
            guard let maskIndex = maskIndexByWord[fragment.wordIndex] else { continue }
            let piece = CALayer()
            piece.frame = fragment.rect; piece.contents = sharpImage.cgImage; piece.contentsScale = scale
            piece.contentsRect = CGRect(x: fragment.rect.minX / layout.size.width, y: fragment.rect.minY / layout.size.height,
                                        width: fragment.rect.width / layout.size.width, height: fragment.rect.height / layout.size.height)
            let mask = CAGradientLayer(); mask.frame = piece.bounds
            mask.startPoint = CGPoint(x: fragment.rtl ? 1 : 0, y: 0.5); mask.endPoint = CGPoint(x: fragment.rtl ? 0 : 1, y: 0.5)
            piece.mask = mask; layer.addSublayer(piece)
            let advance = consumed[fragment.wordIndex, default: 0]
            words.append(.init(layer: piece, mask: mask, fragment: fragment, maskIndex: maskIndex, advance: advance))
            consumed[fragment.wordIndex] = advance + fragment.rect.width
        }

        // `wordIndex` addresses the display document's segmented timing atoms,
        // which may be more numerous than the provider's original words.
        let emphasis = AMLLSourceWordAnimation.chunkEmphasis(words: line.words, lineStart: line.start,
                                                             isBackground: line.isBackground)
        var characterConsumed: [Int: Double] = [:]
        var characterWordIndexes = Set<Int>()
        for fragment in layout.characterFragments where fragment.rect.width > 0 {
            guard let maskIndex = maskIndexByWord[fragment.wordIndex] else { continue }
            let piece = CALayer()
            piece.frame = fragment.rect; piece.contents = sharpImage.cgImage; piece.contentsScale = scale
            piece.contentsRect = CGRect(x: fragment.rect.minX / layout.size.width, y: fragment.rect.minY / layout.size.height,
                                        width: fragment.rect.width / layout.size.width, height: fragment.rect.height / layout.size.height)
            let mask = CAGradientLayer(); mask.frame = piece.bounds
            mask.startPoint = CGPoint(x: fragment.rtl ? 1 : 0, y: 0.5); mask.endPoint = CGPoint(x: fragment.rtl ? 0 : 1, y: 0.5)
            piece.mask = mask; layer.addSublayer(piece)
            let animation = emphasis.indices.contains(fragment.wordIndex)
                ? emphasis[fragment.wordIndex][fragment.characterIndex] : nil
            let advance = characterConsumed[fragment.wordIndex, default: 0]
            characters.append(.init(layer: piece, mask: mask, fragment: fragment, maskIndex: maskIndex,
                                    advance: advance, animation: animation))
            characterConsumed[fragment.wordIndex] = advance + fragment.rect.width
            characterWordIndexes.insert(fragment.wordIndex)
        }
        // A shaped run may legitimately have no per-character fragment (for
        // example a fallback glyph with a zero advance). Keep the cached
        // whole-line raster visible in that case instead of making the lyric
        // disappear merely because word timing exists.
        base.isHidden = !words.isEmpty && !characters.isEmpty
        for word in words where characterWordIndexes.contains(word.fragment.wordIndex) {
            word.layer.isHidden = true
        }
        isAccessibilityElement = true
        accessibilityLabel = layoutLineAccessibilityText()
        accessibilityTraits = .button
        accessibilityIdentifier = "lyricRow." + line.id
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tap)))
    }

    required init?(coder _: NSCoder) {
        nil
    }

    override func accessibilityActivate() -> Bool {
        onSeek?(); return onSeek != nil
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.insetBy(dx: -22, dy: -22).contains(point) || super.point(inside: point, with: event)
    }

    func setCanSeek(_ value: Bool) {
        guard lastCanSeek != value else { return }
        lastCanSeek = value
        accessibilityTraits = value ? .button : []
        accessibilityHint = value ? NSLocalizedString("render.seekHint", comment: "") : nil
        accessibilityCustomActions = value ? [
            UIAccessibilityCustomAction(
                name: NSLocalizedString("render.seekHint", comment: ""),
                target: self,
                selector: #selector(seekFromAccessibility)
            ),
        ] : nil
    }

    private func layoutLineAccessibilityText() -> String {
        // The layout already applies the visibility/profile rules. Repeating
        // them here keeps VoiceOver in the same order as the pixels without
        // exposing parser-only metadata.
        accessibilityConfiguration.accessibilityText(for: line, displayingInlineRomanization: displaysInlineRomanization)
    }

    private var displaysInlineRomanization: Bool {
        textLayout.rubyFragments.contains { $0.kind == .romanization }
    }

    private var accessibilityConfiguration = LyricsRenderConfiguration()

    @objc private func tap() {
        onSeek?()
    }

    @objc private func seekFromAccessibility() -> Bool {
        guard onSeek != nil else { return false }
        onSeek?()
        return true
    }

    private var lastVisualRow: AMLLFrameState.Row?
    private var lastVisualConfiguration: LyricsRenderConfiguration?
    private var lastVisualMotion = false
    private var lastVisualGain = 1.0
    private(set) var visualUpdateCount = 0
    private(set) var needsHDRRetry = false

    func invalidateVisualCache() { lastVisualRow = nil }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        // A recycled CAMetalLayer may no longer own the last presented
        // drawable. Re-submit its current mask when it becomes visible again.
        if window != nil { lastVisualRow = nil }
    }

    func updateVisuals(renderer: LyricsHDRRenderer?, gain: Double, row: AMLLFrameState.Row,
                       configuration: LyricsRenderConfiguration, motionEnabled: Bool)
    {
        // Dragging changes the parent position, not every word's mask.
        // A completed Metal drawable remains the row's current output until
        // its coverage, brightness or geometry changes.
        var visual = row
        visual.y = 0
        visual.scale = 1
        if !visual.wordClock.enabled {
            var settled = AMLLWordAnimationClock()
            settled.enable(at: visual.wordClock.time)
            settled.disable()
            settled.advance(min(visual.wordClock.time, visual.wordClock.reverseElapsed), playing: false)
            visual.wordClock = settled
        }
        guard visual != lastVisualRow || configuration != lastVisualConfiguration
            || motionEnabled != lastVisualMotion || gain != lastVisualGain else { return }
        lastVisualRow = visual
        lastVisualConfiguration = configuration
        lastVisualMotion = motionEnabled
        lastVisualGain = gain
        visualUpdateCount += 1
        apply(row: row, configuration: configuration, motionEnabled: motionEnabled)
        let hdrSubmitted = applyHDR(renderer: renderer, gain: gain, row: row, configuration: configuration)
        needsHDRRetry = gain > 1 && renderer != nil && !hdrSubmitted
        if needsHDRRetry { lastVisualRow = nil }
    }

    func apply(row: AMLLFrameState.Row, configuration: LyricsRenderConfiguration, motionEnabled: Bool) {
        if accessibilityConfiguration != configuration {
            accessibilityConfiguration = configuration
            accessibilityLabel = layoutLineAccessibilityText()
        }
        let bright = row.brightAlpha, dark = row.darkAlpha
        let radius = min(5, max(0, row.blur))
        let sharpWeight = Float(max(0, 1 - radius / 2))
        // A blurred bitmap has no word mask. Preserve the same unplayed
        // brightness instead of displaying its white pixels at full alpha.
        let blurredAlpha = Float(words.isEmpty ? 1 : dark)
        nearBlur.opacity = Float(radius <= 2 ? radius / 2 : (5 - radius) / 3) * blurredAlpha
        farBlur.opacity = Float(max(0, (radius - 2) / 3)) * blurredAlpha
        alpha = row.opacity * (line.isBackground ? 0.4 : 1)
        ruby.opacity = sharpWeight
        for entry in rubyPieces {
            entry.layer.opacity = sharpWeight
            let fragment = entry.fragment
            if textLayout.sourceAtoms.indices.contains(fragment.wordIndex) {
                let word = textLayout.sourceAtoms[fragment.wordIndex].word
                let start = fragment.motionStart ?? word.start
                let end = fragment.motionEnd ?? word.end
                let elapsed = row.wordClock.floatElapsed(wordStart: start - line.start, duration: end - start)
                let offset = AMLLSourceWordAnimation.wordFloat(elapsed: elapsed, duration: end - start,
                                                               isBackground: line.isBackground)
                let staticKoreanRoman = fragment.kind == .romanization && line.generatedRomanizationLanguage == "ko"
                entry.layer.setAffineTransform(CGAffineTransform(translationX: 0,
                    y: motionEnabled && !staticKoreanRoman ? offset * textLayout.font.pointSize : 0))
            }
            guard let start = fragment.start, let end = fragment.end,
                  start.isFinite, end.isFinite, end > start
            else {
                // Legacy/untimed annotation remains visible; never manufacture
                // syllable timing from its character count.
                entry.mask.colors = [UIColor.white.cgColor, UIColor.white.cgColor]
                continue
            }
            let width = max(1, fragment.rect.width)
            let feather = max(0.0001, textLayout.font.lineHeight * configuration.gradientWidth * 0.5)
            let edge = AMLLWordMask.edge(time: line.start + row.wordClock.time, index: 0,
                                         words: [.init(start: start, end: end, width: entry.maskWidth)], feather: feather) - entry.advance
            let first = edge / width, last = (edge + feather) / width
            entry.mask.colors = [UIColor.white.cgColor, UIColor.white.withAlphaComponent(dark).cgColor]
            entry.mask.locations = [0, 1]
            entry.mask.startPoint = CGPoint(x: fragment.rtl ? 1 - first : first, y: 0.5)
            entry.mask.endPoint = CGPoint(x: fragment.rtl ? 1 - last : last, y: 0.5)
        }
        auxiliary.opacity = sharpWeight
        base.opacity = Float(words.isEmpty ? 1 : dark) * sharpWeight
        // Fully blurred inactive rows need only two whole-line layers.
        // Their word clocks remain engine-owned and catch up when sharp.
        for entry in words {
            entry.layer.opacity = sharpWeight
        }
        for entry in characters {
            entry.layer.opacity = sharpWeight
        }
        if sharpWeight == 0 {
            return
        }
        for entry in words {
            guard !entry.layer.isHidden else { continue }
            let elapsed = row.wordClock.floatElapsed(wordStart: entry.fragment.word.start - line.start,
                                                     duration: entry.fragment.word.end - entry.fragment.word.start)
            let float = AMLLSourceWordAnimation.wordFloat(elapsed: elapsed, duration: entry.fragment.word.end - entry.fragment.word.start,
                                                          isBackground: line.isBackground)
            entry.layer.setAffineTransform(CGAffineTransform(translationX: 0, y: motionEnabled ? float * textLayout.font.pointSize : 0))
            let feather = textLayout.font.lineHeight * configuration.gradientWidth
            // Original mask WAAPI animations advance independently between enable/seek
            // events, pause with playback and retain their current time on disable.
            let edge = row.fillComplete ? entry.fragment.rect.width + feather
                : AMLLWordMask.edge(time: line.start + row.wordClock.time, index: entry.maskIndex,
                                    words: maskWords, feather: feather) - entry.advance
            let width = max(1, entry.fragment.rect.width)
            let start = edge / width, end = (edge + max(0.0001, feather)) / width
            entry.mask.colors = [UIColor.white.withAlphaComponent(bright).cgColor, UIColor.white.withAlphaComponent(dark).cgColor]
            entry.mask.locations = [0, 1]
            // Let the gradient extend beyond the fragment. Clamping stops to [0,1]
            // changes the feather slope when a word enters or leaves the mask.
            entry.mask.startPoint = CGPoint(x: entry.fragment.rtl ? 1 - start : start, y: 0.5)
            entry.mask.endPoint = CGPoint(x: entry.fragment.rtl ? 1 - end : end, y: 0.5)
            entry.layer.opacity = sharpWeight
        }
        for entry in characters {
            let word = entry.fragment.word
            let duration = max(0.001, entry.fragment.range.length > 0
                ? word.end - word.start : 0.001)
            let elapsed = row.wordClock.floatElapsed(
                wordStart: word.start - line.start,
                duration: duration
            )
            let presentation = motionEnabled && configuration.emphasizeWords
                ? entry.animation?.sample(lineTime: row.wordClock.time)
                : nil
            let float = AMLLSourceWordAnimation.wordFloat(elapsed: elapsed, duration: duration, isBackground: line.isBackground)
            let scale = presentation?.scale ?? 1
            let x = (presentation?.offsetX ?? 0) * textLayout.font.pointSize
            let y = ((presentation?.offsetY ?? 0) + (motionEnabled ? float : 0)) * textLayout.font.pointSize
            entry.layer.setAffineTransform(CGAffineTransform(translationX: x, y: y).scaledBy(x: scale, y: scale))
            entry.layer.shadowColor = UIColor.white.cgColor
            entry.layer.shadowRadius = CGFloat(presentation?.glowRadius ?? 0) * textLayout.font.pointSize
            entry.layer.shadowOpacity = Float(presentation?.glowOpacity ?? 0)
            entry.layer.shadowOffset = .zero
            let feather = textLayout.font.lineHeight * configuration.gradientWidth
            let edge = row.fillComplete ? entry.fragment.rect.width + feather
                : AMLLWordMask.edge(time: line.start + row.wordClock.time, index: entry.maskIndex,
                                    words: maskWords, feather: feather) - entry.advance
            let width = max(1, entry.fragment.rect.width)
            let start = edge / width, end = (edge + max(0.0001, feather)) / width
            entry.mask.colors = [UIColor.white.withAlphaComponent(bright).cgColor, UIColor.white.withAlphaComponent(dark).cgColor]
            entry.mask.locations = [0, 1]
            entry.mask.startPoint = CGPoint(x: entry.fragment.rtl ? 1 - start : start, y: 0.5)
            entry.mask.endPoint = CGPoint(x: entry.fragment.rtl ? 1 - end : end, y: 0.5)
            entry.layer.opacity = sharpWeight
        }
    }

    @discardableResult
    func applyHDR(renderer: LyricsHDRRenderer?, gain: Double, row: AMLLFrameState.Row,
                  configuration: LyricsRenderConfiguration) -> Bool {
        guard let renderer, window != nil else {
            hdrRow?.layer.removeFromSuperlayer(); hdrRow = nil
            return true
        }
        let sharpWeight = Float(max(0, 1 - min(5, max(0, row.blur)) / 2))
        guard sharpWeight > 0 else { hdrRow?.layer.isHidden = true; return true }
        if hdrRow == nil, let image = sharpImage.cgImage {
            hdrRow = LyricsHDRRow(renderer: renderer, image: image, size: textLayout.size,
                                  scale: window?.screen.scale ?? 1, padding: textLayout.font.pointSize * 3)
            if let hdrRow {
                layer.addSublayer(hdrRow.layer)
            }
        }
        guard let hdrRow else { return false }
        let feather = textLayout.font.lineHeight * configuration.gradientWidth
        var pieces: [LyricsHDRRow.Piece] = []
        if !base.isHidden {
            let opacity = words.isEmpty ? 1.0 : row.darkAlpha
            pieces.append(.init(rect: bounds, transform: .identity, rtl: false, edge: bounds.width,
                                feather: 0, dark: opacity, bright: opacity))
        } else {
            for entry in words where !entry.layer.isHidden {
                let edge = row.fillComplete ? entry.fragment.rect.width + feather
                    : AMLLWordMask.edge(time: line.start + row.wordClock.time, index: entry.maskIndex,
                                        words: maskWords, feather: feather) - entry.advance
                pieces.append(.init(rect: entry.fragment.rect, transform: entry.layer.affineTransform(),
                                    rtl: entry.fragment.rtl, edge: edge, feather: feather,
                                    dark: row.darkAlpha, bright: row.brightAlpha))
            }
            for entry in characters {
                let edge = row.fillComplete ? entry.fragment.rect.width + feather
                    : AMLLWordMask.edge(time: line.start + row.wordClock.time, index: entry.maskIndex,
                                        words: maskWords, feather: feather) - entry.advance
                pieces.append(.init(rect: entry.fragment.rect, transform: entry.layer.affineTransform(),
                                    rtl: entry.fragment.rtl, edge: edge, feather: feather,
                                    dark: row.darkAlpha, bright: row.brightAlpha,
                                    glowRadius: entry.layer.shadowRadius, glowOpacity: Double(entry.layer.shadowOpacity)))
            }
        }
        guard !pieces.isEmpty else { hdrRow.layer.isHidden = true; return true }
        // Disable the original pixels only after a replacement frame is submitted.
        // Failure always returns to the original SDR layers; it never leaves stale HDR.
        if hdrRow.draw(pieces: pieces, gain: gain, sharpWeight: sharpWeight) {
            base.opacity = 0
            words.forEach { $0.layer.opacity = 0 }
            characters.forEach { $0.layer.opacity = 0 }
            return true
        }
        return false
    }
}
