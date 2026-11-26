import SwiftUI

struct AppleMusicItemActions: View {
    @Bindable var model: AppModel
    let item: MusicCatalogItem
    var onChoosePlaylist: ((MusicCatalogItem) -> Void)?
    var onFailure: ((String) -> Void)?
    @State private var choosePlaylist = false
    @State private var failure: String?

    var body: some View {
        Group {
            if item.inFavorites == true {
                Label("已收藏", systemImage: "star.fill")
            }
            if [.track, .album, .playlist].contains(item.kind), model.appleMusicState.capabilities.canFavorite,
               item.inFavorites != true
            {
                Button("加入收藏", systemImage: "star") { mutate { try await $0.favorite(item) } }
            }
            if item.scope == .catalog, model.appleMusicState.capabilities.canModifyLibrary,
               [.track, .album, .playlist, .musicVideo].contains(item.kind)
            {
                Button("加入资料库", systemImage: "plus") { mutate { try await $0.addToLibrary(item) } }
            }
            if item.kind == .track {
                if model.appleMusicState.capabilities.canModifyLibrary {
                    Button("添加到歌单", systemImage: "text.badge.plus") {
                        if let onChoosePlaylist {
                            onChoosePlaylist(item)
                        } else {
                            choosePlaylist = true
                        }
                    }
                }
                if item.canPlay {
                    Button("接下来播放", systemImage: "text.insert") { Task { await model.enqueue(item, next: true) } }
                    Button("最后播放", systemImage: "text.append") { Task { await model.enqueue(item, next: false) } }
                }
            }
        }
        .sheet(isPresented: $choosePlaylist) { AppleMusicPlaylistChooser(model: model, item: item) }
        .alert("操作未完成", isPresented: Binding(get: { failure != nil }, set: {
            if !$0 {
                failure = nil
            }
        })) {
            Button("common.ok", role: .cancel) { failure = nil }
        } message: { Text(failure ?? "") }
    }

    private func mutate(_ action: @escaping @MainActor (any MusicLibraryMutating) async throws -> Void) {
        Task {
            do { try await model.mutateAppleLibrary(action) }
            catch is CancellationError {}
            catch {
                if let onFailure {
                    onFailure(error.localizedDescription)
                } else {
                    failure = error.localizedDescription
                }
            }
        }
    }
}

struct AppleMusicPlaylistChooser: View {
    @Bindable var model: AppModel
    let item: MusicCatalogItem
    @Environment(\.dismiss) private var dismiss
    @State private var state = MusicCatalogPageState()
    @State private var busy = false
    @State private var failure: String?
    var body: some View {
        NavigationStack {
            List {
                ForEach(state.rows) { row in
                    Button { Task {
                        busy = true
                        defer { busy = false }
                        do {
                            try await model.mutateAppleLibrary { try await $0.append(item, to: row.item) }
                            dismiss()
                        } catch is CancellationError {}
                        catch { failure = error.localizedDescription }
                    } } label: {
                        let writable = row.item.libraryWritable || row.item.editablePlaylist
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
                                .foregroundStyle(writable ? MusicProductStyle.accent : Color.secondary.opacity(0.35))
                        }
                        .frame(minHeight: 50)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(MusicContentButtonStyle())
                    .disabled(busy || !(row.item.libraryWritable || row.item.editablePlaylist))
                }
                CatalogPageFooter(state: state) { more, force in
                    await state.load(query: .collection(.playlists), provider: model.appleCatalog, more: more, force: force)
                }
                if let failure {
                    Text(failure).foregroundStyle(.secondary)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("添加到歌单")
            .toolbar { Button("common.done") { dismiss() } }
            .task { await state.load(query: .collection(.playlists), provider: model.appleCatalog) }
        }
    }
}

struct AppleMusicCreatePlaylistButton: View {
    @Bindable var model: AppModel
    @State private var showing = false
    var body: some View {
        Button("新建歌单", systemImage: "plus") { showing = true }
            .disabled(!model.appleMusicState.capabilities.canModifyLibrary)
            .sheet(isPresented: $showing) { AppleMusicPlaylistEditor(model: model, playlist: nil) }
    }
}

struct AppleMusicEditPlaylistButton: View {
    @Bindable var model: AppModel
    let playlist: MusicCatalogItem
    @State private var showing = false
    var body: some View {
        Button("编辑歌单", systemImage: "pencil") { showing = true }
            .sheet(isPresented: $showing) { AppleMusicPlaylistEditor(model: model, playlist: playlist) }
    }
}

struct AppleMusicPlaylistEditor: View {
    @Bindable var model: AppModel
    let playlist: MusicCatalogItem?
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var description = ""
    @State private var busy = false
    @State private var failure: String?
    @State private var entryState = MusicPlaylistEditingState()
    @State private var editEntries = false

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
                    TextField("说明", text: $description, axis: .vertical)
                }
                if playlist != nil {
                    Section {
                        Toggle("编辑歌曲顺序和条目", isOn: $editEntries.hapticSelection())
                            .disabled(busy)
                        if editEntries {
                            ForEach(entryState.entries) { row in Text(row.item.name) }
                                .onDelete { entryState.entries.remove(atOffsets: $0) }
                                .onMove { entryState.entries.move(fromOffsets: $0, toOffset: $1) }
                                .disabled(busy || !entryState.isLoaded)
                        }
                    }
                }
                if busy || entryState.isLoading {
                    ProgressView()
                }
                if let error = entryState.error {
                    Text(error).foregroundStyle(.secondary)
                }
                if let failure {
                    Text(failure).foregroundStyle(.secondary)
                }
            }
            .environment(\.editMode, .constant(editEntries ? .active : .inactive))
            .navigationTitle(playlist == nil ? "新建歌单" : "编辑歌单")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(busy) }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { Task { await save() } }
                    .disabled(busy || (editEntries && !entryState.isLoaded) || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .task {
                name = playlist?.name ?? ""
                description = playlist?.playlist?.description ?? ""
            }
            .task(id: editEntries) {
                guard editEntries, let resource = playlist?.resource else { entryState.cancel(); return }
                await entryState.load(resource: resource, provider: model.appleCatalog)
            }
            .onDisappear { entryState.cancel() }
        }
    }

    private func save() async {
        guard !busy, !editEntries || entryState.isLoaded else { return }
        let replacement = editEntries ? entryState.entries.map(\.item) : nil
        busy = true
        defer { busy = false }
        do {
            try await model.mutateAppleLibrary { library in
                if let playlist {
                    try await library.editPlaylist(playlist, name: name, description: description,
                                                   entries: replacement)
                } else {
                    _ = try await library.createPlaylist(name: name, description: description)
                }
            }
            dismiss()
        } catch is CancellationError {}
        catch { failure = error.localizedDescription }
    }
}

