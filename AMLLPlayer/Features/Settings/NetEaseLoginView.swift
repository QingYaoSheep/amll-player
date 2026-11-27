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
                    qrCard
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
                } else if requestedQR, session.currentState.error == nil, !isGenerating, session.qrPhase != .authorized {
                    Text(LocalizedStringKey(session.qrStatus))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                }
                if let error = session.currentState.error {
                    Text(error.localizedDescription)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .accessibilityIdentifier("neteaseLoginError")
                }
                Button(action: startQR) {
                    SettingsActionLabel(
                        title: qrButtonTitle, icon: hasActiveQR ? "arrow.clockwise" : "qrcode.viewfinder",
                        busy: isGenerating, style: connected || hasActiveQR ? .secondary : .primary,
                        iconColor: MusicServiceID.netease.brandColor
                    )
                }
                .buttonStyle(SettingsButtonStyle())
                .disabled(isGenerating || isCheckingAccount)
                .accessibilityIdentifier("neteaseAuthorize")
            }
            SettingsSection {
                SettingsGroup {
                    Button { refreshAccount() } label: {
                        SettingsRowLabel(
                            title: "重新检查状态",
                            icon: "arrow.clockwise",
                            iconColor: MusicProductStyle.accent,
                            busy: isCheckingAccount
                        )
                    }
                    .buttonStyle(SettingsRowButtonStyle())
                    .disabled(isCheckingAccount || session.currentState.requesting)

                    SettingsDivider()

                    NavigationLink { NetEaseCookieImportView(session: session) } label: {
                        SettingsRowLabel(
                            title: "高级登录方式",
                            icon: "key",
                            iconColor: MusicProductStyle.accent,
                            navigates: true
                        )
                    }
                    .buttonStyle(SettingsRowButtonStyle())
                    .disabled(isStartingQR || isCheckingAccount)

                    if connected {
                        SettingsDivider()

                        Button(role: .destructive) {
                            model.disconnectNetEase()
                            requestedQR = false
                        } label: {
                            SettingsRowLabel(
                                title: "退出网易云音乐",
                                icon: "rectangle.portrait.and.arrow.right",
                                role: .destructive
                            )
                        }
                        .buttonStyle(SettingsRowButtonStyle())
                        .disabled(isStartingQR || isCheckingAccount)
                    }
                }
            }
            SettingsSection {
                SettingsGroup {
                    MusicSourcePicker(model: model)
                    SettingsDivider()
                    NetEaseQualityPicker(model: model)
                }
            }
        }
        .animation(reduceMotion ? nil : SettingsMotion.disclosure, value: hasActiveQR)
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
        if hasActiveQR || (requestedQR && session.qrPhase != .authorized) { return "刷新二维码" }
        return connected ? "重新扫码登录" : "扫码登录"
    }

    private var qrCard: some View {
        SettingsGroup(radius: SettingsCorners.hero) {
            VStack(spacing: 12) {
                if let qr, qr.source == session.qrURL {
                    Image(uiImage: qr.image)
                        .interpolation(.none).resizable().scaledToFit().frame(maxWidth: 210)
                        .padding(12)
                        .background(.white, in: RoundedRectangle(cornerRadius: SettingsCorners.inset, style: .continuous))
                        .accessibilityLabel("网易云音乐登录二维码")
                    Text("用网易云音乐 App 扫码确认")
                        .font(.subheadline.weight(.semibold))
                } else {
                    ProgressView()
                        .padding(.vertical, 40)
                }
                Text(LocalizedStringKey(session.qrStatus))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("neteaseQRStatus")
                if let expiry = session.qrExpires {
                    Text("二维码有效至 \(expiry.formatted(date: .omitted, time: .standard))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .multilineTextAlignment(.center)
            .padding(18)

            if let qr, qr.source == session.qrURL, let file = qr.file {
                SettingsDivider(inset: 16)
                ShareLink(item: file) {
                    SettingsRowLabel(
                        title: "保存或分享二维码",
                        icon: "square.and.arrow.up",
                        iconColor: MusicServiceID.netease.brandColor
                    )
                }
                .buttonStyle(SettingsRowButtonStyle())
            }
        }
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
            SettingsSection("Cookie 登录", footer: cookie.isEmpty ? nil : "验证通过后才会替换已保存的登录。") {
                SettingsGroup {
                    SecureField("粘贴网易云 Cookie", text: $cookie)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .privacySensitive()
                        .padding(.horizontal, 16)
                        .padding(.vertical, 13)
                }
            }
            Button(action: importCookie) {
                SettingsActionLabel(title: "验证并导入", icon: "key", busy: importing, style: .primary)
            }
            .buttonStyle(SettingsButtonStyle())
            .disabled(importing || cookie.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
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
