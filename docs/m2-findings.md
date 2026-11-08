# M2 findings: power and thermals on the M5 (macOS 27.2)

Spike: `Tools/spikes/ioreport`. IOReport is a private library loaded with `dlopen` from
`/usr/lib/libIOReport.dylib`, which lives in the dyld shared cache rather than on disk.

## Works
- All IOReport functions that macmon and mactop use are present.
- **CPU residency:** `CPU Stats / CPU Core Performance States` has one channel per core.
  ECPU0-5 have 9 states (IDLE, V0P7 ... V7P0) and PCPU0-3 have 20 (IDLE, V0P18 ... V18P0).
- **GPU residency:** `GPU Stats / GPU Performance States`, channel GPUPH, has 16 states (OFF, P1 ...).
- **Frequency tables:** the `pmgr` IORegistry node holds `voltage-states*`, as pairs of UInt32.
  `voltage-states1-sram` (8 entries, 972-3048 MHz in kHz) matches the 6 E cores.
  `voltage-states5-sram` (19 entries, 1308-4464 MHz) matches the 4 P cores' 19 active states.
  `voltage-states9` (13 entries, 0-1578 MHz in Hz) is probably the GPU. The GPU reports 15
  active states, so the mapping is still unconfirmed.
- **GPU energy:** `Energy Model / GPU Energy` (nJ) counts normally.

## Does not work
- **CPU, ANE and DRAM energy:** `Energy Model` lists the expected channels (`CPU Energy`, `ECPU`,
  `PCPU`, per-core, `ANE`, `DRAM`, all in mJ), but their raw values did not change at all over
  30 s with 4 busy loops. Only GPU Energy and the PCIe channels move. No other IOReport group
  reports CPU energy or power.

## When the CPU energy counters update (10-minute watch, non-root)
`ior watch 600` read the counters once a second. The Mac slept during the run, so only the sample
index is meaningful, not the timestamps.
- Samples 0-250: one change, at sample 185.
- Samples 251-350: a change every 1-6 samples, about 0.3-1.1 W of CPU, which is plausible.
- Samples 351-599: one change, at sample 519.
- An earlier 30 s run with 4 busy loops saw no change at all, so CPU load alone does not trigger
  updates.

The counters work but update only some of the time. A likely cause is that the driver refreshes
them only while another client, such as `powermetrics` running as root, is sampling. Not yet
confirmed.
- Running the spike as root does not help: 15 s of `sudo ior watch 15` showed no change in CPU,
  ECPU, PCPU, DRAM or ANE energy, while GPU Energy counted normally.

## Why the CPU energy counters freeze, and a possible way around it
- The counters update while `powermetrics` runs and freeze when it exits. In one run they were
  still for 5 s, changed every second during 10 s of `powermetrics`, then froze again.
- Other projects report the same on macOS 27 with M5-class chips: macmon reads 0 W CPU power, and
  refreshing these counters appears to need a private Apple entitlement. Running as root is not
  enough.
- **`PMP / Energy`** has live per-cluster histograms: `EACC0` (E cluster), `PACC0` (P cluster) and
  `AGX` (GPU), each with an SRAM channel. Each state is a power bucket, such as `0.250W` or `16W`,
  and its value is an event count. Under 4 busy loops, the P cluster moved from about 1 W to the
  16-17 W buckets. The time per event is unknown, so `ior calibrate` and `calibrate.sh` measure
  the histograms against Energy Model while `powermetrics` keeps it live.
