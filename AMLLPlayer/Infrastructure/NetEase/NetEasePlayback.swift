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
    @TaskLocal private static var roomLease: UUID?
    private(set) var queue = NetEaseQueueState()
    private(set) var actualQuality = ""
    @ObservationIgnored private(set) var latestSnapshot: PlaybackSnapshot?
    private(set) var failure: String?
    private(set) var radio: NetEaseRadioState?
    private(set) var isStartingRadio = false
    private(set) var isRefillingRadio = false
    private(set) var radioFailure: String?
    var isPersonalFM: Bool { radio != nil }
    private(set) var listeningRoom: NetEaseListeningRoom?
    private(set) var roomQueue: [MusicCatalogItem] = []
    private(set) var roomBusy = false
    private(set) var roomNotice: String?
    var isListeningTogether: Bool { listeningRoom != nil }
    var canEditPersonalQueue: Bool { !isPersonalFM && !isListeningTogether }
    var roomAPI: NetEaseRoomAPI { .init(session: session) }
    @ObservationIgnored private var ordinaryBeforeRoom: NetEaseQueueState?
    @ObservationIgnored private var roomGeneration = UUID()
    @ObservationIgnored private var roomPolling: Task<Void, Never>?
    @ObservationIgnored private var roomSync: Task<Void, Never>?
    @ObservationIgnored private var roomSyncID = UUID()
    @ObservationIgnored private var roomPausedLocally = false
    @ObservationIgnored private var roomCommandSequence: Int64 = 0
    @ObservationIgnored private var unavailableRoomTrack: NetEaseRoomTrack?
    @ObservationIgnored private var radioGeneration = UUID()
    @ObservationIgnored private var radioTask: Task<Void, Never>?
    var quality: NetEaseQuality {
        didSet { defaults.set(quality.rawValue, forKey: "netease.quality.v1") }
    }
    var savedPlaybackModes: (shuffle: Bool, repeatMode: MusicRepeatMode) {
        let ordinary = ordinaryBeforeRoom ?? radio?.ordinary ?? queue
        return (ordinary.shuffle, ordinary.repeatMode)
    }
    @ObservationIgnored let playbackSnapshots: AsyncStream<PlaybackSnapshot>
    @ObservationIgnored private let continuation: AsyncStream<PlaybackSnapshot>.Continuation
    @ObservationIgnored private let session: NetEaseSession
    @ObservationIgnored private let catalog: NetEaseCatalog
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var player: AVPlayer
    @ObservationIgnored private let makeItem: (URL) -> AVPlayerItem
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var itemObservation: NSKeyValueObservation?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var commands: [(MPRemoteCommand, Any)] = []
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var seekOperation: UUID?
    @ObservationIgnored private var seekWaiter: NativeSeekAwaiter?
    @ObservationIgnored private var pendingSeekRequest: PlaybackSeekRequest?
    @ObservationIgnored private var lastSeekConfirmation: PlaybackSeekConfirmation?
    @ObservationIgnored private var resourceGeneration = UUID()
    @ObservationIgnored private let seekTimeout: Double
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
    init(session: NetEaseSession, catalog: NetEaseCatalog, defaults: UserDefaults = .standard, player: AVPlayer = AVPlayer(),
         makeItem: @escaping (URL) -> AVPlayerItem = { NetEasePlayback.makeAudioItem($0) }, seekTimeout: Double = 10) {
        self.session = session; self.catalog = catalog; self.defaults = defaults; self.player = player
        self.makeItem = makeItem; self.seekTimeout = seekTimeout
        quality = defaults.string(forKey: "netease.quality.v1").flatMap(NetEaseQuality.init(rawValue:)) ?? .exhigh
        let s = AsyncStream<PlaybackSnapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
        playbackSnapshots = s.stream; continuation = s.continuation
    }
    deinit {
        timer?.cancel(); radioTask?.cancel(); artworkTask?.cancel(); itemObservation?.invalidate()
        roomPolling?.cancel(); roomSync?.cancel(); continuation.finish()
    }
    func accountChanged() {
        let next = session.profile?.id
        guard account != next else { return }
        deselect(); queue = .init(); radio = nil; account = next; failure = nil; actualQuality = ""
        if let next, let data = defaults.data(forKey: "netease.queue.v1." + next),
           let saved = try? JSONDecoder().decode(NetEaseQueueState.self, from: data), saved.entries.count <= 10000 {
            queue = saved
        }
        if let next, let data = defaults.data(forKey: "netease.radio.v1." + next),
           let saved = try? JSONDecoder().decode(NetEaseRadioState.self, from: data), saved.isValid {
            radio = saved; queue = saved.radio
        }
    }
    func start() {
        accountChanged(); selected = true
        guard timer == nil else { return }
        installNotifications()
        resumeStoredRoom()
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
                        if isListeningTogether { pauseRoomLocally() }
                        else { try? await pause() }
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
        cancelRoomWork()
        if listeningRoom != nil { restoreOrdinaryPlayback(forgetRoom: false) }
        cancelRadioWork()
        PlaybackSeekDiagnostics.shared.record("media-deselected")
        generation = UUID(); cancelSeek(); queue.position = position; intentPlaying = false; selected = false
        player.pause(); save(); removeCommands(); MusicAudioSession.releasePlayback()
        timer?.cancel(); timer = nil; itemObservation?.invalidate(); itemObservation = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }; observers.removeAll()
        player.replaceCurrentItem(with: nil); lastSeekConfirmation = nil; resourceGeneration = UUID()
        artworkTask?.cancel(); artworkTask = nil; artworkURL = nil; nowArtwork = nil
        publish()
    }
    func enterForeground() {
        if selected {
            start()
            publish()
            Task { [weak self] in await self?.synchronizeRoom() }
        }
    }
    func enterBackground() { save() } // Audio continues; snapshots also serve lock-screen metadata.
    func refresh() async throws { publish() }
    func play() async throws {
        if let room = listeningRoom {
            if room.kind == .duet {
                try await sendRoomControl { room in
                    try await self.sendDuetCommand(room, "PLAY", playing: true, position: self.position)
                }
            }
            roomPausedLocally = false
            unavailableRoomTrack = nil
            await synchronizeRoom()
            return
        }
        guard selected, session.currentState.connected, currentEntry != nil else { throw MusicServiceError.noPlayback }
        if player.currentItem == nil || player.currentItem?.status == .failed { try await loadCurrent(position: queue.position, resetRetries: true) }
        else { try activate(); intentPlaying = true; player.play(); publish(); scheduleRadioRefill() }
    }
    func pause() async throws {
        if let room = listeningRoom {
            if room.kind == .duet {
                try await sendRoomControl { room in
                    try await self.sendDuetCommand(room, "PAUSE", playing: false, position: self.position)
                }
            } else { pauseRoomLocally() }
            return
        }
        cancelRadioWork(); generation = UUID(); cancelSeek(); intentPlaying = false; player.pause()
        queue.position = position; save(); publish()
    }
    static func makeAudioItem(_ url: URL) -> AVPlayerItem {
        // FLAC may otherwise estimate byte offsets while reporting the requested time.
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        return AVPlayerItem(asset: asset)
    }
    func seek(to target: TimeInterval) async throws {
        let request = PlaybackSeekRequest(id: UUID(), service: .netease, sourceGeneration: generation,
                                          trackURI: currentEntry?.item.uri ?? "", target: target, entry: .remote,
                                          requestedAt: ProcessInfo.processInfo.systemUptime)
        _ = try await seek(request)
    }
    func seek(_ request: PlaybackSeekRequest) async throws -> PlaybackSeekResult {
        if listeningRoom != nil {
            guard roomRestrictions.canSeek, request.trackURI == currentEntry?.item.uri,
                  request.target.isFinite, request.target >= 0 else { throw NetEaseRoomError.controlsUnavailable }
            let target = duration > 0 ? min(duration, request.target) : request.target
            return try await withRoomOperation {
                guard let room = self.listeningRoom else { throw NetEaseRoomError.roomChanged }
                try await self.sendDuetCommand(room, "seek", playing: self.intentPlaying, position: target)
                return try await self.seekLocally(request)
            }
        }
        return try await seekLocally(request)
    }
    private func seekLocally(_ request: PlaybackSeekRequest) async throws -> PlaybackSeekResult {
        guard request.target.isFinite, request.target >= 0, let entry = currentEntry,
              entry.item.uri == request.trackURI, let item = player.currentItem else { throw MusicServiceError.noPlayback }
        cancelSeek()
        let epoch = generation, resource = resourceGeneration
        let value = duration > 0 ? min(request.target, duration) : request.target
        let waiter = NativeSeekAwaiter()
        seekOperation = request.id; seekWaiter = waiter; pendingSeekRequest = request; lastSeekConfirmation = nil
        publish(seekAnchor: position)
        PlaybackSeekDiagnostics.shared.record("media-seek", request: request, actual: position, resource: resource,
                                              duration: item.duration.seconds.isFinite ? item.duration.seconds : nil,
                                              seekableStart: item.seekableTimeRanges.first?.timeRangeValue.start.seconds,
                                              seekableEnd: item.seekableTimeRanges.last.map { CMTimeRangeGetEnd($0.timeRangeValue).seconds })
        do {
            let finished = try await waiter.wait(seconds: seekTimeout) {
                player.seek(to: CMTime(seconds: value, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { finished in
                    Task { @MainActor [weak self, weak item] in
                        guard let self, let item, self.generation == epoch, self.seekOperation == request.id,
                              self.player.currentItem === item, self.currentEntry?.id == entry.id else {
                            waiter.finish(.failure(CancellationError())); return
                        }
                        waiter.finish(.success(finished))
                    }
                }
            }
            guard epoch == generation, seekOperation == request.id, player.currentItem === item,
                  currentEntry?.id == entry.id else { throw CancellationError() }
            guard finished else { throw CancellationError() }
            let actual = position, sampledAt = ProcessInfo.processInfo.systemUptime
            guard abs(actual - value) <= 0.25 else { throw PlaybackSeekError.inaccurate }
            let confirmation = PlaybackSeekConfirmation(requestID: request.id, sourceGeneration: request.sourceGeneration,
                                                        resourceGeneration: resource, trackURI: request.trackURI,
                                                        target: value, position: actual, sampledAt: sampledAt)
            seekOperation = nil; seekWaiter = nil; pendingSeekRequest = nil
            lastSeekConfirmation = confirmation
            queue.position = actual; revision &+= 1; stallSeconds = 0; save()
            let snapshot = publish(confirmation: confirmation)!
            PlaybackSeekDiagnostics.shared.record("media-confirmed", request: request, actual: actual, resource: resource, revision: revision)
            return PlaybackSeekResult(confirmation: confirmation, snapshot: snapshot)
        } catch {
            if epoch == generation, seekOperation == request.id {
                cancelSeek(); publish()
                PlaybackSeekDiagnostics.shared.record(error is CancellationError ? "media-cancelled" : "media-failed",
                                                      request: request, actual: position, resource: resource)
            }
            throw error
        }
    }
    private func cancelSeek() {
        guard seekOperation != nil || seekWaiter != nil else { return }
        seekOperation = nil; pendingSeekRequest = nil
        seekWaiter?.finish(.failure(CancellationError())); seekWaiter = nil
        player.currentItem?.cancelPendingSeeks()
    }
    func skipNext() async throws {
        if isListeningTogether { try await skipRoom(forward: true) }
        else { try await advance(forward: true, automatic: false) }
    }
    func skipPrevious() async throws {
        if isListeningTogether { try await skipRoom(forward: false); return }
        if position > 3 { try await seek(to: 0) } else { try await advance(forward: false, automatic: false) }
    }
    func play(item: MusicCatalogItem, context: MusicResourceID?, position: Int?) async throws {
        if isListeningTogether { try await recommendRoomSong(item); return }
        guard selected, item.service == .netease, let resource = context ?? item.resource else { throw CancellationError() }
        let epoch = generation, accountToken = session.currentState.contextID
        let songs = try await catalog.allSongs(resource)
        guard selected, !isListeningTogether, epoch == generation, accountToken == session.currentState.contextID else { throw CancellationError() }
        let entries = songs.map { NetEaseQueueEntry(item: $0) }
        let index = position ?? (item.kind == .track ? songs.firstIndex { $0.spotifyID == item.spotifyID } ?? 0 : 0)
        guard entries.indices.contains(index) else { throw NetEaseError.unavailable }
        leaveRadioForNewSelection()
        queue.entries = entries; queue.currentID = entries[index].id; queue.position = 0
        rebuildShuffleOrder()
        try await loadCurrent(position: 0, resetRetries: true)
    }
    func playShuffled(_ item: MusicCatalogItem) async throws {
        guard !isListeningTogether else { throw NetEaseRoomError.controlsUnavailable }
        guard selected, item.service == .netease, let resource = item.resource else { throw CancellationError() }
        let epoch = generation, context = session.currentState.contextID
        let songs = try await catalog.allSongs(resource)
        guard selected, !isListeningTogether, epoch == generation, context == session.currentState.contextID else { throw CancellationError() }
        guard !songs.isEmpty else { throw NetEaseError.unavailable }
        leaveRadioForNewSelection()
        queue.entries = songs.map { NetEaseQueueEntry(item: $0) }
        queue.shuffle = true; queue.currentID = queue.entries.randomElement()?.id
        rebuildShuffleOrder()
        try await loadCurrent(position: 0, resetRetries: true)
    }
    func setShuffle(_ enabled: Bool) async throws {
        guard !isListeningTogether else { throw NetEaseRoomError.controlsUnavailable }
        guard !isPersonalFM else { throw NetEaseRadioError.modesUnavailable }
        queue.shuffle = enabled; rebuildShuffleOrder(); save(); publish()
    }
    func setRepeat(_ mode: MusicRepeatMode) async throws {
        guard !isListeningTogether else { throw NetEaseRoomError.controlsUnavailable }
        guard !isPersonalFM else { throw NetEaseRadioError.modesUnavailable }
        queue.repeatMode = mode; save(); publish()
    }
    func enqueue(_ item: MusicCatalogItem, next: Bool) async throws {
        if isListeningTogether { try await recommendRoomSong(item); return }
        guard !isPersonalFM else { throw NetEaseRadioError.modesUnavailable }
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
        guard canEditPersonalQueue else { return }
        let removing = offsets.filter { queue.entries.indices.contains($0) }
        let currentIndex = queue.entries.firstIndex { $0.id == queue.currentID }
        let removesCurrent = currentIndex.map { removing.contains($0) } ?? false
        if removesCurrent {
            generation = UUID(); cancelSeek(); intentPlaying = false; player.pause(); player.replaceCurrentItem(with: nil)
            itemObservation?.invalidate(); itemObservation = nil; queue.position = 0
            lastSeekConfirmation = nil; resourceGeneration = UUID()
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
        guard canEditPersonalQueue else { return }
        if queue.shuffle { queue.shuffleOrder?.move(fromOffsets: offsets, toOffset: target) }
        else { queue.entries.move(fromOffsets: offsets, toOffset: target) }
        save(); publish()
    }
    func selectEntry(_ id: UUID) async throws {
        guard !isListeningTogether else { throw NetEaseRoomError.controlsUnavailable }
        guard queue.entries.contains(where: { $0.id == id }), selected else { throw CancellationError() }
        queue.currentID = id
        if isPersonalFM { NetEaseRadioState.trimHistory(&queue) }
        try await loadCurrent(position: 0, resetRetries: true)
    }
    func clearAccount() {
        let old = account; deselect(); queue = .init(); radio = nil; account = nil
        if let old { defaults.removeObject(forKey: "netease.queue.v1." + old) }
        if let old { defaults.removeObject(forKey: "netease.radio.v1." + old) }
        if let old { defaults.removeObject(forKey: "netease.room.v1." + old) }
    }
    private var position: Double {
        let time = player.currentItem == nil ? queue.position : player.currentTime().seconds
        return time.isFinite ? max(0, time) : queue.position
    }
    private var duration: Double { Double(currentEntry?.item.track?.durationMS ?? 0) / 1000 }
    private func activate() throws {
        try MusicAudioSession.acquirePlayback(); installCommands()
    }
    func startPersonalFM() async throws {
        guard !isListeningTogether else { throw NetEaseRoomError.controlsUnavailable }
        guard selected, session.currentState.connected else { throw NetEaseError.expired }
        if isPersonalFM { try await play(); return }
        guard !isStartingRadio else { return }
        cancelRadioWork()
        let token = radioGeneration, context = session.currentState.contextID
        isStartingRadio = true; radioFailure = nil
        defer { if token == radioGeneration { isStartingRadio = false } }
        do {
            let songs = try await catalog.personalFMBatch()
            guard token == radioGeneration, selected, context == session.currentState.contextID else { throw CancellationError() }
            var candidate = NetEaseQueueState()
            var record = NetEaseRadioState(ordinary: queue, radio: candidate)
            guard record.append(songs, to: &candidate) > 0 else { throw NetEaseRadioError.noRecommendations }
            var prepared: NetEaseAudioSource?
            for entry in candidate.entries.prefix(5) {
                do {
                    prepared = try await catalog.audio(entry.item.spotifyID, quality: quality)
                    candidate.currentID = entry.id; break
                } catch let error as NetEaseError where [.unavailable, .restricted, .trialOnly].contains(error) { continue }
            }
            guard token == radioGeneration, selected, context == session.currentState.contextID else { throw CancellationError() }
            guard let prepared else { throw NetEaseRadioError.unavailableBatch }
            // Capture the ordinary position at the actual handoff, not before the request.
            record.ordinary = queue
            record.ordinary.position = position
            save(); radio = record; queue = candidate
            try await loadCurrent(position: 0, resetRetries: true, preparedSource: prepared)
        } catch is CancellationError { throw CancellationError() }
        catch {
            guard token == radioGeneration else { throw CancellationError() }
            radioFailure = error.localizedDescription; throw error
        }
    }

    func exitPersonalFM() {
        guard let record = radio else { cancelRadioWork(); return }
        cancelRadioWork(); generation = UUID(); cancelSeek(); intentPlaying = false; player.pause()
        player.replaceCurrentItem(with: nil); itemObservation?.invalidate(); itemObservation = nil
        removeCommands(); MusicAudioSession.releasePlayback()
        queue = record.ordinary; radio = nil; radioFailure = nil; failure = nil; actualQuality = ""
        lastSeekConfirmation = nil; resourceGeneration = UUID(); revision &+= 1
        if let account { defaults.removeObject(forKey: "netease.radio.v1." + account) }
        save(); publish()
    }
    private func leaveRadioForNewSelection() {
        cancelRadioWork()
        if let record = radio {
            queue.shuffle = record.ordinary.shuffle; queue.repeatMode = record.ordinary.repeatMode
        }
        radio = nil; radioFailure = nil
        if let account { defaults.removeObject(forKey: "netease.radio.v1." + account) }
    }
    private func cancelRadioWork() {
        radioGeneration = UUID(); radioTask?.cancel(); radioTask = nil
        isStartingRadio = false; isRefillingRadio = false
    }
    private func scheduleRadioRefill() {
        guard isPersonalFM, selected, intentPlaying, NetEaseRadioState.pendingCount(queue) <= 2,
              radioTask == nil, radioFailure == nil else { return }
        _ = makeRadioRefillTask()
    }
    private func makeRadioRefillTask() -> Task<Void, Never> {
        if let radioTask { return radioTask }
        let token = radioGeneration
        let work = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.refillRadio(expected: token)
        }
        radioTask = work
        return work
    }
    func retryPersonalFM() async {
        guard isPersonalFM, selected else { return }
        radioFailure = nil
        // An explicit retry is allowed while paused; it never starts audio by itself.
        await makeRadioRefillTask().value
    }
    private func refillRadio(expected token: UUID) async {
        guard token == radioGeneration, !Task.isCancelled, isPersonalFM, selected, !isRefillingRadio else { return }
        let context = session.currentState.contextID
        isRefillingRadio = true
        defer { if token == radioGeneration { isRefillingRadio = false; radioTask = nil } }
        for attempt in 0..<3 {
            do {
                try Task.checkCancellation()
                if attempt > 0 { try await Task.sleep(for: .seconds(Double(attempt))) }
                let songs = try await catalog.personalFMBatch()
                try Task.checkCancellation()
                guard selected, token == radioGeneration, context == session.currentState.contextID, var record = radio else { return }
                let count = record.append(songs, to: &queue)
                radio = record
                if count > 0 { radioFailure = nil; save(); return }
                if attempt == 2 { radioFailure = NetEaseRadioError.noRecommendations.localizedDescription }
            } catch is CancellationError { return }
            catch {
                guard token == radioGeneration else { return }
                // Do not retry authentication or server throttling failures.
                if let error = error as? NetEaseError, error == .expired || error == .rateLimited {
                    radioFailure = error.localizedDescription; return
                }
                if attempt == 2 { radioFailure = error.localizedDescription }
            }
        }
    }
    private func advanceRadio(forward: Bool) async throws {
        guard selected, isPersonalFM else { throw MusicServiceError.noPlayback }
        let token = radioGeneration
        for _ in 0..<5 {
            guard token == radioGeneration, let index = queue.entries.firstIndex(where: { $0.id == queue.currentID }) else { throw CancellationError() }
            let expectedEntry = queue.currentID
            if forward && index + 1 >= queue.entries.count {
                if radioFailure == nil { await makeRadioRefillTask().value }
                guard token == radioGeneration else { throw CancellationError() }
            }
            guard queue.currentID == expectedEntry else { throw CancellationError() }
            let target = forward ? index + 1 : index - 1
            guard queue.entries.indices.contains(target) else {
                if !forward { try await seek(to: 0); return }
                try await pause(); radioFailure = radioFailure ?? NetEaseRadioError.noRecommendations.localizedDescription
                throw NetEaseRadioError.noRecommendations
            }
            queue.currentID = queue.entries[target].id
            NetEaseRadioState.trimHistory(&queue)
            do { try await loadCurrent(position: 0, resetRetries: true); return }
            catch let error as NetEaseError where [.unavailable, .restricted, .trialOnly].contains(error) { continue }
        }
        try await pause(); radioFailure = NetEaseRadioError.unavailableBatch.localizedDescription
        throw NetEaseRadioError.unavailableBatch
    }
    private func loadCurrent(position requested: Double, resetRetries: Bool, preparedSource: NetEaseAudioSource? = nil,
                             autoplay: Bool = true) async throws {
        guard selected, let entry = currentEntry else { throw MusicServiceError.noPlayback }
        generation = UUID(); cancelSeek(); let epoch = generation; let context = session.currentState.contextID
        intentPlaying = false; player.pause(); player.replaceCurrentItem(with: nil)
        if resetRetries { reloads = 0 }
        queue.position = requested; actualQuality = ""; failure = nil; stallSeconds = 0; publish()
        do {
            let source: NetEaseAudioSource
            if let preparedSource { source = preparedSource }
            else { source = try await catalog.audio(entry.item.spotifyID, quality: quality) }
            guard selected, generation == epoch, context == session.currentState.contextID else { throw CancellationError() }
            try activate()
            // No account cookie is attached to the independently returned CDN URL.
            let item = makeItem(source.url)
            resourceGeneration = UUID(); lastSeekConfirmation = nil
            PlaybackSeekDiagnostics.shared.record("media-installed", resource: resourceGeneration,
                                                  codec: ["flac", "mp3", "m4a", "aac"].contains(source.url.pathExtension.lowercased())
                                                    ? source.url.pathExtension.lowercased() : "unknown")
            itemObservation?.invalidate()
            player.replaceCurrentItem(with: item)
            itemObservation = item.observe(\.status, options: [.new]) { @Sendable [weak self, weak item] _, _ in
                Task { @MainActor in
                    guard let self, let item, self.selected, self.intentPlaying, self.player.currentItem === item else { return }
                    if item.status == .failed {
                        if self.reloads < 1 {
                            self.reloads += 1
                            do {
                                if self.isListeningTogether { await self.synchronizeRoom() }
                                else { try await self.loadCurrent(position: self.position, resetRetries: false) }
                            }
                            catch is CancellationError {} catch { self.fail(error) }
                        } else { self.fail(NetEaseError.unavailable) }
                    }
                }
            }
            actualQuality = source.level.isEmpty ? "音质未知" : (NetEaseQuality(rawValue: source.level)?.title ?? source.level)
            if !source.level.isEmpty, source.level != quality.rawValue { actualQuality += "（请求\(quality.title)，服务返回较低或不同音质）" }
            if requested > 0 {
                let waiter = NativeSeekAwaiter(); seekWaiter = waiter
                let finished = try await waiter.wait(seconds: seekTimeout) {
                    player.seek(to: CMTime(seconds: requested, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { finished in
                        Task { @MainActor in waiter.finish(.success(finished)) }
                    }
                }
                seekWaiter = nil
                guard finished else { throw CancellationError() }
            }
            guard selected, generation == epoch else { throw CancellationError() }
            revision &+= 1; intentPlaying = autoplay
            if autoplay { player.play() }
            save(); publish(); scheduleRadioRefill()
        } catch is CancellationError { throw CancellationError() }
        catch { guard generation == epoch else { throw CancellationError() }; cancelSeek(); fail(error); throw error }
    }
    private func advance(forward: Bool, automatic: Bool) async throws {
        if isPersonalFM { try await advanceRadio(forward: forward); return }
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
        var state = ordinaryBeforeRoom ?? queue
        if ordinaryBeforeRoom == nil { state.position = position }
        if var radio {
            radio.radio = state
            self.radio = radio
            if let data = try? JSONEncoder().encode(radio) { defaults.set(data, forKey: "netease.radio.v1." + account) }
            return
        }
        if let data = try? JSONEncoder().encode(state) { defaults.set(data, forKey: "netease.queue.v1." + account) }
    }
    @discardableResult
    private func publish(seekAnchor: Double? = nil, confirmation: PlaybackSeekConfirmation? = nil) -> PlaybackSnapshot? {
        // The 250ms sampler can run while AVFoundation is still seeking.
        // Never expose its temporary times as ordinary playback corrections.
        guard seekOperation == nil || seekAnchor != nil else { return nil }
        let position = confirmation?.position ?? seekAnchor ?? self.position
        let e = currentEntry?.item
        let item = e.map { v in PlaybackItem(id: v.spotifyID, uri: v.uri ?? "", title: v.name,
                                            artists: v.track?.artists.map(\.name) ?? [], albumTitle: v.track?.album?.name,
                                            artworkURL: v.artworkURL, duration: duration, isEpisode: false, isAdvertisement: false,
                                            service: .netease, catalogID: v.spotifyID) }
        let playing = seekOperation == nil && intentPlaying && player.timeControlStatus == .playing
        var snapshot = PlaybackSnapshot(item: item, isPlaying: playing, position: position, duration: duration,
                                        device: nil, restrictions: roomRestrictions, source: .nativeAudio,
                                        sampledAtUptime: confirmation?.sampledAt ?? ProcessInfo.processInfo.systemUptime, playbackRate: playing ? 1 : 0,
                                        positionRevision: revision, shuffleEnabled: queue.shuffle, repeatMode: queue.repeatMode)
        snapshot.seekConfirmation = lastSeekConfirmation
        snapshot.seekRequest = pendingSeekRequest
        latestSnapshot = snapshot
        continuation.yield(snapshot)
        if selected, MusicAudioSession.ownsPlayback, let item {
            let commands = MPRemoteCommandCenter.shared()
            commands.playCommand.isEnabled = snapshot.restrictions.canResume
            commands.pauseCommand.isEnabled = snapshot.restrictions.canPause
            commands.togglePlayPauseCommand.isEnabled = playing ? snapshot.restrictions.canPause : snapshot.restrictions.canResume
            commands.changePlaybackPositionCommand.isEnabled = snapshot.restrictions.canSeek
            commands.nextTrackCommand.isEnabled = snapshot.restrictions.canSkipNext
            commands.previousTrackCommand.isEnabled = snapshot.restrictions.canSkipPrevious
            updateArtwork(item.artworkURL)
            var info: [String: Any] = [
                MPMediaItemPropertyTitle: item.title, MPMediaItemPropertyArtist: item.artistLine,
                MPMediaItemPropertyAlbumTitle: item.albumTitle ?? "", MPMediaItemPropertyPlaybackDuration: duration,
                MPNowPlayingInfoPropertyElapsedPlaybackTime: position, MPNowPlayingInfoPropertyPlaybackRate: playing ? 1 : 0,
            ]
            if let nowArtwork { info[MPMediaItemPropertyArtwork] = nowArtwork }
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        }
        return snapshot
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
                    do { try await action() } catch is CancellationError {}
                    catch { if self.isListeningTogether { self.roomNotice = error.localizedDescription } else { self.fail(error) } }
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
                do { try await self.seek(to: time) } catch is CancellationError {}
                catch { if self.isListeningTogether { self.roomNotice = error.localizedDescription } else { self.fail(error) } }
            }
            return .success
        }
        commands.append((center.changePlaybackPositionCommand, target))
    }
    private func removeCommands() {
        commands.forEach { command, target in
            command.removeTarget(target)
            command.isEnabled = true
        }
        commands.removeAll()
        if MusicAudioSession.ownsPlayback { MPNowPlayingInfoCenter.default().nowPlayingInfo = nil }
    }
    /// Invalidates pending source/seek work as well as pausing ready audio.
    func suspendForInterruption() {
        guard selected else { return }
        if isListeningTogether { roomPausedLocally = true }
        cancelRadioWork()
        PlaybackSeekDiagnostics.shared.record("media-interrupted")
        generation = UUID(); cancelSeek(); intentPlaying = false; player.pause()
        queue.position = position
        // Stop republishing our metadata over another app after a system interruption.
        removeCommands(); MusicAudioSession.releasePlayback(); save(); publish()
    }
    private func resetAudioServices() {
        guard selected else { return }
        suspendForInterruption()
        player = AVPlayer(); itemObservation?.invalidate(); itemObservation = nil
        lastSeekConfirmation = nil; resourceGeneration = UUID()
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
                    if let room = self.listeningRoom {
                        if room.kind == .duet, room.isHost { try? await self.skipRoom(forward: true) }
                        else { self.intentPlaying = false; self.publish() }
                        return
                    }
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

extension NetEasePlayback {
    private var roomRestrictions: PlaybackRestrictions {
        guard let room = listeningRoom else { return .unrestricted }
        let track = room.clock?.track
        let ordered = room.tracks
        let index = ordered.firstIndex { $0.id == track?.id }
        let next = room.kind == .group ? track?.businessID != nil :
            index.map { $0 + 1 < ordered.count } ?? !ordered.isEmpty
        return .init(canPause: track != nil, canResume: track != nil,
                     canSeek: room.kind == .duet && track?.id == currentEntry?.item.spotifyID && player.currentItem != nil,
                     canSkipNext: next, canSkipPrevious: room.kind == .duet && (index ?? 0) > 0)
    }

    var roomShareLink: NetEaseRoomInvite? {
        guard let room = listeningRoom, let inviter = session.profile?.id else { return nil }
        return .init(kind: room.kind, room: room.id, inviter: inviter,
                     song: room.clock?.track.id ?? currentEntry?.item.spotifyID ?? ordinaryBeforeRoom?.entries.first?.item.spotifyID)
    }

    var duetChatPeer: NetEaseRoomMember? {
        guard let viewer = session.profile?.id else { return nil }
        return listeningRoom?.chattingPeer(viewer: viewer)
    }

    func createRoom(_ kind: NetEaseRoomKind) async throws {
        try await withRoomOperation {
            if try await self.recoverRoom() { return }
            try await self.startNewRoom(kind)
        }
        await synchronizeRoom()
    }

    private func startNewRoom(_ kind: NetEaseRoomKind) async throws {
        let track = currentEntry?.item.spotifyID
        if kind == .group {
            guard let track else { throw NetEaseRoomError.selectSong }
            _ = try await catalog.audio(track, quality: quality)
        }
        try checkRoomContext()
        var room = try await roomAPI.create(kind, track: track)
        try checkRoomContext()
        room.isHost = true
        enterRoom(room)
        if kind == .duet, let track {
            let queue = ordinaryBeforeRoom?.entries.map(\.item.spotifyID) ?? []
            let ids = queue.contains(track) ? Array(queue.prefix(300)) : [track]
            try await roomAPI.replaceDuetQueue(room, ids: ids.contains(track) ? ids : [track],
                                               version: nextRoomSequence())
            try await sendDuetCommand(room, "GOTO", song: track, playing: true, position: 0)
        }
    }

    enum FriendRoomAction {
        case openRoom, sent(NetEaseRoomInvite), needsConfirmation(NetEaseListeningRoom), deliveryUnknown(NetEaseRoomInvite)
    }

    func listenWithFriend(_ peer: NetEaseRoomMember, replacing expected: NetEaseListeningRoom? = nil) async throws -> FriendRoomAction {
        let result: FriendRoomAction = try await withRoomOperation {
            guard let viewer = session.profile?.id, NetEaseRoomInvite.numericID(peer.id) != nil, peer.id != viewer else {
                throw NetEaseMessageError.invalidRecipient
            }
            if listeningRoom == nil { _ = try await recoverRoom() }
            if let room = listeningRoom {
                if room.chattingPeer(viewer: viewer)?.id == peer.id { return .openRoom }
                let isEmptyDuet = room.kind == .duet && room.isHost && room.members.allSatisfy { $0.id == viewer }
                if !isEmptyDuet {
                    guard expected?.id == room.id, expected?.kind == room.kind else { return .needsConfirmation(room) }
                    try await roomAPI.leave(room)
                    try checkRoomContext()
                    restoreOrdinaryPlayback(forgetRoom: true)
                }
            }
            if listeningRoom == nil { try await startNewRoom(.duet) }
            guard let invite = roomShareLink else { throw NetEaseRoomError.roomChanged }
            try checkRoomContext()
            do {
                try await roomAPI.sendInvite(invite, to: peer)
            } catch where NetEaseMessageError.mayHaveDelivered(error) {
                return .deliveryUnknown(invite)
            }
            return .sent(invite)
        }
        await synchronizeRoom()
        return result
    }

    func joinRoom(_ invite: NetEaseRoomInvite, replacing: Bool) async throws {
        try await withRoomOperation {
            _ = try await self.recoverRoom()
            if let room = self.listeningRoom {
                if room.kind == invite.kind, room.id == invite.room { return }
                guard replacing else { throw NetEaseRoomError.roomChanged }
                try await self.roomAPI.leave(room)
                try self.checkRoomContext()
                self.restoreOrdinaryPlayback(forgetRoom: true)
            }
            let joined = try await self.roomAPI.join(invite)
            try self.checkRoomContext()
            self.enterRoom(joined)
        }
        await synchronizeRoom()
    }

    func refreshListeningRoom() async throws {
        if listeningRoom == nil { _ = try await withRoomOperation { try await self.recoverRoom() } }
        await synchronizeRoom()
    }

    func leaveRoom() async throws {
        try await withRoomOperation {
            guard let room = self.listeningRoom else { return }
            do { try await self.roomAPI.leave(room) }
            catch NetEaseError.request(488) {}
            try self.checkRoomContext()
            self.restoreOrdinaryPlayback(forgetRoom: true)
        }
    }

    private func enterRoom(_ room: NetEaseListeningRoom) {
        var backup = radio?.ordinary ?? queue
        if radio == nil { backup.position = position }
        ordinaryBeforeRoom = backup
        leaveRadioForNewSelection()
        clearRoomAudio()
        queue = .init()
        listeningRoom = room
        roomPausedLocally = false
        if let account { defaults.set(room.kind.rawValue, forKey: "netease.room.v1." + account) }
        save()
        publish()
        scheduleRoomPolling()
    }

    private func restoreOrdinaryPlayback(forgetRoom: Bool) {
        roomPolling?.cancel()
        roomPolling = nil
        roomSync?.cancel()
        roomSync = nil
        clearRoomAudio()
        queue = ordinaryBeforeRoom ?? .init()
        ordinaryBeforeRoom = nil
        listeningRoom = nil
        roomQueue = []
        roomPausedLocally = false
        unavailableRoomTrack = nil
        if forgetRoom, let account { defaults.removeObject(forKey: "netease.room.v1." + account) }
        save()
        publish()
    }

    private func clearRoomAudio() {
        generation = UUID()
        cancelSeek()
        intentPlaying = false
        player.pause()
        player.replaceCurrentItem(with: nil)
        itemObservation?.invalidate()
        itemObservation = nil
        lastSeekConfirmation = nil
        actualQuality = ""
        failure = nil
        resourceGeneration = UUID()
        revision &+= 1
        removeCommands()
        MusicAudioSession.releasePlayback()
    }

    private func pauseRoomLocally() {
        roomPausedLocally = true
        generation = UUID()
        cancelSeek()
        intentPlaying = false
        player.pause()
        queue.position = position
        publish()
    }

    private func cancelRoomWork() {
        roomGeneration = UUID()
        roomPolling?.cancel()
        roomPolling = nil
        roomSync?.cancel()
        roomSync = nil
        roomSyncID = UUID()
        roomBusy = false
        roomNotice = nil
    }

    private func resumeStoredRoom() {
        guard let account, defaults.string(forKey: "netease.room.v1." + account) != nil else { return }
        scheduleRoomPolling()
    }

    private func recoverRoom() async throws -> Bool {
        if listeningRoom != nil { return true }
        let preferred = account.flatMap { defaults.string(forKey: "netease.room.v1." + $0) }
            .flatMap(NetEaseRoomKind.init(rawValue:))
        let kinds: [NetEaseRoomKind] = preferred == .group ? [.group, .duet] : [.duet, .group]
        let api = roomAPI
        for kind in kinds {
            if let room = try await api.current(kind) {
                try checkRoomContext()
                enterRoom(room)
                return true
            }
            try checkRoomContext()
        }
        if let account { defaults.removeObject(forKey: "netease.room.v1." + account) }
        return false
    }

    private func scheduleRoomPolling() {
        guard roomPolling == nil else { return }
        let token = roomGeneration
        roomPolling = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.roomGeneration == token, self.selected else { return }
                if self.listeningRoom == nil {
                    do {
                        let recovered = try await self.withRoomOperation { try await self.recoverRoom() }
                        if !recovered {
                            if self.roomGeneration == token { self.roomPolling = nil }
                            return
                        }
                    } catch is CancellationError { return }
                    catch { self.roomNotice = error.localizedDescription }
                }
                await self.synchronizeRoom()
                let wait = self.listeningRoom?.heartbeat ?? 5
                try? await Task.sleep(for: .seconds(wait))
            }
        }
    }

    private func synchronizeRoom() async {
        guard !roomBusy, let room = listeningRoom else { return }
        if let roomSync { await roomSync.value; return }
        let token = UUID()
        roomSyncID = token
        let task = Task { [weak self] in
            guard let self else { return }
            defer { if self.roomSyncID == token { self.roomSync = nil } }
            await self.refreshRoomSnapshot(room)
        }
        roomSync = task
        await task.value
    }

    private func refreshRoomSnapshot(_ room: NetEaseListeningRoom) async {
        do {
            var next = try await roomAPI.update(room, position: position, playing: intentPlaying)
            try checkRoomContext()
            guard listeningRoom?.id == room.id else { throw CancellationError() }
            if let last = room.clock?.version, let version = next.clock?.version, version < last { return }
            next.isHost = room.isHost || next.isHost
            listeningRoom = next
            try await applyRoomClock(next.clock)
            let ids = next.tracks.prefix(50).map(\.id)
            if ids != roomQueue.map(\.spotifyID) {
                let items = try? await catalog.songs(ids)
                try checkRoomContext()
                if let items { roomQueue = items }
            }
            roomNotice = nil
        } catch is CancellationError {}
        catch NetEaseRoomError.ended {
            guard !Task.isCancelled else { return }
            restoreOrdinaryPlayback(forgetRoom: true)
            roomNotice = NetEaseRoomError.ended.localizedDescription
        } catch NetEaseError.request(488) {
            guard !Task.isCancelled else { return }
            restoreOrdinaryPlayback(forgetRoom: true)
            roomNotice = NetEaseRoomError.ended.localizedDescription
        } catch { if !Task.isCancelled { roomNotice = error.localizedDescription } }
    }

    private func applyRoomClock(_ clock: NetEaseRoomClock?) async throws {
        guard let clock else {
            if currentEntry != nil { clearRoomAudio(); queue = .init(); publish() }
            return
        }
        let shouldPlay = clock.playing && !roomPausedLocally
        let target = clock.target(at: ProcessInfo.processInfo.systemUptime)
        if currentEntry?.item.spotifyID != clock.track.id || player.currentItem == nil || player.currentItem?.status == .failed {
            guard unavailableRoomTrack != clock.track else { return }
            if currentEntry?.item.spotifyID != clock.track.id {
                clearRoomAudio()
                queue = .init()
                publish()
            }
            do {
                let cached = roomQueue.first { $0.spotifyID == clock.track.id }
                let item: MusicCatalogItem?
                if let cached { item = cached }
                else { item = try await catalog.songs([clock.track.id]).first }
                try checkRoomContext()
                guard let item, item.availability != .restricted else { throw NetEaseError.restricted }
                let entry = NetEaseQueueEntry(item: item)
                queue.entries = [entry]; queue.currentID = entry.id
                let corrected = min(max(0, duration - 0.1), clock.target(at: ProcessInfo.processInfo.systemUptime))
                try await loadCurrent(position: duration > 0 ? corrected : target, resetRetries: true, autoplay: shouldPlay)
                unavailableRoomTrack = nil
            } catch let error as NetEaseError where [.restricted, .trialOnly, .unavailable].contains(error) {
                unavailableRoomTrack = clock.track
                fail(error)
                throw error
            }
            return
        }
        let bounded = duration > 0 ? min(target, max(0, duration - 0.1)) : target
        if !shouldPlay { player.pause(); intentPlaying = false }
        if !roomPausedLocally, abs(position - bounded) > (clock.forceSync || !intentPlaying ? 0.25 : 1.0),
           let uri = currentEntry?.item.uri {
            _ = try await seekLocally(.init(id: UUID(), service: .netease, sourceGeneration: generation,
                                            trackURI: uri, target: bounded, entry: .remote,
                                            requestedAt: ProcessInfo.processInfo.systemUptime))
        }
        try checkRoomContext()
        if shouldPlay, !intentPlaying { try activate(); intentPlaying = true; player.play() }
        publish()
    }

    func recommendRoomSong(_ item: MusicCatalogItem) async throws {
        guard item.service == .netease, item.kind == .track, let id = NetEaseRoomInvite.numericID(item.spotifyID) else {
            throw NetEaseRoomError.controlsUnavailable
        }
        try await sendRoomControl { room in
            if room.kind == .group {
                try await self.roomAPI.groupSong(room, song: .init(id: id, businessID: nil), next: false)
            } else {
                var ids = room.tracks.map(\.id)
                if !ids.contains(id) { ids.append(id) }
                try await self.roomAPI.replaceDuetQueue(room, ids: ids, version: self.nextRoomSequence())
                if room.clock == nil {
                    try self.checkRoomContext()
                    try await self.sendDuetCommand(room, "GOTO", song: id, playing: true, position: 0)
                }
            }
        }
    }

    private func skipRoom(forward: Bool) async throws {
        try await sendRoomControl { room in
            if room.kind == .group {
                guard forward, let track = room.clock?.track, track.businessID != nil else {
                    throw NetEaseRoomError.controlsUnavailable
                }
                try await self.roomAPI.groupSong(room, song: track, next: true)
            } else {
                let current = room.tracks.firstIndex { $0.id == room.clock?.track.id } ?? (forward ? -1 : 0)
                let index = current + (forward ? 1 : -1)
                guard room.tracks.indices.contains(index) else { throw NetEaseRoomError.controlsUnavailable }
                try await self.sendDuetCommand(room, "GOTO", song: room.tracks[index].id, playing: true, position: 0)
            }
        }
    }

    private func sendDuetCommand(_ room: NetEaseListeningRoom, _ action: String, song: String? = nil,
                                 playing: Bool, position: Double) async throws {
        guard let song = song ?? room.clock?.track.id else { throw NetEaseRoomError.selectSong }
        try await roomAPI.duetCommand(room, action, song: song, former: room.clock?.track.id,
                                      position: position, playing: playing, sequence: nextRoomSequence())
        try checkRoomContext()
    }

    private func nextRoomSequence() -> Int64 {
        roomCommandSequence = max(roomCommandSequence + 1, Int64(Date().timeIntervalSince1970 * 1000))
        return roomCommandSequence
    }

    private func sendRoomControl(_ action: (NetEaseListeningRoom) async throws -> Void) async throws {
        try await withRoomOperation {
            guard let room = self.listeningRoom else { throw NetEaseRoomError.roomChanged }
            try await action(room)
        }
        await synchronizeRoom()
    }

    private func checkRoomContext() throws {
        try Task.checkCancellation()
        if let lease = Self.roomLease, lease != roomGeneration { throw CancellationError() }
        guard selected, session.currentState.connected, account == session.profile?.id else { throw CancellationError() }
    }

    private func withRoomOperation<T>(_ action: () async throws -> T) async throws -> T {
        guard selected, session.currentState.connected else { throw NetEaseError.expired }
        guard !roomBusy else { throw NetEaseRoomError.roomChanged }
        let token = roomGeneration, context = session.currentState.contextID
        roomBusy = true
        defer { if token == roomGeneration { roomBusy = false } }
        if let current = roomSync {
            current.cancel()
            await current.value
        }
        guard token == roomGeneration, context == session.currentState.contextID else { throw CancellationError() }
        do {
            let result = try await Self.$roomLease.withValue(token) { try await action() }
            guard token == roomGeneration, context == session.currentState.contextID else { throw CancellationError() }
            roomNotice = nil
            return result
        } catch {
            guard token == roomGeneration, context == session.currentState.contextID else { throw CancellationError() }
            throw error
        }
    }
}
