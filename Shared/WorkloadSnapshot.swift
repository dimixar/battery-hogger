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
    let currentCPUPowerWatts: Double
    let currentGPUPowerWatts: Double
    let rollingMedianPowerWatts: Double
    let rollingMedianCPUPowerWatts: Double
    let rollingMedianGPUPowerWatts: Double
    let cumulativeEnergyWattHours: Double
    let cumulativeCPUEnergyWattHours: Double
    let cumulativeGPUEnergyWattHours: Double
    let isGPUEnergyAvailable: Bool
    let monitoredSince: Date
    let processes: [ProcessSnapshot]

    init(
        identifier: String,
        displayName: String,
        bundleIdentifier: String?,
        status: WorkloadStatus,
        currentPowerWatts: Double,
        currentCPUPowerWatts: Double,
        currentGPUPowerWatts: Double,
        rollingMedianPowerWatts: Double,
        rollingMedianCPUPowerWatts: Double,
        rollingMedianGPUPowerWatts: Double,
        cumulativeEnergyWattHours: Double,
        cumulativeCPUEnergyWattHours: Double,
        cumulativeGPUEnergyWattHours: Double,
        isGPUEnergyAvailable: Bool,
        monitoredSince: Date,
        processes: [ProcessSnapshot]
    ) {
        self.identifier = identifier
        self.displayName = displayName
        self.bundleIdentifier = bundleIdentifier
        self.status = status
        self.currentPowerWatts = currentPowerWatts
        self.currentCPUPowerWatts = currentCPUPowerWatts
        self.currentGPUPowerWatts = currentGPUPowerWatts
        self.rollingMedianPowerWatts = rollingMedianPowerWatts
        self.rollingMedianCPUPowerWatts = rollingMedianCPUPowerWatts
        self.rollingMedianGPUPowerWatts = rollingMedianGPUPowerWatts
        self.cumulativeEnergyWattHours = cumulativeEnergyWattHours
        self.cumulativeCPUEnergyWattHours = cumulativeCPUEnergyWattHours
        self.cumulativeGPUEnergyWattHours = cumulativeGPUEnergyWattHours
        self.isGPUEnergyAvailable = isGPUEnergyAvailable
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
        currentCPUPowerWatts = coder.decodeDouble(forKey: CodingKey.currentCPUPowerWatts)
        currentGPUPowerWatts = coder.decodeDouble(forKey: CodingKey.currentGPUPowerWatts)
        rollingMedianPowerWatts = coder.decodeDouble(forKey: CodingKey.rollingMedianPowerWatts)
        rollingMedianCPUPowerWatts = coder.decodeDouble(
            forKey: CodingKey.rollingMedianCPUPowerWatts
        )
        rollingMedianGPUPowerWatts = coder.decodeDouble(
            forKey: CodingKey.rollingMedianGPUPowerWatts
        )
        cumulativeEnergyWattHours = coder.decodeDouble(forKey: CodingKey.cumulativeEnergyWattHours)
        cumulativeCPUEnergyWattHours = coder.decodeDouble(
            forKey: CodingKey.cumulativeCPUEnergyWattHours
        )
        cumulativeGPUEnergyWattHours = coder.decodeDouble(
            forKey: CodingKey.cumulativeGPUEnergyWattHours
        )
        isGPUEnergyAvailable = coder.decodeBool(forKey: CodingKey.isGPUEnergyAvailable)
        self.monitoredSince = monitoredSince
        self.processes = processes
    }

    func encode(with coder: NSCoder) {
        coder.encode(identifier, forKey: CodingKey.identifier)
        coder.encode(displayName, forKey: CodingKey.displayName)
        coder.encode(bundleIdentifier, forKey: CodingKey.bundleIdentifier)
        coder.encode(status.rawValue, forKey: CodingKey.status)
        coder.encode(currentPowerWatts, forKey: CodingKey.currentPowerWatts)
        coder.encode(currentCPUPowerWatts, forKey: CodingKey.currentCPUPowerWatts)
        coder.encode(currentGPUPowerWatts, forKey: CodingKey.currentGPUPowerWatts)
        coder.encode(rollingMedianPowerWatts, forKey: CodingKey.rollingMedianPowerWatts)
        coder.encode(
            rollingMedianCPUPowerWatts,
            forKey: CodingKey.rollingMedianCPUPowerWatts
        )
        coder.encode(
            rollingMedianGPUPowerWatts,
            forKey: CodingKey.rollingMedianGPUPowerWatts
        )
        coder.encode(cumulativeEnergyWattHours, forKey: CodingKey.cumulativeEnergyWattHours)
        coder.encode(cumulativeCPUEnergyWattHours, forKey: CodingKey.cumulativeCPUEnergyWattHours)
        coder.encode(cumulativeGPUEnergyWattHours, forKey: CodingKey.cumulativeGPUEnergyWattHours)
        coder.encode(isGPUEnergyAvailable, forKey: CodingKey.isGPUEnergyAvailable)
        coder.encode(monitoredSince, forKey: CodingKey.monitoredSince)
        coder.encode(processes, forKey: CodingKey.processes)
    }

    private enum CodingKey {
        static let identifier = "identifier"
        static let displayName = "displayName"
        static let bundleIdentifier = "bundleIdentifier"
        static let status = "status"
        static let currentPowerWatts = "currentPowerWatts"
        static let currentCPUPowerWatts = "currentCPUPowerWatts"
        static let currentGPUPowerWatts = "currentGPUPowerWatts"
        static let rollingMedianPowerWatts = "rollingMedianPowerWatts"
        static let rollingMedianCPUPowerWatts = "rollingMedianCPUPowerWatts"
        static let rollingMedianGPUPowerWatts = "rollingMedianGPUPowerWatts"
        static let cumulativeEnergyWattHours = "cumulativeEnergyWattHours"
        static let cumulativeCPUEnergyWattHours = "cumulativeCPUEnergyWattHours"
        static let cumulativeGPUEnergyWattHours = "cumulativeGPUEnergyWattHours"
        static let isGPUEnergyAvailable = "isGPUEnergyAvailable"
        static let monitoredSince = "monitoredSince"
        static let processes = "processes"
    }
}
