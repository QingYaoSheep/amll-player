import Foundation

enum MusicHomeQuery: Hashable, Sendable {
    case catalog(MusicCatalogQuery)
    case recommendations, recommendation(String)
    case personalStation, liveStations, replay, newAlbums, mood(String)
}

struct MusicHomeSection: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    var subtitle: String?
    let query: MusicHomeQuery
}

struct MusicReplaySummary: Hashable, Sendable {
    let year: String
    let sections: [MusicReplaySection]
}

struct MusicReplaySection: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let items: [MusicCatalogRow]
}

struct MusicHomePage: Sendable {
    var items: [MusicCatalogRow] = []
    var next: URL?
    var total: Int?
    var groups: [MusicHomeSection] = []
    var groupPages: [String: MusicHomePage] = [:]
    var replay: MusicReplaySummary?

    init(_ page: MusicPage<MusicCatalogRow>) {
        items = page.items; next = page.next; total = page.total
    }
    init(items: [MusicCatalogRow] = [], next: URL? = nil, total: Int? = nil,
         groups: [MusicHomeSection] = [], groupPages: [String: MusicHomePage] = [:], replay: MusicReplaySummary? = nil) {
        self.items = items; self.next = next; self.total = total
        self.groups = groups; self.groupPages = groupPages; self.replay = replay
    }
}

@MainActor protocol MusicHomeProviding: MusicCatalogProviding {
    func homePage(_ query: MusicHomeQuery, next: URL?) async throws -> MusicHomePage
}

enum MusicHomeCardAction: Hashable {
    case resource(MusicResourceID), personalFM, replay
}

enum MusicHomeLayout {
    static func coverWidth(in width: CGFloat, largeText: Bool) -> CGFloat {
        if largeText { return min(260, max(180, width * 0.6)) }
        return min(200, max(132, (min(1120, width) - 64) / 2.25))
    }
    static func featuredWidth(in width: CGFloat, largeText: Bool) -> CGFloat {
        min(320, max(200, width * (largeText ? 0.76 : 0.577)))
    }
}
