import Foundation
import Observation

/// One bounded queue for every request made by this home, including More pages.
@MainActor private final class MusicHomeRequestGate {
    private var active = 0
    private var waiters: [(UUID, CheckedContinuation<Void, Error>)] = []
    func acquire() async throws {
        try Task.checkCancellation()
        if active < 3 { active += 1; return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { waiters.append((id, $0)) }
        } onCancel: { Task { @MainActor in self.cancel(id) } }
    }
    func release() {
        if !waiters.isEmpty { waiters.removeFirst().1.resume() }
        else { active -= 1 }
    }
    private func cancel(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.0 == id }) else { return }
        waiters.remove(at: index).1.resume(throwing: CancellationError())
    }
}

@MainActor @Observable final class MusicHomeSectionState {
    private(set) var rows: [MusicCatalogRow] = []
    private(set) var groups: [MusicHomeSection] = []
    private(set) var replay: MusicReplaySummary?
    private(set) var next: URL?
    private(set) var total: Int?
    private(set) var loadedAt: Date?
    private(set) var error: MusicCatalogError?
    private(set) var isLoading = false
    var scrollAnchor: String?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var visited = Set<URL>()
    func cancel() { generation = UUID(); task?.cancel(); task = nil; isLoading = false }
    func seed(_ page: MusicHomePage, replace: Bool = false) {
        guard (replace || loadedAt == nil), !isLoading else { return }
        rows = page.items; next = page.next; total = page.total; loadedAt = Date()
        error = nil; visited.removeAll()
    }
    fileprivate func load(query: MusicHomeQuery, store: MusicHomeStore, more: Bool, force: Bool) async {
        if force { cancel() }
        guard !isLoading, !more || next != nil else { return }
        if !force, !more, let loadedAt, Date().timeIntervalSince(loadedAt) < 60 { return }
        if !force, let error, !error.allowsRetry { return }
        let epoch = UUID(), context = store.identity, cursor = more ? next : nil
        generation = epoch; isLoading = true; error = nil
        let work = Task { @MainActor [weak self] in
            do {
                let page = try await store.request(query, next: cursor)
                try Task.checkCancellation()
                guard let self, epoch == generation, context == store.identity else { return }
                if !more { visited.removeAll() }
                if let cursor { visited.insert(cursor) }
                var seen = Set(more ? rows.map(\.id) : [])
                let unique = page.items.filter { seen.insert($0.id).inserted }
                rows = more ? rows + unique : unique
                next = page.next.flatMap { visited.contains($0) ? nil : $0 }
                total = page.total; replay = page.replay
                var groupIDs = Set(more ? groups.map(\.id) : [])
                let added = page.groups.filter { groupIDs.insert($0.id).inserted }
                groups = more ? groups + added : added
                for group in page.groups { if let seed = page.groupPages[group.id] { store.state(group.query).seed(seed, replace: force && !more) } }
                loadedAt = Date()
            } catch is CancellationError {
            } catch {
                guard let self, epoch == generation, context == store.identity else { return }
                self.error = .presenting(error, service: store.provider.service)
            }
            guard let self, epoch == generation else { return }
            isLoading = false
        }
        task = work
        await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
    }
}

@MainActor @Observable final class MusicHomeStore {
    private(set) var identity = UUID()
    private(set) var sections: [MusicHomeSection] = []
    @ObservationIgnored let provider: any MusicCatalogProviding
    @ObservationIgnored private let gate = MusicHomeRequestGate()
    @ObservationIgnored private var states: [MusicHomeQuery: MusicHomeSectionState] = [:]
    @ObservationIgnored private var connected = false
    @ObservationIgnored private var browsing = false
    init(provider: any MusicCatalogProviding) { self.provider = provider }

