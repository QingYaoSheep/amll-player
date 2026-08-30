import Foundation

actor SpotifyWebAPIClient: SpotifyWebAPIProviding {
    private let session: URLSession
    private let baseURL: URL
    private let now: @Sendable () -> TimeInterval
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    init(
        session: URLSession = .shared,
        baseURL: URL = URL(string: "https://api.spotify.com/v1/")!,
        now: @escaping @Sendable () -> TimeInterval = {
            ProcessInfo.processInfo.systemUptime
        }
    ) {
        self.session = session
        self.baseURL = baseURL
        self.now = now

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        self.decoder = decoder

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        self.encoder = encoder
    }

    func playback(accessToken: String) async throws -> PlaybackSnapshot {
        let request = try makeRequest(
            path: "me/player",
            accessToken: accessToken
        )
        let startedAt = now()
        let (data, response) = try await perform(request)
        let finishedAt = now()
        let sampledAt = startedAt + ((finishedAt - startedAt) / 2)

        if response.statusCode == 204 {
            return .empty(source: .webAPI, sampledAtUptime: sampledAt)
        }
        try validate(response)
        let payload = try decoder.decode(PlaybackResponse.self, from: data)
        return payload.snapshot(sampledAtUptime: sampledAt)
    }

    func devices(accessToken: String) async throws -> [PlaybackDevice] {
        let request = try makeRequest(
            path: "me/player/devices",
            accessToken: accessToken
        )
        let (data, response) = try await perform(request)
        try validate(response)
        return try decoder.decode(DevicesResponse.self, from: data).devices.compactMap {
            $0.model
        }
    }

    func play(accessToken: String, deviceID: String?) async throws {
        try await sendPlayerCommand(
            path: "me/player/play",
            method: "PUT",
            accessToken: accessToken,
            deviceID: deviceID
        )
    }

    func pause(accessToken: String, deviceID: String?) async throws {
        try await sendPlayerCommand(
            path: "me/player/pause",
            method: "PUT",
            accessToken: accessToken,
            deviceID: deviceID
        )
    }

    func seek(
        accessToken: String,
        position: TimeInterval,
        deviceID: String?
    ) async throws {
        let milliseconds = max(0, Int((position * 1_000).rounded()))
        try await sendPlayerCommand(
            path: "me/player/seek",
            method: "PUT",
            accessToken: accessToken,
            deviceID: deviceID,
            additionalQuery: [URLQueryItem(name: "position_ms", value: String(milliseconds))]
        )
    }

    func skipNext(accessToken: String, deviceID: String?) async throws {
        try await sendPlayerCommand(
            path: "me/player/next",
            method: "POST",
            accessToken: accessToken,
            deviceID: deviceID
        )
    }

    func skipPrevious(accessToken: String, deviceID: String?) async throws {
        try await sendPlayerCommand(
            path: "me/player/previous",
            method: "POST",
            accessToken: accessToken,
            deviceID: deviceID
        )
    }

    func setVolume(
        accessToken: String,
        percent: Int,
        deviceID: String?
    ) async throws {
        try await sendPlayerCommand(
            path: "me/player/volume",
            method: "PUT",
            accessToken: accessToken,
            deviceID: deviceID,
            additionalQuery: [
                URLQueryItem(
                    name: "volume_percent",
                    value: String(min(max(percent, 0), 100))
                )
            ]
        )
    }

    func play(
        accessToken: String,
        uri: String,
        deviceID: String?
    ) async throws {
        let body = PlayBody(
            uris: uri.hasPrefix("spotify:track:") ? [uri] : nil,
            contextURI: uri.hasPrefix("spotify:track:") ? nil : uri
        )
        try await sendPlayerCommand(
            path: "me/player/play",
            method: "PUT",
            accessToken: accessToken,
            deviceID: deviceID,
            body: try encoder.encode(body)
        )
    }

    func transferPlayback(accessToken: String, deviceID: String) async throws {
        let body = TransferBody(deviceIDs: [deviceID], play: false)
        let request = try makeRequest(
            path: "me/player",
            method: "PUT",
            accessToken: accessToken,
            body: try encoder.encode(body)
        )
        let (_, response) = try await perform(request)
        try validate(response)
    }

    private func sendPlayerCommand(
        path: String,
        method: String,
        accessToken: String,
        deviceID: String?,
        additionalQuery: [URLQueryItem] = [],
        body: Data? = nil
    ) async throws {
        var query = additionalQuery
        if let deviceID, !deviceID.isEmpty {
            query.append(URLQueryItem(name: "device_id", value: deviceID))
        }
        let request = try makeRequest(
            path: path,
            method: method,
            accessToken: accessToken,
            query: query,
            body: body
        )
        let (_, response) = try await perform(request)
        try validate(response)
    }

    private func makeRequest(
        path: String,
        method: String = "GET",
        accessToken: String,
        query: [URLQueryItem] = [],
        body: Data? = nil
    ) throws -> URLRequest {
        guard let endpoint = URL(string: path, relativeTo: baseURL),
              var components = URLComponents(
                  url: endpoint.absoluteURL,
                  resolvingAgainstBaseURL: false
              )
        else {
            throw SpotifyServiceError.transport
        }
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else {
            throw SpotifyServiceError.transport
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = 15
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else {
                throw SpotifyServiceError.transport
            }
            return (data, response)
        } catch let error as SpotifyServiceError {
            throw error
        } catch let error as URLError where [
            .notConnectedToInternet,
            .networkConnectionLost,
            .cannotConnectToHost,
            .cannotFindHost,
            .timedOut,
        ].contains(error.code) {
            throw SpotifyServiceError.offline
        } catch {
            throw SpotifyServiceError.transport
        }
    }

    private func validate(_ response: HTTPURLResponse) throws {
        guard !(200..<300).contains(response.statusCode) else {
            return
        }
        throw SpotifyHTTPStatusMapper.error(
            statusCode: response.statusCode,
            retryAfter: response.value(forHTTPHeaderField: "Retry-After")
        )
    }
}

