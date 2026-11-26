import AVFoundation
import AVKit
import MediaPlayer
import SwiftUI
import UIKit

struct SystemMusicRoutesView: View {
    var body: some View {
        VStack(spacing: 24) {
            Text("当前音乐来源使用系统 AirPlay 和音量控制。")
            SystemAirPlayButton().frame(width: 60, height: 60)
            SystemMusicVolumeView().frame(height: 44)
        }.padding()
    }
}

struct SystemAirPlayButton: UIViewRepresentable {
    func makeUIView(context _: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.prioritizesVideoDevices = false
        return view
    }

    func updateUIView(_: AVRoutePickerView, context _: Context) {}
}

struct SystemMusicVolumeView: UIViewRepresentable {
    func makeUIView(context _: Context) -> MPVolumeView {
        let view = MPVolumeView()
        view.showsRouteButton = false
        return view
    }

    func updateUIView(_: MPVolumeView, context _: Context) {}
}

struct LyricsSystemVolumeControl: View {
    var tabletTrackThickness: CGFloat? = nil
    @State private var systemVolume = Double(AVAudioSession.sharedInstance().outputVolume)
    @State private var draft = Double(AVAudioSession.sharedInstance().outputVolume)
    @State private var editing = false
    @State private var requestedVolume = Double(AVAudioSession.sharedInstance().outputVolume)
    @State private var requestRevision = 0

    var body: some View {
        LyricsCapsuleSlider(
            value: Binding(
                get: { editing ? draft : systemVolume },
                set: { newValue in
                    draft = newValue
                    systemVolume = newValue
                    requestedVolume = newValue
                    requestRevision += 1
                }
            ),
            maximum: 1,
            trackThickness: tabletTrackThickness
        ) { isEditing in
            if isEditing {
                draft = systemVolume
                editing = true
            } else {
                editing = false
                systemVolume = draft
                requestedVolume = draft
                requestRevision += 1
            }
        }
        .accessibilityLabel(Text("render.volume"))
        .background {
            SystemVolumeBridgeView(requestedVolume: requestedVolume, requestRevision: requestRevision) { updated in
                if !editing {
                    systemVolume = updated
                }
            }
            .frame(width: 1, height: 1)
            .opacity(0.01)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

private struct SystemVolumeBridgeView: UIViewRepresentable {
    let requestedVolume: Double
    let requestRevision: Int
    let onVolumeChange: @MainActor (Double) -> Void

    @MainActor
    final class Coordinator {
        var observation: NSKeyValueObservation?
        var lastAppliedRevision = 0
        var onVolumeChange: @MainActor (Double) -> Void

        init(onVolumeChange: @escaping @MainActor (Double) -> Void) {
            self.onVolumeChange = onVolumeChange
            observation = AVAudioSession.sharedInstance().observe(\.outputVolume, options: [.initial, .new]) { [weak self] session, change in
                let value = Double(change.newValue ?? session.outputVolume)
                Task { @MainActor [weak self] in
                    self?.onVolumeChange(value)
                }
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onVolumeChange: onVolumeChange)
    }

    func makeUIView(context _: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        view.showsRouteButton = false
        return view
    }

    func updateUIView(_ uiView: MPVolumeView, context: Context) {
        context.coordinator.onVolumeChange = onVolumeChange
        guard context.coordinator.lastAppliedRevision != requestRevision else { return }
        context.coordinator.lastAppliedRevision = requestRevision
        if let slider = Self.findSlider(in: uiView) {
            slider.setValue(Float(min(1, max(0, requestedVolume))), animated: false)
            slider.sendActions(for: .valueChanged)
        }
    }

    private static func findSlider(in view: UIView) -> UISlider? {
        for subview in view.subviews {
            if let slider = subview as? UISlider { return slider }
            if let nested = findSlider(in: subview) { return nested }
        }
        return nil
    }
}
