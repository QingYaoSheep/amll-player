import Foundation
import Observation

enum AppSection: Hashable {
    case foundation
    case settings
}

struct FoundationStatus: Equatable, Sendable {
    let spotifySDKPinned: Bool
    let secretsConfigured: Bool
    let localPlaybackExcluded: Bool
}

@MainActor
@Observable
final class AppModel {
    var selectedSection: AppSection = .foundation
    private(set) var foundationState: LoadableState<FoundationStatus> = .idle

    let environment: AppEnvironment

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    func prepare() {
        guard case .idle = foundationState else {
            return
        }

        foundationState = .loading
        foundationState = .loaded(
            FoundationStatus(
                spotifySDKPinned: true,
                secretsConfigured: environment.configuration.isSpotifyConfigured,
                localPlaybackExcluded: true
            )
        )
    }
}
