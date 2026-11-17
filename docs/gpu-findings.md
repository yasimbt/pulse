# GPU findings: utilisation, memory and per-process GPU time (Apple M6, macOS 27.2.1)

Spike: `Tools/spikes/gpu` (`sh Tools/spikes/gpu/run.sh watch|cadence|bench|dump|clients`). Fixtures:
`PulseCoreTests/Fixtures/gpu-m6-{idle,load,client-churn}.json`. Plan:
[`gpu-module-plan.md`](gpu-module-plan.md).

## Sources (no root)
- **`AGXAccelerator*` (class `IOAccelerator`) → `PerformanceStatistics`**: `Device Utilization %`,
  `Renderer Utilization %`, `Tiler Utilization %` (integers), `In use system memory`,
  `Alloc system memory` (bytes) and a few driver counters. Also `model` ("Apple M6") and
  `gpu-core-count` (12).
- **Each `AGXDeviceUserClient` child**: `IOUserClientCreator` = `"pid 427, WindowServer"` (the
  name is `p_comm`, cut to 16 characters: `"com.apple.Safari"`, `"TextInputSwitche"`) and
  `AppUsage` = one `{API, accumulatedGPUTime, lastSubmittedTime}` entry per Metal command queue.
  38 clients on this Mac; WindowServer has two.

## accumulatedGPUTime is nanoseconds of GPU time
The spike keeps the GPU busy for a set share (duty) of each 100 ms and reads its own clients'
`accumulatedGPUTime` change over each second:

| Duty | Own GPU time / wall | All clients | GPUPH active | Device Utilization | GPU W | GPU MHz |
|---|---|---|---|---|---|---|
| idle | 0 | 0.045 | 0.08 | 5% | 0.10 | 502 |
| 0.25 | 0.23 | 0.27 | 0.32 | 64% | 1.1-1.8 | 840-1040 |
| 0.5 | 0.47 | 0.49 | 0.54 | 78% | 4.2-6.0 | 1280-1520 |
| 1.0 | 0.97 | 0.99 | 1.00 | 95% | 14.5 | 1735 |

So the unit is nanoseconds, and the sum over all clients is the GPU's busy share.

## Device Utilization is an instant value, not an average
Read every 50 ms under a load busy for 0.3 s of every 1 s, it jumps to 97 within about 100 ms of
the load starting and drops to 0 when it stops (`cadence`). Read once a second, it is one moment
of the second, not its average. With 1 s bursts at 25% duty it read 0 or 75-83. With 100 ms bursts
it read 64%; with 20 ms bursts, 29-38%. It also stays at 95% when the GPU is fully busy.

**Activity Monitor agrees with GPU time.** With the spike holding a 25% load (20 ms bursts) for
180 s, Activity Monitor's % GPU for the process read about 25%, and Window → GPU History looked
about a quarter full. Over the same run: own GPU time 0.272, all clients 0.276, GPUPH active 0.273,
Device Utilization 29% on average, but noisy.

**Conclusion:** Pulse's "GPU usage" is the sum of all clients' GPU time over the interval, capped
at 1, not Device Utilization. GPUPH active residency agrees within a few points under load and
reads higher at idle (0.08 against 0.045), and it needs an IOReport subscription.

## Counters go backwards when a command queue closes
`clients` step by step, for the spike's own client (its registry ID stays the same throughout):

| Step | Queues | accumulatedGPUTime |
|---|---|---|
| device created | 0 | 0 |
| queue + 1 s of work | 1 | 0.98 s |
| second queue + 1 s | 2 | 1.96 s |
| second queue freed | 1 | 0.98 s |
| everything freed | 0 | 0 |

The client and its ID outlive its queues, and a freed queue takes its time out of the client's
total. `AppUsage` entries carry no ID to match them across reads. Keying by pid would also mix
clients, so the collector keys by client registry ID and treats a fall in a client's total as 0
for that interval. That undercounts only the interval in which a queue closes, and only by that
client's other queues' work. A client first seen after the first scan is new since the last read,
so its whole total belongs to the interval. Pid reuse can't carry a total over, because a new
process gets new clients.

## Memory
`In use system memory` (about 130-160 MB idle on this Mac) and `Alloc system memory` (about
850 MB) are unified memory, already counted in Pulse's memory module. Shown as GPU detail only,
never added to memory used.

## Cost (`bench`, Release, M6)
| Read | Cost |
|---|---|
| `PerformanceStatistics` alone, cached service | 47 µs |
| Every accelerator property (`IORegistryEntryCreateCFProperties`) | 743 µs |
| Matching the service | 2 µs |
| Walking 38 user clients (`IOUserClientCreator`, `AppUsage`) | 225 µs |

The headline needs the client walk, so the GPU module costs about 0.27 ms per sample: about
0.03% CPU at 1 s, inside the 0.125% left from M1's measurement. The walk gives per-process rows
at no extra cost.

## Not found
- No GPU temperature sensor (see m2-findings).
- Per-process GPU memory isn't in `AppUsage`.
- Only the M6 is checked. The M5's `PerformanceStatistics` keys are unverified.
