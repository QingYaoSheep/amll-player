import Compression
import Foundation

/// Decoder for QQ Music's encrypted QRC (word-timed lyric) payload.
///
/// QQ's cipher has the shape of 3DES but uses a private bit ordering and
/// S-box implementation. It is only used for lyric transport; it is not a
/// general purpose cryptographic primitive.
enum QQRCDecoder {
    private typealias KeySchedule = [[UInt8]]

    private static let key1 = Array("!@#)(*$%".utf8)
    private static let key2 = Array("123ZXC!@".utf8)
    private static let key3 = Array("!@#)(NHL".utf8)

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
            // Compression consumes RFC 1951 raw DEFLATE, not the RFC 1950 envelope.
            // Validate both the header and Adler-32 so DES padding cannot mask corruption.
            let bytes = Array(input)
            guard bytes.count > 6, bytes[0] & 0x0F == 8, bytes[0] >> 4 <= 7,
                  (Int(bytes[0]) * 256 + Int(bytes[1])) % 31 == 0,
                  bytes[1] & 0x20 == 0 else { continue }
            let payload = Data(bytes[2 ..< bytes.count - 4])
            let expected = bytes.suffix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            var capacity = min(16_777_216, max(1024, payload.count * 4))
            while capacity <= 16_777_216 {
                var output = [UInt8](repeating: 0, count: capacity)
                let decoded = payload.withUnsafeBytes { source -> Int in
                    output.withUnsafeMutableBytes { destination -> Int in
                        guard let sourceBase = source.bindMemory(to: UInt8.self).baseAddress,
                              let destinationBase = destination.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                        return compression_decode_buffer(destinationBase, capacity, sourceBase, payload.count, nil, COMPRESSION_ZLIB)
                    }
                }
                if decoded > 0, decoded < capacity {
                    output.removeSubrange(decoded ..< output.count)
                    var a: UInt32 = 1, b: UInt32 = 0
                    for byte in output {
                        a = (a + UInt32(byte)) % 65521
                        b = (b + a) % 65521
                    }
                    if (b << 16) | a == expected {
                        return Data(output)
                    }
                    break
                }
                capacity *= 2
            }
        }
        return nil
    }

    private static func keySchedule(_ key: [UInt8], decrypt: Bool) -> KeySchedule {
        var c: UInt32 = 0
        var d: UInt32 = 0
        for index in 0 ..< 28 {
            c |= bitnum(key, bit: keyPermutationC[index], target: 31 - index)
            d |= bitnum(key, bit: keyPermutationD[index], target: 31 - index)
        }

        var result = KeySchedule(repeating: [UInt8](repeating: 0, count: 6), count: 16)
        for index in 0 ..< 16 {
            let shift = roundShifts[index]
            c = ((c << UInt32(shift)) | (c >> UInt32(28 - shift))) & 0xFFFF_FFF0
            d = ((d << UInt32(shift)) | (d >> UInt32(28 - shift))) & 0xFFFF_FFF0
            let target = decrypt ? 15 - index : index
            for position in 0 ..< 24 {
                result[target][position / 8] |= bitnumintr(c, bit: keyCompression[position], target: 7 - position % 8)
            }
            for position in 24 ..< 48 {
                result[target][position / 8] |= bitnumintr(d, bit: keyCompression[position] - 27, target: 7 - position % 8)
            }
        }
        return result
    }

    private static func bitnum(_ bytes: [UInt8], bit: Int, target: Int) -> UInt32 {
        let byteIndex = bit / 32 * 4 + 3 - bit % 32 / 8
        return UInt32((bytes[byteIndex] >> UInt8(7 - bit % 8)) & 1) << UInt32(target)
    }

    private static func bitnumintr(_ value: UInt32, bit: Int, target: Int) -> UInt8 {
        UInt8(((value >> UInt32(31 - bit)) & 1) << UInt32(target))
    }

    private static func bitnumintl(_ value: UInt32, bit: Int, target: Int) -> UInt32 {
        ((value << UInt32(bit)) & 0x8000_0000) >> UInt32(target)
    }

    private static func initialPermutation(_ input: [UInt8]) -> (UInt32, UInt32) {
        let leftBits = [
            57, 49, 41, 33, 25, 17, 9, 1, 59, 51, 43, 35, 27, 19, 11, 3,
            61, 53, 45, 37, 29, 21, 13, 5, 63, 55, 47, 39, 31, 23, 15, 7,
        ]
        let rightBits = [
            56, 48, 40, 32, 24, 16, 8, 0, 58, 50, 42, 34, 26, 18, 10, 2,
            60, 52, 44, 36, 28, 20, 12, 4, 62, 54, 46, 38, 30, 22, 14, 6,
        ]
        var left: UInt32 = 0
        var right: UInt32 = 0
        for index in leftBits.indices {
            left |= bitnum(input, bit: leftBits[index], target: 31 - index)
            right |= bitnum(input, bit: rightBits[index], target: 31 - index)
        }
        return (left, right)
    }

    private static func inverseInitialPermutation(_ left: UInt32, _ right: UInt32) -> [UInt8] {
        func outputByte(start: Int) -> UInt8 {
            var value: UInt8 = 0
            for group in 0 ..< 4 {
                let bit = start + group * 8
                if ((right >> UInt32(31 - bit)) & 1) != 0 {
                    value |= UInt8(1 << (7 - group * 2))
                }
                if ((left >> UInt32(31 - bit)) & 1) != 0 {
                    value |= UInt8(1 << (6 - group * 2))
                }
            }
            return value
        }

        return [
            outputByte(start: 4), outputByte(start: 5), outputByte(start: 6), outputByte(start: 7),
            outputByte(start: 0), outputByte(start: 1), outputByte(start: 2), outputByte(start: 3),
        ]
    }

    private static func fFunction(_ state: UInt32, key: [UInt8]) -> UInt32 {
        var t1 = bitnumintl(state, bit: 31, target: 0) | ((state & 0xF000_0000) >> 1) |
            bitnumintl(state, bit: 4, target: 5) | bitnumintl(state, bit: 3, target: 6) |
            ((state & 0x0F00_0000) >> 3) | bitnumintl(state, bit: 8, target: 11) |
            bitnumintl(state, bit: 7, target: 12) | ((state & 0x00F0_0000) >> 5) |
            bitnumintl(state, bit: 12, target: 17) | bitnumintl(state, bit: 11, target: 18) |
            ((state & 0x000F_0000) >> 7) | bitnumintl(state, bit: 16, target: 23)
        var t2 = bitnumintl(state, bit: 15, target: 0) | ((state & 0x0000_F000) << 15) |
            bitnumintl(state, bit: 20, target: 5) | bitnumintl(state, bit: 19, target: 6) |
            ((state & 0x0000_0F00) << 13) | bitnumintl(state, bit: 24, target: 11) |
            bitnumintl(state, bit: 23, target: 12) | ((state & 0x0000_00F0) << 11) |
            bitnumintl(state, bit: 28, target: 17) | bitnumintl(state, bit: 27, target: 18) |
            ((state & 0x0000_000F) << 9) | bitnumintl(state, bit: 0, target: 23)

        var largeState = [
            UInt8((t1 >> 24) & 0xFF), UInt8((t1 >> 16) & 0xFF), UInt8((t1 >> 8) & 0xFF),
            UInt8((t2 >> 24) & 0xFF), UInt8((t2 >> 16) & 0xFF), UInt8((t2 >> 8) & 0xFF),
        ]
        for index in 0 ..< 6 {
            largeState[index] ^= key[index]
        }

        var substituted: UInt32 = 0
        substituted |= UInt32(sBoxes[0][sBoxIndex(Int(largeState[0] >> 2))]) << 28
        substituted |= UInt32(sBoxes[1][sBoxIndex(Int(((largeState[0] & 0x03) << 4) | (largeState[1] >> 4)))]) << 24
        substituted |= UInt32(sBoxes[2][sBoxIndex(Int(((largeState[1] & 0x0F) << 2) | (largeState[2] >> 6)))]) << 20
        substituted |= UInt32(sBoxes[3][sBoxIndex(Int(largeState[2] & 0x3F))]) << 16
        substituted |= UInt32(sBoxes[4][sBoxIndex(Int(largeState[3] >> 2))]) << 12
        substituted |= UInt32(sBoxes[5][sBoxIndex(Int(((largeState[3] & 0x03) << 4) | (largeState[4] >> 4)))]) << 8
        substituted |= UInt32(sBoxes[6][sBoxIndex(Int(((largeState[4] & 0x0F) << 2) | (largeState[5] >> 6)))]) << 4
        substituted |= UInt32(sBoxes[7][sBoxIndex(Int(largeState[5] & 0x3F))])

        return bitnumintl(substituted, bit: 15, target: 0) | bitnumintl(substituted, bit: 6, target: 1) |
            bitnumintl(substituted, bit: 19, target: 2) | bitnumintl(substituted, bit: 20, target: 3) |
            bitnumintl(substituted, bit: 28, target: 4) | bitnumintl(substituted, bit: 11, target: 5) |
            bitnumintl(substituted, bit: 27, target: 6) | bitnumintl(substituted, bit: 16, target: 7) |
            bitnumintl(substituted, bit: 0, target: 8) | bitnumintl(substituted, bit: 14, target: 9) |
            bitnumintl(substituted, bit: 22, target: 10) | bitnumintl(substituted, bit: 25, target: 11) |
            bitnumintl(substituted, bit: 4, target: 12) | bitnumintl(substituted, bit: 17, target: 13) |
            bitnumintl(substituted, bit: 30, target: 14) | bitnumintl(substituted, bit: 9, target: 15) |
            bitnumintl(substituted, bit: 1, target: 16) | bitnumintl(substituted, bit: 7, target: 17) |
            bitnumintl(substituted, bit: 23, target: 18) | bitnumintl(substituted, bit: 13, target: 19) |
            bitnumintl(substituted, bit: 31, target: 20) | bitnumintl(substituted, bit: 26, target: 21) |
            bitnumintl(substituted, bit: 2, target: 22) | bitnumintl(substituted, bit: 8, target: 23) |
            bitnumintl(substituted, bit: 18, target: 24) | bitnumintl(substituted, bit: 12, target: 25) |
            bitnumintl(substituted, bit: 29, target: 26) | bitnumintl(substituted, bit: 5, target: 27) |
            bitnumintl(substituted, bit: 21, target: 28) | bitnumintl(substituted, bit: 10, target: 29) |
            bitnumintl(substituted, bit: 3, target: 30) | bitnumintl(substituted, bit: 24, target: 31)
    }

    private static func sBoxIndex(_ value: Int) -> Int {
        (value & 0x20) | ((value & 0x1F) >> 1) | ((value & 1) << 4)
    }

    private static func desCrypt(_ input: [UInt8], schedule: KeySchedule) -> [UInt8] {
        let (initialLeft, initialRight) = initialPermutation(input)
        var left = initialLeft
        var right = initialRight
        for index in 0 ..< 15 {
            let previousRight = right
            right = fFunction(right, key: schedule[index]) ^ left
            left = previousRight
        }
        left = fFunction(right, key: schedule[15]) ^ left
        return inverseInitialPermutation(left, right)
    }
}
