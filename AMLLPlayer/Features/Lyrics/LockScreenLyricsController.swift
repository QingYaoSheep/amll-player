@preconcurrency import ActivityKit
import Foundation
import UIKit

@MainActor final class LockScreenLyricsController {
    static let preferenceKey = "lockScreenLyrics.enabled"
    static let translationKey = "lockScreenLyrics.translation"
    static let romanizationKey = "lockScreenLyrics.romanization"
    static let keepAliveKey = "lockScreenLyrics.keepAlive"
    private typealias Attributes = LockScreenLyricsAttributes
    private typealias State = Attributes.ContentState
    private typealias LyricsActivity = Activity<Attributes>

    private var activity: LyricsActivity?
    private var activityObserver: Task<Void, Never>?
    private var pulse: Task<Void, Never>?
    private var writeTask: Task<Void, Never>?
    private var endingTask: Task<Void, Never>?
    private var artworkTask: Task<Void, Never>?
    private var pending: ActivityContent<State>?
    private var sent: State?
    private var lastCandidate: State?
    private var session = LockScreenLyricsSession()
    private var trackID: String?
    private var trackNumber = 0
    private var documentRevision: Int?
    private var timeline: LockScreenLyricsTimeline?
    private var lastSeekRevision: Int?
    private var lastOffset: Double?
    private var artworkURL: URL?
    private var backdrop: Data?
    private var retryAfter = 0.0
    private var checkedRestoredActivities = false
    private var externalSampleAfter: Double?

    deinit {
        activityObserver?.cancel()
        pulse?.cancel()
        writeTask?.cancel()
        artworkTask?.cancel()
    }

