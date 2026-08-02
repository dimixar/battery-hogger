import Foundation

struct WorkloadDetection: Sendable {
    let status: WorkloadStatus
    let rollingMedianPowerWatts: Double
    let rollingMedianCPUPowerWatts: Double
    let rollingMedianGPUPowerWatts: Double
}

struct WorkloadDetector: Sendable {
    private struct Sample: Sendable {
        let timestampNanoseconds: UInt64
        let duration: TimeInterval
        let cpuPowerWatts: Double
        let gpuPowerWatts: Double

        var totalPowerWatts: Double {
            cpuPowerWatts + gpuPowerWatts
        }
    }

    private static let candidateAverageWatts = 1.0
    private static let hogMedianWatts = 1.5
    private static let highSampleWatts = 1.0
    private static let recoveryWatts = 0.75
    private static let candidateWindow: TimeInterval = 30
    private static let hogWindow: TimeInterval = 90
    private static let minimumHogCoverage: TimeInterval = 80
    private static let requiredHighFraction = 0.8
    private static let recoveryDuration: TimeInterval = 60

    private var samples: [Sample] = []
    private var status: WorkloadStatus = .normal
    private var continuousRecoveryDuration: TimeInterval = 0

    mutating func record(
        cpuPowerWatts: Double,
        gpuPowerWatts: Double,
        duration: TimeInterval,
        at timestampNanoseconds: UInt64
    ) -> WorkloadDetection {
        guard duration > 0, duration <= 15 else {
            prune(at: timestampNanoseconds)
            let medians = weightedMedians(window: Self.hogWindow)
            return WorkloadDetection(
                status: status,
                rollingMedianPowerWatts: medians.total,
                rollingMedianCPUPowerWatts: medians.cpu,
                rollingMedianGPUPowerWatts: medians.gpu
            )
        }

        samples.append(
            Sample(
                timestampNanoseconds: timestampNanoseconds,
                duration: duration,
                cpuPowerWatts: cpuPowerWatts,
                gpuPowerWatts: gpuPowerWatts
            )
        )
        prune(at: timestampNanoseconds)

        let hogStatistics = statistics(window: Self.hogWindow)
        let candidateAverage = statistics(window: Self.candidateWindow).totalAverage
        let powerWatts = cpuPowerWatts + gpuPowerWatts
        let qualifiesAsHog = hogStatistics.coverage >= Self.minimumHogCoverage
            && hogStatistics.totalMedian >= Self.hogMedianWatts
            && hogStatistics.highFraction >= Self.requiredHighFraction

        if status == .sustainedHog {
            if powerWatts < Self.recoveryWatts {
                continuousRecoveryDuration += duration
            } else {
                continuousRecoveryDuration = 0
            }

            if continuousRecoveryDuration >= Self.recoveryDuration {
                status = candidateAverage >= Self.candidateAverageWatts ? .candidate : .normal
                continuousRecoveryDuration = 0
            }
        } else if qualifiesAsHog {
            status = .sustainedHog
            continuousRecoveryDuration = 0
        } else {
            status = candidateAverage >= Self.candidateAverageWatts ? .candidate : .normal
        }

        return WorkloadDetection(
            status: status,
            rollingMedianPowerWatts: hogStatistics.totalMedian,
            rollingMedianCPUPowerWatts: hogStatistics.cpuMedian,
            rollingMedianGPUPowerWatts: hogStatistics.gpuMedian
        )
    }

    private mutating func prune(at timestampNanoseconds: UInt64) {
        let retentionNanoseconds = UInt64(Self.hogWindow * 1_000_000_000)
        let cutoff = timestampNanoseconds > retentionNanoseconds
            ? timestampNanoseconds - retentionNanoseconds
            : 0
        samples.removeAll { $0.timestampNanoseconds < cutoff }
    }

    private func weightedMedians(window: TimeInterval) -> (
        total: Double,
        cpu: Double,
        gpu: Double
    ) {
        let values = statistics(window: window)
        return (values.totalMedian, values.cpuMedian, values.gpuMedian)
    }

    private func statistics(window: TimeInterval) -> (
        totalAverage: Double,
        totalMedian: Double,
        cpuMedian: Double,
        gpuMedian: Double,
        coverage: TimeInterval,
        highFraction: Double
    ) {
        guard let latestTimestamp = samples.last?.timestampNanoseconds else {
            return (0, 0, 0, 0, 0, 0)
        }

        let windowNanoseconds = UInt64(window * 1_000_000_000)
        let cutoff = latestTimestamp > windowNanoseconds
            ? latestTimestamp - windowNanoseconds
            : 0
        let relevantSamples = samples.filter { $0.timestampNanoseconds >= cutoff }
        let coverage = relevantSamples.reduce(0) { $0 + $1.duration }
        guard coverage > 0 else { return (0, 0, 0, 0, 0, 0) }

        let weightedTotalPower = relevantSamples.reduce(0) {
            $0 + $1.totalPowerWatts * $1.duration
        }
        let medianSample = weightedMedianSample(relevantSamples)
        let highDuration = relevantSamples.reduce(0) {
            $0 + ($1.totalPowerWatts >= Self.highSampleWatts ? $1.duration : 0)
        }
        return (
            totalAverage: weightedTotalPower / coverage,
            totalMedian: medianSample?.totalPowerWatts ?? 0,
            cpuMedian: medianSample?.cpuPowerWatts ?? 0,
            gpuMedian: medianSample?.gpuPowerWatts ?? 0,
            coverage: coverage,
            highFraction: highDuration / coverage
        )
    }

    private func weightedMedianSample(_ samples: [Sample]) -> Sample? {
        let sorted = samples.sorted { $0.totalPowerWatts < $1.totalPowerWatts }
        let totalDuration = sorted.reduce(0) { $0 + $1.duration }
        guard totalDuration > 0 else { return nil }

        let midpoint = totalDuration / 2
        var accumulatedDuration: TimeInterval = 0
        for sample in sorted {
            accumulatedDuration += sample.duration
            if accumulatedDuration >= midpoint {
                return sample
            }
        }
        return sorted.last
    }
}
