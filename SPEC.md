# Product Spec — "Pulse" (working name)
A native macOS menu-bar system monitor for Apple Silicon, built around **power data**, **history**, and **USB-C/Thunderbolt insight**.

> This document is the source of truth for Claude Code. Build milestone by milestone. Do not start a milestone until the previous one meets its acceptance criteria.

---

## 1. Positioning

**One-liner:** Know what your Mac did, how much power it took, and why it throttled.

**Market gap (from research, Nov 2026):**
- iStat Menus 7 (~$12 one-time) is the most complete app, but users dislike the weather upsell and the bloat.
- Stats (free, MIT) is popular. Its UI looks dated, it has a single maintainer, and it needs a privileged helper for SMC.
- Sensei ($29/yr) bundles monitoring with cleaner tools, which is too much for users who just want a monitor.
- macmon / mactop (CLI) expose Apple Silicon power (CPU/GPU/ANE/DRAM watts) without sudo. No polished GUI makes this its main feature.
- Accessibility (VoiceOver) is weak across the category.

**Principles**
1. Focused: no weather, no clock, no "RAM cleaner", no disk cleanup.
2. Low overhead: the app shows its own CPU/energy use and targets < 0.5% average CPU at a 1 s sample rate.
3. No admin password by default. Any privileged helper is optional and only needed for fan control.
4. One-time purchase model (business decision; not relevant to code).
5. Accessible: every value is readable by VoiceOver.

**Target user:** Apple Silicon developers, engineers, and power users who run builds, renders, and local LLMs.

---

## 2. Platform & Tech Stack

| Item | Choice | Notes |
|---|---|---|
| OS target | macOS 14 Sonoma+ (test on macOS 26) | Gives modern SwiftUI and `MenuBarExtra` |
| Hardware | Apple Silicon only (M1–M5) | No Intel support needed |
| Language | Swift 6, strict concurrency | |
| UI | SwiftUI (`MenuBarExtra` with `.window` style), AppKit only where needed | |
| Charts | Swift Charts | |
| Storage | SQLite via GRDB.swift (SPM) | Time-series history |
| Project generation | **XcodeGen** (`project.yml`) | Lets Claude Code edit a YAML file instead of `.xcodeproj`. Regenerate with `xcodegen generate` |
| Build | `xcodebuild` from the terminal | Xcode.app must be installed |
| Tests | Swift Testing (`@Test`) + XCTest where needed | |
| Lint/format | SwiftLint + swift-format (optional) | |
| Distribution | Direct download, Developer ID-signed and notarised. **Not the Mac App Store** at first | Power and temperature data need private IOKit/IOReport APIs that the App Store sandbox and review don't allow |
| App Sandbox | **Off** | Same reason |
| Dock icon | None (`LSUIElement = YES`) | Menu-bar-only app |
| Launch at login | `SMAppService.mainApp` | |

---

## 3. Architecture

```
Pulse/
├── project.yml                 # XcodeGen definition
├── CLAUDE.md
├── SPEC.md
├── Pulse/                      # App target
│   ├── App/                    # PulseApp.swift, AppDelegate, MenuBarExtra scenes
│   ├── Features/
│   │   ├── MenuBar/            # status item renderers (text, sparkline, bar, gauge)
│   │   ├── Panels/             # dropdown panels per module
│   │   ├── History/            # timeline window
│   │   ├── Sessions/           # workload recording
│   │   ├── Ports/              # USB-C / Thunderbolt inspector
│   │   └── Settings/
│   └── Resources/
├── PulseCore/                  # Swift package / framework: NO UI imports
│   ├── Collectors/             # one per metric source
│   ├── Sampling/               # Scheduler, ring buffers
│   ├── Store/                  # GRDB persistence, downsampling
│   ├── Analysis/               # throttling detection, session summaries
│   └── Models/
├── PulseCoreTests/
└── Tools/
    └── pulse-cli/              # later: CLI that uses PulseCore (JSON/Prometheus)
```

**Core rules**
- `PulseCore` must not import SwiftUI/AppKit, so it can also be used by the CLI and widgets.
- Every collector conforms to:
  ```swift
  protocol Collector: Sendable {
      associatedtype Sample: Sendable
      var id: MetricID { get }
      func sample() async throws -> Sample
  }
  ```
