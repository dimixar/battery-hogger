import SwiftUI

@main
struct BatteryHoggerApp: App {
    @StateObject private var model = MonitorModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(model: model)
        } label: {
            Text(model.menuBarLabel)
                .accessibilityLabel(model.menuBarHelp)
                .help(model.menuBarHelp)
                .task { model.start() }
        }
        .menuBarExtraStyle(.window)
    }
}
