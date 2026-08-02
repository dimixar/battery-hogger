import CoreFoundation
import Darwin
import Foundation

struct PackageEnergyCounterSnapshot: Sendable {
    let cpuEnergyJoules: Double?
    let gpuEnergyJoules: Double?
    let otherSoCEnergyJoules: Double?
}

/// Reads cumulative package energy domains exposed by Apple's private
/// libIOReport. The interface is optional so monitoring falls back to directly
/// attributed process energy if it changes or disappears.
final class PackageCPUEnergyReader: @unchecked Sendable {
    private typealias CopyChannelsInGroupFunction = @convention(c) (
        CFString?,
        CFString?,
        UInt64,
        UInt64,
        UInt64
    ) -> Unmanaged<CFDictionary>?
    private typealias CreateSubscriptionFunction = @convention(c) (
        UnsafeMutableRawPointer?,
        CFMutableDictionary,
        UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>?,
        UInt64,
        CFTypeRef?
    ) -> OpaquePointer?
    private typealias CreateSamplesFunction = @convention(c) (
        OpaquePointer?,
        CFMutableDictionary,
        CFTypeRef?
    ) -> Unmanaged<CFDictionary>?
    private typealias ChannelStringFunction = @convention(c) (
        CFDictionary
    ) -> Unmanaged<CFString>?
    private typealias SimpleValueFunction = @convention(c) (
        CFDictionary,
        Int32
    ) -> Int64

    private let imageHandle: UnsafeMutableRawPointer?
    private let channels: CFMutableDictionary?
    private let subscription: OpaquePointer?
    private let createSamples: CreateSamplesFunction?
    private let channelGroup: ChannelStringFunction?
    private let channelName: ChannelStringFunction?
    private let channelUnit: ChannelStringFunction?
    private let simpleValue: SimpleValueFunction?

    init() {
        let handle = dlopen("/usr/lib/libIOReport.dylib", RTLD_LAZY | RTLD_LOCAL)
        imageHandle = handle

        let copyChannels: CopyChannelsInGroupFunction? = Self.symbol(
            "IOReportCopyChannelsInGroup",
            from: handle
        )
        let createSubscription: CreateSubscriptionFunction? = Self.symbol(
            "IOReportCreateSubscription",
            from: handle
        )
        createSamples = Self.symbol("IOReportCreateSamples", from: handle)
        channelGroup = Self.symbol("IOReportChannelGetGroup", from: handle)
        channelName = Self.symbol("IOReportChannelGetChannelName", from: handle)
        channelUnit = Self.symbol("IOReportChannelGetUnitLabel", from: handle)
        simpleValue = Self.symbol("IOReportSimpleGetIntegerValue", from: handle)

        guard
            let copyChannels,
            let createSubscription,
            createSamples != nil,
            channelGroup != nil,
            channelName != nil,
            channelUnit != nil,
            simpleValue != nil,
            let copiedChannels = copyChannels(
                "Energy Model" as CFString,
                nil,
                0,
                0,
                0
            )?.takeRetainedValue(),
            let mutableChannels = CFDictionaryCreateMutableCopy(
                kCFAllocatorDefault,
                0,
                copiedChannels
            )
        else {
            channels = nil
            subscription = nil
            return
        }

        channels = mutableChannels
        var subscribedChannels: Unmanaged<CFMutableDictionary>?
        subscription = createSubscription(
            nil,
            mutableChannels,
            &subscribedChannels,
            0,
            nil
        )
        subscribedChannels?.release()
    }

    deinit {
        if let imageHandle {
            dlclose(imageHandle)
        }
    }

    var isAvailable: Bool {
        channels != nil && subscription != nil && createSamples != nil
    }

    func cumulativeEnergyJoules() -> Double? {
        cumulativeSystemEnergy()?.cpuEnergyJoules
    }

    func cumulativeSystemEnergy() -> PackageEnergyCounterSnapshot? {
        let values = cumulativeEnergyChannels()
        guard !values.isEmpty else { return nil }

        let cpuEnergy = aggregateEnergy(
            in: values,
            exactNames: ["CPU Energy", "CPU_Energy"]
        ) {
            $0.hasSuffix("CPU Energy") || $0.hasSuffix("CPU_Energy")
        }
        let gpuEnergy = aggregateEnergy(
            in: values,
            exactNames: ["GPU Energy", "GPU_Energy"]
        ) {
            $0.hasSuffix("GPU Energy") || $0.hasSuffix("GPU_Energy")
        }
        let otherComponents = values.filter {
            $0.name.hasPrefix("DRAM")
                || $0.name.hasPrefix("ANE")
                || ($0.name.hasPrefix("PCI") && $0.name.hasSuffix("Energy"))
        }

        return PackageEnergyCounterSnapshot(
            cpuEnergyJoules: cpuEnergy,
            gpuEnergyJoules: gpuEnergy,
            otherSoCEnergyJoules: otherComponents.isEmpty
                ? nil
                : otherComponents.reduce(0) { $0 + $1.joules }
        )
    }

    func cumulativeEnergyChannels() -> [(name: String, joules: Double)] {
        guard
            let channels,
            let subscription,
            let createSamples,
            let channelGroup,
            let channelName,
            let channelUnit,
            let simpleValue,
            let sample = createSamples(subscription, channels, nil)?.takeRetainedValue(),
            let channelArray = (sample as NSDictionary)["IOReportChannels"] as? NSArray
        else {
            return []
        }

        var values: [(name: String, joules: Double)] = []

        for case let item as NSDictionary in channelArray {
            let channel = unsafeBitCast(item, to: CFDictionary.self)
            guard
                let group = channelGroup(channel)?.takeUnretainedValue() as String?,
                group == "Energy Model",
                let name = channelName(channel)?.takeUnretainedValue() as String?,
                let unit = channelUnit(channel)?.takeUnretainedValue() as String?
            else {
                continue
            }

            let rawValue = simpleValue(channel, 0)
            guard rawValue >= 0, let joules = joules(Double(rawValue), unit: unit) else {
                continue
            }

            values.append((name, joules))
        }

        return values
    }

    private func aggregateEnergy(
        in values: [(name: String, joules: Double)],
        exactNames: Set<String>,
        componentMatches: (String) -> Bool
    ) -> Double? {
        if let aggregate = values.first(where: { exactNames.contains($0.name) }) {
            return aggregate.joules
        }
        let components = values.filter { componentMatches($0.name) }
        return components.isEmpty ? nil : components.reduce(0) { $0 + $1.joules }
    }

    private func joules(_ value: Double, unit: String) -> Double? {
        switch unit {
        case "J": value
        case "mJ": value / 1_000
        case "uJ", "µJ": value / 1_000_000
        case "nJ": value / 1_000_000_000
        default: nil
        }
    }

    private static func symbol<T>(
        _ name: String,
        from handle: UnsafeMutableRawPointer?
    ) -> T? {
        guard let handle, let value = dlsym(handle, name) else { return nil }
        return unsafeBitCast(value, to: T.self)
    }
}
