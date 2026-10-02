import AVFoundation
import MediaPlayer
import Observation
import SwiftUI

struct NetEaseQueueEntry: Identifiable, Codable, Equatable {
    var id = UUID()
    var item: MusicCatalogItem
}
struct NetEaseQueueState: Codable {
    var entries: [NetEaseQueueEntry] = []
    var currentID: UUID?
    var position = 0.0
    var shuffle = false
    var repeatMode: MusicRepeatMode = .off
    var shuffleOrder: [UUID]?
}

@MainActor @Observable final class NetEasePlayback: MusicPlaybackProviding {
    private(set) var queue = NetEaseQueueState()
    private(set) var actualQuality = ""
    private(set) var failure: String?
    var quality: NetEaseQuality {
        didSet { defaults.set(quality.rawValue, forKey: "netease.quality.v1") }
    }
    @ObservationIgnored let playbackSnapshots: AsyncStream<PlaybackSnapshot>
    @ObservationIgnored private let continuation: AsyncStream<PlaybackSnapshot>.Continuation
    @ObservationIgnored private let session: NetEaseSession
    @ObservationIgnored private let catalog: NetEaseCatalog
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var player = AVPlayer()
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var itemObservation: NSKeyValueObservation?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var commands: [(MPRemoteCommand, Any)] = []
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var selected = false
    @ObservationIgnored private var intentPlaying = false
    @ObservationIgnored private var revision: UInt64 = 0
    @ObservationIgnored private var account: String?
    @ObservationIgnored private var reloads = 0
    @ObservationIgnored private var artworkTask: Task<Void, Never>?
    @ObservationIgnored private var artworkURL: URL?
    @ObservationIgnored private var nowArtwork: MPMediaItemArtwork?
    @ObservationIgnored private var saveTicks = 0
    @ObservationIgnored private var lastPosition = 0.0
    @ObservationIgnored private var stallSeconds = 0
    var currentEntry: NetEaseQueueEntry? { queue.entries.first { $0.id == queue.currentID } }
    var displayedEntries: [NetEaseQueueEntry] {
        guard queue.shuffle, let order = queue.shuffleOrder else { return queue.entries }
        let entries = Dictionary(uniqueKeysWithValues: queue.entries.map { ($0.id, $0) })
        return order.compactMap { entries[$0] }
    }
    init(session: NetEaseSession, catalog: NetEaseCatalog, defaults: UserDefaults = .standard, player: AVPlayer = AVPlayer()) {
        self.session = session; self.catalog = catalog; self.defaults = defaults; self.player = player
        quality = defaults.string(forKey: "netease.quality.v1").flatMap(NetEaseQuality.init(rawValue:)) ?? .exhigh
        let s = AsyncStream<PlaybackSnapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
        playbackSnapshots = s.stream; continuation = s.continuation
    }
    deinit { timer?.cancel(); artworkTask?.cancel(); itemObservation?.invalidate(); continuation.finish() }
    func accountChanged() {
        let next = session.profile?.id
        guard account != next else { return }
        deselect(); queue = .init(); account = next; failure = nil; actualQuality = ""
        if let next, let data = defaults.data(forKey: "netease.queue.v1." + next),
           let saved = try? JSONDecoder().decode(NetEaseQueueState.self, from: data), saved.entries.count <= 10000 {
            queue = saved
        }
    }
    func start() {
        accountChanged(); selected = true
        guard timer == nil else { return }
        installNotifications()
        timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled, let self else { return }
                publish()
                let p = position
                if intentPlaying, player.currentItem != nil {
                    if abs(p - lastPosition) < 0.005 { stallSeconds += 1 } else { stallSeconds = 0 }
                    if stallSeconds >= 120 {
                        failure = "音源持续缓冲超过 30 秒，请重新播放。"
                        try? await pause()
                    }
                } else { stallSeconds = 0 }
                lastPosition = p
                saveTicks += 1
                if saveTicks >= 20 { saveTicks = 0; save() }
            }
        }
    }
    func stop() { deselect() }
    func deselect() {
        generation = UUID(); queue.position = position; intentPlaying = false; selected = false
        player.pause(); save(); removeCommands(); MusicAudioSession.releasePlayback()
        timer?.cancel(); timer = nil; itemObservation?.invalidate(); itemObservation = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }; observers.removeAll()
        player.replaceCurrentItem(with: nil)
        artworkTask?.cancel(); artworkTask = nil; artworkURL = nil; nowArtwork = nil
        publish()
    }
    func enterForeground() { if selected { start(); publish() } }
    func enterBackground() { save() } // Audio continues; snapshots also serve lock-screen metadata.
    func refresh() async throws { publish() }
    func play() async throws {
        guard selected, session.currentState.connected, currentEntry != nil else { throw MusicServiceError.noPlayback }
        if player.currentItem == nil || player.currentItem?.status == .failed { try await loadCurrent(position: queue.position, resetRetries: true) }
        else { try activate(); intentPlaying = true; player.play(); publish() }
    }
    func pause() async throws { generation = UUID(); intentPlaying = false; player.pause(); queue.position = position; save(); publish() }
    func seek(to target: TimeInterval) async throws {
        guard target.isFinite, target >= 0, currentEntry != nil else { throw MusicServiceError.noPlayback }
        if player.currentItem == nil { generation = UUID() }
        let epoch = generation
        let value = duration > 0 ? min(target, duration) : target
        if player.currentItem != nil { await player.seek(to: CMTime(seconds: value, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) }
        guard epoch == generation else { throw CancellationError() }
        queue.position = value; revision &+= 1; stallSeconds = 0; save(); publish()
    }
    func skipNext() async throws { try await advance(forward: true, automatic: false) }
    func skipPrevious() async throws {
        if position > 3 { try await seek(to: 0) } else { try await advance(forward: false, automatic: false) }
    }
    func play(item: MusicCatalogItem, context: MusicResourceID?, position: Int?) async throws {
        guard selected, item.service == .netease, let resource = context ?? item.resource else { throw CancellationError() }
        let epoch = generation, accountToken = session.currentState.contextID
        let songs = try await catalog.allSongs(resource)
        guard selected, epoch == generation, accountToken == session.currentState.contextID else { throw CancellationError() }
        let entries = songs.map { NetEaseQueueEntry(item: $0) }
        let index = position ?? (item.kind == .track ? songs.firstIndex { $0.spotifyID == item.spotifyID } ?? 0 : 0)
        guard entries.indices.contains(index) else { throw NetEaseError.unavailable }
        queue.entries = entries; queue.currentID = entries[index].id; queue.position = 0
        rebuildShuffleOrder()
        try await loadCurrent(position: 0, resetRetries: true)
    }
    func playShuffled(_ item: MusicCatalogItem) async throws {
        guard selected, item.service == .netease, let resource = item.resource else { throw CancellationError() }
        let epoch = generation, context = session.currentState.contextID
        let songs = try await catalog.allSongs(resource)
        guard selected, epoch == generation, context == session.currentState.contextID else { throw CancellationError() }
        guard !songs.isEmpty else { throw NetEaseError.unavailable }
        queue.entries = songs.map { NetEaseQueueEntry(item: $0) }
        queue.shuffle = true; queue.currentID = queue.entries.randomElement()?.id
        rebuildShuffleOrder()
        try await loadCurrent(position: 0, resetRetries: true)
    }
    func setShuffle(_ enabled: Bool) async throws { queue.shuffle = enabled; rebuildShuffleOrder(); save(); publish() }
    func setRepeat(_ mode: MusicRepeatMode) async throws { queue.repeatMode = mode; save(); publish() }
    func enqueue(_ item: MusicCatalogItem, next: Bool) async throws {
        guard item.service == .netease, item.kind == .track else { throw MusicServiceError.unsupportedOperation }
        let entry = NetEaseQueueEntry(item: item)
        if next, let index = queue.entries.firstIndex(where: { $0.id == queue.currentID }) { queue.entries.insert(entry, at: index + 1) }
        else { queue.entries.append(entry) }
        if queue.currentID == nil { queue.currentID = entry.id }
        if queue.shuffle {
            var order = queue.shuffleOrder ?? []
            if next, let index = order.firstIndex(where: { $0 == queue.currentID }) { order.insert(entry.id, at: index + 1) }
            else { order.append(entry.id) }
            queue.shuffleOrder = order
        }
        save(); publish()
    }
    func remove(at offsets: IndexSet) {
        let removing = offsets.filter { queue.entries.indices.contains($0) }
        let currentIndex = queue.entries.firstIndex { $0.id == queue.currentID }
        let removesCurrent = currentIndex.map { removing.contains($0) } ?? false
        if removesCurrent {
            generation = UUID(); intentPlaying = false; player.pause(); player.replaceCurrentItem(with: nil)
            itemObservation?.invalidate(); itemObservation = nil; queue.position = 0
            removeCommands(); MusicAudioSession.releasePlayback()
        }
        for i in removing.sorted(by: >) { queue.entries.remove(at: i) }
        if removesCurrent { queue.currentID = queue.entries.isEmpty ? nil : queue.entries[min(currentIndex ?? 0, queue.entries.count - 1)].id }
        let remaining = Set(queue.entries.map(\.id)); queue.shuffleOrder = queue.shuffleOrder?.filter { remaining.contains($0) }
        save(); publish()
    }
    func removeDisplayed(at offsets: IndexSet) {
        let entries = displayedEntries
        let ids = Set(offsets.compactMap { entries.indices.contains($0) ? entries[$0].id : nil })
        remove(at: IndexSet(queue.entries.indices.filter { ids.contains(queue.entries[$0].id) }))
    }
    func move(from offsets: IndexSet, to target: Int) {
        if queue.shuffle { queue.shuffleOrder?.move(fromOffsets: offsets, toOffset: target) }
        else { queue.entries.move(fromOffsets: offsets, toOffset: target) }
        save(); publish()
    }
    func selectEntry(_ id: UUID) async throws {
        guard queue.entries.contains(where: { $0.id == id }), selected else { throw CancellationError() }
        queue.currentID = id; try await loadCurrent(position: 0, resetRetries: true)
    }
    func clearAccount() {
        let old = account; deselect(); queue = .init(); account = nil
        if let old { defaults.removeObject(forKey: "netease.queue.v1." + old) }
    }
    private var position: Double {
        let time = player.currentItem == nil ? queue.position : player.currentTime().seconds
        return time.isFinite ? max(0, time) : queue.position
    }
    private var duration: Double { Double(currentEntry?.item.track?.durationMS ?? 0) / 1000 }
    private func activate() throws {
        try MusicAudioSession.acquirePlayback(); installCommands()
    }
    private func loadCurrent(position requested: Double, resetRetries: Bool) async throws {
        guard selected, let entry = currentEntry else { throw MusicServiceError.noPlayback }
        generation = UUID(); let epoch = generation; let context = session.currentState.contextID
        intentPlaying = false; player.pause(); player.replaceCurrentItem(with: nil)
        if resetRetries { reloads = 0 }
        queue.position = requested; actualQuality = ""; failure = nil; stallSeconds = 0; publish()
        do {
            let source = try await catalog.audio(entry.item.spotifyID, quality: quality)
            guard selected, generation == epoch, context == session.currentState.contextID else { throw CancellationError() }
            try activate()
            // No account cookie is attached to the independently returned CDN URL.
            let item = AVPlayerItem(url: source.url)
            itemObservation?.invalidate()
            player.replaceCurrentItem(with: item)
            itemObservation = item.observe(\.status, options: [.new]) { @Sendable [weak self, weak item] _, _ in
                Task { @MainActor in
                    guard let self, let item, self.selected, self.intentPlaying, self.player.currentItem === item else { return }
                    if item.status == .failed {
                        if self.reloads < 1 {
                            self.reloads += 1
                            do { try await self.loadCurrent(position: self.position, resetRetries: false) }
                            catch is CancellationError {} catch { self.fail(error) }
                        } else { self.fail(NetEaseError.unavailable) }
                    }
                }
            }
            actualQuality = source.level.isEmpty ? "音质未知" : (NetEaseQuality(rawValue: source.level)?.title ?? source.level)
            if !source.level.isEmpty, source.level != quality.rawValue { actualQuality += "（请求\(quality.title)，服务返回较低或不同音质）" }
            if requested > 0 { await player.seek(to: CMTime(seconds: requested, preferredTimescale: 600)) }
            guard selected, generation == epoch else { throw CancellationError() }
            revision &+= 1; intentPlaying = true; player.play(); save(); publish()
        } catch is CancellationError { throw CancellationError() }
        catch { guard generation == epoch else { throw CancellationError() }; fail(error); throw error }
    }
    private func advance(forward: Bool, automatic: Bool) async throws {
        guard selected, let index = queue.entries.firstIndex(where: { $0.id == queue.currentID }) else { throw MusicServiceError.noPlayback }
        let sourceEpoch = generation
        let entries = queue.entries
        if automatic, queue.repeatMode == .one { try await loadCurrent(position: 0, resetRetries: true); return }
        var indices: [Int]
        if queue.shuffle {
            let order = queue.shuffleOrder ?? entries.map(\.id)
            let current = order.firstIndex(of: entries[index].id) ?? 0
            var ids = forward ? Array(order.dropFirst(current + 1)) : Array(order.prefix(current).reversed())
            if queue.repeatMode == .all {
                ids += forward ? Array(order.prefix(current + 1)) : Array(order.dropFirst(current).reversed())
            }
            indices = ids.compactMap { id in entries.firstIndex { $0.id == id } }
        } else if forward {
            indices = Array(entries.indices.dropFirst(index + 1))
            if queue.repeatMode == .all { indices += Array(entries.indices.prefix(index + 1)) }
        } else {
            indices = Array(entries.indices.prefix(index).reversed())
            if queue.repeatMode == .all { indices += Array(entries.indices.dropFirst(index).reversed()) }
        }
        var expectedEpoch = sourceEpoch
        for i in indices {
            try Task.checkCancellation()
            guard selected, generation == expectedEpoch, queue.entries.contains(where: { $0.id == entries[i].id }) else { throw CancellationError() }
            queue.currentID = entries[i].id
            do { try await loadCurrent(position: 0, resetRetries: true); return }
            catch is CancellationError { throw CancellationError() }
            catch {
                if !automatic { throw error }
                guard let reason = error as? NetEaseError, [.unavailable, .restricted, .trialOnly].contains(reason) else { throw error }
                expectedEpoch = generation
            }
        }
        queue.currentID = entries[index].id
        try await pause()
        if automatic, !indices.isEmpty { failure = "队列中没有可播放的歌曲。" }
        publish()
    }
    private func rebuildShuffleOrder() {
        guard queue.shuffle else { queue.shuffleOrder = nil; return }
        let rest = queue.entries.map(\.id).filter { $0 != queue.currentID }.shuffled()
        queue.shuffleOrder = queue.currentID.map { [$0] + rest } ?? rest
    }
    private func fail(_ error: Error) {
        intentPlaying = false; player.pause(); failure = error.localizedDescription; save(); publish()
    }
    private func save() {
        guard let account else { return }
        var state = queue; state.position = position
        if let data = try? JSONEncoder().encode(state) { defaults.set(data, forKey: "netease.queue.v1." + account) }
    }
    private func publish() {
        let e = currentEntry?.item
        let item = e.map { v in PlaybackItem(id: v.spotifyID, uri: v.uri ?? "", title: v.name,
                                            artists: v.track?.artists.map(\.name) ?? [], albumTitle: v.track?.album?.name,
                                            artworkURL: v.artworkURL, duration: duration, isEpisode: false, isAdvertisement: false,
                                            service: .netease, catalogID: v.spotifyID) }
        let playing = intentPlaying && player.timeControlStatus == .playing
        let snapshot = PlaybackSnapshot(item: item, isPlaying: playing, position: position, duration: duration,
                                        device: nil, restrictions: .unrestricted, source: .nativeAudio,
                                        sampledAtUptime: ProcessInfo.processInfo.systemUptime, playbackRate: playing ? 1 : 0,
                                        positionRevision: revision, shuffleEnabled: queue.shuffle, repeatMode: queue.repeatMode)
        continuation.yield(snapshot)
        if selected, MusicAudioSession.ownsPlayback, let item {
            updateArtwork(item.artworkURL)
            var info: [String: Any] = [
                MPMediaItemPropertyTitle: item.title, MPMediaItemPropertyArtist: item.artistLine,
                MPMediaItemPropertyAlbumTitle: item.albumTitle ?? "", MPMediaItemPropertyPlaybackDuration: duration,
                MPNowPlayingInfoPropertyElapsedPlaybackTime: position, MPNowPlayingInfoPropertyPlaybackRate: playing ? 1 : 0,
            ]
            if let nowArtwork { info[MPMediaItemPropertyArtwork] = nowArtwork }
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        }
    }
    private func updateArtwork(_ url: URL?) {
        guard artworkURL != url else { return }
        artworkTask?.cancel(); artworkURL = url; nowArtwork = nil
        guard let url, let trusted = NetEaseDecoder.image(url.absoluteString) else { return }
        let entry = queue.currentID
        artworkTask = Task { [weak self] in
            // Independent ephemeral download never carries session cookies.
            let config = URLSessionConfiguration.ephemeral
            config.httpCookieStorage = nil; config.httpShouldSetCookies = false; config.timeoutIntervalForRequest = 15
            let download = URLSession(configuration: config)
            defer { download.invalidateAndCancel() }
            guard let (data, _) = try? await download.data(from: trusted), data.count <= 8 * 1024 * 1024,
                  !Task.isCancelled, let image = UIImage(data: data), let self,
                  selected, queue.currentID == entry, artworkURL == url else { return }
            nowArtwork = NetEaseNowPlayingArtwork.make(image)
            publish()
        }
    }
    private func installCommands() {
        guard commands.isEmpty else { return }
        let center = MPRemoteCommandCenter.shared()
        func command(_ c: MPRemoteCommand, _ action: @escaping @MainActor () async throws -> Void) {
            let target = c.addTarget { @Sendable [weak self] _ in
                Task { @MainActor in
                    guard let self, self.selected else { return }
                    do { try await action() } catch is CancellationError {} catch { self.fail(error) }
                }
                return .success
            }
            commands.append((c, target))
        }
        command(center.playCommand) { [weak self] in try await self?.play() }
        command(center.pauseCommand) { [weak self] in try await self?.pause() }
        command(center.nextTrackCommand) { [weak self] in try await self?.skipNext() }
        command(center.previousTrackCommand) { [weak self] in try await self?.skipPrevious() }
        command(center.togglePlayPauseCommand) { [weak self] in
            guard let self else { return }; if intentPlaying { try await pause() } else { try await play() }
        }
        let target = center.changePlaybackPositionCommand.addTarget { @Sendable [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let time = event.positionTime
            Task { @MainActor in
                guard let self, self.selected else { return }
                do { try await self.seek(to: time) } catch is CancellationError {} catch { self.fail(error) }
            }
            return .success
        }
        commands.append((center.changePlaybackPositionCommand, target))
    }
    private func removeCommands() {
        commands.forEach { $0.0.removeTarget($0.1) }; commands.removeAll()
        if MusicAudioSession.ownsPlayback { MPNowPlayingInfoCenter.default().nowPlayingInfo = nil }
    }
    /// Invalidates pending source/seek work as well as pausing ready audio.
    func suspendForInterruption() {
        guard selected else { return }
        generation = UUID(); intentPlaying = false; player.pause()
        queue.position = position
        // Stop republishing our metadata over another app after a system interruption.
        removeCommands(); MusicAudioSession.releasePlayback(); save(); publish()
    }
    private func resetAudioServices() {
        guard selected else { return }
        suspendForInterruption()
        player = AVPlayer(); itemObservation?.invalidate(); itemObservation = nil
        removeCommands(); MusicAudioSession.releasePlayback(); publish()
    }
    private func installNotifications() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] notification in
            let finishedID = (notification.object as? AVPlayerItem).map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
                guard let self, self.selected, let current = self.player.currentItem, finishedID == ObjectIdentifier(current) else { return }
                let epoch = self.generation
                Task { @MainActor in
                    guard self.selected, self.generation == epoch else { return }
                    do { try await self.advance(forward: true, automatic: true) }
                    catch is CancellationError {} catch { self.fail(error) }
                }
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] notification in
            let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            MainActor.assumeIsolated {
                if type == AVAudioSession.InterruptionType.began.rawValue { self?.suspendForInterruption() }
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] notification in
            let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            MainActor.assumeIsolated {
                if reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue { self?.suspendForInterruption() }
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.resetAudioServices() }
        })
    }
}
