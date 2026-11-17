# Plan: GPU module and panel

Status: revised after review (pulse.review, 2026-11-17, against fd1d3ab) and after the spike
([`gpu-findings.md`](gpu-findings.md)). Steps 0 and 1 are done (v0.6.2, `Tools/spikes/gpu`).

## Goal
Add a **GPU** module that works like CPU: a menu-bar item (text, sparkline, bar or gauge), and a
panel with details, a 10-minute chart and the top processes. Today GPU numbers appear only inside
the Power panel (watts, frequency, active residency), the HUD and sessions. `pulse-cli --json`
has no GPU utilisation (a gap found while benchmarking MLX).

**Scope and milestones:** SPEC.md mentions GPU frequency and residency, and "hide GPU module" in
rules (§5 M6), but no milestone has a GPU module. This adds scope, so SPEC.md gets a GPU module
entry. Where it sits relative to M7 (inside M7, or its own release) is the user's decision; see
Open decisions.

## What the Mac exposes (checked with `ioreg` on the M6, macOS 27.2.1)
1. **`AGXAccelerator*` → `PerformanceStatistics`** (IORegistry, no root): `Device Utilization %`,
   `Renderer Utilization %`, `Tiler Utilization %` (integers), `In use system memory`,
   `Alloc system memory` (bytes). Also `model` ("Apple M6") and `gpu-core-count` (12). This is
   where Activity Monitor and exelban/stats get GPU usage.
2. **Per process:** each `AGXDeviceUserClient` has `IOUserClientCreator` = `"pid 427,
   WindowServer"` and `AppUsage` = `[{API, accumulatedGPUTime, lastSubmittedTime}]`. One
   process can own several clients. The unit of `accumulatedGPUTime` is unknown until the spike.
3. **Already read by `PowerCollector`:** GPU watts (CLPC or Energy Model), and with detail on,
   `GPUPH` active residency and frequency (`voltage-states9`, unconfirmed on M5 and M6).

Items 1 and 2 are undocumented IORegistry data, so per CLAUDE.md rule 3 a spike comes first.

## Steps (one commit each)

### 0. Prerequisites (fixes from the v0.6.1 swift-reviewer review)
- **Release IOReport subscriptions.** `PowerCollector.setDetail(false)` drops `detailFeed`, but
  `IOReportSubscription` releases nothing, so every panel open and close leaks one subscription.
  Fix this before adding more detail toggles.
- **Group Prometheus output by metric name.** Families are already interleaved
  (`pulse_cpu_frequency_hertz` between `pulse_power_watts` samples), which breaks the text format
  0.0.4. Adding `pulse_gpu_*` would make it worse.
