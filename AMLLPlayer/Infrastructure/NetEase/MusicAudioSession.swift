import AVFoundation

@MainActor enum MusicAudioSession {
    private(set) static var ownsPlayback = false
    private static var artworkPrepared = false
    private static var pictureInPicturePrepared = false
    private static var pictureInPictureActivated = false
    private(set) static var lockScreenKeepAliveActivated = false
    private static var mixesPlaybackWithOthers: Bool {
        pictureInPicturePrepared || pictureInPictureActivated || lockScreenKeepAliveActivated
    }

    static func prepareArtwork() throws {
        guard !ownsPlayback, !mixesPlaybackWithOthers, !artworkPrepared else { return }
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
        if mixesPlaybackWithOthers {
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: .mixWithOthers)
        }
        if !pictureInPictureActivated && !lockScreenKeepAliveActivated {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        artworkPrepared = false
    }

    static func preparePictureInPicture() throws {
        guard !pictureInPicturePrepared else { return }
        if !ownsPlayback {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: .mixWithOthers)
            artworkPrepared = false
        }
        pictureInPicturePrepared = true
    }

    static func activatePictureInPicture() throws {
        try preparePictureInPicture()
        guard !pictureInPictureActivated else { return }
        if !ownsPlayback { try AVAudioSession.sharedInstance().setActive(true) }
        pictureInPictureActivated = true
    }

    static func releasePictureInPicture() {
        guard pictureInPicturePrepared else { return }
        pictureInPicturePrepared = false
        let activated = pictureInPictureActivated
        pictureInPictureActivated = false
        guard !ownsPlayback else { return }
        let session = AVAudioSession.sharedInstance()
        if activated && !lockScreenKeepAliveActivated {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
        }
        try? prepareArtwork()
    }

    static func activateLockScreenKeepAlive() throws {
        guard !ownsPlayback else { return }
        if !mixesPlaybackWithOthers {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: .mixWithOthers)
            artworkPrepared = false
        }
        if !lockScreenKeepAliveActivated {
            try AVAudioSession.sharedInstance().setActive(true)
            lockScreenKeepAliveActivated = true
        }
    }

    static func releaseLockScreenKeepAlive() {
        guard lockScreenKeepAliveActivated else { return }
        lockScreenKeepAliveActivated = false
        guard !ownsPlayback else { return }
        let session = AVAudioSession.sharedInstance()
        if !pictureInPictureActivated {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
        }
        try? prepareArtwork()
    }
}
