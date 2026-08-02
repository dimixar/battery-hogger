import Foundation

struct WorkloadDetection: Sendable {
    let status: WorkloadStatus
    let rollingAveragePowerWatts: Double
}

struct WorkloadDetector: Sendable {
    private struct Sample: Sendable {
        let timestampNanoseconds: UInt64
        let duration: TimeInterval
        let powerWatts: Double
    }

    private static let candidateAverageWatts = 1.0
    private static let hogAverageWatts = 1.5
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
        powerWatts: Double,
        duration: TimeInterval,
        at timestampNanoseconds: UInt64
    ) -> WorkloadDetection {
        guard duration > 0, duration <= 15 else {
            prune(at: timestampNanoseconds)
            return WorkloadDetection(
                status: status,
                rollingAveragePowerWatts: weightedAverage(window: Self.hogWindow)
            )
        }

        samples.append(
            Sample(
                timestampNanoseconds: timestampNanoseconds,
                duration: duration,
                powerWatts: powerWatts
            )
        )
        prune(at: timestampNanoseconds)

        let hogStatistics = statistics(window: Self.hogWindow)
        let candidateAverage = weightedAverage(window: Self.candidateWindow)
        let qualifiesAsHog = hogStatistics.coverage >= Self.minimumHogCoverage
            && hogStatistics.average >= Self.hogAverageWatts
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
            rollingAveragePowerWatts: hogStatistics.average
        )
    }

    private mutating func prune(at timestampNanoseconds: UInt64) {
        let retentionNanoseconds = UInt64(Self.hogWindow * 1_000_000_000)
        let cutoff = timestampNanoseconds > retentionNanoseconds
            ? timestampNanoseconds - retentionNanoseconds
            : 0
        samples.removeAll { $0.timestampNanoseconds < cutoff }
    }

    private func weightedAverage(window: TimeInterval) -> Double {
        statistics(window: window).average
    }

    private func statistics(window: TimeInterval) -> (
        average: Double,
        coverage: TimeInterval,
        highFraction: Double
    ) {
        guard let latestTimestamp = samples.last?.timestampNanoseconds else {
            return (0, 0, 0)
        }

        let windowNanoseconds = UInt64(window * 1_000_000_000)
        let cutoff = latestTimestamp > windowNanoseconds
            ? latestTimestamp - windowNanoseconds
            : 0
        let relevantSamples = samples.filter { $0.timestampNanoseconds >= cutoff }
        let coverage = relevantSamples.reduce(0) { $0 + $1.duration }
        guard coverage > 0 else { return (0, 0, 0) }

        let weightedPower = relevantSamples.reduce(0) {
            $0 + $1.powerWatts * $1.duration
        }
        let highDuration = relevantSamples.reduce(0) {
            $0 + ($1.powerWatts >= Self.highSampleWatts ? $1.duration : 0)
        }
        return (
            average: weightedPower / coverage,
            coverage: coverage,
            highFraction: highDuration / coverage
        )
    }
}
