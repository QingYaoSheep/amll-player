import Foundation
import Observation

@MainActor @Observable
final class AnimatedArtworkLoader {
    enum Status: String { case idle, loading, streaming, ready, unavailable, failed }
    private(set) var status: Status = .idle
    private(set) var localURL: URL?
    private(set) var trackID: String?
    private(set) var kind: ArtworkAsset.Kind?
    private(set) var failureCode: String?
    private(set) var streamingURL: URL?
    private(set) var playbackState: ArtworkPlaybackState = .preparing
    var requestToken: UUID {
        revision
    }

    func playbackChanged(token: UUID, url: URL, state: ArtworkPlaybackState) {
        guard token == revision, url == playbackURL else { return }
        playbackState = state
    }

    var playbackURL: URL? {
        localURL ?? streamingURL
    }

    @ObservationIgnored private var revision = UUID()

    func playbackFailed(trackID: String, url: URL, error: Error?, token: UUID? = nil) {
        if let token, token != revision {
            return
        }
        guard self.trackID == trackID, playbackURL == url else { return }
        ArtworkMediaCache.shared.invalidate(localURL: url)
        // A completed cache request must not resurrect a resource which the
        // actual decoder rejected. Retrying starts a fresh request revision.
        revision = UUID()
        localURL = nil; streamingURL = nil; kind = nil
        status = .failed
        playbackState = .failed
        let failure = (error ?? URLError(.cannotDecodeContentData)) as NSError
        failureCode = "\(failure.domain) (\(failure.code))"
    }

    func reset() {
        revision = UUID(); localURL = nil; trackID = nil; kind = nil; status = .idle
        failureCode = nil
        streamingURL = nil
        playbackState = .preparing
    }

    func load(trackID: String, kind: ArtworkAsset.Kind = .squareVideo,
              streamWhileDownloading: Bool = false,
              assets: @MainActor () async throws -> [ArtworkAsset],
              download: @MainActor (URL) async throws -> URL) async
    {
        reset()
        self.trackID = trackID
        status = .loading
        let revision = revision
        do {
            let assets = try await assets()
            try Task.checkCancellation()
            guard revision == self.revision else { return }
            // A portrait-only release must not be cropped into the standard
            // square page. The separate immersive layout owns tall resources.
            guard let asset = assets.first(where: { $0.kind == kind }) else {
                status = .unavailable; return
            }
            if streamWhileDownloading, asset.url.scheme?.lowercased() == "https" {
                streamingURL = asset.url; self.kind = asset.kind; status = .streaming
            }
            let local = try await download(asset.url)
            try Task.checkCancellation()
            guard revision == self.revision else { return }
            guard local.isFileURL else { throw URLError(.unsupportedURL) }
            localURL = local; self.kind = asset.kind; status = .ready
        } catch {
            guard revision == self.revision else { return }
            localURL = nil
            status = Task.isCancelled || error is CancellationError ? .idle : .failed
            if status == .idle {
                streamingURL = nil; self.kind = nil
            }
            if status == .failed {
                let failure = error as NSError
                failureCode = "\(failure.domain) (\(failure.code))"
                if streamingURL != nil {
                    status = .streaming
                }
            }
        }
    }
}
