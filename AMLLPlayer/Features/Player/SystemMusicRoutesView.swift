import AVKit
import MediaPlayer
import SwiftUI

struct SystemMusicRoutesView: View {
    var body: some View {
        VStack(spacing: 24) {
            Text("Apple Music 使用系统 AirPlay 和音量控制。")
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
