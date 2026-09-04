import SwiftUI

struct CatalogDetailView: View {
    @Bindable var model: AppModel
    let store: SpotifyCatalogStore
    let kind: SpotifyCatalogKind
    let spotifyID: String

    var body: some View {
        CatalogDetailContent(
            model: model, store: store, kind: kind, spotifyID: spotifyID,
            state: store.detail(kind: kind, id: spotifyID)
        )
    }
}

private struct CatalogDetailContent: View {
    @Bindable var model: AppModel
    let store: SpotifyCatalogStore
    let kind: SpotifyCatalogKind
    let spotifyID: String
    @Bindable var state: SpotifyCatalogDetailState

    var body: some View {
        List {
            if let detail = state.value {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        CatalogArtwork(url: detail.item.artworkURL, size: 180)
                        Text(detail.item.name).font(.title2.bold()).textSelection(.enabled)
                        Text(detail.item.subtitle).foregroundStyle(.secondary)
                        if let date = detail.item.releaseDate { Text(date).font(.caption) }
                        if let track = detail.item.track {
                            Text(duration(track.durationMS)).font(.caption.monospacedDigit())
                        }
                        if let description = detail.item.playlist?.description, !description.isEmpty {
                            // Treat service text as text, not executable HTML or Markdown links.
                            Text(verbatim: description).font(.callout).foregroundStyle(.secondary)
                        }
                        if detail.item.canPlay, detail.availability == .available {
                            CatalogPlayButton(model: model, item: detail.item, compact: false)
                        }
                        CatalogExternalLink(item: detail.item)
                        if detail.availability == .metadataOnly {
                            Text("catalog.metadataOnly").font(.callout).foregroundStyle(.secondary)
                        } else if detail.availability == .restricted {
                            Text("catalog.restricted").font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical)
                }
                if let album = detail.item.track?.album {
                    Section("catalog.albums") {
                        NavigationLink(album.name, value: CatalogRoute.detail(.album, album.id))
                    }
                }
                if !detail.item.artists.isEmpty {
                    Section("catalog.artists") {
                        ForEach(detail.item.artists, id: \.id) { artist in
                            NavigationLink(artist.name, value: CatalogRoute.detail(.artist, artist.id))
                        }
                    }
                }
                if let query = detail.children {
                    CatalogDetailChildren(model: model, store: store, query: query,
                                          state: store.page(query), parent: detail.item)
                }
            }
            if state.isLoading { ProgressView() }
            if let error = state.error {
                CatalogErrorView(error: error) { await load(force: true) }
                // Even inaccessible details retain a safe, public Spotify escape route.
                Link("catalog.openSpotify", destination: URL(string: "https://open.spotify.com/\(kind.rawValue)/\(spotifyID)")!)
            }
        }
        .navigationTitle(state.value?.item.name ?? kind.title)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: "\(kind.rawValue):\(spotifyID)") { await load(force: false) }
        .refreshable {
            await load(force: true)
            if let query = state.value?.children {
                await store.page(query).load(query: query, provider: store.provider, force: true)
            }
        }
    }

    private func load(force: Bool) async {
        await state.load(kind: kind, id: spotifyID, provider: store.provider, force: force)
    }

    private func duration(_ milliseconds: Int) -> String {
        let seconds = milliseconds / 1_000
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

private struct CatalogDetailChildren: View {
    @Bindable var model: AppModel
    let store: SpotifyCatalogStore
    let query: SpotifyCatalogQuery
    @Bindable var state: SpotifyCatalogPageState
    let parent: SpotifyCatalogItem

    var body: some View {
        Section(parent.kind == .artist ? String(localized: "catalog.albums") : String(localized: "catalog.tracks")) {
            ForEach(state.rows) { row in
                CatalogRowView(model: model, row: row, contextURI: query.preservesPositions ? parent.uri : nil)
            }
            if state.error == .forbidden || state.error == .unavailable {
                Text("catalog.metadataOnly").foregroundStyle(.secondary)
                CatalogExternalLink(item: parent)
            } else {
                CatalogPageFooter(state: state) { more, force in
                    await state.load(query: query, provider: store.provider, more: more, force: force)
                }
            }
        }
        .task(id: query) { await state.load(query: query, provider: store.provider) }
    }
}
