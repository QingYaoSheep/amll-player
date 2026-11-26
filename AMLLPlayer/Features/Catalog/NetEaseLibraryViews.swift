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
                    Button {
                        Task {
                            busy = true; defer { busy = false }
                            do { try await model.mutateNetEase { try await $0.append(item, to: row.item) }; dismiss() }
                            catch is CancellationError {} catch { failure = error.localizedDescription }
                        }
                    } label: {
                        HStack(spacing: 12) {
                            CatalogArtwork(url: row.item.artworkURL, size: 46)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.item.name)
                                    .font(.body.weight(.medium))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                if let total = row.item.playlist?.total {
                                    Text("\(total.formatted()) 首歌曲")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                } else if !row.item.subtitle.isEmpty {
                                    Text(row.item.subtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "plus.circle.fill")
                                .font(.title3)
                                .foregroundStyle(row.item.libraryWritable ? MusicProductStyle.accent : Color.secondary.opacity(0.35))
                        }
                        .frame(minHeight: 50)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(MusicContentButtonStyle())
                    .disabled(busy || !row.item.libraryWritable)
                }
                CatalogPageFooter(state: state) { more, force in await state.load(query: .collection(.playlists), provider: model.netEaseCatalog, more: more, force: force) }
                if let failure { Text(failure).foregroundStyle(.secondary) }
            }
            .listStyle(.insetGrouped)
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
                Section {
                    VStack(spacing: 10) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(
                                    LinearGradient(
                                        colors: [MusicProductStyle.accent.opacity(0.24), MusicProductStyle.accent.opacity(0.10)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                            Image(systemName: "music.note.list")
                                .font(.title.weight(.semibold))
                                .foregroundStyle(MusicProductStyle.accent)
                        }
                        .frame(width: 64, height: 64)
                        .accessibilityHidden(true)

                        let previewTitle = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        Text(previewTitle.isEmpty ? (playlist == nil ? "新建歌单" : playlist?.name ?? "") : previewTitle)
                            .font(.headline)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }
                .listRowBackground(Color.clear)

                Section("歌单信息") {
                    TextField("名称", text: $name)
                    TextField("描述", text: $description, axis: .vertical)
                }

                Section {
                    Button {
                        perform {
                            if let playlist { try await model.mutateNetEase { try await $0.editPlaylist(playlist, name: name, description: description, entries: nil) } }
                            else { try await model.mutateNetEase { _ = try await $0.createPlaylist(name: name, description: description) } }
                        }
                    } label: {
                        HStack {
                            if busy { ProgressView().controlSize(.small) }
                            Text("保存")
                                .font(.body.weight(.semibold))
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .disabled(busy || name.trimmingCharacters(in: .whitespaces).isEmpty)

                    if let playlist, playlist.editablePlaylist {
                        Button("删除歌单", role: .destructive) { deleting = true }
                            .frame(maxWidth: .infinity)
                    }
                }
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
        } else if quickSettingsNavigation != nil {
            queueContent
        } else {
            NavigationStack {
                queueContent
                    .navigationTitle("网易云播放队列")
                    .toolbar {
                        if !model.netEasePlayback.isPersonalFM { EditButton() }
                        Button("完成") { dismiss() }
                    }
            }
            .environment(\.editMode, $editMode)
        }
    }

    private var queueContent: some View {
        List {
            if model.netEasePlayback.isPersonalFM {
                Section("私人 FM") {
                    Text("私人 FM 会自动补歌，也可以回听。暂停后会停止主动补歌。").font(.subheadline)
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
            if !model.netEasePlayback.actualQuality.isEmpty {
                HStack(spacing: 8) {
                    Label("实际音质", systemImage: "hifispeaker")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(model.netEasePlayback.actualQuality)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(MusicProductStyle.accent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(MusicProductStyle.accent.opacity(0.12), in: Capsule())
                }
            }
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
                Text("移除正在播放的歌曲会暂停播放。其他条目可以自由调整顺序。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
            .listStyle(.insetGrouped)
            .lyricsQuickSettingsDestination("网易云播放队列", showsEditButton: !model.netEasePlayback.isPersonalFM)
            .environment(\.editMode, $editMode)
            .onChange(of: model.netEasePlayback.isPersonalFM) { editMode = .inactive }
            .alert("播放未完成", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button("好", role: .cancel) { failure = nil }
            } message: { Text(failure ?? "") }
    }

    private func queueRows(_ entries: ArraySlice<NetEaseQueueEntry>, canMove: Bool = false) -> some View {
        let playback = model.netEasePlayback
        return ForEach(entries) { entry in
            let isCurrent = entry.id == playback.queue.currentID
            Button {
                Task {
                    do { try await playback.selectEntry(entry.id) } catch { failure = error.localizedDescription }
                }
            } label: {
                queueRow(entry)
            }
            .listRowBackground(isCurrent ? MusicProductStyle.accent.opacity(0.08) : nil)
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
            CatalogArtwork(url: entry.item.artworkURL, size: 44).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.item.name)
                    .font(.subheadline.weight(current ? .semibold : .regular))
                    .foregroundStyle(current ? MusicProductStyle.accent : .primary)
                Text(entry.item.subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if current {
                Image(systemName: "waveform")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(MusicProductStyle.accent)
                    .frame(width: 28, height: 28)
                    .background(MusicProductStyle.accent.opacity(0.12), in: Circle())
                    .accessibilityLabel("正在播放")
            }
        }
        .frame(minHeight: 46, alignment: .leading)
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
