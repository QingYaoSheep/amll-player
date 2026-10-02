import Foundation
import Observation

@MainActor
@Observable
final class MusicCatalogPageState {
    var scrollAnchor: String?
    private(set) var rows: [SpotifyCatalogRow] = []
    private(set) var next: URL?
    private(set) var total: Int?
    private(set) var error: SpotifyCatalogError?
    private(set) var isLoading = false
    private(set) var loadedAt: Date?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var visited = Set<URL>()

    func cancel() {
        generation = UUID()
        task?.cancel()
        task = nil
        isLoading = false
    }

    func load(
        query: SpotifyCatalogQuery, provider: any SpotifyCatalogProviding,
        more: Bool = false, force: Bool = false
    ) async {
        if force {
            cancel()
        }
        guard !isLoading else { return }
        if !force, !more, let loadedAt, Date().timeIntervalSince(loadedAt) < 60 {
            return
        }
        if more, next == nil {
            return
        }
        if let error, !error.allowsRetry, !force {
            return
        }
        let epoch = UUID()
        generation = epoch
        let cursor = more ? next : nil
        isLoading = true
        error = nil
        let work = Task { [weak self] in
            do {
                let page = try await provider.page(query, next: cursor)
                try Task.checkCancellation()
                guard let self, generation == epoch else { return }
                if !more {
                    visited.removeAll()
                }
                if let cursor {
                    visited.insert(cursor)
                }
                var seen = Set(more ? rows.map(\.id) : [])
                let unique = page.items.filter { seen.insert($0.id).inserted }
                rows = more ? rows + unique : unique
                if let anchor = scrollAnchor, !self.rows.contains(where: { $0.id == anchor }) {
                    scrollAnchor = nil
                }
                total = page.total
                next = page.next.flatMap { self.visited.contains($0) ? nil : $0 }
                loadedAt = Date()
            } catch is CancellationError {
                // Cancellation is not a user-visible network failure.
            } catch {
                guard let self, generation == epoch else { return }
                self.error = .presenting(error, service: provider.service)
            }
            guard let self, generation == epoch else { return }
            isLoading = false
        }
        task = work
        await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
        }
    }
}

@MainActor
@Observable
final class MusicCatalogDetailState {
    private(set) var value: SpotifyCatalogDetail?
    private(set) var error: SpotifyCatalogError?
    private(set) var isLoading = false
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var task: Task<Void, Never>?

    func cancel() {
        generation = UUID()
        task?.cancel()
        isLoading = false
    }

    func load(kind: SpotifyCatalogKind, id: String, scope: MusicResourceScope = .catalog, provider: any SpotifyCatalogProviding, force: Bool = false) async {
        if force {
            cancel()
        }
        guard !isLoading, force || value == nil else { return }
        let epoch = UUID()
        generation = epoch
        isLoading = true
        error = nil
        let work = Task { [weak self] in
            do {
                let detail = try await provider.detail(resource: .init(service: provider.service, kind: kind, scope: scope, rawValue: id))
                try Task.checkCancellation()
                guard let self, generation == epoch else { return }
                value = detail
            } catch is CancellationError {
            } catch {
                guard let self, generation == epoch else { return }
                self.error = .presenting(error, service: provider.service)
            }
            guard let self, generation == epoch else { return }
            isLoading = false
        }
        task = work
        await withTaskCancellationHandler {
            await work.value
        } onCancel: { work.cancel() }
    }
}

@MainActor
@Observable
final class MusicCatalogStore {
    private(set) var identity = UUID()
    private(set) var active = false
    private(set) var profile: SpotifyProfile?
    private(set) var profileError: SpotifyCatalogError?
    var searchLibrary = false
    var searchFilter: MusicCatalogKind? = nil
    var suggestions: [String] = []
    var searchHistory: [String] = []
    var searchText = ""
    var searchKind: SpotifyCatalogKind = .track
    @ObservationIgnored let provider: any SpotifyCatalogProviding
    @ObservationIgnored private var pages: [SpotifyCatalogQuery: MusicCatalogPageState] = [:]
    @ObservationIgnored private var details: [String: MusicCatalogDetailState] = [:]
    @ObservationIgnored private var detailResources: [String: MusicResourceID] = [:]
    @ObservationIgnored private let historyDefaults: UserDefaults
    @ObservationIgnored private var searchRequests = Set<MusicCatalogQuery>()
    @ObservationIgnored private var profileTask: Task<Void, Never>?

