import Network
import Observation

@MainActor @Observable
final class ArtworkNetworkPolicy {
    static let shared = ArtworkNetworkPolicy()
    private(set) var connected = false
    private(set) var wifi = false
    private(set) var constrained = true
    @ObservationIgnored private let monitor = NWPathMonitor()

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let connected = path.status == .satisfied
            let wifi = path.usesInterfaceType(.wifi) && !path.isExpensive
            let constrained = path.isConstrained
            Task { @MainActor [weak self] in
                self?.connected = connected; self?.wifi = wifi; self?.constrained = constrained
            }
        }
        monitor.start(queue: DispatchQueue(label: "AMLL.artwork.network"))
    }

    deinit { monitor.cancel() }

    func permits(allowCellular: Bool) -> Bool {
        connected && !constrained && (wifi || allowCellular)
    }
}
