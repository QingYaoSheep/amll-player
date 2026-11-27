import AVKit
import Observation
import SwiftUI

@MainActor
@Observable
final class DesktopLyricsController: NSObject {
    static let autoStartKey = "desktopLyrics.autoStart"

    private enum State { case stopped, starting, active, stopping }
    private var state = State.stopped
    var showsStartError = false
    var isOpen: Bool { state == .starting || state == .active }
    var isBusy: Bool { state == .starting || state == .stopping }
    let isSupported = AVPictureInPictureController.isPictureInPictureSupported()

    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private weak var sourceView: DesktopLyricsSourceView?
    @ObservationIgnored private var restorePlayer: (() -> Void)?
    @ObservationIgnored private var restoreCompletion: ((Bool) -> Void)?
    @ObservationIgnored private var restoreTimeout: Task<Void, Never>?
    @ObservationIgnored private var controller: AVPictureInPictureController?
    @ObservationIgnored private var possibility: NSKeyValueObservation?
    @ObservationIgnored private var producer: DesktopLyricsFrames?
    @ObservationIgnored private var renderTask: Task<Void, Never>?
    @ObservationIgnored private var startTimeout: Task<Void, Never>?
    @ObservationIgnored private var timebase: CMTimebase?
    @ObservationIgnored private var phase: ScenePhase = .inactive
    @ObservationIgnored private var autoStart = false
    @ObservationIgnored private var lyricsVisible = false
    @ObservationIgnored private var immersive = false
    @ObservationIgnored private var automaticAttempt = false
    @ObservationIgnored private var autoSuppressed = false
    @ObservationIgnored private var playbackState: PlaybackState?

    private struct PlaybackState: Equatable {
        var track: String?
        var playing: Bool
        var duration: Double
        var seekRevision: Int
        var canSeek: Bool
    }

    func attach(_ view: DesktopLyricsSourceView, model: AppModel, restore: @escaping () -> Void) {
        guard isSupported, view.window != nil, sourceView !== view,
              sourceView?.window == nil || state == .stopped else { return }
        sourceView = view
        self.model = model
        restorePlayer = restore
        if let layer = producer?.layer { view.install(layer) }
        completeRestore(restored: true)
    }

    func detach(_ view: DesktopLyricsSourceView) {
        guard sourceView === view else { return }
        sourceView = nil
        autoStart = false
        controller?.canStartPictureInPictureAutomaticallyFromInline = false
        if state == .stopped {
            restorePlayer = nil
            releaseIfIdle()
        }
    }

    func update(_ view: DesktopLyricsSourceView, phase: ScenePhase, autoStart: Bool,
                lyricsVisible: Bool, immersive: Bool) {
        guard sourceView === view else { return }
        let previous = self.phase
        self.phase = phase
        self.autoStart = autoStart
        self.lyricsVisible = lyricsVisible
        self.immersive = immersive
        if phase == .active && previous != .active { autoSuppressed = false }
        reevaluate()
        // AVKit normally starts during the scene transition. Handle devices
        // that haven't delivered the delegate callback by the background hop.
        if phase == .background, previous != .background, armed, state == .stopped,
           UIApplication.shared.applicationState == .background
        {
            requestStart(automatic: true)
        }
    }

    func playbackChanged() { reevaluate() }

    private var armed: Bool {
        autoStart && !autoSuppressed && lyricsVisible && sourceView?.window != nil
            && model?.playbackSnapshot?.isPlaying == true && model?.playbackSnapshot?.item != nil
    }

    private func reevaluate() {
        if armed && phase != .background { prepare() }
        controller?.canStartPictureInPictureAutomaticallyFromInline = armed && producer?.hasSubmittedFrame == true
        if state == .stopped { releaseIfIdle() }
        if producer != nil { startRendering() }
    }

    func toggle() {
        if state == .active {
            stop()
        } else if state == .stopped {
            requestStart(automatic: false)
        }
    }

    func stop() {
        guard state != .stopped else {
            tearDown()
            return
        }
        guard state != .stopping else { return }
        autoSuppressed = true
        controller?.canStartPictureInPictureAutomaticallyFromInline = false
        state = .stopping
        controller?.stopPictureInPicture()
        waitForCallback()
    }

