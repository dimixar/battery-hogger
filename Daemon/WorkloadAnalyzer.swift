import Foundation

final class WorkloadAnalyzer {
    private struct BundleAssociation {
        let key: String
        let displayName: String
        let bundleIdentifier: String?
        let mainExecutablePath: String?
    }

    private struct Descriptor {
        let key: String
        let displayName: String
        let bundleIdentifier: String?
        let mainExecutablePath: String?
    }

    private final class SessionState {
        let monitoredSince: Date
        var cumulativeCPUEnergyNanojoules: UInt64 = 0
        var cumulativeGPUEnergyNanojoules: UInt64 = 0
        var hasGPUEnergyMeasurement = false
        var detector = WorkloadDetector()

        init(monitoredSince: Date) {
            self.monitoredSince = monitoredSince
        }
    }

    private static let nanojoulesPerWattHour = 3_600_000_000_000.0
    private static let infrastructureProcessNames: Set<String> = [
        "launchd",
        "xpcproxy",
        "loginwindow"
    ]

    private var sessions: [String: SessionState] = [:]
    private var bundleCache: [String: BundleAssociation] = [:]

    func analyze(_ batch: ProcessSampleBatch) -> [WorkloadSnapshot] {
        let measurementsByPID = Dictionary(
            uniqueKeysWithValues: batch.measurements.map { ($0.identity.pid, $0) }
        )
        var directAssociations: [ProcessIdentity: BundleAssociation] = [:]
        for measurement in batch.measurements {
            if let path = measurement.executablePath,
               let association = bundleAssociation(forExecutablePath: path) {
                directAssociations[measurement.identity] = association
            }
        }

        var resolvedAssociations: [ProcessIdentity: BundleAssociation] = [:]
        var groups: [String: [ProcessMeasurement]] = [:]
        var descriptors: [String: Descriptor] = [:]

        for measurement in batch.measurements {
            let association = resolveAssociation(
                for: measurement,
                measurementsByPID: measurementsByPID,
                directAssociations: directAssociations,
                resolvedAssociations: &resolvedAssociations,
                visited: []
            )

            let descriptor: Descriptor
            if let association {
                descriptor = Descriptor(
                    key: association.key,
                    displayName: association.displayName,
                    bundleIdentifier: association.bundleIdentifier,
                    mainExecutablePath: association.mainExecutablePath
                )
            } else {
                descriptor = Descriptor(
                    key: measurement.resourceCoalitionID.map {
                        "coalition:\($0)"
                    } ?? standaloneKey(for: measurement.identity),
                    displayName: measurement.name,
                    bundleIdentifier: nil,
                    mainExecutablePath: measurement.executablePath
                )
            }

            guard descriptor.bundleIdentifier != MonitorConstants.appBundleIdentifier else {
                continue
            }
            groups[descriptor.key, default: []].append(measurement)
            descriptors[descriptor.key] = descriptor
        }

        let gpuMeasurementsByCoalition = Dictionary(
            uniqueKeysWithValues: batch.coalitionGPUMeasurements.map {
                ($0.coalitionID, $0)
            }
        )
        let gpuCoalitionOwners = gpuCoalitionOwners(
            groups: groups,
            descriptors: descriptors
        )
        var gpuMeasurementsByGroup: [String: [CoalitionGPUMeasurement]] = [:]
        for (coalitionID, groupKey) in gpuCoalitionOwners {
            if let measurement = gpuMeasurementsByCoalition[coalitionID] {
                gpuMeasurementsByGroup[groupKey, default: []].append(measurement)
            }
        }

        var snapshots: [WorkloadSnapshot] = []
        snapshots.reserveCapacity(groups.count)
        let activeKeys = Set(groups.keys)

        for (key, measurements) in groups {
            guard var descriptor = descriptors[key] else { continue }
            if descriptor.bundleIdentifier == nil,
               let rootIdentity = workloadRoot(in: measurements, mainExecutablePath: nil),
               let root = measurements.first(where: { $0.identity == rootIdentity }) {
                descriptor = Descriptor(
                    key: key,
                    displayName: root.name,
                    bundleIdentifier: nil,
                    mainExecutablePath: root.executablePath
                )
            }
            let state = sessions[key] ?? SessionState(monitoredSince: batch.sampledAtDate)
            sessions[key] = state

            let cpuIntervalEnergy = measurements.reduce(UInt64(0)) {
                $0 &+ $1.energyDeltaNanojoules
            }
            let gpuMeasurements = gpuMeasurementsByGroup[key] ?? []
            state.hasGPUEnergyMeasurement = state.hasGPUEnergyMeasurement
                || !gpuMeasurements.isEmpty
            let gpuIntervalEnergy = gpuMeasurements.reduce(UInt64(0)) {
                $0 &+ $1.energyDeltaNanojoules
            }
            state.cumulativeCPUEnergyNanojoules &+= cpuIntervalEnergy
            state.cumulativeGPUEnergyNanojoules &+= gpuIntervalEnergy

            let currentCPUPower = measurements.reduce(0) { $0 + $1.cpuPowerWatts }
            let currentGPUPower = gpuMeasurements.reduce(0) { $0 + $1.gpuPowerWatts }
            let currentPower = currentCPUPower + currentGPUPower
            let sampleDuration = max(
                measurements.map(\ProcessMeasurement.sampleDuration).max() ?? 0,
                gpuMeasurements.map(\CoalitionGPUMeasurement.sampleDuration).max() ?? 0
            )
            let detection = state.detector.record(
                cpuPowerWatts: currentCPUPower,
                gpuPowerWatts: currentGPUPower,
                duration: sampleDuration,
                at: batch.sampledAtNanoseconds
            )
            let rootIdentity = workloadRoot(
                in: measurements,
                mainExecutablePath: descriptor.mainExecutablePath
            )
            let processSnapshots = measurements
                .map { processSnapshot(from: $0, rootIdentity: rootIdentity) }
                .sorted {
                    if $0.isWorkloadRoot != $1.isWorkloadRoot {
                        return $0.isWorkloadRoot
                    }
                    return $0.cpuPowerWatts > $1.cpuPowerWatts
                }

            snapshots.append(
                WorkloadSnapshot(
                    identifier: key,
                    displayName: descriptor.displayName,
                    bundleIdentifier: descriptor.bundleIdentifier,
                    status: detection.status,
                    currentPowerWatts: currentPower,
                    currentCPUPowerWatts: currentCPUPower,
                    currentGPUPowerWatts: currentGPUPower,
                    rollingAveragePowerWatts: detection.rollingAveragePowerWatts,
                    rollingAverageCPUPowerWatts: detection.rollingAverageCPUPowerWatts,
                    rollingAverageGPUPowerWatts: detection.rollingAverageGPUPowerWatts,
                    cumulativeEnergyWattHours: Double(
                        state.cumulativeCPUEnergyNanojoules
                            &+ state.cumulativeGPUEnergyNanojoules
                    ) / Self.nanojoulesPerWattHour,
                    cumulativeCPUEnergyWattHours: Double(
                        state.cumulativeCPUEnergyNanojoules
                    ) / Self.nanojoulesPerWattHour,
                    cumulativeGPUEnergyWattHours: Double(
                        state.cumulativeGPUEnergyNanojoules
                    )
                        / Self.nanojoulesPerWattHour,
                    isGPUEnergyAvailable: state.hasGPUEnergyMeasurement,
                    monitoredSince: state.monitoredSince,
                    processes: processSnapshots
                )
            )
        }

        sessions = sessions.filter { key, _ in
            let isEphemeral = key.hasPrefix("process:") || key.hasPrefix("coalition:")
            return !isEphemeral || activeKeys.contains(key)
        }

        return snapshots.sorted {
            let lhsRank = statusRank($0.status)
            let rhsRank = statusRank($1.status)
            if lhsRank != rhsRank { return lhsRank > rhsRank }
            return $0.currentPowerWatts > $1.currentPowerWatts
        }
    }

