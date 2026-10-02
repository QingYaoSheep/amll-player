import SwiftUI
import ImageIO

enum CatalogRoute: Hashable {
    case collection(SpotifyLibrarySection)
    case detail(SpotifyCatalogKind, String)
    case resource(MusicResourceID)
}

struct CatalogArtwork: View {
    let url: URL?
    var size: CGFloat = 52
    var isArtist = false
    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(.quaternary)
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "music.note").foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: isArtist ? size / 2 : min(16, size / 6)))
        .accessibilityHidden(true)
        .task(id: "\(url?.absoluteString ?? ""):\(Int(size * displayScale))") {
            image = nil
            guard let url else { return }
            let loaded = await CatalogImageCache.shared.image(url, pixels: Int(size * displayScale))
            if !Task.isCancelled {
                image = loaded
            }
        }
    }
}

@MainActor
final class CatalogImageCache {
    static let shared = CatalogImageCache()
    private var cache: [String: UIImage] = [:]
    private var costs: [String: Int] = [:]
    private var order: [String] = []
    private var tasks: [URL: Task<Data?, Never>] = [:]
    private var subscribers: [URL: Set<UUID>] = [:]

    private init() {}

    private(set) var byteCount = 0
    func clear() { cache.removeAll(); costs.removeAll(); order.removeAll(); byteCount = 0 }
    func image(_ url: URL, pixels: Int = 600) async -> UIImage? {
        guard url.scheme == "https" else { return nil }
        let edge = min(1400, max(64, ((pixels + 63) / 64) * 64))
        let key = url.absoluteString + ":" + String(edge)
        if let image = cache[key] {
            order.removeAll { $0 == key }; order.append(key)
            return image
        }
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
                    guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode),
                          data.count <= 5 * 1024 * 1024 else { return nil }
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
        guard !Task.isCancelled, let data else { return nil }
        let thumbnail = await Task.detached(priority: .utility) { () -> UIImage? in
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: edge,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true,
                  ] as CFDictionary) else { return nil }
            return UIImage(cgImage: cg)
        }.value
        guard !Task.isCancelled, let thumbnail else { return nil }
        let cost = Int(thumbnail.size.width * thumbnail.size.height * 4)
        byteCount -= costs[key] ?? 0
        cache[key] = thumbnail; costs[key] = cost; byteCount += cost
        order.removeAll { $0 == key }; order.append(key)
        while byteCount > 32 * 1024 * 1024, let oldest = order.first {
            order.removeFirst(); cache.removeValue(forKey: oldest)
            byteCount -= costs.removeValue(forKey: oldest) ?? 0
        }
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
                guard item.service == .spotify, let uri = item.uri, let nativeURL = URL(string: uri) else {
                    UIApplication.shared.open(webURL)
                    return
                }
                UIApplication.shared.open(nativeURL) { opened in
                    if !opened {
                        Task { @MainActor in UIApplication.shared.open(webURL) }
                    }
                }
            } label: {
                Label(item.service == .spotify ? String(localized: "catalog.openSpotify") : "在 \(item.service.title) 打开", systemImage: "arrow.up.right.square")
            }
        }
    }
}

struct CatalogErrorView: View {
    let error: MusicCatalogError
    let retry: () async -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.subheadline).foregroundStyle(.secondary)
            if case .rateLimited = error {
                TimelineView(.periodic(from: .now, by: 1)) { _ in retryButton }
            } else { retryButton }
            DisclosureGroup("查看技术详情") {
                Text(error.localizedDescription).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }.font(.caption)
        }.accessibilityIdentifier("catalogError")
    }
    @ViewBuilder private var retryButton: some View {
        if error.allowsRetry { Button("player.tryAgain") { Task { await retry() } }.frame(minHeight: 44) }
    }
    private var message: String {
        switch error {
        case .offline: "网络暂时不可用。检查网络后重试，已加载的内容会保留。"
        case .signInRequired: "请先连接当前音乐服务，再查看个人内容。"
        case .forbidden: "当前账号暂时无法查看此内容，请检查服务权限。"
        case .unavailable: "此内容暂不可用，可以返回浏览其他音乐。"
        case .quotaExceeded, .rateLimited: "请求较频繁，请稍后重试。"
        case let .service(_, retry): retry ? "内容暂时未能加载，请检查连接后重试。" : "当前服务权限或配置未就绪，请前往音乐来源检查连接。"
        case .invalidResponse: "服务返回异常，请稍后重试。"
        }
    }
}

