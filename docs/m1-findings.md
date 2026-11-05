# M1 data source findings

Recorded on an Apple M5 (4 Super + 6 Efficiency cores) running macOS 27.2.
Reproduce with `Tools/spikes/m1-sources` and `Tools/spikes/m1-details`.

## CPU clusters
- `hw.perflevel0` is the fastest tier. On the M5 it is named `Super`, not `Performance`.
- Logical CPUs are numbered slowest first: cpu0-5 are `cluster-type` E and cpu6-9 are P,
  so `perflevel0` does not map to the first CPUs.
- Pulse reads `cluster-type` from the `cpuN` IORegistry nodes and takes names from sysctl.

## Process list
- `proc_pid_rusage` and `proc_name` fail for processes owned by other users: 337 of 950 here,
  including anything running as root. Activity Monitor gets these through a privileged helper.
- **Decision:** panels list "your processes" and state how many are unreadable. Spawning the
  setuid `ps` every sample would use up the CPU budget by itself.
- Whole-system CPU, memory, disk, and network totals are not affected.

## Process CPU time units
- `ri_user_time` and `ri_system_time` are Mach ticks on Apple Silicon, not nanoseconds.
  A 1 s burn measured 23,991,310 at timebase 125/3. Unscaled, values read about 40x too low.
- `ri_energy_nj` exists in `rusage_info_v6`, not v4. Its units are unverified until M2.

## Network
- Both `getifaddrs` and `NET_RT_IFLIST2` report counts in 1 KiB steps on this OS, so rates
  have 1 KiB resolution.
- Pulse uses `NET_RT_IFLIST2` for its 64-bit counters. `if_data` from `getifaddrs` wraps at 4 GiB.
- Routing buffers contain messages shorter than `if_msghdr2`, so read the common header first.
- Totals count `en*` only, because `utun` VPN traffic also crosses the physical interface.

## Memory
- `kern.memorystatus_level` is the free percentage (matches `memory_pressure -Q`), not pressure.
- Pulse uses `kern.memorystatus_vm_pressure_level`: 1 normal, 2 warning, 4 critical.

## Battery
- Top-level `CurrentCapacity` and `MaxCapacity` are percentages. Raw values are under `BatteryData`.
- `Temperature` is not exposed by `AppleSmartBattery` on the M5, so the field is hidden.
  M2's temperature collector may provide it.
- `TimeRemaining` of 65535 means unknown.
- Properties include `Serial`, so fixtures keep numeric fields only.

## nettop
- `nettop -P -L 1 -x -J bytes_in,bytes_out -n` takes about 14 ms and prints cumulative totals, so
  rates come from differences between runs. It runs every 5 s, only while the network panel is open.

## Menu-bar update cost
On this OS, status items are drawn by `MenuBarAgent`. Setting `button.image` or `button.title` makes
AppKit snapshot the item and send it over (`-[NSStatusItem _updateReplicant:]`).
`Tools/spikes/statusitem-cost` measured one item in isolation with no collectors, using `ps` CPU
time over 30 s:

| Strategy | CPU at 1 update/s | Per update |
|---|---|---|
| No updates | 0.03% | - |
| Template bitmap, 40 pt | 1.67% | 16.7 ms |
| Plain bitmap, 40 pt | 1.57% | 15.7 ms |
| Template bitmap, 200 pt | 1.80% | 18.0 ms |
| Plain bitmap, 200 pt | 1.73% | 17.3 ms |
| `button.title` | 2.47% | 24.7 ms |
| Sublayer `contents` | 0.13% | 1.3 ms |

**Decision:** Pulse draws into a `CALayer` added to the status button. The spike's sublayer was
confirmed moving on an external display. This relies on behaviour Apple doesn't document, so
recheck it on each new macOS release.

A layer isn't recoloured the way a template image is, so Pulse draws using the button's
`effectiveAppearance` and redraws when that changes.

### Full app, Release build, 1 s rate
Measured from outside with `ps`, with panels and Settings closed unless noted. Runs with a Pulse
window open, or where the Mac slept, are excluded. A 0.135% reading was caused by sleep.

| Configuration | CPU | Footprint |
|---|---|---|
| Button images, one wide combined item | about 2.5% | 23 MB |
| Layer, 5 sparklines, one transaction per item | 0.448%, 0.486%, 0.552% | 27-28 MB |
| Layer, 5 sparklines, one transaction per tick | 0.415%, 0.434%, 0.439%, 0.467% | 27 MB |
| Same, 5 items combined, compact layout | 0.524%, 0.547%, 0.540%, fresh start 0.547-0.571% | 22-24 MB |
| Combined, with cached text measurements, `CGImage` contents and 60 s free space (current) | 0.375% over 317 s | 23 MB |
| 5 sparklines, same changes (current) | 0.395% over 190 s | 33 MB |
| A panel open for the whole run (not a clean measurement) | about 5.8% | 90-106 MB |

- Grouping updates into one `CATransaction` and removing `String(format:)` from per-sample formatting
  gave the current margin. Collectors take about 0.5 ms per second.
- Capping redraws at 3 items per tick made no measurable difference, so there is no cap.
- Single runs of the same binary vary, so compare several runs.
- RSS stays at about 85-88 MB even with the panels closed, because it counts shared system libraries.

The combined item originally missed the target, which the sparkline runs had labelled the worst
case. It redraws almost every tick because network digits change, and a profile showed measuring
text as about half of that drawing. Free-space reads were the largest collector cost, because they
ask the system to total its purgeable caches. A fresh start measured the same as six hours of
uptime, so this was the cost of the configuration and not drift.
