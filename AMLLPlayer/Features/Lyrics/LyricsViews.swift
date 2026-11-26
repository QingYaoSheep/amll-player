import SwiftUI

struct LyricsDiagnosticView: View {
    @Bindable var model: AppModel
    private var lyrics: LyricsCoordinator {
        model.lyrics
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("lyrics.title").font(.headline)
                if lyrics.isLoading {
                    ProgressView().controlSize(.small)
                }
                Spacer()
            }
            Text(LocalizedStringKey("lyrics.status." + lyrics.status.rawValue)).font(.subheadline).foregroundStyle(.secondary)
            if let document = lyrics.document {
                if document.isInstrumental {
                    Text("lyrics.status.instrumental").font(.subheadline)
                }
                Text(document.candidate.source.name + " · " + document.candidate.title).font(.subheadline)
                HStack {
                    Text(LocalizedStringKey(document.precision == .word ? "lyrics.precision.word" : "lyrics.precision.line"))
                    Text(LocalizedStringKey(lyrics.selection.candidate == nil ? "lyrics.match.auto" : "lyrics.match.manual"))
                    Text(String(format: "%+.1f s", lyrics.selection.offset)).monospacedDigit()
                }.font(.caption).foregroundStyle(.secondary)
                if let saved = lyrics.savedAt {
                    Text(saved, format: .dateTime.year().month().day()).font(.caption)
                }
                DisclosureGroup("lyrics.evidence") {
                    Text(document.candidate.evidence.joined(separator: " · "))
                    Text(document.language + " · " + document.selectionReason)
                    Text(String(format: "word %.0f%% · translation %.0f%% · romanization %.0f%%",
                                document.wordTimedLineRatio * 100, document.translationCoverage * 100,
                                document.romanizationCoverage * 100))
                    if let degradationReason = document.degradationReason {
                        Text(degradationReason).foregroundStyle(.orange)
                    }
                    if let author = document.lyricAuthor {
                        Text(author)
                    }
                    if !document.songwriters.isEmpty {
                        Text(document.songwriters.joined(separator: ", "))
                    }
                }.font(.caption)
                TimelineView(.periodic(from: .now, by: 0.2)) { _ in
                    let position = model.progress() - lyrics.effectiveOffset
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(document.lines) { line in
                            LyricDiagnosticRow(line: line, active: position >= line.start && position < line.end)
                        }
                    }
                }
            }
            ForEach(LyricsSource.allCases) { source in
                if let message = lyrics.errors[source] {
                    Text(source.name + ": " + message).font(.caption).foregroundStyle(.secondary)
                }
            }
            if let warning = lyrics.cacheWarning {
                Text(warning).font(.caption).foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("lyricsDiagnostic")
    }
}

struct LyricsQuickMenu: View {
    @Bindable var coordinator: LyricsCoordinator
    var showSearch: () -> Void

    var body: some View {
        Menu {
            Button("lyrics.find", systemImage: "magnifyingglass", action: showSearch)
            Button("lyrics.refresh", systemImage: "arrow.clockwise") { coordinator.reload(force: true) }
            Button("lyrics.automatic", systemImage: "arrow.uturn.backward") { coordinator.restoreAutomatic() }
            Divider()
            Button("lyrics.offset.minus") { coordinator.setOffset(coordinator.selection.offset - 0.1) }
            Button("lyrics.offset.plus") { coordinator.setOffset(coordinator.selection.offset + 0.1) }
            Button("lyrics.offset.zero") { coordinator.setOffset(0) }
        } label: {
            Label("lyrics.actions", systemImage: "quote.bubble")
        }
        .accessibilityIdentifier("lyricsActions")
        .disabled(coordinator.track == nil || !coordinator.settings.enabled)
    }
}

private struct LyricDiagnosticRow: View {
    let line: LyricLine
    var active = false
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                if line.isBackground {
                    Text("lyrics.background").font(.caption2)
                }
                if line.isDuet {
                    Image(systemName: "person.2")
                }
                Text(line.text).fontWeight(active ? .bold : .regular)
                    .environment(\.layoutDirection, line.isRTL ? .rightToLeft : .leftToRight)
            }.foregroundStyle(active ? Color.accentColor : Color.primary)
            if !line.translation.isEmpty {
                Text(line.translation).font(.subheadline).foregroundStyle(.secondary)
            }
            if !line.romanization.isEmpty {
                Text(line.romanization).font(.caption).foregroundStyle(.secondary)
            }
            DisclosureGroup(String(format: "%.3f – %.3f s", line.start, line.end)) {
                ForEach(Array(line.words.enumerated()), id: \.offset) { _, word in
                    Text(String(format: "%.3f–%.3f  ", word.start, word.end) + word.text + (word.romanWord.map { " · " + $0 } ?? ""))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }.font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .contain)
    }
}

