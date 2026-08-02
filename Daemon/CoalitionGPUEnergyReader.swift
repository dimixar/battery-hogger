import Darwin
import Foundation

struct CoalitionGPUCounterSnapshot: Sendable {
    let energyNanojoules: UInt64
    let gpuTimeNanoseconds: UInt64
    let energyBilledToMeNanojoules: UInt64
    let energyBilledToOthersNanojoules: UInt64
}

/// Isolates the two undocumented Darwin interfaces used for coalition GPU accounting.
/// If Apple removes either interface, callers receive `nil` and CPU monitoring continues.
final class CoalitionGPUEnergyReader: @unchecked Sendable {
    private typealias CoalitionUsageFunction = @convention(c) (
        UInt64,
        UnsafeMutableRawPointer?,
        Int
    ) -> Int32

    private static let processCoalitionInfoFlavor: Int32 = 20
    private static let resourceCoalitionIndex = 0
    private static let processCoalitionInfoWordCount = 5

    // Layout of `coalition_resource_usage` in current XNU. Apple has historically
    // appended fields; the kernel copies only min(caller size, kernel size).
    private static let resourceUsageWordCount = 45
    private static let gpuTimeIndex = 8
    private static let gpuEnergyIndex = 41
    private static let gpuEnergyBilledToMeIndex = 42
    private static let gpuEnergyBilledToOthersIndex = 43

    private let imageHandle: UnsafeMutableRawPointer?
    private let coalitionUsage: CoalitionUsageFunction?
    private let supportsGPUCounters: Bool

    init() {
        // The GPU fields were appended in XNU 11215 (macOS 15). Earlier kernels
        // successfully return a shorter structure, which would otherwise look
        // indistinguishable from a valid all-zero GPU reading.
        supportsGPUCounters = ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 15
        let handle = dlopen(nil, RTLD_LAZY | RTLD_LOCAL)
        imageHandle = handle
        if let symbol = handle.flatMap({ dlsym($0, "coalition_info_resource_usage") }) {
            coalitionUsage = unsafeBitCast(symbol, to: CoalitionUsageFunction.self)
        } else {
            coalitionUsage = nil
        }
    }

    deinit {
        if let imageHandle {
            dlclose(imageHandle)
        }
    }

    var isAvailable: Bool {
        supportsGPUCounters && coalitionUsage != nil
    }

    func resourceCoalitionID(for pid: pid_t) -> UInt64? {
        var words = [UInt64](
            repeating: 0,
            count: Self.processCoalitionInfoWordCount
        )
        let bytesRead = words.withUnsafeMutableBytes { buffer in
            proc_pidinfo(
                pid,
                Self.processCoalitionInfoFlavor,
                0,
                buffer.baseAddress,
                Int32(buffer.count)
            )
        }
        guard bytesRead == words.count * MemoryLayout<UInt64>.stride else {
            return nil
        }

        let identifier = words[Self.resourceCoalitionIndex]
        return identifier == 0 ? nil : identifier
    }

    func snapshot(for coalitionID: UInt64) -> CoalitionGPUCounterSnapshot? {
        guard supportsGPUCounters, let coalitionUsage else { return nil }

        var words = [UInt64](repeating: 0, count: Self.resourceUsageWordCount)
        let result = words.withUnsafeMutableBytes { buffer in
            coalitionUsage(coalitionID, buffer.baseAddress, buffer.count)
        }
        guard result == 0 else { return nil }

        return CoalitionGPUCounterSnapshot(
            energyNanojoules: words[Self.gpuEnergyIndex],
            gpuTimeNanoseconds: words[Self.gpuTimeIndex],
            energyBilledToMeNanojoules: words[Self.gpuEnergyBilledToMeIndex],
            energyBilledToOthersNanojoules: words[Self.gpuEnergyBilledToOthersIndex]
        )
    }
}
