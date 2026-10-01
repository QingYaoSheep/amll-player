// Protocol: chaunsin/netease-cloud-music c3de3582, MIT.
import CommonCrypto
import Foundation
import Security

enum NetEaseError: Error, LocalizedError, Equatable {
    case expired, invalidCookie, invalidResponse, restricted, trialOnly, unavailable, rateLimited
    case request(Int)
    var errorDescription: String? {
        switch self {
        case .expired: "网易云登录已过期，请重新登录。"
        case .invalidCookie: "Cookie 无效，当前有效登录已保留。"
        case .invalidResponse: "网易云返回的数据无法识别。"
        case .restricted: "当前账号没有此歌曲的播放权限，或歌曲在当前地区不可用。"
        case .trialOnly: "此歌曲仅提供试听，无法播放完整歌曲。"
        case .unavailable: "此歌曲暂无可用音源。"
        case .rateLimited: "网易云请求频繁，请稍后重试。"
        case let .request(code): "网易云请求失败（\(code)），请稍后重试。"
        }
    }
}
struct NetEaseResponse {
    var object: [String: Any]
    var cookie: String?
}
@MainActor protocol NetEaseRequesting: AnyObject {
    func send(_ path: String, _ parameters: [String: Any], cookie: String?) async throws -> NetEaseResponse
}
private final class NetEaseRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}
@MainActor final class NetEaseAPI: NetEaseRequesting {
    private let session: URLSession
    init() {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 20
        session = URLSession(configuration: config, delegate: NetEaseRedirectPolicy(), delegateQueue: nil)
    }
    func send(_ path: String, _ parameters: [String: Any] = [:], cookie: String? = nil) async throws -> NetEaseResponse {
        let request = try Self.request(path, parameters, cookie: cookie)
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, data.count <= 16 * 1024 * 1024 else { throw NetEaseError.invalidResponse }
        guard http.statusCode == 200 else {
            if http.statusCode == 429 { throw NetEaseError.rateLimited }
            throw NetEaseError.request(http.statusCode)
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw NetEaseError.invalidResponse }
        let code = root["code"] as? Int ?? 200
        if [301, 302].contains(code) { throw NetEaseError.expired }
        if code == 429 || code == 405 { throw NetEaseError.rateLimited }
        guard code == 200 || (800...803).contains(code) else { throw NetEaseError.request(code) }
        let headers = http.allHeaderFields.reduce(into: [String: String]()) { r, pair in
            if let k = pair.key as? String { r[k] = String(describing: pair.value) }
        }
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: headers, for: request.url!)
        let auth = cookies.filter { NetEaseCookie.allowed.contains($0.name) }.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        return .init(object: root, cookie: auth.isEmpty ? nil : auth)
    }
    static func request(_ path: String, _ parameters: [String: Any], cookie: String?, secret: String? = nil) throws -> URLRequest {
        guard path.hasPrefix("/"), !path.contains(".."), !path.contains("?"), !path.contains("#"),
              let url = URL(string: "https://music.163.com/weapi" + path) else { throw NetEaseError.invalidResponse }
        guard cookie.map({ !$0.contains("\r") && !$0.contains("\n") && $0.utf8.count <= 16384 }) ?? true else { throw NetEaseError.invalidCookie }
        var object = parameters
        object["csrf_token"] = NetEaseCookie.values(cookie ?? "")["__csrf"] ?? ""
        let fields = try NetEaseCrypto.encrypt(object, secret: secret)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"; request.timeoutInterval = 20
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        request.setValue("os=pc; appver=2.10.13" + (cookie.map { "; " + $0 } ?? ""), forHTTPHeaderField: "Cookie")
        var form = URLComponents()
        form.queryItems = fields.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = form.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)
        return request
    }
}
enum NetEaseCookie {
    static let allowed: Set<String> = ["MUSIC_U", "MUSIC_A", "__csrf", "NMTID", "WNMCID"]
    static func values(_ raw: String) -> [String: String] {
        raw.split(separator: ";").reduce(into: [:]) { result, part in
            let pieces = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if pieces.count == 2 {
                let key = pieces[0].trimmingCharacters(in: .whitespaces)
                if allowed.contains(key) { result[key] = pieces[1].trimmingCharacters(in: .whitespaces) }
            }
        }
    }
    static func normalized(_ raw: String) throws -> String {
        guard raw.utf8.count <= 16384, !raw.contains("\n"), !raw.contains("\r") else { throw NetEaseError.invalidCookie }
        let v = values(raw)
        guard !(v["MUSIC_U"] ?? "").isEmpty || !(v["MUSIC_A"] ?? "").isEmpty else { throw NetEaseError.invalidCookie }
        return v.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
    }
}
enum NetEaseCrypto {
    private static let rsaDER = "MIGJAoGBAOC1CfYlnfhkLbw1ZikBR33yJnfsFStf9orOYVu3tyUVKzqxeodq6opap20uQXYp7E7jQfVhNfzPaVKAEE4DEuy9qSVXyThwEUr2ydBcT38MNoW3pGvuJVkyV1zOELQk2BPP5IddPoIEe5fd71J0HVRrjiidxpNbPs4EYtsKIrjnAgMBAAE="
    static func encrypt(_ object: [String: Any], secret supplied: String? = nil) throws -> [String: String] {
        let secret = supplied ?? String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16))
        guard secret.utf8.count == 16 else { throw NetEaseError.invalidResponse }
        let body = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        let first = try aes(body, key: "0CoJUm6Qyw8W8jud").base64EncodedString()
        let params = try aes(Data(first.utf8), key: secret).base64EncodedString()
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
                                      kSecAttrKeyClass as String: kSecAttrKeyClassPublic, kSecAttrKeySizeInBits as String: 1024]
        guard let der = Data(base64Encoded: rsaDER),
              let key = SecKeyCreateWithData(der as CFData, attributes as CFDictionary, nil) else { throw NetEaseError.invalidResponse }
        var padded = Data(repeating: 0, count: 112); padded.append(contentsOf: secret.utf8.reversed())
        guard let encrypted = SecKeyCreateEncryptedData(key, .rsaEncryptionRaw, padded as CFData, nil) as Data? else { throw NetEaseError.invalidResponse }
        return ["params": params, "encSecKey": encrypted.map { String(format: "%02x", $0) }.joined()]
    }
    private static func aes(_ input: Data, key: String) throws -> Data {
        let keyData = Data(key.utf8), iv = Data("0102030405060708".utf8)
        var output = Data(count: input.count + kCCBlockSizeAES128)
        let capacity = output.count; var size = 0
        let status = output.withUnsafeMutableBytes { dst in
            input.withUnsafeBytes { src in
                keyData.withUnsafeBytes { k in
                    iv.withUnsafeBytes { v in
                        CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                                k.baseAddress, keyData.count, v.baseAddress, src.baseAddress, input.count,
                                dst.baseAddress, capacity, &size)
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw NetEaseError.invalidResponse }
        output.removeSubrange(size..<output.count); return output
    }
}