struct LyricsSearchView: View {
    @Bindable var coordinator: LyricsCoordinator
    @Environment(\.dismiss) private var dismiss
    @Environment(\.lyricsQuickSettingsNavigation) private var quickSettingsNavigation
    @State private var query = ""
    @State private var selected: LyricCandidate?
    var body: some View {
        NavigationStack {
            List {
                if let track = coordinator.track {
                    Section { Text(track.query).font(.subheadline) }
                }
                if quickSettingsNavigation != nil, !coordinator.searchErrors.isEmpty, coordinator.searching.isEmpty {
                    Section {
                        Button("player.tryAgain", systemImage: "arrow.clockwise") { coordinator.search(query) }
                    }
                }
                ForEach(coordinator.settings.priority) { source in
                    Section(source.name) {
                        if coordinator.searching.contains(source) {
                            ProgressView()
                        }
                        ForEach(coordinator.candidates[source] ?? []) { candidate in
                            Button { selected = candidate } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(candidate.title).foregroundStyle(.primary)
                                    Text(candidate.artists.joined(separator: ", ") + " · " + candidate.album).font(.caption).foregroundStyle(.secondary)
                                    Text("\(candidate.score)% · " + candidate.evidence.joined(separator: " · ")).font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                        if let error = coordinator.searchErrors[source] {
                            Text(error).font(.caption).foregroundStyle(.secondary)
                        } else if !coordinator.searching.contains(source), coordinator.candidates[source]?.isEmpty == true {
                            Text("lyrics.error.notFound")
                        }
                    }
                }
            }
            .navigationTitle("lyrics.find")
            .modifier(LyricsSearchField(query: $query, inline: quickSettingsNavigation != nil))
            .lyricsQuickSettingsDestination("lyrics.find")
            .task(id: query) {
                coordinator.cancelSearch()
                do { try await Task.sleep(for: .milliseconds(350)); try Task.checkCancellation(); coordinator.search(query) }
                catch {}
            }
            .toolbar {
                if quickSettingsNavigation == nil {
                    ToolbarItem(placement: .cancellationAction) { Button("common.done", action: close).keyboardShortcut(.cancelAction) }
                }
            }
            .sheet(item: $selected) { candidate in
                LyricsPreviewView(coordinator: coordinator, candidate: candidate, onApply: close)
            }
        }
        .onDisappear { coordinator.cancelSearch() }
        .onChange(of: coordinator.track?.spotifyID) { _, _ in close() }
    }

    private func close() {
        if let quickSettingsNavigation { quickSettingsNavigation.close() }
        else { dismiss() }
    }
}

private struct LyricsSearchField: ViewModifier {
    @Binding var query: String
    let inline: Bool

    func body(content: Content) -> some View {
        if inline {
            content
                .scrollDismissesKeyboard(.interactively)
                .safeAreaInset(edge: .top, spacing: 0) {
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                        TextField("lyrics.search.prompt", text: $query)
                            .submitLabel(.search)
                            .accessibilityIdentifier("quickSettingsLyricsSearchField")
                        if !query.isEmpty {
                            Button("Clear search", systemImage: "xmark.circle.fill") { query = "" }
                                .labelStyle(.iconOnly)
                                .frame(width: 44, height: 44)
                                .buttonStyle(MusicContentButtonStyle())
                        }
                    }
                    .padding(.horizontal, 12)
                    .frame(minHeight: 44)
                    .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 13))
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
                }
        } else {
            content.searchable(text: $query, prompt: "lyrics.search.prompt")
        }
    }
}

private struct LyricsPreviewView: View {
    @Bindable var coordinator: LyricsCoordinator
    let candidate: LyricCandidate
    var onApply: () -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section { Text(candidate.title); Text(candidate.source.name + " · " + candidate.artists.joined(separator: ", ")) }
                if coordinator.isPreviewing {
                    ProgressView("lyrics.preview.loading")
                }
                if let error = coordinator.previewError {
                    Text(error)
                }
                if let preview = coordinator.preview, preview.candidate.id == candidate.id {
                    if preview.isInstrumental {
                        Text("lyrics.status.instrumental")
                    }
                    ForEach(preview.lines) { line in LyricDiagnosticRow(line: line) }
                }
            }
            .navigationTitle("lyrics.preview")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("common.done") { dismiss() }.keyboardShortcut(.cancelAction) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("lyrics.apply") { coordinator.applyPreview(); dismiss(); onApply() }
                        .disabled(coordinator.preview?.candidate.id != candidate.id || coordinator.isPreviewing)
                        .accessibilityIdentifier("lyricsApply")
                }
            }
            .task { coordinator.preview(candidate) }
            .onDisappear { coordinator.cancelPreview() }
            .onChange(of: coordinator.track?.spotifyID) { _, _ in dismiss() }
        }
    }
}

