import SwiftUI

struct SpotifyBrowserView: View {
    @Bindable var model: AppModel
    @State private var showingDevices = false
    let playerNamespace: Namespace.ID
    var openPlayer: () -> Void

    var body: some View {
        Group {
            if #available(iOS 26.0, *) {
                tabs
                    .tabBarMinimizeBehavior(.onScrollDown)
                    .tabViewBottomAccessory {
                        if let snapshot = model.playbackSnapshot, snapshot.item != nil, model.currentServiceConnected {
                            TabMusicAccessory(model: model, snapshot: snapshot, namespace: playerNamespace, openPlayer: openPlayer)
                        }
                    }
            } else {
                tabs
            }
        }
        .sheet(isPresented: $showingDevices) { DevicePickerView(model: model) }
    }

    private var tabs: some View {
        TabView {
            Tab("catalog.home", systemImage: "house") {
                navigation {
                    CatalogHomeView(model: model, store: model.catalog)
                }
            }
            Tab("catalog.search", systemImage: "magnifyingglass", role: .search) {
                navigation {
                    CatalogSearchView(model: model, store: model.catalog)
                }
            }
            Tab("catalog.library", systemImage: "square.stack") {
                navigation {
                    List(model.catalog.provider.librarySections, id: \.self) { section in
                        NavigationLink(value: CatalogRoute.collection(section)) {
                            Label(section.title, systemImage: section.symbol)
                        }
                    }
                    .safeAreaInset(edge: .bottom) {
                        if model.selectedMusicService == .appleMusic {
                            AppleMusicCreatePlaylistButton(model: model).padding()
                        }
                    }
                    .navigationTitle("catalog.library")
                    .accessibilityIdentifier("catalogLibrary")
                }
            }
        }
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
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button("player.devices", systemImage: "airplayaudio") {
                            showingDevices = true
                            Task { await model.loadDevices() }
                        }
                        NavigationLink { SettingsView(model: model) } label: {
                            Label("settings.open", systemImage: "gearshape")
                        }
                        .accessibilityIdentifier("openSettings")
                    }
                }
        }
    }
}

private struct CatalogHomeView: View {
    @Bindable var model: AppModel
    @Bindable var store: SpotifyCatalogStore

    var body: some View {
        List {
            Section {
                MusicSourcePicker(model: model)
                if let profile = store.profile {
                    Label(profile.displayName, systemImage: "person.crop.circle")
                        .font(.title2.bold())
                } else if let error = store.profileError {
                    CatalogErrorView(error: error) { await store.loadProfile(force: true) }
                } else {
                    ProgressView()
                }
            }
            ForEach(store.provider.homeSections, id: \.self) { section in
                CatalogHomeSection(model: model, store: store, section: section, state: store.page(.collection(section)))
            }
        }
        .navigationTitle("catalog.home")
        .accessibilityIdentifier("catalogHome")
        .task { await store.loadProfile() }
        .refreshable {
            await store.loadProfile(force: true)
            for section in store.provider.homeSections {
                await store.page(.collection(section)).load(query: .collection(section), provider: store.provider, force: true)
            }
        }
    }
}

private struct CatalogHomeSection: View {
    @Bindable var model: AppModel
    let store: SpotifyCatalogStore
    let section: SpotifyLibrarySection
    @Bindable var state: SpotifyCatalogPageState

    var body: some View {
        Section {
            ForEach(Array(state.rows.prefix(4))) { row in CatalogRowView(model: model, row: row) }
            if state.isLoading {
                ProgressView()
            } else if let error = state.error {
                CatalogErrorView(error: error) { await load(force: true) }
            } else if state.loadedAt != nil, state.rows.isEmpty {
                Text("catalog.empty").foregroundStyle(.secondary)
            }
            NavigationLink("catalog.seeAll", value: CatalogRoute.collection(section))
        } header: {
            Label(section.title, systemImage: section.symbol)
        } footer: {
            if section == .topTracks {
                Text("catalog.topRange")
            }
        }
        .task { await load(force: false) }
    }

    private func load(force: Bool) async {
        await state.load(query: .collection(section), provider: store.provider, force: force)
    }
}

private struct CatalogCollectionView: View {
    @Bindable var model: AppModel
    let store: SpotifyCatalogStore
    let section: SpotifyLibrarySection
    @State private var alphabetical = true

