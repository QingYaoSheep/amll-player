import CoreImage
import ImageIO
import Observation

/// One immutable decode supplies the visible cover, reflection and live blur.
struct ImmersiveStillFrame: @unchecked Sendable {
    let image: CGImage
    let buffer: CVPixelBuffer
    var size: CGSize { CGSize(width: CGFloat(image.width), height: CGFloat(image.height)) }
}

actor ImmersiveStillArtworkCache {
    static let shared = ImmersiveStillArtworkCache()
    private var cached: [(URL, ImmersiveStillFrame)] = []
    private var pending: [URL: (id: UUID, task: Task<ImmersiveStillFrame?, Never>)] = [:]

    func load(_ url: URL) async -> ImmersiveStillFrame? {
        if let index = cached.firstIndex(where: { $0.0 == url }) {
            let value = cached.remove(at: index); cached.append(value)
            return value.1
        }
        if let request = pending[url] { return await request.task.value }
        // Fast track changes cannot leave an unbounded set of background decodes.
        if pending.count >= 2, let retired = pending.first {
            retired.value.task.cancel()
            pending.removeValue(forKey: retired.key)
        }
        let id = UUID()
        let task = Task.detached(priority: .userInitiated) { () -> ImmersiveStillFrame? in
            guard let data = try? await ArtworkImageData.load(url), !Task.isCancelled,
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 1600,
                    kCGImageSourceShouldCacheImmediately: true,
                  ] as CFDictionary) else { return nil }
            var buffer: CVPixelBuffer?
            guard CVPixelBufferCreate(kCFAllocatorDefault, image.width, image.height, kCVPixelFormatType_32BGRA,
                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer) == kCVReturnSuccess,
                let buffer else { return nil }
            let space = CGColorSpace(name: CGColorSpace.sRGB)!
            CIContext(options: [.cacheIntermediates: false]).render(CIImage(cgImage: image), to: buffer,
                bounds: CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height)), colorSpace: space)
            CVBufferSetAttachment(buffer, kCVImageBufferCGColorSpaceKey, space, .shouldPropagate)
            return ImmersiveStillFrame(image: image, buffer: buffer)
        }
        pending[url] = (id, task)
        let frame = await task.value
        guard pending[url]?.id == id else { return nil }
        pending[url] = nil
        if let frame {
            cached.append((url, frame))
            if cached.count > 2 { cached.removeFirst(cached.count - 2) }
        }
        return frame
    }
}

@MainActor @Observable final class ImmersiveStillArtwork {
    private var loadedFrame: ImmersiveStillFrame?
    private var loadedURL: URL?
    private var generation = UUID()

    func load(_ url: URL?) async {
        let request = UUID(); generation = request
        loadedFrame = nil
        loadedURL = nil
        guard let url else { return }
        let loaded = await ImmersiveStillArtworkCache.shared.load(url)
        guard !Task.isCancelled, generation == request else { return }
        loadedFrame = loaded
        loadedURL = url
    }

    func frame(for url: URL?) -> ImmersiveStillFrame? { loadedURL == url ? loadedFrame : nil }
}