    private func resolveAssociation(
        for measurement: ProcessMeasurement,
        measurementsByPID: [pid_t: ProcessMeasurement],
        directAssociations: [ProcessIdentity: BundleAssociation],
        resolvedAssociations: inout [ProcessIdentity: BundleAssociation],
        visited: Set<ProcessIdentity>
    ) -> BundleAssociation? {
        if let direct = directAssociations[measurement.identity] {
            resolvedAssociations[measurement.identity] = direct
            return direct
        }
        if let resolved = resolvedAssociations[measurement.identity] {
            return resolved
        }
        guard !visited.contains(measurement.identity) else { return nil }
        guard let parent = measurementsByPID[measurement.parentPID] else { return nil }
        guard parent.uid == measurement.uid else { return nil }
        guard !Self.infrastructureProcessNames.contains(parent.name.lowercased()) else {
            return nil
        }

        var nextVisited = visited
        nextVisited.insert(measurement.identity)
        let association = resolveAssociation(
            for: parent,
            measurementsByPID: measurementsByPID,
            directAssociations: directAssociations,
            resolvedAssociations: &resolvedAssociations,
            visited: nextVisited
        )
        if let association {
            resolvedAssociations[measurement.identity] = association
        }
        return association
    }

    private func bundleAssociation(forExecutablePath executablePath: String) -> BundleAssociation? {
        guard let appPath = outermostApplicationPath(in: executablePath) else { return nil }
        if let cached = bundleCache[appPath] { return cached }

        let bundle = Bundle(path: appPath)
        let bundleIdentifier = bundle?.bundleIdentifier
        let fallbackName = URL(fileURLWithPath: appPath)
            .deletingPathExtension()
            .lastPathComponent
        let displayName = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? fallbackName
        let association = BundleAssociation(
            key: "bundle:\(bundleIdentifier ?? appPath)",
            displayName: displayName,
            bundleIdentifier: bundleIdentifier,
            mainExecutablePath: bundle?.executablePath
        )
        bundleCache[appPath] = association
        return association
    }

