import Foundation
import Observation

@MainActor
@Observable
final class SpotifyCatalogPageState {
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
        if force { cancel() }
        guard !isLoading else { return }
        if !force, !more, let loadedAt, Date().timeIntervalSince(loadedAt) < 60 { return }
        if more, next == nil { return }
        if let error, !error.allowsRetry, !force { return }
        let epoch = UUID()
        generation = epoch
        let cursor = more ? next : nil
        isLoading = true
        error = nil
        let work = Task { [weak self] in
            do {
                let page = try await provider.page(query, next: cursor)
                try Task.checkCancellation()
                guard let self, self.generation == epoch else { return }
                if !more { self.visited.removeAll() }
                if let cursor { self.visited.insert(cursor) }
                var seen = Set(more ? self.rows.map(\.id) : [])
                let unique = page.items.filter { seen.insert($0.id).inserted }
                self.rows = more ? self.rows + unique : unique
                if let anchor = self.scrollAnchor, !self.rows.contains(where: { $0.id == anchor }) {
                    self.scrollAnchor = nil
                }
                self.total = page.total
                self.next = page.next.flatMap { self.visited.contains($0) ? nil : $0 }
                self.loadedAt = Date()
            } catch is CancellationError {
                // Cancellation is not a user-visible network failure.
            } catch {
                guard let self, self.generation == epoch else { return }
                self.error = error as? SpotifyCatalogError ?? .invalidResponse
            }
            guard let self, self.generation == epoch else { return }
            self.isLoading = false
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
final class SpotifyCatalogDetailState {
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

    func load(kind: SpotifyCatalogKind, id: String, provider: any SpotifyCatalogProviding, force: Bool = false) async {
        if force { cancel() }
        guard !isLoading, force || value == nil else { return }
        let epoch = UUID()
        generation = epoch
        isLoading = true
        error = nil
        let work = Task { [weak self] in
            do {
                let detail = try await provider.detail(kind: kind, id: id)
                try Task.checkCancellation()
                guard let self, self.generation == epoch else { return }
                self.value = detail
            } catch is CancellationError {
            } catch {
                guard let self, self.generation == epoch else { return }
                self.error = error as? SpotifyCatalogError ?? .invalidResponse
            }
            guard let self, self.generation == epoch else { return }
            self.isLoading = false
        }
        task = work
        await withTaskCancellationHandler {
            await work.value
        } onCancel: { work.cancel() }
    }
}

@MainActor
@Observable
final class SpotifyCatalogStore {
    private(set) var identity = UUID()
    private(set) var active = false
    private(set) var profile: SpotifyProfile?
    private(set) var profileError: SpotifyCatalogError?
    var searchText = ""
    var searchKind: SpotifyCatalogKind = .track
    @ObservationIgnored let provider: any SpotifyCatalogProviding
    @ObservationIgnored private var pages: [SpotifyCatalogQuery: SpotifyCatalogPageState] = [:]
    @ObservationIgnored private var details: [String: SpotifyCatalogDetailState] = [:]
    @ObservationIgnored private var profileTask: Task<Void, Never>?

    init(provider: any SpotifyCatalogProviding) { self.provider = provider }

    func activate() { active = true }

    func reset() {
        active = false
        identity = UUID()
        profileTask?.cancel()
        profileTask = nil
        pages.values.forEach { $0.cancel() }
        details.values.forEach { $0.cancel() }
        pages.removeAll()
        details.removeAll()
        profile = nil
        profileError = nil
        searchText = ""
        searchKind = .track
        provider.invalidate()
    }

    func page(_ query: SpotifyCatalogQuery) -> SpotifyCatalogPageState {
        if let existing = pages[query] { return existing }
        let state = SpotifyCatalogPageState()
        pages[query] = state
        return state
    }

    func detail(kind: SpotifyCatalogKind, id: String) -> SpotifyCatalogDetailState {
        let key = "\(kind.rawValue):\(id)"
        if let state = details[key] { return state }
        let state = SpotifyCatalogDetailState()
        details[key] = state
        return state
    }

    func discardSearch(_ query: SpotifyCatalogQuery) {
        guard case .search = query else { return }
        pages.removeValue(forKey: query)?.cancel()
    }

    func loadProfile(force: Bool = false) async {
        guard active, force || profile == nil else { return }
        if let profileTask, !force { await profileTask.value; return }
        profileTask?.cancel()
        let epoch = identity
        let work = Task { [weak self] in
            guard let self else { return }
            do {
                let value = try await self.provider.profile()
                try Task.checkCancellation()
                guard self.identity == epoch else { return }
                if let old = self.profile, old.accountID != value.accountID {
                    self.reset()
                    self.activate()
                }
                self.profile = value
                self.profileError = nil
            } catch is CancellationError {
            } catch {
                guard self.identity == epoch else { return }
                self.profileError = error as? SpotifyCatalogError ?? .invalidResponse
            }
        }
        profileTask = work
        await work.value
        if identity == epoch { profileTask = nil }
    }
}
