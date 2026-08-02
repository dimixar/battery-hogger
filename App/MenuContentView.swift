import ServiceManagement
import SwiftUI

struct MenuContentView: View {
    @ObservedObject var model: MonitorModel
    @State private var selectedWorkloadIdentifier: String?

    private var selectedWorkload: WorkloadSnapshot? {
        guard let selectedWorkloadIdentifier else { return nil }
        return model.workloads.first { $0.identifier == selectedWorkloadIdentifier }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content

            if let errorMessage = model.errorMessage {
                Divider()
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }

            Divider()
            footer
        }
        .frame(width: 460)
        .task { model.start() }
    }

    @ViewBuilder
    private var content: some View {
        if model.serviceStatus != .enabled {
            serviceSetup
        } else if let selectedWorkload {
            WorkloadDetailView(workload: selectedWorkload)
        } else if model.topWorkloads.isEmpty {
            collectingPlaceholder
        } else {
            workloadList
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            if selectedWorkload != nil {
                Button {
                    selectedWorkloadIdentifier = nil
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.plain)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(selectedWorkload?.displayName ?? "Battery Hogger")
                    .font(.headline)
                    .lineLimit(1)
                Text(selectedWorkload == nil ? "Estimated CPU + GPU power by workload" : "Workload details")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.isLoading {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(12)
    }

    private var serviceSetup: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Privileged monitor is not active", systemImage: "lock.shield")
                .font(.headline)
            Text("Approve the read-only system monitor to inspect CPU and GPU energy counters.")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack {
                Button("Install Monitor") {
                    model.registerDaemon()
                }
                .buttonStyle(.borderedProminent)

                if model.serviceStatus == .requiresApproval {
                    Button("Open Login Items") {
                        model.openLoginItemsSettings()
                    }
                }
            }
        }
        .padding(16)
        .frame(minHeight: 180)
    }

    private var collectingPlaceholder: some View {
        VStack(spacing: 10) {
            Image(systemName: "bolt.badge.clock")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Collecting Energy Data")
                .font(.headline)
            Text("The first useful sample takes a few seconds.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 220)
    }

    private var workloadList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(model.topWorkloads, id: \WorkloadSnapshot.identifier) { workload in
                    Button {
                        selectedWorkloadIdentifier = workload.identifier
                    } label: {
                        WorkloadRow(workload: workload)
                    }
                    .buttonStyle(.plain)
                    Divider()
                }
            }
        }
        .frame(height: 440)
    }

    private var footer: some View {
        HStack {
            if let lastUpdated = model.lastUpdated {
                Text("Updated \(lastUpdated, style: .relative) ago")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                Button("Refresh") {
                    Task { await model.refresh() }
                }
                Button("Open Login Items Settings") {
                    model.openLoginItemsSettings()
                }
                Divider()
                Button("Remove Privileged Monitor", role: .destructive) {
                    model.unregisterDaemon()
                }
                Button("Quit Battery Hogger") {
                    NSApplication.shared.terminate(nil)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(10)
    }
}

private struct WorkloadRow: View {
    let workload: WorkloadSnapshot

    var body: some View {
        HStack(spacing: 10) {
            statusIndicator
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(workload.displayName)
                        .lineLimit(1)
                    if workload.status == .sustainedHog {
                        Text("SUSTAINED")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.red)
                    }
                }
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text(workload.currentPowerWatts, format: .number.precision(.fractionLength(3)))
                    .monospacedDigit()
                    .foregroundStyle(workload.status == .sustainedHog ? .red : .primary)
                Text("W total estimate")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(componentSummary)
                    .font(.system(size: 9).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(backgroundColor)
        .contentShape(Rectangle())
    }

    private var subtitle: String {
        let processCount = workload.processes.count
        let kind: String
        if workload.bundleIdentifier != nil {
            kind = "Application"
        } else {
            kind = processCount == 1 ? "Standalone process" : "Process group"
        }
        return "\(kind) · \(processCount) process\(processCount == 1 ? "" : "es")"
    }

    private var componentSummary: String {
        let cpu = workload.currentCPUPowerWatts.formatted(
            .number.precision(.fractionLength(2))
        )
        guard workload.isGPUEnergyAvailable else {
            return "CPU \(cpu) · GPU unavailable"
        }
        let gpu = workload.currentGPUPowerWatts.formatted(
            .number.precision(.fractionLength(2))
        )
        return "CPU \(cpu) · GPU \(gpu)"
    }

    @ViewBuilder
    private var statusIndicator: some View {
        switch workload.status {
        case .normal:
            Circle().fill(.clear).frame(width: 7, height: 7)
        case .candidate:
            Circle().fill(.orange).frame(width: 7, height: 7)
        case .sustainedHog:
            Circle().fill(.red).frame(width: 7, height: 7)
        }
    }

    private var backgroundColor: Color {
        workload.status == .sustainedHog ? .red.opacity(0.10) : .clear
    }
}

private struct WorkloadDetailView: View {
    let workload: WorkloadSnapshot

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if workload.status == .sustainedHog {
                    Label("Sustained high estimated power use", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.red)
                }

                metrics

                VStack(alignment: .leading, spacing: 4) {
                    Text("Observed since")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(workload.monitoredSince.formatted(date: .abbreviated, time: .standard))
                        .font(.callout)
                    if let bundleIdentifier = workload.bundleIdentifier {
                        Text(bundleIdentifier)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()
                Text("Contributing processes")
                    .font(.headline)

                LazyVStack(spacing: 0) {
                    ForEach(workload.processes, id: \ProcessSnapshot.processIdentifier) { process in
                        ProcessDetailRow(process: process)
                        Divider()
                    }
                }
            }
            .padding(14)
        }
        .frame(height: 440)
    }

    private var metrics: some View {
        VStack(alignment: .leading, spacing: 10) {
            MetricSection(
                title: "Current estimate",
                unit: "W",
                total: workload.currentPowerWatts,
                cpu: workload.currentCPUPowerWatts,
                gpu: workload.currentGPUPowerWatts,
                gpuAvailable: workload.isGPUEnergyAvailable,
                fractionLength: 3
            )
            MetricSection(
                title: "90-second average",
                unit: "W",
                total: workload.rollingAveragePowerWatts,
                cpu: workload.rollingAverageCPUPowerWatts,
                gpu: workload.rollingAverageGPUPowerWatts,
                gpuAvailable: workload.isGPUEnergyAvailable,
                fractionLength: 3
            )
            MetricSection(
                title: "Session energy",
                unit: "Wh",
                total: workload.cumulativeEnergyWattHours,
                cpu: workload.cumulativeCPUEnergyWattHours,
                gpu: workload.cumulativeGPUEnergyWattHours,
                gpuAvailable: workload.isGPUEnergyAvailable,
                fractionLength: 6
            )
        }
    }
}

private struct MetricSection: View {
    let title: String
    let unit: String
    let total: Double
    let cpu: Double
    let gpu: Double
    let gpuAvailable: Bool
    let fractionLength: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                MetricCard(title: "Total", value: formatted(total), unit: unit)
                MetricCard(title: "CPU", value: formatted(cpu), unit: unit)
                MetricCard(
                    title: "GPU",
                    value: gpuAvailable ? formatted(gpu) : "—",
                    unit: gpuAvailable ? unit : ""
                )
            }
        }
    }

    private func formatted(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(fractionLength)))
    }
}

