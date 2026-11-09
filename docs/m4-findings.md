# M4 findings: sessions and throttling

## What throttling looks like on the M5 MacBook Air (`Tools/spikes/throttle`)
`run.sh` records once a second: load, E/P active share and frequency (from residency), watts, chip
temperature and `ProcessInfo.thermalState`, through 30 s idle, a load, and 60 s cooling.

**`yes` loops are the wrong load.** With 10 of them the P cores sat in their top state at only about
9 W (16 W at 4 loops, in a lower state): `yes` mostly waits in the kernel writing to /dev/null, so
cores count as busy but do little. The chip reached 67 °C and never throttled.

**Floating-point work on every core plus a Metal GPU load** (`pulse-power cpu-load` and `gpu-load`)
draws about 25 W of CPU and throttles within seconds
(`PulseCoreTests/Fixtures/throttle-m5-cpu-gpu-load.csv`):

| Into the load | P frequency | CPU watts | Chip hottest | Thermal state |
|---|---|---|---|---|
| 3 s | 3140 MHz | 21.9 W | 77 °C | nominal |
| 13 s | 2170 MHz | 14.0 W | 82 °C | nominal |
| 24-66 s | 1600-1780 MHz | 10-12 W | 84-88 °C | nominal |
| 67 s on | about 1350 MHz (minimum 1308) | 3.4-7.5 W | 75-88 °C | fair |

The E cluster fell from 2758 to about 1560 MHz. macOS's thermal state is late (about a minute) and
coarse, and stays "fair" for 45 s after the load ends. All-core load runs below the single-core
maximum without throttling (3140 MHz at the start), so the threshold must sit well below it.

## Throttle rule
A second is throttled when some cluster is at least half active and below 60% of its maximum
frequency, and the chip's hottest sensor is at least 80 °C or the thermal state is fair or worse.
A throttle period starts after 3 throttled seconds and ends after 10 normal ones.

On the recording: one period from 42 s to 329 s, starting 12 s into the load and ending with it.
No false positives at idle or while cooling, even with the thermal state still "fair". With a 3 s
end, work briefly moving off the P cores split it into three periods.

## Sessions
- Record from any panel or with ⌃⌥⌘R (Carbon `RegisterEventHotKey`, no Accessibility permission).
  While recording, Pulse reads frequencies, temperatures, whole-Mac power and processes every
  second, as with the Power panel open. Stopping saves the session and opens its summary.
- Stored in the history database (migration v3): one row per session with its summary, samples and
  per-process totals as JSON. The Sessions window shows one session's summary and charts with
  throttle bands, compares two side by side, and exports JSON (everything) or CSV (one row a second).
- Process totals add each scan's top processes for the time the scan covers, so a process is counted
  only while it's among the busiest. Energy adds watts times the gap to the next sample, capped at
  5 s so that sleep adds nothing.

## Acceptance run (`sh Tools/spikes/session-check/run.sh`)
Pulse's own Sampler and SessionRecorder, 5 minutes: 30 s idle, 240 s of floating-point CPU load plus a
Metal GPU load, 30 s cooling.

- Duration 5:00. CPU usage 70% average, 100% peak; GPU 74%, 100%. CPU power 7.3 W average, 26.9 W
  peak; GPU 9.4 W, 14.4 W; whole Mac 23.8 W, 52.2 W. Hottest chip 87 °C; worst thermal state fair.
- **Throttle bands:** one period, 49-271 s. The load ran from about 32 s to 272 s.
- **Energy:** summed 5,148.7 J against the cumulative CLPC counter's 5,140.8 J over the same samples:
  +0.15%.
- Top process: the load generator, `pulse-power`, with 1,961 CPU-seconds (about 8.2 of 10 cores).
- Only 227 samples in 300 s: under full load the utility-priority sampler sometimes ran late. Energy
  uses the real gaps, so it's unaffected; averages are per sample, so they're slightly less exact
  under extreme load.