- A single `Sampler` actor drives every collector on one timer (default 1 s; user can choose 0.5–5 s). It coalesces work and publishes an immutable `Snapshot` through `AsyncStream`.
- The UI observes a `@MainActor @Observable` `LiveModel` that consumes the stream.
- Ring buffers hold the last 10 minutes in memory for sparklines. The Store writes to SQLite every 1 s and downsamples: raw for 1 h, 10 s averages for 24 h, 1 min averages for 30 days. Older data is pruned.
- Collectors fail soft: if a source isn't available on a given machine, the metric is hidden. The app must not crash.

---

## 4. Data Sources (investigate & verify on device)

| Metric | Likely source | Privilege | Notes |
|---|---|---|---|
| CPU usage per core, E/P clusters | `host_processor_info` (Mach) + `sysctl hw.perflevel*` | none | Use `hw.perflevel0/1` to map cores to clusters |
| CPU/GPU frequency, residency | IOReport (`libIOReport.dylib`, private) channels "CPU Stats", "GPU Stats" | none | See how macmon (Rust) and mactop (Go) do it |
| Power: CPU/GPU/ANE/DRAM watts | IOReport "Energy Model" group | none | Convert energy deltas to watts using the sample interval |
| System power (total) | SMC key `PSTR` or IOReport | none for reads | Verify on each chip |
| Temperatures | `IOHIDEventSystemClient` (private) and/or SMC keys | none for reads | Sensor names differ per chip, so keep a mapping table in JSON |
| Fans | SMC `F0Ac`, `F0Mx`, etc. | read: none; **write: privileged helper** | Fan control is in a later milestone |
| Memory, pressure, swap | `host_statistics64`, `vm.swapusage`, `kern.memorystatus_level` | none | |
| Disk I/O | IOKit `IOBlockStorageDriver` statistics | none | |
| Disk space | `URLResourceValues.volumeAvailableCapacityForImportantUsage` | none | |
| Network throughput | `getifaddrs` / `sysctl NET_RT_IFLIST2` | none | |
| Per-app network | `nettop -P -L 1 -J ...` subprocess at first; consider NetworkStatistics private framework later | none | Run at a lower rate (5 s) |
| Top processes CPU/mem | `proc_listpids` + `proc_pid_rusage` | none | Use `ri_energy_nj` / `ri_billed_energy` for per-app energy |
| Battery | IOKit `AppleSmartBattery` (`IOServiceGetMatchingService`) | none | Cycles, health, temp, voltage, amperage, `AdapterDetails` |
| USB-C PD / ports | IORegistry: `AppleSmartBattery` → `AdapterDetails`, `PowerTelemetryData`; port services (inspect with `ioreg -l -w0`, `ioreg -p IOUSB`, `system_profiler SPUSBDataType SPThunderboltDataType SPPowerDataType -json`) | none | **Spike required:** find out which PD fields (PDOs, negotiated V/I, cable e-marker) are exposed on Apple Silicon |
| Thermal state | `ProcessInfo.thermalState` + IOReport/SMC throttle signals | none | Used for throttling detection |

**Before writing a collector for any private API, write a tiny spike executable in `Tools/spikes/` that prints raw values. Confirm it works on the dev machine, then wrap it.**

---

## 5. Features by Milestone

### M0 — Project skeleton
- XcodeGen `project.yml` with targets: `Pulse` (app), `PulseCore` (framework), `PulseCoreTests`.
- `LSUIElement`, sandbox off, hardened runtime on, signing "Sign to Run Locally" for development.
- A `MenuBarExtra` that shows a static "Pulse" label and a Quit button.
- `make build`, `make test`, `make run` targets.

**Accept:** `make run` launches the app, an icon appears in the menu bar, and the app has no Dock icon.

### M1 — Core monitors (feature parity)
- Collectors: CPU (total + per core, E/P), memory (used, pressure, swap), disk (space + I/O), network (per interface up/down), battery.
- Menu-bar item renderers: text, sparkline, bar, gauge, plus a combined mode where one status item shows several metrics.
- A dropdown panel for each module with a 10-min chart and the top 5 processes. Include an "Open Activity Monitor" button.
- Settings: choose which modules appear, their order, renderer, sample rate, and colours. Launch at login.
- A self-overhead indicator in Settings that shows Pulse's own CPU %.

**Accept:** CPU readings stay within ±3% of Activity Monitor under load. Pulse averages < 0.5% CPU at a 1 s rate with 5 modules enabled.

