import AppKit
import Network

/// The two hints that a tab on a host may have its connection back: the
/// Mac woke from sleep, or a network path became usable (a change of
/// network counts: the path is reported again). Started only once a host
/// is enabled; nothing is watched with none.
@MainActor
final class ConnectivityWatcher {
    private let onChange: @MainActor () -> Void
    private var monitor: NWPathMonitor?
    private var wakeObserver: NSObjectProtocol?
    /// The monitor's first update describes the path as it is, not a change.
    private var pathReported = false

    init(onChange: @escaping @MainActor () -> Void) { self.onChange = onChange }

    var isStarted: Bool { monitor != nil }

    func start() {
        guard monitor == nil else { return }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.onChange() }
        }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let usable = path.status == .satisfied
            Task { @MainActor in self?.pathChanged(usable: usable) }
        }
        monitor.start(queue: .main)
        self.monitor = monitor
    }

    func stop() {
        monitor?.cancel()
        monitor = nil
        pathReported = false
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
    }

    private func pathChanged(usable: Bool) {
        defer { pathReported = true }
        guard pathReported, usable else { return }
        onChange()
    }
}