    private var usesLibrarySort: Bool {
        store.provider.service == .appleMusic && MusicLibrarySection.library.contains(section)
    }

    private var query: MusicCatalogQuery {
        usesLibrarySort ? .libraryItems(section, ascending: alphabetical) : .collection(section)
    }

    var body: some View {
        CatalogPagedList(model: model, store: store, query: query, state: store.page(query))
            .navigationTitle(section.title)
            .safeAreaInset(edge: .top) {
                if usesLibrarySort {
                    Picker("名称排序", selection: $alphabetical) { Text("名称 A–Z").tag(true); Text("名称 Z–A").tag(false) }
                        .pickerStyle(.segmented).padding()
                }
            }
    }
}

private struct CatalogPagedList: View {
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

private struct CatalogSearchView: View {
    @Bindable var model: AppModel
    @Bindable var store: SpotifyCatalogStore
    @State private var displayedQuery: SpotifyCatalogQuery?

    private var query: SpotifyCatalogQuery {
        store.searchLibrary ? .librarySearch(store.searchText.trimmingCharacters(in: .whitespacesAndNewlines), store.searchKind)
            : .search(store.searchText.trimmingCharacters(in: .whitespacesAndNewlines), store.searchKind)
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("catalog.searchType", selection: $store.searchKind) {
                ForEach(store.searchLibrary ? [MusicCatalogKind.track, .album, .artist, .playlist] : store.provider.searchKinds, id: \.self) { kind in Text(kind.title).tag(kind) }
            }
            .pickerStyle(.menu)
            .padding()
            if store.provider.service == .appleMusic {
                Picker("搜索范围", selection: $store.searchLibrary) {
                    Text("Apple Music 全库").tag(false)
                    Text("我的资料库").tag(true)
                }.pickerStyle(.segmented).padding(.horizontal)
                    .onChange(of: store.searchLibrary) { _, library in
                        if library, [.station, .musicVideo].contains(store.searchKind) {
                            store.searchKind = .track
                        }
                    }
            }
            if let displayedQuery, displayedQuery == query {
                CatalogSearchResults(model: model, store: store, query: displayedQuery, state: store.page(displayedQuery))
            } else if store.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                List(store.searchHistory, id: \.self) { term in
                    Button(term) { store.searchText = term }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("catalog.search")
        .searchable(text: $store.searchText, prompt: "catalog.searchPrompt")
        .searchSuggestions {
            ForEach(store.suggestions, id: \.self) { term in Text(term).searchCompletion(term) }
        }
        .task(id: store.searchText) {
            store.suggestions = []
            let term = store.searchText
            guard !term.isEmpty, !store.searchLibrary else { return }
            do {
                try await Task.sleep(for: .milliseconds(300))
                let values = try await store.provider.suggestions(term)
                guard !Task.isCancelled, term == store.searchText else { return }
                store.suggestions = values
            } catch {}
        }
        .task(id: query) {
            let current = query
            if displayedQuery == current, store.page(current).loadedAt != nil {
                return
            }
            if let old = displayedQuery, old != current {
                store.discardSearch(old)
            }
            displayedQuery = nil
            guard !store.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            guard !Task.isCancelled else { return }
            store.rememberSearch(store.searchText.trimmingCharacters(in: .whitespacesAndNewlines))
            displayedQuery = current
            await store.page(current).load(query: current, provider: store.provider)
        }
    }
}

private struct CatalogSearchResults: View {
    @Bindable var model: AppModel
    let store: SpotifyCatalogStore
    let query: SpotifyCatalogQuery
    @Bindable var state: SpotifyCatalogPageState

    var body: some View {
        CatalogRowsScrollView(model: model, state: state) { more, force in
            await state.load(query: query, provider: store.provider, more: more, force: force)
        }
        .refreshable { await state.load(query: query, provider: store.provider, force: true) }
    }
}

private struct CatalogRowsScrollView: View {
    @Bindable var model: AppModel
    @Bindable var state: SpotifyCatalogPageState
    let load: (Bool, Bool) async -> Void

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(state.rows) { row in
                    VStack(spacing: 0) {
                        CatalogRowView(model: model, row: row)
                        Divider()
                    }
                    .id(row.id)
                }
            }
            .scrollTargetLayout()
            .padding(.horizontal)
            CatalogPageFooter(state: state, load: load).padding()
        }
        .scrollPosition(id: $state.scrollAnchor, anchor: .top)
    }
}
