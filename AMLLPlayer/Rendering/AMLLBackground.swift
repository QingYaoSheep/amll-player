import SwiftUI

/// Once selected, each renderer keeps its context until the lyric page closes.
struct AMLLBackground: View {
    var artworkURL: URL?
    var active: Bool
    var blur: Double
    var mode: LyricsRenderConfiguration.BackgroundMode
    var color: LyricsRenderConfiguration.BackgroundColor = .sourceDefault
    var gradientEnd: LyricsRenderConfiguration.BackgroundColor = .sourceDefault
    @State private var usedMesh = false
    @State private var usedPixi = false

    var body: some View {
        ZStack {
            if mode == .solid {
                color.swiftUIColor
            }
            if mode == .gradient {
                LinearGradient(colors: [color.swiftUIColor, gradientEnd.swiftUIColor], startPoint: .top, endPoint: .bottom)
            }
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
            }
            if value == .pixi {
                usedPixi = true
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

extension LyricsRenderConfiguration.BackgroundColor {
    var swiftUIColor: Color {
        func component(_ value: Double) -> Double {
            value.isFinite ? min(1, max(0, value)) : 17.0 / 255
        }
        return Color(.sRGB, red: component(red), green: component(green), blue: component(blue), opacity: 1)
    }
}
