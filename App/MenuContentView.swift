import ServiceManagement
import SwiftUI

struct MenuContentView: View {
    @ObservedObject var model: MonitorModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if model.serviceStatus != .enabled {
                serviceSetup
            } else if model.topProcesses.isEmpty {
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
            } else {
                processList
            }

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
        .frame(width: 430)
        .task { model.start() }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Battery Hogger")
                    .font(.headline)
                Text("Apple silicon process energy")
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
            Text("Approve the read-only system monitor to inspect energy counters for every process.")
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

    private var processList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(model.topProcesses, id: \ProcessSnapshot.processIdentifier) { process in
                    ProcessRow(process: process)
                    Divider()
                }
            }
        }
        .frame(height: 420)
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

private struct ProcessRow: View {
    let process: ProcessSnapshot

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(process.name)
                    .lineLimit(1)
                Text("PID \(process.processIdentifier) · parent \(process.parentProcessIdentifier)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text(process.cpuPowerWatts, format: .number.precision(.fractionLength(3)))
                    .monospacedDigit()
                Text("W CPU estimate")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .help(helpText)
    }

    private var helpText: String {
        let path = process.executablePath ?? "Path unavailable"
        return """
        \(path)
        Launched: \(process.launchDate.formatted())
        CPU: \(process.cpuPercentage.formatted(.number.precision(.fractionLength(1))))%
        Wakeups: \(process.interruptWakeupsPerSecond.formatted(.number.precision(.fractionLength(1))))/s
        """
    }
}
