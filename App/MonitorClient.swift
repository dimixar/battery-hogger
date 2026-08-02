import Foundation

enum MonitorClientError: LocalizedError {
    case unavailable
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "The privileged monitor is unavailable."
        case .invalidResponse:
            "The privileged monitor returned an invalid response."
        }
    }
}

final class MonitorClient: @unchecked Sendable {
    private let lock = NSLock()
    private var storedConnection: NSXPCConnection?

    func fetchWorkloadSnapshot() async throws -> [WorkloadSnapshot] {
        let connection = connection()

        return try await withCheckedThrowingContinuation { continuation in
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                continuation.resume(throwing: error)
            }

            guard let monitor = proxy as? MonitorXPCProtocol else {
                continuation.resume(throwing: MonitorClientError.unavailable)
                return
            }

            monitor.fetchWorkloadSnapshot { snapshots, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let snapshots {
                    continuation.resume(returning: snapshots)
                } else {
                    continuation.resume(throwing: MonitorClientError.invalidResponse)
                }
            }
        }
    }

    func invalidate() {
        lock.withLock {
            storedConnection?.invalidate()
            storedConnection = nil
        }
    }

    private func connection() -> NSXPCConnection {
        lock.withLock {
            if let storedConnection {
                return storedConnection
            }

            let connection = NSXPCConnection(
                machServiceName: MonitorConstants.daemonLabel,
                options: .privileged
            )
            connection.remoteObjectInterface = MonitorXPCInterface.make()
            connection.setCodeSigningRequirement(MonitorConstants.daemonCodeSigningRequirement)
            connection.invalidationHandler = { [weak self, weak connection] in
                guard let self else { return }
                self.lock.withLock {
                    if self.storedConnection === connection {
                        self.storedConnection = nil
                    }
                }
            }
            connection.activate()
            storedConnection = connection
            return connection
        }
    }
}
