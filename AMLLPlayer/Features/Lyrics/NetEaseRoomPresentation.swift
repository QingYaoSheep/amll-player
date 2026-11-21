import SwiftUI
import UIKit
import UserNotifications

@MainActor final class NetEaseRoomNotificationDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate, ObservableObject {
    struct Response: Equatable {
        let id = UUID()
        let destination: NetEaseRoomDestination
    }

    @Published private(set) var response: Response?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let destination = NetEaseRoomDestination(response.notification.request.content.userInfo) else { return }
        await MainActor.run { self.response = Response(destination: destination) }
    }
}

/// One banner surface per scene, above player and chat presentations. The
/// window never becomes key and only the banner's bounds accept touches.
@MainActor final class NetEaseRoomOverlay {
    private final class BannerWindow: UIWindow {
        var bannerFrame = CGRect.null

        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
            guard bannerFrame.contains(point) else { return nil }
            return super.hitTest(point, with: event)
        }
    }

    fileprivate weak var anchor: UIView?
    private var window: BannerWindow?
    private var routeTask: Task<Void, Never>?

    fileprivate func attach(to anchor: UIView, model: AppModel) {
        guard let scene = anchor.window?.windowScene else { return }
        self.anchor = anchor
        guard window?.windowScene !== scene else { return }
        let window = BannerWindow(windowScene: scene)
        let banner = NetEaseRoomBanner(activity: model.netEasePlayback.roomActivity) { [weak window] frame in
            window?.bannerFrame = frame
        } open: { [weak self] destination in self?.open(destination, model: model) }
        let host = UIHostingController(rootView: banner)
        host.view.backgroundColor = .clear
        window.rootViewController = host
        window.backgroundColor = .clear
        window.windowLevel = .normal + 1
        window.isHidden = false
        self.window = window
    }

    fileprivate func detach(from anchor: UIView) {
        guard self.anchor === anchor else { return }
        self.anchor = nil
        window?.isHidden = true
        window = nil
        routeTask?.cancel()
    }

    func open(_ destination: NetEaseRoomDestination, model: AppModel) {
        routeTask?.cancel()
        routeTask = Task { [weak self] in
            // A notification can launch the app before the persisted room recovers.
            for _ in 0..<50 {
                guard !Task.isCancelled, let self else { return }
                if self.present(destination, model: model) { return }
                do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            }
        }
    }

    private func present(_ destination: NetEaseRoomDestination, model: AppModel) -> Bool {
        guard UIApplication.shared.applicationState == .active,
              let root = anchor?.window?.rootViewController else { return false }
        if let account = model.netEaseSession.profile?.id, account != destination.account { return true }
        guard model.selectedMusicService == .netease,
              model.netEaseSession.profile?.id == destination.account,
              let room = model.netEasePlayback.listeningRoom else { return false }
        guard room.id == destination.roomID, room.kind == destination.kind else { return true }
        if let peer = destination.peer, model.netEasePlayback.duetChatPeer?.id != peer { return true }
        var presenter = root
        while let presented = presenter.presentedViewController { presenter = presented }
        guard !presenter.isBeingDismissed, !presenter.isBeingPresented, presenter.viewIfLoaded?.window != nil else {
            return false
        }
        let host = UIHostingController(rootView: NetEaseRoomView(model: model, opensChat: destination.chat) { [weak presenter] in
            presenter?.dismiss(animated: true)
        })
        host.modalPresentationStyle = .pageSheet
        presenter.present(host, animated: true)
        return true
    }
}

struct NetEaseRoomOverlayAnchor: UIViewRepresentable {
    let overlay: NetEaseRoomOverlay
    let model: AppModel

    final class Anchor: UIView {
        var overlay: NetEaseRoomOverlay?
        weak var model: AppModel?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil, let model { overlay?.attach(to: self, model: model) }
            else { overlay?.detach(from: self) }
        }
    }

    func makeUIView(context: Context) -> Anchor {
        let anchor = Anchor()
        anchor.isUserInteractionEnabled = false
        anchor.overlay = overlay
        anchor.model = model
        return anchor
    }

    func updateUIView(_ view: Anchor, context: Context) {}
}

