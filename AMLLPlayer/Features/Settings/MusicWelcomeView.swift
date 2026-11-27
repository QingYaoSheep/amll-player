import SwiftUI

struct MusicWelcomeView: View {
    @Bindable var model: AppModel
    var complete: () -> Void

    var body: some View {
        NavigationStack {
            SettingsPage {
                SettingsGroup(radius: SettingsCorners.hero) {
                    VStack(alignment: .leading, spacing: 14) {
                        Image("LaunchMark")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 64, height: 64)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                            }
                            .accessibilityHidden(true)

                        Text("连接音乐服务")
                            .font(.largeTitle.bold())
                            .accessibilityAddTraits(.isHeader)

                        Text("welcome.subtitle")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(20)
                }

                SettingsSection {
                    SettingsGroup {
                        ForEach(Array(MusicServiceID.allCases.enumerated()), id: \.element.id) { index, service in
                            if index > 0 { SettingsDivider() }
                            NavigationLink {
                                MusicLoginDestination(model: model, service: service)
                                    .toolbar {
                                        ToolbarItem(placement: .confirmationAction) { Button("common.done", action: complete) }
                                    }
                            } label: {
                                SettingsRowLabel(
                                    title: LocalizedStringKey(service.title),
                                    icon: service.settingsIcon,
                                    iconColor: service.brandColor,
                                    navigates: true
                                )
                            }
                            .buttonStyle(SettingsRowButtonStyle())
                        }
                    }
                }

                Button(action: complete) {
                    SettingsActionLabel(title: "稍后设置", icon: "arrow.right", iconColor: MusicProductStyle.accent)
                }
                .buttonStyle(SettingsButtonStyle())
                .accessibilityIdentifier("skipMusicWelcome")
            }
        }
        .tint(MusicProductStyle.accent)
        .interactiveDismissDisabled()
        .onChange(of: model.spotifyCatalog.active) { _, active in
            if active && model.sessionState.isAuthenticated {
                model.selectMusicService(.spotify)
            }
        }
        .onChange(of: model.appleMusicState.connected) { _, connected in
            if connected {
                model.selectMusicService(.appleMusic)
                complete()
            }
        }
        .onChange(of: model.netEaseState.connected) { _, connected in
            if connected {
                model.selectMusicService(.netease)
                complete()
            }
        }
        .onChange(of: model.sessionState.isAuthenticated) { _, connected in
            if connected {
                model.selectMusicService(.spotify)
                complete()
            }
        }
        .onChange(of: model.currentServiceConnected) { _, connected in if connected { complete() } }
    }
}
