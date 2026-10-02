import SwiftUI

/// Shared shell for all three music providers.
struct MusicBrowserView: View {
    @Bindable var model: AppModel
    @State private var showingDevices = false
    let playerNamespace: Namespace.ID
    var openPlayer: () -> Void
    var body: some View {
        Group {
            if #available(iOS 26.0, *) {
                tabs.tabBarMinimizeBehavior(.onScrollDown).tabViewBottomAccessory {
                    if let snapshot = model.playbackSnapshot, snapshot.item != nil, model.currentServiceConnected {
                        TabMusicAccessory(model: model, snapshot: snapshot, namespace: playerNamespace, openPlayer: openPlayer)
                    }
                }
            } else { tabs }
        }
        .tint(MusicProductStyle.accent)
        .sheet(isPresented: $showingDevices) { DevicePickerView(model: model) }
    }
    private var tabs: some View {
        TabView {
            Tab("catalog.home", systemImage: "house") {
                navigation { CatalogHomeView(model: model, store: model.catalog, openPlayer: openPlayer) }
            }
            Tab("catalog.library", systemImage: "square.stack") {
                navigation { MusicLibraryView(model: model, store: model.catalog) }
            }
            Tab("catalog.search", systemImage: "magnifyingglass", role: .search) {
                navigation { CatalogSearchView(model: model, store: model.catalog) }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
    }
    private func navigation(@ViewBuilder content: () -> some View) -> some View {
        NavigationStack {
            content()
                .navigationDestination(for: CatalogRoute.self) { route in
                    switch route {
                    case let .collection(section):
                        CatalogCollectionView(model: model, store: model.catalog, section: section)
                    case let .detail(kind, id):
                        CatalogDetailView(model: model, store: model.catalog, kind: kind, spotifyID: id)
                    case let .resource(resource):
                        CatalogDetailView(model: model, store: model.catalog, kind: resource.kind, spotifyID: resource.rawValue, scope: resource.scope)
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { MusicSourceMenu(model: model) }
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        if model.currentServiceConnected {
                            Button("player.devices", systemImage: "airplayaudio") {
                                showingDevices = true
                                Task { await model.loadDevices() }
                            }
                        }
                        NavigationLink { SettingsView(model: model) } label: { Label("settings.open", systemImage: "gearshape") }
                            .accessibilityIdentifier("openSettings")
                    }
                }
        }
    }
}

struct CatalogHomeView: View {
    @Bindable var model: AppModel
    @Bindable var store: MusicCatalogStore
    var openPlayer: () -> Void
    private var sections: [MusicLibrarySection] {
        model.canBrowseCurrentService ? MusicHomePresentation.sections(
            supported: store.provider.homeSections, connected: model.currentServiceConnected) : []
    }
    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: MusicProductStyle.sectionSpacing) {
                    if !model.currentServiceConnected || !model.canBrowseCurrentService {
                        MusicConnectionCard(model: model)
                    }
                    if let profile = store.profile {
                        Text("为 " + profile.displayName + " 精选")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    if model.selectedMusicService == .appleMusic, model.currentServiceConnected, !model.canBrowseCurrentService,
                       let item = model.playbackSnapshot?.item {
                        Button(action: openPlayer) {
                            Label("打开 " + item.title + " 的歌词", systemImage: "quote.bubble")
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }.buttonStyle(.bordered)
                    }
                    ForEach(sections, id: \.self) { section in
                        MusicHomeSection(model: model, store: store, section: section,
                            state: store.page(.collection(section)),
                            width: min(220, max(145, (proxy.size.width - 40) * 0.45)))
                    }
                }
                .padding(.horizontal, MusicProductStyle.pageInset)
                .padding(.top, 12).padding(.bottom, 28)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .refreshable {
                if model.currentServiceConnected { await store.loadProfile(force: true) }
                let tasks = sections.map { section in Task { @MainActor in
                    await store.page(.collection(section)).load(query: .collection(section), provider: store.provider, force: true)
                } }
                await withTaskCancellationHandler {
                    for task in tasks { await task.value }
                } onCancel: { tasks.forEach { $0.cancel() } }
            }
        }
        .navigationTitle("catalog.home")
        .accessibilityIdentifier("catalogHome")
        .task { if model.currentServiceConnected && model.canBrowseCurrentService { await store.loadProfile() } }
    }
}

