import SwiftUI

/// Once selected, each renderer keeps its context until the lyric page closes.
struct AMLLBackground: View {
    var artworkURL: URL?
    var active: Bool
    var blur: Double
    var mode: LyricsRenderConfiguration.BackgroundMode
    @State private var usedMesh = false
    @State private var usedPixi = false

    var body: some View {
        ZStack {
            if usedMesh || mode == .mesh {
                AMLLMeshBackground(artworkURL: artworkURL, active: active && mode == .mesh, blur: blur)
                    .opacity(mode == .mesh ? 1 : 0)
            }
            if usedPixi || mode == .pixi {
                AMLLPixiBackground(artworkURL: artworkURL, active: active && mode == .pixi)
                    .opacity(mode == .pixi ? 1 : 0)
            }
        }
        .onChange(of: mode, initial: true) { _, value in
            if value == .mesh {
                usedMesh = true
            } else {
                usedPixi = true
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
