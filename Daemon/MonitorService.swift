import Foundation
import os

final class MonitorService: NSObject, MonitorXPCProtocol {
    private let engine: MonitorEngine
    private let logger = Logger(
        subsystem: MonitorConstants.daemonBundleIdentifier,
        category: "monitor"
    )

    init(engine: MonitorEngine) {
        self.engine = engine
    }

    func ping(withReply reply: @escaping (String) -> Void) {
        reply("Battery Hogger monitor is running as uid \(geteuid())")
    }

    func fetchMonitorSnapshot(
        withReply reply: @escaping (MonitorSnapshot?, NSError?) -> Void
    ) {
        let snapshot = engine.snapshot()
        logger.debug("Returning \(snapshot.workloads.count) workload samples")
        reply(snapshot, nil)
    }
}

final class MonitorListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let service: MonitorService

    init(service: MonitorService) {
        self.service = service
    }

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        connection.exportedInterface = MonitorXPCInterface.make()
        connection.exportedObject = service
        connection.activate()
        return true
    }
}
