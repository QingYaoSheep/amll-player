import Foundation

/// Prevents display auto-lock only while the user is actively viewing a playing
/// lyrics page in the foreground; restores system idle timer immediately otherwise.
enum LyricsIdleTimerPolicy {
    nonisolated static let preferenceKey = "lyrics.keepScreenAwake"

    static func shouldKeepAwake(
        enabled: Bool,
        lyricsPageVisible: Bool,
        isForeground: Bool,
        isPlaying: Bool
    ) -> Bool {
        enabled && lyricsPageVisible && isForeground && isPlaying
    }
}
