import SwiftUI

struct SpotifyBrowserView: View {
    @Bindable var model: AppModel
    @State private var showingDevices = false

    var body: some View {
        TabView {
            navigation {
                CatalogHomeView(model: model, store: model.catalog)
            }
            .tabItem { Label("catalog.home", systemImage: "house") }
            navigation {
                CatalogSearchView(model: model, store: model.catalog)
            }
            .tabItem { Label("catalog.search", systemImage: "magnifyingglass") }
            navigation {
                List(SpotifyLibrarySection.library, id: \.self) { section in
                    NavigationLink(value: CatalogRoute.collection(section)) {
                        Label(section.title, systemImage: section.symbol)
                    }
                }
                .navigationTitle("catalog.library")
                .accessibilityIdentifier("catalogLibrary")
            }
            .tabItem { Label("catalog.library", systemImage: "square.stack") }
        }
        .sheet(isPresented: $showingDevices) { DevicePickerView(model: model) }
    }

    private func navigation<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        NavigationStack {
            content()
                .navigationDestination(for: CatalogRoute.self) { route in
                    switch route {
                    case let .collection(section):
                        CatalogCollectionView(model: model, store: model.catalog, section: section)
                    case let .detail(kind, id):
                        CatalogDetailView(model: model, store: model.catalog, kind: kind, spotifyID: id)
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
                if let profile = store.profile {
                    Label(profile.displayName, systemImage: "person.crop.circle")
                        .font(.title2.bold())
                } else if let error = store.profileError {
                    CatalogErrorView(error: error) { await store.loadProfile(force: true) }
                } else {
                    ProgressView()
                }
            }
            ForEach(SpotifyLibrarySection.allCases, id: \.self) { section in
                CatalogHomeSection(model: model, store: store, section: section, state: store.page(.collection(section)))
            }
        }
        .navigationTitle("catalog.home")
        .accessibilityIdentifier("catalogHome")
        .task { await store.loadProfile() }
        .refreshable {
            await store.loadProfile(force: true)
            for section in SpotifyLibrarySection.allCases {
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
            if section == .topTracks { Text("catalog.topRange") }
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

    var body: some View {
        CatalogPagedList(model: model, store: store, query: .collection(section), state: store.page(.collection(section)))
            .navigationTitle(section.title)
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
        .search(store.searchText.trimmingCharacters(in: .whitespacesAndNewlines), store.searchKind)
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("catalog.searchType", selection: $store.searchKind) {
                ForEach(SpotifyCatalogKind.allCases, id: \.self) { kind in Text(kind.title).tag(kind) }
            }
            .pickerStyle(.segmented)
            .padding()
            if let displayedQuery, displayedQuery == query {
                CatalogSearchResults(model: model, store: store, query: displayedQuery, state: store.page(displayedQuery))
            } else if store.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ContentUnavailableView("catalog.searchPrompt", systemImage: "magnifyingglass")
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("catalog.search")
        .searchable(text: $store.searchText, prompt: "catalog.searchPrompt")
        .task(id: query) {
            let current = query
            if displayedQuery == current, store.page(current).loadedAt != nil { return }
            if let old = displayedQuery, old != current { store.discardSearch(old) }
            displayedQuery = nil
            guard !store.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            guard !Task.isCancelled else { return }
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
