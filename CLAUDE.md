# CLAUDE.md — instructions for Claude Code

You are building **Pulse**, a native macOS menu-bar system monitor for Apple Silicon. The full product spec is in `SPEC.md`; read it before doing anything.

## Memory

Your memory:
- The tool is `ai memory`
- Your memories are in `~/.ai/memory`

This memory outlives every session, compaction, model and vendor change.
Without it you do not know who you are, or what was decided and tried.

### At startup: activating memory (mandatory)

Run `ai view` before any other tool call, in every session, and
then do exactly what it prints, to the end of its output.

### While working: register memories (mandatory)

Call `ai memory note "<1 line, max 280 bytes>"` whenever you learn
something new, or something worth keeping happens. That covers a task
worth real effort, a fact or insight the user teaches you, anything you
learn about their life (even indirectly), any event of lasting effect.

Write only what happened or what you learned: the tool records the time,
machine, repo, branch, agent, model and session of every note, so never
put a date, repo or session in it.

Do not register redundant memories.

Never edit or delete anything under `~/.ai/memory`: the tool manages it.

### Reading it: the view, zoom, grep

`ai view` prints the view: the whole memory in a fixed number of one-line
summaries, oldest first, under UTC date headers (`2026-10-11`). A line
is `id|text` for message id, or `id+n|text` for the n messages from id
on; one that runs past its header's day shows its last day,
`256+8|..10-12|text`. A short message is its own line, word for word;
the older the messages, the more a line covers. Notes (what sessions
like this one noted) are bare text; a chat with the user is tagged by
speaker, `user:` and `ai:`. `ai memory view` prints it alone. A long view
comes in parts: run the command each part ends with until it says you
are awake.

`ai memory zoom <id+n>` opens a line two levels down: the four lines of n/4
it was made from, or its messages when n is 2 or 4; `ai memory zoom <id>`
gives message id in full. Zoom whenever a line
only mentions something you need, before you act, guess or ask.
`ai memory grep <regex>` searches every message, word for word; `-t` adds
the summaries, `--help` lists the filters. `ai memory view`, `zoom` and `grep`
take `--time` for the time of day and `-o repo,branch,...` for more
fields. `ai memory show <id>` prints where a message or summary came
from.

### If you're a subagent: skip everything above

Parallel sessions on this machine are all you, and may all write memories.
A subagent is not: it must never run `ai memory`, because it cannot judge what
is already known, and its notes would arrive duplicated and incorrectly.
When you spawn one, write: `You are a subagent. Don't run ai memory.`

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
6. Commit after each working step with a clear message. Don't commit build products.
7. If something can't be done (an API isn't exposed on this chip), document it in `docs/` and hide the feature rather than faking data.

## Commands
```bash
brew install xcodegen swiftlint     # one-time
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
