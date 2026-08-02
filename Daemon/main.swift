import Foundation
import os

let logger = Logger(
    subsystem: MonitorConstants.daemonBundleIdentifier,
    category: "lifecycle"
)
let service = MonitorService(engine: MonitorEngine())
let delegate = MonitorListenerDelegate(service: service)
let listener = NSXPCListener(machServiceName: MonitorConstants.daemonLabel)

listener.delegate = delegate
listener.setConnectionCodeSigningRequirement(MonitorConstants.appCodeSigningRequirement)
listener.activate()

logger.notice("Battery Hogger privileged monitor started")
dispatchMain()
