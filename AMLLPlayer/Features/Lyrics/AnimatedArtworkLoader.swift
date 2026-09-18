import Foundation
import Observation

@MainActor @Observable
final class AnimatedArtworkLoader {
    enum Status: String { case idle, loading, ready, unavailable, failed }
    private(set) var status: Status = .idle
    private(set) var localURL: URL?
    private(set) var trackID: String?
    private(set) var kind: ArtworkAsset.Kind?
    @ObservationIgnored private var revision = UUID()

    func reset() {
        revision = UUID(); localURL = nil; trackID = nil; kind = nil; status = .idle
    }

    func load(trackID: String, kind: ArtworkAsset.Kind = .squareVideo,
              assets: @MainActor () async throws -> [ArtworkAsset],
              download: @MainActor (URL) async throws -> URL) async
    {
        reset()
        self.trackID = trackID
        status = .loading
        let revision = self.revision
        do {
            let assets = try await assets()
            try Task.checkCancellation()
            guard revision == self.revision else { return }
            // A portrait-only release must not be cropped into the standard
            // square page. The separate immersive layout owns tall resources.
            guard let asset = assets.first(where: { $0.kind == kind }) else {
                status = .unavailable; return
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
        }
    }
}
