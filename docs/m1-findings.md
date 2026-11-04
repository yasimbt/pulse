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
