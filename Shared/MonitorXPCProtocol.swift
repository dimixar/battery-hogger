import Foundation

@objc(BHMonitorXPCProtocol)
protocol MonitorXPCProtocol {
    func ping(withReply reply: @escaping (String) -> Void)
    func fetchWorkloadSnapshot(
        withReply reply: @escaping ([WorkloadSnapshot]?, NSError?) -> Void
    )
}

enum MonitorXPCInterface {
    static func make() -> NSXPCInterface {
        let interface = NSXPCInterface(with: MonitorXPCProtocol.self)
        // Foundation imports the Objective-C `NSSet<Class>` parameter as
        // `Set<AnyHashable>`, so bridge through NSSet to preserve class objects.
        let snapshotClasses = NSSet(
            array: [NSArray.self, WorkloadSnapshot.self, ProcessSnapshot.self]
        ) as! Set<AnyHashable>
        interface.setClasses(
            snapshotClasses,
            for: #selector(MonitorXPCProtocol.fetchWorkloadSnapshot(withReply:)),
            argumentIndex: 0,
            ofReply: true
        )
        return interface
    }
}