enum SpotifyHTTPStatusMapper {
    static func error(
        statusCode: Int,
        retryAfter: String?
    ) -> SpotifyServiceError {
        switch statusCode {
        case 401:
            .tokenExpired
        case 403:
            .premiumRequired
        case 404:
            .noActiveDevice
        case 429:
            .rateLimited(retryAfter: retryAfter.flatMap(TimeInterval.init))
        default:
            .invalidResponse(statusCode: statusCode)
        }
    }
}

private struct DevicesResponse: Decodable {
    let devices: [DeviceResponse]
}

private struct PlaybackResponse: Decodable {
    let device: DeviceResponse?
    let progressMs: Int?
    let isPlaying: Bool
    let item: ItemResponse?
    let currentlyPlayingType: String?
    let actions: ActionsResponse?

    func snapshot(sampledAtUptime: TimeInterval) -> PlaybackSnapshot {
        let itemModel = item?.model(currentlyPlayingType: currentlyPlayingType)
        return PlaybackSnapshot(
            item: itemModel,
            isPlaying: isPlaying,
            position: TimeInterval(progressMs ?? 0) / 1_000,
            duration: itemModel?.duration ?? 0,
            device: device?.model,
            restrictions: actions?.restrictions ?? .unrestricted,
            source: .webAPI,
            sampledAtUptime: sampledAtUptime
        )
    }
}

private struct DeviceResponse: Decodable {
    let id: String?
    let isActive: Bool
    let isRestricted: Bool
    let name: String
    let type: String
    let volumePercent: Int?
    let supportsVolume: Bool

    var model: PlaybackDevice? {
        guard let id, !id.isEmpty else {
            return nil
        }
        return PlaybackDevice(
            id: id,
            name: name,
            type: type,
            isActive: isActive,
            isRestricted: isRestricted,
            volumePercent: volumePercent,
            supportsVolume: supportsVolume
        )
    }
}

private struct ItemResponse: Decodable {
    let id: String?
    let uri: String
    let name: String
    let durationMs: Int
    let type: String?
    let artists: [NamedResponse]?
    let album: AlbumResponse?
    let show: NamedResponse?

    func model(currentlyPlayingType: String?) -> PlaybackItem {
        let episode = type == "episode" || currentlyPlayingType == "episode"
        let advertisement = type == "ad" || currentlyPlayingType == "ad"
        let artistNames = artists?.map(\.name) ?? show.map { [$0.name] } ?? []
        return PlaybackItem(
            id: id,
            uri: uri,
            title: name,
            artists: artistNames,
            albumTitle: album?.name,
            artworkURL: album?.images.first.flatMap { URL(string: $0.url) },
            duration: TimeInterval(durationMs) / 1_000,
            isEpisode: episode,
            isAdvertisement: advertisement
        )
    }
}

private struct NamedResponse: Decodable {
    let name: String
}

private struct AlbumResponse: Decodable {
    let name: String
    let images: [ImageResponse]
}

private struct ImageResponse: Decodable {
    let url: String
}

private struct ActionsResponse: Decodable {
    let pausing: Bool?
    let resuming: Bool?
    let seeking: Bool?
    let skippingNext: Bool?
    let skippingPrev: Bool?

    var restrictions: PlaybackRestrictions {
        PlaybackRestrictions(
            canPause: !(pausing ?? false),
            canResume: !(resuming ?? false),
            canSeek: !(seeking ?? false),
            canSkipNext: !(skippingNext ?? false),
            canSkipPrevious: !(skippingPrev ?? false)
        )
    }
}

private struct PlayBody: Encodable {
    let uris: [String]?
    let contextURI: String?
}

private struct TransferBody: Encodable {
    let deviceIDs: [String]
    let play: Bool
}
