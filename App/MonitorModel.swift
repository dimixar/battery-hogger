import Combine
import Foundation
import ServiceManagement

@MainActor
final class MonitorModel: ObservableObject {
    @Published private(set) var processes: [ProcessSnapshot] = []
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

    var topProcesses: [ProcessSnapshot] {
        Array(processes.prefix(20))
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
            processes = []
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
            processes = try await client.fetchProcessSnapshot()
            lastUpdated = Date()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            client.invalidate()
        }
    }
}
