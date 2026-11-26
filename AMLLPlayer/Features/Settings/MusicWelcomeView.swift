import SwiftUI

struct MusicWelcomeView: View {
    @Bindable var model: AppModel
    var complete: () -> Void

    var body: some View {
        NavigationStack {
            SettingsPage {
                VStack(alignment: .leading, spacing: 12) {
                    Image(systemName: "music.note")
                        .font(.largeTitle.weight(.semibold))
                        .foregroundStyle(MusicProductStyle.accent)
                        .accessibilityHidden(true)
                    Text("连接音乐服务").font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
                }
                .settingsSurface(radius: 24)
                SettingsSection {
                    ForEach(MusicServiceID.allCases) { service in
                        NavigationLink {
                            MusicLoginDestination(model: model, service: service)
                                .toolbar {
                                    ToolbarItem(placement: .confirmationAction) { Button("完成", action: complete) }
                                }
                        } label: {
                            SettingsActionLabel(title: LocalizedStringKey(service.title), icon: service.settingsIcon, navigates: true)
                        }
                        .simultaneousGesture(TapGesture().onEnded { model.selectMusicService(service) })
                    }
                }
                Button(action: complete) {
                    SettingsActionLabel(title: "稍后设置", icon: "arrow.right")
                }
                .accessibilityIdentifier("skipMusicWelcome")
            }
            .buttonStyle(SettingsButtonStyle())
        }
        .tint(MusicProductStyle.accent)
        .interactiveDismissDisabled()
        .onChange(of: model.currentServiceConnected) { _, connected in if connected { complete() } }
    }
}
