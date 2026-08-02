import Darwin
import Foundation

struct ProcessIdentity: Hashable, Sendable {
    let pid: pid_t
    let startSeconds: UInt64
    let startMicroseconds: UInt64
}

struct ProcessMeasurement: Sendable {
    let identity: ProcessIdentity
    let parentPID: pid_t
    let uid: uid_t
    let name: String
    let executablePath: String?
    let launchDate: Date
    let resourceCoalitionID: UInt64?
    let sampledAtNanoseconds: UInt64
    let sampleDuration: TimeInterval
    let energyDeltaNanojoules: UInt64
    let cumulativeEnergyNanojoules: UInt64
    let cpuPowerWatts: Double
    let cpuPercentage: Double
}

struct CoalitionGPUMeasurement: Sendable {
    let coalitionID: UInt64
    let sampledAtNanoseconds: UInt64
    let sampleDuration: TimeInterval
    let energyDeltaNanojoules: UInt64
    let gpuPowerWatts: Double
}

struct PackageEnergyMeasurement: Sendable {
    let sampleDuration: TimeInterval
    let cpuPowerWatts: Double?
    let gpuPowerWatts: Double?
    let otherSoCPowerWatts: Double?
}

struct ProcessSampleBatch: Sendable {
    let sampledAtNanoseconds: UInt64
    let sampledAtDate: Date
    let measurements: [ProcessMeasurement]
    let coalitionGPUMeasurements: [CoalitionGPUMeasurement]
    let packageEnergyMeasurement: PackageEnergyMeasurement?
}

final class ProcessSampler: @unchecked Sendable {
    private struct Counters {
        let sampledAtNanoseconds: UInt64
        let energyNanojoules: UInt64
        let userTime: UInt64
        let systemTime: UInt64
    }

    private struct Metadata {
        let identity: ProcessIdentity
        let parentPID: pid_t
        let uid: uid_t
        let name: String
        let executablePath: String?
        let launchDate: Date
        let resourceCoalitionID: UInt64?
    }

    private struct GPUCounters {
        let sampledAtNanoseconds: UInt64
        let energyNanojoules: UInt64
    }

    private struct PackageEnergyCounter {
        let sampledAtNanoseconds: UInt64
        let cpuEnergyJoules: Double?
        let gpuEnergyJoules: Double?
        let otherSoCEnergyJoules: Double?
    }

    private struct Rates {
        let duration: TimeInterval
        let energyDeltaNanojoules: UInt64
        let cpuPowerWatts: Double
        let cpuPercentage: Double

        static let baseline = Rates(
            duration: 0,
            energyDeltaNanojoules: 0,
            cpuPowerWatts: 0,
            cpuPercentage: 0
        )
    }

    private static let maximumRateIntervalNanoseconds: UInt64 = 15_000_000_000

    private var previousCounters: [ProcessIdentity: Counters] = [:]
    private var previousGPUCounters: [UInt64: GPUCounters] = [:]
    private var previousPackageEnergyCounter: PackageEnergyCounter?
    private var cumulativeEnergy: [ProcessIdentity: UInt64] = [:]
    private let timebase: mach_timebase_info_data_t
    private let gpuEnergyReader = CoalitionGPUEnergyReader()
    private let packageCPUEnergyReader = PackageCPUEnergyReader()
    private let lock = NSLock()

    init() {
        var value = mach_timebase_info_data_t()
        mach_timebase_info(&value)
        timebase = value
    }

    func sample() -> ProcessSampleBatch {
        lock.withLock { sampleLocked() }
    }

