import AVFoundation

@MainActor enum MusicAudioSession {
    private(set) static var ownsPlayback = false
    private static var artworkPrepared = false
    private static var pictureInPicturePrepared = false
    private static var pictureInPictureActivated = false
    static func prepareArtwork() throws {
        guard !ownsPlayback, !pictureInPicturePrepared, !artworkPrepared else { return }
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
        if pictureInPicturePrepared {
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: .mixWithOthers)
        }
        if !pictureInPictureActivated {
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
        if activated { try? session.setActive(false, options: .notifyOthersOnDeactivation) }
        try? prepareArtwork()
    }
}
