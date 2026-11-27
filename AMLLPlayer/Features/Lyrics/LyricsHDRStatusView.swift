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
                text = String(localized: "已开启「减少透明度」，歌词使用普通亮度（SDR）。")
            } else if screen.potentialEDRHeadroom <= 1 || screen.currentEDRHeadroom <= 1 {
                text = String(localized: "这块屏幕当前没有可用的扩展亮度，歌词使用普通亮度（SDR）。")
            } else {
                text = String(format: String(localized: "HDR 可用：当前高光上限 %.2f× SDR 白"), min(LyricsHDRConfiguration.targetBrightness, screen.currentEDRHeadroom))
            }
        }
    }
}
