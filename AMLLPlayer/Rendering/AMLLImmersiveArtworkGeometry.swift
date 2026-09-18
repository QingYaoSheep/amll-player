import CoreGraphics

/// react-full vertical.tsx calcCoverLayout, applied to the native shell's cover slot.
enum AMLLImmersiveArtworkGeometry {
    static func frame(viewport: CGSize, slot: CGRect) -> CGRect {
        let size = max(slot.midY * 2.4, viewport.width * 1.2, min(slot.width, slot.height))
        return CGRect(x: slot.midX - size / 2, y: slot.midY - size / 2, width: size, height: size)
    }
}
