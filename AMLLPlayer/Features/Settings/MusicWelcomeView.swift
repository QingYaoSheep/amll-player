import SwiftUI

struct MusicWelcomeView: View {
    @Bindable var model: AppModel
    var complete: () -> Void

    var body: some View {
        NavigationStack {
            SettingsPage {
                SettingsGroup(radius: SettingsCorners.hero) {
                    VStack(alignment: .leading, spacing: 14) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(
                                    LinearGradient(
                                        colors: [MusicProductStyle.accent.opacity(0.28), MusicProductStyle.accent.opacity(0.10)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                            Image(systemName: "music.note")
                                .font(.title.weight(.semibold))
                                .foregroundStyle(MusicProductStyle.accent)
                        }
                        .frame(width: 58, height: 58)
                        .accessibilityHidden(true)

                        Text("连接音乐服务")
                            .font(.largeTitle.bold())
                            .accessibilityAddTraits(.isHeader)
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
                            .simultaneousGesture(TapGesture().onEnded { model.selectMusicService(service) })
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
        .onChange(of: model.currentServiceConnected) { _, connected in if connected { complete() } }
    }
}
