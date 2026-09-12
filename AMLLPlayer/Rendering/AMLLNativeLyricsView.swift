import CoreImage
import SwiftUI
import UIKit

/// Native AMLL lyric canvas used by the real lyric page and the deterministic
/// Debug preview. The legacy renderer remains available as a comparison path.
struct AMLLNativeLyricsView: UIViewRepresentable {
    var document: LyricsDocument
    var configuration: LyricsRenderConfiguration
    var input: AMLLPlayerInput
    var position: () -> Double
    var interaction: (AMLLInteraction) -> Void
    var canSeek = true
    var active = true
    var targetFPS = 120
    var resumeToken = 0
    var created: (AMLLNativeCanvas) -> Void = { _ in }
    var browsing: (Bool) -> Void = { _ in }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeUIView(context _: Context) -> AMLLNativeCanvas {
        let view = AMLLNativeCanvas()
        DispatchQueue.main.async { created(view) }
        return view
    }

    func updateUIView(_ view: AMLLNativeCanvas, context _: Context) {
        view.position = position
        view.onInteraction = interaction
        view.onBrowsing = browsing
        view.setFrameRate(targetFPS)
        view.configure(document: document, configuration: configuration, input: input, active: active,
                       reduceMotion: reduceMotion, canSeek: canSeek)
        view.resumeFollowing(token: resumeToken)
    }

    static func dismantleUIView(_ view: AMLLNativeCanvas, coordinator _: ()) {
        view.stop()
    }
}

@MainActor
final class AMLLNativeCanvas: UIView {
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
    private var display: AMLLDisplayDocument?
    private var configuration = LyricsRenderConfiguration()
    private var input = AMLLPlayerInput(position: 0, playing: false)
    private var engine: AMLLFrameEngine?
    private var layouts: [Int: AMLLCoreTextLayout] = [:]
    private var heights: [Double] = []
    private var rowViews: [Int: AMLLNativeRow] = [:]
    private var link: CADisplayLink?
    private var linkTarget: LinkTarget?
    private var lastTick = 0.0
    private var measuredSize = CGSize.zero
    private var dirty = true
    private var active = true
    private var canSeek = true
    private var reduceMotion = false
    private var lastTranslation: CGFloat = 0
    private var resumeToken = 0
    private var targetFPS = 120
    private var framesInSample = 0
    private var sampleDuration = 0.0
    private var sampleWork = 0.0
    private var hasDuet = false
    private let dots = AMLLInterludeDotsView()
    private(set) var frameState: AMLLFrameState?
    private(set) var measuredFPS = 0.0
    private(set) var frameMilliseconds = 0.0
    var visibleRowCount: Int {
        rowViews.count
    }

