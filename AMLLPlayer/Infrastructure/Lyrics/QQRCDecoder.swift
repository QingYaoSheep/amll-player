import Compression
import Foundation

/// Decoder for QQ Music's encrypted QRC (word-timed lyric) payload.
///
/// QQ's cipher has the shape of 3DES but uses a private bit ordering and
/// S-box implementation. It is only used for lyric transport; it is not a
/// general purpose cryptographic primitive.
enum QQRCDecoder {
    private typealias KeySchedule = [UInt32]

    private static let key1 = Array("!@#)(*$%".utf8)
    private static let key2 = Array("123ZXC!@".utf8)
    private static let key3 = Array("!@#)(NHL".utf8)

    private static let initialPermutation = [
        58, 50, 42, 34, 26, 18, 10, 2, 60, 52, 44, 36, 28, 20, 12, 4,
        62, 54, 46, 38, 30, 22, 14, 6, 64, 56, 48, 40, 32, 24, 16, 8,
        57, 49, 41, 33, 25, 17, 9, 1, 59, 51, 43, 35, 27, 19, 11, 3,
        61, 53, 45, 37, 29, 21, 13, 5, 63, 55, 47, 39, 31, 23, 15, 7,
    ]
    private static let inverseInitialPermutation = [
        40, 8, 48, 16, 56, 24, 64, 32, 39, 7, 47, 15, 55, 23, 63, 31,
        38, 6, 46, 14, 54, 22, 62, 30, 37, 5, 45, 13, 53, 21, 61, 29,
        36, 4, 44, 12, 52, 20, 60, 28, 35, 3, 43, 11, 51, 19, 59, 27,
        34, 2, 42, 10, 50, 18, 58, 26, 33, 1, 41, 9, 49, 17, 57, 25,
    ]
    private static let expansion = [
        32, 1, 2, 3, 4, 5, 4, 5, 6, 7, 8, 9, 8, 9, 10, 11, 12, 13,
        12, 13, 14, 15, 16, 17, 16, 17, 18, 19, 20, 21, 20, 21, 22, 23,
        24, 25, 24, 25, 26, 27, 28, 29, 28, 29, 30, 31, 32, 1,
    ]
    private static let pBox = [
        16, 7, 20, 21, 29, 12, 28, 17, 1, 15, 23, 26, 5, 18, 31, 10,
        2, 8, 24, 14, 32, 27, 3, 9, 19, 13, 30, 6, 22, 11, 4, 25,
    ]
    private static let roundShifts = [1, 1, 2, 2, 2, 2, 2, 2, 1, 2, 2, 2, 2, 2, 2, 1]
    private static let keyPermutationC = [
        56, 48, 40, 32, 24, 16, 8, 0, 57, 49, 41, 33, 25, 17, 9, 1,
        58, 50, 42, 34, 26, 18, 10, 2, 59, 51, 43, 35,
    ]
    private static let keyPermutationD = [
        62, 54, 46, 38, 30, 22, 14, 6, 61, 53, 45, 37, 29, 21, 13, 5,
        60, 52, 44, 36, 28, 20, 12, 4, 27, 19, 11, 3,
    ]
    private static let keyCompression = [
        13, 16, 10, 23, 0, 4, 2, 27, 14, 5, 20, 9, 22, 18, 11, 3, 25, 7,
        15, 6, 26, 19, 12, 1, 40, 51, 30, 36, 46, 54, 29, 39, 50, 44, 32,
        47, 43, 48, 38, 55, 33, 52, 45, 41, 49, 35, 28, 31,
    ]

