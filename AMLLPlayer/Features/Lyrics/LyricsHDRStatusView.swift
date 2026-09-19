import SwiftUI
import UIKit

/// Query the screen of the actual settings window, including external displays.
struct LyricsHDRStatusView: UIViewRepresentable {
    func makeUIView(context _: Context) -> StatusLabel {
        StatusLabel()
    }

    func updateUIView(_ view: StatusLabel, context _: Context) {
        view.refresh()
    }

    final class StatusLabel: UILabel {
        private var timer: Timer?
        override init(frame: CGRect) {
            super.init(frame: frame)
            font = .preferredFont(forTextStyle: .footnote)
            textColor = .secondaryLabel
            adjustsFontForContentSizeCategory = true
            numberOfLines = 0
        }

        required init?(coder _: NSCoder) {
            nil
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            timer?.invalidate(); timer = nil
            if window != nil {
                timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                    Task { @MainActor [weak self] in self?.refresh() }
                }
            }
            refresh()
        }

        func refresh() {
            guard let screen = window?.screen else { return }
            if UIAccessibility.isReduceTransparencyEnabled {
                text = "SDR 回退：减少透明度已开启"
            } else if screen.potentialEDRHeadroom <= 1 || screen.currentEDRHeadroom <= 1 {
                text = "SDR 回退：当前屏幕没有可用扩展亮度"
            } else {
                text = String(format: "HDR 可用：当前高光上限 %.2f× SDR 白", min(LyricsHDRConfiguration.targetBrightness, screen.currentEDRHeadroom))
            }
        }
    }
}
