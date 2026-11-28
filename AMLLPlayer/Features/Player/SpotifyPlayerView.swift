import SwiftUI

struct DevicePickerView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.lyricsQuickSettingsNavigation) private var quickSettingsNavigation

    var body: some View {
        NavigationStack {
            Group {
                if model.selectedMusicService != .spotify {
                    SystemMusicRoutesView()
                } else {
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
                                        close()
                                    }
                                } label: {
                                    HStack(spacing: 12) {
                                        SettingsIconBadge(
                                            systemImage: deviceIcon(for: device.type),
                                            color: device.isActive ? MusicProductStyle.accent : .secondary
                                        )
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(device.name)
                                                .font(.body.weight(device.isActive ? .semibold : .regular))
                                                .foregroundStyle(.primary)
                                            Text(device.type)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        if device.isActive {
                                            Image(systemName: "checkmark.circle.fill")
                                                .foregroundStyle(MusicProductStyle.accent)
                                                .accessibilityLabel("player.device.active")
                                        }
                                        if device.isRestricted {
                                            Image(systemName: "lock.fill")
                                                .foregroundStyle(.orange)
                                                .accessibilityLabel("player.device.restricted")
                                        }
                                    }
                                    .frame(minHeight: 46)
                                }
                                .disabled(device.isRestricted || model.isPerformingAction)
                            }
                            .listStyle(.insetGrouped)
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
            }
            .navigationTitle("player.devices")
            .lyricsQuickSettingsDestination("player.devices")
            .toolbar {
                if quickSettingsNavigation == nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("common.done", action: close)
                    }
                }
            }
        }
    }

    private func close() {
        if let quickSettingsNavigation { quickSettingsNavigation.close() }
        else { dismiss() }
    }

    private func deviceIcon(for type: String) -> String {
        switch type.lowercased() {
        case let value where value.contains("phone"): "iphone"
        case let value where value.contains("tablet"), let value where value.contains("ipad"): "ipad"
        case let value where value.contains("computer"), let value where value.contains("mac"): "laptopcomputer"
        case let value where value.contains("speaker"): "hifispeaker"
        case let value where value.contains("tv"): "tv"
        default: "airplayaudio"
        }
    }
}
