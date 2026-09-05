import Foundation
import Observation

@MainActor
@Observable
final class LyricsCoordinator {
    enum Status: String { case idle, disabled, loading, ready, cached, stale, instrumental, notFound, failed }
    private(set) var track: TrackIdentity?
    private(set) var document: LyricsDocument?
    private(set) var status: Status = .idle
    private(set) var settings: LyricsSettings
    private(set) var selection = LyricsSelection()
    private(set) var errors: [LyricsSource: String] = [:]
    private(set) var cacheWarning: String?
    private(set) var savedAt: Date?
    private(set) var isLoading = false
    private(set) var candidates: [LyricsSource: [LyricCandidate]] = [:]
    private(set) var searchErrors: [LyricsSource: String] = [:]
    private(set) var searching: Set<LyricsSource> = []
    private(set) var preview: LyricsDocument?
    private(set) var previewError: String?
    private(set) var isPreviewing = false
    private(set) var appleStatus = ""
    private(set) var isTestingApple = false

    let apple: AppleLyricsProvider?
    @ObservationIgnored private let providers: [any LyricsProvider]
    @ObservationIgnored private let cache: any LyricsCacheProviding
    @ObservationIgnored private let settingsStore: LyricsSettingsStore
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var searchTasks: [Task<Void, Never>] = []
    @ObservationIgnored private var previewTask: Task<Void, Never>?
    @ObservationIgnored private var epoch = UUID()
    @ObservationIgnored private var searchEpoch = UUID()
    @ObservationIgnored private var previewEpoch = UUID()
    @ObservationIgnored private var previewPayload: LyricsPayload?
    @ObservationIgnored private var previewTrackID: String?
    @ObservationIgnored private var foreground = true

    init(providers: [any LyricsProvider], cache: any LyricsCacheProviding, settingsStore: LyricsSettingsStore = LyricsSettingsStore(), apple: AppleLyricsProvider? = nil) {
        self.providers = providers; self.cache = cache; self.settingsStore = settingsStore; self.apple = apple
        settings = settingsStore.load()
    }

    static func live() -> LyricsCoordinator {
        let http = LyricsHTTP(), credentials = AppleLyricsCredentials()
        let apple = AppleLyricsProvider(http: http, credentials: credentials)
        let cache: any LyricsCacheProviding
        var failed = false
        do { cache = try SwiftDataLyricsCache() }
        catch { cache = MemoryLyricsCache(); failed = true }
        let coordinator = LyricsCoordinator(providers: [apple, QQLyricsProvider(http: http), NetEaseLyricsProvider(http: http)], cache: cache, apple: apple)
        if failed {
            coordinator.cacheWarning = LyricsError.cache.localizedDescription
        }
        return coordinator
    }

    deinit { loadTask?.cancel(); searchTasks.forEach { $0.cancel() }; previewTask?.cancel() }

    func update(track next: TrackIdentity?) {
        if track?.spotifyID == next?.spotifyID {
            // App Remote may omit ISRC after a Web API sample. Preserve known metadata.
            let enriched = track?.isrc == nil && next?.isrc != nil
            if var next {
                next.isrc = next.isrc ?? track?.isrc; track = next
            }
            if enriched, selection.candidate == nil, isLoading {
                reload(force: true)
            }
            return
        }
        cancelLoad(); cancelSearch(); track = next
        document = nil; savedAt = nil; errors = [:]; selection = LyricsSelection(); status = .idle
        guard let next else { return }
        do { selection = try cache.selection(for: next.spotifyID) }
        catch { cacheWarning = LyricsError.cache.localizedDescription }
        reload()
    }

    func setForeground(_ value: Bool) {
        guard foreground != value else { return }
        foreground = value
        if value {
            reload()
        } else {
            cancelLoad(); cancelSearch(); apple?.invalidateDiscovery()
        }
    }

    func updateSettings(_ value: LyricsSettings) {
        let value = value.validated()
        guard value != settings else { return }
        let reordered = settings.priority != value.priority
        do { try settingsStore.save(value); settings = value; cancelSearch(); reload(force: reordered) }
        catch { cacheWarning = LyricsError.cache.localizedDescription }
    }

    private func cancelLoad() {
        epoch = UUID(); loadTask?.cancel(); loadTask = nil; isLoading = false
    }

