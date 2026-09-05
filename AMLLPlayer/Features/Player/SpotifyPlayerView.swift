import SwiftUI

struct SpotifyPlayerView: View {
    @Bindable var model: AppModel
    @State private var isShowingDevices = false

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if !model.environment.configuration.isSpotifyConfigured {
                    ContentUnavailableView(
                        "player.configurationRequired",
                        systemImage: "key.slash",
                        description: Text("foundation.spotifyClientID.help")
                    )
                } else {
                    content
                }
            }
            .navigationTitle("player.title")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if model.sessionState.isAuthenticated {
                        Button("player.devices", systemImage: "airplayaudio") {
                            isShowingDevices = true
                            Task { await model.loadDevices() }
                        }
                    }

                    NavigationLink {
                        SettingsView(model: model)
                    } label: {
                        Label("settings.open", systemImage: "gearshape")
                    }
                    .accessibilityIdentifier("openSettings")
                }
            }
            .sheet(isPresented: $isShowingDevices) {
                DevicePickerView(model: model)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.sessionState {
        case .signedOut:
            ContentUnavailableView {
                Label("player.connectTitle", systemImage: "person.crop.circle.badge.plus")
            } description: {
                Text("player.connectDescription")
            } actions: {
                Button("player.connect", action: model.authorize)
                    .buttonStyle(.borderedProminent)
            }
        case .authorizing:
            ProgressView("player.authorizing")
        case .refreshing:
            ProgressView("player.refreshingSession")
        case .authenticated:
            playerContent
        case let .failed(error):
            ContentUnavailableView {
                Label("player.connectionFailed", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error.localizedDescription)
            } actions: {
                Button("player.tryAgain", action: model.authorize)
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    @ViewBuilder
    private var playerContent: some View {
        if let snapshot = model.playbackSnapshot,
           let item = snapshot.item
        {
            ScrollView {
                VStack(spacing: 24) {
                    artwork(item)
                    VStack(spacing: 6) {
                        Text(item.title)
                            .font(.title2.bold())
                            .multilineTextAlignment(.center)
                        Text(item.artistLine)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }

                    ProgressControl(model: model, snapshot: snapshot)
                    PlaybackControls(model: model, snapshot: snapshot)

                    if let device = snapshot.device {
                        DeviceSummaryView(model: model, device: device)
                    }

                    Label(
                        snapshot.source == .appRemote
                            ? "player.source.appRemote" : "player.source.webAPI",
                        systemImage: snapshot.source == .appRemote
                            ? "bolt.horizontal.circle" : "network"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    LyricsDiagnosticView(model: model)
                }
                .padding()
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
            }
            .accessibilityIdentifier("playerScroll")
            .refreshable {
                await model.refreshPlayback()
            }
        } else {
            ContentUnavailableView {
                Label("player.noPlayback", systemImage: "music.note")
            } description: {
                Text("player.noPlaybackDescription")
            } actions: {
                Button("player.refresh") {
                    Task { await model.refreshPlayback() }
                }
                Button("player.chooseDevice") {
                    isShowingDevices = true
                    Task { await model.loadDevices() }
                }
            }
        }
    }

    @ViewBuilder
    private func artwork(_ item: PlaybackItem) -> some View {
        if let artworkURL = item.artworkURL {
            AsyncImage(url: artworkURL) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                artworkPlaceholder
            }
            .frame(width: 260, height: 260)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        } else {
            artworkPlaceholder
                .frame(width: 260, height: 260)
        }
    }

    private var artworkPlaceholder: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(.quaternary)
            .overlay {
                Image(systemName: "music.note")
                    .font(.system(size: 60))
                    .foregroundStyle(.secondary)
            }
    }
}

private struct PlaybackControls: View {
    @Bindable var model: AppModel
    let snapshot: PlaybackSnapshot

    var body: some View {
        HStack(spacing: 34) {
            Button("player.previous", systemImage: "backward.fill") {
                Task { await model.skipPrevious() }
            }
            .labelStyle(.iconOnly)
            .disabled(
                model.isPerformingAction || !snapshot.restrictions.canSkipPrevious
            )

            Button(
                snapshot.isPlaying ? "player.pause" : "player.play",
                systemImage: snapshot.isPlaying ? "pause.circle.fill" : "play.circle.fill"
            ) {
                Task { await model.togglePlayPause() }
            }
            .labelStyle(.iconOnly)
            .font(.system(size: 52))
            .disabled(model.isPerformingAction)

            Button("player.next", systemImage: "forward.fill") {
                Task { await model.skipNext() }
            }
            .labelStyle(.iconOnly)
            .disabled(model.isPerformingAction || !snapshot.restrictions.canSkipNext)
        }
        .font(.title2)
        .buttonStyle(.plain)
    }
}

private struct ProgressControl: View {
    @Bindable var model: AppModel
    let snapshot: PlaybackSnapshot
    @State private var isSeeking = false
    @State private var draftPosition: TimeInterval = 0

    var body: some View {
        TimelineView(
            .animation(minimumInterval: 1 / 30, paused: !snapshot.isPlaying)
        ) { _ in
            let livePosition = model.progress()
            VStack(spacing: 4) {
                Slider(
                    value: Binding(
                        get: { isSeeking ? draftPosition : livePosition },
                        set: { draftPosition = $0 }
                    ),
                    in: 0...max(snapshot.duration, 1),
                    onEditingChanged: { editing in
                        if editing {
                            isSeeking = true
                            draftPosition = livePosition
                        } else {
                            isSeeking = false
                            Task { await model.seek(to: draftPosition) }
                        }
                    }
                )
                .disabled(!snapshot.restrictions.canSeek)

                HStack {
                    Text(format(isSeeking ? draftPosition : livePosition))
                    Spacer()
                    Text(format(snapshot.duration))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
        }
    }

    private func format(_ value: TimeInterval) -> String {
        let seconds = max(0, Int(value.rounded(.down)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

private struct DeviceSummaryView: View {
    @Bindable var model: AppModel
    let device: PlaybackDevice
    @State private var isEditingVolume = false
    @State private var draftVolume = 0.0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(device.name, systemImage: "hifispeaker")
                .font(.headline)

            if device.supportsVolume, let volume = device.volumePercent {
                HStack {
                    Image(systemName: "speaker.fill")
                    Slider(
                        value: Binding(
                            get: { isEditingVolume ? draftVolume : Double(volume) },
                            set: { draftVolume = $0 }
                        ),
                        in: 0...100,
                        onEditingChanged: { editing in
                            if editing {
                                isEditingVolume = true
                                draftVolume = Double(volume)
                            } else {
                                isEditingVolume = false
                                Task {
                                    await model.setVolume(
                                        percent: Int(draftVolume.rounded()),
                                        deviceID: device.id
                                    )
                                }
                            }
                        }
                    )
                    Image(systemName: "speaker.wave.3.fill")
                }
            }

            if device.isRestricted {
                Label("player.deviceRestricted", systemImage: "lock.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

struct DevicePickerView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                switch model.devicesState {
                case .idle, .loading:
                    ProgressView("player.loadingDevices")
                case let .loaded(devices):
                    if devices.isEmpty {
                        ContentUnavailableView(
                            "player.noDevices",
                            systemImage: "airplayaudio",
                            description: Text("player.noDevicesDescription")
                        )
                    } else {
                        List(devices) { device in
                            Button {
                                Task {
                                    await model.transferPlayback(to: device.id)
                                    dismiss()
                                }
                            } label: {
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(device.name)
                                        Text(device.type)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if device.isActive {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(.green)
                                    }
                                    if device.isRestricted {
                                        Image(systemName: "lock.fill")
                                            .foregroundStyle(.orange)
                                    }
                                }
                            }
                            .disabled(device.isRestricted || model.isPerformingAction)
                        }
                        .refreshable { await model.loadDevices() }
                    }
                case let .failed(error):
                    ContentUnavailableView {
                        Label("player.deviceLoadFailed", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(error.localizedDescription)
                    } actions: {
                        Button("player.tryAgain") {
                            Task { await model.loadDevices() }
                        }
                    }
                }
            }
            .navigationTitle("player.devices")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("common.done") { dismiss() }
                }
            }
        }
    }
}
