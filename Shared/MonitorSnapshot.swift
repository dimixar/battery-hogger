import Foundation

@objc(BHSystemPowerSnapshot)
final class SystemPowerSnapshot: NSObject, NSSecureCoding, @unchecked Sendable {
    static var supportsSecureCoding: Bool { true }

    let totalPowerWatts: Double
    let attributedCPUPowerWatts: Double
    let packageCPUPowerWatts: Double
    let residualCPUPowerWatts: Double
    let attributedGPUPowerWatts: Double
    let packageGPUPowerWatts: Double
    let residualGPUPowerWatts: Double
    let otherSoCPowerWatts: Double
    let isPackageCPUPowerAvailable: Bool
    let isPackageGPUPowerAvailable: Bool
    let isOtherSoCPowerAvailable: Bool
    let isGPUEnergyAvailable: Bool

    init(
        totalPowerWatts: Double,
        attributedCPUPowerWatts: Double,
        packageCPUPowerWatts: Double,
        residualCPUPowerWatts: Double,
        attributedGPUPowerWatts: Double,
        packageGPUPowerWatts: Double,
        residualGPUPowerWatts: Double,
        otherSoCPowerWatts: Double,
        isPackageCPUPowerAvailable: Bool,
        isPackageGPUPowerAvailable: Bool,
        isOtherSoCPowerAvailable: Bool,
        isGPUEnergyAvailable: Bool
    ) {
        self.totalPowerWatts = totalPowerWatts
        self.attributedCPUPowerWatts = attributedCPUPowerWatts
        self.packageCPUPowerWatts = packageCPUPowerWatts
        self.residualCPUPowerWatts = residualCPUPowerWatts
        self.attributedGPUPowerWatts = attributedGPUPowerWatts
        self.packageGPUPowerWatts = packageGPUPowerWatts
        self.residualGPUPowerWatts = residualGPUPowerWatts
        self.otherSoCPowerWatts = otherSoCPowerWatts
        self.isPackageCPUPowerAvailable = isPackageCPUPowerAvailable
        self.isPackageGPUPowerAvailable = isPackageGPUPowerAvailable
        self.isOtherSoCPowerAvailable = isOtherSoCPowerAvailable
        self.isGPUEnergyAvailable = isGPUEnergyAvailable
    }

    required init?(coder: NSCoder) {
        totalPowerWatts = coder.decodeDouble(forKey: "totalPowerWatts")
        attributedCPUPowerWatts = coder.decodeDouble(forKey: "attributedCPUPowerWatts")
        packageCPUPowerWatts = coder.decodeDouble(forKey: "packageCPUPowerWatts")
        residualCPUPowerWatts = coder.decodeDouble(forKey: "residualCPUPowerWatts")
        attributedGPUPowerWatts = coder.decodeDouble(forKey: "attributedGPUPowerWatts")
        packageGPUPowerWatts = coder.decodeDouble(forKey: "packageGPUPowerWatts")
        residualGPUPowerWatts = coder.decodeDouble(forKey: "residualGPUPowerWatts")
        otherSoCPowerWatts = coder.decodeDouble(forKey: "otherSoCPowerWatts")
        isPackageCPUPowerAvailable = coder.decodeBool(forKey: "isPackageCPUPowerAvailable")
        isPackageGPUPowerAvailable = coder.decodeBool(forKey: "isPackageGPUPowerAvailable")
        isOtherSoCPowerAvailable = coder.decodeBool(forKey: "isOtherSoCPowerAvailable")
        isGPUEnergyAvailable = coder.decodeBool(forKey: "isGPUEnergyAvailable")
    }

    func encode(with coder: NSCoder) {
        coder.encode(totalPowerWatts, forKey: "totalPowerWatts")
        coder.encode(attributedCPUPowerWatts, forKey: "attributedCPUPowerWatts")
        coder.encode(packageCPUPowerWatts, forKey: "packageCPUPowerWatts")
        coder.encode(residualCPUPowerWatts, forKey: "residualCPUPowerWatts")
        coder.encode(attributedGPUPowerWatts, forKey: "attributedGPUPowerWatts")
        coder.encode(packageGPUPowerWatts, forKey: "packageGPUPowerWatts")
        coder.encode(residualGPUPowerWatts, forKey: "residualGPUPowerWatts")
        coder.encode(otherSoCPowerWatts, forKey: "otherSoCPowerWatts")
        coder.encode(isPackageCPUPowerAvailable, forKey: "isPackageCPUPowerAvailable")
        coder.encode(isPackageGPUPowerAvailable, forKey: "isPackageGPUPowerAvailable")
        coder.encode(isOtherSoCPowerAvailable, forKey: "isOtherSoCPowerAvailable")
        coder.encode(isGPUEnergyAvailable, forKey: "isGPUEnergyAvailable")
    }
}

@objc(BHMonitorSnapshot)
final class MonitorSnapshot: NSObject, NSSecureCoding, @unchecked Sendable {
    static var supportsSecureCoding: Bool { true }

    let workloads: [WorkloadSnapshot]
    let systemPower: SystemPowerSnapshot

    init(workloads: [WorkloadSnapshot], systemPower: SystemPowerSnapshot) {
        self.workloads = workloads
        self.systemPower = systemPower
    }

    required init?(coder: NSCoder) {
        guard
            let workloads = coder.decodeObject(
                of: [NSArray.self, WorkloadSnapshot.self, ProcessSnapshot.self],
                forKey: "workloads"
            ) as? [WorkloadSnapshot],
            let systemPower = coder.decodeObject(
                of: SystemPowerSnapshot.self,
                forKey: "systemPower"
            )
        else {
            return nil
        }
        self.workloads = workloads
        self.systemPower = systemPower
    }

    func encode(with coder: NSCoder) {
        coder.encode(workloads, forKey: "workloads")
        coder.encode(systemPower, forKey: "systemPower")
    }
}