private struct MetricCard: View {
    let title: String
    let value: String
    let unit: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.callout.monospacedDigit())
                Text(unit)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background(.quaternary.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct ProcessDetailRow: View {
    let process: ProcessSnapshot

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(process.name)
                        .lineLimit(1)
                    if process.isWorkloadRoot {
                        Text("ROOT")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                }
                Text("PID \(process.processIdentifier) · parent \(process.parentProcessIdentifier)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text("\(process.cpuPowerWatts.formatted(.number.precision(.fractionLength(3)))) W CPU")
                    .font(.callout.monospacedDigit())
                Text("\(process.cumulativeEnergyWattHours.formatted(.number.precision(.fractionLength(6)))) Wh CPU")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 8)
        .help(helpText)
    }

    private var helpText: String {
        let path = process.executablePath ?? "Path unavailable"
        return """
        \(path)
        Launched: \(process.launchDate.formatted())
        CPU: \(process.cpuPercentage.formatted(.number.precision(.fractionLength(1))))%
        Resource coalition: \(process.resourceCoalitionIdentifier == 0 ? "Unavailable" : String(process.resourceCoalitionIdentifier))
        Wakeups: \(process.interruptWakeupsPerSecond.formatted(.number.precision(.fractionLength(1))))/s
        """
    }
}
