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
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var playlistChoice: MusicCatalogItem?
    @State private var editingPlaylist: MusicCatalogItem?
    @State private var failure: String?
    @State private var width: CGFloat = 320

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                if let detail = state.value {
                    hero(detail).id(detail.item.id)
                    if !detail.highlights.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("热门歌曲").font(.title2.bold()).accessibilityAddTraits(.isHeader)
                            ForEach(detail.highlights) { row in
                                CatalogRowView(model: model, row: row, tapToPlay: true)
                                Divider()
                            }
                        }
                    }
                    if let query = detail.children {
                        CatalogDetailChildren(model: model, store: store, query: query, state: store.page(query), parent: detail.item)
                    }
                    if let about = MusicCatalogText.description(detail.about) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("关于这位歌手").font(.title2.bold()).accessibilityAddTraits(.isHeader)
                            MusicDetailDescription(text: about)
                        }
                    }
                    relatedResources(detail)
                }
                if state.isLoading, state.value == nil { MusicSkeleton().padding(.top, 24) }
                if let error = state.error {
                    CatalogErrorView(error: error) { await load(force: true) }
                    if let item = state.value?.item { CatalogExternalLink(item: item) }
                    else if store.provider.service == .spotify,
                            let url = URL(string: "https://open.spotify.com/\(kind.rawValue)/\(spotifyID)") {
                        Link("catalog.openSpotify", destination: url).frame(minHeight: 44)
                    }
                }
            }
            .padding(20).frame(maxWidth: MusicCatalogLayout.maximumWidth).frame(maxWidth: .infinity)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width = $0 }
        .navigationTitle(state.value?.item.name ?? kind.title)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("catalogDetail")
        .animation(reduceMotion ? nil : MusicProductMotion.change, value: state.value == nil)
        .toolbar {
            if let detail = state.value {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        if let url = detail.item.externalURL { ShareLink(item: url) { Label("分享", systemImage: "square.and.arrow.up") } }
                        CatalogExternalLink(item: detail.item)
                        if detail.item.service == .netease {
                            NetEaseItemActions(model: model, item: detail.item,
                                onChoosePlaylist: { playlistChoice = $0 }, onFailure: { failure = $0 })
                        } else if detail.item.service == .appleMusic {
                            AppleMusicItemActions(model: model, item: detail.item,
                                onChoosePlaylist: { playlistChoice = $0 }, onFailure: { failure = $0 })
                        }
                        if detail.item.editablePlaylist { Button("编辑歌单", systemImage: "pencil") { editingPlaylist = detail.item } }
                    } label: { Label("更多操作", systemImage: "ellipsis") }
                        .accessibilityIdentifier("catalogDetailActions")
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

    @ViewBuilder private func hero(_ detail: MusicCatalogDetail) -> some View {
        if width >= 700, !typeSize.isAccessibilitySize {
            HStack(alignment: .center, spacing: 32) {
                cover(detail, size: min(300, width * 0.3))
                information(detail)
            }.padding(.vertical, 12)
        } else {
            VStack(alignment: .leading, spacing: 20) {
                cover(detail, size: min(max(1, width - 64), kind == .artist ? 232 : 272)).frame(maxWidth: .infinity)
                information(detail)
            }.padding(.top, 12)
        }
    }

    private func cover(_ detail: MusicCatalogDetail, size: CGFloat) -> some View {
        CatalogArtwork(url: detail.item.artworkURL, size: size, isArtist: kind == .artist)
            .shadow(color: .black.opacity(kind == .artist ? 0.05 : 0.12), radius: 18, y: 8)
    }

    private func information(_ detail: MusicCatalogDetail) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(kind.title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(detail.item.name).font(.largeTitle.bold()).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            if kind != .artist, let artist = detail.item.artists.first {
                NavigationLink(artist.name, value: related(.artist, artist.id)).font(.title3)
                    .frame(minHeight: 44).accessibilityIdentifier("catalogPrimaryArtist")
            } else if !detail.item.subtitle.isEmpty {
                Text(detail.item.subtitle).font(.title3).foregroundStyle(.secondary)
            }
            metadata(detail.item)
            if let description = MusicCatalogText.description(detail.item.playlist?.description) { MusicDetailDescription(text: description) }
            if detail.item.canPlay, detail.availability == .available {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { playback(detail.item) }
                    VStack(alignment: .leading, spacing: 12) { playback(detail.item) }
                }.padding(.top, 4)
            } else if detail.availability == .metadataOnly || detail.availability == .restricted {
                Label(LocalizedStringKey(detail.availability == .metadataOnly ? "catalog.metadataOnly" : "catalog.restricted"),
                      systemImage: "info.circle").font(.subheadline).foregroundStyle(.secondary)
                CatalogExternalLink(item: detail.item).frame(minHeight: 44)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func metadata(_ item: MusicCatalogItem) -> some View {
        if let date = item.releaseDate { Text(date).font(.subheadline).foregroundStyle(.secondary) }
        if let count = item.playlist?.total { Text("\(count.formatted()) 首歌曲").font(.subheadline).foregroundStyle(.secondary) }
        if let track = item.track, track.durationMS > 0 {
            Text(String(format: "%d:%02d", track.durationMS / 60000, track.durationMS / 1000 % 60))
                .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func playback(_ item: MusicCatalogItem) -> some View {
        CatalogPlayButton(model: model, item: item, compact: false)
            .frame(minWidth: 120, minHeight: 48).padding(.horizontal, 16)
            .foregroundStyle(.white).background(MusicProductStyle.filledAccent, in: Capsule())
        if [.appleMusic, .netease].contains(item.service), [.album, .playlist].contains(item.kind) {
            Button {
                Task {
                    do { try await model.playCatalog(item, shuffled: true) }
                    catch is CancellationError {} catch { failure = error.localizedDescription }
                }
            } label: { Label("随机播放", systemImage: "shuffle").frame(minWidth: 120, minHeight: 48).padding(.horizontal, 16) }
                .buttonStyle(MusicContentButtonStyle()).disabled(model.isPerformingAction)
                .background(MusicProductStyle.accent.opacity(0.1), in: Capsule())
                .accessibilityIdentifier("catalogShuffleCollection")
        }
    }

    @ViewBuilder private func relatedResources(_ detail: MusicCatalogDetail) -> some View {
        if let album = detail.item.track?.album {
            VStack(alignment: .leading, spacing: 8) {
                Text("收录专辑").font(.headline).accessibilityAddTraits(.isHeader)
                NavigationLink(album.name, value: related(.album, album.id)).frame(minHeight: 44)
            }
        }
        if !detail.item.artists.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("catalog.artists").font(.headline).accessibilityAddTraits(.isHeader)
                ForEach(detail.item.artists, id: \.id) { artist in
                    NavigationLink(value: related(.artist, artist.id)) {
                        HStack {
                            Label(artist.name, systemImage: "person.crop.circle")
                            Spacer(); Image(systemName: "chevron.right").font(.caption)
                        }.frame(minHeight: 44).contentShape(Rectangle())
                    }.buttonStyle(MusicContentButtonStyle())
                }
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
            HStack(alignment: .firstTextBaseline) {
                Text(parent.kind == .artist ? String(localized: "catalog.albums") : String(localized: "catalog.tracks"))
                    .font(.title2.bold()).accessibilityAddTraits(.isHeader)
                Spacer()
                if state.next != nil, let total = state.total {
                    Text("已加载 \(state.rows.count) / \(total)").font(.caption).foregroundStyle(.secondary)
                }
            }
            if parent.kind == .artist {
                MusicCatalogGrid(model: model, rows: state.rows)
            } else {
                ForEach(state.rows) { row in
                    CatalogRowView(model: model, row: row, contextURI: query.preservesPositions ? parent.uri : nil,
                        tapToPlay: true, parentPlaylist: parent.service == .netease ? parent : nil, showsPosition: true)
                    Divider()
                }
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
