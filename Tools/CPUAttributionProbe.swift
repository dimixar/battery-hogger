import Darwin
import Foundation

private struct ProcessIdentity: Hashable {
    let pid: pid_t
    let startSeconds: UInt64
    let startMicroseconds: UInt64
}

private struct EnergySnapshot {
    let sampledAtNanoseconds: UInt64
    let energyByProcess: [ProcessIdentity: UInt64]
}

private struct AttributedSample {
    let watts: Double
    let matchedProcesses: Int
}

private struct PackageSample {
    let watts: Double
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

private func identity(for pid: pid_t) -> ProcessIdentity? {
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
    return ProcessIdentity(
        pid: pid,
        startSeconds: info.pbi_start_tvsec,
        startMicroseconds: info.pbi_start_tvusec
    )
}

private func energy(for pid: pid_t) -> UInt64? {
    var usage = rusage_info_v6()
    let result = withUnsafeMutablePointer(to: &usage) { pointer in
        pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
            proc_pid_rusage(pid, RUSAGE_INFO_V6, $0)
        }
    }
    return result == 0 ? usage.ri_energy_nj : nil
}

private func takeSnapshot() -> EnergySnapshot {
    var values: [ProcessIdentity: UInt64] = [:]
    for pid in allProcessIdentifiers() where pid > 0 {
        guard let identity = identity(for: pid), let energy = energy(for: pid) else {
            continue
        }
        values[identity] = energy
    }
    return EnergySnapshot(
        sampledAtNanoseconds: DispatchTime.now().uptimeNanoseconds,
        energyByProcess: values
    )
}

private func attributedSample(
    previous: EnergySnapshot,
    current: EnergySnapshot
) -> AttributedSample {
    guard current.sampledAtNanoseconds > previous.sampledAtNanoseconds else {
        return AttributedSample(watts: 0, matchedProcesses: 0)
    }

    var energyDelta: UInt64 = 0
    var matchedProcesses = 0
    for (identity, currentEnergy) in current.energyByProcess {
        guard
            let previousEnergy = previous.energyByProcess[identity],
            currentEnergy >= previousEnergy
        else {
            continue
        }
        energyDelta &+= currentEnergy - previousEnergy
        matchedProcesses += 1
    }

    let elapsedNanoseconds = current.sampledAtNanoseconds - previous.sampledAtNanoseconds
    return AttributedSample(
        watts: Double(energyDelta) / Double(elapsedNanoseconds),
        matchedProcesses: matchedProcesses
    )
}

private func powermetricsCPUWatts(from output: String) -> [Double] {
    output.split(whereSeparator: \.isNewline).compactMap { line in
        let text = String(line)
        guard let range = text.range(
            of: #"CPU Power:\s*([0-9]+(?:\.[0-9]+)?)\s*mW"#,
            options: .regularExpression
        ) else {
            return nil
        }
        let match = String(text[range])
        guard
            let numberRange = match.range(
                of: #"[0-9]+(?:\.[0-9]+)?"#,
                options: .regularExpression
            ),
            let milliwatts = Double(match[numberRange])
        else {
            return nil
        }
        return milliwatts / 1_000
    }
}

private func parsePositiveInteger(_ value: String?, default defaultValue: Int) -> Int {
    guard let value, let parsed = Int(value), parsed > 0 else { return defaultValue }
    return parsed
}

