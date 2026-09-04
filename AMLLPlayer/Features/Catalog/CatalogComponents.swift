import SwiftUI

enum CatalogRoute: Hashable {
    case collection(SpotifyLibrarySection)
    case detail(SpotifyCatalogKind, String)
}

struct CatalogArtwork: View {
    let url: URL?
    var size: CGFloat = 52
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(.quaternary)
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                Image(systemName: "music.note").foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityHidden(true)
        .task(id: url) {
            image = nil
            guard let url else { return }
            let loaded = await CatalogImageCache.shared.image(url)
            if !Task.isCancelled { image = loaded }
        }
    }
}

@MainActor
private final class CatalogImageCache {
    static let shared = CatalogImageCache()
    private let cache = NSCache<NSURL, UIImage>()
    private var tasks: [URL: Task<Data?, Never>] = [:]
    private var subscribers: [URL: Set<UUID>] = [:]

    private init() { cache.totalCostLimit = 32 * 1_024 * 1_024 }

    func image(_ url: URL) async -> UIImage? {
        guard url.scheme == "https" else { return nil }
        if let image = cache.object(forKey: url as NSURL) { return image }
        let id = UUID()
        subscribers[url, default: []].insert(id)
        let task: Task<Data?, Never>
        if let existing = tasks[url] {
            task = existing
        } else {
            task = Task {
                var request = URLRequest(url: url)
                request.timeoutInterval = 15
                do {
                    let (data, response) = try await URLSession.shared.data(for: request)
                    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                          data.count <= 5 * 1_024 * 1_024 else { return nil }
                    return data
                } catch { return nil }
            }
            tasks[url] = task
        }
        let data = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            Task { @MainActor in self.release(url, id: id) }
        }
        defer { release(url, id: id) }
        guard !Task.isCancelled, let data, let image = UIImage(data: data) else { return nil }
        let thumbnail = image.preparingThumbnail(of: CGSize(width: 600, height: 600)) ?? image
        cache.setObject(thumbnail, forKey: url as NSURL, cost: Int(thumbnail.size.width * thumbnail.size.height * 4))
        return thumbnail
    }

    private func release(_ url: URL, id: UUID) {
        guard subscribers[url]?.remove(id) != nil else { return }
        if subscribers[url]?.isEmpty == true {
            tasks.removeValue(forKey: url)?.cancel()
            subscribers[url] = nil
        }
    }
}

struct CatalogExternalLink: View {
    let item: SpotifyCatalogItem

    var body: some View {
        if let webURL = item.externalURL {
            Button {
                guard let uri = item.uri, let nativeURL = URL(string: uri) else {
                    UIApplication.shared.open(webURL)
                    return
                }
                UIApplication.shared.open(nativeURL) { opened in
                    if !opened { Task { @MainActor in UIApplication.shared.open(webURL) } }
                }
            } label: {
                Label("catalog.openSpotify", systemImage: "arrow.up.right.square")
            }
        }
    }
}

struct CatalogErrorView: View {
    let error: SpotifyCatalogError
    let retry: () async -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(error.localizedDescription, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.secondary)
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                if error.allowsRetry {
                    Button("player.tryAgain") { Task { await retry() } }
                }
            }
        }
        .accessibilityIdentifier("catalogError")
    }
}

struct CatalogPlayButton: View {
    @Bindable var model: AppModel
    let item: SpotifyCatalogItem
    var contextURI: String? = nil
    var position: Int? = nil
    var compact = true
    @State private var failure: String?

    var body: some View {
        Button {
            Task {
                do { try await model.playCatalog(item, contextURI: contextURI, position: position) }
                catch is CancellationError { }
                catch { failure = error.localizedDescription }
            }
        } label: {
            if compact {
                Image(systemName: "play.fill").frame(minWidth: 44, minHeight: 44)
            } else {
                Label("player.play", systemImage: "play.fill").frame(minHeight: 44)
            }
        }
        .buttonStyle(.borderless)
        .disabled(!item.canPlay || model.isPerformingAction)
        .accessibilityLabel(Text("player.play") + Text(" " + item.name))
        .accessibilityIdentifier("catalogPlay-\(item.id)")
        .alert("error.title", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            if let url = item.externalURL {
                Button("catalog.openSpotify") { UIApplication.shared.open(url) }
            }
            Button("common.ok", role: .cancel) { failure = nil }
        } message: { Text(failure ?? "") }
        .contextMenu { CatalogExternalLink(item: item) }
    }
}

struct CatalogRowView: View {
    @Bindable var model: AppModel
    let row: SpotifyCatalogRow
    var contextURI: String? = nil

    var body: some View {
        HStack(spacing: 8) {
            if let kind = row.item.kind, row.item.availability != .unsupported {
                NavigationLink(value: CatalogRoute.detail(kind, row.item.spotifyID)) { label }
                    .buttonStyle(.plain)
            } else {
                label
            }
            if row.item.canPlay {
                CatalogPlayButton(model: model, item: row.item, contextURI: contextURI, position: row.position)
            }
        }
        .contextMenu { CatalogExternalLink(item: row.item) }
    }

    private var label: some View {
        HStack(spacing: 12) {
            CatalogArtwork(url: row.item.artworkURL)
            VStack(alignment: .leading, spacing: 4) {
                Text(row.item.name).font(.body.weight(.medium)).lineLimit(2)
                if !row.item.subtitle.isEmpty {
                    Text(row.item.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if row.item.availability == .unsupported {
                    Text("catalog.unsupported").font(.caption).foregroundStyle(.secondary)
                } else if row.item.availability == .restricted {
                    Text("catalog.restricted").font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

struct CatalogPageFooter: View {
    @Bindable var state: SpotifyCatalogPageState
    let load: (Bool, Bool) async -> Void

    var body: some View {
        if state.isLoading {
            ProgressView().frame(maxWidth: .infinity).accessibilityIdentifier("catalogLoading")
        } else if let error = state.error {
            CatalogErrorView(error: error) { await load(state.next != nil && !state.rows.isEmpty, true) }
        } else if state.rows.isEmpty, state.loadedAt != nil {
            ContentUnavailableView("catalog.empty", systemImage: "music.note.list")
        } else if state.next != nil {
            Button("catalog.loadMore") { Task { await load(true, false) } }
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("catalogLoadMore")
        }
    }
}
