import SwiftUI

struct NetEaseItemActions: View {
    @Bindable var model: AppModel
    let item: MusicCatalogItem
    var onChoosePlaylist: ((MusicCatalogItem) -> Void)?
    var onFailure: ((String) -> Void)?
    @State private var favorite: Bool?
    @State private var failure: String?
    @State private var choose = false
    var body: some View {
        Group {
            if [.track, .playlist].contains(item.kind) {
                Button(favorite == true ? "取消收藏" : "加入收藏", systemImage: favorite == true ? "heart.fill" : "heart") {
                    run { try await $0.setFavorite(item, enabled: favorite != true) }
                }.disabled(favorite == nil || !model.currentServiceConnected)
            }
            if item.kind == .track {
                Button("添加到歌单", systemImage: "text.badge.plus") { if let onChoosePlaylist { onChoosePlaylist(item) } else { choose = true } }
                Button("接下来播放", systemImage: "text.insert") { Task { await model.enqueue(item, next: true) } }
                Button("最后播放", systemImage: "text.append") { Task { await model.enqueue(item, next: false) } }
            }
        }
        .task(id: item.id) {
            guard [.track, .playlist].contains(item.kind) else { return }
            let context = model.netEaseState.contextID
            let value = try? await model.netEaseLibrary.favoriteState(item)
            if !Task.isCancelled, model.selectedMusicService == .netease, context == model.netEaseState.contextID { favorite = value }
        }
        .sheet(isPresented: $choose) { NetEasePlaylistChooser(model: model, item: item) }
        .alert("操作未完成", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("好", role: .cancel) { failure = nil }
        } message: { Text(failure ?? "") }
    }
    private func run(_ action: @escaping @MainActor (NetEaseLibrary) async throws -> Void) {
        Task {
            do { try await model.mutateNetEase(action); favorite = try await model.netEaseLibrary.favoriteState(item) }
            catch is CancellationError {} catch { if let onFailure { onFailure(error.localizedDescription) } else { failure = error.localizedDescription } }
        }
    }
}

struct NetEasePlaylistChooser: View {
    @Bindable var model: AppModel
    let item: MusicCatalogItem
    @State private var state = MusicCatalogPageState()
    @State private var failure: String?
    @State private var busy = false
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {

                ForEach(state.rows) { row in
                    Button(row.item.name) {
                        Task {
                            busy = true; defer { busy = false }
                            do { try await model.mutateNetEase { try await $0.append(item, to: row.item) }; dismiss() }
                            catch is CancellationError {} catch { failure = error.localizedDescription }
                        }
                    }.disabled(busy || !row.item.libraryWritable)
                }
                CatalogPageFooter(state: state) { more, force in await state.load(query: .collection(.playlists), provider: model.netEaseCatalog, more: more, force: force) }
                if let failure { Text(failure).foregroundStyle(.secondary) }
            }
            .navigationTitle("添加到歌单")
            .toolbar { Button("完成") { dismiss() } }
            .task { await state.load(query: .collection(.playlists), provider: model.netEaseCatalog) }
        }
    }
}

struct NetEasePlaylistEditorButton: View {
    @Bindable var model: AppModel
    var playlist: MusicCatalogItem?
    @State private var showing = false
    var body: some View {
        Button(playlist == nil ? "新建歌单" : "编辑歌单", systemImage: playlist == nil ? "plus" : "pencil") { showing = true }
            .sheet(isPresented: $showing) { NetEasePlaylistEditor(model: model, playlist: playlist) }
    }
}
struct NetEasePlaylistEditor: View {
    @Bindable var model: AppModel
    let playlist: MusicCatalogItem?
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var description = ""
    @State private var failure: String?
    @State private var busy = false
    @State private var deleting = false
    var body: some View {
        NavigationStack {
            Form {
                TextField("名称", text: $name)
                TextField("描述", text: $description, axis: .vertical)
                Button("保存") { perform {
                    if let playlist { try await model.mutateNetEase { try await $0.editPlaylist(playlist, name: name, description: description, entries: nil) } }
                    else { try await model.mutateNetEase { _ = try await $0.createPlaylist(name: name, description: description) } }
                } }.disabled(busy || name.trimmingCharacters(in: .whitespaces).isEmpty)
                if let playlist, playlist.editablePlaylist { Button("删除歌单", role: .destructive) { deleting = true } }
                if let failure { Text(failure).foregroundStyle(.secondary) }
            }.navigationTitle(playlist == nil ? "新建歌单" : "编辑歌单")
                .toolbar { Button("取消") { dismiss() } }
                .onAppear { name = playlist?.name ?? ""; description = playlist?.playlist?.description ?? "" }
                .confirmationDialog("删除歌单？此操作不可撤销。", isPresented: $deleting) {
                    Button("删除歌单", role: .destructive) { perform { if let playlist { try await model.mutateNetEase { try await $0.deletePlaylist(playlist) } } } }
                }
        }
    }
    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        Task {
            busy = true; defer { busy = false }
            do { try await action(); dismiss() } catch is CancellationError {} catch { failure = error.localizedDescription }
        }
    }
}

