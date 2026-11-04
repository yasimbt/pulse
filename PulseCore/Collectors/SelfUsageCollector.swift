import Darwin

/// Pulse's own CPU and memory use, for the indicator in Settings.
public actor SelfUsageCollector: Collector {
    public nonisolated let id = MetricID.selfUsage
    private let clock = ContinuousClock()
    private let start: (cpu: UInt64, time: ContinuousClock.Instant)
    private var previous: (cpu: UInt64, time: ContinuousClock.Instant)

    public init() {
        let now = ContinuousClock.now
        let cpu = Self.read()?.cpu ?? 0
        start = (cpu, now)
        previous = (cpu, now)
    }

    public func sample() throws -> SelfUsage {
        guard let reading = Self.read() else {
            throw CollectorError.unavailable("proc_pid_rusage(self) failed")
        }
        let now = clock.now
        defer { previous = (reading.cpu, now) }
        return SelfUsage(
            cpuCores: Rates.perSecond(current: reading.cpu, previous: previous.cpu, seconds: Rates.seconds(now - previous.time)) / 1e9,
            averageCPUCores: Rates.perSecond(current: reading.cpu, previous: start.cpu, seconds: Rates.seconds(now - start.time)) / 1e9,
            footprintBytes: reading.footprint
        )
    }

    private static func read() -> (cpu: UInt64, footprint: UInt64)? {
        guard let usage = readRusage(pid: getpid()) else { return nil }
        let timebase = SystemInfo.timebase
        let cpu = ProcessCalculations.nanoseconds(
            ticks: usage.ri_user_time + usage.ri_system_time,
            numer: timebase.numer,
            denom: timebase.denom
        )
        return (cpu, usage.ri_phys_footprint)
    }
}