private struct MusicHomeSection: View {
    @Bindable var model: AppModel
    let store: MusicCatalogStore
    let section: MusicLibrarySection
    @Bindable var state: MusicCatalogPageState
    let width: CGFloat
    @ScaledMetric(relativeTo: .body) private var songColumnHeight: CGFloat = 230
    var body: some View {
        if state.loadedAt == nil || !state.rows.isEmpty || state.error != nil {
            VStack(alignment: .leading, spacing: 12) {
                MusicSectionHeading(title: section.title, route: .collection(section))
                if !state.rows.isEmpty {
                    ScrollView(.horizontal) {
                        if MusicHomePresentation.usesSongColumns(section) {
                            LazyHGrid(rows: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 20) {
                                ForEach(Array(state.rows.prefix(12))) { row in
                                    CatalogRowView(model: model, row: row, tapToPlay: true)
                                        .frame(width: max(280, width * 1.9))
                                }
                            }.frame(height: songColumnHeight).padding(.vertical, 2)
                        } else {
                            LazyHStack(alignment: .top, spacing: 12) {
                                ForEach(Array(state.rows.prefix(12))) { row in
                                    MusicCatalogCard(model: model, row: row, width: width)
                                }
                            }
                        }
                    }.scrollIndicators(.hidden)
                } else if state.error == nil { MusicSkeleton() }
                if let error = state.error {
                    CatalogErrorView(error: error) { await load(force: true) }
                }
            }
            .task { await load(force: false) }
        }
    }
    private func load(force: Bool) async {
        await state.load(query: .collection(section), provider: store.provider, force: force)
    }
}

struct MusicLibraryView: View {
    @Bindable var model: AppModel
    @Bindable var store: MusicCatalogStore
    @State private var selection: MusicLibrarySection = .playlists
    private var sections: [MusicLibrarySection] { store.provider.librarySections }
    private var current: MusicLibrarySection { sections.contains(selection) ? selection : sections.first ?? .playlists }
    var body: some View {
        Group {
            if !model.currentServiceConnected || !model.canBrowseCurrentService {
                ScrollView { MusicConnectionCard(model: model).padding(20) }
            } else {
                VStack(spacing: 0) {
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            ForEach(sections, id: \.self) { section in
                                Button { selection = section } label: {
                                    Label(section.title, systemImage: section.symbol)
                                        .font(.subheadline.weight(.semibold)).padding(.horizontal, 14).frame(minHeight: 44)
                                }.buttonStyle(.plain)
                                    .foregroundStyle(current == section ? MusicProductStyle.accent : .primary)
                                    .background(current == section ? MusicProductStyle.accent.opacity(0.12) : Color.clear, in: Capsule())
                                    .accessibilityAddTraits(current == section ? .isSelected : [])
                            }
                        }.padding(.horizontal, 20)
                    }.scrollIndicators(.hidden).padding(.vertical, 8)
                    CatalogCollectionView(model: model, store: store, section: current, showsTitle: false)
                        .id(current)
                }
            }
        }
        .navigationTitle("catalog.library")
        .accessibilityIdentifier("catalogLibrary")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if model.currentServiceConnected {
                    if model.selectedMusicService == .netease { NetEasePlaylistEditorButton(model: model) }
                    if model.selectedMusicService == .appleMusic, model.appleMusicState.capabilities.canModifyLibrary {
                        AppleMusicCreatePlaylistButton(model: model)
                    }
                }
            }
        }
    }
}

struct CatalogCollectionView: View {
    @Bindable var model: AppModel
    let store: SpotifyCatalogStore
    let section: SpotifyLibrarySection
    var showsTitle = true
    @State private var alphabetical = true

    private var usesLibrarySort: Bool {
        store.provider.service == .appleMusic && MusicLibrarySection.library.contains(section)
    }

    private var query: MusicCatalogQuery {
        usesLibrarySort ? .libraryItems(section, ascending: alphabetical) : .collection(section)
    }

