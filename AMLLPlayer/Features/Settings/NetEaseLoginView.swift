import CoreImage.CIFilterBuiltins
import SwiftUI

struct NetEaseLoginView: View {
    @Bindable var model: AppModel
    @State private var qr: QRPresentation?
    @State private var requestedQR = false
    @State private var isStartingQR = false
    @State private var isCheckingAccount = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct QRPresentation {
        let source: URL
        let image: UIImage
        let file: URL?
    }

    private var session: NetEaseSession { model.netEaseSession }
    private var connected: Bool { session.currentState.connected }
    private var hasActiveQR: Bool { session.qrURL != nil }
    private var isGenerating: Bool { isStartingQR || (session.currentState.requesting && !hasActiveQR) }

    var body: some View {
        SettingsPage {
            SettingsAccountHeader(
                service: .netease, name: session.profile?.name, avatar: session.profile?.avatar,
                status: model.settingsConnectionStatus(.netease), connected: connected
            )
            SettingsSection {
                if hasActiveQR {
                    qrCard.transition(.opacity)
                } else if requestedQR, session.currentState.error == nil, !isGenerating, session.qrStatus != "登录成功" {
                    Text(LocalizedStringKey(session.qrStatus)).font(.subheadline).foregroundStyle(.secondary)
                }
                if let error = session.currentState.error {
                    Text(error.localizedDescription).font(.subheadline).foregroundStyle(.secondary)
                        .accessibilityIdentifier("neteaseLoginError")
                }
                Button(action: startQR) {
                    SettingsActionLabel(
                        title: qrButtonTitle, icon: hasActiveQR ? "arrow.clockwise" : "qrcode.viewfinder",
                        busy: isGenerating, style: connected || hasActiveQR ? .secondary : .primary
                    )
                }
                .disabled(isGenerating || isCheckingAccount)
                .accessibilityIdentifier("neteaseAuthorize")
            }
            SettingsSection {
                Button { refreshAccount() } label: {
                    SettingsActionLabel(title: "重新检查状态", icon: "arrow.clockwise", busy: isCheckingAccount)
                }
                .disabled(isCheckingAccount || session.currentState.requesting)
                NavigationLink { NetEaseCookieImportView(session: session) } label: {
                    SettingsActionLabel(title: "高级登录方式", icon: "key", navigates: true)
                }
                .disabled(isStartingQR || isCheckingAccount)
                if connected {
                    Button(role: .destructive) {
                        model.disconnectNetEase()
                        requestedQR = false
                    } label: {
                        SettingsActionLabel(title: "退出网易云音乐", icon: "rectangle.portrait.and.arrow.right", style: .destructive)
                    }
                    .disabled(isStartingQR || isCheckingAccount)
                }
            }
            SettingsSection {
                MusicSourcePicker(model: model).settingsSurface()
                NetEaseQualityPicker(model: model)
            }
        }
        .buttonStyle(SettingsButtonStyle())
        .animation(reduceMotion ? nil : MusicProductMotion.change, value: hasActiveQR)
        .navigationTitle("登录到网易云音乐")
        .navigationBarTitleDisplayMode(.inline)
        .task { await session.refresh() }
        .task(id: session.qrURL) { makeQR() }
        .onDisappear {
            session.cancelQR()
            requestedQR = false
            clearQR()
        }
    }

    private var qrButtonTitle: LocalizedStringKey {
        if isGenerating { return "正在生成二维码" }
        if hasActiveQR || (requestedQR && session.qrStatus != "登录成功") { return "刷新二维码" }
        return connected ? "重新扫码登录" : "扫码登录"
    }

    private var qrCard: some View {
        VStack(spacing: 12) {
            if let qr, qr.source == session.qrURL {
                Image(uiImage: qr.image)
                    .interpolation(.none).resizable().scaledToFit().frame(maxWidth: 220)
                    .padding(12)
                    .background(.white, in: RoundedRectangle(cornerRadius: SettingsCorners.inset, style: .continuous))
                    .accessibilityLabel("网易云音乐登录二维码")
                Text("用网易云音乐 App 扫码确认").font(.subheadline.weight(.semibold))
                if let file = qr.file {
                    ShareLink(item: file) {
                        SettingsActionLabel(title: "保存或分享二维码", icon: "square.and.arrow.up")
                    }
                }
            } else {
                ProgressView()
            }
            Text(LocalizedStringKey(session.qrStatus))
                .font(.subheadline)
                .accessibilityIdentifier("neteaseQRStatus")
            if let expiry = session.qrExpires {
                Text("二维码有效至 \(expiry.formatted(date: .omitted, time: .standard))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .multilineTextAlignment(.center)
        .settingsSurface(radius: SettingsCorners.card)
    }

    private func startQR() {
        guard !isGenerating, !isCheckingAccount else { return }
        requestedQR = true
        isStartingQR = true
        Task {
            defer { isStartingQR = false }
            await session.beginQR()
        }
    }

    private func refreshAccount() {
        guard !isCheckingAccount, !session.currentState.requesting else { return }
        isCheckingAccount = true
        Task {
            defer { isCheckingAccount = false }
            await session.refresh()
        }
    }

    private func makeQR() {
        clearQR()
        guard let url = session.qrURL else { return }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.absoluteString.utf8)
        guard let ci = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cg = CIContext().createCGImage(ci, from: ci.extent) else { return }
        let image = UIImage(cgImage: cg)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("netease-qr-\(UUID().uuidString).png")
        if let png = image.pngData(), (try? png.write(to: file, options: .atomic)) != nil {
            qr = QRPresentation(source: url, image: image, file: file)
        } else {
            qr = QRPresentation(source: url, image: image, file: nil)
        }
    }

    private func clearQR() {
        if let file = qr?.file { try? FileManager.default.removeItem(at: file) }
        qr = nil
    }
}

private struct NetEaseCookieImportView: View {
    let session: NetEaseSession
    @State private var cookie = ""
    @State private var importing = false
    @State private var failure: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SettingsPage {
            SettingsSection("Cookie 登录") {
                SecureField("粘贴网易云 Cookie", text: $cookie)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .privacySensitive()
                    .settingsSurface()
                if !cookie.isEmpty {
                    Text("验证通过后才会替换已保存的登录。").font(.footnote).foregroundStyle(.secondary)
                }
                Button(action: importCookie) {
                    SettingsActionLabel(title: "验证并导入", icon: "key", busy: importing, style: .primary)
                }
                .disabled(importing || cookie.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .buttonStyle(SettingsButtonStyle())
        .navigationTitle("高级登录方式")
        .onDisappear { cookie = "" }
        .alert("登录未完成", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("common.ok", role: .cancel) { failure = nil }
        } message: {
            Text(failure ?? "")
        }
    }

    private func importCookie() {
        guard !importing else { return }
        importing = true
        let input = cookie
        Task {
            defer { importing = false; cookie = "" }
            do {
                try await session.importCookie(input)
                dismiss()
            } catch is CancellationError {
                return
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}
