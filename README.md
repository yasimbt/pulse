# Pulse

A lightweight menu-bar system monitor for Apple Silicon Macs.

Pulse shows CPU, memory, disk, network and battery in the menu bar, and opens a small panel with a
10-minute chart and the busiest processes when you click it. It aims to cost almost nothing to run:
under 0.5% CPU and about 25-40 MB of memory with the panel closed.

> **Status: v0.1.0, early development.** The core monitors (milestone M1) are done. Power,
> temperatures, history and USB-C details are planned next; see [`SPEC.md`](SPEC.md).

## What it does today

- **Menu bar:** one item per module, or all modules in one compact item. Each module can show
  text, a sparkline, a bar or a gauge, in the colour you choose.
- **Panels:** click an item for a 10-minute chart, details, and the top 5 processes. CPU shows
  every core, grouped into Super (performance) and Efficiency cores.
- **Network:** shows which apps are using the network, only while the Network tab is open.
- **Settings:** choose modules, order, style, colour and sample rate, and turn on Launch at Login.
  Settings also show Pulse's own CPU and memory use.
- **Privacy:** Pulse sends nothing off your Mac and needs no admin password.

## Requirements

- A Mac with Apple Silicon (M1 or later). Intel Macs are not supported.
- macOS 14 Sonoma or later.
- Xcode with Swift 6. Development uses Xcode 27.2 on macOS 27.2.
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) and, for linting,
  [SwiftLint](https://github.com/realm/SwiftLint). Install them with Homebrew:
  ```bash
  brew install xcodegen swiftlint
  ```
  If they aren't installed but [Nix](https://nixos.org) is, the Makefile runs them through Nix.

## Install (test build)

Pulse is not yet signed with an Apple Developer ID, so macOS warns that it can't check the app
for malware. These steps tell macOS you trust it. You only need them once.

1. Download `Pulse-0.1.0-arm64.zip` from the
   [Releases page](https://github.com/yasimbt/pulse/releases).
2. Double-click the zip to unzip it, then drag **Pulse** into your **Applications** folder.
3. Open Pulse from Applications. macOS says it can't verify Pulse: click **Done**.
4. Open **System Settings → Privacy & Security** and scroll down to **Security**. Next to the
   message that Pulse was blocked, click **Open Anyway**, enter your password, then click
   **Open Anyway** again.

Pulse appears in the menu bar at the top right of the screen; it has no Dock icon. If you can't see
it, check **System Settings → Menu Bar** and make sure Pulse is allowed. On a MacBook with a notch,
too many menu-bar items can push it out of sight.

To uninstall, quit Pulse (click it, then **Quit**) and drag it from Applications to the Bin.

A normal installer that opens without these steps is planned for a later version.

## Build and run

```bash
git clone git@github.com:yasimbt/pulse.git
cd pulse
make run
```

`make run` generates the Xcode project, builds a Debug app into `build/`, and opens it.

Pulse lives in the menu bar and has no Dock icon. To quit, click any Pulse item and choose
**Quit** in the panel.

The Xcode project (`Pulse.xcodeproj`) is generated from `project.yml` and is not checked in. Run
`make generate` if you want to open it in Xcode.

| Command | What it does |
|---|---|
| `make build` | Generate the project and build a Debug app |
| `make run` | Build, then quit any running Pulse and open the new one |
| `make test` | Run the unit tests |
| `make lint` | Run SwiftLint |
| `make clean` | Delete `build/` and the generated project |

### Release builds

The app is signed for local use only (an "ad hoc" signature, with no Apple Developer account).
An optimised Release build with Apple's hardened runtime crashes at launch with that signature.
Build Release locally with the hardened runtime turned off:

```bash
xcodebuild -scheme Pulse -configuration Release -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/ ENABLE_HARDENED_RUNTIME=NO build
```

Details are in [`docs/signing.md`](docs/signing.md). Test builds are attached to [GitHub Releases](https://github.com/yasimbt/pulse/releases).

## Project layout

| Path | Contents |
|---|---|
| `Pulse/` | The app: menu-bar items, panels and settings (SwiftUI and AppKit) |
| `PulseCore/` | Data collection and calculations, with no UI code |
| `PulseCoreTests/` | Unit tests, using data recorded from a real Mac in `Fixtures/` |
| `Tools/spikes/` | Small command-line programs used to check a data source before relying on it |
| `docs/` | Findings and measurements from each milestone |
| `SPEC.md` | The product spec and milestone plan |
| `CLAUDE.md` | Instructions for Claude Code, which is used to develop Pulse |

## Contributing

Commit messages follow [Conventional Commits](https://www.conventionalcommits.org):

```
<type>(<optional scope>): <summary in the imperative, lower case>
```

| Type | Use for |
|---|---|
| `feat` | A new feature |
| `fix` | A bug fix |
| `perf` | A performance improvement |
| `refactor` | A code change that neither fixes a bug nor adds a feature |
| `test` | Adding or changing tests |
| `docs` | Documentation only |
| `build` | The build system, `project.yml` or the Makefile |
| `chore` | Anything else, such as spikes or tooling |

For example: `feat(power): add GPU watts to the Power panel`. Commits made before v0.1.0 use
plain sentences.

Before sending a change, run `make test` and `make lint`.

Releases are tagged `vMAJOR.MINOR.PATCH`. Each milestone in `SPEC.md` gets a minor version:
M1 is v0.1.0, M2 will be v0.2.0, and so on.