    var body: some View {
        CatalogPagedList(model: model, store: store, query: query, state: store.page(query))
            .navigationTitle(showsTitle ? section.title : String(localized: "catalog.library"))
            .safeAreaInset(edge: .top) {
                if usesLibrarySort {
                    Picker("名称排序", selection: $alphabetical) { Text("名称 A–Z").tag(true); Text("名称 Z–A").tag(false) }
                        .pickerStyle(.segmented).padding()
                }
            }
    }
}

struct CatalogPagedList: View {
    @Bindable var model: AppModel
    let store: SpotifyCatalogStore
    let query: SpotifyCatalogQuery
    @Bindable var state: SpotifyCatalogPageState

    var body: some View {
        CatalogRowsScrollView(model: model, state: state, load: load)
            .task(id: query) { await load(false, false) }
            .refreshable { await load(false, true) }
    }

    private func load(_ more: Bool, _ force: Bool) async {
        await state.load(query: query, provider: store.provider, more: more, force: force)
    }
}


struct CatalogSearchView: View {
    @Bindable var model: AppModel
    @Bindable var store: MusicCatalogStore
    @State private var displayedRequest: MusicSearchRequest?
    private var request: MusicSearchRequest {
        .init(term: store.searchText.trimmingCharacters(in: .whitespacesAndNewlines),
              library: store.searchLibrary, kind: store.searchFilter)
    }
    var body: some View {
        VStack(spacing: 0) {
            if model.canBrowseCurrentService {
                if store.provider.service == .appleMusic {
                    Picker("搜索范围", selection: $store.searchLibrary) {
                        Text("Apple Music 全库").tag(false); Text("我的资料库").tag(true)
                    }.pickerStyle(.segmented).padding(.horizontal, 20).padding(.bottom, 8)
                        .onChange(of: store.searchLibrary) { _, library in
                            if library, store.searchFilter == .station || store.searchFilter == .musicVideo { store.searchFilter = nil }
                        }
                }
                if request.term.isEmpty { history }
                else {
                    filters
                    if displayedRequest == request {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 28) {
                                ForEach(request.queries(supported: store.provider.searchKinds), id: \.self) { query in
                                    MusicSearchGroup(model: model, store: store, query: query,
                                        state: store.page(query), preview: store.searchFilter == nil,
                                        onSelect: { store.rememberSearch(request.term) },
                                        seeAll: { kind in store.rememberSearch(request.term); store.searchFilter = kind })
                                }
                            }.padding(20)
                        }
                    } else { MusicSkeleton().padding(20); Spacer() }
                }
            } else {
                ScrollView { MusicConnectionCard(model: model).padding(20) }
            }
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("catalog.search")
        .searchable(text: $store.searchText, prompt: "catalog.searchPrompt")
        .onSubmit(of: .search) { store.rememberSearch(request.term) }
        .searchSuggestions {
            ForEach(store.suggestions, id: \.self) { term in
                Button { store.searchText = term; store.rememberSearch(term) } label: { Label(term, systemImage: "magnifyingglass") }
                    .searchCompletion(term)
            }
        }
        .task(id: request) {
            store.suggestions = []
            guard model.canBrowseCurrentService, !request.term.isEmpty else {
                store.cancelSearch(); displayedRequest = nil; return
            }
            let current = request
            if displayedRequest != current {
                store.cancelSearch()
                displayedRequest = nil
                do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            }
            guard !Task.isCancelled else { return }
            displayedRequest = current
            await store.loadSearch(current)
        }
        .task(id: MusicSearchRequest(term: request.term, library: request.library, kind: nil)) {
            let term = request.term
            guard model.canBrowseCurrentService, !term.isEmpty, !store.searchLibrary else { return }
            do {
                try await Task.sleep(for: .milliseconds(300))
                let suggestions = try await store.provider.suggestions(term)
                guard !Task.isCancelled, term == request.term, !store.searchLibrary else { return }
                store.suggestions = suggestions
            } catch {}
        }
    }
    private var filters: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                filter("综合", kind: nil)
                ForEach(store.searchLibrary ? [.track, .album, .artist, .playlist] : store.provider.searchKinds, id: \.self) { kind in
                    filter(kind.title, kind: kind)
                }
            }.padding(.horizontal, 20)
        }.scrollIndicators(.hidden).padding(.vertical, 8)
    }
    private func filter(_ title: String, kind: MusicCatalogKind?) -> some View {
        Button { store.searchFilter = kind } label: {
            Text(title).font(.subheadline.weight(.semibold)).padding(.horizontal, 14).frame(minHeight: 44)
        }.buttonStyle(.plain)
            .foregroundStyle(store.searchFilter == kind ? MusicProductStyle.accent : .primary)
            .background(store.searchFilter == kind ? MusicProductStyle.accent.opacity(0.12) : Color.clear, in: Capsule())
            .accessibilityAddTraits(store.searchFilter == kind ? .isSelected : [])
    }
    private var history: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("最近搜索").font(.title2.bold())
                    Spacer()
                    if !store.searchHistory.isEmpty {
                        Button("清除") { store.clearSearchHistory() }.frame(minHeight: 44)
                            .accessibilityIdentifier("clearMusicSearchHistory")
                    }
                }
                if store.searchHistory.isEmpty {
                    ContentUnavailableView("寻找喜欢的音乐", systemImage: "magnifyingglass",
                        description: Text("搜索歌曲、艺人、专辑或歌单。"))
                }
                ForEach(store.searchHistory, id: \.self) { term in
                    HStack {
                        Button { store.searchText = term; store.rememberSearch(term) } label: {
                            Label(term, systemImage: "clock").frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        }.buttonStyle(.plain)
                        Button { store.removeSearch(term) } label: {
                            Image(systemName: "xmark").frame(width: 44, height: 44)
                        }.accessibilityLabel("删除搜索记录 " + term).foregroundStyle(.secondary)
                    }
                    Divider()
                }
            }.padding(20)
        }
    }
}

