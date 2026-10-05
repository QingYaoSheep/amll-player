import Metal
import CoreGraphics
import Foundation

/// Completed background pixels shared with the immersive blur. The private
/// texture is never modified while a reader or GPU command retains this lease.
final class AMLLBackgroundTextureFrame: @unchecked Sendable {
    let texture: any MTLTexture
    let viewport: CGSize
    let sequence: UInt64
    let timestamp: CFTimeInterval
    private let release: @Sendable () -> Void

    fileprivate init(texture: any MTLTexture, viewport: CGSize, sequence: UInt64,
                     timestamp: CFTimeInterval, release: @escaping @Sendable () -> Void) {
        self.texture = texture; self.viewport = viewport; self.sequence = sequence
        self.timestamp = timestamp; self.release = release
    }
    deinit { release() }
}

/// Only the producer allocates/encodes; completion publishes under the lock.
/// Four leased textures bound current output, blur inputs and pending copies.
/// Ordinary non-immersive backgrounds never enable this path.
final class AMLLBackgroundFrameSource: @unchecked Sendable {
    private final class TexturePool: @unchecked Sendable {
        private let lock = NSLock()
        private var textures: [any MTLTexture] = []
        private var leased = Set<Int>()
        let width: Int
        let height: Int
        let format: MTLPixelFormat

        init(_ texture: any MTLTexture) {
            width = texture.width; height = texture.height; format = texture.pixelFormat
        }
        func acquire(device: any MTLDevice) -> (Int, any MTLTexture)? {
            lock.lock(); defer { lock.unlock() }
            if let index = textures.indices.first(where: { !leased.contains($0) }) {
                leased.insert(index)
                return (index, textures[index])
            }
            guard textures.count < 4 else { return nil }
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format,
                width: width, height: height, mipmapped: false)
            descriptor.storageMode = .private
            descriptor.usage = [.shaderRead]
            guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
            let index = textures.count
            textures.append(texture); leased.insert(index)
            return (index, texture)
        }
        func release(_ index: Int) {
            lock.lock(); defer { lock.unlock() }
            leased.remove(index)
        }
        var allocatedCount: Int {
            lock.lock(); defer { lock.unlock() }
            return textures.count
        }
    }

    private let lock = NSLock()
    private var enabled = false
    private var generation = UUID()
    private var pool: TexturePool?
    private var latest: AMLLBackgroundTextureFrame?
    private var sequence: UInt64 = 0
    private var copies = 0
    private var skipped = 0

    func setEnabled(_ value: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard value != enabled else { return }
        enabled = value; generation = UUID()
        latest = nil
        if !value { pool = nil }
    }

    /// Blit is appended to the background's existing render command. No CPU
    /// readback, extra renderer, or main-actor completion hop is involved.
    func encodeCopy(texture: any MTLTexture, viewport: CGSize, timestamp: CFTimeInterval,
                    command: any MTLCommandBuffer) {
        lock.lock()
        guard enabled, !texture.isFramebufferOnly else { lock.unlock(); return }
        if pool?.width != texture.width || pool?.height != texture.height || pool?.format != texture.pixelFormat {
            pool = TexturePool(texture); generation = UUID(); latest = nil
        }
        guard let pool, let (slot, output) = pool.acquire(device: texture.device) else {
            skipped += 1; lock.unlock(); return
        }
        sequence &+= 1
        let token = generation
        let frame = AMLLBackgroundTextureFrame(texture: output, viewport: viewport, sequence: sequence,
            timestamp: timestamp, release: { pool.release(slot) })
        lock.unlock()
        guard let blit = command.makeBlitCommandEncoder() else { return }
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: .init(x: 0, y: 0, z: 0),
            sourceSize: .init(width: texture.width, height: texture.height, depth: 1),
            to: output, destinationSlice: 0, destinationLevel: 0, destinationOrigin: .init(x: 0, y: 0, z: 0))
        blit.endEncoding()
        command.addCompletedHandler { [weak self] command in
            guard command.status == .completed else { return }
            self?.publish(frame, generation: token)
        }
    }

    private func publish(_ frame: AMLLBackgroundTextureFrame, generation token: UUID) {
        lock.lock(); defer { lock.unlock() }
        guard enabled, generation == token, frame.sequence > (latest?.sequence ?? 0) else { return }
        latest = frame; copies += 1
    }

    func current(viewport: CGSize) -> AMLLBackgroundTextureFrame? {
        lock.lock(); defer { lock.unlock() }
        guard enabled, let latest, abs(latest.viewport.width - viewport.width) < 0.5,
              abs(latest.viewport.height - viewport.height) < 0.5 else { return nil }
        return latest
    }

    var statistics: (copies: Int, skipped: Int, textures: Int, bytes: Int) {
        lock.lock(); defer { lock.unlock() }
        let count = pool?.allocatedCount ?? 0
        return (copies, skipped, count, count * (pool?.width ?? 0) * (pool?.height ?? 0) * 4)
    }
}
