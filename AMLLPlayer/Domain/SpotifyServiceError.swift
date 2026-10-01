import Foundation

enum MusicServiceError: Error, Equatable, LocalizedError, Sendable {
    case notConfigured
    case invalidRedirectURI
    case notAuthorized
    case noActiveDevice
    case restrictedDevice
    case noPlayback
    case premiumRequired
    case rateLimited(retryAfter: TimeInterval?)
    case offline
    case tokenExpired
    case appRemoteUnavailable
    case invalidResponse(statusCode: Int)
    case transport
    case musicConfiguration
    case musicPermissionDenied
    case musicPermissionRestricted
    case musicSubscriptionRequired
    case cloudLibraryRequired
    case unsupportedOperation
    case musicFailure(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            String(localized: "error.spotifyConfigurationMissing")
        case .invalidRedirectURI:
            String(localized: "error.spotifyRedirectInvalid")
        case .notAuthorized:
            String(localized: "error.spotifyNotAuthorized")
        case .noActiveDevice:
            String(localized: "error.spotifyNoActiveDevice")
        case .restrictedDevice:
            String(localized: "error.spotifyRestrictedDevice")
        case .noPlayback:
            String(localized: "error.spotifyNoPlayback")
        case .premiumRequired:
            String(localized: "error.spotifyPremiumRequired")
        case .rateLimited:
            String(localized: "error.spotifyRateLimited")
        case .offline:
            String(localized: "error.offline")
        case .tokenExpired:
            String(localized: "error.spotifyTokenExpired")
        case .appRemoteUnavailable:
            String(localized: "error.spotifyAppRemoteUnavailable")
        case .invalidResponse:
            String(localized: "error.spotifyInvalidResponse")
        case .transport:
            String(localized: "error.spotifyTransport")
        case .musicConfiguration:
            "Apple Music 服务不可用。请确认重签后的 Bundle ID 对应已启用 MusicKit 的 App ID，再重新检查。"
        case .musicPermissionDenied:
            "Apple Music 权限未允许，请在系统设置中允许音乐与媒体资料库访问。"
        case .musicPermissionRestricted:
            "此设备的音乐访问受到系统限制。"
        case .musicSubscriptionRequired:
            "当前账号无法播放 Apple Music 订阅内容。"
        case .cloudLibraryRequired:
            "请在系统音乐设置中启用同步资料库后重试。"
        case .unsupportedOperation:
            "此音乐服务或当前内容不支持该操作。"
        case let .musicFailure(message):
            message
        }
    }
}

typealias SpotifyServiceError = MusicServiceError
