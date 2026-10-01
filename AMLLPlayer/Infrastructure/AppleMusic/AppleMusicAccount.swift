import MusicKit

@MainActor
protocol AppleMusicAccountChecking {
    var authorization: MusicAuthorizationState { get }
    func requestAuthorization() async
    func subscription() async throws -> MusicServiceCapabilities
    var subscriptionUpdates: AsyncStream<MusicServiceCapabilities> { get }
}

@MainActor
struct AppleMusicAccount: AppleMusicAccountChecking {
    var authorization: MusicAuthorizationState {
        switch MusicAuthorization.currentStatus {
        case .authorized: .authorized
        case .denied: .denied
        case .restricted: .restricted
        case .notDetermined: .notDetermined
        @unknown default: .restricted
        }
    }

    func requestAuthorization() async {
        _ = await MusicAuthorization.request()
    }

    func subscription() async throws -> MusicServiceCapabilities {
        try Self.capabilities(await MusicSubscription.current)
    }

    var subscriptionUpdates: AsyncStream<MusicServiceCapabilities> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task {
                for await value in MusicSubscription.subscriptionUpdates {
                    guard !Task.isCancelled else { break }
                    continuation.yield(Self.capabilities(value))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func capabilities(_ value: MusicSubscription) -> MusicServiceCapabilities {
        .init(canBrowse: true, canPlayCatalog: value.canPlayCatalogContent,
              canModifyLibrary: value.hasCloudLibraryEnabled,
              canFavorite: value.canPlayCatalogContent && value.hasCloudLibraryEnabled,
              usesSystemRoutes: true)
    }
}
