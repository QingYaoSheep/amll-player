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
    private var refreshGeneration = UUID()
    private let account: any AppleMusicAccountChecking
    private var subscriptionTask: Task<Void, Never>?
    private(set) var connectionID = UUID()
    private var wantsConnection: Bool

    init(api: any AppleMusicRequesting = AppleMusicAPI(), defaults: UserDefaults = .standard,
         account: any AppleMusicAccountChecking = AppleMusicAccount())
    {
        self.api = api
        self.account = account
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
        subscriptionTask?.cancel()
        subscriptionTask = nil
        wantsConnection = true
        currentState.requesting = true
        currentState.connected = false
        currentState.catalogChecking = false
        currentState.storefront = nil
        currentState.capabilities = .init()
        currentState.error = nil
        publish()
        await account.requestAuthorization()
        guard generation == token else { return }
        defaults.set(true, forKey: "appleMusic.connected.v1")
        await refresh()
    }

    func refresh() async {
        guard wantsConnection else { return }
        let token = generation
        refreshGeneration = UUID()
        let refreshToken = refreshGeneration
        let status = account.authorization
        currentState.authorization = status
        currentState.requesting = false
        guard status == .authorized else {
            currentState.connected = false
            currentState.catalogChecking = false
            currentState.storefront = nil
            currentState.capabilities = .init()
            currentState.error = status == .restricted ? .musicPermissionRestricted : .musicPermissionDenied
            subscriptionTask?.cancel()
            subscriptionTask = nil
            publish()
            return
        }

        // System observation depends on authorization, not on catalog tokens.
        currentState.connected = true
        currentState.catalogChecking = true
        currentState.capabilities.usesSystemRoutes = true
        currentState.error = nil
        publish()
        do {
            let capabilities = try await account.subscription()
            let data = try await api.send(AppleMusicAPI.request("/v1/me/storefront"))
            try Task.checkCancellation()
            guard token == generation, refreshToken == refreshGeneration else { return }
            guard account.authorization == .authorized else { await refresh(); return }
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard let rows = root?["data"] as? [[String: Any]], let region = rows.first?["id"] as? String,
                  region.count == 2, region.allSatisfy(\.isLetter) else { throw MusicCatalogError.invalidResponse }
            if currentState.storefront != nil, currentState.storefront != region {
                connectionID = UUID()
            }
            currentState.catalogChecking = false
            currentState.storefront = region
            currentState.capabilities = capabilities
            currentState.error = nil
            observeSubscription()
        } catch is CancellationError {
            guard token == generation, refreshToken == refreshGeneration else { return }
            guard account.authorization == .authorized else { await refresh(); return }
            currentState.catalogChecking = false
            publish()
            return
        } catch {
            guard token == generation, refreshToken == refreshGeneration else { return }
            guard account.authorization == .authorized else { await refresh(); return }
            if currentState.capabilities.canBrowse {
                connectionID = UUID() // Reject obsolete private catalog results.
            }
            currentState.catalogChecking = false
            currentState.capabilities = .init(usesSystemRoutes: true)
            currentState.error = error as? MusicServiceError ?? .musicFailure(error.localizedDescription)
        }
        publish()
    }

    func requireCatalog() throws {
        guard currentState.connected else { throw MusicCatalogError.signInRequired }
        guard currentState.capabilities.canBrowse else {
            throw currentState.error ?? MusicServiceError.musicFailure(
                currentState.catalogChecking ? "正在检查 Apple Music 目录服务，请稍后重试。" : "Apple Music 目录服务尚未验证。系统歌曲同步仍可使用。"
            )
        }
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
        let token = generation
        subscriptionTask = Task { [weak self] in
            defer {
                if let self, generation == token {
                    subscriptionTask = nil
                }
            }
            guard let updates = self?.account.subscriptionUpdates else { return }
            for await capabilities in updates {
                guard !Task.isCancelled, let self, wantsConnection, generation == token else { return }
                guard account.authorization == .authorized else { await refresh(); return }
                // A temporary network failure does not terminate the official update sequence.
                guard currentState.connected, currentState.capabilities.canBrowse else { continue }
                let old = currentState.capabilities
                currentState.capabilities = capabilities
                if old.canModifyLibrary != capabilities.canModifyLibrary {
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
