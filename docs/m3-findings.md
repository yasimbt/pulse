# M3 findings: history store

## Store design (`PulseCore/Store`)
- SQLite through GRDB 7.12.0, pinned exactly in `project.yml` (the generated project and its
  `Package.resolved` aren't committed). File: `~/Library/Application Support/Pulse/history.sqlite`,
  in WAL mode so reads don't wait for writes.
- Three tiers with the same columns, one row per time and one column per `SeriesID` (its raw
  value is the column name, so cases must never be renamed):
  `samples_raw` (1 h), `samples_10s` (24 h) and `samples_1m` (30 days), as in SPEC §3.
- Writes are buffered and done in one transaction every 30 s, which also averages completed
  buckets into the coarser tiers and deletes rows past retention. Quitting normally writes the
  buffer first; a crash or `kill` loses up to 30 s.
- Reads use the finest tier that reaches back to the start of the range, then finer tiers for the
  newest stretch the coarser tier hasn't averaged yet, then unwritten buffered rows.
- Only enabled modules are sampled, so history covers what's in the menu bar.
- Migrations: GRDB's `DatabaseMigrator`. Shipped migrations are never edited.

## Measurements
- **Size:** 30 days with every tier full and every series set: 6 MB (test
  `thirtyDaysOfHistoryStayFarUnder200MB`). Acceptance limit: 200 MB.
- **CPU:** combined menu-bar item with Power, Release, panels closed: 0.508% over 189 s with history
  on, against 0.495-0.503% before. The 30 s batched writes are within run-to-run noise.
- **Quit:** after a normal quit, the newest row was 2 s before quitting.

## Process snapshots
- Every 10 s, the union of the top 5 by CPU, memory and energy (about 11 processes) goes into
  `processes_10s`, kept for 24 h. Each finished minute is thinned into `processes_1m`, kept for
  30 days: each process's peak values, keeping only processes in that minute's top 5 by any of
  the three. "Processes at T" returns the nearest snapshot at or before T, or nothing across a gap.
- History needs a process scan every 10 s even with every panel closed: about 5.2 ms of CPU each
  (0.052%). With panels open, the every-second scans are reused.
- **Size:** 30 full days of metrics and process snapshots: 64 MB.
- **CPU:** combined menu-bar item with Power, Release, panels closed: 0.558% and 0.579% over 190 s,
  against about 0.50% without process snapshots. Over the 0.5% target; see the decision below.

## Linking PulseCore without GRDB
Tools in `Tools/spikes` compile against `PulseCore.framework` with `swiftc`. `internal import GRDB`
still made clients require GRDB's modules, because without library evolution Swift records internal
imports in the compiled module. `@_implementationOnly import GRDB`, plus making `HistoryDatabase` a
class so that clients never need its layout, removes that.

## Budget decision (developer, 2026-11-09)
Process snapshots every 30 s instead of 10 s, and menu-bar Power every 3 s instead of 2 s. Combined
item with Power and history, Release, panels closed: 0.520% over 252 s (one clean run; two other
runs had a Pulse window open and are excluded). Two more clean runs: 0.458% and 0.500% (a third was excluded because the Mac slept). Average of the
three clean runs: 0.493%, just under the 0.5% target, with little margin.

## History window
- Opened with "History…" in any panel's footer. One chart per metric group (CPU, memory, power,
  network, disk, battery) on a shared time axis; groups with no data in range are hidden.
- Zoom: 1 h, 6 h, 24 h, 7 d and 30 d buttons, or pinch on the trackpad (5 min to 30 days).
  Scrubber: a slider moves the range back through the last 30 days. "Now" returns to the present.
- Crosshair: click or drag on any chart. The side panel lists every value at that moment and the
  nearest stored process snapshot.
- Gaps (Mac asleep or off, or Pulse not running) are shaded, and lines break there. Gaps are found
  in the full data, then lines are split only where a real gap falls between two thinned points;
  splitting by the spacing of thinned points broke every line into dots at 24 h.
- Each series is thinned to 600 points for drawing, keeping each bucket's peak so that spikes stay
  visible. Values under the crosshair come from the full data.

**Performance (acceptance: 24 h renders in < 300 ms):** a full synthetic day, inserted as 86,400
one-second rows and averaged and pruned by the store as a real day would be: 13,050 points read in
23 ms and drawn by `ImageRenderer` in 85 ms, about 110 ms in total
(`Tools/spikes/render-preview`, `benchmarkFullDay`). The window also shows its own load time.
