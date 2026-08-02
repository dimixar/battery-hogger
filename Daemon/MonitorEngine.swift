import Foundation

final class MonitorEngine: @unchecked Sendable {
    private let sampler = ProcessSampler()
    private let analyzer = WorkloadAnalyzer()
    private let lock = NSLock()

    func snapshot() -> MonitorSnapshot {
        lock.withLock {
            analyzer.analyze(sampler.sample())
        }
    }
}
