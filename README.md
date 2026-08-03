# Battery Hogger

Battery Hogger is an Apple-silicon-only macOS menu-bar utility that combines the kernel's CPU- and GPU-energy estimates and identifies unusually expensive application workloads.

Its menu-bar label reflects current reconciled system power: `⚡️` below 2 W or while waiting for data, `⚡️⚡️` from 2 W up to 10 W, and `⚡️⚡️🔥` at 10 W or above.

## Architecture

- **BatteryHogger** is an unprivileged SwiftUI menu-bar app. It owns presentation, service registration, refresh timing, and eventually notifications and history.
- **BatteryHoggerMonitor** is a root LaunchDaemon registered with `SMAppService`. It owns process enumeration, per-process CPU sampling, CPU-package energy sampling, and resource-coalition GPU sampling.
- **Shared** contains the narrow `NSXPCConnection` contract and secure-coding transport model. Both peers enforce the other side's code-signing identity before exchanging messages.

The privileged service intentionally exposes no process mutation, filesystem access, shell execution, or arbitrary PID operations. It returns a single system snapshot so that authorization stays easy to audit.

## How energy usage is calculated

Battery Hogger does not copy Activity Monitor's undocumented, relative **Energy Impact** score. Its displayed total is the sum of independently sampled CPU and GPU energy estimates.

### CPU energy

The cumulative CPU counter comes from:

```c
proc_pid_rusage(pid, RUSAGE_INFO_V6, ...)
```

On Apple silicon, this counter represents the kernel's estimated CPU energy attributed to a process, expressed in nanojoules. Battery Hogger samples the counter approximately every three seconds and computes the difference between consecutive samples of the same process instance:

```text
energy delta (nJ) = current counter - previous counter
elapsed time (ns) = current sample time - previous sample time
estimated CPU power (W) = CPU energy delta / elapsed time
```

The final division works because one nanojoule per nanosecond is one joule per second, or one watt. A process instance is identified using its PID and launch time so that a reused PID is not compared with measurements from an older process.

### Package power and residuals

Per-process Recount energy does not add up to the complete CPU-package estimate reported by `powermetrics`, and coalition GPU energy may similarly leave package GPU power unattributed. Battery Hogger therefore also samples the private libIOReport **Energy Model** channels for CPU, GPU, DRAM, Neural Engine, and PCIe energy, converts their cumulative joules into watts, and calculates:

```text
CPU residual (W) = max(CPU package power - directly attributed CPU power, 0)
GPU residual (W) = max(GPU package power - coalition-attributed GPU power, 0)
Other SoC (W) = DRAM power + Neural Engine power + PCIe power
Tracked Total (W) = CPU Direct + CPU Residual + GPU Direct + GPU Residual + Other SoC
```

The overview exposes both residuals as their own cards; they are never assigned to an application or used to inflate per-process values. Workload rows and sustained-hog detection continue to use directly attributed CPU plus coalition-attributed GPU power. If an undocumented package channel is unavailable, its card reports unavailable and Tracked Total falls back to the directly attributed value for that domain.

### GPU energy

macOS accounts GPU energy per **resource coalition**, the kernel grouping used to represent a related application or `launchd` job. Battery Hogger first obtains a process's resource-coalition ID with the private `PROC_PIDCOALITIONINFO` flavor of `proc_pidinfo`, then reads the coalition's cumulative counters through the exported but undocumented function:

```c
coalition_info_resource_usage(coalition_id, ...)
```

The relevant result is `gpu_energy_nj`, which XNU documents as nanojoules reported to the resource coalition by the GPU driver. Battery Hogger samples each distinct coalition only once, even when many visible processes belong to it:

```text
estimated GPU power (W) = GPU energy delta (nJ) / elapsed time (ns)
estimated total power (W) = estimated CPU power + estimated GPU power
```

The `gpu_energy_nj_billed_to_me` and `gpu_energy_nj_billed_to_others` counters are collected by the kernel but are not currently included in hog detection. Raw GPU energy is monotonic and better suited to sustained physical-work detection; billed attribution can be delivered later and cause abrupt or temporarily negative interval adjustments.

The GPU fields were appended to the coalition structure in XNU 11215, corresponding to macOS 15. On macOS 13 and 14, Battery Hogger continues with CPU-only monitoring and reports GPU as unavailable. The coalition interface is private API: Battery Hogger resolves its symbol at runtime and treats it as optional, so CPU monitoring also continues if a later macOS update removes or changes it. The implementation is isolated in `Daemon/CoalitionGPUEnergyReader.swift` and must be checked against each major macOS release.

The first CPU or GPU observation only establishes a baseline. Battery Hogger needs a second observation before it can display a meaningful rate.

### Application grouping

The intended top-level list represents applications or standalone workloads rather than every helper process:

- Processes associated with the same application bundle or its resource coalition are grouped together.
- The application's displayed CPU power is the sum of its own estimate and the estimates of its currently associated child/helper processes.
- Its displayed GPU power is the sum of the distinct resource coalitions owned by that application group. A coalition is never counted twice.
- Its displayed total watts are directly attributed CPU watts plus coalition-attributed GPU watts. CPU and GPU package residuals and Other SoC remain system-level and are not assigned to a workload.
- Selecting an application reveals the individual contributing processes.
- Processes without bundle ownership are grouped by resource coalition when available. Otherwise, they remain standalone processes. They are not forced under `launchd`, `xpcproxy`, or another incidental system ancestor.

