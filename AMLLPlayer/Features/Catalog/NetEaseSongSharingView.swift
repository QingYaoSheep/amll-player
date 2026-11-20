import SwiftUI

struct NetEaseSongPicker: View {
    let model: AppModel
    let select: (MusicCatalogItem) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    private var term: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var current: MusicCatalogItem? { model.netEasePlayback.currentEntry?.item }

    var body: some View {
        NavigationStack {
            Group {
                if term.isEmpty {
                    List {
                        if let current {
                            Section("当前播放") {
                                NetEaseSongChoice(item: current) { select(current) }
                            }
                        }
                        Section("音乐库") {
                            NavigationLink {
                                songs(.collection(.savedTracks), title: "我喜欢的音乐")
                            } label: {
                                Label("我喜欢的音乐", systemImage: "heart")
                            }
                            NavigationLink {
                                NetEaseSongPickerList(catalog: model.netEaseCatalog, query: .collection(.playlists),
                                                      title: "个人歌单") { item in
                                    NavigationLink {
                                        songs(.playlistItems(item.spotifyID), title: item.name)
                                    } label: {
                                        NetEaseSharingTrackLabel(item: item)
                                    }
                                }
                            } label: {
                                Label("个人歌单", systemImage: "music.note.list")
                            }
                        }
                    }
                } else {
                    songs(.search(term, .track), title: "分享歌曲", delaySearch: true)
                        .id(term)
                }
            }
            .navigationTitle("分享歌曲")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $text, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索网易云歌曲")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }

    private func songs(_ query: MusicCatalogQuery, title: String, delaySearch: Bool = false) -> some View {
        NetEaseSongPickerList(catalog: model.netEaseCatalog, query: query, title: title, delaySearch: delaySearch) { item in
            NetEaseSongChoice(item: item) { select(item) }
        }
    }
}

private struct NetEaseSongPickerList<Row: View>: View {
    let catalog: NetEaseCatalog
    let query: MusicCatalogQuery
    let title: String
    var delaySearch = false
    @ViewBuilder let row: (MusicCatalogItem) -> Row
    @State private var rows: [MusicCatalogRow] = []
    @State private var next: URL?
    @State private var loading = false
    @State private var loaded = false
    @State private var failure: String?

    var body: some View {
        List {
            ForEach(rows) { entry in row(entry.item) }
            if let failure { Text(failure).font(.footnote).foregroundStyle(.secondary) }
            if loading {
                ProgressView().frame(maxWidth: .infinity)
            } else if next != nil || failure != nil {
                Button(failure == nil ? "载入更多" : "重试") { Task { await load() } }
            } else if loaded, rows.isEmpty {
                ContentUnavailableView("没有找到内容", systemImage: "music.note.list")
            }
        }
        .navigationTitle(title)
        .task {
            if delaySearch {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            }
            if !loaded { await load() }
        }
    }

    private func load() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        do {
            let page = try await catalog.page(query, next: next)
            try Task.checkCancellation()
            var seen = Set(rows.map(\.id))
            rows.append(contentsOf: page.items.filter { seen.insert($0.id).inserted })
            next = page.next == next ? nil : page.next
            failure = nil
            loaded = true
        } catch is CancellationError {
        } catch {
            failure = error.localizedDescription
        }
    }
}

private struct NetEaseSongChoice: View {
    let item: MusicCatalogItem
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack {
                NetEaseSharingTrackLabel(item: item)
                Spacer(minLength: 8)
                Image(systemName: "plus.circle").foregroundStyle(Color.accentColor)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(MusicContentButtonStyle())
        .disabled(NetEaseRoomInvite.numericID(item.spotifyID) == nil)
        .accessibilityIdentifier("netEasePickSong:\(item.spotifyID)")
    }
}

private struct NetEaseSharingTrackLabel: View {
    let item: MusicCatalogItem

    var body: some View {
        HStack(spacing: 10) {
            CatalogArtwork(url: item.artworkURL, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                Text(item.subtitle).font(.caption).foregroundStyle(.secondary)
            }
            .lineLimit(2)
        }
    }
}

struct NetEaseSharedSongCard: View {
    let model: AppModel
    let songID: String
    let showDetail: () -> Void
    @State private var failure: String?
    @State private var busy = false

    private var detail: MusicCatalogDetailState { model.catalog.detail(kind: .track, id: songID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Button(action: showDetail) {
                    if let song = detail.value?.item {
                        NetEaseSharingTrackLabel(item: song)
                    } else {
                        Label("网易云歌曲", systemImage: "music.note").font(.subheadline.weight(.semibold))
                    }
                }
                .buttonStyle(MusicContentButtonStyle())
                .accessibilityHint("打开歌曲详情")
                if let song = detail.value?.item {
                    Button {
                        Task { await play(song) }
                    } label: {
                        Image(systemName: model.netEasePlayback.isListeningTogether ? "text.line.first.and.arrowtriangle.forward" : "play.fill")
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .buttonStyle(MusicContentButtonStyle())
                    .disabled(!song.canPlay || busy)
                    .accessibilityLabel(model.netEasePlayback.isListeningTogether ? "添加到一起听队列" : "播放歌曲")
                }
            }
            if let failure {
                Text(failure).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
        .task(id: songID) {
            guard model.selectedMusicService == .netease else { return }
            await detail.load(kind: .track, id: songID, provider: model.catalog.provider)
        }
    }

    private func play(_ item: MusicCatalogItem) async {
        guard !busy, model.selectedMusicService == .netease else { return }
        busy = true
        defer { busy = false }
        failure = nil
        do { try await model.playCatalog(item) }
        catch is CancellationError {}
        catch { failure = error.localizedDescription }
    }
}

struct NetEaseSharedSongDetail: View {
    let model: AppModel
    let songID: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            CatalogDetailView(model: model, store: model.catalog, kind: .track, spotifyID: songID)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("关闭", systemImage: "xmark") { dismiss() }
                    }
                }
        }
    }
}
