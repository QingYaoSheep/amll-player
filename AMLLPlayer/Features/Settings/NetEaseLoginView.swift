import CoreImage.CIFilterBuiltins
import SwiftUI

struct NetEaseLoginView: View {
    @Bindable var model: AppModel
    @State private var failure: String?
    @State private var qrImage: UIImage?
    @State private var qrFile: URL?
    private var session: NetEaseSession { model.netEaseSession }
    var body: some View {
        Form {
            Section("网易云音乐") {
                if let p = session.profile {
                    HStack { CatalogArtwork(url: p.avatar); Text(p.name) }
                    LabeledContent("会员类型", value: p.vipType.map { $0 == 0 ? "普通账号" : "会员类型 \($0)" } ?? "未获取")
                    Text("可播放歌曲与音质以当前音源请求的实际权限为准。").font(.footnote).foregroundStyle(.secondary)
                }
                Label(model.netEaseState.connected ? "已连接" : "未连接", systemImage: "music.note")
                Button(model.netEaseState.connected ? "重新扫码登录" : "登录到网易云音乐") {
                    Task { await session.beginQR() }
                }.accessibilityIdentifier("neteaseAuthorize")
                if let qrImage {
                    Image(uiImage: qrImage).interpolation(.none).resizable().scaledToFit().frame(maxWidth: 240)
                    Text(session.qrStatus)
                    if let expiry = session.qrExpires { Text("二维码有效至 \(expiry.formatted(date: .omitted, time: .standard))").font(.caption) }
                    if let qrFile { ShareLink(item: qrFile) { Label("保存或分享二维码", systemImage: "square.and.arrow.up") } }
                    Button("刷新二维码") { Task { await session.beginQR() } }
                    Text("使用网易云音乐官方 App 扫码确认。同机识别可尝试保存二维码后从相册扫描；是否支持以官方 App 为准，也可用另一台设备显示二维码。")
                        .font(.footnote).foregroundStyle(.secondary)
                } else if session.currentState.requesting { ProgressView(session.qrStatus) }
                else { Text(session.qrStatus).foregroundStyle(.secondary) }
                if let error = session.currentState.error { Text(error.localizedDescription).foregroundStyle(.secondary) }
                Button("重新检查状态") { Task { await session.refresh() } }
                if session.currentState.connected { Button("退出网易云音乐", role: .destructive) { model.disconnectNetEase() } }
            }
            Section("当前音乐来源") { MusicSourcePicker(model: model) }
            Section("播放音质") {
                Picker("请求音质", selection: Binding(get: { model.netEasePlayback.quality }, set: { model.netEasePlayback.quality = $0 })) {
                    ForEach(NetEaseQuality.allCases) { q in Text(q.title).tag(q) }
                }
                Text("默认高品质；修改后从下一首生效。当前歌曲需重新起播才能更换。实际音质取决于账号权限和设备解码能力。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                NavigationLink("高级登录方式") { NetEaseCookieImportView(session: session) }
            }
        }
        .navigationTitle("登录到网易云音乐")
        .task { await session.refresh() }
        .task(id: session.qrURL) { makeQR() }
        .onDisappear { session.cancelQR(); clearQRFile() }
        .alert("登录未完成", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("好", role: .cancel) { failure = nil }
        } message: { Text(failure ?? "") }
    }
    private func makeQR() {
        qrImage = nil; clearQRFile()
        guard let url = session.qrURL else { return }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.absoluteString.utf8)
        guard let ci = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cg = CIContext().createCGImage(ci, from: ci.extent) else { return }
        let image = UIImage(cgImage: cg); qrImage = image
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("netease-qr-\(UUID().uuidString).png")
        if let png = image.pngData(), (try? png.write(to: file)) != nil { qrFile = file }
    }
    private func clearQRFile() { if let qrFile { try? FileManager.default.removeItem(at: qrFile) }; qrFile = nil }
}

private struct NetEaseCookieImportView: View {
    let session: NetEaseSession
    @State private var cookie = ""
    @State private var importing = false
    @State private var failure: String?
    var body: some View {
        Form {
            Section("高级：Cookie 导入") {
                SecureField("粘贴网易云 Cookie", text: $cookie).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("验证并导入") {
                    Task {
                        importing = true; defer { importing = false; cookie = "" }
                        do { try await session.importCookie(cookie) } catch is CancellationError {} catch { failure = error.localizedDescription }
                    }
                }.disabled(importing || cookie.isEmpty)
                Text("仅在你主动粘贴后验证，成功后保存在本机 Keychain；失败保留原有效登录。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }.navigationTitle("高级登录方式")
        .onDisappear { cookie = "" }
        .alert("登录未完成", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("好", role: .cancel) { failure = nil }
        } message: { Text(failure ?? "") }
    }
}