    private static let sBoxes = [
        [14, 4, 13, 1, 2, 15, 11, 8, 3, 10, 6, 12, 5, 9, 0, 7, 0, 15, 7, 4, 14, 2, 13, 1, 10, 6, 12, 11, 9, 5, 3, 8, 4, 1, 14, 8, 13, 6, 2, 11, 15, 12, 9, 7, 3, 10, 5, 0, 15, 12, 8, 2, 4, 9, 1, 7, 5, 11, 3, 14, 10, 0, 6, 13],
        [15, 1, 8, 14, 6, 11, 3, 4, 9, 7, 2, 13, 12, 0, 5, 10, 3, 13, 4, 7, 15, 2, 8, 15, 12, 0, 1, 10, 6, 9, 11, 5, 0, 14, 7, 11, 10, 4, 13, 1, 5, 8, 12, 6, 9, 3, 2, 15, 13, 8, 10, 1, 3, 15, 4, 2, 11, 6, 7, 12, 0, 5, 14, 9],
        [10, 0, 9, 14, 6, 3, 15, 5, 1, 13, 12, 7, 11, 4, 2, 8, 13, 7, 0, 9, 3, 4, 6, 10, 2, 8, 5, 14, 12, 11, 15, 1, 13, 6, 4, 9, 8, 15, 3, 0, 11, 1, 2, 12, 5, 10, 14, 7, 1, 10, 13, 0, 6, 9, 8, 7, 4, 15, 14, 3, 11, 5, 2, 12],
        [7, 13, 14, 3, 0, 6, 9, 10, 1, 2, 8, 5, 11, 12, 4, 15, 13, 8, 11, 5, 6, 15, 0, 3, 4, 7, 2, 12, 1, 10, 14, 9, 10, 6, 9, 0, 12, 11, 7, 13, 15, 1, 3, 14, 5, 2, 8, 4, 3, 15, 0, 6, 10, 10, 13, 8, 9, 4, 5, 11, 12, 7, 2, 14],
        [2, 12, 4, 1, 7, 10, 11, 6, 8, 5, 3, 15, 13, 0, 14, 9, 14, 11, 2, 12, 4, 7, 13, 1, 5, 0, 15, 10, 3, 9, 8, 6, 4, 2, 1, 11, 10, 13, 7, 8, 15, 9, 12, 5, 6, 3, 0, 14, 11, 8, 12, 7, 1, 14, 2, 13, 6, 15, 0, 9, 10, 4, 5, 3],
        [12, 1, 10, 15, 9, 2, 6, 8, 0, 13, 3, 4, 14, 7, 5, 11, 10, 15, 4, 2, 7, 12, 9, 5, 6, 1, 13, 14, 0, 11, 3, 8, 9, 14, 15, 5, 2, 8, 12, 3, 7, 0, 4, 10, 1, 13, 11, 6, 4, 3, 2, 12, 9, 5, 15, 10, 11, 14, 1, 7, 6, 0, 8, 13],
        [4, 11, 2, 14, 15, 0, 8, 13, 3, 12, 9, 7, 5, 10, 6, 1, 13, 0, 11, 7, 4, 9, 1, 10, 14, 3, 5, 12, 2, 15, 8, 6, 1, 4, 11, 13, 12, 3, 7, 14, 10, 15, 6, 8, 0, 5, 9, 2, 6, 11, 13, 8, 1, 4, 10, 7, 9, 5, 0, 15, 14, 2, 3, 12],
        [13, 2, 8, 4, 6, 15, 11, 1, 10, 9, 3, 14, 5, 0, 12, 7, 1, 15, 13, 8, 10, 3, 7, 4, 12, 5, 6, 11, 0, 14, 9, 2, 7, 11, 4, 1, 9, 12, 14, 2, 0, 6, 10, 13, 15, 3, 5, 8, 2, 1, 14, 7, 4, 10, 8, 13, 15, 12, 9, 0, 3, 5, 6, 11],
    ]

    private static let decryptSchedules: [KeySchedule] = [
        keySchedule(key3, decrypt: true),
        keySchedule(key2, decrypt: false),
        keySchedule(key1, decrypt: true),
    ]

