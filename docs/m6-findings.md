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