@main
private enum CPUAttributionProbe {
static func main() {
guard geteuid() == 0 else {
    FileHandle.standardError.write(Data("This probe must run as root.\n".utf8))
    exit(77)
}

let sampleCount = parsePositiveInteger(CommandLine.arguments.dropFirst().first, default: 10)
let intervalMilliseconds = parsePositiveInteger(
    CommandLine.arguments.dropFirst(2).first,
    default: 3_000
)

let temporaryDirectory = FileManager.default.temporaryDirectory
let outputURL = temporaryDirectory.appendingPathComponent(
    "battery-hogger-powermetrics-\(UUID().uuidString).out"
)
let errorURL = temporaryDirectory.appendingPathComponent(
    "battery-hogger-powermetrics-\(UUID().uuidString).err"
)
guard
    FileManager.default.createFile(atPath: outputURL.path, contents: nil),
    FileManager.default.createFile(atPath: errorURL.path, contents: nil)
else {
    FileHandle.standardError.write(Data("Unable to create temporary output files.\n".utf8))
    exit(73)
}

let outputHandle: FileHandle
let errorHandle: FileHandle
do {
    outputHandle = try FileHandle(forWritingTo: outputURL)
    errorHandle = try FileHandle(forWritingTo: errorURL)
} catch {
    try? FileManager.default.removeItem(at: outputURL)
    try? FileManager.default.removeItem(at: errorURL)
    FileHandle.standardError.write(Data("Unable to open temporary output files: \(error)\n".utf8))
    exit(73)
}

let powermetrics = Process()
powermetrics.executableURL = URL(fileURLWithPath: "/usr/bin/powermetrics")
powermetrics.arguments = [
    "--samplers", "cpu_power",
    "--sample-rate", String(intervalMilliseconds),
    "--sample-count", String(sampleCount),
    "--buffer-size", "1"
]
powermetrics.standardOutput = outputHandle
powermetrics.standardError = errorHandle

var attributedSamples: [AttributedSample] = []
var previous = takeSnapshot()
let packageReader = PackageCPUEnergyReader()
var previousPackageEnergy = packageReader.cumulativeEnergyJoules()
var previousPackageSampledAt = DispatchTime.now().uptimeNanoseconds
var ioReportSamples: [PackageSample?] = []

do {
    try powermetrics.run()
} catch {
    try? outputHandle.close()
    try? errorHandle.close()
    try? FileManager.default.removeItem(at: outputURL)
    try? FileManager.default.removeItem(at: errorURL)
    FileHandle.standardError.write(Data("Unable to launch powermetrics: \(error)\n".utf8))
    exit(70)
}

for sampleIndex in 0..<sampleCount {
    Thread.sleep(forTimeInterval: Double(intervalMilliseconds) / 1_000)
    let current = takeSnapshot()
    attributedSamples.append(attributedSample(previous: previous, current: current))
    previous = current
    let packageSampledAt = DispatchTime.now().uptimeNanoseconds
    if
        let previousEnergy = previousPackageEnergy,
        let currentEnergy = packageReader.cumulativeEnergyJoules(),
        currentEnergy >= previousEnergy,
        packageSampledAt > previousPackageSampledAt
    {
        let elapsed = Double(packageSampledAt - previousPackageSampledAt) / 1_000_000_000
        ioReportSamples.append(
            PackageSample(watts: (currentEnergy - previousEnergy) / elapsed)
        )
        previousPackageEnergy = currentEnergy
    } else {
        ioReportSamples.append(nil)
        previousPackageEnergy = packageReader.cumulativeEnergyJoules()
    }
    previousPackageSampledAt = packageSampledAt
    print("Captured synchronized sample \(sampleIndex + 1)/\(sampleCount)")
    fflush(stdout)
}

powermetrics.waitUntilExit()
try? outputHandle.close()
try? errorHandle.close()
let output = (try? String(contentsOf: outputURL, encoding: .utf8)) ?? ""
let errorOutput = (try? String(contentsOf: errorURL, encoding: .utf8)) ?? ""
try? FileManager.default.removeItem(at: outputURL)
try? FileManager.default.removeItem(at: errorURL)
guard powermetrics.terminationStatus == 0 else {
    FileHandle.standardError.write(
        Data("powermetrics failed: \(errorOutput)\n".utf8)
    )
    exit(powermetrics.terminationStatus)
}

let packageSamples = powermetricsCPUWatts(from: output)
let comparableCount = min(attributedSamples.count, packageSamples.count)
guard comparableCount > 0 else {
    FileHandle.standardError.write(
        Data("No CPU Power samples were found in powermetrics output.\n".utf8)
    )
    exit(65)
}

print("Sample  Attributed CPU  IOReport CPU  powermetrics CPU  IOReport/PM  Matched")
for index in 0..<comparableCount {
    let attributed = attributedSamples[index]
    let packageWatts = packageSamples[index]
    let ioReportWatts = ioReportSamples[index]?.watts ?? 0
    let ioReportRatio = packageWatts > 0 ? ioReportWatts / packageWatts : 0
    print(
        String(
            format: "%6d  %12.3f W  %10.3f W  %14.3f W  %10.1f%%  %7d",
            index + 1,
            attributed.watts,
            ioReportWatts,
            packageWatts,
            ioReportRatio * 100,
            attributed.matchedProcesses
        )
    )
}

let attributedAverage = attributedSamples.prefix(comparableCount).reduce(0) {
    $0 + $1.watts
} / Double(comparableCount)
let packageAverage = packageSamples.prefix(comparableCount).reduce(0, +)
    / Double(comparableCount)
let validIOReportSamples = ioReportSamples.prefix(comparableCount).compactMap { $0?.watts }
let ioReportAverage = validIOReportSamples.isEmpty
    ? 0
    : validIOReportSamples.reduce(0, +) / Double(validIOReportSamples.count)
let averageRatio = packageAverage > 0 ? ioReportAverage / packageAverage : 0
print(
    String(
        format: "Average %12.3f W  %10.3f W  %14.3f W  %10.1f%%",
        attributedAverage,
        ioReportAverage,
        packageAverage,
        averageRatio * 100
    )
)
}
}
