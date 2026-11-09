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
