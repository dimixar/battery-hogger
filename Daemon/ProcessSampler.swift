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
    let sampledAtNanoseconds: UInt64
    let sampleDuration: TimeInterval
    let energyDeltaNanojoules: UInt64
    let cumulativeEnergyNanojoules: UInt64
    let cpuPowerWatts: Double
    let cpuPercentage: Double
    let interruptWakeupsPerSecond: Double
    let diskReadBytesPerSecond: Double
    let diskWriteBytesPerSecond: Double
}

struct ProcessSampleBatch: Sendable {
    let sampledAtNanoseconds: UInt64
    let sampledAtDate: Date
    let measurements: [ProcessMeasurement]
}

final class ProcessSampler: @unchecked Sendable {
    private struct Counters {
        let sampledAtNanoseconds: UInt64
        let energyNanojoules: UInt64
        let userTime: UInt64
        let systemTime: UInt64
        let interruptWakeups: UInt64
        let diskBytesRead: UInt64
        let diskBytesWritten: UInt64
    }

    private struct Metadata {
        let identity: ProcessIdentity
        let parentPID: pid_t
        let uid: uid_t
        let name: String
        let executablePath: String?
        let launchDate: Date
    }

    private struct Rates {
        let duration: TimeInterval
        let energyDeltaNanojoules: UInt64
        let cpuPowerWatts: Double
        let cpuPercentage: Double
        let interruptWakeupsPerSecond: Double
        let diskReadBytesPerSecond: Double
        let diskWriteBytesPerSecond: Double

        static let baseline = Rates(
            duration: 0,
            energyDeltaNanojoules: 0,
            cpuPowerWatts: 0,
            cpuPercentage: 0,
            interruptWakeupsPerSecond: 0,
            diskReadBytesPerSecond: 0,
            diskWriteBytesPerSecond: 0
        )
    }

    private static let maximumRateIntervalNanoseconds: UInt64 = 15_000_000_000

    private var previousCounters: [ProcessIdentity: Counters] = [:]
    private var cumulativeEnergy: [ProcessIdentity: UInt64] = [:]
    private let timebase: mach_timebase_info_data_t
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
                systemTime: usage.ri_system_time,
                interruptWakeups: usage.ri_interrupt_wkups,
                diskBytesRead: usage.ri_diskio_bytesread,
                diskBytesWritten: usage.ri_diskio_byteswritten
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
                    sampledAtNanoseconds: sampledAtNanoseconds,
                    sampleDuration: rates.duration,
                    energyDeltaNanojoules: rates.energyDeltaNanojoules,
                    cumulativeEnergyNanojoules: processCumulativeEnergy,
                    cpuPowerWatts: rates.cpuPowerWatts,
                    cpuPercentage: rates.cpuPercentage,
                    interruptWakeupsPerSecond: rates.interruptWakeupsPerSecond,
                    diskReadBytesPerSecond: rates.diskReadBytesPerSecond,
                    diskWriteBytesPerSecond: rates.diskWriteBytesPerSecond
                )
            )
        }

        previousCounters = nextCounters
        let activeIdentities = Set(nextCounters.keys)
        cumulativeEnergy = cumulativeEnergy.filter { activeIdentities.contains($0.key) }

        return ProcessSampleBatch(
            sampledAtNanoseconds: sampledAtNanoseconds,
            sampledAtDate: sampledAtDate,
            measurements: measurements
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
            launchDate: launchDate
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
            cpuPercentage: cpuNanoseconds / Double(elapsedNanoseconds) * 100,
            interruptWakeupsPerSecond: Double(nonnegativeDelta(current.interruptWakeups, previous.interruptWakeups)) / elapsedSeconds,
            diskReadBytesPerSecond: Double(nonnegativeDelta(current.diskBytesRead, previous.diskBytesRead)) / elapsedSeconds,
            diskWriteBytesPerSecond: Double(nonnegativeDelta(current.diskBytesWritten, previous.diskBytesWritten)) / elapsedSeconds
        )
    }

    private func nonnegativeDelta(_ current: UInt64, _ previous: UInt64) -> UInt64 {
        current >= previous ? current - previous : 0
    }

    private func decodeUTF8(_ buffer: [CChar], length: Int) -> String {
        let bytes = buffer.prefix(length).map(UInt8.init(bitPattern:))
        return String(decoding: bytes, as: UTF8.self)
    }
}
