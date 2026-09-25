import Foundation

/// Optional, bounded measurements from the production canvas. All values are
/// milliseconds except resource bytes. Sampling never changes the frame clock.
struct AMLLFramePerformance: Codable, Sendable {
    struct Sample: Codable, Sendable {
        var interval: Double
        var cpu: Double
        var layout: Double
        var raster: Double
        var engine: Double
        var layers: Double
        var drawableWait: Double
        var gpuSubmission: Double
        var gpu: Double
        var cacheBytes: Int
    }

    struct Distribution: Codable, Sendable {
        var p50: Double
        var p95: Double
        var p99: Double

        init(_ values: [Double]) {
            let sorted = values.sorted()
            func percentile(_ fraction: Double) -> Double {
                guard !sorted.isEmpty else { return 0 }
                return sorted[min(sorted.count - 1, Int(ceil(Double(sorted.count) * fraction)) - 1)]
            }
            p50 = percentile(0.5); p95 = percentile(0.95); p99 = percentile(0.99)
        }
    }

    var targetFPS: Int
    var frames: Int
    var longFrames: Int
    var cpu: Distribution
    var interval: Distribution
    var layout: Distribution
    var raster: Distribution
    var engine: Distribution
    var layers: Distribution
    var drawableWait: Distribution
    var gpuSubmission: Distribution
    var gpu: Distribution
    var peakCacheBytes: Int
}

@MainActor
final class AMLLFramePerformanceRecorder {
    private var storage: [AMLLFramePerformance.Sample] = []
    private var nextIndex = 0
    private let capacity: Int

    var samples: [AMLLFramePerformance.Sample] {
        guard storage.count == capacity else { return storage }
        return Array(storage[nextIndex...]) + Array(storage[..<nextIndex])
    }

    init(capacity: Int = 1_800) {
        self.capacity = max(1, capacity)
    }

    func reset() {
        storage.removeAll(keepingCapacity: true)
        nextIndex = 0
    }

    func append(_ sample: AMLLFramePerformance.Sample) {
        if storage.count == capacity {
            storage[nextIndex] = sample
            nextIndex = (nextIndex + 1) % capacity
        } else {
            storage.append(sample)
        }
    }

    func summary(targetFPS: Int) -> AMLLFramePerformance {
        let recorded = samples
        let budget = 1_000 / Double(max(1, targetFPS))
        return .init(targetFPS: targetFPS, frames: recorded.count,
                     longFrames: recorded.filter { $0.interval > budget * 1.5 }.count,
                     cpu: .init(recorded.map(\.cpu)), interval: .init(recorded.map(\.interval)),
                     layout: .init(recorded.map(\.layout)), raster: .init(recorded.map(\.raster)),
                     engine: .init(recorded.map(\.engine)), layers: .init(recorded.map(\.layers)),
                     drawableWait: .init(recorded.map(\.drawableWait)),
                     gpuSubmission: .init(recorded.map(\.gpuSubmission)),
                     gpu: .init(recorded.map(\.gpu)),
                     peakCacheBytes: recorded.map(\.cacheBytes).max() ?? 0)
    }
}