    var cachedLayoutCount: Int {
        layouts.count
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        addSubview(dots)
        dots.isHidden = true
        addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(pan(_:))))
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self, UITraitLegibilityWeight.self]) { (view: AMLLNativeCanvas, _: UITraitCollection) in
            view.dirty = true; view.setNeedsLayout()
        }
    }

    required init?(coder _: NSCoder) {
        nil
    }

    func configure(document: LyricsDocument, configuration: LyricsRenderConfiguration, input: AMLLPlayerInput,
                   active: Bool, reduceMotion: Bool, canSeek: Bool = true)
    {
        if source != document {
            source = document; display = AMLLDisplayDocument(lines: document.lines); engine = nil; dirty = true
            hasDuet = display?.lines.contains(where: \.isDuet) ?? false
        }
        if self.configuration != configuration || self.reduceMotion != reduceMotion {
            dirty = true
        }
        self.configuration = configuration; self.input = input; self.active = active
        self.canSeek = canSeek; self.reduceMotion = reduceMotion
        setNeedsLayout()
        syncLink()
        if !dirty {
            draw(delta: 0)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0, let display else { return }
        if dirty || measuredSize != bounds.size {
            dirty = false; measuredSize = bounds.size
            layouts.removeAll()
            rowViews.values.forEach { $0.removeFromSuperview() }; rowViews.removeAll()
            heights = display.lines.indices.map { makeLayout($0).size.height }
            layouts.removeAll()
            let environment = renderEnvironment()
            if engine == nil {
                engine = AMLLFrameEngine(document: display, environment: environment, heights: heights)
            } else {
                engine?.resize(environment: environment, heights: heights)
            }
        }
        draw(delta: 0)
    }

    private func renderEnvironment() -> AMLLRenderEnvironment {
        let safeArea = safeAreaInsets
        let traits = traitCollection
        let typeScale = UIFontMetrics(forTextStyle: .body).scaledValue(for: 1)
        return AMLLRenderEnvironment(
            width: bounds.width,
            height: bounds.height,
            screenWidth: Double(window?.bounds.width ?? bounds.width),
            fontSize: configuration.fontSize,
            safeArea: .init(top: safeArea.top, leading: safeArea.left, bottom: safeArea.bottom, trailing: safeArea.right),
            displayScale: Double(window?.screen.scale ?? 1),
            maximumFPS: window?.screen.maximumFramesPerSecond ?? 60,
            localeIdentifier: Locale.current.identifier,
            layoutDirection: effectiveUserInterfaceLayoutDirection == .rightToLeft ? "rtl" : "ltr",
            alignPosition: configuration.anchor,
            reduceMotion: reduceMotion,
            reduceTransparency: UIAccessibility.isReduceTransparencyEnabled,
            boldText: traits.legibilityWeight == .bold,
            dynamicTypeScale: typeScale,
            voiceOver: UIAccessibility.isVoiceOverRunning,
            enableBlur: configuration.blurInactive && !UIAccessibility.isReduceTransparencyEnabled,
            dotHeight: max(configuration.fontSize * 0.5, bounds.height * 0.01)
        )
    }

    private var inset: CGFloat {
        (window?.bounds.width ?? bounds.width) <= 500 ? 20 : configuration.fontSize
    }

    private func makeLayout(_ index: Int) -> AMLLCoreTextLayout {
        if let cached = layouts[index] {
            return cached
        }
        let line = display!.lines[index]
        let size = max(10, configuration.fontSize * (line.isBackground ? 0.7 : 1))
        let font = UIFontMetrics(forTextStyle: .title1).scaledFont(for: .systemFont(ofSize: size, weight: configuration.bold ? .semibold : .regular), compatibleWith: traitCollection)
        let width = max(1, bounds.width - inset * 2) * (hasDuet ? 0.85 : 1)
        return AMLLCoreTextLayout(line: line, width: width, font: font, configuration: configuration)
    }

    private func draw(delta: Double) {
        guard !dirty, var engine, let display else { return }
        input.position = position()
        let state = engine.render(input, delta: delta)
        if frameState?.browsing != state.browsing {
            DispatchQueue.main.async { [weak self] in self?.onBrowsing(state.browsing) }
        }
        self.engine = engine; frameState = state
        let visible = state.rows.filter { !$0.hidden && $0.y + heights[$0.lineIndex] >= -bounds.height * 0.5 && $0.y <= bounds.height * 1.5 }
        let indexes = Set(visible.map(\.lineIndex))
        for index in Array(rowViews.keys) where !indexes.contains(index) {
            rowViews.removeValue(forKey: index)?.removeFromSuperview(); layouts.removeValue(forKey: index)
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for row in visible {
            let view: AMLLNativeRow
            if let existing = rowViews[row.lineIndex] {
                view = existing
            } else {
                let layout = makeLayout(row.lineIndex)
                layouts[row.lineIndex] = layout
                view = AMLLNativeRow(line: display.lines[row.lineIndex], layout: layout, scale: window?.screen.scale ?? 2)
                view.onSeek = { [weak self] in
                    guard let self, canSeek else { return }
                    onInteraction(.seek(lineID: display.lines[row.lineIndex].id))
                }
                rowViews[row.lineIndex] = view; addSubview(view)
            }
            let line = display.lines[row.lineIndex]
            let width = layouts[row.lineIndex]?.size.width ?? bounds.width - inset * 2
            view.layer.anchorPoint = CGPoint(x: line.isDuet ? 1 : 0, y: 0.5)
            view.bounds = CGRect(x: 0, y: 0, width: width, height: heights[row.lineIndex])
            view.layer.position = CGPoint(x: line.isDuet ? bounds.width - inset : inset, y: row.y + heights[row.lineIndex] / 2)
            view.transform = CGAffineTransform(scaleX: row.scale, y: row.scale)
            view.apply(row: row, configuration: configuration, motionEnabled: !reduceMotion && configuration.emphasizeWords)
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
        CATransaction.commit()
    }

    #if DEBUG
        /// Manual display-link equivalent for deterministic offscreen validation.
        func advanceFrame(delta: Double) {
            layoutIfNeeded()
            draw(delta: delta)
        }
    #endif

    override func didMoveToWindow() {
        super.didMoveToWindow(); syncLink()
    }

    func stop() {
        link?.invalidate(); link = nil; linkTarget = nil; lastTick = 0
    }

    func resumeFollowing(token: Int) {
        guard resumeToken != token else { return }
        resumeToken = token
        engine?.handle(.resumeFollowing)
        draw(delta: 0)
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
                var schema = 1
                var coreVersion = "0.5.2"
                var environment: AMLLRenderEnvironment
                var fps: Int
                var lineIDs: [String]
                var breaks: [[Int]]
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
                              breaks: heights.indices.map { makeLayout($0).breakOffsets }, frames: frames)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return try? encoder.encode(trace)
        }
    #endif

    private func syncLink() {
        guard window != nil, active else { stop(); return }
        guard link == nil else { return }
        let target = LinkTarget(); target.owner = self; linkTarget = target
        let link = CADisplayLink(target: target, selector: #selector(LinkTarget.tick(_:)))
        applyFrameRate(link)
        link.add(to: .main, forMode: .common); self.link = link
    }

    private func tick(_ link: CADisplayLink) {
        let start = CACurrentMediaTime()
        let delta = lastTick == 0 ? 0 : link.timestamp - lastTick
        lastTick = link.timestamp; draw(delta: delta)
        framesInSample += 1; sampleDuration += delta; sampleWork += CACurrentMediaTime() - start
        if sampleDuration >= 1 {
            measuredFPS = Double(framesInSample) / sampleDuration
            frameMilliseconds = sampleWork * 1000 / Double(framesInSample)
            framesInSample = 0; sampleDuration = 0; sampleWork = 0
        }
    }

    @objc private func pan(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began: lastTranslation = 0; engine?.handle(.beginBrowsing)
        case .changed:
            let value = gesture.translation(in: self).y
            engine?.handle(.browseBy(lastTranslation - value)); lastTranslation = value
        case .ended: engine?.handle(.endBrowsing(velocity: gesture.velocity(in: self).y))
        case .cancelled, .failed: engine?.handle(.endBrowsing(velocity: 0))
        default: break
        }
        draw(delta: 0)
    }
}

@MainActor
private final class AMLLNativeRow: UIView {
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
    private let auxiliary = CALayer()
    private var words: [WordPiece] = []
    private var characters: [CharacterPiece] = []
    private let maskWords: [AMLLWordMask.Word]
    private let sharpImage: UIImage
    private let nearBlurImage: UIImage
    private let farBlurImage: UIImage
    private let sharpAuxiliaryImage: UIImage
    private let nearBlurAuxiliaryImage: UIImage
    private let farBlurAuxiliaryImage: UIImage
    var onSeek: (() -> Void)?

    init(line: LyricLine, layout: AMLLCoreTextLayout, scale: CGFloat) {
        self.line = line; textLayout = layout
        let indexes = layout.maskWords.indices.filter { layout.maskWords[$0].width > 0 }
        maskWords = indexes.map { layout.maskWords[$0] }
        sharpImage = layout.raster(scale: scale)
        nearBlurImage = layout.raster(scale: scale, blurRadius: 2)
        farBlurImage = layout.raster(scale: scale, blurRadius: 5)
        sharpAuxiliaryImage = layout.raster(scale: scale, auxiliary: true)
        nearBlurAuxiliaryImage = layout.raster(scale: scale, auxiliary: true, blurRadius: 2)
        farBlurAuxiliaryImage = layout.raster(scale: scale, auxiliary: true, blurRadius: 5)
        super.init(frame: CGRect(origin: .zero, size: layout.size))
        base.contents = sharpImage.cgImage; base.contentsScale = scale; base.frame = bounds; layer.addSublayer(base)
        auxiliary.contents = sharpAuxiliaryImage.cgImage
        auxiliary.contentsScale = scale; auxiliary.frame = bounds; layer.addSublayer(auxiliary)
        var consumed: [Int: Double] = [:]
        for fragment in layout.fragments where fragment.rect.width > 0 {
            guard let maskIndex = indexes.firstIndex(of: fragment.wordIndex) else { continue }
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

        let nonEmptyWordIndexes = line.words.indices.filter {
            !line.words[$0].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let lastWordIndex = nonEmptyWordIndexes.last
        var characterConsumed: [Int: Double] = [:]
        var characterWordIndexes = Set<Int>()
        for fragment in layout.characterFragments where fragment.rect.width > 0 {
            guard let maskIndex = indexes.firstIndex(of: fragment.wordIndex) else { continue }
            let piece = CALayer()
            piece.frame = fragment.rect; piece.contents = sharpImage.cgImage; piece.contentsScale = scale
            piece.contentsRect = CGRect(x: fragment.rect.minX / layout.size.width, y: fragment.rect.minY / layout.size.height,
                                        width: fragment.rect.width / layout.size.width, height: fragment.rect.height / layout.size.height)
            let mask = CAGradientLayer(); mask.frame = piece.bounds
            mask.startPoint = CGPoint(x: fragment.rtl ? 1 : 0, y: 0.5); mask.endPoint = CGPoint(x: fragment.rtl ? 0 : 1, y: 0.5)
            piece.mask = mask; layer.addSublayer(piece)
            let word = line.words[fragment.wordIndex]
            let characterCount = max(1, word.text.count)
            let animation = AMLLSourceWordAnimation.emphasis(
                duration: word.end - word.start,
                delay: word.start - line.start,
                characterCount: characterCount,
                rubyCount: word.ruby?.count ?? word.romanWord?.count ?? 0,
                isLastWord: lastWordIndex == fragment.wordIndex,
                isBackground: line.isBackground
            ).dropFirst(fragment.characterIndex).first
            let advance = characterConsumed[fragment.wordIndex, default: 0]
            characters.append(.init(layer: piece, mask: mask, fragment: fragment, maskIndex: maskIndex,
                                    advance: advance, animation: animation))
            characterConsumed[fragment.wordIndex] = advance + fragment.rect.width
            characterWordIndexes.insert(fragment.wordIndex)
        }
        base.isHidden = !words.isEmpty
        for word in words where characterWordIndexes.contains(word.fragment.wordIndex) {
            word.layer.isHidden = true
        }
        isAccessibilityElement = true; accessibilityLabel = line.text
        accessibilityTraits = .button
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tap)))
    }

    required init?(coder _: NSCoder) {
        nil
    }

    override func accessibilityActivate() -> Bool {
        onSeek?(); return onSeek != nil
    }

    @objc private func tap() {
        onSeek?()
    }

    func apply(row: AMLLFrameState.Row, configuration: LyricsRenderConfiguration, motionEnabled: Bool) {
        let bright = row.brightAlpha, dark = row.darkAlpha
        let image: UIImage
        let auxiliaryImage: UIImage
        switch row.blur {
        case ..<0.5:
            image = sharpImage; auxiliaryImage = sharpAuxiliaryImage
        case ..<3.5:
            image = nearBlurImage; auxiliaryImage = nearBlurAuxiliaryImage
        default:
            image = farBlurImage; auxiliaryImage = farBlurAuxiliaryImage
        }
        base.contents = image.cgImage
        auxiliary.contents = auxiliaryImage.cgImage
        alpha = row.opacity * (line.isBackground ? 0.4 : 1)
        base.opacity = Float(words.isEmpty ? 1 : dark)
        let auxiliaryText = configuration.auxiliaryText(for: line)
        accessibilityLabel = ([line.text] + auxiliaryText).filter { !$0.isEmpty }.joined(separator: ", ")
        for entry in words {
            entry.layer.contents = image.cgImage
            guard !entry.layer.isHidden else { continue }
            let elapsed = row.wordClock.floatElapsed(wordStart: entry.fragment.word.start - line.start,
                                                     duration: entry.fragment.word.end - entry.fragment.word.start)
            let float = AMLLSourceWordAnimation.wordFloat(elapsed: elapsed, duration: entry.fragment.word.end - entry.fragment.word.start,
                                                          isBackground: line.isBackground)
            entry.layer.setAffineTransform(CGAffineTransform(translationX: 0, y: motionEnabled ? float * textLayout.font.pointSize : 0))
            let feather = textLayout.font.lineHeight * configuration.gradientWidth
            // Original mask WAAPI animations advance independently between enable/seek
            // events, pause with playback and retain their current time on disable.
            let edge = AMLLWordMask.edge(time: line.start + row.wordClock.time, index: entry.maskIndex, words: maskWords, feather: feather) - entry.advance
            let width = max(1, entry.fragment.rect.width)
            let start = edge / width, end = (edge + max(0.0001, feather)) / width
            entry.mask.colors = [UIColor.white.withAlphaComponent(bright).cgColor, UIColor.white.withAlphaComponent(dark).cgColor]
            entry.mask.locations = [0, 1]
            // Let the gradient extend beyond the fragment. Clamping stops to [0,1]
            // changes the feather slope when a word enters or leaves the mask.
            entry.mask.startPoint = CGPoint(x: entry.fragment.rtl ? 1 - start : start, y: 0.5)
            entry.mask.endPoint = CGPoint(x: entry.fragment.rtl ? 1 - end : end, y: 0.5)
            entry.layer.opacity = 1
        }
        for entry in characters {
            entry.layer.contents = image.cgImage
            let duration = max(0.001, entry.fragment.range.length > 0
                ? line.words[entry.fragment.wordIndex].end - line.words[entry.fragment.wordIndex].start : 0.001)
            let elapsed = row.wordClock.floatElapsed(
                wordStart: line.words[entry.fragment.wordIndex].start - line.start,
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
            let edge = AMLLWordMask.edge(time: line.start + row.wordClock.time, index: entry.maskIndex,
                                         words: maskWords, feather: feather) - entry.advance
            let width = max(1, entry.fragment.rect.width)
            let start = edge / width, end = (edge + max(0.0001, feather)) / width
            entry.mask.colors = [UIColor.white.withAlphaComponent(bright).cgColor, UIColor.white.withAlphaComponent(dark).cgColor]
            entry.mask.locations = [0, 1]
            entry.mask.startPoint = CGPoint(x: entry.fragment.rtl ? 1 - start : start, y: 0.5)
            entry.mask.endPoint = CGPoint(x: entry.fragment.rtl ? 1 - end : end, y: 0.5)
            entry.layer.opacity = 1
        }
    }
}
