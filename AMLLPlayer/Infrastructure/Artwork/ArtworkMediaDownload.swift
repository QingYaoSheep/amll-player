import AVFoundation
import Foundation

/// One cancellable transfer, owned by the current cover request. No streaming
/// URL reaches AVPlayer: only completed local assets are eligible for display.
@MainActor
final class ArtworkMediaDownload: NSObject, @preconcurrency AVAssetDownloadDelegate {
    private static let wifi = ArtworkMediaDownload(allowCellular: false)
    private static let cellular = ArtworkMediaDownload(allowCellular: true)
    private var session: AVAssetDownloadURLSession?
    private var task: AVAssetDownloadTask?
    private var continuation: CheckedContinuation<URL, Error>?
    private var completedLocation: URL?
    private var requestID = UUID()
    private var recovery: Task<Void, Never>?

    private init(allowCellular: Bool) {
        super.init()
        UserDefaults.standard.set(true, forKey: "artwork.hasDownloadSessions")
        let suffix = allowCellular ? "cellular" : "wifi"
        let configuration = URLSessionConfiguration.background(withIdentifier: "net.stevexmh.amllplayer.artwork." + suffix)
        configuration.allowsCellularAccess = allowCellular
        configuration.allowsExpensiveNetworkAccess = allowCellular
        configuration.allowsConstrainedNetworkAccess = false
        configuration.sessionSendsLaunchEvents = false
        // Cover caching is not a user-requested offline media download.
        // Discretionary asset transfers do not create a system Live Activity.
        configuration.isDiscretionary = true
        let session = AVAssetDownloadURLSession(configuration: configuration, assetDownloadDelegate: self, delegateQueue: .main)
        self.session = session
        recovery = Task {
            // Reattach to stable session identifiers after process death so
            // abandoned cover transfers cannot accumulate outside the cache.
            for task in await session.allTasks {
                task.cancel()
            }
        }
    }

    static func recoverAbandonedTransfers() {
        guard UserDefaults.standard.bool(forKey: "artwork.hasDownloadSessions") else { return }
        _ = wifi; _ = cellular
    }

    static func download(_ url: URL, allowCellular: Bool) async throws -> URL {
        try await (allowCellular ? cellular : wifi).fetch(url, allowCellular: allowCellular)
    }

    private func fetch(_ url: URL, allowCellular: Bool) async throws -> URL {
        if let cached = ArtworkMediaCache.shared.cached(url) {
            return cached
        }
        try Task.checkCancellation()
        if url.pathExtension.lowercased() != "m3u8" {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.allowsCellularAccess = allowCellular
            configuration.allowsExpensiveNetworkAccess = allowCellular
            configuration.allowsConstrainedNetworkAccess = false
            configuration.timeoutIntervalForResource = 120
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            let (local, response) = try await session.download(from: url)
            defer { try? FileManager.default.removeItem(at: local) }
            try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse, (200 ... 299).contains(response.statusCode),
                  response.mimeType?.hasPrefix("video/") == true else { throw URLError(.cannotDecodeContentData) }
            return try ArtworkMediaCache.shared.insert(local, for: url, managedPackage: false)
        }
        await recovery?.value
        try Task.checkCancellation()
        finish(.failure(CancellationError()))
        let id = UUID()
        requestID = id
        let local: URL = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                self.continuation = continuation
                guard let session = self.session else { self.finish(.failure(URLError(.unknown))); return }
                let asset = AVURLAsset(url: url, options: [AVURLAssetAllowsCellularAccessKey: allowCellular])
                let download = AVAssetDownloadConfiguration(asset: asset, title: "AMLL 动态封面")
                let task = session.makeAssetDownloadTask(downloadConfiguration: download)
                self.task = task
                task.resume()
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.requestID == id else { return }
                self.finish(.failure(CancellationError()))
            }
        }
        do {
            try Task.checkCancellation()
            return try ArtworkMediaCache.shared.insert(local, for: url, managedPackage: true)
        } catch {
            try? FileManager.default.removeItem(at: local)
            throw error
        }
    }

    func urlSession(_: URLSession, assetDownloadTask: AVAssetDownloadTask, didFinishDownloadingTo location: URL) {
        guard continuation != nil, task?.taskIdentifier == assetDownloadTask.taskIdentifier else { try? FileManager.default.removeItem(at: location); return }
        completedLocation = location
    }

    func urlSession(_: URLSession, assetDownloadTask: AVAssetDownloadTask, willDownloadTo location: URL) {
        // makeAssetDownloadTask(downloadConfiguration:) reports the location
        // before completion. Save it, but never expose the unfinished package.
        guard continuation != nil, task?.taskIdentifier == assetDownloadTask.taskIdentifier else {
            assetDownloadTask.cancel()
            return
        }
        completedLocation = location
    }

    func urlSession(_: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard self.task?.taskIdentifier == task.taskIdentifier else { return }
        if let error {
            finish(.failure(error))
        } else if let completedLocation {
            finish(.success(completedLocation))
        } else {
            finish(.failure(URLError(.cannotCreateFile)))
        }
    }

    private func finish(_ result: Result<URL, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        if case .failure = result, let completedLocation {
            try? FileManager.default.removeItem(at: completedLocation)
        }
        completedLocation = nil
        task?.cancel(); task = nil
        continuation.resume(with: result)
    }
}