Grouping is conservative. Direct bundle membership takes precedence. When a resource coalition has one unambiguous same-user application owner, unbundled XPC services in that coalition inherit the application's association. Otherwise, an unbundled process may inherit the bundle association of a same-user ancestor. Association stops at infrastructure boundaries such as `launchd`, `xpcproxy`, and `loginwindow`. If no reliable association is found, the process remains a standalone workload.

### Cumulative energy

Session energy is calculated by accumulating valid CPU and GPU energy deltas while Battery Hogger is monitoring. Nanojoules are converted to watt-hours using:

```text
estimated component energy (Wh) = accumulated component energy (nJ) / 3,600,000,000,000
estimated total energy (Wh) = CPU energy (Wh) + GPU energy (Wh)
```

This value means **estimated CPU and GPU energy observed since monitoring began**. It does not include energy consumed before Battery Hogger established its first baselines.

The application detail view shows current, duration-weighted 90-second median, and session-cumulative values split into total, CPU, and GPU components. The median is the total-power sample at which half of the observed duration was at or below that value and half was at or above it, which prevents brief spikes from dominating the displayed sustained level. Its CPU and GPU cards show the components from that same sample, so they add up to the displayed median total. The child-process list remains CPU-only because macOS exposes GPU energy at coalition granularity rather than per process. Contributions from a child that exits remain part of the workload session total, even though that child disappears from the current-process list.

### Sustained-hog detection

Battery Hogger prioritizes persistent consumption rather than reacting to a single spike. The current balanced detector uses duration-weighted samples and the following transparent rules:

- A workload becomes a candidate when its 30-second average reaches 1 W. Candidates receive an orange indicator.
- It becomes a sustained hog after at least 80 seconds of coverage in a 90-second window, when its duration-weighted median is at least 1.5 W and it spent at least 80% of the observed time at or above 1 W.
- Sustained hogs are sorted above other workloads and marked red.
- A sustained hog returns to normal only after remaining below 0.75 W for 60 consecutive seconds. This hysteresis prevents the row from repeatedly changing state near a threshold.

These thresholds are evaluated against combined estimated CPU plus GPU power, not whether the work is inherently unnecessary. A long compile, export, game, or indexing operation can be correctly identified as expensive even when the user intended it.

### Scope and limitations

- CPU and GPU measurements are kernel/driver estimates, not direct readings from the battery.
- Tracked Total includes CPU and GPU package power plus the available DRAM, Neural Engine, and PCIe energy-model domains. It does not include the display, networking hardware, storage devices, fans, voltage-regulator losses, or other unreported domains, so it is not whole-machine power.
- GPU energy is available only per resource coalition. Individual child-process rows show CPU values and must not be interpreted as per-process GPU attribution.
- The GPU interface is undocumented and may stop working after a macOS update. The UI explicitly shows GPU as unavailable when the optional query fails.
- The package libIOReport interface is also undocumented and may change. The UI explicitly marks unavailable residual or Other SoC cards and falls back safely when a domain cannot be sampled.
- Battery Hogger therefore labels values as **estimated power** and **estimated energy**, not battery percentage or Activity Monitor Energy Impact.
- Very short-lived processes can start and exit between samples and may not be observed.
- Rate baselines must be reset across sleep, wake, and other long sampling gaps.
- Process grouping is necessarily conservative: uncertain ownership is shown as a standalone process instead of potentially attributing it to the wrong application.

## Requirements

- Apple silicon
- macOS 13 or later
- macOS 15 or later for coalition GPU-energy readings; macOS 13 and 14 operate in CPU-only mode
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

## Validating CPU attribution

The repository includes a diagnostic probe that compares the sum of the same per-process `ri_energy_nj` deltas used by Battery Hogger with the package-level **CPU Power** estimate reported by `powermetrics` over synchronized intervals:

```bash
./scripts/compare-powermetrics.sh
```

The script requests administrator access because `powermetrics` is root-only. Its output reports directly attributed CPU power, Battery Hogger's libIOReport CPU-package reading, the `powermetrics` CPU reading, and the IOReport/`powermetrics` ratio for ten three-second samples. The package readings should closely agree; a directly attributed/package ratio below 100% is expected because the two counters do not have identical attribution boundaries. Processes that start and exit entirely between observations also cannot produce a per-process delta. The comparison is intended to reveal scale errors and consistent bias, not to prove that either estimate equals battery power.

An optional third argument starts a controlled number of CPU load workers after authorization and stops them automatically when sampling ends. For example, this collects twenty samples with eight workers:

```bash
./scripts/compare-powermetrics.sh 20 3000 8
```

If no signing identity is installed, the script produces an ad-hoc-signed build. That build is useful for UI testing, but macOS may reject privileged LaunchDaemon registration. Install an Apple Development or Developer ID Application certificate and rebuild for the complete workflow.

Alternatively, open `BatteryHogger.xcodeproj`, select your development team for both targets, and build the `BatteryHogger` scheme.

After building:

1. Move `BatteryHogger.app` to `/Applications`.
2. Launch it and choose **Install Monitor** from the menu-bar panel.
3. Approve the daemon under **System Settings → General → Login Items & Extensions** if macOS requests it.

The first snapshot establishes cumulative-counter baselines. Power and rate values appear on the following refresh, approximately three seconds later.