- **Downgrade safety (optional, user's call).** `SettingsStore` decodes with `try?` and falls back
  to `.default`, so an older Pulse that reads `"gpu"` in settings would silently reset everything.
  To prevent that, decode `modules` leniently (skip unknown kinds) in a release before the GPU one.

### 1. Spike: `Tools/spikes/gpu/`
A command-line tool that prints, every second:
- the `PerformanceStatistics` dictionary, `model`, `gpu-core-count`;
- per-client `accumulatedGPUTime` deltas, keyed by registry entry ID, then summed per pid;
- the time each read takes: one `IORegistryEntryCreateCFProperty` of `PerformanceStatistics` on
  a cached service, and the full user-client walk.

Run it idle and under a Metal load (`Tools/spikes/power-accuracy gpu-load`, or an MLX decode).
Compare against Activity Monitor's GPU % column and GPU History window, and against GPUPH active
residency. Record fixtures (`PulseCoreTests/Fixtures/gpu-m6-{idle,load,client-closed,
client-opened}.json`) and write `docs/gpu-findings.md`. **Questions the spike answers:**
- Does Device Utilization match Activity Monitor? How often does the driver update it, and how
  smoothed is it?
- `accumulatedGPUTime` unit, measured, not assumed to be ns. Does the per-process sum track
  Device Utilization?
- Cost per read, against the remaining budget. M1 measured 0.375% with 5 modules
  (m1-findings.md), so about 0.125% is left before history and power are counted.

**What the spike changed** (details in gpu-findings.md):
- "GPU usage" is the **sum of every client's `accumulatedGPUTime` change** over the interval
  (nanoseconds), capped at 1. It matches Activity Monitor. Device Utilization is an instant value
  the driver refreshes about every 50 ms, so it is dropped, with the renderer and tiler figures.
- `AppUsage` has one entry per command queue, and a client's total falls when a queue closes.
  Keying by client registry ID is still right, but a fall counts as 0 for that interval. A client
  first seen after the first scan counts its whole total, as it is new since the last read.
- The client walk feeds both the headline and the per-process rows, so one `GPUCollector` does
  both, and `GPUProcessCollector` is dropped. Cost: about 0.27 ms per sample (0.03% at 1 s).

### 2. Core model and collectors (`PulseCore`)
- `ModuleKind.gpu` (title "GPU", short label "GPU"). `PulseSettings.default` lists it disabled
  after Power. `normalized()` already appends new kinds as disabled for existing users.
- `GPUSample` in a new `Models/GPUSamples.swift`: `usage` (0...1, from GPU time),
  `memoryInUseBytes`, `memoryAllocatedBytes`, `coreCount`, `model`, and `processes`
  (`[GPUProcessUsage]`: pid, name, usage), sorted, top 5.
- `Collectors/GPUCollector.swift` (actor): matches the `IOAccelerator` service once, keeps the
  `io_service_t` and releases it in `deinit`. Each sample reads `PerformanceStatistics` with
  `IORegistryEntryCreateCFProperty` (memory only), never `…CFProperties`, and walks the user
  clients for `IOUserClientCreator` and `AppUsage`. The first sample only sets the baselines.
  - Counters are keyed per client by `IORegistryEntryGetRegistryEntryID`. A fall in a client's
    total counts as 0 (a queue closed). A client new since the last read counts in full. Deltas
    are summed per pid, then over all clients for `usage`, divided by elapsed time, capped at 1.
  - Names: `IOUserClientCreator` gives `p_comm`, cut to 16 characters. The app replaces it with
    the name from `ProcessCollector`'s table when the pid is in it.
  - Parsing and the delta maths are pure functions in `Analysis/GPUCalculations.swift`, tested
    with the fixtures.
- `Snapshot.gpu`. `collectReadings` reads it when the module is enabled, the GPU panel is open,
  or the HUD is shown.
- **Detail demand.** `PowerCollector.setDetail(Bool)` becomes an `OptionSet` `{ clusters, gpu }`,
  and the detail `Feed` subscribes only to the selections needed: PMP histograms plus CPU core
  P-states for `.clusters`, `GPUPH` for `.gpu`. `Sampler.Demand.powerDetail` becomes that option
  set. Sampler reads thermal and SMC only for `.clusters`. The 3 s summary cadence still applies
  when only `.gpu` is set, unless the spike shows GPUPH needs every sample. The GPU panel adds
  `.gpu` for frequency and "GPU active". It does not read temperatures, SMC or the PMP histograms.

### 3. History
- `SeriesID.gpuUsage` (value: `snapshot.gpu?.usage`).
- **Migration.** `v1` creates columns from `SeriesID.allCases`, and `insert()`, `rollUp()` and
  `points()` build their column lists from it too. So the column must exist in every tier before
  the first insert, or every series' INSERT fails. Freeze v1's column list as a literal of the
  current 10 raw values, and add `"v4: gpu usage"` with `ALTER TABLE … ADD COLUMN gpuUsage` on all
  three tiers. Tests: a fresh database, an upgraded v3 file, and a roll-up through the 10 s and
  1 min tiers.
- `HistoryModel.groups` is an explicit list, so add a "GPU" usage group there.

### 4. App UI (`Pulse`)
- `ModuleReading.make(.gpu)`: percent text, fraction, series `.gpuUsage`, "GPU 42% used".
- `StatusBarController`: width template and `.gpuUsage` scale 1.
- `ModulePanel`: `GPUDetails`: usage; frequency vs the table's top (when known); "GPU active"
  residency; GPU watts; memory in use / allocated; model and core count. Chart: one "Used" line (fraction).
- `TopProcessesView`: "Top processes by GPU", without "Your", as for network: the walk also sees
  root processes and WindowServer. Value as a percent of the GPU, as Activity Monitor shows it
  (the spike confirmed the unit).
- `AppController.updateDemand`: GPU panel open → `.gpu` detail. `processes: openPanel != nil`
  already runs the CPU process scan too, which counts toward the open-panel cost and supplies the
  full process names.
- Settings needs no change: it lists `ModuleKind.allCases`, and so do the rules' hidden modules.

### 5. One meaning of "GPU usage"
Headline metric: **GPU time over all clients** (`GPUSample.usage`), which matches Activity
Monitor. It's cheap and needs no detail flag. GPUPH residency is then labelled "GPU active" everywhere:
- Sessions: add an optional `gpuUtilization` to the session sample. Synthesised `Codable` decodes
  a missing optional as nil, so old sessions still load. The existing `gpuUsage` field
  (`Sessions.swift`) stays, labelled "GPU active" in `SessionsView`, `SessionDetailView` and the
  CSV in `SessionExport`. A new "GPU usage" row and CSV column carry utilisation.
- HUD (`HUDController.swift:96`): show `GPUSample.usage`, and add `.gpu` to the modules
  `AppController.updateDemand` adds for the HUD. Then check whether the HUD still needs power
  detail at all. It forces it today partly for this row, and dropping it would cut the HUD's cost.

### 6. Export and CLI
- `MetricsExport`: `pulse_gpu_usage_ratio`, `pulse_gpu_memory_bytes{kind="in_use|allocated"}`,
  and `pulse_gpu_frequency_hertz` when known. HELP text says GPU memory is unified memory already
  counted in `pulse_memory_used_bytes`, so the two shouldn't be summed. `/metrics.json` and
  `pulse-cli --json` carry the same fields.
- `pulse-cli`'s demand already uses `ModuleKind.allCases`, so it picks up the GPU automatically.

### 7. Tests, docs, release
- Unit tests: `PerformanceStatistics` parsing (M6 fixtures, plus missing keys → nil fields);
  `IOUserClientCreator` pid and name parsing; per-client deltas with the churn fixture (a queue
  closes and the total falls, a new client mid-run, a client disappears), usage capped at 1; `ModuleReading(.gpu)`; settings normalisation adds `.gpu`
  disabled; migration v4 (fresh, upgraded v3, roll-up); old sessions decode without
  `gpuUtilization`; the detail option set picks the right IOReport selections.
- Measure Pulse's CPU in Release with the GPU module on and every panel closed (M1's method);
  it must stay under 0.5%. Also measure with the GPU panel open.
- README: add GPU to the modules and panels lists. SPEC.md: the GPU module entry.
  `docs/gpu-findings.md` from the spike.
- `make test`, `make lint` before each commit.

## Out of scope
GPU temperature (no sensor identified, see m2-findings), widget changes, GPU memory per process.

## Decisions (user, 2026-11-17)
1. The GPU module is its own release with its own SPEC.md entry, separate from M7.
2. Downgrades matter: lenient settings decoding (step 0) ships first, in a patch release before the
   GPU one.
3. Relabel approved: the Activity Monitor-matching figure is "GPU usage" everywhere, residency
   becomes "GPU active" (step 5). The spike showed that figure is GPU time, not Device Utilization.
