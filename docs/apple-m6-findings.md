# Apple M6 findings: power and frequency (macOS 27.2.1)

Spike: `Tools/spikes/ioreport`. Fixtures: `PulseCoreTests/Fixtures/ioreport-power-m6-{idle,load}.json`
(`ior dump 2`, idle and with 6 busy loops). Compare with the M5 in [`m2-findings.md`](m2-findings.md).

## What changed from the M5
- **Three core tiers.** `sysctl hw.nperflevels` is 3: Super (2 cores), Performance (4) and
  Efficiency (6). The CPU module already reads tiers from `hw.perflevel*`, so it needed no change.
- **Two power clusters.** IOReport still has only `EACC` and `PACC0`. The Super cores are `PCPU`
  and the Performance cores are `MCPU`, and both sit in `PACC0`: they share its energy histogram,
  its 21 residency states (IDLE plus 20) and the `voltage-states5-sram` table. Power and
  frequency can't be split between them, so Pulse's power "performance" cluster counts all six.
- **Core channel names carry the cluster.** `CPU Core Performance States` channels are
  `EACC_ECPU0-5`, `PACC0_PCPU0-1` and `PACC0_MCPU2-5`, instead of the M5's `ECPU0-5` and
  `PCPU0-3`. Matching only on `ECPU`/`PCPU` found no cores, so cluster activity and frequency
  were missing. Pulse now uses the cluster prefix when there is one, then the core prefix.
- **Energy channels** are `EACC0` and `PACC0` (plus `SRAM` variants); the existing `EACC`/`PACC`
  prefix match still works.
- **Frequency tables moved.** A `pmgr` IORegistry node still exists but has no `voltage-states*`.
  They are on `pmgr-child`, with the same keys as the M5. Pulse now takes the first `pmgr*`
  device that has `voltage-states5-sram`.

| Table | Entries | Range | Matches |
|---|---|---|---|
| `voltage-states1-sram` | 7 | 972-2940 MHz | E cores, 7 running states |
| `voltage-states5-sram` | 20 | 1440-4788 MHz | PACC0 cores, 20 running states |
| `voltage-states9` | 13 (+ a zero off state) | 502-1735 MHz | GPU, 15 running states (the top ones unmapped, as on the M5) |

## Not yet verified
- Watts have not been compared against `sudo powermetrics` on the M6, so the PMP event length
  calibrated on the M5 (`PowerCalculations.eventSeconds`) is assumed to hold. With 6 busy loops,
  PMP gave 16.0 W for `PACC0`, and AppleCLPC's counter about 13 W in a separate run.
- The GPU table mapping is as unconfirmed as on the M5.
