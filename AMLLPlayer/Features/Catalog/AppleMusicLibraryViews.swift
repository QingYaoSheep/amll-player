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
                    Button(row.item.name) { Task {
                        busy = true
                        defer { busy = false }
                        do {
                            try await model.mutateAppleLibrary { try await $0.append(item, to: row.item) }
                            dismiss()
                        } catch is CancellationError {}
                        catch { failure = error.localizedDescription }
                    } }
                    .disabled(busy || !(row.item.libraryWritable || row.item.editablePlaylist))
                }
                CatalogPageFooter(state: state) { more, force in
                    await state.load(query: .collection(.playlists), provider: model.appleCatalog, more: more, force: force)
                }
                if let failure {
                    Text(failure).foregroundStyle(.secondary)
                }
            }
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

private struct AppleMusicPlaylistEditor: View {
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
                TextField("名称", text: $name)
                TextField("说明", text: $description, axis: .vertical)
                if playlist != nil {
                    Toggle("编辑歌曲顺序和条目", isOn: $editEntries)
                        .disabled(busy)
                    if editEntries {
                        ForEach(entryState.entries) { row in Text(row.item.name) }
                            .onDelete { entryState.entries.remove(atOffsets: $0) }
                            .onMove { entryState.entries.move(fromOffsets: $0, toOffset: $1) }
                            .disabled(busy || !entryState.isLoaded)
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
    var body: some View {
        NavigationStack {
            List {
                if let item = model.playbackSnapshot?.item {
                    Section("正在播放") { Text(item.title); Text(item.artistLine) }
                }
                Section { Text("系统 MusicKit 仅提供当前队列条目。外部完整队列请在系统音乐 App 查看；本应用不推测或重排不可读取的队列。") }
                Link("打开音乐", destination: URL(string: "music://")!)
            }
            .navigationTitle("系统播放队列")
            .toolbar { Button("common.done") { dismiss() } }
        }
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