    init(provider: any SpotifyCatalogProviding, defaults: UserDefaults = .standard) {
        self.provider = provider
        historyDefaults = defaults
        searchHistory = defaults.stringArray(forKey: "music.search.history." + provider.service.rawValue) ?? []
    }

    func rememberSearch(_ term: String) {
        let term = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        searchHistory = Array(([term] + searchHistory.filter { $0 != term }).prefix(20))
        historyDefaults.set(searchHistory, forKey: "music.search.history." + provider.service.rawValue)
    }

    func removeSearch(_ term: String) {
        searchHistory.removeAll { $0 == term }
        historyDefaults.set(searchHistory, forKey: "music.search.history." + provider.service.rawValue)
    }

    func clearSearchHistory() {
        searchHistory.removeAll()
        historyDefaults.removeObject(forKey: "music.search.history." + provider.service.rawValue)
    }

    /// Each group owns a page state: one failure never erases sibling results.
    func loadSearch(_ request: MusicSearchRequest) async {
        let queries = Set(request.queries(supported: provider.searchKinds))
        for old in searchRequests.subtracting(queries) { discardSearch(old) }
        searchRequests = queries
        let tasks = queries.map { query in
            Task { @MainActor in await self.page(query).load(query: query, provider: self.provider) }
        }
        await withTaskCancellationHandler {
            for task in tasks { await task.value }
        } onCancel: {
            tasks.forEach { $0.cancel() }
        }
    }

    func cancelSearch() {
        searchRequests.forEach { discardSearch($0) }
        searchRequests.removeAll()
        suggestions = []
    }

    func activate() {
        active = true
    }

    func reset() {
        active = false
        identity = UUID()
        profileTask?.cancel()
        profileTask = nil
        pages.values.forEach { $0.cancel() }
        details.values.forEach { $0.cancel() }
        pages.removeAll()
        details.removeAll()
        detailResources.removeAll()
        profile = nil
        profileError = nil
        searchText = ""
        searchKind = .track
        searchFilter = nil
        searchLibrary = false
        suggestions = []
        searchRequests.removeAll()
        provider.invalidate()
    }

    func page(_ query: SpotifyCatalogQuery) -> MusicCatalogPageState {
        if let existing = pages[query] {
            return existing
        }
        let state = MusicCatalogPageState()
        pages[query] = state
        return state
    }

    func detail(kind: SpotifyCatalogKind, id: String, scope: MusicResourceScope = .catalog) -> MusicCatalogDetailState {
        let key = "\(provider.service.rawValue):\(scope.rawValue):\(kind.rawValue):\(id)"
        if let state = details[key] {
            return state
        }
        let state = MusicCatalogDetailState()
        details[key] = state
        detailResources[key] = .init(service: provider.service, kind: kind, scope: scope, rawValue: id)
        return state
    }

    func refreshContent() async {
        let epoch = identity
        let requestedPages = pages
        let requestedDetails = details
        for (query, state) in requestedPages {
            guard epoch == identity else { return }
            await state.load(query: query, provider: provider, force: true)
        }
        for (key, state) in requestedDetails {
            guard epoch == identity, let resource = detailResources[key] else { return }
            await state.load(kind: resource.kind, id: resource.rawValue, scope: resource.scope, provider: provider, force: true)
        }
    }

    func discardSearch(_ query: SpotifyCatalogQuery) {
        switch query { case .search, .librarySearch: break; default: return }
        pages.removeValue(forKey: query)?.cancel()
    }

    func loadProfile(force: Bool = false) async {
        guard active, force || profile == nil else { return }
        if let profileTask, !force {
            await profileTask.value; return
        }
        profileTask?.cancel()
        let epoch = identity
        let work = Task { [weak self] in
            guard let self else { return }
            do {
                let value = try await provider.profile()
                try Task.checkCancellation()
                guard identity == epoch else { return }
                if let old = profile, old.accountID != value.accountID {
                    reset()
                    activate()
                }
                profile = value
                profileError = nil
            } catch is CancellationError {
            } catch {
                guard identity == epoch else { return }
                profileError = .presenting(error, service: provider.service)
            }
        }
        profileTask = work
        await work.value
        if identity == epoch {
            profileTask = nil
        }
    }
}

// Existing Spotify call sites retain their source-compatible names.
typealias SpotifyCatalogStore = MusicCatalogStore
typealias SpotifyCatalogPageState = MusicCatalogPageState
typealias SpotifyCatalogDetailState = MusicCatalogDetailState
