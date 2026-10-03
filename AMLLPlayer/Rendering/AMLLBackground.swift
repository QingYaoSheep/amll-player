import SwiftUI

/// Once selected, each renderer keeps its context until the lyric page closes.
struct AMLLBackground: View {
    var artworkURL: URL?
    var active: Bool
    var blur: Double
    var mode: LyricsRenderConfiguration.BackgroundMode
    var color: LyricsRenderConfiguration.BackgroundColor = .sourceDefault
    var gradientEnd: LyricsRenderConfiguration.BackgroundColor = .sourceDefault
    var flowing: FlowingBackgroundConfiguration = .init()
    var dimming: Double = 0
    /// Presentation override; never writes the user's background preferences.
    var suppressBlur = false
    @State private var usedMesh = false
    @State private var usedPixi = false
    @State private var usedFlowing = false

    var effectiveMeshBlur: Double { suppressBlur ? 0 : blur }
    var effectiveFlowingConfiguration: FlowingBackgroundConfiguration {
        var value = flowing
        if suppressBlur { value.blur = 0 }
        return value
    }

    var body: some View {
        ZStack {
            if mode == .solid {
                color.swiftUIColor
            }
            if mode == .gradient {
                LinearGradient(colors: [color.swiftUIColor, gradientEnd.swiftUIColor], startPoint: .top, endPoint: .bottom)
            }
            if usedMesh || mode == .mesh {
                AMLLMeshBackground(artworkURL: artworkURL, active: active && mode == .mesh, blur: effectiveMeshBlur)
                    .opacity(mode == .mesh ? 1 : 0)
            }
            if usedPixi || mode == .pixi {
                AMLLPixiBackground(artworkURL: artworkURL, active: active && mode == .pixi, blurEnabled: !suppressBlur)
                    .opacity(mode == .pixi ? 1 : 0)
            }
            if usedFlowing || mode == .flowing {
                AMLLFlowingBackground(artworkURL: artworkURL, active: active && mode == .flowing,
                    configuration: effectiveFlowingConfiguration, suppressBlur: suppressBlur)
                    .opacity(mode == .flowing ? 1 : 0)
            }
        }
        .overlay { Color.black.opacity(dimming) }
        .onChange(of: mode, initial: true) { _, value in
            if value == .mesh {
                usedMesh = true
            }
            if value == .pixi {
                usedPixi = true
            }
            if value == .flowing { usedFlowing = true }
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
