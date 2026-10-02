import SwiftUI

struct CatalogDetailView: View {
    @Bindable var model: AppModel
    let store: MusicCatalogStore
    let kind: MusicCatalogKind
    let spotifyID: String
    var scope: MusicResourceScope = .catalog
    var body: some View {
        CatalogDetailContent(model: model, store: store, kind: kind, spotifyID: spotifyID, scope: scope,
                             state: store.detail(kind: kind, id: spotifyID, scope: scope))
    }
}

private struct CatalogDetailContent: View {
    @Bindable var model: AppModel
    let store: MusicCatalogStore
    let kind: MusicCatalogKind
    let spotifyID: String
    let scope: MusicResourceScope
    @Bindable var state: MusicCatalogDetailState
    @State private var playlistChoice: MusicCatalogItem?
    @State private var editingPlaylist: MusicCatalogItem?
    @State private var failure: String?
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                if let detail = state.value {
                    hero(detail)
                    if let album = detail.item.track?.album {
                        NavigationLink(album.name, value: related(.album, album.id)).font(.headline)
                    }
                    if !detail.item.artists.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("catalog.artists").font(.headline)
                            ForEach(detail.item.artists, id: \.id) { artist in
                                NavigationLink(artist.name, value: related(.artist, artist.id)).frame(minHeight: 44)
                            }
                        }
                    }
                    if let query = detail.children {
                        CatalogDetailChildren(model: model, store: store, query: query, state: store.page(query), parent: detail.item)
                    }
                }
                if state.isLoading, state.value == nil { MusicSkeleton() }
                if let error = state.error {
                    CatalogErrorView(error: error) { await load(force: true) }
                    if store.provider.service == .spotify {
                        Link("catalog.openSpotify", destination: URL(string: "https://open.spotify.com/\(kind.rawValue)/\(spotifyID)")!)
                    }
                }
            }.padding(20).frame(maxWidth: 880).frame(maxWidth: .infinity)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(state.value?.item.name ?? kind.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let detail = state.value {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        CatalogExternalLink(item: detail.item)
                        if detail.item.service == .netease {
                            NetEaseItemActions(model: model, item: detail.item,
                                onChoosePlaylist: { playlistChoice = $0 }, onFailure: { failure = $0 })
                            if detail.item.editablePlaylist { Button("编辑歌单", systemImage: "pencil") { editingPlaylist = detail.item } }
                        }
                        if detail.item.service == .appleMusic {
                            AppleMusicItemActions(model: model, item: detail.item,
                                onChoosePlaylist: { playlistChoice = $0 }, onFailure: { failure = $0 })
                            if detail.item.editablePlaylist { Button("编辑歌单", systemImage: "pencil") { editingPlaylist = detail.item } }
                        }
                    } label: { Label("更多操作", systemImage: "ellipsis") }.accessibilityIdentifier("catalogDetailActions")
                }
            }
        }
        .sheet(item: $editingPlaylist) { item in
            if item.service == .netease { NetEasePlaylistEditor(model: model, playlist: item) }
            else { AppleMusicPlaylistEditor(model: model, playlist: item) }
        }
        .sheet(item: $playlistChoice) { item in
            if item.service == .netease { NetEasePlaylistChooser(model: model, item: item) }
            else { AppleMusicPlaylistChooser(model: model, item: item) }
        }
        .alert("操作未完成", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("好", role: .cancel) { failure = nil }
        } message: { Text(failure ?? "") }
        .task(id: "\(scope.rawValue):\(kind.rawValue):\(spotifyID)") { await load(force: false) }
        .refreshable {
            await load(force: true)
            if let query = state.value?.children { await store.page(query).load(query: query, provider: store.provider, force: true) }
        }
    }
    private func hero(_ detail: MusicCatalogDetail) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            CatalogArtwork(url: detail.item.artworkURL, size: 240, isArtist: kind == .artist)
                .frame(maxWidth: .infinity).padding(.top, 12)
            Text(detail.item.name).font(.title.bold()).textSelection(.enabled)
            Text(detail.item.subtitle).font(.headline).foregroundStyle(.secondary)
            if let date = detail.item.releaseDate { Text(date).font(.caption).foregroundStyle(.secondary) }
            if let track = detail.item.track {
                Text(String(format: "%d:%02d", track.durationMS / 60000, (track.durationMS / 1000) % 60))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            if let description = detail.item.playlist?.description, !description.isEmpty {
                Text(verbatim: description).font(.subheadline).foregroundStyle(.secondary)
            }
            if detail.item.canPlay, detail.availability == .available {
                HStack(spacing: 12) {
                    CatalogPlayButton(model: model, item: detail.item, compact: false)
                        .padding(.horizontal, 20).background(MusicProductStyle.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                    if [.appleMusic, .netease].contains(detail.item.service), [.album, .playlist].contains(detail.item.kind) {
                        Button {
                            Task {
                                do { try await model.playCatalog(detail.item, shuffled: true) }
                                catch is CancellationError {} catch { failure = error.localizedDescription }
                            }
                        } label: { Label("随机播放", systemImage: "shuffle").frame(minHeight: 44) }
                            .disabled(model.isPerformingAction).buttonStyle(.bordered)
                    }
                }
            }
            if detail.availability == .metadataOnly {
                Text("catalog.metadataOnly").font(.subheadline).foregroundStyle(.secondary)
                CatalogExternalLink(item: detail.item)
            } else if detail.availability == .restricted {
                Text("catalog.restricted").font(.subheadline).foregroundStyle(.secondary)
                CatalogExternalLink(item: detail.item)
            }
        }
    }
    private func load(force: Bool) async {
        await state.load(kind: kind, id: spotifyID, scope: scope, provider: store.provider, force: force)
    }
    private func related(_ kind: MusicCatalogKind, _ id: String) -> CatalogRoute {
        .resource(.init(service: store.provider.service, kind: kind, scope: scope, rawValue: id))
    }
}

private struct CatalogDetailChildren: View {
    @Bindable var model: AppModel
    let store: MusicCatalogStore
    let query: MusicCatalogQuery
    @Bindable var state: MusicCatalogPageState
    let parent: MusicCatalogItem
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(parent.kind == .artist ? String(localized: "catalog.albums") : String(localized: "catalog.tracks")).font(.title2.bold())
            ForEach(state.rows) { row in
                CatalogRowView(model: model, row: row, contextURI: query.preservesPositions ? parent.uri : nil,
                    tapToPlay: true, parentPlaylist: parent.service == .netease ? parent : nil)
                Divider()
            }
            if state.error == .forbidden || state.error == .unavailable {
                Text("catalog.metadataOnly").foregroundStyle(.secondary)
                CatalogExternalLink(item: parent)
            } else {
                CatalogPageFooter(state: state) { more, force in
                    await state.load(query: query, provider: store.provider, more: more, force: force)
                }
            }
        }.task(id: query) { await state.load(query: query, provider: store.provider) }
    }
}