struct NetEaseQueueView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.lyricsQuickSettingsNavigation) private var quickSettingsNavigation
    @State private var failure: String?
    @State private var editMode: EditMode = .inactive

    var body: some View {
        if model.netEasePlayback.isListeningTogether {
            NetEaseRoomView(model: model)
        } else {
          NavigationStack {
            List {
                if model.netEasePlayback.isPersonalFM {
                    Section("私人 FM") {
                        Text("自动续播；可返回已听歌曲，暂停后停止主动补歌。").font(.subheadline)
                        if model.netEasePlayback.isRefillingRadio { ProgressView("正在补充推荐") }
                        if let error = model.netEasePlayback.radioFailure {
                            Text(error).foregroundStyle(.secondary)
                            Button("重试补歌") { Task { await model.netEasePlayback.retryPersonalFM() } }
                        }
                        Button("退出 FM，恢复普通队列") { model.netEasePlayback.exitPersonalFM() }
                            .accessibilityIdentifier("exitPersonalFM")
                    }
                }
                if let failure = model.netEasePlayback.failure { Text(failure).foregroundStyle(.secondary) }
                if !model.netEasePlayback.actualQuality.isEmpty { Text("实际音质：\(model.netEasePlayback.actualQuality)") }
                let entries = model.netEasePlayback.displayedEntries
                if editMode.isEditing {
                    Section("播放顺序") { queueRows(entries[...], canMove: true) }
                } else if let index = entries.firstIndex(where: { $0.id == model.netEasePlayback.queue.currentID }) {
                    Section("正在播放") { queueRows(entries[index ... index]) }
                    Section("接下来播放") {
                        let upcoming = entries[(index + 1)...]
                        if upcoming.isEmpty { Text("暂无待播歌曲").foregroundStyle(.secondary) }
                        else { queueRows(upcoming) }
                    }
                    if index > entries.startIndex {
                        Section("之前的歌曲") { queueRows(entries[..<index]) }
                    }
                } else {
                    Section("播放顺序") { queueRows(entries[...]) }
                }
                if !model.netEasePlayback.isPersonalFM {
                    Text("移除正在播放的条目会暂停；其余条目可自由排序。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
                .navigationTitle("网易云播放队列")
                .lyricsQuickSettingsDestination("网易云播放队列", showsEditButton: !model.netEasePlayback.isPersonalFM)
                .toolbar {
                    if quickSettingsNavigation == nil {
                        if !model.netEasePlayback.isPersonalFM { EditButton() }
                        Button("完成") { dismiss() }
                    }
                }
                .environment(\.editMode, $editMode)
                .onChange(of: model.netEasePlayback.isPersonalFM) { editMode = .inactive }
                .alert("播放未完成", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                    Button("好", role: .cancel) { failure = nil }
                } message: { Text(failure ?? "") }
          }
        }
    }

    private func queueRows(_ entries: ArraySlice<NetEaseQueueEntry>, canMove: Bool = false) -> some View {
        let playback = model.netEasePlayback
        return ForEach(entries) { entry in
            Button {
                Task {
                    do { try await playback.selectEntry(entry.id) } catch { failure = error.localizedDescription }
                }
            } label: {
                queueRow(entry)
            }
        }
        .onDelete { offsets in
            let removed = Set(offsets.compactMap { offset in
                let index = entries.startIndex + offset
                return entries.indices.contains(index) ? entries[index].id : nil
            })
            let displayed = playback.displayedEntries
            playback.removeDisplayed(at: IndexSet(displayed.indices.filter { removed.contains(displayed[$0].id) }))
        }
        .onMove { from, to in playback.move(from: from, to: to) }
        .deleteDisabled(playback.isPersonalFM)
        .moveDisabled(!canMove || playback.isPersonalFM)
    }

    private func queueRow(_ entry: NetEaseQueueEntry) -> some View {
        let current = entry.id == model.netEasePlayback.queue.currentID
        return HStack(spacing: 12) {
            CatalogArtwork(url: entry.item.artworkURL, size: 40).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.item.name).font(.subheadline.weight(current ? .semibold : .regular))
                Text(entry.item.subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if current {
                Image(systemName: "waveform").foregroundStyle(MusicProductStyle.accent)
                    .accessibilityLabel("正在播放")
            }
        }
        .frame(minHeight: 44, alignment: .leading)
        .foregroundStyle(.primary)
    }
}

struct NetEaseCurrentFavorite: View {
    @Bindable var model: AppModel
    @State private var item: MusicCatalogItem?
    @State private var choosingPlaylist: MusicCatalogItem?
    @State private var failure: String?
    var body: some View {
        Group { if let item { Menu { NetEaseItemActions(model: model, item: item, onChoosePlaylist: { choosingPlaylist = $0 }, onFailure: { failure = $0 }) } label: { Image(systemName: "heart").frame(width: 44, height: 44) } } }
            .sheet(item: $choosingPlaylist) { NetEasePlaylistChooser(model: model, item: $0) }
            .alert("操作未完成", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button("好", role: .cancel) { failure = nil }
            } message: { Text(failure ?? "") }
            .task(id: model.playbackSnapshot?.item?.id) {
                item = nil
                guard let track = model.playbackSnapshot?.item, track.service == .netease, let id = track.id else { return }
                let value = try? await model.netEaseCatalog.detail(kind: .track, id: id)
                if !Task.isCancelled, model.playbackSnapshot?.item?.id == id { item = value?.item }
            }
    }
}
