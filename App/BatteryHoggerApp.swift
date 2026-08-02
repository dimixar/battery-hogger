import SwiftUI

@main
struct BatteryHoggerApp: App {
    @StateObject private var model = MonitorModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(model: model)
        } label: {
            Text("BH")
                .font(.system(size: 11, weight: .bold, design: .rounded))
        }
        .menuBarExtraStyle(.window)
    }
}
