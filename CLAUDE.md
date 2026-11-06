# CLAUDE.md — instructions for Claude Code

You are building **Pulse**, a native macOS menu-bar system monitor for Apple Silicon. The full product spec is in `SPEC.md`; read it before doing anything.

## About the developer
- Experienced hardware/embedded engineer (Rust, C, PCB design) who is **new to macOS/Swift/Xcode**.
- When you introduce an Apple-specific concept (signing, entitlements, IOKit, SwiftUI scenes, `@Observable`), explain it in one or two plain sentences in your reply.
- Prefer terminal workflows. Only ask the developer to open Xcode.app when a task genuinely needs it (e.g. first-time signing setup, Instruments profiling) and say exactly what to click.

## Workflow rules
1. Work **one milestone at a time** (M0 → M7 in SPEC.md). At the end of each milestone, run the build and tests, then list what you verified against the acceptance criteria.
2. Never edit `Pulse.xcodeproj` by hand. Edit `project.yml` and run `xcodegen generate`. `Pulse.xcodeproj` is git-ignored.
3. For any private or undocumented API (IOReport, IOHIDEventSystemClient, SMC, IORegistry port data), **write a spike first** in `Tools/spikes/<name>/` (a small Swift command-line executable) that prints raw values. Show the output, then build the collector.
4. Keep `PulseCore` free of SwiftUI/AppKit imports.
5. Add unit tests for every parser and calculation, using recorded fixtures.
6. Commit after each working step. Use Conventional Commits (`feat:`, `fix:`, `perf:`, `refactor:`, `test:`, `docs:`, `build:`, `chore:`, with an optional scope such as `feat(power):`). Summary in the imperative, lower case. Run `make test` and `make lint` before committing. Don't commit build products.
7. If something can't be done (an API isn't exposed on this chip), document it in `docs/` and hide the feature rather than faking data.
8. Tag each accepted milestone: M1 is `v0.1.0`, M2 is `v0.2.0`, and so on.

## Commands
```bash
brew install xcodegen swiftlint     # one-time (the Makefile falls back to Nix if missing)
xcodegen generate                   # regenerate project after editing project.yml
make build                          # xcodebuild -scheme Pulse -configuration Debug build
make test                           # xcodebuild test -scheme PulseCoreTests
make run                            # build then open the .app from DerivedData
make lint                           # swiftlint
```
Create the `Makefile` in M0 to wrap these. Use `-derivedDataPath build/` so paths are predictable.

## Conventions
- Swift 6, strict concurrency, `async/await`, actors for shared mutable state.
- `@Observable` models on `@MainActor` for UI. No Combine unless unavoidable.
- Logging: `os.Logger(subsystem: "com.pulse.app", category: "<area>")`.
- Units: store SI values (W, J, °C, bytes, Hz) and format only in the UI.
- Files < 400 lines. One collector per file.

## Reference implementations to study (read the code, don't copy-paste licence-incompatibly)
- exelban/stats (Swift, MIT): SMC, sensors, menu-bar widgets
- vladkens/macmon (Rust, MIT): IOReport power/frequency without sudo
- metaspartan/mactop (Go, MIT): IOReport, IOHIDEventSystemClient temperatures