private struct MusicSearchGroup: View {
    @Bindable var model: AppModel
    let store: MusicCatalogStore
    let query: MusicCatalogQuery
    @Bindable var state: MusicCatalogPageState
    let preview: Bool
    var onSelect: () -> Void
    var seeAll: (MusicCatalogKind) -> Void
    private var kind: MusicCatalogKind {
        switch query { case let .search(_, kind), let .librarySearch(_, kind): kind; default: .track }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(kind.title).font(.title2.bold())
                Spacer()
                if preview, !state.rows.isEmpty {
                    Button("查看全部") { seeAll(kind) }.frame(minHeight: 44)
                }
            }
            ForEach(Array(state.rows.prefix(preview ? 4 : state.rows.count))) { row in
                CatalogRowView(model: model, row: row, tapToPlay: true, onSelect: onSelect)
                Divider()
            }
            if let error = state.error {
                CatalogErrorView(error: error) { await state.load(query: query, provider: store.provider, force: true) }
            } else if state.isLoading || state.loadedAt == nil {
                MusicSkeleton()
            } else if state.rows.isEmpty {
                Text("没有找到相关" + kind.title + "，试试其他关键词。").font(.subheadline).foregroundStyle(.secondary)
            } else if !preview, state.next != nil {
                CatalogPageFooter(state: state) { more, force in
                    await state.load(query: query, provider: store.provider, more: more, force: force)
                }
            }
        }
    }
}

struct CatalogRowsScrollView: View {
    @Bindable var model: AppModel
    @Bindable var state: SpotifyCatalogPageState
    let load: (Bool, Bool) async -> Void

    var body: some View {
        ScrollView {
            if !state.rows.isEmpty, state.rows.allSatisfy({ [.album, .playlist, .artist].contains($0.item.kind) }) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 145, maximum: 220), spacing: 12)], alignment: .leading, spacing: 24) {
                    ForEach(state.rows) { row in
                        MusicCatalogCard(model: model, row: row, width: 145).id(row.id)
                    }
                }.padding(20)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(state.rows) { row in
                        VStack(spacing: 0) {
                            CatalogRowView(model: model, row: row, tapToPlay: true)
                            Divider()
                        }.id(row.id)
                    }
                }
            }
            .scrollTargetLayout()
            .padding(.horizontal)
            CatalogPageFooter(state: state, load: load).padding()
        }
        .scrollPosition(id: $state.scrollAnchor, anchor: .top)
    }
}
