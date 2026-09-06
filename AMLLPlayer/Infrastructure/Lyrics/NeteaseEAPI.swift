import CommonCrypto
import CryptoKit
import Foundation

enum NeteaseEAPI {
    private static let key = Data("e82ckenh8dichen8".utf8)
    private static let delimiter = "-36cd479b6b5-"

    static func request(songID: String, now: Date = Date(), nonce: Int = Int.random(in: 0 ... 9999)) throws -> URLRequest {
        let milliseconds = Int64(now.timeIntervalSince1970 * 1000)
        let seconds = Int64(now.timeIntervalSince1970)
        let header = [
            "__csrf": "", "appver": "8.0.0", "buildver": String(seconds), "channel": "", "deviceId": "",
            "mobilename": "", "resolution": "1920x1080", "os": "android", "osver": "",
            "requestId": "\(milliseconds)_\(String(format: "%04d", nonce))", "versioncode": "140", "MUSIC_U": "",
        ]
        let headerJSON = try json(header)
        let data: [String: Any] = [
            "id": songID, "cp": "false", "lv": "0", "kv": "0", "tv": "0", "rv": "0", "yv": "0", "ytv": "0", "yrv": "0",
            "csrf_token": "", "header": headerJSON,
        ]
        let path = "/api/song/lyric/v1"
        let encrypted = try encryptedParameters(path: path, object: data)
        let fields = ["params": encrypted]
        let cookie = header.sorted { $0.key < $1.key }.map { $0.key + "=" + $0.value }.joined(separator: "; ")
        return try LyricsRequest.form("https://interface3.music.163.com/eapi/song/lyric/v1", fields: fields, headers: [
            "User-Agent": "Mozilla/5.0 (Linux; Android 9) AppleWebKit/537.36 Mobile Safari/537.36",
            "Referer": "https://music.163.com/", "Cookie": cookie,
        ])
    }

    static func encryptedParameters(path: String, object: [String: Any]) throws -> String {
        let body = try json(object)
        let message = "nobody\(path)use\(body)md5forencrypt"
        let digest = Insecure.MD5.hash(data: Data(message.utf8)).map { String(format: "%02x", $0) }.joined()
        let envelope = path + delimiter + body + delimiter + digest
        return try aesECB(Data(envelope.utf8)).map { String(format: "%02X", $0) }.joined()
    }

    private static func json(_ value: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
        guard let result = String(data: data, encoding: .utf8) else { throw LyricsError.malformed }
        return result
    }

    private static func aesECB(_ data: Data) throws -> Data {
        var output = Data(count: data.count + kCCBlockSizeAES128)
        let outputCapacity = output.count
        var outputLength = 0
        let status = output.withUnsafeMutableBytes { outputBytes in
            data.withUnsafeBytes { dataBytes in
                key.withUnsafeBytes { keyBytes in
                    CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionECBMode | kCCOptionPKCS7Padding),
                            keyBytes.baseAddress, key.count, nil,
                            dataBytes.baseAddress, data.count,
                            outputBytes.baseAddress, outputCapacity, &outputLength)
                }
            }
        }
        guard status == kCCSuccess else { throw LyricsError.transport }
        output.removeSubrange(outputLength ..< output.count)
        return output
    }
}
