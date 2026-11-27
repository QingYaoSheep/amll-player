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
                                    if AppDiagnosticsVisibility.shared.isUnlocked {
                                        Text("\(candidate.score)% · " + candidate.evidence.joined(separator: " · ")).font(.caption2).foregroundStyle(.secondary)
                                    }
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
                            Button("lyrics.clearSearch", systemImage: "xmark.circle.fill") { query = "" }
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
                    ForEach(preview.lines) { line in
                        if AppDiagnosticsVisibility.shared.isUnlocked {
                            LyricDiagnosticRow(line: line)
                        } else {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(line.text)
                                if let translation = line.translation, !translation.isEmpty {
                                    Text(translation).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
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
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var draft = LyricsSettings()
    @State private var editMode: EditMode = .inactive
    @State private var confirm: DestructiveAction?
    private enum DestructiveAction { case cache, matches }

    var body: some View {
        List {
            Section {
                Toggle(isOn: $draft.enabled.hapticSelection()) {
                    SettingsIconToggleLabel(title: "lyrics.enabled", icon: "quote.bubble", color: MusicProductStyle.accent)
                }
                .modifier(LyricsListRowStyle(background: rowCardFill))

                NavigationLink {
                    AppleLyricsSettingsView(coordinator: coordinator)
                        .toolbar(.visible, for: .navigationBar)
                } label: {
                    HStack(spacing: 12) {
                        SettingsIconBadge(systemImage: "music.note", color: MusicServiceID.appleMusic.brandColor)
                        Text("lyrics.apple.settings")
                            .font(.body)
                    }
                }
                .modifier(LyricsListRowStyle(background: rowCardFill))
            }

            Section {
                ForEach(draft.priority) { source in
                    Text(source.name)
                        .font(.body)
                        .frame(minHeight: 44, alignment: .leading)
                        .modifier(LyricsListRowStyle(background: rowCardFill))
                }
                .onMove { from, to in draft.priority.move(fromOffsets: from, toOffset: to) }
            } header: { sectionTitle("lyrics.priority") }

            Section {
                Toggle("lyrics.cache.enabled", isOn: $draft.cacheEnabled.hapticSelection())
                    .modifier(LyricsListRowStyle(background: rowCardFill))
                Stepper(value: $draft.refreshDays, in: 0 ... 3650) {
                    LabeledContent("lyrics.cache.days", value: draft.refreshDays.formatted())
                        .monospacedDigit()
                }
                .modifier(LyricsListRowStyle(background: rowCardFill))
            } header: { sectionTitle("lyrics.cache") }
            .accessibilityIdentifier("lyricsSettingsCacheControls")

            if coordinator.track != nil {
                Section {
                    trackOffsetCard
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                        .listRowBackground(rowCardFill)
                }
            }

            Section {
                Button(role: .destructive) { confirm = .cache } label: {
                    HStack(spacing: 12) {
                        SettingsIconBadge(systemImage: "trash", color: .red)
                        Text("lyrics.cache.clear")
                            .foregroundStyle(.red)
                    }
                }
                .modifier(LyricsListRowStyle(background: rowCardFill))

                Button(role: .destructive) { confirm = .matches } label: {
                    HStack(spacing: 12) {
                        SettingsIconBadge(systemImage: "arrow.counterclockwise", color: .red)
                        Text("lyrics.matches.reset")
                            .foregroundStyle(.red)
                    }
                }
                .modifier(LyricsListRowStyle(background: rowCardFill))
            } header: { sectionTitle("lyrics.maintenance") }

            if let warning = coordinator.cacheWarning {
                Section {
                    Text(warning)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .modifier(LyricsListRowStyle(background: rowCardFill))
                }
            }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(18)
        .scrollContentBackground(.hidden)
        .frame(maxWidth: 600)
        .frame(maxWidth: .infinity)
        .background {
            if quickSettingsNavigation == nil { Color(uiColor: .systemGroupedBackground).ignoresSafeArea() }
        }
        .accessibilityIdentifier("lyricsSettingsList")
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

    private var rowCardFill: Color {
        if quickSettingsNavigation != nil {
            return reduceTransparency ? Color(uiColor: .secondarySystemBackground) : .white.opacity(0.09)
        }
        return Color(uiColor: .secondarySystemGroupedBackground)
    }

    private var trackOffsetCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("lyrics.offset")
                    .font(.body)
                Spacer(minLength: 8)
                Text(String(format: "%+.1f s", coordinator.selection.offset))
                    .font(.subheadline.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .background(Color.primary.opacity(0.06), in: Capsule())
                    .accessibilityIdentifier("lyricsSettingsOffsetReadout")
            }

            Slider(
                value: Binding(get: { coordinator.selection.offset }, set: { coordinator.setOffset($0) }),
                in: -10 ... 10, step: 0.1
            )
            .accessibilityLabel(Text("lyrics.offset"))
            .accessibilityIdentifier("lyricsSettingsOffsetSlider")

            HStack(spacing: 8) {
                offsetStepButton("−0.1 s", delta: -0.1)
                    .accessibilityLabel(Text("lyrics.offset.minus"))
                offsetStepButton("+0.1 s", delta: 0.1)
                    .accessibilityLabel(Text("lyrics.offset.plus"))
                Spacer(minLength: 4)
                Button {
                    coordinator.setOffset(0)
                } label: {
                    Label("lyrics.offset.zero", systemImage: "arrow.counterclockwise")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(MusicProductStyle.accent)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(MusicProductStyle.accent.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
                .accessibilityIdentifier("lyricsSettingsOffsetReset")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private func offsetStepButton(_ title: String, delta: Double) -> some View {
        Button {
            coordinator.setOffset(coordinator.selection.offset + delta)
        } label: {
            Text(title)
                .font(.footnote.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(.primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Color.primary.opacity(0.06), in: Capsule())
        }
        .buttonStyle(.plain)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }

    private func sectionTitle(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(nil)
            .accessibilityAddTraits(.isHeader)
    }
}

private struct LyricsListRowStyle: ViewModifier {
    let background: Color

    func body(content: Content) -> some View {
        content
            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
            .listRowSeparatorTint(Color.primary.opacity(0.09))
            .listRowBackground(background)
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
                SettingsGroup {
                    TextField("lyrics.apple.storefront", text: $storefront)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .padding(.horizontal, 16)
                        .padding(.vertical, 13)
                    SettingsDivider(inset: 16)
                    TextField("lyrics.apple.language", text: $language)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .padding(.horizontal, 16)
                        .padding(.vertical, 13)
                    SettingsDivider()
                    SettingsTextButton(title: "lyrics.save", icon: "checkmark", iconColor: MusicProductStyle.accent, inGroup: true) {
                        var settings = coordinator.settings; settings.storefront = storefront; settings.language = language
                        coordinator.updateSettings(settings); storefront = coordinator.settings.storefront; language = coordinator.settings.language
                    }
                }
            }

            SettingsSection("lyrics.apple.account") {
                SettingsGroup {
                    SecureField("media-user-token", text: $media)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .privacySensitive()
                        .padding(.horizontal, 16)
                        .padding(.vertical, 13)
                    SettingsDivider(inset: 16)
                    SettingsInfoRow(
                        title: "media-user-token",
                        value: String(localized: hasMedia ? "lyrics.credential.saved" : "lyrics.credential.empty"),
                        valueColor: hasMedia ? MusicProductStyle.accent : .secondary
                    )
                    SettingsDivider()
                    SettingsTextButton(title: "lyrics.credential.saveMedia", icon: "checkmark", iconColor: MusicProductStyle.accent, inGroup: true) {
                        perform { try coordinator.apple?.credentials.saveMedia(media); media = "" }
                    }
                    .disabled(media.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    SettingsDivider()
                    SettingsTextButton(title: "lyrics.credential.deleteMedia", icon: "trash", role: .destructive, inGroup: true) {
                        deleting = "media"
                    }
                }
            }

            SettingsSection("lyrics.apple.bearer") {
                SettingsGroup {
                    Text(automatic)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                    SettingsDivider()
                    SettingsTextButton(title: "lyrics.apple.discover", icon: "arrow.clockwise", iconColor: MusicProductStyle.accent, inGroup: true) {
                        busy = true
                        Task {
                            defer { busy = false; refreshStatus() }
                            do { _ = try await coordinator.apple?.bearer(force: true); feedback = NSLocalizedString("lyrics.apple.discovered", comment: "") }
                            catch { feedback = LyricsCoordinator.safeError(error) }
                        }
                    }
                    .disabled(busy)
                    SettingsDivider()
                    SettingsTextButton(title: "lyrics.apple.clearAutomatic", icon: "trash", role: .destructive, inGroup: true) {
                        deleting = "automatic"
                    }
                    SettingsDivider(inset: 16)
                    SecureField("Authorization Bearer", text: $manual)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .privacySensitive()
                        .padding(.horizontal, 16)
                        .padding(.vertical, 13)
                    SettingsDivider(inset: 16)
                    SettingsInfoRow(
                        title: "Authorization Bearer",
                        value: String(localized: hasManual ? "lyrics.credential.saved" : "lyrics.credential.empty"),
                        valueColor: hasManual ? MusicProductStyle.accent : .secondary
                    )
                    SettingsDivider()
                    SettingsTextButton(title: "lyrics.credential.saveManual", icon: "checkmark", iconColor: MusicProductStyle.accent, inGroup: true) {
                        perform { try coordinator.apple?.credentials.saveManual(manual); manual = "" }
                    }
                    .disabled(manual.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    SettingsDivider()
                    SettingsTextButton(title: "lyrics.credential.deleteManual", icon: "trash", role: .destructive, inGroup: true) {
                        deleting = "manual"
                    }
                }
            }

            SettingsSection("lyrics.apple.diagnostics") {
                SettingsGroup {
                    SettingsTextButton(title: "lyrics.apple.testCatalog", icon: "stethoscope", iconColor: MusicProductStyle.accent, inGroup: true) {
                        Task { await coordinator.testApple(account: false) }
                    }
                    SettingsDivider()
                    SettingsTextButton(title: "lyrics.apple.testAccount", icon: "person.crop.circle.badge.checkmark", iconColor: MusicServiceID.appleMusic.brandColor, inGroup: true) {
                        Task { await coordinator.testApple(account: true) }
                    }
                    if coordinator.isTestingApple {
                        SettingsDivider(inset: 16)
                        HStack {
                            ProgressView()
                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                    }
                    SettingsDivider(inset: 16)
                    Text(coordinator.appleStatus)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                    if !feedback.isEmpty {
                        SettingsDivider(inset: 16)
                        Text(feedback)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                    }
                    SettingsDivider()
                    SettingsTextButton(title: "lyrics.credential.deleteAll", icon: "trash", role: .destructive, inGroup: true) {
                        deleting = "all"
                    }
                }
            }
            .disabled(coordinator.isTestingApple || busy)
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
