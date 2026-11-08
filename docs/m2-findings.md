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

## Calibration result: CPU watts from the PMP histograms
`sudo sh Tools/spikes/ioreport/calibrate.sh`, 12 s per stage, MacBook Air (Mac17,3, no fan).

| Busy loops | powermetrics CPU | Energy Model CPU | Histogram estimate | vs powermetrics | vs Energy Model |
|---|---|---|---|---|---|
| 0 | 0.085 W | 0.216 W | 0.154 W | +81.2% | -28.6% |
| 1 | 6.707 W | 6.882 W | 6.728 W | +0.3% | -2.2% |
| 2 | 8.775 W | 8.978 W | 8.556 W | -2.5% | -4.7% |
| 4 | 18.247 W | 18.426 W | 18.263 W | +0.1% | -0.9% |
| 6 | 14.494 W | 14.608 W | 14.333 W | -1.1% | -1.9% |
| 10 | 11.372 W | 11.564 W | 11.511 W | +1.2% | -0.5% |

**Model:** energy = sum over buckets of (bucket label - step / 2) x event count x 227.3 us, for the
cluster channel plus its SRAM channel. A bucket label is the top of its range, and `step` is the
spacing between buckets. Both clusters record at most about 4,399 events per second (52,790-52,811
per 12 s when busy), which gives the 227.3 us.

- **Under load it is within 2.5% of powermetrics**, well inside M2's ±10% target, with no root and
  no powermetrics running.
- **At idle the three sources disagree** (0.085, 0.154 and 0.216 W), so percentages are not
  meaningful there. The estimate is within 0.07 W of powermetrics, which is fine for display.
- 6 and 10 loops drew less than 4: this fanless Air throttles under sustained all-core load. M4's
  throttling detection can use this.
- GPU power uses the `GPU Energy` counter, which stays live without root. It is not calibrated
  under GPU load yet.
- ANE and DRAM have no live source, so they will be hidden.

## Sampling cost, and the cheaper AppleCLPC counters
CPU time per `IOReportCreateSamples` + delta, one sample per 1-3 s (`ior time 1 8`, `ior time 3 4`).
Almost all of it is the kernel call; back-to-back calls look cheaper because the cores are already
running fast.

| Group | CPU per sample |
|---|---|
| PMP / Energy (histograms) | 7.3-7.6 ms |
| Energy Model, all 167 channels | 5.5-6.1 ms |
| CPU Stats / CPU Core Performance States | 3.1 ms |
| GPU Stats / GPU Performance States | 1.6-1.8 ms |

At one sample per second, PMP alone would cost about 0.75% CPU, more than Pulse's whole budget.

**AppleCLPC aggregate counters** (`Tools/spikes/clpc`): the CPU performance controller keeps hidden
energy counters in a `CLPC / Energy Counters` group that IOReport doesn't list. macmon 0.9 (MIT)
describes them by hand with per-chip IDs extracted from macOS 27.0. With its M5 (`AppleT8142CLPC`)
IDs on macOS 27.2, without root:
- CPU Energy: 0.18-0.30 W idle and 18.0-18.5 W with 4 busy loops (powermetrics: 18.2 W).
- GPU Energy counts; ANE reads 0 at idle and is not yet checked under an ANE workload.
- **Cost: 0.5-1.1 ms per sample**, roughly a seventh of the PMP histograms.

Trade-offs: CLPC gives one CPU total rather than E/P clusters, and its IDs are chip- and
OS-specific, so they may change with a macOS update. The PMP histograms need no IDs and give the
cluster split, but cost far more.

## Power collector design (PulseCore)
- **Always:** AppleCLPC CPU, GPU and ANE counters on verified chips (M5 on macOS 27), then
  1.46 ms of CPU per sample, about 0.15% at a 1 s rate. Other chips or macOS versions fall back to
  the PMP histograms plus the Energy Model GPU counter, read at most every 5 s.
- **Detail on** (Power panel open): adds the PMP histograms for the E/P split and performance-state
  residency for frequencies, 11.7 ms per sample in total.
- Frequency tables come from `pmgr` and are used only when their length matches the residency
  states, so an unverified chip shows watts without frequencies rather than wrong frequencies.
- ANE watts are read but not yet checked against powermetrics under an ANE workload.

## Full app with Power in the menu bar (Release, combined item, panels closed)
| Configuration | CPU |
|---|---|
| Power off (same session, for comparison) | 0.420% over 193 s |
| Power read every second | 0.553%, then 0.537% after skipping the since-boot total while closed |
| Power read every 2 s (current) | 0.503%, 0.495% |

Power adds about 0.08% when read every 2 s, which puts the combined item right at the 0.5% target.
Each read averages the whole interval, so the slower refresh misses no energy. The panel still
reads every second, with the cluster split and frequencies. Footprint stays at 23 MB closed.

## Temperatures (`Tools/spikes/hid-temps`)
IOHIDEventSystemClient, matched on usage page 0xff00 and usage 5, lists 47 sensors on the M5 with no
root. Reading all of them costs about 1.4 ms of CPU. Sensor names don't say what they measure, so
they were identified by load (idle, then 25 s of 4 and of 10 busy loops):

| Sensors | Idle | 4 loops | Reading |
|---|---|---|---|
| PMU tdie1-14 | 37-40 °C | 57-76 °C | Chip die. tdie1, 6 and 8 heat most, probably beside the P cores. |
| PMU2 tdie1-10 | 34-35 °C | 43-45 °C | Even +10 °C rise: probably a second power chip, not the die. Not shown. |
| NAND CH0 | 34 °C | 40 °C | SSD |
| gas gauge battery (6) | 27-28 °C | | Battery. AppleSmartBattery has no temperature on the M5, so this fills the gap. |
| PMU tdev1-8 | | | Board sensors. tdev1 reads -22 °C and is faulty. Not shown. |
| PMU tcal | 51.82 °C | 51.82 °C | Constant, probably calibration. Not shown. |

At 10 loops the die ran cooler than at 4 (65 vs 76 °C hottest), matching the throttling seen in power.
No sensor is identified as the GPU yet, so no GPU temperature is shown.

`PulseCore/Resources/TemperatureSensors.json` groups sensors by name prefix per model, with defaults
for unknown models: chip hottest and average (PMU tdie), SSD and battery. Readings outside 0-130 °C
are dropped. Only mapped sensors are opened. Temperatures show in the Power panel and are read only
while it is open.