struct CatalogPlayButton: View {
    @Bindable var model: AppModel
    let item: SpotifyCatalogItem
    var contextURI: String?
    var position: Int?
    var compact = true
    @State private var failure: String?
    @State private var showingLogin = false

    var body: some View {
        Button {
            guard model.isConnected(to: item.service) else { showingLogin = true; return }
            Task {
                do { try await model.playCatalog(item, contextURI: contextURI, position: position) }
                catch is CancellationError {}
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
        .alert("error.title", isPresented: Binding(get: { failure != nil }, set: {
            if !$0 {
                failure = nil
            }
        })) {
            if let url = item.externalURL {
                Button(item.service == .spotify ? String(localized: "catalog.openSpotify") : "在 \(item.service.title) 打开") { UIApplication.shared.open(url) }
            }
            Button("common.ok", role: .cancel) { failure = nil }
        } message: { Text(failure ?? "") }
        .sheet(isPresented: $showingLogin) { MusicLoginSheet(model: model, service: item.service) }
        .contextMenu { CatalogExternalLink(item: item) }
    }
}

struct CatalogRowView: View {
    @Bindable var model: AppModel
    let row: SpotifyCatalogRow
    var contextURI: String?
    var tapToPlay = false
    var onSelect: (() -> Void)? = nil
    var parentPlaylist: MusicCatalogItem?
    @State private var showingLogin = false
    @State private var netEasePlaylistItem: MusicCatalogItem?
    @State private var playlistItem: MusicCatalogItem?
    @State private var failure: String?

    var body: some View {
        HStack(spacing: 8) {
            if tapToPlay, row.item.kind == .track, row.item.canPlay {
                Button {
                    onSelect?()
                    guard model.isConnected(to: row.item.service) else { showingLogin = true; return }
                    Task {
                        do { try await model.playCatalog(row.item, contextURI: contextURI, position: row.position) }
                        catch is CancellationError {} catch { failure = error.localizedDescription }
                    }
                } label: { label }.buttonStyle(.plain)
            } else if let kind = row.item.kind, row.item.availability != .unsupported {
                NavigationLink(value: row.item.service != .spotify
                    ? CatalogRoute.resource(row.item.resource!) : CatalogRoute.detail(kind, row.item.spotifyID)) { label }
                    .buttonStyle(.plain)
                    .simultaneousGesture(TapGesture().onEnded { onSelect?() })
            } else {
                label
            }
            if row.item.canPlay {
                CatalogPlayButton(model: model, item: row.item, contextURI: contextURI, position: row.position)
            }
        }
        .contextMenu {
            if row.item.service == .netease {
                NetEaseItemActions(model: model, item: row.item, onChoosePlaylist: { netEasePlaylistItem = $0 }, onFailure: { failure = $0 })
                if let parentPlaylist, parentPlaylist.libraryWritable, parentPlaylist.kind == .playlist {
                    Button("从歌单移除此歌曲", role: .destructive) {
                        Task { do { try await model.mutateNetEase { try await $0.remove(row.item, from: parentPlaylist) } }
                            catch is CancellationError {} catch { failure = error.localizedDescription } }
                    }
                }
            }
            CatalogExternalLink(item: row.item)
            if row.item.service == .appleMusic {
                AppleMusicItemActions(model: model, item: row.item,
                                      onChoosePlaylist: { playlistItem = $0 }, onFailure: { failure = $0 })
            }
        }
        .sheet(isPresented: $showingLogin) { MusicLoginSheet(model: model, service: row.item.service) }
        .sheet(item: $netEasePlaylistItem) { NetEasePlaylistChooser(model: model, item: $0) }
        .sheet(item: $playlistItem) { AppleMusicPlaylistChooser(model: model, item: $0) }
        .alert("操作未完成", isPresented: Binding(get: { failure != nil }, set: {
            if !$0 {
                failure = nil
            }
        })) {
            Button("common.ok", role: .cancel) { failure = nil }
        } message: { Text(failure ?? "") }
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
