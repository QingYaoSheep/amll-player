import Foundation

struct PlayerClock: Equatable, Sendable {
    private(set) var anchor: PlaybackSnapshot?

    init(anchor: PlaybackSnapshot? = nil) {
        self.anchor = anchor
    }

    func position(at uptime: TimeInterval) -> TimeInterval {
        guard let anchor else {
            return 0
        }

        guard anchor.position.isFinite, anchor.duration.isFinite, anchor.sampledAtUptime.isFinite,
              uptime.isFinite, anchor.playbackRate.isFinite else { return 0 }

        let elapsed = anchor.isPlaying ? max(0, uptime - anchor.sampledAtUptime) * max(0, anchor.playbackRate) : 0
        return min(max(0, anchor.position + elapsed), max(0, anchor.duration))
    }

    @discardableResult
    mutating func calibrate(
        with snapshot: PlaybackSnapshot,
        allowBackwardJump: Bool = false
    ) -> PlaybackSnapshot {
        var calibrated = snapshot

        if let anchor,
           anchor.item?.uri == snapshot.item?.uri,
           !allowBackwardJump
        {
            let predicted = position(at: snapshot.sampledAtUptime)
            let correctedPosition = max(snapshot.position, predicted)
            calibrated = PlaybackSnapshot(
                item: snapshot.item,
                isPlaying: snapshot.isPlaying,
                position: min(correctedPosition, snapshot.duration),
                duration: snapshot.duration,
                device: snapshot.device ?? anchor.device,
                restrictions: snapshot.restrictions,
                source: snapshot.source,
                sampledAtUptime: snapshot.sampledAtUptime,
                playbackRate: snapshot.playbackRate, positionRevision: snapshot.positionRevision,
                shuffleEnabled: snapshot.shuffleEnabled, repeatMode: snapshot.repeatMode
            )
        }

        anchor = calibrated
        return calibrated
    }
}