    func synchronize(_ model: AppModel) {
        if !checkedRestoredActivities {
            checkedRestoredActivities = true
            let restored = LyricsActivity.activities
            if !restored.isEmpty {
                endingTask = Task { [weak self] in
                    for activity in restored { await activity.end(nil, dismissalPolicy: .immediate) }
                    self?.endingTask = nil
                }
            }
        }
        guard model.lockScreenLyricsEnabled else {
            pulse?.cancel()
            pulse = nil
            stopSession()
            return
        }
        refresh(model)
        guard pulse == nil, needsPulse(model) else { return }
        pulse = Task { [weak self, weak model] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
                guard let self, let model else { return }
                refresh(model)
                if !needsPulse(model) {
                    pulse = nil
                    return
                }
            }
        }
    }

    private func needsPulse(_ model: AppModel) -> Bool {
        activity != nil || (model.lockScreenLyricsInForeground && model.playbackSnapshot?.isPlaying == true && !session.dismissed)
    }

    func stopSession() {
        session.ended()
        resetTrack(nil)
        endActivity()
    }

    func requireNewExternalSample() {
        externalSampleAfter = ProcessInfo.processInfo.systemUptime
    }

    private func resetTrack(_ id: String?) {
        guard trackID != id else { return }
        trackID = id
        trackNumber &+= 1
        documentRevision = nil
        timeline = nil
        lastSeekRevision = nil
        lastOffset = nil
        retryAfter = 0
        artworkTask?.cancel()
        artworkTask = nil
        artworkURL = nil
        backdrop = nil
    }

    private func refresh(_ model: AppModel) {
        let uptime = ProcessInfo.processInfo.systemUptime
        let frame = model.lyricsPlaybackFrame(at: uptime)
        guard let snapshot = frame.snapshot, let item = snapshot.item, let identity = TrackIdentity(item) else {
            stopSession()
            return
        }
        guard model.lyrics.settings.enabled, ActivityAuthorizationInfo().areActivitiesEnabled else {
            endActivity()
            return
        }
        resetTrack(identity.spotifyID)
        let foreground = model.lockScreenLyricsInForeground
        let trusted = LockScreenLyricsState.canFollow(snapshot, externalSampleAfter: externalSampleAfter, uptime: uptime)
        let coordinator = model.lyrics
        let document = coordinator.track?.spotifyID == identity.spotifyID ? coordinator.document : nil
        let revision = document == nil ? nil : coordinator.documentRevision
        let documentChanged = documentRevision != revision
        if documentChanged {
            documentRevision = revision
            timeline = document.map(LockScreenLyricsTimeline.init(document:))
        }

        if activity == nil {
            guard endingTask == nil, uptime >= retryAfter, frame.pending == nil,
                  session.canStart(foreground: foreground, playing: snapshot.isPlaying, synchronized: trusted) else { return }
        }

        loadArtwork(item.artworkURL)
        let displayed = lastCandidate
        let lyricsUnavailable = timeline?.isEmpty == true || (document == nil && [.instrumental, .notFound, .failed].contains(coordinator.status))
        var state = State(track: trackNumber, title: item.title, status: lyricsUnavailable ? .unavailable : .loading, backdrop: backdrop)
        let offset = coordinator.effectiveOffset
        let holdingSeek = frame.pending?.trackURI == item.uri && displayed?.track == trackNumber
        let readyTimeline = lyricsUnavailable ? nil : timeline
        let reanchored = trusted && !holdingSeek && readyTimeline != nil && (lastSeekRevision != frame.seekRevision || lastOffset != offset)
        let nextCue: Double?
        if holdingSeek, trusted, let displayed {
            state = displayed
            state.backdrop = backdrop
            readyTimeline?.updateFrozenAuxiliary(&state)
            nextCue = nil
        } else {
            nextCue = LockScreenLyricsState.project(&state, timeline: readyTimeline, position: frame.position, offset: offset,
                                                    playing: snapshot.isPlaying, trusted: trusted, previous: displayed)
        }
        LockScreenLyricsState.applyAuxiliaryPreferences(&state, translation: model.lockScreenLyricsShowsTranslation,
                                                        romanization: model.lockScreenLyricsShowsRomanization)
        if trusted && !holdingSeek && readyTimeline != nil {
            lastSeekRevision = frame.seekRevision
            lastOffset = offset
        }
        guard state != lastCandidate || reanchored else { return }
        lastCandidate = state
        state.scrollsForward = LockScreenLyricsState.isForward(sent, state, discontinuity: documentChanged || reanchored)
        let fitted = LockScreenLyricsState.fitted(state)
        // Keep an honest snapshot if the app is suspended before the next expected cue.
        let boundary = nextCue ?? (snapshot.duration > frame.position ? snapshot.duration : frame.position + 15)
        let staleDate: Date? = if state.status == .playing || state.status == .loading || state.status == .unavailable {
            Date().addingTimeInterval(state.status == .loading ? 20 : max(0, boundary - frame.position) / max(0.1, snapshot.playbackRate) + 2)
        } else { nil }
        let content = ActivityContent(state: fitted, staleDate: staleDate)
        if let activity {
            submit(content, to: activity)
        } else {
            do {
                let live = try LyricsActivity.request(attributes: Attributes(), content: content)
                activity = live
                sent = content.state
                observe(live, model: model)
            } catch {
                lastCandidate = nil
                retryAfter = uptime + 10
            }
        }
    }

    private func observe(_ live: LyricsActivity, model: AppModel) {
        activityObserver = Task { [weak self, weak model] in
            for await state in live.activityStateUpdates {
                guard let self, activity?.id == live.id else { return }
                if state == .dismissed || state == .ended {
                    session.dismiss()
                    endActivity()
                    if let model { model.handleLockScreenLyricsEnded() }
                    return
                }
            }
        }
    }

    private func submit(_ content: ActivityContent<State>, to live: LyricsActivity) {
        pending = content
        guard writeTask == nil else { return }
        writeTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, activity?.id == live.id, let content = pending {
                pending = nil
                sent = content.state
                await live.update(content)
            }
            writeTask = nil
        }
    }

    private func endActivity() {
        guard let live = activity else { return }
        activity = nil
        activityObserver?.cancel()
        activityObserver = nil
        pending = nil
        sent = nil
        lastCandidate = nil
        let lastWrite = writeTask
        lastWrite?.cancel()
        endingTask = Task { [weak self] in
            await lastWrite?.value
            await live.end(nil, dismissalPolicy: .immediate)
            self?.endingTask = nil
        }
    }

    var needsBackgroundLyrics: Bool { activity != nil }

    private func loadArtwork(_ url: URL?) {
        if #available(iOS 26, *) { return }
        guard artworkURL != url else { return }
        artworkTask?.cancel()
        artworkURL = url
        backdrop = nil
        guard let url else { return }
        let expectedTrack = trackNumber
        artworkTask = Task { [weak self] in
            guard let data = try? await ArtworkImageData.load(url), !Task.isCancelled,
                  let result = await DesktopLyricsArtworkWorker.shared.makeBackdrop(from: data, size: .init(width: 48, height: 24)),
                  let self, !Task.isCancelled, expectedTrack == trackNumber, artworkURL == url else { return }
            let preview = UIImage(cgImage: result.blurred)
            backdrop = preview.jpegData(compressionQuality: 0.30)
        }
    }
}
