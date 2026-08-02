import Foundation
import os

final class MonitorService: NSObject, MonitorXPCProtocol {
    private let sampler: ProcessSampler
    private let logger = Logger(
        subsystem: MonitorConstants.daemonBundleIdentifier,
        category: "monitor"
    )

    init(sampler: ProcessSampler) {
        self.sampler = sampler
    }

    func ping(withReply reply: @escaping (String) -> Void) {
        reply("Battery Hogger monitor is running as uid \(geteuid())")
    }

    func fetchProcessSnapshot(
        withReply reply: @escaping ([ProcessSnapshot]?, NSError?) -> Void
    ) {
        let snapshots = sampler.sample()
        logger.debug("Returning \(snapshots.count) process samples")
        reply(snapshots, nil)
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