    func reload(force: Bool = false) {
        cancelLoad()
        guard let track else { return }
        guard settings.enabled else { status = .disabled; document = nil; return }
        let config = settings, ticket = epoch, manual = selection.candidate
        let order = manual.map { [$0.source] } ?? config.priority
        if config.cacheEnabled {
            for source in order {
                do {
                    if let entry = try cache.read(track: track, source: source, settings: config),
                       manual == nil || entry.document.candidate.id == manual?.id
                    {
                        document = entry.document; savedAt = entry.savedAt
                        let fresh = entry.isFresh(days: config.refreshDays)
                        status = fresh || manual != nil ? .cached : .stale
                        if !force, fresh || manual != nil {
                            return
                        }
                        break
                    }
                } catch { cacheWarning = LyricsError.cache.localizedDescription }
            }
        }
        guard foreground else { return }
        isLoading = true; errors = [:]
        if document == nil {
            status = .loading
        }
        loadTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if epoch == ticket {
                    isLoading = false
                }
            }
            var allNotFound = true
            for source in order {
                guard let provider = providers.first(where: { $0.source == source }) else { continue }
                do {
                    try Task.checkCancellation()
                    if source == .apple, let apple {
                        _ = try apple.credentials.mediaToken()
                    }
                    let matches: [LyricCandidate] = if let manual {
                        [manual]
                    } else {
                        try await provider.search(track: track, query: "", settings: config).filter { $0.score >= 35 }
                    }
                    guard !matches.isEmpty else { throw LyricsError.notFound }
                    var failure: Error = LyricsError.notFound
                    for candidate in matches.prefix(3) {
                        do {
                            let payload = try await provider.lyrics(candidate: candidate, settings: config)
                            let parsed = try await Self.parse(payload, candidate: candidate, duration: track.duration)
                            guard epoch == ticket, foreground, !Task.isCancelled else { return }
                            install(payload, document: parsed, track: track, settings: config)
                            return
                        } catch is CancellationError { return }
                        catch { failure = error }
                    }
                    throw failure
                } catch is CancellationError { return }
                catch {
                    guard epoch == ticket, !Task.isCancelled else { return }
                    errors[source] = Self.safeError(error)
                    if error as? LyricsError != .notFound {
                        allNotFound = false
                    }
                }
            }
            guard epoch == ticket else { return }
            status = document != nil ? .stale : allNotFound ? .notFound : .failed
        }
    }

    private static func parse(_ payload: LyricsPayload, candidate: LyricCandidate, duration: Double) async throws -> LyricsDocument {
        let task = Task.detached(priority: .userInitiated) { try payload.parse(candidate: candidate, duration: duration) }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    private func install(_ payload: LyricsPayload, document: LyricsDocument, track: TrackIdentity, settings: LyricsSettings) {
        self.document = document; status = document.isInstrumental ? .instrumental : .ready; savedAt = Date()
        if settings.cacheEnabled {
            do { try cache.save(LyricsCacheEntry(track: track, payload: payload, document: document, savedAt: savedAt ?? Date()), settings: settings) }
            catch { cacheWarning = LyricsError.cache.localizedDescription }
        }
    }

    func search(_ query: String) {
        cancelSearch()
        guard let track, foreground, settings.enabled else { return }
        let ticket = searchEpoch, config = settings
        let query = String(query.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))
        for provider in providers {
            let source = provider.source
            searching.insert(source)
            searchTasks.append(Task { [weak self] in
                guard let self else { return }
                do {
                    let results = try await provider.search(track: track, query: query, settings: config)
                    guard searchEpoch == ticket, !Task.isCancelled else { return }
                    candidates[source] = results
                } catch {
                    guard searchEpoch == ticket, !Task.isCancelled else { return }
                    searchErrors[source] = Self.safeError(error)
                }
                if searchEpoch == ticket {
                    searching.remove(source)
                }
            })
        }
    }

    func cancelSearch() {
        searchEpoch = UUID(); searchTasks.forEach { $0.cancel() }; searchTasks = []
        searching = []; candidates = [:]; searchErrors = [:]; cancelPreview()
    }

    func cancelPreview() {
        previewEpoch = UUID(); previewTask?.cancel(); previewTask = nil
        preview = nil; previewPayload = nil; previewTrackID = nil; previewError = nil; isPreviewing = false
    }

    func preview(_ candidate: LyricCandidate) {
        cancelPreview()
        guard let track, foreground, let provider = providers.first(where: { $0.source == candidate.source }) else { return }
        let ticket = previewEpoch, config = settings
        isPreviewing = true
        previewTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if previewEpoch == ticket {
                    isPreviewing = false
                }
            }
            do {
                let payload = try await provider.lyrics(candidate: candidate, settings: config)
                let parsed = try await Self.parse(payload, candidate: candidate, duration: track.duration)
                guard previewEpoch == ticket, self.track?.spotifyID == track.spotifyID, !Task.isCancelled else { return }
                preview = parsed; previewPayload = payload; previewTrackID = track.spotifyID
            } catch {
                if previewEpoch == ticket, !Task.isCancelled {
                    previewError = Self.safeError(error)
                }
            }
        }
    }

    func applyPreview() {
        guard let track, track.spotifyID == previewTrackID, let preview, let payload = previewPayload, !isPreviewing else { return }
        cancelLoad()
        selection.candidate = preview.candidate
        persistSelection()
        install(payload, document: preview, track: track, settings: settings)
        cancelSearch()
    }

    func restoreAutomatic() {
        selection.candidate = nil; persistSelection(); cancelSearch(); reload(force: true)
    }

    func setOffset(_ value: Double) {
        guard value.isFinite else { return }
        selection.offset = max(-10, min(10, value)); persistSelection()
    }

    private func persistSelection() {
        guard let track else { return }
        do { try cache.saveSelection(selection, for: track.spotifyID) }
        catch { cacheWarning = LyricsError.cache.localizedDescription }
    }

    func clearCache() {
        cancelLoad()
        do { try cache.clearLyrics(); savedAt = nil }
        catch { cacheWarning = LyricsError.cache.localizedDescription }
    }

    func resetMatches() {
        cancelLoad(); cancelSearch()
        do { try cache.resetSelections(); selection.candidate = nil; reload(force: true) }
        catch { cacheWarning = LyricsError.cache.localizedDescription }
    }

    func credentialsChanged() {
        apple?.invalidateDiscovery(); cancelSearch(); reload(force: true)
    }

    func testApple(account: Bool) async {
        guard let apple, !isTestingApple else { return }
        let generation = apple.credentials.generation
        isTestingApple = true
        defer { isTestingApple = false }
        do {
            if account {
                try await apple.probeAccount()
            } else {
                try await apple.probeCatalog()
            }
            guard generation == apple.credentials.generation else { return }
            appleStatus = NSLocalizedString(account ? "lyrics.apple.accountOK" : "lyrics.apple.catalogOK", comment: "")
        } catch {
            if generation == apple.credentials.generation {
                appleStatus = Self.safeError(error)
            }
        }
    }

    static func safeError(_ error: Error) -> String {
        (error as? LyricsError ?? .transport).localizedDescription
    }
}