### M2 — Apple Silicon power & thermals (differentiator #1)
- IOReport collector for CPU/GPU/ANE/DRAM watts, CPU/GPU frequency, and residency.
- Temperature collector with a per-chip sensor map (JSON resource).
- Fan RPM readout only.
- "Power" panel: live stacked watts chart, plus cumulative energy (Wh) since boot and since the panel was opened.
- Per-app energy ranking from `proc_pid_rusage` energy counters.

**Accept:** watts readings stay within ±10% of `sudo powermetrics` or macmon on the same workload.

### M3 — History & timeline (differentiator #2)
- GRDB store with downsampling and retention as described in §3, plus a migration system.
- History window: zoomable timeline for all metrics, a scrubber, and a crosshair that shows every value at time T.
- Store a top-processes snapshot every 10 s so "what spiked at 14:02?" can be answered.
- Survives restarts. Shows a gap marker for periods when the Mac was asleep or off.

**Accept:** the database stays below 200 MB after 30 days at default settings, and the timeline renders 24 h of data in < 300 ms.

### M4 — Workload sessions & throttling detection
- A Record button (in the menu-bar panel, with a global hotkey) starts and stops a session.
- Session summary: duration; peak and average CPU/GPU/ANE usage and watts; energy used (Wh); peak temperatures; throttling time; top processes.
- Throttling detector: flags intervals where frequency drops while load is high and temperature or thermal state is elevated. Shows them as bands on the charts.
- Compare two sessions side by side. Export sessions as JSON/CSV.

**Accept:** a 5-minute `stress`/build run produces a correct summary. A forced thermal load produces throttle bands.

### M5 — USB-C / Thunderbolt inspector (differentiator #3)
- Run the IORegistry spike first and document findings in `docs/ports-findings.md`.
- Ports panel: device tree for each physical port (USB/TB devices, link speed).
- Charger info: advertised wattage compared with actual input power, charging state, and negotiated voltage/current plus PDOs if the IORegistry exposes them.
- Alerts, e.g. "Charger is 30 W but the Mac is drawing 45 W — battery is draining" or "Device linked at USB 2 speed on a TB port".

**Accept:** correct readout with at least 2 different chargers and 1 dock/hub.

### M6 — Alerts, automation & export
- Threshold alerts: temperature, swap growth, low disk space, battery health, sustained throttling. Sent via `UserNotifications`, with cooldowns.
- Rules, e.g. "when on battery → reduce sample rate / hide GPU module".
- App Intents / Shortcuts actions: Get current metrics, Start/Stop session.
- Local HTTP endpoint (opt-in, localhost only) serving JSON and Prometheus text format.
- `pulse-cli` tool that uses PulseCore and supports `--json`, `--prometheus`, `--watch`.

### M7 — Polish & extras
- WidgetKit desktop/Notification Centre widgets that read from a shared App Group store.
- Floating HUD overlay (always on top, click-through) for benchmarking or gaming.
- Optional privileged helper (`SMAppService.daemon`) for fan control, with clear explanations for each permission.
- Multi-Mac: Bonjour discovery so one Mac can view another Pulse instance on the LAN.
- Full VoiceOver pass: every chart has an `accessibilityLabel` summary and the audio graphs API (`AXChartDescriptor`).
- Onboarding: explain the macOS 26 System Settings → Menu Bar permission and help users enable it.

### Explicitly out of scope
Weather, clocks/calendars, RAM "cleaning", disk cleanup, app uninstalling, ads, telemetry/analytics. The app sends **no data off the machine**.

---

## 6. Non-functional requirements
- **Performance:** < 0.5% average CPU and < 60 MB RSS with M1 features at a 1 s rate. Collectors run off the main thread, and the UI redraws at most once per sample.
- **Energy:** Pulse must not appear in the "Using Significant Energy" list.
- **Reliability:** a collector failure is never fatal. Errors are logged via `os.Logger` (subsystem `com.<you>.pulse`).
- **Privacy:** no network access except the opt-in LAN/localhost features.
- **Accessibility:** Dynamic Type where applicable, VoiceOver labels, and no colour-only signalling.
- **Testing:** pure parsing and maths functions (energy→watts, downsampling, throttle detection, PD parsing) have unit tests using recorded fixtures in `PulseCoreTests/Fixtures/`.

---

## 7. Open questions (decide later)
- Final name and bundle ID.
- Pricing and licence-key system (e.g. Paddle or Lemon Squeezy) for direct sales.
- Whether to add an App Store "Lite" build using only public APIs.