private struct NetEaseRoomBanner: View {
    let activity: NetEaseRoomActivity
    let frameChanged: (CGRect) -> Void
    let open: (NetEaseRoomDestination) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            if let event = activity.banner {
                Button {
                    activity.advanceBanner()
                    if let destination = event.destination { open(destination) }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: event.symbol).foregroundStyle(MusicProductStyle.accent)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(event.text).font(.subheadline.weight(.semibold))
                            if let preview = event.preview {
                                Text(verbatim: preview).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                        Spacer(minLength: 0)
                        Image(systemName: event.destination == nil ? "xmark" : "chevron.right")
                            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 10).frame(minHeight: 48)
                    .multilineTextAlignment(.leading)
                    .foregroundStyle(.primary)
                    .modifier(NetEaseRoomGlass(shape: RoundedRectangle(cornerRadius: 23)))
                    .contentShape(RoundedRectangle(cornerRadius: 23))
                }
                .buttonStyle(MusicContentButtonStyle())
                .frame(maxWidth: 520)
                .accessibilityIdentifier("netEaseRoomBanner")
                .accessibilityHint(event.destination?.chat == true ? "打开聊天" : "打开房间详情")
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frameChanged($0) }
                .transition(reduceMotion ? .opacity : .offset(y: -8).combined(with: .opacity))
                .task(id: event.id) {
                    if UIAccessibility.isVoiceOverRunning {
                        UIAccessibility.post(notification: .announcement, argument: event.text)
                    }
                    let wait = UIAccessibility.isVoiceOverRunning ? 8 : 4
                    do { try await Task.sleep(for: .seconds(wait)) } catch { return }
                    if activity.banner?.id == event.id { activity.advanceBanner() }
                }
            }
        }
        .padding(.horizontal, 16).padding(.top, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(MusicProductMotion.change, value: activity.banner?.id)
        .onChange(of: activity.banner?.id) { if activity.banner == nil { frameChanged(.null) } }
    }
}

struct NetEaseRoomGlass<Surface: Shape>: ViewModifier {
    let shape: Surface
    var interactive = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        if reduceTransparency || contrast == .increased {
            content.background(Color(uiColor: .secondarySystemBackground), in: shape)
        } else if #available(iOS 26, *) {
            content.glassEffect(.regular.interactive(interactive && !reduceMotion), in: shape)
        } else {
            content.background(.regularMaterial, in: shape)
        }
    }
}

struct NetEaseRoomDurationLabel: View {
    let seconds: Int

    var body: some View {
        let minutes = seconds / 60
        if minutes == 0 { Text("一起听不到 1 分钟") }
        else if minutes < 60 { Text("一起听了 \(minutes) 分钟") }
        else { Text("一起听了 \(minutes / 60) 小时 \(minutes % 60) 分钟") }
    }
}

struct NetEaseRoomCapsule: View {
    let room: NetEaseListeningRoom
    let seconds: Int
    let action: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                avatars.fixedSize(horizontal: true, vertical: false)
                ScrollView(.horizontal) { avatars }.scrollIndicators(.hidden)
            }
            .frame(maxWidth: room.kind == .duet ? 72 : 132)
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
            .accessibilityHidden(true)
            Button(action: action) {
                HStack(spacing: 8) {
                    Group {
                        if room.members.count < 2 { Text("等待好友加入") }
                        else { NetEaseRoomDurationLabel(seconds: seconds) }
                    }
                    .font(.caption.weight(.semibold))
                    .lineLimit(2)
                    Image(systemName: "chevron.right").font(.caption2.weight(.semibold))
                        .accessibilityHidden(true)
                }
                .padding(.leading, room.members.isEmpty ? 0 : 8)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(MusicContentButtonStyle())
            .accessibilityIdentifier("netEaseLyricsRoomCapsule")
            .accessibilityHint("打开房间详情")
            .accessibilityValue(room.members.map(\.name).joined(separator: "、"))
        }
        .padding(.horizontal, 12)
        .modifier(NetEaseRoomGlass(shape: Capsule(), interactive: true))
        .contentShape(Capsule())
        .frame(maxWidth: 420)
        .padding(.horizontal, 16)
    }

    private var avatars: some View {
        HStack(spacing: -5) {
            ForEach(room.members) { member in
                CatalogArtwork(url: member.avatar, size: 24, isArtist: true)
                    .overlay { Circle().strokeBorder(.white.opacity(0.35), lineWidth: 1) }
            }
        }
    }
}