struct AppleMusicPlaybackOptions: View {
    @Bindable var model: AppModel
    let snapshot: PlaybackSnapshot
    @State private var showingQueue = false
    var body: some View {
        HStack {
            Button(snapshot.shuffleEnabled ? "关闭随机" : "随机播放", systemImage: "shuffle") {
                Task { await model.setShuffle(!snapshot.shuffleEnabled) }
            }
            Menu {
                ForEach(MusicRepeatMode.allCases, id: \.self) { mode in
                    Button(mode.title) { Task { await model.setRepeat(mode) } }
                }
            } label: { Label(snapshot.repeatMode.title, systemImage: snapshot.repeatMode == .one ? "repeat.1" : "repeat") }
            Button("播放队列", systemImage: "list.bullet") { showingQueue = true }
        }
        .sheet(isPresented: $showingQueue) {
            AppleMusicQueueView(model: model)
        }
    }
}

struct AppleMusicQueueView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.lyricsQuickSettingsNavigation) private var quickSettingsNavigation

    var body: some View {
        if quickSettingsNavigation != nil {
            queueContent.lyricsQuickSettingsDestination("系统播放队列")
        } else {
            NavigationStack {
                queueContent
                    .navigationTitle("系统播放队列")
                    .toolbar { Button("common.done") { dismiss() } }
            }
        }
    }

    private var queueContent: some View {
        List {
            if let item = model.playbackSnapshot?.item {
                Section("正在播放") {
                    HStack(spacing: 12) {
                        CatalogArtwork(url: item.artworkURL, size: 48).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.title).font(.headline)
                            Text(item.artistLine).font(.subheadline).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "waveform")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(MusicProductStyle.accent)
                            .frame(width: 28, height: 28)
                            .background(MusicProductStyle.accent.opacity(0.12), in: Circle())
                            .accessibilityHidden(true)
                    }
                    .padding(.vertical, 2)
                }
            }
            Section {
                Text("这里显示系统音乐 App 的当前曲目。请到系统音乐 App 查看完整队列。AMLL 无法读取或调整那部分队列。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Section {
                Link(destination: URL(string: "music://")!) {
                    HStack(spacing: 12) {
                        SettingsIconBadge(systemImage: "music.note", color: MusicProductStyle.accent)
                        Text("打开音乐")
                            .font(.body.weight(.medium))
                            .foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }
}

struct AppleMusicCurrentFavorite: View {
    @Bindable var model: AppModel
    @State private var item: MusicCatalogItem?
    @State private var busy = false
    private var resource: MusicResourceID? {
        guard let track = model.playbackSnapshot?.item, let id = track.id, track.service == .appleMusic, !track.isEpisode else { return nil }
        return .init(service: .appleMusic, kind: .track, scope: track.resourceScope, rawValue: id)
    }

    var body: some View {
        Button {
            guard let item else { return }
            Task {
                busy = true
                defer { busy = false }
                do {
                    try await model.mutateAppleLibrary { try await $0.favorite(item) }
                    await reload()
                } catch is CancellationError {} catch { model.presentedError = .musicFailure(error.localizedDescription) }
            }
        } label: {
            Label(item?.inFavorites == true ? "已收藏" : "加入 Apple Music 收藏",
                  systemImage: item?.inFavorites == true ? "star.fill" : "star")
                .labelStyle(.iconOnly).font(.system(size: 25, weight: .semibold)).frame(width: 44, height: 44)
        }
        .disabled(busy || item == nil || item?.inFavorites == true || !model.appleMusicState.capabilities.canFavorite)
        .task(id: resource) { item = nil; await reload() }
        .accessibilityIdentifier("appleMusicFavorite")
    }

    private func reload() async {
        guard let resource else { return }
        let detail = try? await model.appleCatalog.detail(resource: resource)
        guard !Task.isCancelled, self.resource == resource else { return }
        item = detail?.item
    }
}
