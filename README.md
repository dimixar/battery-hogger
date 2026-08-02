# Battery Hogger

Battery Hogger is an Apple-silicon-only macOS menu-bar utility that samples the kernel's per-process CPU-energy estimate and identifies unusually expensive processes.

## Architecture

- **BatteryHogger** is an unprivileged SwiftUI menu-bar app. It owns presentation, service registration, refresh timing, and eventually notifications and history.
- **BatteryHoggerMonitor** is a root LaunchDaemon registered with `SMAppService`. It owns process enumeration and read-only kernel metric collection.
- **Shared** contains the narrow `NSXPCConnection` contract and secure-coding transport model. Both peers enforce the other side's code-signing identity before exchanging messages.

The privileged service intentionally exposes no process mutation, filesystem access, shell execution, or arbitrary PID operations. It returns a single system snapshot so that authorization stays easy to audit.

## Requirements

- Apple silicon
- macOS 13 or later
- Xcode 26 or later
- A real Apple Development signing identity for `SMAppService` registration

## Running

Build and package from Terminal:

```bash
./scripts/build-app.sh
```

The script creates `dist/BatteryHogger.app` and `dist/BatteryHogger.zip`. It automatically uses the first available code-signing identity. You can select one explicitly:

```bash
./scripts/build-app.sh --identity "Apple Development: Your Name (TEAMID)"
```

If no signing identity is installed, the script produces an ad-hoc-signed build. That build is useful for UI testing, but macOS may reject privileged LaunchDaemon registration. Install an Apple Development or Developer ID Application certificate and rebuild for the complete workflow.

Alternatively, open `BatteryHogger.xcodeproj`, select your development team for both targets, and build the `BatteryHogger` scheme.

After building:

1. Move `BatteryHogger.app` to `/Applications`.
2. Launch it and choose **Install Monitor** from the menu-bar panel.
3. Approve the daemon under **System Settings → General → Login Items & Extensions** if macOS requests it.

The first snapshot establishes cumulative-counter baselines. Power and rate values appear on the following refresh, approximately three seconds later.
