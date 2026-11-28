import SwiftUI

struct PlayPauseSymbolTransition: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if reduceMotion {
            content.contentTransition(.opacity)
        } else {
            content.contentTransition(.symbolEffect(.replace))
        }
    }
}

struct ReturnCurrentLyricsPill: View {
    let visible: Bool
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        Button {
            AppHaptics.shared.play(.selection)
            action()
        } label: {
            Label("render.returnCurrent", systemImage: "location.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .frame(minHeight: 44)
                .modifier(ReturnCurrentPillSurface(reduceTransparency: reduceTransparency, reduceMotion: reduceMotion))
        }
        .buttonStyle(MusicContentButtonStyle())
        .accessibilityIdentifier("resumeLyricsFollowing")
        .scaleEffect(visible || reduceMotion ? 1 : 0.95)
        .offset(y: visible || reduceMotion ? 0 : 10)
        .opacity(visible ? 1 : 0)
        .animation(MusicProductMotion.change, value: visible)
        .disabled(!visible)
        .allowsHitTesting(visible)
        .accessibilityHidden(!visible)
    }
}

private struct ReturnCurrentPillSurface: ViewModifier {
    let reduceTransparency: Bool
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        let shape = Capsule()
        if reduceTransparency {
            content
                .background(Color(white: 0.16), in: shape)
                .overlay { shape.strokeBorder(.white.opacity(0.22), lineWidth: 0.75) }
        } else if #available(iOS 26.0, *) {
            content.glassEffect(.regular.interactive(!reduceMotion), in: shape)
        } else {
            content
                .background(.ultraThinMaterial, in: shape)
                .overlay { shape.strokeBorder(.white.opacity(0.16), lineWidth: 0.75) }
        }
    }
}
