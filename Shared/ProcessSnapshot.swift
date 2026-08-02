import Foundation

@objc(BHProcessSnapshot)
final class ProcessSnapshot: NSObject, NSSecureCoding, @unchecked Sendable {
    static var supportsSecureCoding: Bool { true }

    let processIdentifier: Int32
    let parentProcessIdentifier: Int32
    let userIdentifier: UInt32
    let name: String
    let executablePath: String?
    let launchDate: Date
    let resourceCoalitionIdentifier: UInt64
    let cpuPowerWatts: Double
    let cpuPercentage: Double
    let interruptWakeupsPerSecond: Double
    let diskReadBytesPerSecond: Double
    let diskWriteBytesPerSecond: Double
    let sampleDuration: TimeInterval
    let cumulativeEnergyWattHours: Double
    let isWorkloadRoot: Bool

    init(
        processIdentifier: Int32,
        parentProcessIdentifier: Int32,
        userIdentifier: UInt32,
        name: String,
        executablePath: String?,
        launchDate: Date,
        resourceCoalitionIdentifier: UInt64,
        cpuPowerWatts: Double,
        cpuPercentage: Double,
        interruptWakeupsPerSecond: Double,
        diskReadBytesPerSecond: Double,
        diskWriteBytesPerSecond: Double,
        sampleDuration: TimeInterval,
        cumulativeEnergyWattHours: Double,
        isWorkloadRoot: Bool
    ) {
        self.processIdentifier = processIdentifier
        self.parentProcessIdentifier = parentProcessIdentifier
        self.userIdentifier = userIdentifier
        self.name = name
        self.executablePath = executablePath
        self.launchDate = launchDate
        self.resourceCoalitionIdentifier = resourceCoalitionIdentifier
        self.cpuPowerWatts = cpuPowerWatts
        self.cpuPercentage = cpuPercentage
        self.interruptWakeupsPerSecond = interruptWakeupsPerSecond
        self.diskReadBytesPerSecond = diskReadBytesPerSecond
        self.diskWriteBytesPerSecond = diskWriteBytesPerSecond
        self.sampleDuration = sampleDuration
        self.cumulativeEnergyWattHours = cumulativeEnergyWattHours
        self.isWorkloadRoot = isWorkloadRoot
    }

    required init?(coder: NSCoder) {
        guard
            let name = coder.decodeObject(of: NSString.self, forKey: CodingKey.name) as String?,
            let launchDate = coder.decodeObject(of: NSDate.self, forKey: CodingKey.launchDate) as Date?
        else {
            return nil
        }

        processIdentifier = coder.decodeInt32(forKey: CodingKey.processIdentifier)
        parentProcessIdentifier = coder.decodeInt32(forKey: CodingKey.parentProcessIdentifier)
        userIdentifier = UInt32(bitPattern: coder.decodeInt32(forKey: CodingKey.userIdentifier))
        self.name = name
        executablePath = coder.decodeObject(of: NSString.self, forKey: CodingKey.executablePath) as String?
        self.launchDate = launchDate
        resourceCoalitionIdentifier = UInt64(
            bitPattern: coder.decodeInt64(forKey: CodingKey.resourceCoalitionIdentifier)
        )
        cpuPowerWatts = coder.decodeDouble(forKey: CodingKey.cpuPowerWatts)
        cpuPercentage = coder.decodeDouble(forKey: CodingKey.cpuPercentage)
        interruptWakeupsPerSecond = coder.decodeDouble(forKey: CodingKey.interruptWakeupsPerSecond)
        diskReadBytesPerSecond = coder.decodeDouble(forKey: CodingKey.diskReadBytesPerSecond)
        diskWriteBytesPerSecond = coder.decodeDouble(forKey: CodingKey.diskWriteBytesPerSecond)
        sampleDuration = coder.decodeDouble(forKey: CodingKey.sampleDuration)
        cumulativeEnergyWattHours = coder.decodeDouble(forKey: CodingKey.cumulativeEnergyWattHours)
        isWorkloadRoot = coder.decodeBool(forKey: CodingKey.isWorkloadRoot)
    }

    func encode(with coder: NSCoder) {
        coder.encode(processIdentifier, forKey: CodingKey.processIdentifier)
        coder.encode(parentProcessIdentifier, forKey: CodingKey.parentProcessIdentifier)
        coder.encode(Int32(bitPattern: userIdentifier), forKey: CodingKey.userIdentifier)
        coder.encode(name, forKey: CodingKey.name)
        coder.encode(executablePath, forKey: CodingKey.executablePath)
        coder.encode(launchDate, forKey: CodingKey.launchDate)
        coder.encode(
            Int64(bitPattern: resourceCoalitionIdentifier),
            forKey: CodingKey.resourceCoalitionIdentifier
        )
        coder.encode(cpuPowerWatts, forKey: CodingKey.cpuPowerWatts)
        coder.encode(cpuPercentage, forKey: CodingKey.cpuPercentage)
        coder.encode(interruptWakeupsPerSecond, forKey: CodingKey.interruptWakeupsPerSecond)
        coder.encode(diskReadBytesPerSecond, forKey: CodingKey.diskReadBytesPerSecond)
        coder.encode(diskWriteBytesPerSecond, forKey: CodingKey.diskWriteBytesPerSecond)
        coder.encode(sampleDuration, forKey: CodingKey.sampleDuration)
        coder.encode(cumulativeEnergyWattHours, forKey: CodingKey.cumulativeEnergyWattHours)
        coder.encode(isWorkloadRoot, forKey: CodingKey.isWorkloadRoot)
    }

    private enum CodingKey {
        static let processIdentifier = "processIdentifier"
        static let parentProcessIdentifier = "parentProcessIdentifier"
        static let userIdentifier = "userIdentifier"
        static let name = "name"
        static let executablePath = "executablePath"
        static let launchDate = "launchDate"
        static let resourceCoalitionIdentifier = "resourceCoalitionIdentifier"
        static let cpuPowerWatts = "cpuPowerWatts"
        static let cpuPercentage = "cpuPercentage"
        static let interruptWakeupsPerSecond = "interruptWakeupsPerSecond"
        static let diskReadBytesPerSecond = "diskReadBytesPerSecond"
        static let diskWriteBytesPerSecond = "diskWriteBytesPerSecond"
        static let sampleDuration = "sampleDuration"
        static let cumulativeEnergyWattHours = "cumulativeEnergyWattHours"
        static let isWorkloadRoot = "isWorkloadRoot"
    }
}
