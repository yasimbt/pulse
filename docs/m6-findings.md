# M6 findings: alerts, automation and export

## Metrics export (`PulseCore/Analysis/MetricsExport.swift`)
One list of named values, SI units, shared by `pulse-cli` and the HTTP endpoint. Prometheus names
follow its conventions (`pulse_cpu_usage_ratio`, `pulse_power_watts{component="gpu"}`,
`pulse_temperature_celsius{sensor="chipHottest"}`); every metric is a gauge. JSON is written with
`JSONEncoder`, which gives the shortest form of each number.

## pulse-cli
A command-line target that ships inside the app at `Pulse.app/Contents/MacOS/pulse-cli`, with
`@executable_path/../Frameworks` in its run path so it uses the app's PulseCore. It samples every
module with power detail, so it includes frequencies, temperatures and whole-Mac power whatever the
menu bar shows. `--watch` flushes after each update, so it works through a pipe.

## Local HTTP endpoint (`PulseCore/Sharing/MetricsServer.swift`)
Off by default; Settings → Sharing. Network framework listener bound to `127.0.0.1`: checked with
`lsof` (`TCP 127.0.0.1:9466 (LISTEN)`), and a request to the Mac's network address was refused.
`GET /metrics` (Prometheus text 0.0.4) and `/metrics.json`; HEAD is allowed; other paths 404, other
methods 405, no sample yet 503. It serves the app's latest snapshot, so it adds no sampling and
covers only the modules in the menu bar.

## Threshold alerts (`PulseCore/Analysis/Alerts.swift`, `Pulse/App/AlertNotifier.swift`)
Off by default; Settings → Alerts. Each alert must hold for a while before it fires, then stays
quiet for a cooldown: chip temperature (95 °C for 60 s, 30 min), swap growth (2 GB in 10 minutes,
30 min), low disk (under 10 GB or 5%, 6 h), battery health (under 80%, 7 days), sustained throttling
(thermal pressure "serious" for 30 s or "fair" for 3 minutes, 30 min) and charger shortfall (60 s,
30 min).

- Sustained throttling uses macOS's thermal pressure, not the M4 frequency detector, which needs
  the per-second detail (about 1.2% CPU). On the M5 Air, pressure reached "fair" about a minute into
  throttling, so this alert is slower but nearly free.
- With any alert on, the sampler reads memory, disk, battery, temperatures and ports every 10 s
  when nothing else needs them (about 1 ms, mostly temperature sensors).
- A condition has three states: unknown, clear and active. Snapshots between 10 s scans have no
  temperature, and treating that as "clear" would have reset the 60 s timer every second.
- Notifications use one identifier per alert kind, so a newer alert replaces an older one of the
  same kind. Permission is asked for when an alert is first turned on.

## Rules (`PulseCore/Analysis/Rules.swift`)
"On battery" and "In Low Power Mode", each with an optional slower sample rate (2 s or 5 s) and
modules to hide. `Rules.effective` turns the person's settings and the power situation into the
settings the app runs with; Settings keeps showing the person's own. When both apply, the slower
rate wins and hidden modules add up; a rule never speeds sampling up. The power situation comes
from `IOPSGetProvidingPowerSourceType` (checked every 10 s) and `isLowPowerModeEnabled` (with its
change notification).

## Settings window
With Alerts, Rules and Sharing added, the window grew to 1,623 pt, taller than a MacBook Air's
screen, and didn't scroll. It now has a fixed height of 640 pt and the grouped form scrolls.
`SettingsStore` takes the `UserDefaults` to use, so previews write to a throwaway domain.

## Shortcuts actions (`Pulse/App/PulseIntents.swift`)
App Intents in the app target: "Get Current Metrics" (returns a sentence such as "CPU 12%, memory
76%, power 3.2 W, chip 45 °C."), "Start Pulse Session" (optional name) and "Stop Pulse Session"
(returns the session's summary). `PulseShortcuts` lists them with phrases so they appear in
Shortcuts and Spotlight without setup. They run inside the running app through `IntentBridge`, so
they use the menu bar's latest snapshot and the same session recorder; temperatures appear in the
summary only when something is reading them (an open Power panel, a session or alerts).
The build's `Metadata.appintents/extract.actionsdata` lists all three actions and three shortcuts.

## M6 acceptance
SPEC.md gives M6 no acceptance line, so each item was checked as below.

| Spec item | Status |
|---|---|
| Threshold alerts (temperature, swap growth, low disk, battery health, sustained throttling) via UserNotifications, with cooldowns | Done, plus charger shortfall. Engine tests cover timing and cooldowns; the developer saw a real chip-temperature notification. |
| Rules, e.g. on battery reduce sample rate or hide a module | Done for on battery and Low Power Mode; checked live by the developer. |
| App Intents / Shortcuts: get current metrics, start/stop session | Done; run in Shortcuts by the developer. |
| Local HTTP endpoint, opt-in, localhost only, JSON and Prometheus | Done; checked live, including refusal on the network address. |
| `pulse-cli` with `--json`, `--prometheus`, `--watch` | Done; ships inside Pulse.app. |

Accepted by the developer on 2026-11-09 and tagged v0.6.0. 114 tests pass; lint is clean.
v0.5.0 is not tagged yet: M5 stays open until a second charger and a hub are tested.