    /// Decrypt a QQ hex payload and inflate its UTF-8 XML/QRC container.
    static func decrypt(_ encryptedHex: String) -> String? {
        let hex = encryptedHex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !hex.isEmpty, hex.utf8.count <= 8_000_000, hex.count.isMultiple(of: 2), hex.count.isMultiple(of: 16) else { return nil }
        var encrypted: [UInt8] = []
        encrypted.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index ..< next], radix: 16) else { return nil }
            encrypted.append(byte)
            index = next
        }
        var decrypted = [UInt8](repeating: 0, count: encrypted.count)
        for offset in stride(from: 0, to: encrypted.count, by: 8) {
            var block = Array(encrypted[offset ..< offset + 8])
            for schedule in decryptSchedules {
                block = desCrypt(block, schedule: schedule)
            }
            decrypted.replaceSubrange(offset ..< offset + 8, with: block)
        }
        guard let inflated = inflate(Data(decrypted)) else { return nil }
        var output = inflated
        if output.starts(with: [0xEF, 0xBB, 0xBF]) {
            output.removeFirst(3)
        }
        return String(data: output, encoding: .utf8)
    }

    /// Parse a decrypted QRC container or raw QRC text into AMLL lyric lines.
    static func parse(_ source: String, duration _: Double) throws -> [LyricLine] {
        let qrc = extractQRC(source)
        guard !qrc.isEmpty else { throw LyricsError.malformed }
        let lineRegex = try NSRegularExpression(pattern: #"^\[(\d+)\s*,\s*(\d+)\](.*)$"#)
        let wordRegex = try NSRegularExpression(pattern: #"(.*?)\((\d+)\s*,\s*(\d+)\)"#)
        let offsetRegex = try NSRegularExpression(pattern: #"(?i)\[offset:([+-]?\d+)\]"#)
        let nsQRC = qrc as NSString
        let offset = offsetRegex.firstMatch(in: qrc, range: NSRange(location: 0, length: nsQRC.length))
            .flatMap { Double(nsQRC.substring(with: $0.range(at: 1))) }.map { max(-60, min(60, $0 / 1000)) } ?? 0
        var result: [LyricLine] = []
        for rawLine in qrc.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            let nsLine = line as NSString
            guard let lineMatch = lineRegex.firstMatch(in: line, range: NSRange(location: 0, length: nsLine.length)) else { continue }
            let startMillis = Double(nsLine.substring(with: lineMatch.range(at: 1))) ?? 0
            let durationMillis = Double(nsLine.substring(with: lineMatch.range(at: 2))) ?? 0
            let content = nsLine.substring(with: lineMatch.range(at: 3)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { continue }
            let nsContent = content as NSString
            let matches = wordRegex.matches(in: content, range: NSRange(location: 0, length: nsContent.length))
            var words: [LyricWord] = []
            var previousStart = -Double.infinity
            for match in matches {
                let word = nsContent.substring(with: match.range(at: 1))
                let wordStart = (Double(nsContent.substring(with: match.range(at: 2))) ?? 0) / 1000 + offset
                let wordDuration = (Double(nsContent.substring(with: match.range(at: 3))) ?? 0) / 1000
                guard wordStart >= previousStart, wordDuration >= 0 else { throw LyricsError.malformed }
                words.append(LyricWord(text: word, start: wordStart, end: wordStart + max(0, wordDuration)))
                previousStart = wordStart
            }
            if let last = matches.last, NSMaxRange(last.range) < nsContent.length, !words.isEmpty {
                words[words.count - 1].text += nsContent.substring(from: NSMaxRange(last.range))
            }
            guard !words.isEmpty else { continue }
            let isBackground = (words.first?.text.first == "(" || words.first?.text.first == "（") &&
                (words.last?.text.last == ")" || words.last?.text.last == "）")
            if isBackground {
                words[0].text.removeFirst()
                words[words.count - 1].text.removeLast()
            }
            let text = words.map(\.text).joined()
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let start = max(0, startMillis / 1000 + offset)
            let end = max(start, start + durationMillis / 1000)
            result.append(LyricLine(id: "qrc-\(result.count)", text: text, start: start, end: end,
                                    words: words, isBackground: isBackground,
                                    isRTL: containsRTL(text), precision: .word))
            guard result.count <= 20000 else { throw LyricsError.tooLarge }
        }
        guard !result.isEmpty else { throw LyricsError.notFound }
        return result
    }

    private static func extractQRC(_ source: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"LyricContent\s*=\s*"(.*?)""#,
                                                   options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return source }
        let ns = source as NSString
        if let match = regex.firstMatch(in: source, range: NSRange(location: 0, length: ns.length)) {
            return decodeXML(ns.substring(with: match.range(at: 1)))
        }
        return source
    }

    private static func decodeXML(_ value: String) -> String {
        value.replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    private static func containsRTL(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (0x0590 ... 0x08FF).contains(scalar.value) || (0xFB1D ... 0xFEFC).contains(scalar.value)
        }
    }

    private static func inflate(_ data: Data) -> Data? {
        var inputs = [data]
        var trimmed = data
        for _ in 0 ..< 7 where trimmed.last == 0 {
            trimmed.removeLast()
            inputs.append(trimmed)
        }
        for input in inputs {
            var capacity = max(1024, input.count * 4)
            for _ in 0 ..< 8 {
                var output = [UInt8](repeating: 0, count: capacity)
                let decoded = input.withUnsafeBytes { source -> Int in
                    output.withUnsafeMutableBytes { destination -> Int in
                        guard let sourceBase = source.bindMemory(to: UInt8.self).baseAddress,
                              let destinationBase = destination.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                        return compression_decode_buffer(destinationBase, capacity, sourceBase, input.count, nil, COMPRESSION_ZLIB)
                    }
                }
                if decoded > 0 {
                    output.removeSubrange(decoded ..< output.count)
                    return Data(output)
                }
                capacity *= 2
            }
        }
        return nil
    }

    private static func permute(_ input: UInt64, rule: [Int]) -> UInt64 {
        var output: UInt64 = 0
        for (index, sourceBit) in rule.enumerated() where ((input >> UInt64(64 - sourceBit)) & 1) != 0 {
            output |= UInt64(1) << UInt64(63 - index)
        }
        return output
    }

    private static func permuteKey(_ key: [UInt8], table: [Int]) -> UInt64 {
        var output: UInt64 = 0
        for (index, position) in table.enumerated() {
            let wordIndex = position >> 5
            let bitInWord = position & 31
            let byteInWord = bitInWord >> 3
            let bitInByte = bitInWord & 7
            let byteIndex = wordIndex * 4 + 3 - byteInWord
            if ((key[byteIndex] >> UInt8(7 - bitInByte)) & 1) != 0 {
                output |= UInt64(1) << UInt64(table.count - 1 - index)
            }
        }
        return output
    }

    private static func keySchedule(_ key: [UInt8], decrypt: Bool) -> KeySchedule {
        let mask: UInt64 = 0xFFFF_FFF0
        var c = permuteKey(key, table: keyPermutationC) << 4
        var d = permuteKey(key, table: keyPermutationD) << 4
        var result = KeySchedule(repeating: 0, count: 32)
        for (index, shift) in roundShifts.enumerated() {
            c = ((c << UInt64(shift)) | (c >> UInt64(28 - shift))) & mask
            d = ((d << UInt64(shift)) | (d >> UInt64(28 - shift))) & mask
            let target = decrypt ? 15 - index : index
            var subkey: UInt64 = 0
            for position in keyCompression {
                let bit = position < 28
                    ? (c >> UInt64(31 - position)) & 1
                    : (d >> UInt64(31 - (position - 27))) & 1
                subkey = (subkey << 1) | bit
            }
            result[target * 2] = UInt32((subkey >> 24) & 0xFFFFFF)
            result[target * 2 + 1] = UInt32(subkey & 0xFFFFFF)
        }
        return result
    }

    private static func sBoxIndex(_ value: Int) -> Int {
        (value & 0x20) | ((value & 0x1F) >> 1) | ((value & 1) << 4)
    }

    private static func fFunction(_ state: UInt32, high: UInt32, low: UInt32) -> UInt32 {
        var expanded: UInt64 = 0
        for position in expansion {
            expanded = (expanded << 1) | UInt64((state >> UInt32(32 - position)) & 1)
        }
        let mixed = expanded ^ (UInt64(high) << 24 | UInt64(low))
        var substituted: UInt32 = 0
        for index in 0 ..< 8 {
            let sixBits = Int((mixed >> UInt64(42 - index * 6)) & 0x3F)
            substituted = (substituted << 4) | UInt32(sBoxes[index][sBoxIndex(sixBits)])
        }
        var output: UInt32 = 0
        for (index, sourceBit) in pBox.enumerated() where ((substituted >> UInt32(32 - sourceBit)) & 1) != 0 {
            output |= UInt32(1) << UInt32(31 - index)
        }
        return output
    }

    private static func desCrypt(_ input: [UInt8], schedule: KeySchedule) -> [UInt8] {
        var block: UInt64 = 0
        for byte in input {
            block = (block << 8) | UInt64(byte)
        }
        let permuted = permute(block, rule: initialPermutation)
        var left = UInt32((permuted >> 32) & 0xFFFF_FFFF)
        var right = UInt32(permuted & 0xFFFF_FFFF)
        for index in 0 ..< 15 {
            let previousRight = right
            right = left ^ fFunction(right, high: schedule[index * 2], low: schedule[index * 2 + 1])
            left = previousRight
        }
        left ^= fFunction(right, high: schedule[30], low: schedule[31])
        let outputBlock = permute(UInt64(left) << 32 | UInt64(right), rule: inverseInitialPermutation)
        return (0 ..< 8).map { index in UInt8((outputBlock >> UInt64(56 - index * 8)) & 0xFF) }
    }
}
