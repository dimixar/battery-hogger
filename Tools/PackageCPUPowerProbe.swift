import Foundation

@main
enum PackageCPUPowerProbe {
    static func main() {
        let reader = PackageCPUEnergyReader()
        guard reader.isAvailable, let baseline = reader.cumulativeEnergyJoules() else {
            print("Package CPU energy is unavailable.")
            return
        }

        let startedAt = DispatchTime.now().uptimeNanoseconds
        let baselineChannels = Dictionary(
            uniqueKeysWithValues: reader.cumulativeEnergyChannels().map { ($0.name, $0.joules) }
        )
        Thread.sleep(forTimeInterval: 3)
        let finishedAt = DispatchTime.now().uptimeNanoseconds
        guard
            let current = reader.cumulativeEnergyJoules(),
            current >= baseline,
            finishedAt > startedAt
        else {
            print("Unable to calculate package CPU power.")
            return
        }

        let duration = Double(finishedAt - startedAt) / 1_000_000_000
        print(String(format: "IOReport CPU Power: %.3f W", (current - baseline) / duration))
        guard CommandLine.arguments.contains("--channels") else { return }
        for channel in reader.cumulativeEnergyChannels() {
            guard let previous = baselineChannels[channel.name], channel.joules >= previous else {
                continue
            }
            print(
                String(
                    format: "  %-28s %.3f W",
                    (channel.name as NSString).utf8String!,
                    (channel.joules - previous) / duration
                )
            )
        }
    }
}
