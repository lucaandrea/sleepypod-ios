import Network

/// Route changes trigger a fresh read; path availability alone never proves Pod connectivity.
@MainActor final class ConnectionPathMonitor {
    private var monitor: NWPathMonitor?
    private var generation = 0
    private var previous: String?

    func start(onPermission: @escaping @MainActor (Bool) -> Void, onChange: @escaping @MainActor () -> Void) {
        stop()
        let operation = generation
        let monitor = NWPathMonitor()
        self.monitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            let fingerprint = "\(path.status)|\(path.availableInterfaces.filter { path.usesInterfaceType($0.type) }.map(\.name).sorted())"
            let available = path.status == .satisfied
            let denied = path.status == .unsatisfied && path.unsatisfiedReason == .localNetworkDenied
            Task { @MainActor in
                guard let self, self.generation == operation else { return }
                onPermission(denied)
                defer { self.previous = fingerprint }
                guard let previous = self.previous, previous != fingerprint, available else { return }
                onChange()
            }
        }
        monitor.start(queue: .global(qos: .utility))
    }
    func stop() {
        generation += 1; monitor?.cancel(); monitor = nil; previous = nil
    }
}