    private func outermostApplicationPath(in executablePath: String) -> String? {
        var accumulatedPath = ""
        for component in URL(fileURLWithPath: executablePath).pathComponents {
            if component == "/" {
                accumulatedPath = "/"
                continue
            }
            accumulatedPath = (accumulatedPath as NSString).appendingPathComponent(component)
            if component.lowercased().hasSuffix(".app") {
                return accumulatedPath
            }
        }
        return nil
    }

    private func workloadRoot(
        in measurements: [ProcessMeasurement],
        mainExecutablePath: String?
    ) -> ProcessIdentity? {
        if let mainExecutablePath,
           let main = measurements.first(where: { $0.executablePath == mainExecutablePath }) {
            return main.identity
        }

        let memberPIDs = Set(measurements.map(\ProcessMeasurement.identity.pid))
        return measurements
            .filter { !memberPIDs.contains($0.parentPID) }
            .min { $0.launchDate < $1.launchDate }?
            .identity
            ?? measurements.min { $0.launchDate < $1.launchDate }?.identity
    }

    private func processSnapshot(
        from measurement: ProcessMeasurement,
        rootIdentity: ProcessIdentity?
    ) -> ProcessSnapshot {
        ProcessSnapshot(
            processIdentifier: measurement.identity.pid,
            parentProcessIdentifier: measurement.parentPID,
            userIdentifier: measurement.uid,
            name: measurement.name,
            executablePath: measurement.executablePath,
            launchDate: measurement.launchDate,
            resourceCoalitionIdentifier: measurement.resourceCoalitionID ?? 0,
            cpuPowerWatts: measurement.cpuPowerWatts,
            cpuPercentage: measurement.cpuPercentage,
            interruptWakeupsPerSecond: measurement.interruptWakeupsPerSecond,
            diskReadBytesPerSecond: measurement.diskReadBytesPerSecond,
            diskWriteBytesPerSecond: measurement.diskWriteBytesPerSecond,
            sampleDuration: measurement.sampleDuration,
            cumulativeEnergyWattHours: Double(measurement.cumulativeEnergyNanojoules)
                / Self.nanojoulesPerWattHour,
            isWorkloadRoot: measurement.identity == rootIdentity
        )
    }

    private func standaloneKey(for identity: ProcessIdentity) -> String {
        "process:\(identity.pid):\(identity.startSeconds):\(identity.startMicroseconds)"
    }

    private func gpuCoalitionOwners(
        groups: [String: [ProcessMeasurement]],
        descriptors: [String: Descriptor]
    ) -> [UInt64: String] {
        var candidates: [UInt64: [(key: String, memberCount: Int, isBundle: Bool)]] = [:]

        for (key, measurements) in groups {
            let counts = Dictionary(
                grouping: measurements.compactMap(\.resourceCoalitionID),
                by: { $0 }
            ).mapValues(\.count)
            for (coalitionID, memberCount) in counts {
                candidates[coalitionID, default: []].append(
                    (
                        key: key,
                        memberCount: memberCount,
                        isBundle: descriptors[key]?.bundleIdentifier != nil
                    )
                )
            }
        }

        return candidates.compactMapValues { values in
            values.max {
                if $0.isBundle != $1.isBundle {
                    return !$0.isBundle && $1.isBundle
                }
                if $0.memberCount != $1.memberCount {
                    return $0.memberCount < $1.memberCount
                }
                return $0.key > $1.key
            }?.key
        }
    }

    private func statusRank(_ status: WorkloadStatus) -> Int {
        switch status {
        case .normal: 0
        case .candidate: 1
        case .sustainedHog: 2
        }
    }
}