    private func sampleLocked() -> ProcessSampleBatch {
        let sampledAtNanoseconds = DispatchTime.now().uptimeNanoseconds
        let sampledAtDate = Date()
        let pids = allProcessIdentifiers()
        var nextCounters: [ProcessIdentity: Counters] = [:]
        nextCounters.reserveCapacity(pids.count)

        var measurements: [ProcessMeasurement] = []
        measurements.reserveCapacity(pids.count)

        for pid in pids where pid > 0 {
            guard
                let metadata = metadata(for: pid),
                let usage = resourceUsage(for: pid)
            else {
                continue
            }

            let counters = Counters(
                sampledAtNanoseconds: sampledAtNanoseconds,
                energyNanojoules: usage.ri_energy_nj,
                userTime: usage.ri_user_time,
                systemTime: usage.ri_system_time
            )
            nextCounters[metadata.identity] = counters

            let rates = rates(current: counters, previous: previousCounters[metadata.identity])
            let processCumulativeEnergy = cumulativeEnergy[metadata.identity, default: 0]
                + rates.energyDeltaNanojoules
            cumulativeEnergy[metadata.identity] = processCumulativeEnergy

            measurements.append(
                ProcessMeasurement(
                    identity: metadata.identity,
                    parentPID: metadata.parentPID,
                    uid: metadata.uid,
                    name: metadata.name,
                    executablePath: metadata.executablePath,
                    launchDate: metadata.launchDate,
                    resourceCoalitionID: metadata.resourceCoalitionID,
                    sampledAtNanoseconds: sampledAtNanoseconds,
                    sampleDuration: rates.duration,
                    energyDeltaNanojoules: rates.energyDeltaNanojoules,
                    cumulativeEnergyNanojoules: processCumulativeEnergy,
                    cpuPowerWatts: rates.cpuPowerWatts,
                    cpuPercentage: rates.cpuPercentage
                )
            )
        }

        previousCounters = nextCounters
        let activeIdentities = Set(nextCounters.keys)
        cumulativeEnergy = cumulativeEnergy.filter { activeIdentities.contains($0.key) }

        let activeCoalitionIDs = Set(measurements.compactMap(\.resourceCoalitionID))
        var nextGPUCounters: [UInt64: GPUCounters] = [:]
        var gpuMeasurements: [CoalitionGPUMeasurement] = []
        nextGPUCounters.reserveCapacity(activeCoalitionIDs.count)
        gpuMeasurements.reserveCapacity(activeCoalitionIDs.count)

        for coalitionID in activeCoalitionIDs {
            guard let snapshot = gpuEnergyReader.snapshot(for: coalitionID) else {
                continue
            }
            let counters = GPUCounters(
                sampledAtNanoseconds: sampledAtNanoseconds,
                energyNanojoules: snapshot.energyNanojoules
            )
            nextGPUCounters[coalitionID] = counters
            let rate = gpuRate(
                current: counters,
                previous: previousGPUCounters[coalitionID]
            )
            gpuMeasurements.append(
                CoalitionGPUMeasurement(
                    coalitionID: coalitionID,
                    sampledAtNanoseconds: sampledAtNanoseconds,
                    sampleDuration: rate.duration,
                    energyDeltaNanojoules: rate.energyDeltaNanojoules,
                    gpuPowerWatts: rate.powerWatts
                )
            )
        }
        previousGPUCounters = nextGPUCounters

        let packageEnergyMeasurement: PackageEnergyMeasurement?
        if let energy = packageCPUEnergyReader.cumulativeSystemEnergy() {
            let current = PackageEnergyCounter(
                sampledAtNanoseconds: DispatchTime.now().uptimeNanoseconds,
                cpuEnergyJoules: energy.cpuEnergyJoules,
                gpuEnergyJoules: energy.gpuEnergyJoules,
                otherSoCEnergyJoules: energy.otherSoCEnergyJoules
            )
            packageEnergyMeasurement = packageEnergyRate(
                current: current,
                previous: previousPackageEnergyCounter
            )
            previousPackageEnergyCounter = current
        } else {
            packageEnergyMeasurement = nil
            previousPackageEnergyCounter = nil
        }

        return ProcessSampleBatch(
            sampledAtNanoseconds: sampledAtNanoseconds,
            sampledAtDate: sampledAtDate,
            measurements: measurements,
            coalitionGPUMeasurements: gpuMeasurements,
            packageEnergyMeasurement: packageEnergyMeasurement
        )
    }

    private func allProcessIdentifiers() -> [pid_t] {
        let estimatedCount = max(proc_listallpids(nil, 0), 256)
        var pids = [pid_t](repeating: 0, count: Int(estimatedCount) + 128)
        let count = proc_listallpids(
            &pids,
            Int32(pids.count * MemoryLayout<pid_t>.stride)
        )
        guard count > 0 else { return [] }
        return Array(pids.prefix(Int(count)))
    }

    private func metadata(for pid: pid_t) -> Metadata? {
        var info = proc_bsdinfo()
        let bytesRead = withUnsafeMutablePointer(to: &info) { pointer in
            proc_pidinfo(
                pid,
                PROC_PIDTBSDINFO,
                0,
                pointer,
                Int32(MemoryLayout<proc_bsdinfo>.stride)
            )
        }
        guard bytesRead == MemoryLayout<proc_bsdinfo>.stride else { return nil }

        let identity = ProcessIdentity(
            pid: pid,
            startSeconds: info.pbi_start_tvsec,
            startMicroseconds: info.pbi_start_tvusec
        )
        let launchDate = Date(
            timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec)
                + TimeInterval(info.pbi_start_tvusec) / 1_000_000
        )