    private func prepare() {
        guard let model, let sourceView, isSupported else { return }
        let aspect = model.desktopLyricsPreferences.settings.aspect
        if state == .stopped, let producer, producer.aspect != aspect { tearDown() }
        guard controller == nil else { return }
        do { try MusicAudioSession.preparePictureInPicture() } catch { return }
        let frames = DesktopLyricsFrames(aspect: aspect)
        let content = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: frames.layer,
                                                                 playbackDelegate: self)
        let pip = AVPictureInPictureController(contentSource: content)
        var clock: CMTimebase?
        if CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault, sourceClock: CMClockGetHostTimeClock(),
                                           timebaseOut: &clock) == noErr, let clock {
            frames.layer.controlTimebase = clock
            timebase = clock
        }
        producer = frames
        controller = pip
        sourceView.install(frames.layer)
        pip.delegate = self
        possibility = pip.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.startWhenPossible()
            }
        }
    }

    private func requestStart(automatic: Bool) {
        guard isSupported, sourceView?.window != nil, state == .stopped, model?.playbackSnapshot?.item != nil else {
            if !automatic { showsStartError = true }
            return
        }
        prepare()
        automaticAttempt = automatic
        guard controller != nil else { finish(failed: true); return }
        do { try MusicAudioSession.activatePictureInPicture() } catch { finish(failed: true); return }
        state = .starting
        if automatic { model?.setDesktopLyricsRunning(true) }
        _ = renderNextFrame()
        startRendering()
        startWhenPossible()
        waitForCallback()
    }

    @ObservationIgnored private var startRequested = false

    private func startWhenPossible() {
        guard state == .starting, !startRequested, let controller,
              producer?.hasSubmittedFrame == true, controller.isPictureInPicturePossible else { return }
        startRequested = true
        controller.startPictureInPicture()
    }

    private func waitForCallback() {
        startTimeout?.cancel()
        startTimeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            guard let self, state == .starting || state == .stopping else { return }
            if controller?.isPictureInPictureActive == true {
                state = .active
                model?.setDesktopLyricsRunning(true)
            } else {
                finish(failed: state == .starting)
            }
        }
    }

    private func startRendering() {
        guard renderTask == nil else { return }
        renderTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let delay = self?.renderNextFrame() else { break }
                do { try await Task.sleep(for: delay) } catch { break }
            }
        }
    }

    private func renderNextFrame() -> Duration? {
        guard let model, let producer else { return nil }
        if controller?.isPictureInPictureSuspended == true { return .milliseconds(200) }
        let started = ProcessInfo.processInfo.systemUptime
        var frame = model.lyricsPlaybackFrame()
        // PiP always follows the confirmed playback timeline.
        frame.progressDraft = nil
        frame.legacySeekPosition = nil
        updateTimebase(frame)
        producer.render(model: model, frame: frame, immersive: immersive,
                        animates: state != .stopped)
        if state == .stopped {
            controller?.canStartPictureInPictureAutomaticallyFromInline = armed && producer.hasSubmittedFrame
            return .milliseconds(200)
        }
        startWhenPossible()
        let interval = frame.playing || producer.isAnimating ? 1.0 / 60 : 0.1
        return .seconds(max(0.001, interval - (ProcessInfo.processInfo.systemUptime - started)))
    }

    private func updateTimebase(_ frame: LyricsPlaybackFrame) {
        let snapshot = frame.snapshot
        let state = PlaybackState(track: snapshot?.item?.uri, playing: frame.playing,
                                  duration: snapshot?.duration ?? 0, seekRevision: frame.seekRevision,
                                  canSeek: snapshot?.restrictions.canSeek == true && frame.pending == nil)
        if let timebase {
            let position = CMTime(seconds: frame.position, preferredTimescale: 600)
            let drift = abs(CMTimebaseGetTime(timebase).seconds - frame.position)
            if playbackState != state || drift > 0.25 {
                CMTimebaseSetRateAndAnchorTime(timebase, rate: frame.playing ? 1 : 0,
                                              anchorTime: position, immediateSourceTime: CMClockGetTime(CMClockGetHostTimeClock()))
            }
        }
        if playbackState != state {
            playbackState = state
            controller?.requiresLinearPlayback = !state.canSeek
            controller?.invalidatePlaybackState()
        }
    }

    private func finish(failed: Bool = false) {
        if failed && !automaticAttempt { showsStartError = true }
        autoSuppressed = true
        model?.setDesktopLyricsRunning(false)
        tearDown()
    }

    private func completeRestore(restored: Bool) {
        let completion = restoreCompletion
        restoreCompletion = nil
        restoreTimeout?.cancel(); restoreTimeout = nil
        completion?(restored)
    }

    private func releaseIfIdle() {
        if state == .stopped && !armed { tearDown() }
    }

    private func tearDown() {
        MusicAudioSession.releasePictureInPicture()
        state = .stopped
        startRequested = false
        automaticAttempt = false
        playbackState = nil
        startTimeout?.cancel(); startTimeout = nil
        renderTask?.cancel(); renderTask = nil
        possibility?.invalidate(); possibility = nil
        controller?.delegate = nil
        controller?.contentSource = nil
        controller = nil
        producer?.layer.removeFromSuperlayer()
        producer = nil
        timebase = nil
    }
}

