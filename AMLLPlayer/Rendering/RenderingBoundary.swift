import Foundation

struct RenderingSnapshot: Equatable, Sendable {
    let timestamp: TimeInterval
}

@MainActor
protocol RenderingBoundary: AnyObject {
    func render(_ snapshot: RenderingSnapshot)
}
