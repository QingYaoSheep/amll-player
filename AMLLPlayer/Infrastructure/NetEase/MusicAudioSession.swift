import AVFoundation

@MainActor enum MusicAudioSession {
    private(set) static var ownsPlayback = false
    private static var artworkPrepared = false
    static func prepareArtwork() throws {
        guard !ownsPlayback, !artworkPrepared else { return }
        try AVAudioSession.sharedInstance().setCategory(.ambient, mode: .default)
        artworkPrepared = true
    }
    static func acquirePlayback() throws {
        try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try AVAudioSession.sharedInstance().setActive(true)
        ownsPlayback = true; artworkPrepared = false
    }
    static func releasePlayback() {
        guard ownsPlayback else { return }
        ownsPlayback = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        artworkPrepared = false
    }
}
