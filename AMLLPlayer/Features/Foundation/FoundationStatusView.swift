import SwiftUI

struct FoundationStatusView: View {
    let state: LoadableState<FoundationStatus>

    var body: some View {
        NavigationStack {
            Group {
                switch state {
                case .idle, .loading:
                    ProgressView("foundation.loading")
                case let .loaded(status):
                    List {
                        Section("foundation.section.project") {
                            StatusRow(
                                title: "foundation.swiftui",
                                isReady: true
                            )
                            StatusRow(
                                title: "foundation.spotifySDK",
                                isReady: status.spotifySDKPinned
                            )
                            StatusRow(
                                title: "foundation.spotifyOnly",
                                isReady: status.localPlaybackExcluded
                            )
                        }

                        Section("foundation.section.configuration") {
                            StatusRow(
                                title: "foundation.spotifyClientID",
                                isReady: status.secretsConfigured
                            )
                            if !status.secretsConfigured {
                                Text("foundation.spotifyClientID.help")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                case let .failed(error):
                    ContentUnavailableView(
                        "foundation.failed",
                        systemImage: "exclamationmark.triangle",
                        description: Text(error.localizedDescription)
                    )
                }
            }
            .navigationTitle("app.name")
        }
    }
}

private struct StatusRow: View {
    let title: LocalizedStringKey
    let isReady: Bool

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: isReady ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(isReady ? .green : .secondary)
        }
        .accessibilityValue(isReady ? Text("status.ready") : Text("status.actionRequired"))
    }
}