struct LyricsSettingsView: View {
    @Bindable var coordinator: LyricsCoordinator
    @Environment(\.lyricsQuickSettingsNavigation) private var quickSettingsNavigation
    @State private var draft = LyricsSettings()
    @State private var editMode: EditMode = .inactive
    @State private var confirm: DestructiveAction?
    private enum DestructiveAction: String, Identifiable { case cache, matches; var id: String {
        rawValue
    } }
    var body: some View {
        Form {
            Section {
                Toggle("lyrics.enabled", isOn: $draft.enabled.hapticSelection())
                NavigationLink {
                    AppleLyricsSettingsView(coordinator: coordinator)
                        .toolbar(.visible, for: .navigationBar)
                } label: {
                    Label("lyrics.apple.settings", systemImage: "music.note")
                }
            }
            Section {
                ForEach(draft.priority) { source in Text(source.name) }
                    .onMove { from, to in draft.priority.move(fromOffsets: from, toOffset: to) }
            } header: { Text("lyrics.priority") }
            Section {
                Toggle("lyrics.cache.enabled", isOn: $draft.cacheEnabled.hapticSelection())
                Stepper(value: $draft.refreshDays, in: 0 ... 3650) { LabeledContent("lyrics.cache.days", value: "\(draft.refreshDays)") }
                SettingsTextButton(title: "lyrics.cache.clear", icon: "trash", role: .destructive) { confirm = .cache }
                    .listRowBackground(Color.clear)
                SettingsTextButton(title: "lyrics.matches.reset", icon: "arrow.counterclockwise", role: .destructive) { confirm = .matches }
                    .listRowBackground(Color.clear)
            } header: { Text("lyrics.cache") }
            if coordinator.track != nil {
                Section {
                    Slider(value: Binding(get: { coordinator.selection.offset }, set: { coordinator.setOffset($0) }), in: -10 ... 10, step: 0.1)
                    Text(String(format: "%+.1f s", coordinator.selection.offset)).monospacedDigit()
                    SettingsTextButton(title: "lyrics.offset.zero", icon: "arrow.counterclockwise") { coordinator.setOffset(0) }
                        .listRowBackground(Color.clear)
                } header: { Text("lyrics.offset") }
            }
            if let warning = coordinator.cacheWarning {
                Section { Text(warning).foregroundStyle(.orange) }
            }
        }
        .navigationTitle("lyrics.settings")
        .lyricsQuickSettingsDestination("lyrics.settings", showsEditButton: true)
        .toolbar { if quickSettingsNavigation == nil { EditButton() } }
        .environment(\.editMode, $editMode)
        .onAppear { draft = coordinator.settings }
        .onChange(of: draft) { _, value in coordinator.updateSettings(value) }
        .confirmationDialog("lyrics.confirm", isPresented: Binding(get: { confirm != nil }, set: {
            if !$0 {
                confirm = nil
            }
        })) {
            if confirm == .cache {
                Button("lyrics.cache.clear", role: .destructive) { coordinator.clearCache(); confirm = nil }
            }
            if confirm == .matches {
                Button("lyrics.matches.reset", role: .destructive) { coordinator.resetMatches(); confirm = nil }
            }
        } message: { Text(LocalizedStringKey(confirm == .cache ? "lyrics.cache.clear.help" : "lyrics.matches.reset.help")) }
    }
}

