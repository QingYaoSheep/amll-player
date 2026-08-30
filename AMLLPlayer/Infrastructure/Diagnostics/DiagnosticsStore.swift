import Foundation
import OSLog

actor DiagnosticsStore: DiagnosticsExporting {
    private struct Event: Codable, Sendable {
        let timestamp: Date
        let category: String
        let message: String
    }

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "net.stevexmh.amllplayer",
        category: "diagnostics"
    )
    private var events: [Event] = []
    private let maximumEventCount = 500

    func record(category: String, message: String) {
        let safeCategory = Self.redact(category)
        let safeMessage = Self.redact(message)

        logger.info("[\(safeCategory, privacy: .public)] \(safeMessage, privacy: .public)")
        events.append(Event(timestamp: .now, category: safeCategory, message: safeMessage))

        if events.count > maximumEventCount {
            events.removeFirst(events.count - maximumEventCount)
        }
    }

    func exportDiagnostics() async throws -> URL {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let exportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("amll-player-diagnostics-\(UUID().uuidString)")
            .appendingPathExtension("json")
        try encoder.encode(events).write(to: exportURL, options: .atomic)
        return exportURL
    }

    static func redact(_ value: String) -> String {
        let patterns = [
            #"(?i)(authorization\s*:\s*bearer\s+)[^\s]+"#,
            #"(?i)((?:access|refresh|id)[_-]?token\s*[=:]\s*)[^\s&,]+"#,
            #"(?i)(client[_-]?id\s*[=:]\s*)[^\s&,]+"#,
            #"(?i)(code\s*[=:]\s*)[^\s&,]+"#,
            #"(?i)((?:code[_-]?(?:verifier|challenge)|authorization[_-]?code)\s*[=:]\s*)[^\s&,]+"#,
        ]

        return patterns.reduce(value) { result, pattern in
            result.replacingOccurrences(
                of: pattern,
                with: "$1<redacted>",
                options: .regularExpression
            )
        }
    }
}