extension DesktopLyricsController: @preconcurrency AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        guard controller === pictureInPictureController else { return }
        if state == .stopping { return }
        if state == .stopped { automaticAttempt = true }
        try? MusicAudioSession.activatePictureInPicture()
        state = .starting
        startRequested = true
        model?.setDesktopLyricsRunning(true)
        _ = renderNextFrame()
        waitForCallback()
    }

    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        guard controller === pictureInPictureController else { return }
        if state == .stopping {
            pictureInPictureController.stopPictureInPicture()
            return
        }
        state = .active
        startTimeout?.cancel(); startTimeout = nil
        model?.setDesktopLyricsRunning(true)
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    failedToStartPictureInPictureWithError _: any Error) {
        if controller === pictureInPictureController { finish(failed: true) }
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        if controller === pictureInPictureController { finish() }
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        guard controller === pictureInPictureController, let restorePlayer else { completionHandler(false); return }
        if sourceView?.window != nil { completionHandler(true); return }
        completeRestore(restored: false)
        restoreCompletion = completionHandler
        restorePlayer()
        restoreTimeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            self?.completeRestore(restored: false)
        }
    }
}

extension DesktopLyricsController: @preconcurrency AVPictureInPictureSampleBufferPlaybackDelegate {
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {
        guard controller === pictureInPictureController else { return }
        Task { [weak self] in await self?.model?.setDesktopLyricsPlayback(playing: playing) }
    }

    func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        guard controller === pictureInPictureController, let duration = model?.playbackSnapshot?.duration,
              duration.isFinite, duration > 0 else { return .invalid }
        return CMTimeRange(start: .zero, duration: CMTime(seconds: duration, preferredTimescale: 600))
    }

    func pictureInPictureControllerIsPlaybackPaused(_: AVPictureInPictureController) -> Bool {
        model?.playbackSnapshot?.isPlaying != true
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    didTransitionToRenderSize newRenderSize: CMVideoDimensions) {
        if controller === pictureInPictureController { producer?.resize(newRenderSize) }
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    skipByInterval skipInterval: CMTime, completion completionHandler: @escaping () -> Void) {
        guard controller === pictureInPictureController, let model, let snapshot = model.playbackSnapshot,
              snapshot.restrictions.canSeek, let track = snapshot.item?.uri, snapshot.duration.isFinite,
              snapshot.duration > 0, skipInterval.seconds.isFinite else {
            completionHandler()
            return
        }
        let target = min(snapshot.duration, max(0, model.progress() + skipInterval.seconds))
        Task {
            defer { completionHandler() }
            await model.seek(to: target, entry: .remote, trackURI: track)
        }
    }
}

@MainActor
final class DesktopLyricsSourceView: UIView {
    weak var displayLayer: AVSampleBufferDisplayLayer?
    var windowChanged: (() -> Void)?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        Task { @MainActor [weak self] in self?.windowChanged?() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer?.frame = bounds
        CATransaction.commit()
    }

    func install(_ displayLayer: AVSampleBufferDisplayLayer) {
        self.displayLayer = displayLayer
        displayLayer.removeFromSuperlayer()
        layer.addSublayer(displayLayer)
        setNeedsLayout()
        layoutIfNeeded()
    }
}

struct DesktopLyricsAnchor: UIViewRepresentable {
    let model: AppModel
    let phase: ScenePhase
    let autoStart: Bool
    let lyricsVisible: Bool
    let configuration: LyricsRenderConfiguration
    let restore: () -> Void

    func makeUIView(context _: Context) -> DesktopLyricsSourceView {
        let view = DesktopLyricsSourceView()
        view.isUserInteractionEnabled = false
        view.accessibilityElementsHidden = true
        return view
    }

    func updateUIView(_ view: DesktopLyricsSourceView, context _: Context) {
        let controller = model.desktopLyrics
        view.windowChanged = { [weak view, weak model] in
            guard let view, let model else { return }
            if view.window == nil {
                controller.detach(view)
                return
            }
            controller.attach(view, model: model, restore: restore)
            controller.update(view, phase: phase, autoStart: autoStart,
                              lyricsVisible: lyricsVisible,
                              immersive: ImmersiveLyricsLayout.isEnabled(configuration,
                                  isPhone: view.traitCollection.userInterfaceIdiom == .phone, viewport: view.bounds.size))
        }
        // The delegate may change observable state while arming AVKit.
        Task { @MainActor [weak view] in view?.windowChanged?() }
    }

}
