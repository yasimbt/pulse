# Pulse

A lightweight menu-bar system monitor for Apple Silicon Macs, built around power data, history and
low overhead.

Pulse shows CPU, memory, disk, network, battery, power and charger readings in the menu bar. Click an
item for charts, details and the busiest processes. It reads CPU and GPU watts, frequencies and
temperatures without an admin password, keeps 30 days of history, and records workload sessions with
throttling detection. With the panels closed it uses about 0.5% CPU and 25-40 MB of memory.

> **Status: v0.6.0, in development.** Milestones M0-M4 and M6 are done. M5 (ports and chargers) is
> built but waiting on hardware tests, and M7 (polish) is in progress. See [`SPEC.md`](SPEC.md) and
> the findings in [`docs/`](docs/).

## Features

**Menu bar**
- One item per module, or all of them in one compact item. Each module can show text, a sparkline,
  a bar or a gauge, in a colour you choose.
- Modules: CPU, memory, disk, network, battery, **power** (CPU+GPU watts) and **ports** (charger
  input, or ports in use).

**Panels** (click a menu-bar item)
- A 10-minute chart, details and the top 5 processes for each module. CPU shows every core, grouped
  into performance and efficiency cores.
- **Power:** whole-Mac, CPU, GPU and per-cluster watts with frequencies, energy since the Mac started
  and since the panel opened, chip, SSD and battery temperatures, and the top processes by energy.
  CPU and GPU watts match `sudo powermetrics` within about 1% under load.
- **Ports:** the charger's rating, every voltage it offers, the power actually drawn, and what's on
  each USB-C and MagSafe port, with a warning when the charger can't keep up.
- **Network:** which apps are using the network, while that tab is open.

**History** (History… in any panel)
- 30 days of every recorded metric on one timeline, with zoom, a scrubber, and a crosshair that shows
  every value and the busiest processes at that moment. Gaps for sleep are marked.

**Sessions** (Record in any panel, or ⌃⌥⌘R anywhere)
- Record a build, render or game, then see its duration, average and peak usage and watts, energy
  used, peak temperature, time spent throttled, and top processes. Throttled periods are shaded on
  the charts. Compare two sessions side by side; export as JSON or CSV.

**Alerts, rules and automation** (Settings)
- Notifications for a hot chip, swap growth, low disk space, battery health, sustained throttling and
  a charger that can't keep up, each with a cooldown so it doesn't repeat.
- Rules: on battery or in Low Power Mode, sample less often or hide modules.
- Shortcuts actions: Get Current Metrics, Start Pulse Session and Stop Pulse Session.
- A floating, click-through heads-up display for games and benchmarks (⌃⌥⌘H).
- An optional endpoint on this Mac only, for Prometheus or scripts: `http://127.0.0.1:9466/metrics`
  and `/metrics.json`.

**Privacy:** Pulse sends nothing off your Mac and needs no admin password. Its history stays in
`~/Library/Application Support/Pulse/`.

## Requirements

- A Mac with Apple Silicon (M1 or later). Intel Macs are not supported.
- macOS 14 Sonoma or later. Power readings without root are verified on an M5 with macOS 27; on
  other chips Pulse falls back to slower readings, or hides what it can't verify.
- To build: Xcode with Swift 6 (development uses Xcode 27.2 on macOS 27.2), plus
  [XcodeGen](https://github.com/yonaskolb/XcodeGen) and [SwiftLint](https://github.com/realm/SwiftLint):
  ```bash
  brew install xcodegen swiftlint
  ```
  If they aren't installed but [Nix](https://nixos.org) is, the Makefile runs them through Nix.

## Install

There's no download yet, so for now [build it from source](#build-and-run). Test builds will be
attached to the [Releases page](https://github.com/yasimbt/pulse/releases).

Those builds aren't signed with an Apple Developer ID, so macOS warns that it can't check them for
malware. To open one the first time:

1. Unzip the download and drag **Pulse** into your **Applications** folder.
2. Open Pulse. When macOS says it can't verify Pulse, click **Done**.
3. Open **System Settings → Privacy & Security**, scroll to **Security**, click **Open Anyway** next
   to the message about Pulse, enter your password, then click **Open Anyway** again.

Pulse appears at the top right of the screen and has no Dock icon. A welcome window explains where to
find it. If you can't see it, open **System Settings → Menu Bar** and make sure Pulse is allowed; on a
MacBook with a notch, try fewer modules or the single combined item.

To uninstall, quit Pulse (click it, then **Quit**), drag it from Applications to the Bin, and delete
`~/Library/Application Support/Pulse/` to remove its history.

## Build and run

```bash
git clone https://github.com/yasimbt/pulse.git
cd pulse
make run
```

`make run` generates the Xcode project, builds a Debug app into `build/`, and opens it. The Xcode
project (`Pulse.xcodeproj`) is generated from `project.yml` and isn't checked in; run `make generate`
to open it in Xcode.

| Command | What it does |
|---|---|
| `make build` | Generate the project and build a Debug app |
| `make run` | Build, then quit any running Pulse and open the new one |
| `make test` | Run the unit tests |
| `make lint` | Run SwiftLint |
| `make cli ARGS="..."` | Build and run `pulse-cli` |
| `make clean` | Delete `build/` and the generated project |

**Release builds.** The app is signed for local use only (an "ad hoc" signature, without an Apple
Developer account), and an optimised Release build with Apple's hardened runtime crashes at launch
with that signature. Build Release with the hardened runtime off:

```bash
xcodebuild -scheme Pulse -configuration Release -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/ ENABLE_HARDENED_RUNTIME=NO build
```

Details are in [`docs/signing.md`](docs/signing.md).

## Command line

`pulse-cli` ships inside the app and prints the same metrics, including power, frequencies and
temperatures:

```bash
/Applications/Pulse.app/Contents/MacOS/pulse-cli               # readable list
/Applications/Pulse.app/Contents/MacOS/pulse-cli --json        # JSON, SI units
/Applications/Pulse.app/Contents/MacOS/pulse-cli --prometheus  # Prometheus text format
/Applications/Pulse.app/Contents/MacOS/pulse-cli --watch 5     # repeat every 5 s
```

To type just `pulse-cli`, link it onto your `PATH`, for example
`ln -s /Applications/Pulse.app/Contents/MacOS/pulse-cli ~/.local/bin/pulse-cli`.

## Project layout

| Path | Contents |
|---|---|
| `Pulse/App/` | App startup, settings storage, shortcuts, notifications and Shortcuts actions |
| `Pulse/Features/` | Menu bar, panels, history, sessions, HUD and settings (SwiftUI and AppKit) |
| `PulseCore/Collectors/` | Readers for each data source: IOKit, IOReport, SMC, HID sensors, processes |
| `PulseCore/Analysis/` | Calculations and parsers: power, throttling, sessions, alerts, rules, export |
| `PulseCore/Store/` | The SQLite history (GRDB): downsampling, process snapshots, sessions |
| `PulseCore/Sharing/` | The localhost metrics endpoint |
| `PulseCLI/` | `pulse-cli`, which ships inside Pulse.app |
| `PulseCoreTests/` | Unit tests, many using data recorded from a real Mac in `Fixtures/` |
| `Tools/spikes/` | Small programs used to check a data source, or measure accuracy and cost |
| `docs/` | Findings and measurements from each milestone |
| `SPEC.md` | The product spec and milestone plan |
| `CLAUDE.md` | Instructions for Claude Code, which is used to develop Pulse |

PulseCore has no UI code, so the app, `pulse-cli` and the tests all share it.
