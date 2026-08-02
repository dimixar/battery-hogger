import Foundation

@objc(BHWorkloadStatus)
enum WorkloadStatus: Int, Sendable {
    case normal
    case candidate
    case sustainedHog
}

@objc(BHWorkloadSnapshot)
final class WorkloadSnapshot: NSObject, NSSecureCoding, @unchecked Sendable {
    static var supportsSecureCoding: Bool { true }

    let identifier: String
    let displayName: String
    let bundleIdentifier: String?
    let status: WorkloadStatus
    let currentPowerWatts: Double
    let rollingAveragePowerWatts: Double
    let cumulativeEnergyWattHours: Double
    let monitoredSince: Date
    let processes: [ProcessSnapshot]

    init(
        identifier: String,
        displayName: String,
        bundleIdentifier: String?,
        status: WorkloadStatus,
        currentPowerWatts: Double,
        rollingAveragePowerWatts: Double,
        cumulativeEnergyWattHours: Double,
        monitoredSince: Date,
        processes: [ProcessSnapshot]
    ) {
        self.identifier = identifier
        self.displayName = displayName
        self.bundleIdentifier = bundleIdentifier
        self.status = status
        self.currentPowerWatts = currentPowerWatts
        self.rollingAveragePowerWatts = rollingAveragePowerWatts
        self.cumulativeEnergyWattHours = cumulativeEnergyWattHours
        self.monitoredSince = monitoredSince
        self.processes = processes
    }

    required init?(coder: NSCoder) {
        guard
            let identifier = coder.decodeObject(of: NSString.self, forKey: CodingKey.identifier) as String?,
            let displayName = coder.decodeObject(of: NSString.self, forKey: CodingKey.displayName) as String?,
            let monitoredSince = coder.decodeObject(of: NSDate.self, forKey: CodingKey.monitoredSince) as Date?,
            let processes = coder.decodeObject(
                of: [NSArray.self, ProcessSnapshot.self],
                forKey: CodingKey.processes
            ) as? [ProcessSnapshot]
        else {
            return nil
        }

        self.identifier = identifier
        self.displayName = displayName
        bundleIdentifier = coder.decodeObject(of: NSString.self, forKey: CodingKey.bundleIdentifier) as String?
        status = WorkloadStatus(rawValue: coder.decodeInteger(forKey: CodingKey.status)) ?? .normal
        currentPowerWatts = coder.decodeDouble(forKey: CodingKey.currentPowerWatts)
        rollingAveragePowerWatts = coder.decodeDouble(forKey: CodingKey.rollingAveragePowerWatts)
        cumulativeEnergyWattHours = coder.decodeDouble(forKey: CodingKey.cumulativeEnergyWattHours)
        self.monitoredSince = monitoredSince
        self.processes = processes
    }

    func encode(with coder: NSCoder) {
        coder.encode(identifier, forKey: CodingKey.identifier)
        coder.encode(displayName, forKey: CodingKey.displayName)
        coder.encode(bundleIdentifier, forKey: CodingKey.bundleIdentifier)
        coder.encode(status.rawValue, forKey: CodingKey.status)
        coder.encode(currentPowerWatts, forKey: CodingKey.currentPowerWatts)
        coder.encode(rollingAveragePowerWatts, forKey: CodingKey.rollingAveragePowerWatts)
        coder.encode(cumulativeEnergyWattHours, forKey: CodingKey.cumulativeEnergyWattHours)
        coder.encode(monitoredSince, forKey: CodingKey.monitoredSince)
        coder.encode(processes, forKey: CodingKey.processes)
    }

    private enum CodingKey {
        static let identifier = "identifier"
        static let displayName = "displayName"
        static let bundleIdentifier = "bundleIdentifier"
        static let status = "status"
        static let currentPowerWatts = "currentPowerWatts"
        static let rollingAveragePowerWatts = "rollingAveragePowerWatts"
        static let cumulativeEnergyWattHours = "cumulativeEnergyWattHours"
        static let monitoredSince = "monitoredSince"
        static let processes = "processes"
    }
}