        return Metadata(
            identity: identity,
            parentPID: pid_t(info.pbi_ppid),
            uid: info.pbi_uid,
            name: processName(for: pid),
            executablePath: executablePath(for: pid),
            launchDate: launchDate,
            resourceCoalitionID: gpuEnergyReader.resourceCoalitionID(for: pid)
        )
    }

    private func processName(for pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return "Process \(pid)" }
        return decodeUTF8(buffer, length: Int(length))
    }

    private func executablePath(for pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return decodeUTF8(buffer, length: Int(length))
    }

    private func resourceUsage(for pid: pid_t) -> rusage_info_v6? {
        var usage = rusage_info_v6()
        let result = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V6, $0)
            }
        }
        return result == 0 ? usage : nil
    }

    private func rates(current: Counters, previous: Counters?) -> Rates {
        guard
            let previous,
            current.sampledAtNanoseconds > previous.sampledAtNanoseconds
        else {
            return .baseline
        }

        let elapsedNanoseconds = current.sampledAtNanoseconds - previous.sampledAtNanoseconds
        guard elapsedNanoseconds <= Self.maximumRateIntervalNanoseconds else {
            return .baseline
        }

        let elapsedSeconds = Double(elapsedNanoseconds) / 1_000_000_000
        let energyDelta = nonnegativeDelta(current.energyNanojoules, previous.energyNanojoules)
        let userDelta = nonnegativeDelta(current.userTime, previous.userTime)
        let systemDelta = nonnegativeDelta(current.systemTime, previous.systemTime)
        let cpuMachTime = userDelta + systemDelta
        let cpuNanoseconds = Double(cpuMachTime)
            * Double(timebase.numer)
            / Double(timebase.denom)

        return Rates(
            duration: elapsedSeconds,
            energyDeltaNanojoules: energyDelta,
            cpuPowerWatts: Double(energyDelta) / Double(elapsedNanoseconds),
            cpuPercentage: cpuNanoseconds / Double(elapsedNanoseconds) * 100
        )
    }

    private func nonnegativeDelta(_ current: UInt64, _ previous: UInt64) -> UInt64 {
        current >= previous ? current - previous : 0
    }

    private func gpuRate(
        current: GPUCounters,
        previous: GPUCounters?
    ) -> (duration: TimeInterval, energyDeltaNanojoules: UInt64, powerWatts: Double) {
        guard
            let previous,
            current.sampledAtNanoseconds > previous.sampledAtNanoseconds
        else {
            return (0, 0, 0)
        }

        let elapsedNanoseconds = current.sampledAtNanoseconds - previous.sampledAtNanoseconds
        guard elapsedNanoseconds <= Self.maximumRateIntervalNanoseconds else {
            return (0, 0, 0)
        }

        let delta = nonnegativeDelta(current.energyNanojoules, previous.energyNanojoules)
        return (
            Double(elapsedNanoseconds) / 1_000_000_000,
            delta,
            Double(delta) / Double(elapsedNanoseconds)
        )
    }

    private func packageEnergyRate(
        current: PackageEnergyCounter,
        previous: PackageEnergyCounter?
    ) -> PackageEnergyMeasurement {
        guard
            let previous,
            current.sampledAtNanoseconds > previous.sampledAtNanoseconds
        else {
            return PackageEnergyMeasurement(
                sampleDuration: 0,
                cpuPowerWatts: nil,
                gpuPowerWatts: nil,
                otherSoCPowerWatts: nil
            )
        }

        let elapsedNanoseconds = current.sampledAtNanoseconds - previous.sampledAtNanoseconds
        guard elapsedNanoseconds <= Self.maximumRateIntervalNanoseconds else {
            return PackageEnergyMeasurement(
                sampleDuration: 0,
                cpuPowerWatts: nil,
                gpuPowerWatts: nil,
                otherSoCPowerWatts: nil
            )
        }
        let elapsedSeconds = Double(elapsedNanoseconds) / 1_000_000_000
        return PackageEnergyMeasurement(
            sampleDuration: elapsedSeconds,
            cpuPowerWatts: energyRate(
                current.cpuEnergyJoules,
                previous.cpuEnergyJoules,
                elapsedSeconds: elapsedSeconds
            ),
            gpuPowerWatts: energyRate(
                current.gpuEnergyJoules,
                previous.gpuEnergyJoules,
                elapsedSeconds: elapsedSeconds
            ),
            otherSoCPowerWatts: energyRate(
                current.otherSoCEnergyJoules,
                previous.otherSoCEnergyJoules,
                elapsedSeconds: elapsedSeconds
            )
        )
    }

    private func energyRate(
        _ current: Double?,
        _ previous: Double?,
        elapsedSeconds: TimeInterval
    ) -> Double? {
        guard let current, let previous, current >= previous else { return nil }
        return (current - previous) / elapsedSeconds
    }

    private func decodeUTF8(_ buffer: [CChar], length: Int) -> String {
        let bytes = buffer.prefix(length).map(UInt8.init(bitPattern:))
        return String(decoding: bytes, as: UTF8.self)
    }
}