private struct AppleLyricsSettingsView: View {
    @Bindable var coordinator: LyricsCoordinator
    @State private var storefront = ""
    @State private var language = ""
    @State private var media = ""
    @State private var manual = ""
    @State private var feedback = ""
    @State private var automatic = ""
    @State private var hasMedia = false
    @State private var hasManual = false
    @State private var busy = false
    @State private var deleting: String?
    var body: some View {
        SettingsPage {
            SettingsSection("lyrics.apple.region") {
                TextField("lyrics.apple.storefront", text: $storefront).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .settingsSurface()
                TextField("lyrics.apple.language", text: $language).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .settingsSurface()
                SettingsTextButton(title: "lyrics.save", icon: "checkmark") {
                    var settings = coordinator.settings; settings.storefront = storefront; settings.language = language
                    coordinator.updateSettings(settings); storefront = coordinator.settings.storefront; language = coordinator.settings.language
                }
            }
            SettingsSection("lyrics.apple.account") {
                SecureField("media-user-token", text: $media).textInputAutocapitalization(.never).autocorrectionDisabled().privacySensitive()
                    .settingsSurface()
                Text(LocalizedStringKey(hasMedia ? "lyrics.credential.saved" : "lyrics.credential.empty")).font(.caption)
                SettingsTextButton(title: "lyrics.credential.saveMedia", icon: "checkmark") {
                    perform { try coordinator.apple?.credentials.saveMedia(media); media = "" }
                }
                    .disabled(media.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                SettingsTextButton(title: "lyrics.credential.deleteMedia", icon: "trash", role: .destructive) { deleting = "media" }
            }
            SettingsSection("lyrics.apple.bearer") {
                Text(automatic).font(.caption)
                SettingsTextButton(title: "lyrics.apple.discover", icon: "arrow.clockwise") {
                    busy = true
                    Task {
                        defer { busy = false; refreshStatus() }
                        do { _ = try await coordinator.apple?.bearer(force: true); feedback = NSLocalizedString("lyrics.apple.discovered", comment: "") }
                        catch { feedback = LyricsCoordinator.safeError(error) }
                    }
                }.disabled(busy)
                SettingsTextButton(title: "lyrics.apple.clearAutomatic", icon: "trash", role: .destructive) { deleting = "automatic" }
                SecureField("Authorization Bearer", text: $manual).textInputAutocapitalization(.never).autocorrectionDisabled().privacySensitive()
                    .settingsSurface()
                Text(LocalizedStringKey(hasManual ? "lyrics.credential.saved" : "lyrics.credential.empty")).font(.caption)
                SettingsTextButton(title: "lyrics.credential.saveManual", icon: "checkmark") {
                    perform { try coordinator.apple?.credentials.saveManual(manual); manual = "" }
                }
                    .disabled(manual.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                SettingsTextButton(title: "lyrics.credential.deleteManual", icon: "trash", role: .destructive) { deleting = "manual" }
            }
            SettingsSection("lyrics.apple.diagnostics") {
                SettingsTextButton(title: "lyrics.apple.testCatalog", icon: "stethoscope") { Task { await coordinator.testApple(account: false) } }
                SettingsTextButton(title: "lyrics.apple.testAccount", icon: "person.crop.circle.badge.checkmark") { Task { await coordinator.testApple(account: true) } }
                if coordinator.isTestingApple {
                    ProgressView()
                }
                Text(coordinator.appleStatus).font(.caption)
                if !feedback.isEmpty { Text(feedback).font(.caption) }
                SettingsTextButton(title: "lyrics.credential.deleteAll", icon: "trash", role: .destructive) { deleting = "all" }
            }.disabled(coordinator.isTestingApple || busy)
        }
        .navigationTitle("lyrics.apple.settings")
        .onAppear { storefront = coordinator.settings.storefront; language = coordinator.settings.language; refreshStatus() }
        .onDisappear { media = ""; manual = "" }
        .confirmationDialog("lyrics.confirm", isPresented: Binding(get: { deleting != nil }, set: {
            if !$0 {
                deleting = nil
            }
        })) {
            Button("lyrics.delete", role: .destructive) {
                perform {
                    switch deleting {
                    case "media": try coordinator.apple?.credentials.saveMedia("")
                    case "manual": try coordinator.apple?.credentials.saveManual("")
                    case "automatic": try coordinator.apple?.credentials.clearAutomatic()
                    default: try coordinator.apple?.credentials.clearAll()
                    }
                }
                deleting = nil
            }
        } message: { Text("lyrics.credential.delete.help") }
    }

    private func perform(_ action: () throws -> Void) {
        do { try action(); feedback = NSLocalizedString("lyrics.saved", comment: "") }
        catch { feedback = LyricsCoordinator.safeError(error) }
        coordinator.credentialsChanged(); refreshStatus()
    }

    private func refreshStatus() {
        hasMedia = (try? coordinator.apple?.credentials.mediaToken()) != nil
        hasManual = (try? coordinator.apple?.credentials.manualToken()) != nil
        if let info = try? coordinator.apple?.credentials.cachedBearer() {
            automatic = NSLocalizedString("lyrics.apple.expires", comment: "") + " " + info.expiration.formatted()
        } else {
            automatic = NSLocalizedString("lyrics.apple.noAutomatic", comment: "")
        }
    }
}
