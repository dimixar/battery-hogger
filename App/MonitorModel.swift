import Combine
import Foundation
import ServiceManagement

@MainActor
final class MonitorModel: ObservableObject {
    private enum MenuBarThreshold {
        static let activeWatts = 2.0
        static let hotWatts = 10.0
    }

    @Published private(set) var workloads: [WorkloadSnapshot] = []
    @Published private(set) var systemPower: SystemPowerSnapshot?
    @Published private(set) var serviceStatus: SMAppService.Status
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var errorMessage: String?
    @Published private(set) var isLoading = false

    private let client = MonitorClient()
    private let service = SMAppService.daemon(plistName: MonitorConstants.daemonPlistName)
    private var refreshTask: Task<Void, Never>?

    init() {
        serviceStatus = service.status
    }

    var topWorkloads: [WorkloadSnapshot] {
        Array(workloads.prefix(30))
    }

    var menuBarLabel: String {
        guard let totalPowerWatts = systemPower?.totalPowerWatts else {
            return "⚡️"
        }
        if totalPowerWatts >= MenuBarThreshold.hotWatts {
            return "⚡️⚡️🔥"
        }
        if totalPowerWatts >= MenuBarThreshold.activeWatts {
            return "⚡️⚡️"
        }
        return "⚡️"
    }

    var menuBarHelp: String {
        guard let totalPowerWatts = systemPower?.totalPowerWatts else {
            return "Battery Hogger is waiting for a power sample."
        }
        return "Battery Hogger total: \(totalPowerWatts.formatted(.number.precision(.fractionLength(2)))) W"
    }

    func start() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    func stop() {
        refreshTask?.cancel()
        refreshTask = nil
        client.invalidate()
    }

    func registerDaemon() {
        do {
            try service.register()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        updateServiceStatus()
    }

    func unregisterDaemon() {
        do {
            try service.unregister()
            client.invalidate()
            workloads = []
            systemPower = nil
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        updateServiceStatus()
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    func updateServiceStatus() {
        serviceStatus = service.status
    }

    func refresh() async {
        updateServiceStatus()
        guard serviceStatus == .enabled else { return }

        isLoading = true
        defer { isLoading = false }

        do {
            let snapshot = try await client.fetchMonitorSnapshot()
            workloads = snapshot.workloads
            systemPower = snapshot.systemPower
            lastUpdated = Date()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            client.invalidate()
        }
    }
}
