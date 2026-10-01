import Foundation
import MusicKit

@MainActor
final class AppleMusicSession: MusicSessionProviding {
    private(set) var currentState = MusicConnectionState()
    let connectionStates: AsyncStream<MusicConnectionState>
    private let continuation: AsyncStream<MusicConnectionState>.Continuation
    let api: any AppleMusicRequesting
    private let defaults: UserDefaults
    private var generation = UUID()
    private var subscriptionTask: Task<Void, Never>?
    private(set) var connectionID = UUID()
    private var wantsConnection: Bool

    init(api: any AppleMusicRequesting = AppleMusicAPI(), defaults: UserDefaults = .standard) {
        self.api = api
        self.defaults = defaults
        wantsConnection = defaults.bool(forKey: "appleMusic.connected.v1")
        let stream = AsyncStream<MusicConnectionState>.makeStream(bufferingPolicy: .bufferingNewest(1))
        connectionStates = stream.stream
        continuation = stream.continuation
    }

    deinit { subscriptionTask?.cancel(); continuation.finish() }

    func connect() async {
        guard !currentState.requesting else { return }
        generation = UUID()
        connectionID = UUID()
        let token = generation
        wantsConnection = true
        currentState.requesting = true
        currentState.connected = false
        currentState.capabilities = .init()
        currentState.error = nil
        publish()
        _ = await MusicAuthorization.request()
        guard generation == token else { return }
        defaults.set(true, forKey: "appleMusic.connected.v1")
        await refresh()
    }

    func refresh() async {
        guard wantsConnection else { return }
        let token = generation
        let status = MusicAuthorization.currentStatus
        currentState.authorization = switch status {
        case .authorized: .authorized
        case .denied: .denied
        case .restricted: .restricted
        case .notDetermined: .notDetermined
        @unknown default: .restricted
        }
        currentState.requesting = false
        guard status == .authorized else {
            currentState.connected = false
            currentState.capabilities = .init()
            currentState.error = status == .restricted ? .musicPermissionRestricted : .musicPermissionDenied
            publish()
            return
        }
        do {
            let subscription = try await MusicSubscription.current
            let data = try await api.send(AppleMusicAPI.request("/v1/me/storefront"))
            try Task.checkCancellation()
            guard token == generation else { return }
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard let rows = root?["data"] as? [[String: Any]], let region = rows.first?["id"] as? String,
                  region.count == 2, region.allSatisfy(\.isLetter) else { throw MusicCatalogError.invalidResponse }
            if currentState.storefront != nil, currentState.storefront != region {
                connectionID = UUID()
            }
            currentState.connected = true
            currentState.storefront = region
            currentState.capabilities = .init(
                canBrowse: true, canPlayCatalog: subscription.canPlayCatalogContent,
                canModifyLibrary: subscription.hasCloudLibraryEnabled,
                canFavorite: subscription.canPlayCatalogContent && subscription.hasCloudLibraryEnabled,
                usesSystemRoutes: true
            )
            currentState.error = nil
            observeSubscription()
        } catch is CancellationError { return }
        catch {
            guard token == generation else { return }
            currentState.connected = false
            currentState.capabilities = .init()
            currentState.error = error as? MusicServiceError ?? .musicFailure(error.localizedDescription)
        }
        publish()
    }

    func disconnect() {
        generation = UUID()
        connectionID = UUID()
        wantsConnection = false
        defaults.removeObject(forKey: "appleMusic.connected.v1")
        subscriptionTask?.cancel()
        subscriptionTask = nil
        currentState = .init()
        publish()
    }

    private func observeSubscription() {
        guard subscriptionTask == nil else { return }
        subscriptionTask = Task { [weak self] in
            for await subscription in MusicSubscription.subscriptionUpdates {
                guard !Task.isCancelled, let self, wantsConnection else { return }
                let old = currentState.capabilities
                currentState.capabilities.canPlayCatalog = subscription.canPlayCatalogContent
                currentState.capabilities.canModifyLibrary = subscription.hasCloudLibraryEnabled
                currentState.capabilities.canFavorite = subscription.canPlayCatalogContent && subscription.hasCloudLibraryEnabled
                if old.canModifyLibrary != subscription.hasCloudLibraryEnabled {
                    connectionID = UUID()
                }
                publish()
            }
        }
    }

    private func publish() {
        currentState.contextID = connectionID
        continuation.yield(currentState)
    }
}
