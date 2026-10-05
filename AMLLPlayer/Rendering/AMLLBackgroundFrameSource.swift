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
        private struct Slot {
            var texture: (any MTLTexture)?
            var leased = false
        }
        private let lock = NSLock()
        private var slots = (0 ..< 4).map { _ in Slot() }
        private var enabled = false

        func setEnabled(_ value: Bool) {
            lock.lock(); defer { lock.unlock() }
            enabled = value
            if !value {
                for index in slots.indices where !slots[index].leased { slots[index].texture = nil }
            }
        }
        func acquire(matching source: any MTLTexture) -> (Int, any MTLTexture)? {
            lock.lock(); defer { lock.unlock() }
            guard enabled, let index = slots.indices.first(where: { !slots[$0].leased }) else { return nil }
            if let texture = slots[index].texture, texture.width == source.width,
               texture.height == source.height, texture.pixelFormat == source.pixelFormat {
                slots[index].leased = true
                return (index, texture)
            }
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: source.pixelFormat,
                width: source.width, height: source.height, mipmapped: false)
            descriptor.storageMode = .private
            descriptor.usage = [.shaderRead]
            // One budget spans viewport generations. Retired readers keep
            // their slots; only an unleased texture can change dimensions.
            slots[index].texture = nil
            guard let texture = source.device.makeTexture(descriptor: descriptor) else { return nil }
            slots[index].texture = texture; slots[index].leased = true
            return (index, texture)
        }
        func release(_ index: Int) {
            lock.lock(); defer { lock.unlock() }
            slots[index].leased = false
            if !enabled { slots[index].texture = nil }
        }
        var statistics: (textures: Int, bytes: Int) {
            lock.lock(); defer { lock.unlock() }
            let textures = slots.compactMap(\.texture)
            return (textures.count, textures.reduce(0) { $0 + $1.width * $1.height * 4 })
        }
    }

    private let lock = NSLock()
    private var enabled = false
    private var generation = UUID()
    private let pool = TexturePool()
    private var dimensions: (width: Int, height: Int, format: MTLPixelFormat)?
    private var latest: AMLLBackgroundTextureFrame?
    private var sequence: UInt64 = 0
    private var copies = 0
    private var skipped = 0

    func setEnabled(_ value: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard value != enabled else { return }
        enabled = value; generation = UUID()
        latest = nil
        pool.setEnabled(value)
    }

    /// Blit is appended to the background's existing render command. No CPU
    /// readback, extra renderer, or main-actor completion hop is involved.
    func encodeCopy(texture: any MTLTexture, viewport: CGSize, timestamp: CFTimeInterval,
                    command: any MTLCommandBuffer) {
        lock.lock()
        guard enabled, !texture.isFramebufferOnly else { lock.unlock(); return }
        if dimensions?.width != texture.width || dimensions?.height != texture.height || dimensions?.format != texture.pixelFormat {
            dimensions = (texture.width, texture.height, texture.pixelFormat)
            generation = UUID(); latest = nil
        }
        guard let (slot, output) = pool.acquire(matching: texture) else {
            skipped += 1; lock.unlock(); return
        }
        sequence &+= 1
        let token = generation
        let pool = pool
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
        let allocation = pool.statistics
        return (copies, skipped, allocation.textures, allocation.bytes)
    }
}
