# Battery Hogger

Battery Hogger is an Apple-silicon-only macOS menu-bar utility that samples the kernel's per-process CPU-energy estimate and identifies unusually expensive processes.

## Architecture

- **BatteryHogger** is an unprivileged SwiftUI menu-bar app. It owns presentation, service registration, refresh timing, and eventually notifications and history.
- **BatteryHoggerMonitor** is a root LaunchDaemon registered with `SMAppService`. It owns process enumeration and read-only kernel metric collection.
- **Shared** contains the narrow `NSXPCConnection` contract and secure-coding transport model. Both peers enforce the other side's code-signing identity before exchanging messages.

The privileged service intentionally exposes no process mutation, filesystem access, shell execution, or arbitrary PID operations. It returns a single system snapshot so that authorization stays easy to audit.

## How energy usage is calculated

Battery Hogger does not copy Activity Monitor's undocumented, relative **Energy Impact** score. It reads the cumulative `ri_energy_nj` counter returned by macOS through:

```c
proc_pid_rusage(pid, RUSAGE_INFO_V6, ...)
```

On Apple silicon, this counter represents the kernel's estimated CPU energy attributed to a process, expressed in nanojoules. Battery Hogger samples the counter approximately every three seconds and computes the difference between consecutive samples of the same process instance:

```text
energy delta (nJ) = current counter - previous counter
elapsed time (ns) = current sample time - previous sample time
estimated CPU power (W) = energy delta / elapsed time
```

The final division works because one nanojoule per nanosecond is one joule per second, or one watt. A process instance is identified using its PID and launch time so that a reused PID is not compared with measurements from an older process.

The first observation only establishes a baseline. Battery Hogger needs a second observation before it can display a meaningful power rate.

### Application grouping

The intended top-level list represents applications or standalone workloads rather than every helper process:

- Processes associated with the same application bundle are grouped together.
- The application's displayed power is the sum of its own estimate and the estimates of its currently associated child/helper processes.
- Selecting an application reveals the individual contributing processes.
- A process that cannot be reliably associated with an application bundle remains a standalone process. It is not forced under `launchd`, `xpcproxy`, or another incidental system ancestor.

Grouping is conservative. Direct bundle membership takes precedence; otherwise, an unbundled process may inherit the bundle association of a same-user ancestor. Association stops at infrastructure boundaries such as `launchd`, `xpcproxy`, and `loginwindow`. If no reliable association is found, the process remains a standalone workload.

### Cumulative energy

Session energy is calculated by accumulating valid energy deltas while Battery Hogger is monitoring. Nanojoules are converted to watt-hours using:

```text
estimated CPU energy (Wh) = accumulated energy (nJ) / 3,600,000,000,000
```

This value means **estimated CPU energy observed since monitoring began**. It does not include energy consumed before Battery Hogger established its first baseline.

The application detail view shows both the workload's cumulative total and the contribution recorded for each currently running process. Contributions from a child that exits remain part of the workload session total, even though that child disappears from the current-process list.

### Sustained-hog detection

Battery Hogger prioritizes persistent consumption rather than reacting to a single spike. The current balanced detector uses duration-weighted samples and the following transparent rules:

- A workload becomes a candidate when its 30-second average reaches 1 W. Candidates receive an orange indicator.
- It becomes a sustained hog after at least 80 seconds of coverage in a 90-second window, when its average is at least 1.5 W and it spent at least 80% of the observed time at or above 1 W.
- Sustained hogs are sorted above other workloads and marked red.
- A sustained hog returns to normal only after remaining below 0.75 W for 60 consecutive seconds. This hysteresis prevents the row from repeatedly changing state near a threshold.

These thresholds describe sustained estimated CPU power, not whether the work is inherently unnecessary. A long compile, export, or indexing operation can be correctly identified as expensive even when the user intended it.

### Scope and limitations

- The measurement is an estimated CPU-energy attribution, not a direct reading from the battery.
- It does not represent total application energy from the GPU, display, networking hardware, storage, or other devices.
- Battery Hogger therefore labels values as **estimated CPU power** and **estimated CPU energy**, not battery percentage or Activity Monitor Energy Impact.
- Very short-lived processes can start and exit between samples and may not be observed.
- Rate baselines must be reset across sleep, wake, and other long sampling gaps.
- Process grouping is necessarily conservative: uncertain ownership is shown as a standalone process instead of potentially attributing it to the wrong application.

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