    func reset() {
        identity = UUID(); states.values.forEach { $0.cancel() }; states.removeAll()
        sections = []; connected = false; browsing = false
    }
    func configure(connected: Bool, browsing: Bool) {
        guard self.connected != connected || self.browsing != browsing || sections.isEmpty else { return }
        if self.connected != connected || self.browsing != browsing { reset() }
        self.connected = connected; self.browsing = browsing
        sections = browsing ? Self.descriptors(provider: provider, connected: connected) : []
        // Install states before the first body reads featured; its rows then form
        // observable dependencies even when every request is still pending.
        for section in sections { _ = state(section.query) }
    }
    func state(_ query: MusicHomeQuery) -> MusicHomeSectionState {
        if let state = states[query] { return state }
        let value = MusicHomeSectionState(); states[query] = value; return value
    }
    func load(_ query: MusicHomeQuery, more: Bool = false, force: Bool = false) async {
        await state(query).load(query: query, store: self, more: more, force: force)
    }
    fileprivate func request(_ query: MusicHomeQuery, next: URL?) async throws -> MusicHomePage {
        let epoch = identity
        try await gate.acquire()
        defer { gate.release() }
        try Task.checkCancellation()
        guard epoch == identity, browsing else { throw CancellationError() }
        if let home = provider as? any MusicHomeProviding { return try await home.homePage(query, next: next) }
        guard case let .catalog(catalogQuery) = query else { throw MusicCatalogError.unavailable }
        return MusicHomePage(try await provider.page(catalogQuery, next: next))
    }
    func prime(force: Bool = false) async {
        let priorities: [MusicHomeQuery] = [.recommendations, .catalog(.collection(.recommendations)),
            .catalog(.collection(.recent)), .catalog(.collection(.topTracks)), .catalog(.collection(.playlists))]
        let queries = priorities.filter { query in sections.contains { $0.query == query } }
        await withTaskGroup(of: Void.self) { group in
            for query in queries { group.addTask { await self.load(query, force: force) } }
        }
    }
    func refresh() async {
        let queries = states.keys.filter { states[$0]?.loadedAt != nil || states[$0]?.error != nil }
        await withTaskGroup(of: Void.self) { group in
            for query in queries { group.addTask { await self.load(query, force: true) } }
        }
    }
    var featured: [(MusicCatalogRow, String)] {
        let priorities: [MusicHomeQuery] = [.recommendations, .catalog(.collection(.recommendations)),
            .catalog(.collection(.recent)), .catalog(.collection(.topTracks)), .catalog(.collection(.playlists))]
        var result: [(MusicCatalogRow, String)] = [], seen = Set<String>()
        for query in priorities {
            guard let section = sections.first(where: { $0.query == query }), let state = states[query] else { continue }
            let candidates = query == .recommendations ? state.groups.flatMap { states[$0.query]?.rows ?? [] } : state.rows
            for row in candidates where row.item.resource != nil {
                if seen.insert(row.item.resource!.key).inserted { result.append((row, section.title)) }
                if result.count == (provider.service == .netease && connected ? 5 : 6) { return result }
            }
        }
        return result
    }
    private static func descriptors(provider: any MusicCatalogProviding, connected: Bool) -> [MusicHomeSection] {
        let supported = MusicHomePresentation.sections(supported: provider.homeSections, connected: connected)
        func ordinary(_ section: MusicLibrarySection) -> MusicHomeSection? {
            supported.contains(section) ? .init(id: section.rawValue, title: section.title, query: .catalog(.collection(section))) : nil
        }
        var result = [ordinary(.recent)].compactMap { $0 }
        let specialized = provider is any MusicHomeProviding
        if specialized, provider.service == .netease { result.append(.init(id: "new-albums", title: "新碟上架", query: .newAlbums)) }
        result += [.playlists, .dailySongs, .recentlyAdded].compactMap(ordinary)
        if specialized, provider.service == .appleMusic {
            result += [.init(id: "recommendations", title: "为你推荐", query: .recommendations),
                       .init(id: "personal-station", title: "你的专属电台", query: .personalStation),
                       .init(id: "live-stations", title: "Apple Music 电台", query: .liveStations)]
        } else if let recommendations = ordinary(.recommendations) { result.append(recommendations) }
        if specialized, provider.service == .netease {
            for mood in ["放松", "快乐", "伤感"] { result.append(.init(id: "mood-" + mood, title: mood + "时刻", subtitle: "分类歌单", query: .mood(mood))) }
        }
        result += [.topTracks, .savedTracks, .savedAlbums, .followedArtists].compactMap(ordinary)
        if specialized, provider.service == .appleMusic { result.append(.init(id: "replay", title: "你的年度回顾", query: .replay)) }
        if let charts = ordinary(.charts) { result.append(charts) }
        return result
    }
}
