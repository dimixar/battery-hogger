import Foundation

enum MonitorConstants {
    static let appBundleIdentifier = "com.molosnicdumitru.BatteryHogger"
    static let daemonBundleIdentifier = "com.molosnicdumitru.BatteryHogger.Monitor"
    static let daemonLabel = "com.molosnicdumitru.BatteryHogger.Monitor"
    static let daemonPlistName = "com.molosnicdumitru.BatteryHogger.Monitor.plist"

    #if ADHOC_SIGNING
    // Ad-hoc builds are for local UI and transport testing. Rebuild with an
    // Apple-issued identity before relying on the privileged service boundary.
    static let appCodeSigningRequirement = "identifier \"\(appBundleIdentifier)\""
    static let daemonCodeSigningRequirement = "identifier \"\(daemonBundleIdentifier)\""
    #else
    static let appCodeSigningRequirement =
        "anchor apple generic and identifier \"\(appBundleIdentifier)\""
    static let daemonCodeSigningRequirement =
        "anchor apple generic and identifier \"\(daemonBundleIdentifier)\""
    #endif
}
